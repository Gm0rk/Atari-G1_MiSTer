//============================================================================
//  Atari G1 for MiSTer
//  g1_rle.sv -- motion object engine ("growth renderer") top level
//
//  Port of MAME atarirle.cpp as configured by atarig1.cpp:
//
//      g1_rle_prescan    load-time size/offset table, indexed by object code
//      g1_rle_objram     descriptor snapshot and field extraction
//      g1_rle_sort       256-bucket priority ordering
//      g1_rle_scaler     per-object origin, scaled size and step arithmetic
//      g1_rle_render     row walker and Bresenham resampler
//      g1_rle_fb         double framebuffer and erase engine
//      g1_rle_checksum   ROM checksums for Pit Fighter's self-test
//
//  Control is $FA0001 (byte): bit 0 MOGO, bit 1 ERASE, bit 2 FRAME. Each
//  write to $FF2000 (a work RAM word, snooped) latches the command as MAME
//  mo_command_w does: CHECKSUM if 0 on Pit Fighter, else DRAW; NOP until the
//  first write. A MOGO rising edge executes it. DRAW snapshots object RAM,
//  builds the order buckets, then per object reads the descriptor, looks up
//  the prescan entry by code, scales and renders.
//
//  The framebuffer is double buffered, so a render has a whole frame (about
//  956,000 clocks), not just VBLANK. The 80,640-pixel screen at 4x overdraw
//  takes about a third of that at one pixel per clock; heavy downscaling makes
//  row walking the dominant cost (see g1_rle_render).
//
//  Clock domain: clk_sys
//============================================================================

