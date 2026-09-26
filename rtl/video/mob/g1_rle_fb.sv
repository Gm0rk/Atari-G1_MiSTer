//============================================================================
//  Atari G1 for MiSTer
//  g1_rle_fb.sv -- double-buffered motion object framebuffer and erase engine
//
//  Two 336 x 240 x 10-bit buffers in BRAM, about 79 M10K each (158 of the
//  DE10-Nano's 553). Pixels are 10 bits because a 6bpp object reaches palette
//  index $200 + (color << 4) + $3F = $32F; only the self-test pattern
//  (object 2 in each game) uses 6bpp.
//
//  Control register $FA0001 (byte):
//      bit 0  MOGO   rising edge executes the pending command
//      bit 1  ERASE  erase the displayed buffer behind the raster
//      bit 2  FRAME  selects the displayed buffer
//
//  MAME atarirle.cpp (control_write / vblank_callback):
//    control_write(data), only if data != old bits:
//      if old ERASE:  clear buffer[old FRAME] over lines
//                     max(0, partial+1) .. min(239, vpos)
//      bits = data
//      MOGO rising:   render into buffer[~new FRAME]
//      partial = vpos
//    VBLANK start:
//      if ERASE:      clear buffer[FRAME] over lines max(0, partial+1) .. 239
//      partial = -1
//
//  Both games write the register from their VBLANK handler with the same
//  four-frame table (Hydra $7306, Pit Fighter $64A4):
//      $0000,$0001   $0003,$0003   $0004,$0005   $0007,$0007
//  The first write of the $0000 and $0004 pairs lands in VBLANK just after
//  partial was reset, so it clears the whole old-FRAME buffer, which the MOGO
//  in the next write renders into. The VBLANK-start erase is empty in this
//  sequence (partial >= 240) but is modelled anyway.
//
//  MAME's operations are instant; here each erase request latches its buffer
//  and line range when made (FRAME can flip mid-erase) into a one-deep queue
//  per buffer, where overlapping requests merge. The engine clears one pixel
//  per clock: a full wipe is 80,640 clocks, 1.41 ms. rnd_hold is high while
//  an erase of the render target is queued or running; g1_rle waits for it
//  before drawing each object, so the erase completes first, as in MAME.
//
//  Clock domain: clk_sys
//============================================================================

