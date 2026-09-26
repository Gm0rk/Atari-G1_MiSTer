//============================================================================
//  Atari G1 for MiSTer
//  g1_rle_render.sv -- RLE row walker and Bresenham resampler
//
//  Draws one object set up by g1_rle_scaler: walks its compressed rows in
//  SDRAM and writes one destination pixel per clock to g1_rle_fb. Port of
//  the inner loop of MAME draw_rle_zoom():
//
//      sourcex = dx / 2                  // sample at pixel centres
//      rle_end = 0
//      for each packet byte:
//          (value, run) = decode(byte)
//          rle_end += run << 16
//          while sourcex < rle_end:
//              if value: fb[dest] = PAL_BASE_MO + color*16 + value
//              dest += 1                 // -1 when hflipped
//              sourcex += dx
//
//  Rows are variable length (a count word, then that many packet words) with
//  no row index, so reaching source row N means walking N row headers.
//  Downscaling still reads the header of every skipped row, and upscaling
//  replays a row from row_start_ptr for each destination row mapped to it.
//
//  SDRAM is shared with the 68000, the 6502 and the tile fetchers. Three
//  measures cut the renderer's traffic without changing any output pixel:
//    - Row cache: the first read of a source row copies it into a 256-word
//      buffer that replays then read. Pit Fighter draws fighters at 2x-4x.
//    - Destination rows above the screen only advance the Bresenham state;
//      the object ends at the first row below it.
//    - An object wholly outside the clip window is not drawn. A 4-pixel
//      margin covers rounding between the scaled width and emitted pixels.
//
//  Clock domain: clk_sys
//============================================================================