`default_nettype none

module g1_rle
    import g1_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    // ---- Configuration ----------------------------------------------------
    input  wire         is_pitfight,
    input  wire [10:0]  obj_count,     // ROM objects: 768 Hydra, 1312 Pit Fighter
    input  wire [8:0]   clip_left,     // MO clip window, screen X
    input  wire [8:0]   clip_right,

    // ---- Registers written by the 68000 -----------------------------------
    input  wire [2:0]   ctrl,          // $FA0001 bits 2:0
    input  wire         ctrl_wr,       // one clock per write that changes the byte
    input  wire [15:0]  cmd,           // $FF2000, snooped from work RAM writes
    input  wire         cmd_wr,        // high while cmd is being written
    input  wire [15:0]  objram_word0,  // work RAM word 0: CHECKSUM count - 1

    // ---- Raster ------------------------------------------------------------
    input  wire [8:0]   vpos,          // raster line; >= 240 in VBLANK
    input  wire         vblank_rise,

    // ---- Work RAM port (read for the snapshot, write for CHECKSUM) --------
    output logic [14:0] vram_addr,
    output logic        vram_req,
    input  wire [15:0]  vram_dout,
    input  wire         vram_ack,
    output logic [15:0] vram_din,
    output logic        vram_we,

    // ---- SDRAM port (RLE object ROM) --------------------------------------
    output logic [24:0] rom_addr,
    output logic        rom_req,
    input  wire [15:0]  rom_dout,
    input  wire         rom_ack,

    // ---- ROM loader snoop, for checksum accumulation ----------------------
    input  wire         load_active,    // ROM (index 0) download in progress
    input  wire         load_rst_n,     // reset for the checksum accumulator
    input  wire [24:0]  load_addr,
    input  wire [15:0]  load_data,
    input  wire         load_we,
    input  wire         load_complete,  // pulse: start the prescan

    // ---- Framebuffer display read -----------------------------------------
    input  wire [8:0]   disp_x,
    input  wire [7:0]   disp_y,
    output logic [9:0]  disp_index,

    // ---- Status ------------------------------------------------------------
    output logic        prescan_busy,
    output logic        render_busy,
    output logic [10:0] stat_valid,
    output logic [10:0] stat_null,
    output logic [9:0]  stat_max_w,
    output logic [7:0]  stat_max_h
);

    //========================================================================
    //  Command decode
    //========================================================================
    // MAME: m_rle->command_write((data == 0 && m_is_pitfight) ? CHECKSUM : DRAW)
    localparam [1:0] CMD_NOP = 2'd0, CMD_DRAW = 2'd1, CMD_CKSUM = 2'd2;

    logic [1:0] decoded_cmd;
    always_ff @(posedge clk) begin
        if (!rst_n)      decoded_cmd <= CMD_NOP;
        else if (cmd_wr) decoded_cmd <= (cmd == 16'd0 && is_pitfight) ? CMD_CKSUM
                                                                      : CMD_DRAW;
    end

    //========================================================================
    //  Framebuffer
    //========================================================================
    wire        mogo_rise, erase_busy, rnd_hold;
    logic       draw_accept;     // assigned with the sequencer below
    wire [8:0]  rnd_x;
    wire [7:0]  rnd_y;
    wire [9:0]  rnd_index;
    wire        rnd_we;

    g1_rle_fb u_fb (
        .clk         (clk),
        .rst_n       (rst_n),
        .ctrl        (ctrl),
        .ctrl_wr     (ctrl_wr),
        .vpos        (vpos),
        .vblank_rise (vblank_rise),
        .rnd_x       (rnd_x),
        .rnd_y       (rnd_y),
        .rnd_index   (rnd_index),
        .rnd_we      (rnd_we),
        .disp_x      (disp_x),
        .disp_y      (disp_y),
        .disp_index  (disp_index),
        .mogo_rise   (mogo_rise),
        .rnd_accept  (draw_accept),
        .rnd_hold    (rnd_hold),
        .erase_busy  (erase_busy)
    );

    //========================================================================
    //  Prescan
    //========================================================================
    wire [10:0] ps_index;
    wire [9:0]  ps_width;
    wire [7:0]  ps_height;
    wire [2:0]  ps_mode;
    wire [23:0] ps_dataoff;
    wire signed [15:0] ps_xoffs, ps_yoffs;
    wire        ps_valid;
    wire [24:0] ps_rom_addr;
    wire        ps_rom_req;
    logic       ps_rom_ack;
    wire        ps_done;

    logic [10:0] desc_obj;    // object currently being set up

    // Descriptor fields from g1_rle_objram.
    wire [14:0]  obj_code;
    wire         obj_hflip;
    wire [3:0]   obj_color;
    wire signed [15:0] obj_xpos, obj_ypos;
    wire [15:0]  obj_scale;
    wire [7:0]   obj_order;

    g1_rle_prescan u_prescan (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (load_complete),
        .obj_count  (obj_count),
        .busy       (prescan_busy),
        .done       (ps_done),
        .rom_addr   (ps_rom_addr),
        .rom_req    (ps_rom_req),
        .rom_dout   (rom_dout),
        .rom_ack    (ps_rom_ack),
        // Indexed by the object's code, not its slot (MAME: m_info[code]).
        // Codes >= obj_count are skipped in E_FETCH_W, so the truncation to
        // 11 bits cannot alias a valid entry.
        .q_index    (obj_code[10:0]),
        .q_width    (ps_width),
        .q_height   (ps_height),
        .q_mode     (ps_mode),
        .q_dataoff  (ps_dataoff),
        .q_xoffs    (ps_xoffs),
        .q_yoffs    (ps_yoffs),
        .q_valid    (ps_valid),
        .stat_valid (stat_valid),
        .stat_null  (stat_null),
        .stat_max_w (stat_max_w),
        .stat_max_h (stat_max_h)
    );

    assign ps_index = obj_code[10:0];

    //========================================================================
    //  Descriptor snapshot
    //========================================================================
    logic        snap_start;
    wire         snap_busy;
    wire [14:0]  or_vaddr;
    wire         or_vreq;
    logic        or_vack;

    wire [7:0]   sort_desc_index;
    wire         sort_desc_sel;

    // The sort owns the descriptor port during its build phase; afterwards the
    // render sequencer drives it.
    wire [7:0] desc_index = sort_desc_sel ? sort_desc_index : desc_obj[7:0];

    g1_rle_objram u_objram (
        .clk         (clk),
        .rst_n       (rst_n),
        .snap_start  (snap_start),
        .snap_busy   (snap_busy),
        .vram_addr   (or_vaddr),
        .vram_req    (or_vreq),
        .vram_dout   (vram_dout),
        .vram_ack    (or_vack),
        .is_pitfight (is_pitfight),
        .obj_index   (desc_index),
        .obj_code    (obj_code),
        .obj_hflip   (obj_hflip),
        .obj_color   (obj_color),
        .obj_xpos    (obj_xpos),
        .obj_ypos    (obj_ypos),
        .obj_scale   (obj_scale),
        .obj_order   (obj_order)
    );

    //========================================================================
    //  Sort
    //========================================================================
    logic        sort_build;
    logic        walk_next;
    wire [10:0]  walk_obj;
    wire         walk_valid, walk_done, sort_busy;

    g1_rle_sort u_sort (
        .clk         (clk),
        .rst_n       (rst_n),
        .build_start (sort_build),
        .obj_count   (obj_count),
        .desc_index  (sort_desc_index),
        .desc_sel    (sort_desc_sel),
        .desc_order  (obj_order),
        .walk_next   (walk_next),
        .walk_obj    (walk_obj),
        .walk_valid  (walk_valid),
        .walk_done   (walk_done),
        .busy        (sort_busy)
    );

    //========================================================================
    //  Scaler
    //========================================================================
    logic        scale_start;
    wire signed [15:0] sc_sx, sc_sy;
    wire [15:0]  sc_sw, sc_sh;
    wire [25:0]  sc_dx, sc_dy;
    wire         sc_skip, sc_done, sc_busy;

    // Hotspot offsets come from the ROM object header, held in the prescan
    // table, not from the descriptor.
    wire signed [15:0] hdr_xoffs = ps_xoffs;
    wire signed [15:0] hdr_yoffs = ps_yoffs;

    // MAME sort_and_render: x += m_cliprect.left(). Descriptor X is relative
    // to the clip window (left edge 40 on Pit Fighter, 0 on Hydra); the
    // framebuffer is in screen coordinates.
    wire signed [15:0] obj_xpos_clip = obj_xpos + $signed({7'd0, clip_left});

    g1_rle_scaler u_scaler (
        .clk    (clk),
        .rst_n  (rst_n),
        .start  (scale_start),
        .scale  (obj_scale),
        .width  (ps_width),
        .height (ps_height),
        .xoffs  (hdr_xoffs),
        .yoffs  (hdr_yoffs),
        .xpos   (obj_xpos_clip),
        .ypos   (obj_ypos),
        .hflip  (obj_hflip),
        .sx     (sc_sx),
        .sy     (sc_sy),
        .sw     (sc_sw),
        .sh     (sc_sh),
        .dx     (sc_dx),
        .dy     (sc_dy),
        .skip   (sc_skip),
        .done   (sc_done),
        .busy   (sc_busy)
    );

    //========================================================================
    //  Renderer
    //========================================================================
    logic        rnd_start;
    wire [24:0]  rnd_rom_addr;
    wire         rnd_rom_req;
    logic        rnd_rom_ack;
    wire         rnd_busy, rnd_done;

    g1_rle_render u_render (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (rnd_start),
        .data_ptr   (ps_dataoff),
        .mode       (ps_mode),
        .color      (obj_color),
        .hflip      (obj_hflip),
        .sx         (sc_sx),
        .sy         (sc_sy),
        .sw         (sc_sw),
        .sh         (sc_sh),
        .dx         (sc_dx),
        .dy         (sc_dy),
        .clip_left  (clip_left),
        .clip_right (clip_right),
        .rom_addr   (rnd_rom_addr),
        .rom_req    (rnd_rom_req),
        .rom_dout   (rom_dout),
        .rom_ack    (rnd_rom_ack),
        .fb_x       (rnd_x),
        .fb_y       (rnd_y),
        .fb_index   (rnd_index),
        .fb_we      (rnd_we),
        .busy       (rnd_busy),
        .done       (rnd_done)
    );

    //========================================================================
    //  Checksum
    //========================================================================
    logic       cksum_start;
    wire [14:0] ck_addr;
    wire [15:0] ck_data;
    wire        ck_we, ck_busy, ck_done;

    g1_rle_checksum u_cksum (
        .clk          (clk),
        .rst_n        (rst_n),
        .acc_rst_n    (load_rst_n),
        .load_active  (load_active),
        .load_addr    (load_addr),
        .load_data    (load_data),
        .load_we      (load_we),
        .q_index      (8'd0),
        .q_sum        (),
        .cksum_start  (cksum_start),
        .objram_word0 (objram_word0),
        .wr_addr      (ck_addr),
        .wr_data      (ck_data),
        .wr_en        (ck_we),
        .busy         (ck_busy),
        .done         (ck_done)
    );

    //========================================================================
    //  Port muxing
    //========================================================================
    // SDRAM: the prescan owns it after the ROM load, the renderer afterwards.
    // They are never active at the same time.
    always_comb begin
        if (prescan_busy) begin
            rom_addr = ps_rom_addr;
            rom_req  = ps_rom_req;
        end else begin
            rom_addr = rnd_rom_addr;
            rom_req  = rnd_rom_req;
        end
    end
    assign ps_rom_ack  = rom_ack &&  prescan_busy;
    assign rnd_rom_ack = rom_ack && !prescan_busy;

    // Work RAM: the snapshot reads, the checksum writes.
    always_comb begin
        vram_addr = ck_we ? ck_addr : or_vaddr;
        vram_req  = or_vreq;
        vram_din  = ck_data;
        vram_we   = ck_we;
    end
    assign or_vack = vram_ack;

    //========================================================================
    //  Render sequencer
    //========================================================================
    // Sort handshake: take walk_obj while walk_valid is high, pulse walk_next
    // when finished with it, then spend one clock in E_GAP so the sort has
    // dropped walk_valid before E_SORT tests it again (otherwise the object
    // just drawn is fetched twice). walk_done is a level held until the next
    // build, so E_SORT cannot miss it.
    typedef enum logic [3:0] {
        E_IDLE, E_SNAP, E_SORT, E_FETCH, E_FETCH_W,
        E_SCALE, E_SCALE_W, E_RENDER, E_RENDER_W, E_NEXT, E_CKSUM,
        E_GAP, E_HOLD
    } estate_t;

    estate_t estate;
    logic [1:0] fetch_lat;

    assign render_busy = (estate != E_IDLE);

    // High on the clock E_IDLE accepts a MOGO as a DRAW; g1_rle_fb latches
    // the render buffer on it.
    assign draw_accept = (estate == E_IDLE) && mogo_rise && !prescan_busy
                      && (decoded_cmd == CMD_DRAW);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            estate      <= E_IDLE;
            snap_start  <= 1'b0;
            sort_build  <= 1'b0;
            scale_start <= 1'b0;
            rnd_start   <= 1'b0;
            walk_next   <= 1'b0;
            cksum_start <= 1'b0;
        end
        else begin
            snap_start  <= 1'b0;
            sort_build  <= 1'b0;
            scale_start <= 1'b0;
            rnd_start   <= 1'b0;
            walk_next   <= 1'b0;
            cksum_start <= 1'b0;

            case (estate)

            E_IDLE:
                if (mogo_rise && !prescan_busy) begin
                    case (decoded_cmd)
                        CMD_DRAW: begin
                            snap_start <= 1'b1;
                            estate     <= E_SNAP;
                        end
                        CMD_CKSUM: begin
                            cksum_start <= 1'b1;
                            estate      <= E_CKSUM;
                        end
                        default: ;   // NOP
                    endcase
                end

            // The sort sees sort_build during E_GAP and clears the previous
            // frame's walk_done, so E_SORT never sees a stale one.
            E_SNAP:
                if (!snap_busy && !snap_start) begin
                    sort_build <= 1'b1;
                    estate     <= E_GAP;
                end

            E_GAP: estate <= E_SORT;

            E_SORT:
                if (walk_valid) begin
                    desc_obj  <= walk_obj;
                    fetch_lat <= 2'd0;
                    estate    <= E_FETCH;
                end
                else if (walk_done) begin
                    estate <= E_IDLE;
                end

            // Three clocks: obj_code is valid two clocks after desc_obj, the
            // prescan entry one clock after that.
            E_FETCH: begin
                if (fetch_lat == 2'd2) estate <= E_FETCH_W;
                else                   fetch_lat <= fetch_lat + 1'b1;
            end

            E_FETCH_W: begin
                // Skip null objects and out-of-range codes
                // (MAME: if (code >= count) continue).
                if (!ps_valid || obj_code >= obj_count) begin
                    estate <= E_NEXT;
                end else begin
                    scale_start <= 1'b1;
                    estate      <= E_SCALE;
                end
            end

            E_SCALE: estate <= E_SCALE_W;

            E_SCALE_W:
                if (sc_done) begin
                    if (sc_skip) begin
                        estate <= E_NEXT;
                    end else begin
                        estate <= E_HOLD;
                    end
                end

            // Wait out any queued or running erase of the render buffer, so
            // it completes before this object draws, as in MAME (g1_rle_fb).
            E_HOLD:
                if (!rnd_hold) begin
                    rnd_start <= 1'b1;
                    estate    <= E_RENDER;
                end

            E_RENDER: estate <= E_RENDER_W;

            E_RENDER_W:
                if (rnd_done) estate <= E_NEXT;

            E_NEXT: begin
                walk_next <= 1'b1;
                estate    <= E_GAP;
            end

            E_CKSUM:
                if (ck_done) estate <= E_IDLE;

            default: estate <= E_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
