//============================================================================
//  Atari G1 for MiSTer
//  g1_video.sv -- video subsystem: timing, layers, port arbitration, mixing
//
//  Owns the raster timebase and runs the per-line fetch engines against it.
//  Arbitrates the two resources they share:
//    - the work RAM video port (scroll words, alpha map, playfield map)
//    - SDRAM channel 2         (alpha character ROM, playfield tile ROM)
//
//  Each line is fetched one line ahead into ping-pong line buffers, so the
//  fetchers are decoupled from the dot clock. At each line start:
//    1. g1_scroll reads line N+1's two control words from alpha RAM
//       (columns 48/49).
//    2. g1_playfield (43 tiles) and g1_alpha (42 tiles) then fetch
//       concurrently. The playfield uses the new scroll values, so it must
//       start after step 1 or the image shears by one line.
//
//  Budget: a line is 456 dots = 3648 clk_sys. The fetch needs 213 SDRAM words
//  (43 x 3 + 42 x 2) and 85 work RAM reads; each SDRAM word is a full arbiter
//  round trip shared with the 68000, 6502, OKI and sprite engine. Running the
//  layers concurrently overlaps one's map reads and line-buffer stores with
//  the other's SDRAM reads: about 1,900 clocks on an idle bus, 3,200 with
//  every other channel busy. A serial fetch overruns the line under load.
//
//  Clock domain: clk_sys.
//============================================================================