`default_nettype none

module g1_rle_render
    import g1_pkg::*;
(
    input  wire                clk,
    input  wire                rst_n,

    // ---- Object to draw ---------------------------------------------------
    input  wire                start,
    input  wire [23:0]         data_ptr,   // word offset of the object's data
    input  wire [2:0]          mode,       // encoding mode
    input  wire [3:0]          color,
    input  wire                hflip,
    input  wire signed [15:0]  sx,         // destination origin
    input  wire signed [15:0]  sy,
    input  wire [15:0]         sw,         // scaled width
    input  wire [15:0]         sh,         // scaled height
    input  wire [25:0]         dx,         // 16.16 source step per dest pixel
    input  wire [25:0]         dy,

    // ---- Clip window (MRA config) ------------------------------------------
    // Hydra 0..255, Pit Fighter 40..295: 256 wide within the 336-pixel screen.
    input  wire [8:0]          clip_left,
    input  wire [8:0]          clip_right,

    // ---- SDRAM read port --------------------------------------------------
    output logic [24:0]        rom_addr,
    output logic               rom_req,
    input  wire [15:0]         rom_dout,
    input  wire                rom_ack,

    // ---- Framebuffer write port -------------------------------------------
    output logic [8:0]         fb_x,
    output logic [7:0]         fb_y,
    output logic [9:0]         fb_index,
    output logic               fb_we,

    output logic               busy,
    output logic               done
);

    //------------------------------------------------------------------------
    // Packet decoder (combinational)
    //------------------------------------------------------------------------
    logic [7:0] pkt;
    wire  [5:0] pkt_value;
    wire  [4:0] pkt_run;

    g1_rle_decode u_decode (
        .mode        (mode),
        .packet      (pkt),
        .value       (pkt_value),
        .run         (pkt_run),
        .transparent ()
    );

    //------------------------------------------------------------------------
    // Walk state
    //------------------------------------------------------------------------
    logic [23:0] ptr;             // current word pointer
    logic [23:0] row_start_ptr;   // start of the current source row
    logic [15:0] cur_src_row;     // source row the pointer is sitting on
    logic [15:0] rows_left;       // destination rows still to draw

    logic [31:0] sourcey;         // 16.16 position in the source
    logic [31:0] sourcex;
    logic [31:0] rle_end;

    logic signed [15:0] dest_y;
    logic signed [15:0] dest_x;

    logic [7:0]  entries_left;
    logic [15:0] pkt_word;
    logic        second_byte;     // low byte first, then high

    wire [15:0] target_row = sourcey[31:16];


    // Vertical clip. Redundant with R_SEEK, which never decodes a row above
    // the screen and ends the object at the first row below it.
    wire dest_y_visible = (dest_y >= 0) && (dest_y < MO_FB_H);

    // Horizontal clip against the per-game window.
    wire dest_x_visible = (dest_x >= $signed({7'd0, clip_left}))
                       && (dest_x <= $signed({7'd0, clip_right}));

    wire [24:0] rom_byte_addr = SDR_RLE + {ptr, 1'b0};

    //------------------------------------------------------------------------
    // FSM
    //------------------------------------------------------------------------
    typedef enum logic [3:0] {
        R_IDLE,
        R_SEEK,                        // decide whether to skip rows
        R_SKIP_REQ,  R_SKIP_WAIT,      // skip one source row
        R_ROW_REQ,   R_ROW_WAIT,       // read the current row's count
        R_PKT_REQ,   R_PKT_WAIT,       // read a packet word
        R_EMIT,                        // one pixel per clock
        R_ROW_END,
        R_DONE
    } rstate_t;

    rstate_t state;

    assign busy = (state != R_IDLE);

    //------------------------------------------------------------------------
    // Row cache: header at index 0, packet words at 1..entries. Filled on the
    // first read of a source row, read on replays of it.
    //------------------------------------------------------------------------
    logic [15:0] rowbuf [256];
    logic [15:0] rc_q;
    logic        row_cached;     // rowbuf holds the whole row at row_start_ptr
    logic        use_cache;      // this row's words come from rowbuf
    wire  [7:0]  rc_idx = 8'(ptr - row_start_ptr);

    always_ff @(posedge clk) begin
        rc_q <= rowbuf[rc_idx];
        if (rom_ack && !use_cache && (state == R_ROW_WAIT || state == R_PKT_WAIT))
            rowbuf[rc_idx] <= rom_dout;
    end

    // One word from the cache or SDRAM. The cache answers the clock after the
    // REQ state; rc_idx is stable until the WAIT state consumes the word.
    wire        word_ok   = use_cache ? 1'b1 : rom_ack;
    wire [15:0] word_data = use_cache ? rc_q : rom_dout;

    // Whole-object reject against the clip window, 4-pixel margin.
    wire signed [17:0] obj_x0 = $signed({{2{sx[15]}}, sx}) - 18'sd4;
    wire signed [17:0] obj_x1 = $signed({{2{sx[15]}}, sx}) + $signed({2'b00, sw}) + 18'sd4;
    wire obj_outside = (obj_x1 < $signed({9'd0, clip_left}))
                    || (obj_x0 > $signed({9'd0, clip_right}));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state   <= R_IDLE;
            rom_req <= 1'b0;
            fb_we   <= 1'b0;
            done    <= 1'b0;
        end
        else begin
            fb_we <= 1'b0;
            done  <= 1'b0;

            case (state)

            R_IDLE:
                if (start) begin
                    ptr           <= data_ptr;
                    row_start_ptr <= data_ptr;
                    cur_src_row   <= 16'd0;
                    rows_left     <= sh;
                    // Half-step: sample at pixel centres, not edges. Without
                    // it, objects shift half a pixel and wobble while scaling.
                    sourcey       <= {6'd0, dy} >> 1;
                    dest_y        <= sy;
                    row_cached    <= 1'b0;
                    use_cache     <= 1'b0;
                    state         <= R_SEEK;
                end

            //---- Advance to the source row this destination row needs ----
            R_SEEK: begin
                if (rows_left == 16'd0 || dest_y >= $signed(16'(MO_FB_H)) || obj_outside) begin
                    // Out of rows, below the screen (rows only move down), or
                    // nowhere near the clip window.
                    state <= R_DONE;
                end
                else if (dest_y < 0) begin
                    // Above the screen: only the Bresenham state moves. The
                    // source rows passed over are walked when a visible row
                    // needs them.
                    dest_y    <= dest_y + 16'sd1;
                    sourcey   <= sourcey + {6'd0, dy};
                    rows_left <= rows_left - 1'b1;
                end
                else if (cur_src_row == target_row) begin
                    // Already on the source row (upscaling): replay it from
                    // its start, from the row cache if it holds the row.
                    ptr       <= row_start_ptr;
                    use_cache <= row_cached;
                    state     <= R_ROW_REQ;
                end
                else begin
                    state <= R_SKIP_REQ;
                end
            end

            R_SKIP_REQ: begin
                rom_addr <= rom_byte_addr;
                rom_req  <= 1'b1;
                state    <= R_SKIP_WAIT;
            end

            R_SKIP_WAIT:
                if (rom_ack) begin
                    rom_req <= 1'b0;
                    if (rom_dout == RLE_ROW_TERMINATOR || rom_dout == 16'd0) begin
                        // End of object. Legal: at the margins the scaled
                        // height can map past the last real row.
                        state <= R_DONE;
                    end else begin
                        // Skip the header and its packet words. The cache
                        // holds the row just left, not the new one.
                        ptr           <= ptr + 1 + {16'd0, rom_dout[7:0]};
                        row_start_ptr <= ptr + 1 + {16'd0, rom_dout[7:0]};
                        cur_src_row   <= cur_src_row + 1'b1;
                        row_cached    <= 1'b0;
                        state         <= R_SEEK;
                    end
                end

            //---- Start of a destination row ------------------------------
            // Entered only with ptr == row_start_ptr (a replay, or after the
            // skip walk set both), so the header is cache index 0.
            R_ROW_REQ: begin
                row_start_ptr <= ptr;
                rom_addr      <= rom_byte_addr;
                rom_req       <= !use_cache;
                state         <= R_ROW_WAIT;
            end

            R_ROW_WAIT:
                if (word_ok) begin
                    rom_req <= 1'b0;
                    if (word_data == RLE_ROW_TERMINATOR || word_data == 16'd0) begin
                        state <= R_DONE;
                    end else begin
                        entries_left <= word_data[7:0];
                        ptr          <= ptr + 1'b1;
                        sourcex      <= {6'd0, dx} >> 1;
                        rle_end      <= 32'd0;
                        // hflip walks the destination backwards from the
                        // right edge of the scaled object.
                        dest_x       <= hflip ? (sx + $signed(sw) - 16'sd1) : sx;
                        state        <= R_PKT_REQ;
                    end
                end

            //---- Packet words: two RLE bytes each, low byte first --------
            R_PKT_REQ: begin
                if (entries_left == 8'd0) begin
                    state <= R_ROW_END;
                end else begin
                    rom_addr <= rom_byte_addr;
                    rom_req  <= !use_cache;
                    state    <= R_PKT_WAIT;
                end
            end

            R_PKT_WAIT:
                if (word_ok) begin
                    rom_req      <= 1'b0;
                    pkt_word     <= word_data;
                    ptr          <= ptr + 1'b1;
                    entries_left <= entries_left - 1'b1;
                    pkt          <= word_data[7:0];     // low byte first
                    second_byte  <= 1'b0;
                    rle_end      <= rle_end + ({27'd0, pkt_run_of(word_data[7:0])} << 16);
                    state        <= R_EMIT;
                end

            //---- Emit: one destination pixel per clock -------------------
            R_EMIT: begin
                if (sourcex < rle_end) begin
                    // Transparent runs still advance the destination; they
                    // just do not write.
                    if (pkt_value != 6'd0 && dest_y_visible && dest_x_visible) begin
                        fb_x     <= dest_x[8:0];
                        fb_y     <= dest_y[7:0];
                        // 10-bit palette index: a 6bpp object reaches $32F.
                        fb_index <= PAL_BASE_MO + {color, 4'd0} + {4'd0, pkt_value};
                        fb_we    <= 1'b1;
                    end
                    dest_x  <= hflip ? (dest_x - 16'sd1) : (dest_x + 16'sd1);
                    sourcex <= sourcex + {6'd0, dx};
                end
                else if (!second_byte) begin
                    // Move on to the high byte of the same word.
                    pkt         <= pkt_word[15:8];
                    second_byte <= 1'b1;
                    rle_end     <= rle_end + ({27'd0, pkt_run_of(pkt_word[15:8])} << 16);
                end
                else begin
                    state <= R_PKT_REQ;
                end
            end

            //---- End of destination row ----------------------------------
            R_ROW_END: begin
                // Rewind for a possible replay. Every packet of the row has
                // been read by now, so the cache holds it.
                ptr        <= row_start_ptr;
                row_cached <= 1'b1;
                use_cache  <= 1'b0;
                dest_y    <= dest_y + 16'sd1;
                sourcey   <= sourcey + {6'd0, dy};
                rows_left <= rows_left - 1'b1;
                state     <= R_SEEK;
            end

            R_DONE: begin
                done  <= 1'b1;
                state <= R_IDLE;
            end

            default: state <= R_IDLE;
            endcase
        end
    end

    //------------------------------------------------------------------------
    // Run length of a packet byte (same as g1_rle_decode), needed for both
    // bytes in the clock the packet word arrives.
    //------------------------------------------------------------------------
    function automatic [4:0] pkt_run_of(input [7:0] b);
        logic [2:0] bpp; logic sp;
        begin
            bpp = rle_mode_bpp(mode);
            sp  = rle_mode_special(mode);
            if ((sp && b[3:0] == 4'h0) || bpp == 3'd4) pkt_run_of = {1'b0, b[7:4]} + 5'd1;
            else if (bpp == 3'd5)                      pkt_run_of = {2'd0, b[7:5]} + 5'd1;
            else                                       pkt_run_of = {3'd0, b[7:6]} + 5'd1;
        end
    endfunction

`ifdef SIMULATION
    // synthesis translate_off
    // Stop on an object that never terminates (runaway pointer arithmetic).
    int guard;
    always_ff @(posedge clk) begin
        if (busy) begin
            guard <= guard + 1;
            if (guard > 4_000_000)
                $fatal(1, "g1_rle_render: object did not terminate");
        end else guard <= 0;
    end
    // synthesis translate_on
`endif

endmodule

`default_nettype wire