`default_nettype none

module g1_rle_fb
    import g1_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    // ---- Control register -------------------------------------------------
    input  wire [2:0]   ctrl,          // {FRAME, ERASE, MOGO}
    input  wire         ctrl_wr,       // one clock per write that changes the byte

    // ---- Raster position --------------------------------------------------
    input  wire [8:0]   vpos,          // 0..239 visible, any value >= 240 in VBLANK
    input  wire         vblank_rise,

    // ---- Render write port ------------------------------------------------
    input  wire [8:0]   rnd_x,
    input  wire [7:0]   rnd_y,
    input  wire [9:0]   rnd_index,
    input  wire         rnd_we,

    // ---- Display read port ------------------------------------------------
    input  wire [8:0]   disp_x,
    input  wire [7:0]   disp_y,
    output logic [9:0]  disp_index,

    // ---- Status -----------------------------------------------------------
    output logic        mogo_rise,     // render trigger, one clock
    input  wire         rnd_accept,    // g1_rle took that MOGO as a DRAW
    output logic        rnd_hold,      // erase of the render target pending
    output logic        erase_busy
);

    localparam int FB_WORDS = MO_FB_W * MO_FB_H;   // 80,640
    localparam [7:0] LAST_LINE = 8'(MO_FB_H - 1);  // 239

    //------------------------------------------------------------------------
    // Address: y * 336 + x = y*256 + y*64 + y*16 + x
    //------------------------------------------------------------------------
    function automatic [MO_FB_AW-1:0] fb_addr(input [7:0] y, input [8:0] x);
        fb_addr = {y, 8'd0} + {2'd0, y, 6'd0} + {4'd0, y, 4'd0} + {8'd0, x};
    endfunction

    //------------------------------------------------------------------------
    // Register state
    //------------------------------------------------------------------------
    logic [2:0] bits;          // MAME m_control_bits (low three)
    logic [8:0] part_top;      // max(0, m_partial_scanline + 1)
    logic       rnd_buf;       // buffer the current/last render writes

    wire  frame = bits[2];

    //------------------------------------------------------------------------
    // Erase requests
    //------------------------------------------------------------------------
    // VBLANK start and a register write can request in the same clock. Both
    // use the current FRAME, so they merge into one range; the VBLANK request
    // is evaluated first, as in MAME.
    //------------------------------------------------------------------------
    wire [8:0] wr_bot9 = (vpos > 9'(LAST_LINE)) ? 9'(LAST_LINE) : vpos;
    wire [8:0] top_after_vb = vblank_rise ? 9'd0 : part_top;

    logic       req_v;
    logic [7:0] req_top, req_bot;

    always_comb begin
        req_v   = 1'b0;
        req_top = 8'd0;
        req_bot = 8'd0;
        if (bits[1]) begin
            if (vblank_rise && 9'(LAST_LINE) >= part_top) begin
                req_v   = 1'b1;
                req_top = part_top[7:0];
                req_bot = LAST_LINE;
            end
            if (ctrl_wr && wr_bot9 >= top_after_vb) begin
                if (req_v) begin
                    if (top_after_vb[7:0] < req_top) req_top = top_after_vb[7:0];
                    if (wr_bot9[7:0]     > req_bot) req_bot = wr_bot9[7:0];
                end else begin
                    req_v   = 1'b1;
                    req_top = top_after_vb[7:0];
                    req_bot = wr_bot9[7:0];
                end
            end
        end
    end

    //------------------------------------------------------------------------
    // Queue (one slot per buffer) and engine
    //------------------------------------------------------------------------
    logic [1:0] pend_v;
    logic [7:0] pend_top [2];
    logic [7:0] pend_bot [2];

    logic       erasing, erase_buf;
    logic [7:0] erase_line, erase_end;
    logic [8:0] erase_x;

    assign erase_busy = erasing || (pend_v != 2'b00);
    assign rnd_hold   = (erasing && erase_buf == rnd_buf) || pend_v[rnd_buf];

    // The engine takes a queued request when idle or on the clock its current
    // one finishes, buffer 0 first (the buffers are separate memories, so the
    // order is immaterial).
    wire eng_last = erasing && (erase_x == 9'(MO_FB_W - 1)) && (erase_line >= erase_end);
    wire eng_free = !erasing || eng_last;
    wire take_v   = eng_free && (pend_v != 2'b00);
    wire take_b   = !pend_v[0];

    logic [1:0] pend_v_tk;     // queue state after this clock's take
    always_comb begin
        pend_v_tk = pend_v;
        if (take_v) pend_v_tk[take_b] = 1'b0;
    end

    always_ff @(posedge clk) begin
        mogo_rise <= 1'b0;

        if (!rst_n) begin
            bits     <= 3'b000;
            part_top <= 9'd0;
            rnd_buf  <= 1'b1;
            pend_v   <= 2'b00;
            erasing  <= 1'b0;
            erase_buf  <= 1'b0;
            erase_line <= 8'd0;
            erase_end  <= 8'd0;
            erase_x    <= 9'd0;
        end
        else begin
            //----------------------------------------------------------------
            // Register update
            //----------------------------------------------------------------
            if (ctrl_wr) begin
                bits     <= ctrl;
                part_top <= vpos + 9'd1;
                if (!bits[0] && ctrl[0]) mogo_rise <= 1'b1;
            end
            else if (vblank_rise) begin
                part_top <= 9'd0;
            end

            // Latch the render target when g1_rle starts a DRAW (the clock
            // after mogo_rise, when bits holds the new FRAME). A MOGO it
            // ignores (busy, NOP, CHECKSUM) leaves a running render's target.
            if (rnd_accept) rnd_buf <= ~bits[2];

            //----------------------------------------------------------------
            // Engine stepping
            //----------------------------------------------------------------
            if (erasing) begin
                if (erase_x == 9'(MO_FB_W - 1)) begin
                    erase_x <= 9'd0;
                    if (erase_line >= erase_end) erasing <= 1'b0;
                    else                         erase_line <= erase_line + 1'b1;
                end else begin
                    erase_x <= erase_x + 1'b1;
                end
            end

            //----------------------------------------------------------------
            // Queue: take, then insert (pend_v_tk), so a request arriving as
            // its slot is taken starts a fresh slot rather than merging.
            //----------------------------------------------------------------
            if (take_v) begin
                erasing    <= 1'b1;
                erase_buf  <= take_b;
                erase_line <= pend_top[take_b];
                erase_end  <= pend_bot[take_b];
                erase_x    <= 9'd0;
            end
            if (req_v) begin
                if (pend_v_tk[frame]) begin
                    if (req_top < pend_top[frame]) pend_top[frame] <= req_top;
                    if (req_bot > pend_bot[frame]) pend_bot[frame] <= req_bot;
                end else begin
                    pend_top[frame] <= req_top;
                    pend_bot[frame] <= req_bot;
                end
            end
            pend_v <= pend_v_tk | (req_v ? (frame ? 2'b10 : 2'b01) : 2'b00);
        end
    end

    //------------------------------------------------------------------------
    // The two buffers
    //------------------------------------------------------------------------
    // Separate arrays, each with its own write port: driven by the erase
    // engine while it erases that buffer, otherwise by the renderer if it is
    // the render target. rnd_hold keeps the two off the same buffer.
    //------------------------------------------------------------------------
    logic [9:0] fb0 [FB_WORDS];
    logic [9:0] fb1 [FB_WORDS];

    wire [MO_FB_AW-1:0] a_disp  = fb_addr(disp_y,     disp_x);
    wire [MO_FB_AW-1:0] a_rnd   = fb_addr(rnd_y,      rnd_x);
    wire [MO_FB_AW-1:0] a_erase = fb_addr(erase_line, erase_x);

    wire er0 = erasing && (erase_buf == 1'b0);
    wire er1 = erasing && (erase_buf == 1'b1);

    // Write port registered for timing: each buffer spans ~79 M10K across the
    // die, and address arithmetic, erase/render select and block write decode
    // would otherwise be one path. The extra clock is harmless: the display
    // never reads the buffer being written, and rnd_hold drops long before
    // the renderer's next write.
    logic [MO_FB_AW-1:0] fb0_waddr, fb1_waddr;
    logic [9:0]          fb0_wdata, fb1_wdata;
    logic                fb0_we,    fb1_we;

    always_ff @(posedge clk) begin
        fb0_waddr <= er0 ? a_erase : a_rnd;
        fb0_wdata <= er0 ? 10'd0   : rnd_index;
        fb0_we    <= er0 || (rnd_we && rnd_buf == 1'b0);

        fb1_waddr <= er1 ? a_erase : a_rnd;
        fb1_wdata <= er1 ? 10'd0   : rnd_index;
        fb1_we    <= er1 || (rnd_we && rnd_buf == 1'b1);
    end

    logic [9:0] fb0_q, fb1_q;
    logic       disp_sel;

    always_ff @(posedge clk) begin
        if (fb0_we) fb0[fb0_waddr] <= fb0_wdata;
        fb0_q <= fb0[a_disp];
    end

    always_ff @(posedge clk) begin
        if (fb1_we) fb1[fb1_waddr] <= fb1_wdata;
        fb1_q <= fb1[a_disp];
    end

    // Registered alongside the BRAM read so the select matches the data.
    always_ff @(posedge clk) disp_sel <= frame;

    // One clock of BRAM latency; the mixer's own register absorbs it.
    assign disp_index = disp_sel ? fb1_q : fb0_q;

`ifdef SIMULATION
    // synthesis translate_off
    // A render pixel to a buffer being erased is dropped (the erase owns the
    // port). rnd_hold should prevent this.
    always_ff @(posedge clk) begin
        if (rst_n && rnd_we && erasing && erase_buf == rnd_buf)
            $display("%t g1_rle_fb: render pixel dropped during erase of buffer %0d",
                     $time, rnd_buf);
    end
    // synthesis translate_on
`endif

endmodule

`default_nettype wire