`default_nettype none

module g1_video
    import g1_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         ce_pix,

    // ---- Configuration ----------------------------------------------------
    input  wire [7:0]   pf_xoffset,   // playfield X scroll bias: 0 Hydra, 2 Pit Fighter
    input  wire         mo_enable,    // motion object layer enable

    // ---- Work RAM video port (to g1_mainram via g1_top) -------------------
    output logic [14:0] vram_addr,       // read address (port B)
    input  wire [15:0]  vram_dout,
    output logic [14:0] vram_din_addr,   // write address (shares port A)
    output logic [15:0] vram_din,
    output logic        vram_we,

    // ---- External work RAM requester (the RLE engine) ---------------------
    // Object RAM snapshot reads and the CHECKSUM write-back. Lowest read
    // priority: the snapshot is a 2048-word burst with a frame of slack,
    // while the tile fetchers must finish within a line. Writes bypass the
    // arbiter (vram_din_addr/vram_din/vram_we).
    input  wire [14:0]  ext_vram_addr,
    input  wire         ext_vram_req,
    output logic        ext_vram_ack,
    input  wire [15:0]  ext_vram_din,
    input  wire         ext_vram_we,

    // ---- SDRAM tile port (to g1_sdram_arb channel 2) ----------------------
    output logic [24:0] tile_rom_addr,

    // Debug: per-fetcher tile acks and busy flags (tell starvation from a
    // hung fetcher), and g1_alpha's map-word probes.
    output logic        dbg_al_ack,
    output logic        dbg_pf_ack,
    output logic        dbg_al_busy,
    output logic        dbg_pf_busy,
    output logic        dbg_map_nz,
    output logic [15:0] dbg_map_word,
    output logic        tile_rom_req,
    input  wire         tile_rom_gnt,   // arbiter took the presented request
    input  wire [15:0]  tile_rom_dout,
    input  wire         tile_rom_ack,

    // Debug, per frame: lines whose fetch was still running when the next
    // line began (that line is skipped and the previous one shows twice),
    // and the longest line fetch in clk_sys.
    output logic [7:0]  dbg_fetch_overruns,
    output logic [11:0] dbg_fetch_max,

    // ---- Motion object framebuffer read -----------------------------------
    output logic [8:0]  mo_x,
    output logic [7:0]  mo_y,
    input  wire [9:0]   mo_index,

    // ---- Palette read port ------------------------------------------------
    output logic [PAL_AW-1:0] pal_index,

    // ---- Raster outputs ---------------------------------------------------
    output logic        hblank,
    output logic        vblank,
    output logic        hsync,
    output logic        vsync,
    output logic        de,
    output logic        vblank_rise,
    output logic [8:0]  vis_x,
    output logic [7:0]  vis_y
);

    //========================================================================
    //  Raster timing
    //========================================================================
    wire [HCNT_W-1:0] hcnt;
    wire [VCNT_W-1:0] vcnt;
    wire line_start, frame_start, vblank_fall;

    g1_video_timing u_timing (
        .clk         (clk),
        .rst_n       (rst_n),
        .ce_pix      (ce_pix),
        .hcnt        (hcnt),
        .vcnt        (vcnt),
        .hblank      (hblank),
        .vblank      (vblank),
        .hsync       (hsync),
        .vsync       (vsync),
        .de          (de),
        .line_start  (line_start),
        .frame_start (frame_start),
        .vblank_rise (vblank_rise),
        .vblank_fall (vblank_fall),
        .vis_x       (vis_x),
        .vis_y       (vis_y)
    );

    // The fetched line is one ahead of the displayed line; from the last
    // visible line on it is 0, so line 0 is fetched during vertical blanking.
    wire [8:0] fetch_line = (vcnt >= VCNT_W'(V_VISIBLE - 1))
                          ? 9'd0
                          : (vcnt[8:0] + 9'd1);

    //========================================================================
    //  Per-line fetch sequencer
    //========================================================================
    typedef enum logic [1:0] { L_IDLE, L_SCROLL, L_FETCH } lstate_t;

    // line_start arrives with vcnt already on the new line v, whose start
    // fetches line v+1. Blanking lines fetch nothing, except two:
    //   - line 239: each start also swaps the ping-pong buffers, and line 239
    //     is displayed from the buffer that swap exposes;
    //   - line 261: refetches line 0 after the VBLANK handler has written the
    //     new frame's scroll words and tile maps.
    // The swaps at 261 and 0 leave line 0 displaying 261's fill.
    wire fetch_needed = (vcnt < VCNT_W'(V_VISIBLE))
                     || (vcnt == VCNT_W'(V_TOTAL - 1));
    lstate_t lstate;

    logic scroll_start, pf_start, al_start;
    wire  scroll_done, pf_busy, al_busy;

    // Scroll read, then playfield and alpha fetch concurrently.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lstate       <= L_IDLE;
            scroll_start <= 1'b0;
            pf_start     <= 1'b0;
            al_start     <= 1'b0;
        end
        else begin
            scroll_start <= 1'b0;
            pf_start     <= 1'b0;
            al_start     <= 1'b0;

            case (lstate)
            L_IDLE:
                if (line_start && fetch_needed) begin
                    scroll_start <= 1'b1;
                    lstate       <= L_SCROLL;
                end

            L_SCROLL:
                if (scroll_done) begin
                    pf_start <= 1'b1;
                    al_start <= 1'b1;
                    lstate   <= L_FETCH;
                end

            // The fetchers go busy the clock after their start pulse.
            L_FETCH:
                if (!pf_busy && !al_busy && !pf_start && !al_start)
                    lstate <= L_IDLE;

            default: lstate <= L_IDLE;
            endcase
        end
    end

    //------------------------------------------------------------------------
    // Debug: fetch overruns and longest fetch, latched once a frame
    //------------------------------------------------------------------------
    logic [7:0]  ovr_cnt;
    logic [11:0] len_cnt, len_max;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ovr_cnt            <= '0;
            len_cnt            <= '0;
            len_max            <= '0;
            dbg_fetch_overruns <= '0;
            dbg_fetch_max      <= '0;
        end
        else begin
            if (lstate != L_IDLE) begin
                if (len_cnt != 12'hFFF) len_cnt <= len_cnt + 1'b1;
            end
            else begin
                len_cnt <= '0;
                if (len_cnt > len_max) len_max <= len_cnt;
            end
            if (line_start && fetch_needed && lstate != L_IDLE && ovr_cnt != 8'hFF)
                ovr_cnt <= ovr_cnt + 1'b1;
            if (frame_start) begin
                dbg_fetch_overruns <= ovr_cnt;
                dbg_fetch_max      <= len_max;
                ovr_cnt            <= '0;
                len_max            <= '0;
            end
        end
    end

    wire [8:0] xscroll, yscroll;
    wire [2:0] tile_bank;

    wire [14:0] sc_vaddr;  wire sc_vreq;
    wire [14:0] al_vaddr;  wire al_vreq;
    wire [14:0] pf_vaddr;  wire pf_vreq;
    logic sc_vack, al_vack, pf_vack;

    g1_scroll u_scroll (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (scroll_start),
        .line       (fetch_line),
        .pf_xoffset (pf_xoffset),
        .vram_addr  (sc_vaddr),
        .vram_req   (sc_vreq),
        .vram_dout  (vram_dout),
        .vram_ack   (sc_vack),
        .xscroll    (xscroll),
        .yscroll    (yscroll),
        .tile_bank  (tile_bank),
        .done       (scroll_done)
    );

    //========================================================================
    //  Work RAM port arbitration
    //========================================================================
    // Fixed read priority: scroll, playfield, alpha, then the RLE engine.
    // Work RAM is BRAM with one clock of latency, so the ack is the grant
    // delayed by one clock.
    //------------------------------------------------------------------------
    logic sc_sel_d, al_sel_d, pf_sel_d, ext_sel_d;

    always_comb begin
        // Reads only. The CHECKSUM write-back has its own address on the
        // CPU's write port: a second write port would stop this RAM inferring
        // as block RAM (g1_mainram.sv).
        if      (sc_vreq) vram_addr = sc_vaddr;
        else if (pf_vreq) vram_addr = pf_vaddr;
        else if (al_vreq) vram_addr = al_vaddr;
        else              vram_addr = ext_vram_addr;

        vram_din_addr = ext_vram_addr;
        vram_din      = ext_vram_din;
        vram_we       = ext_vram_we;
    end

    always_ff @(posedge clk) begin
        sc_sel_d  <= sc_vreq;
        pf_sel_d  <= pf_vreq  && !sc_vreq;
        al_sel_d  <= al_vreq  && !sc_vreq && !pf_vreq;
        ext_sel_d <= ext_vram_req && !sc_vreq && !pf_vreq && !al_vreq;
    end

    assign sc_vack     = sc_sel_d;
    assign pf_vack     = pf_sel_d;
    assign al_vack     = al_sel_d;
    assign ext_vram_ack = ext_sel_d;

    //========================================================================
    //  Layers
    //========================================================================
    wire [24:0] pf_raddr, al_raddr;
    wire        pf_rreq,  al_rreq;
    logic       pf_rack,  al_rack;

    wire [4:0] pf_pixel;  wire [2:0] pf_color;  wire pf_prio;
    wire [3:0] al_pixel;  wire [3:0] al_color;  wire al_opaque;

    g1_playfield u_pf (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (pf_start),
        .line       (fetch_line),
        .xscroll    (xscroll),
        .yscroll    (yscroll),
        .tile_bank  (tile_bank),
        .vram_addr  (pf_vaddr),
        .vram_req   (pf_vreq),
        .vram_dout  (vram_dout),
        .vram_ack   (pf_vack),
        .rom_addr   (pf_raddr),
        .rom_req    (pf_rreq),
        .rom_dout   (tile_rom_dout),
        .rom_ack    (pf_rack),
        .disp_x     (vis_x),
        .disp_pixel (pf_pixel),
        .disp_color (pf_color),
        .disp_prio  (pf_prio),
        .busy       (pf_busy)
    );

    g1_alpha u_al (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (al_start),
        .line        (fetch_line),
        .vram_addr   (al_vaddr),
        .vram_req    (al_vreq),
        .vram_dout   (vram_dout),
        .vram_ack    (al_vack),
        .rom_addr    (al_raddr),
        .rom_req     (al_rreq),
        .rom_dout    (tile_rom_dout),
        .rom_ack     (al_rack),
        .disp_x      (vis_x),
        .disp_pixel  (al_pixel),
        .disp_color  (al_color),
        .disp_opaque (al_opaque),
        .busy        (al_busy),
        .dbg_map_nz  (dbg_map_nz),
        .dbg_map_word(dbg_map_word)
    );

    //========================================================================
    //  Tile ROM channel: two fetchers, one arbiter port
    //========================================================================
    // Grant handshake: the arbiter raises tile_rom_gnt in the clock it takes
    // the presented request and latches tile_rom_addr. At that same edge the
    // owner is recorded and the fetcher marked taken, so its request (high
    // until its ack) is not presented again. Owner, taken flag and arbiter
    // address all come from one selection at one edge, so they cannot
    // disagree, and the arbiter can re-grant in the ack clock. (Dropping the
    // request for a clock per handover instead gives the slot to the sprite
    // engine and roughly doubles the time per word.)
    //
    // One access is in flight at a time, so one owner register routes every
    // ack; an ack and a grant in the same clock route by the old owner.
    //
    // Do not restart a fetcher with a word in flight: the pending ack would
    // arrive as data for its next request. The sequencer starts them only
    // from L_IDLE.
    //========================================================================
    logic pf_taken, al_taken, inflight_pf;

    wire pf_can  = pf_rreq && !pf_taken;
    wire al_can  = al_rreq && !al_taken;
    wire pick_pf = pf_can;            // playfield first: it has more words

    assign tile_rom_req  = pf_can || al_can;
    assign tile_rom_addr = pick_pf ? pf_raddr : al_raddr;

    assign pf_rack = tile_rom_ack &&  inflight_pf;
    assign al_rack = tile_rom_ack && !inflight_pf;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pf_taken    <= 1'b0;
            al_taken    <= 1'b0;
            inflight_pf <= 1'b0;
        end
        else begin
            if (pf_rack) pf_taken <= 1'b0;
            if (al_rack) al_taken <= 1'b0;
            if (tile_rom_gnt) begin
                inflight_pf <= pick_pf;
                if (pick_pf) pf_taken <= 1'b1;
                else         al_taken <= 1'b1;
            end
        end
    end

    assign dbg_al_ack  = al_rack;
    assign dbg_pf_ack  = pf_rack;
    assign dbg_al_busy = al_busy;
    assign dbg_pf_busy = pf_busy;

    //========================================================================
    //  Motion object framebuffer address
    //========================================================================
    assign mo_x = vis_x;
    assign mo_y = vis_y;

    //========================================================================
    //  Mixer
    //========================================================================
    g1_mixer u_mixer (
        .clk       (clk),
        .de        (de),
        .pf_pixel  (pf_pixel),
        .pf_color  (pf_color),
        .pf_prio   (pf_prio),
        .mo_index  (mo_index),
        .mo_enable (mo_enable),
        .al_pixel  (al_pixel),
        .al_color  (al_color),
        .al_opaque (al_opaque),
        .pal_index (pal_index)
    );

endmodule

`default_nettype wire
