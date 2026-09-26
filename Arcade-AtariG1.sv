//============================================================================
//  Atari G1 for MiSTer
//  Arcade-AtariG1.sv -- top level: MiSTer framework glue for the core
//
//  Instantiates the board (g1_top), video (g1_video), motion-object renderer
//  (g1_rle), JSA II sound board (g1_jsa2), ROM loader, SDRAM arbiter and
//  controller with a boot-time self-test, Hydra analog controls and a
//  diagnostic overlay. The module must be named "emu" and use
//  sys/emu_ports.vh; the framework binds to those names.
//
//  Coins are not on the 68000's input ports: COIN1/2/3 are on the JSA II's
//  RDIO port (6502 $2804, active high) and reach the 68000 only through the
//  sound command latch (MAME port definitions). Only coins 1 and 2 are
//  credited; see Inputs.
//
//  Clock domain: clk_sys; the SDRAM controller runs on clk_ram.
//============================================================================

module emu
(
    `include "sys/emu_ports.vh"
);

    import g1_pkg::*;

    //========================================================================
    //  Unused framework ports
    //========================================================================
    assign ADC_BUS  = 'Z;
    assign USER_OUT = '1;
    assign {UART_RTS, UART_TXD, UART_DTR} = 0;
    assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
    assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR,
            DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

    assign VGA_F1         = 0;
    assign VGA_SCALER     = 0;
    assign VGA_DISABLE    = 0;
    assign HDMI_FREEZE    = 0;
    assign HDMI_BLACKOUT  = 0;
    assign HDMI_BOB_DEINT = 0;

    assign LED_DISK  = 0;
    assign LED_POWER = 0;
    assign BUTTONS   = 0;

    //========================================================================
    //  Aspect ratio
    //========================================================================
    wire [1:0] ar = status[122:121];
    assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
    assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

    //========================================================================
    //  OSD
    //========================================================================
    // build_id.v provides `BUILD_DATE for the OSD version line. It is generated
    // before every compile by sys/build_id.tcl (pre-flow script, sys/sys.tcl).
    `include "build_id.v"
    localparam CONF_STR = {
        "AtariG1;;",
        "-;",
        "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
        "O[4:2],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
        "-;",
        // The game's own service (test) menu: turn on, then reset.
        "O[23],Service Menu,Off,On;",
        "-;",
        "P1,Debug;",
        "P1-;",
        "P1O[10],CPU clock,14.318MHz (MAME),7.159MHz;",
        "P1O[22],SDRAM capture,Auto (self-test),Manual;",
        "P1O[19:18],Manual read phase,t8,t9,t10,t7;",
        "P1O[20],Manual sample edge,Falling,Rising;",
        "P1O[21],Self-test bus,Shared,Exclusive;",
        "P1O[11],Watchdog,Enabled,Disabled;",
        "P1O[12],Slapstic,Enabled,Bootleg mode;",
        "P1O[15],Motion objects,On,Off;",
        "P1-;",
        // Debug overlay, off by default. status[17:16] is left unused: saved
        // configs may still hold the overlay's earlier setting there.
        "P1O[25:24],Diagnostic,Off,Text,Activity;",
        "-;",
        "P2,Controls;",
        "P2-;",
        // Hydra yoke scaling. Medium (100%) is listed first so it is the
        // default; Low is 50%.
        "P2O[14:13],Analog sensitivity,Medium,High,Low;",
        "-;",
        "DIP;",
        "-;",
        "T[0],Reset;",
        "R[0],Reset and close OSD;",
        // Overridden by each MRA's <buttons>; matches Pit Fighter's list so a
        // bare .rbf maps the same way (see Inputs).
        "J1,Punch,Kick,Jump,Start,Coin;",
        "jn,A,B,X,Start,R;",
        "v,0;",
        "V,v",`BUILD_DATE
    };

    wire         forced_scandoubler;
    wire  [1:0]  buttons;
    wire [127:0] status;
    wire [21:0]  gamma_bus;
    wire         direct_video;

    wire         ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd;
    wire [26:0]  ioctl_addr;
    wire  [7:0]  ioctl_dout;
    wire [15:0]  ioctl_index;
    wire         ioctl_wait;
    logic [7:0]  ioctl_din;

    wire [31:0]  joystick_0, joystick_1, joystick_2;
    wire [15:0]  joystick_l_analog_0;
    wire [15:0]  joystick_r_analog_0;
    wire [7:0]   paddle_0;

    hps_io #(.CONF_STR(CONF_STR)) hps_io
    (
        .clk_sys(clk_sys),
        .HPS_BUS(HPS_BUS),
        .EXT_BUS(),
        .gamma_bus(gamma_bus),

        .forced_scandoubler(forced_scandoubler),
        .direct_video(direct_video),
        .video_rotated(1'b0),
        .new_vmode(1'b0),

        .buttons(buttons),
        .status(status),
        .status_menumask(16'd0),

        .ioctl_download(ioctl_download),
        .ioctl_upload(ioctl_upload),
        .ioctl_upload_req(nv_dirty),
        .ioctl_upload_index(8'd2),
        .ioctl_wr(ioctl_wr),
        .ioctl_rd(ioctl_rd),
        .ioctl_addr(ioctl_addr),
        .ioctl_dout(ioctl_dout),
        .ioctl_din(ioctl_din),
        .ioctl_index(ioctl_index),
        .ioctl_wait(ioctl_wait),

        .joystick_0(joystick_0),
        .joystick_1(joystick_1),
        .joystick_2(joystick_2),
        .joystick_l_analog_0(joystick_l_analog_0),
        .joystick_r_analog_0(joystick_r_analog_0),
        .paddle_0(paddle_0)
    );

    //========================================================================
    //  Clocks
    //========================================================================
    wire clk_sys, clk_ram, clk_ram_ps, pll_locked;

    pll pll
    (
        .refclk(CLK_50M),
        .rst(1'b0),
        .outclk_0(clk_sys),     //  57.272724 MHz
        .outclk_1(clk_ram),     // 114.545448 MHz
        .outclk_2(clk_ram_ps),  // 114.545448 MHz, phase shifted
        .locked(pll_locked)
    );

    assign SDRAM_CLK = clk_ram_ps;

    // ---- Reset domains ----------------------------------------------------
    //   rst_n      game logic (CPUs, video, RLE engine, sound). Held during the
    //              ROM download and the SDRAM self-test: there is no valid ROM
    //              yet, and the self-test borrows the CPU memory channel.
    //   rst_n_mem  loader, arbiter and SDRAM path. Must run during the
    //              download, which writes through them: an arbiter in reset
    //              never acks the loader, ioctl_wait stays high and the HPS
    //              stalls at "Sending ROM #0".
    // ------------------------------------------------------------------------
    wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~pll_locked
               | st_busy;
    wire rst_n = ~reset;

    // Everything the download needs: excludes ioctl_download and st_busy but
    // still clears on a real reset or PLL unlock. The `| ioctl_download` term
    // is required: the framework asserts RESET during a ROM download, and
    // without it the loader never asserts ioctl_wait, so the download reports
    // success at full speed while nothing reaches SDRAM.
    wire rst_n_mem = ~(RESET | status[0] | buttons[1] | ~pll_locked)
                   | ioctl_download;

    // Download-start edge. Declared here because g1_top's dbg_clr uses it and
    // that instance comes first; a forward reference to a variable is an error.
    logic dl_d;
    always_ff @(posedge clk_sys) dl_d <= ioctl_download;

    // Debug/accumulator clear: PLL unlock only. An MRA performs several
    // downloads (index 0 the 3.7 MB ROM, index 1 a 9-byte config blob), so
    // clearing at each download start would keep only the last, tiny one.
    // Anything that must accumulate across the download uses this rather than
    // rst_n_mem, which the framework's post-download RESET pulls low.
    wire dbg_clear = ~pll_locked;

    // The ROM image is download index 0, the same test g1_rom_loader uses.
    wire rom_loading = ioctl_download && (ioctl_index[5:0] == 6'd0);

    //------------------------------------------------------------------------
    // Re-arm the read probes when the OSD read phase changes. The probes
    // capture the first reads after reset and then freeze; reloading the MRA
    // does not unlock the PLL, so without this they would keep showing values
    // from the previous setting. The write-side capture is not re-armed: it
    // is taken during the download.
    //------------------------------------------------------------------------
    logic [1:0] rd_phase_d;
    always_ff @(posedge clk_sys) rd_phase_d <= status[19:18];
    wire rd_probe_rearm = dbg_clear || (rd_phase_d != status[19:18]);

    wire ce_pix, ce_cpu_p1, ce_cpu_p2, ce_14m, ce_ym, ce_6502, ce_oki;

    g1_ce u_ce
    (
        .clk       (clk_sys),
        .rst_n     (rst_n),
        .cpu_div2  (status[10]),
        .ce_pix    (ce_pix),
        .ce_cpu_p1 (ce_cpu_p1),
        .ce_cpu_p2 (ce_cpu_p2),
        .ce_14m    (ce_14m),
        .ce_ym     (ce_ym),
        .ce_6502   (ce_6502),
        .ce_oki    (ce_oki)
    );

    //========================================================================
    //  ROM loading
    //========================================================================
    g1_cfg_t cfg;
    wire     cfg_valid, rom_loaded, loading;

    wire [24:0] ldr_addr;
    wire [15:0] ldr_din;
    wire        ldr_we, ldr_ack;

    //------------------------------------------------------------------------
    // Debug: the first four words the loader writes. The loader writes
    // sequentially from 0, so these are $0/$2/$4/$6, the same words the read
    // probes (RV0..RV3) read back; together they separate a write fault from
    // a read fault. Captured on the rising edge of ldr_we, which is a level
    // held until the arbiter acknowledges.
    //------------------------------------------------------------------------
    logic [63:0] dbg_wv_pk;
    logic [2:0]  wv_count;
    logic        ldr_we_d;
    always_ff @(posedge clk_sys) begin
        ldr_we_d <= ldr_we;
        if (dbg_clear) begin
            dbg_wv_pk <= 64'd0;
            wv_count  <= 3'd0;
            ldr_we_d  <= 1'b0;
        end
        else if (ldr_we && !ldr_we_d && wv_count < 3'd4) begin
            dbg_wv_pk[16*wv_count +: 16] <= ldr_din;
            wv_count <= wv_count + 3'd1;
        end
    end

    g1_rom_loader u_loader
    (
        .clk            (clk_sys),
        .rst_n          (rst_n_mem),
        .ioctl_download (ioctl_download),
        .ioctl_index    (ioctl_index),
        .ioctl_wr       (ioctl_wr),
        .ioctl_addr     (ioctl_addr),
        .ioctl_dout     (ioctl_dout),
        .ioctl_wait     (ioctl_wait),
        .sdr_addr       (ldr_addr),
        .sdr_din        (ldr_din),
        .sdr_we         (ldr_we),
        .sdr_ack        (ldr_ack),
        .cfg            (cfg),
        .cfg_valid      (cfg_valid),
        .rom_loaded     (rom_loaded),
        .loading        (loading)
    );

    // One-shot when the ROM download completes: kicks off the RLE prescan
    // and the SDRAM self-test.
    logic rom_loaded_d;
    always_ff @(posedge clk_sys) rom_loaded_d <= rom_loaded;
    wire load_complete = rom_loaded && !rom_loaded_d;

    //------------------------------------------------------------------------
    // Latched start requests (self-test, RLE prescan). load_complete is a
    // one-clock pulse in the cycle ioctl_download drops, when the consumers
    // can still be held in reset. The latches have no reset, so a request
    // holds until its consumer raises its busy flag.
    //------------------------------------------------------------------------
    logic st_pending, pf_pending;
    always_ff @(posedge clk_sys) begin
        if (load_complete) st_pending <= 1'b1;
        else if (st_busy)  st_pending <= 1'b0;

        if (load_complete)     pf_pending <= 1'b1;
        else if (prescan_busy) pf_pending <= 1'b0;
    end

    // Convenience decodes of the config blob.
    wire        is_pitfight = (cfg.game_id == 8'd1);
    wire        has_adc     = cfg.flags[0];
    wire [10:0] obj_count   = is_pitfight ? RLE_OBJCOUNT_PITFIGHT[10:0]
                                          : RLE_OBJCOUNT_HYDRA[10:0];

    //========================================================================
    //  SDRAM
    //========================================================================
    wire [24:0] cpu_rom_addr, tile_rom_addr, rle_rom_addr, oki_rom_addr;
    wire        cpu_rom_req,  tile_rom_req,  rle_rom_req,  oki_rom_req;
    wire [15:0] cpu_rom_dout, tile_rom_dout, rle_rom_dout, oki_rom_dout;
    wire        cpu_rom_ack,  tile_rom_ack,  rle_rom_ack,  oki_rom_ack;
    // Tile channel grant: the arbiter took g1_video's presented request this
    // clock. See the handshake note in g1_video.sv.
    wire        tile_rom_gnt;

    // The JSA II 6502 fetches its program from SDRAM over the CPU channel,
    // shared with the 68000; at 1.79 MHz it has a full bus cycle of slack.
    wire [24:0] jsa_prog_addr;
    wire        jsa_prog_req;
    wire        jsa_prog_ack;

    wire [24:0] sdr_addr;
    wire [24:0] arb_done_addr;

    // Debug: SDRAM DQ sampled at t7..t10 of the most recent read.
    wire [15:0] dq7, dq8, dq9, dq10;
    wire [31:0] refresh_count;
    // A/B: the DQ samples for the first two 68000 reads after a re-arm ($0,
    // expected $00FF; $2, expected $FFFE). The two reads can fail at
    // different sample phases, so both are kept.
    logic [15:0] a7_l, a8_l, a9_l, a10_l;
    logic [15:0] b7_l, b8_l, b9_l, b10_l;
    logic [1:0]  dq_set;
    // Re-armed on the same conditions as RV (download start, read-phase
    // change), so both probes describe the same read.
    always_ff @(posedge clk_sys) begin
        if (dbg_clear || (ioctl_download & ~dl_d) || rd_probe_rearm) begin
            dq_set <= 2'd0;
            a7_l <= '0; a8_l <= '0; a9_l <= '0; a10_l <= '0;
            b7_l <= '0; b8_l <= '0; b9_l <= '0; b10_l <= '0;
        end
        else if (cpu_rom_ack_68k && dq_set < 2'd2) begin
            if (dq_set == 2'd0) begin
                a7_l <= dq7; a8_l <= dq8; a9_l <= dq9; a10_l <= dq10;
            end else begin
                b7_l <= dq7; b8_l <= dq8; b9_l <= dq9; b10_l <= dq10;
            end
            dq_set <= dq_set + 2'd1;
        end
    end
    wire [15:0] sdr_din;
    wire        sdr_we, sdr_rd;
    wire [15:0] sdr_dout;
    wire        sdr_ready;

    // ---- CPU channel: 68000 and 6502 --------------------------------------
    // The 68000 wins any tie. Owner and address latch together at grant (as
    // at the tile port in g1_video.sv): an owner flag that tracks the live mux
    // can hand a completed read to the wrong CPU.
    wire [24:0] m68k_addr = cpu_rom_addr;
    wire        m68k_req  = cpu_rom_req;

    logic       cpu_owner_68k;
    logic       cpu_arb_req;
    logic [24:0] cpujsa_addr_held;

    //------------------------------------------------------------------------
    // Registered request. Owner and address latch before the request becomes
    // visible, and the request drops for one cycle at handover, so the arbiter
    // cannot re-grant while the previous owner's address is still presented.
    // The 68000 is DTACK-gated on rom_have, so the extra clk_sys per fetch is
    // absorbed.
    //
    // The self-test bypasses the hold: it owns the channel while it runs, with
    // both CPUs in reset, so no request is pending across the transition.
    //------------------------------------------------------------------------
    always_ff @(posedge clk_sys) begin
        if (!rst_n_mem) begin
            cpu_arb_req      <= 1'b0;
            cpu_owner_68k    <= 1'b0;
            cpujsa_addr_held <= '0;
        end
        else if (!cpu_arb_req) begin
            if (!st_busy) begin
                if (m68k_req) begin
                    cpu_owner_68k    <= 1'b1;
                    cpujsa_addr_held <= m68k_addr;
                    cpu_arb_req      <= 1'b1;
                end
                else if (jsa_prog_req) begin
                    cpu_owner_68k    <= 1'b0;
                    cpujsa_addr_held <= jsa_prog_addr;
                    cpu_arb_req      <= 1'b1;
                end
            end
        end
        else if (cpu_rom_ack) begin
            cpu_arb_req <= 1'b0;
        end
    end

    wire cpu_rom_ack_68k = cpu_rom_ack &&  cpu_owner_68k && !st_busy;

    //------------------------------------------------------------------------
    // Debug: the SDRAM address the arbiter used for the first two completed
    // 68000 reads, recorded at completion so address and data are paired.
    //------------------------------------------------------------------------
    logic [49:0] dbg_aa_pk;
    logic [1:0]  aa_count;
    always_ff @(posedge clk_sys) begin
        if (rd_probe_rearm) begin
            dbg_aa_pk <= 50'd0;
            aa_count  <= 2'd0;
        end
        else if (cpu_rom_ack_68k && aa_count < 2'd2) begin
            dbg_aa_pk[25*aa_count +: 25] <= arb_done_addr;
            aa_count <= aa_count + 2'd1;
        end
    end
    // The address compare drops an ack for a fetch the 6502 no longer wants:
    // a sound reset ($F98000) resets the 6502 but cannot withdraw a fetch this
    // mux has already latched. While the 6502 waits for a byte its address
    // cannot change, so a real ack always matches.
    assign jsa_prog_ack  = cpu_rom_ack && !cpu_owner_68k && !st_busy
                        && (cpujsa_addr_held == jsa_prog_addr);

    g1_sdram_arb u_arb
    (
        .clk       (clk_sys),
        // rst_n_mem: must run during the ROM download (see Reset domains).
        .rst_n     (rst_n_mem),
        .ld_addr   (ldr_addr),   .ld_din   (ldr_din),   .ld_we   (ldr_we),
        .ld_ack    (ldr_ack),
        // Held address and request (see cpu_owner_68k). The self-test owns the
        // channel outright while it runs and bypasses the hold.
        .cpu_addr  (st_busy ? st_addr : cpujsa_addr_held),
        .cpu_req   (st_busy ? st_req  : cpu_arb_req),
        .cpu_dout  (cpu_rom_dout),  .cpu_ack  (cpu_rom_ack),
        .tile_addr (tile_rom_addr), .tile_req (tile_rom_req), .tile_gnt (tile_rom_gnt),
        .tile_dout (tile_rom_dout), .tile_ack (tile_rom_ack),
        .rle_addr  (rle_rom_addr),  .rle_req  (rle_rom_req),
        .rle_dout  (rle_rom_dout),  .rle_ack  (rle_rom_ack),
        .oki_addr  (oki_rom_addr),  .oki_req  (oki_rom_req),
        .oki_dout  (oki_rom_dout),  .oki_ack  (oki_rom_ack),
        .sdr_addr  (sdr_addr),
        .dbg_cpu_done_addr (arb_done_addr),
        // No other master on the bus while the self-test runs: automatic in
        // its second pass, or forced by the OSD "Self-test bus" option.
        .solo_cpu  ((st_busy & st_solo) | (st_busy & status[21])),
        .sdr_din   (sdr_din),
        .sdr_we    (sdr_we),
        .sdr_rd    (sdr_rd),
        .sdr_dout  (sdr_dout),
        .sdr_ready (sdr_ready)
    );

    //------------------------------------------------------------------------
    // SDRAM capture setting {rd_half, rd_phase}, numbered as the S rows:
    //
    //     S0 t8 Rise  S1 t9 Rise  S2 t10 Rise  S3 t7 Rise
    //     S4 t8 Fall  S5 t9 Fall  S6 t10 Fall  S7 t7 Fall
    //
    // The working sample point depends on where the fitter places the capture
    // registers, so it can move between compiles. In Auto (default) the
    // self-test measures all eight settings at boot and the best is used.
    // Manual uses the OSD setting, which MiSTer keeps in the saved config.
    //------------------------------------------------------------------------
    wire [2:0] cap_manual = {~status[20], status[19:18]};
    wire       cap_auto   = ~status[22];
    // Selected in an always_comb after the self-test instance, where the
    // st_best_* nets are declared.
    logic [2:0] cap_sel;

    wire which_controller;

    g1_sdram_iface u_sdram
    (
        // During the self-test sweep, the sweep's setting; afterwards the best
        // measured (Auto) or the OSD's (Manual). See cap_sel.
        .rd_phase   (cap_sel[1:0]),
        .rd_half    (cap_sel[2]),
        .dbg_refresh_count (refresh_count),
        .dbg_dq7    (dq7), .dbg_dq8  (dq8),
        .dbg_dq9    (dq9), .dbg_dq10 (dq10),
        .SDRAM_DQ   (SDRAM_DQ),
        .SDRAM_A    (SDRAM_A),
        .SDRAM_BA   (SDRAM_BA),
        .SDRAM_DQML (SDRAM_DQML),
        .SDRAM_DQMH (SDRAM_DQMH),
        .SDRAM_nCS  (SDRAM_nCS),
        .SDRAM_nRAS (SDRAM_nRAS),
        .SDRAM_nCAS (SDRAM_nCAS),
        .SDRAM_nWE  (SDRAM_nWE),
        .SDRAM_CKE  (SDRAM_CKE),

        .init       (~pll_locked),
        .clk        (clk_ram),

        .addr       (sdr_addr),
        .din        (sdr_din),
        .dout       (sdr_dout),
        .rd         (sdr_rd),
        .we         (sdr_we),
        .ready      (sdr_ready),
        .which_controller (which_controller)
    );

    //========================================================================
    //  SDRAM self-test
    //========================================================================
    // Checks that every word read back from SDRAM equals the word written
    // (write-side and read-side checksums), and measures the error count of
    // each capture setting. It borrows the CPU read channel and finishes
    // before the 68000 is released from reset. See g1_sdram_selftest.sv for
    // what a pass does and does not prove.
    wire [24:0] st_addr;
    wire        st_req, st_busy, st_done, st_pass;
    wire [31:0] st_sum_w, st_sum_r, st_mix_w, st_mix_r;
    wire [31:0] st_sum_r1;   // first read pass, for the two-pass comparison
    wire        st_solo;   // self-test pass 2 wants the bus to itself
    wire [31:0] st_rep_err;  // mismatches re-reading one address 65536 times
    wire [15:0] st_rep_ref;  // the value that repeat test expects
    wire [2:0]  st_sw_sel;   // capture setting the sweep is measuring
    wire        st_sw_on;    // sweep is driving the setting, not the OSD
    wire [16*8-1:0] st_sw_err;  // error count per setting, 16 bits each
    wire [2:0]  st_best_sel;    // setting the sweep measured best
    wire        st_best_valid;  // ... and it has finished measuring
    wire        st_best_clean;  // ... and that setting made no errors

    //------------------------------------------------------------------------
    // Reset from ~dbg_clear, not rst_n_mem: the write-side checksum is
    // accumulated during the download, and rst_n_mem includes the framework
    // RESET that pulses when the download ends, which would clear it before
    // the comparison. Any accumulator spanning the download needs this.
    //------------------------------------------------------------------------
    g1_sdram_selftest u_selftest
    (
        .clk           (clk_sys),
        .rst_n         (~dbg_clear),
        .load_active   (loading),
        .load_addr     (ldr_addr),
        .load_data     (ldr_din),
        .load_we       (ldr_we),
        .load_complete (st_pending),
        .rd_addr       (st_addr),
        .rd_req        (st_req),
        .rd_dout       (cpu_rom_dout),
        .rd_ack        (cpu_rom_ack),
        .busy          (st_busy),
        .done          (st_done),
        .pass          (st_pass),
        .sum_written   (st_sum_w),
        .sum_read      (st_sum_r),
        .sum_read_1    (st_sum_r1),
        .solo_pass     (st_solo),
        .rep_err       (st_rep_err),
        .rep_ref       (st_rep_ref),
        .sweep_sel     (st_sw_sel),
        .sweep_on      (st_sw_on),
        .sweep_err     (st_sw_err),
        .best_sel      (st_best_sel),
        .best_valid    (st_best_valid),
        .best_clean    (st_best_clean),
        .mix_written   (st_mix_w),
        .mix_read      (st_mix_r),
        .first_bad_addr(),
        .had_bad_addr  ()
    );

    always_comb begin
        if (st_sw_on)                       cap_sel = st_sw_sel;
        else if (cap_auto && st_best_valid) cap_sel = st_best_sel;
        else                                cap_sel = cap_manual;
    end

    // Latch the result so it survives past the one-clock done pulse.
    logic st_ran, st_result;
    always_ff @(posedge clk_sys) begin
        if (!rst_n) begin
            st_ran    <= 1'b0;
            st_result <= 1'b0;
        end else if (st_done) begin
            st_ran    <= 1'b1;
            st_result <= st_pass;
        end
    end

    //========================================================================
    //  Inputs
    //========================================================================
    // Bit assignments follow MAME's INPUT_PORTS. Game buttons are active low;
    // the VBLANK and ADC-EOC status bits are active high.
    //
    // MiSTer joystick bits: [0] right, [1] left, [2] down, [3] up, then one
    // bit per button in the order of the MRA's <buttons names="...">, from
    // bit 4. The MRA list overrides the CONF_STR J1 line, so the games differ:
    //
    //   Pit Fighter  [4] Punch  [5] Kick  [6] Jump  [7] Start  [8] Coin
    //   Hydra        [4] Left Trigger  [5] Right Trigger  [6] Left Thumb
    //                [7] Right Thumb   [8] Boost  [9] Pedal  [10] Coin
    //                (Hydra has no start button: the pedal starts a game)
    //------------------------------------------------------------------------
    // Service/test switch (IN0 bit 14, active low), from the OSD. MAME's
    // PORT_SERVICE; both games check it at boot to enter the test menu.
    wire        service = ~status[23];
    wire        vblank_status;
    wire [7:0]  adc_data;
    wire        adc_eoc;
    // snd_ready is declared with the sound board signals below.

    // Pit Fighter player port, MAME order: down, up, right, left, Punch,
    // Kick, Jump/Start. The cabinet's Jump button is also Start, so the MRA's
    // separate Start button drives the same bit.
    function automatic [15:0] pf_in0(input [31:0] j);
        pf_in0 = 16'hFFFF;
        pf_in0[0] = ~j[2];            // down
        pf_in0[1] = ~j[3];            // up
        pf_in0[2] = ~j[0];            // right
        pf_in0[3] = ~j[1];            // left
        pf_in0[4] = ~j[4];            // punch
        pf_in0[5] = ~j[5];            // kick
        pf_in0[6] = ~(j[6] | j[7]);   // jump / start
    endfunction

    // Hydra: five buttons, no directions (steering is analog). MAME order:
    // Left Trigger, Right Trigger, Left Thumb, Right Thumb, Boost -- the
    // same order as the MRA's buttons, so bit n is joystick bit n+4.
    wire [15:0] hydra_in0 = {
        vblank_status,          // 15  VBLANK, active high
        service,                // 14  service, active low
        adc_eoc,                // 13  ADC end of conversion, active high
        ~snd_ready,             // 12  main-to-sound latch full, active low
        7'h7F,                  // 11:5 unused
        ~joystick_0[8],         //  4  Boost
        ~joystick_0[7],         //  3  Right Thumb
        ~joystick_0[6],         //  2  Left Thumb
        ~joystick_0[5],         //  1  Right Trigger
        ~joystick_0[4]          //  0  Left Trigger
    };

    // Coin buttons (MRA order above). Both cabinets have two coin mechs (Pit
    // Fighter manual fig. 5-3: COIN 1 on JAMMA pin 16, COIN 2 on pin T). The
    // JSA II's third coin input is counted by the 6502 but credited by
    // neither game (MAME), so player 3's coin drops into the right mech and
    // coin 3 reads 0: no switch is wired to it.
    wire coin_p1 = is_pitfight ? joystick_0[8] : joystick_0[10];
    wire coin_p2 = is_pitfight ? joystick_1[8] : joystick_1[10];
    wire coin_p3 = is_pitfight ? joystick_2[8] : joystick_2[10];
    wire coin_left  = coin_p1;
    wire coin_right = coin_p2 | coin_p3;

    // Pit Fighter IN1: player 3 in the low byte, player 2 in the high byte.
    wire [15:0] p3 = pf_in0(joystick_2);
    wire [15:0] p2 = pf_in0(joystick_1);
    wire [15:0] in1 = {1'b1, p2[6:0], 1'b1, p3[6:0]};

    // IN0 bits 11:8: unused in MAME, but on the PCB (manual fig. 5-1, buffer
    // 35A) they repeat player 2's JAMMA lines through R15/R16/R13/R14: bit 8
    // JAM-Z (Punch 2), 9 JAM-a (Kick 2), 10 JAM-b (Jump 2), 11 JAM-c (spare,
    // pulled up). The game reads player 2 from IN1; these show only in the
    // Switch Test's raw FC0000 word.
    wire [15:0] pf_in0_bits = pf_in0(joystick_0);
    wire [15:0] pitfight_in0 = {
        vblank_status,          // 15
        service,                // 14
        1'b1,                   // 13  ADC EOC -- no ADC on Pit Fighter, pulled up
        ~snd_ready,             // 12
        1'b1,                   // 11  JAM-c, spare
        p2[6:4],                // 10:8 Jump 2, Kick 2, Punch 2 (active low)
        1'b1,                   //  7  JAM-25, spare
        pf_in0_bits[6:0]
    };

    wire [15:0] in0 = is_pitfight ? pitfight_in0 : hydra_in0;

    wire [1:0] adc_chan_sel;
    wire       adc_start;

    // Hydra yoke and pedal from a MiSTer pad (g1_hydra_controls.sv). The
    // pedal, which starts a game, is button 6 "Pedal" (joystick bit 9), the
    // right stick pushed up, or the paddle. The d-pad steers while the left
    // stick is centred. frame_tick marks the start of VBLANK.
    logic vbl_d;
    always_ff @(posedge clk_sys) vbl_d <= vblank_status;
    wire  frame_tick = vblank_status & ~vbl_d;

    wire [15:0] hydra_stick;
    wire  [7:0] hydra_pedal;

    g1_hydra_controls u_hydra_ctl
    (
        .clk        (clk_sys),
        .rst_n      (rst_n),
        .frame_tick (frame_tick),
        .dpad       (joystick_0[3:0]),
        .pedal_btn  (joystick_0[9]),
        .l_analog   (joystick_l_analog_0),
        .r_analog   (joystick_r_analog_0),
        .paddle     (paddle_0),
        .stick      (hydra_stick),
        .pedal      (hydra_pedal)
    );

    g1_adc0809 u_adc
    (
        .clk         (clk_sys),
        .rst_n       (rst_n),
        .stick       (hydra_stick),
        .pedal       (hydra_pedal),
        .sensitivity (status[14:13]),
        .chan_sel    (adc_chan_sel),
        .start       (adc_start && has_adc),
        .data        (adc_data),
        .eoc         (adc_eoc)
    );

    //========================================================================
    //  The board
    //========================================================================
    wire [10:0] pal_addr;
    wire [15:0] pal_din, pal_dout;
    wire        pal_wr_hi, pal_wr_lo;

    wire [14:0] vram_addr, vram_din_addr;
    wire [15:0] vram_din, vram_dout;
    wire        vram_we;

    wire [2:0]  rle_ctrl;
    wire        rle_ctrl_wr;
    wire [15:0] rle_cmd, rle_objram_w0;
    wire        rle_cmd_wr;

    wire [7:0]  nv_dout;
    wire        nv_dirty;
    wire        vblank_rise;

    wire [23:1] dbg_cpu_addr;
    wire        dbg_cpu_as_n;
    wire        dbg_unmapped;
    wire [7:0]  dbg_hit;
    wire [15:0] dbg_wd_count;
    wire [23:1] dbg_wd_addr;
    wire  [3:0] dbg_wd_sel;
    wire [15:0] dbg_iack_cnt;
    wire  [7:0] dbg_ipl_seen;
    wire [8*23-1:0] dbg_trace;
    wire [63:0] dbg_rv_pk;
    wire [95:0] dbg_ra_pk;
    wire [15:0] dbg_ack_count, dbg_cyc_count;

    g1_top u_board
    (
        .clk             (clk_sys),
        .rst_n           (rst_n),
        .ce_cpu_p1       (ce_cpu_p1),
        .ce_cpu_p2       (ce_cpu_p2),
        .ce_pix          (ce_pix),

        .cfg             (cfg),
        .disable_wd      (status[11]),
        .dbg_clr         (ioctl_download & ~dl_d),
        .rd_probe_rearm  (rd_probe_rearm),
        .force_bootleg   (status[12]),

        .vblank_rise     (vblank_rise),

        .in0             (in0),
        .in1             (in1),
        .adc_data        (adc_data),
        .adc_eoc         (adc_eoc),
        .adc_chan_sel    (adc_chan_sel),
        .adc_start       (adc_start),

        .rom_addr        (cpu_rom_addr),
        .rom_req         (cpu_rom_req),
        .rom_dout        (cpu_rom_dout),
        .rom_ack         (cpu_rom_ack_68k),

        .pal_addr        (pal_addr),
        .pal_din         (pal_din),
        .pal_wr_hi       (pal_wr_hi),
        .pal_wr_lo       (pal_wr_lo),
        .pal_dout        (pal_dout),

        .vram_snoop_addr     (vram_addr),
        .vram_snoop_din_addr (vram_din_addr),
        .vram_snoop_din      (vram_din),
        .vram_snoop_we       (vram_we),
        .vram_snoop_dout (vram_dout),

        .snd_cmd         (snd_cmd),
        .snd_cmd_wr      (snd_cmd_wr),
        .snd_reset       (snd_reset),
        .snd_resp_rd     (snd_resp_rd),
        .snd_resp        (snd_resp),
        .snd_int         (snd_int),
        .snd_ready       (snd_ready),

        .rle_ctrl        (rle_ctrl),
        .rle_ctrl_wr     (rle_ctrl_wr),
        .rle_cmd         (rle_cmd),
        .rle_cmd_wr      (rle_cmd_wr),
        .rle_objram_w0   (rle_objram_w0),

        .nv_active       (nv_access),
        .nv_addr         (ioctl_addr[10:0]),
        .nv_din          (ioctl_dout),
        .nv_wr           (nv_access && ioctl_wr),
        .nv_dout         (nv_dout),
        .nv_dirty        (nv_dirty),

        .dbg_cpu_addr    (dbg_cpu_addr),
        .dbg_cpu_as_n    (dbg_cpu_as_n),
        .dbg_unmapped    (dbg_unmapped),
        .dbg_hit         (dbg_hit),
        .dbg_wd_count    (dbg_wd_count),
        .dbg_wd_addr     (dbg_wd_addr),
        .dbg_wd_sel      (dbg_wd_sel),
        .dbg_iack_cnt    (dbg_iack_cnt),
        .dbg_ipl_seen    (dbg_ipl_seen),
        .dbg_trace       (dbg_trace),
        .dbg_rv_pk       (dbg_rv_pk),
        .dbg_ra_pk       (dbg_ra_pk),
        .dbg_ack_count   (dbg_ack_count),
        .dbg_cyc_count   (dbg_cyc_count)
    );

    // NVRAM transfers use ioctl index 2 in both directions.
    wire nv_access = (ioctl_index[7:0] == 8'd2) && (ioctl_download | ioctl_upload);
    always_comb ioctl_din = nv_dout;

    //========================================================================
    //  JSA II sound board
    //========================================================================
    wire [7:0] snd_cmd, snd_resp;
    wire       snd_cmd_wr, snd_reset, snd_int, snd_ready;
    wire signed [15:0] audio_l, audio_r;

    // $FD0000 read strobe, a g1_top port: Quartus will not resolve a
    // hierarchical read of an internal net.
    wire snd_resp_rd;

    g1_jsa2 u_jsa2
    (
        .clk                 (clk_sys),
        .rst_n               (rst_n),
        .board_reset         (snd_reset),
        .ce_6502             (ce_6502),
        .ce_ym               (ce_ym),
        .ce_oki              (ce_oki),

        .main_din            (snd_cmd),
        .main_wr             (snd_cmd_wr),
        .main_rd             (snd_resp_rd),
        .main_dout           (snd_resp),
        .main_irq            (snd_int),
        .main_to_sound_ready (snd_ready),

        // Coin and service come from the pad. Coins are active high on this
        // port, unlike the 68000-side buttons.
        //
        // self_test is the same switch as IN0 bit 14: one /SELFTEST net joins
        // JAMMA pin 15, the game PCB (AUD-29) and the JSA II's SW1 (J1-29),
        // and the 6502 reads it through inverting buffer 2F (74LS240), so it
        // is active high here. MAME reads 0 (it inverts the line twice). See
        // g1_jsa2.sv for its use.
        .coin1               (coin_left),
        .coin2               (coin_right),
        .coin3               (1'b0),
        .self_test           (~service),

        .prog_addr           (jsa_prog_addr),
        .prog_req            (jsa_prog_req),
        .prog_dout           (cpu_rom_dout),
        .prog_ack            (jsa_prog_ack),

        .oki_addr            (oki_rom_addr),
        .oki_req             (oki_rom_req),
        .oki_dout            (oki_rom_dout),
        .oki_ack             (oki_rom_ack),

        .audio_l             (audio_l),
        .audio_r             (audio_r)
    );

    //========================================================================
    //  Video
    //========================================================================
    wire [PAL_AW-1:0] pal_index;
    wire [7:0]  vid_fetch_ovr;      // overlay VFET: skipped lines last frame
    wire [11:0] vid_fetch_max;      //               longest line fetch, clk_sys
    wire dbg_al_ack, dbg_pf_ack, dbg_al_busy, dbg_pf_busy;
    wire dbg_map_nz;
    wire [15:0] dbg_map_word;
    // Declared here, ahead of the palette instance, because the video probes
    // below use them.
    wire [7:0] pal_r, pal_g, pal_b;
    wire hblank, vblank, hsync, vsync, de;
    wire [8:0] vis_x, mo_x;
    wire [7:0] vis_y, mo_y;
    wire [9:0] mo_index;

    wire [14:0] rle_vaddr;
    wire        rle_vreq, rle_vack;
    wire [15:0] rle_vdin;
    wire        rle_vwe;

    g1_video u_video
    (
        .clk            (clk_sys),
        .rst_n          (rst_n),
        .ce_pix         (ce_pix),
        .pf_xoffset     (cfg.pf_xoffset),
        .mo_enable      (~status[15]),

        .vram_addr      (vram_addr),
        .vram_dout      (vram_dout),
        .vram_din_addr  (vram_din_addr),
        .vram_din       (vram_din),
        .vram_we        (vram_we),
        .ext_vram_addr  (rle_vaddr),
        .ext_vram_req   (rle_vreq),
        .ext_vram_ack   (rle_vack),
        .ext_vram_din   (rle_vdin),
        .ext_vram_we    (rle_vwe),

        .tile_rom_addr  (tile_rom_addr),
        .tile_rom_req   (tile_rom_req),
        .tile_rom_gnt   (tile_rom_gnt),
        .dbg_fetch_overruns (vid_fetch_ovr),
        .dbg_fetch_max  (vid_fetch_max),
        .tile_rom_dout  (tile_rom_dout),
        .tile_rom_ack   (tile_rom_ack),

        .mo_x           (mo_x),
        .mo_y           (mo_y),
        .mo_index       (mo_index),

        .pal_index      (pal_index),
        .dbg_al_ack     (dbg_al_ack),
        .dbg_pf_ack     (dbg_pf_ack),
        .dbg_al_busy    (dbg_al_busy),
        .dbg_pf_busy    (dbg_pf_busy),
        .dbg_map_nz     (dbg_map_nz),
        .dbg_map_word   (dbg_map_word),

        .hblank         (hblank),
        .vblank         (vblank),
        .hsync          (hsync),
        .vsync          (vsync),
        .de             (de),
        .vblank_rise    (vblank_rise),
        .vis_x          (vis_x),
        .vis_y          (vis_y)
    );

    assign vblank_status = vblank;

    //========================================================================
    //  Motion objects
    //========================================================================
    wire prescan_busy, render_busy;
    wire [10:0] stat_valid, stat_null;
    wire [9:0]  stat_max_w;
    wire [7:0]  stat_max_h;

    g1_rle u_rle
    (
        .clk           (clk_sys),
        .rst_n         (rst_n),
        .is_pitfight   (is_pitfight),
        .obj_count     (obj_count),
        .clip_left     ({1'b0, cfg.mo_left}),
        // 9-bit clip: config byte 4 plus flags bit 2. Pit Fighter's right
        // edge (295) does not fit in a byte.
        .clip_right    ({cfg.flags[2], cfg.mo_right}),

        .ctrl          (rle_ctrl),
        .ctrl_wr       (rle_ctrl_wr),
        .cmd           (rle_cmd),
        .cmd_wr        (rle_cmd_wr),
        .objram_word0  (rle_objram_w0),

        // MAME uses vpos only through min(239, vpos) and partial = vpos, so
        // any value >= 240 is exact for all of VBLANK (vis_y reads 0 there).
        .vpos          (vblank ? 9'd240 : {1'b0, vis_y}),
        .vblank_rise   (vblank_rise),

        .vram_addr     (rle_vaddr),
        .vram_req      (rle_vreq),
        .vram_dout     (vram_dout),
        .vram_ack      (rle_vack),
        .vram_din      (rle_vdin),
        .vram_we       (rle_vwe),

        .rom_addr      (rle_rom_addr),
        .rom_req       (rle_rom_req),
        .rom_dout      (rle_rom_dout),
        .rom_ack       (rle_rom_ack),

        // The checksum accumulator spans the download: not rst_n (held for
        // the whole transfer), and only the ROM download may restart it, not
        // the config download that follows.
        .load_active   (rom_loading),
        .load_rst_n    (~dbg_clear),
        .load_addr     (ldr_addr),
        .load_data     (ldr_din),
        .load_we       (ldr_we),
        .load_complete (pf_pending),

        .disp_x        (mo_x),
        .disp_y        (mo_y),
        .disp_index    (mo_index),

        .prescan_busy  (prescan_busy),
        .render_busy   (render_busy),
        .stat_valid    (stat_valid),
        .stat_null     (stat_null),
        .stat_max_w    (stat_max_w),
        .stat_max_h    (stat_max_h)
    );

    //========================================================================
    //  Diagnostic overlay (OSD: Debug -> Diagnostic)
    //========================================================================
    // Two pages, drawn from the raster counters and bypassing the mixer and
    // the palette (which only the CPU writes), so they work even when the
    // 68000 never runs:
    //   Text      labelled hex readout (g1_dbg_text) in an opaque box
    //   Activity  full-screen per-bit stuck/toggle map of the load, SDRAM
    //             and CPU buses
    // There is no single "overlay on" flag: the pages composite differently
    // at the RGB_in mux.
    //------------------------------------------------------------------------
    wire [1:0] dbg_page = status[25:24];   // 0 Off, 1 Text, 2 Activity

    // ---- Debug capture reset ----------------------------------------------
    // Most captures clear on dbg_clear (PLL unlock) only. rst_n and rst_n_mem
    // include the RESET MiSTer pulses when a download completes, which would
    // erase them, and clearing per download would keep only the MRA's last
    // (9-byte config) download.

    // ---- ioctl download probes --------------------------------------------
    // Locate a load failure upstream of the loader:
    //   wr_count == 0             no data arrives from the HPS
    //   dl_index[5:0] != 0        data arrives under an index the loader rejects
    //   ldr_max == 0 (rest ok)    data accepted, but no SDRAM write issued
    logic  [7:0] idx_raw;        // full ioctl_index[7:0] of the first download
    logic        idx_raw_set;
    logic  [7:0] idx_seen;       // bit N set if a download used index N (low 3 bits)
    logic [15:0] dl_index;       // ioctl_index of the most recent download
    logic [23:0] wr_count;       // ioctl_wr pulses seen while downloading
    logic [15:0] ioctl_max;      // high bits of the largest ioctl_addr seen

    always_ff @(posedge clk_sys) begin
        if (dbg_clear) begin
            dl_index    <= 16'd0;
            idx_seen    <= 8'd0;
            idx_raw     <= 8'd0;
            idx_raw_set <= 1'b0;
            wr_count  <= 24'd0;
            ioctl_max <= 16'd0;
        end else begin
            // Sticky bitmap: a later download cannot overwrite it.
            if (ioctl_download && !dl_d && ioctl_index[7:0] < 8'd8)
                idx_seen[ioctl_index[2:0]] <= 1'b1;
            // Full low byte of the first download's index: idx_seen keeps only
            // the low 3 bits and cannot show an extension index in [7:6].
            if (ioctl_download && !dl_d && !idx_raw_set) begin
                idx_raw     <= ioctl_index[7:0];
                idx_raw_set <= 1'b1;
            end
            if (ioctl_download && !dl_d) dl_index <= ioctl_index;
            if (ioctl_download && ioctl_wr) begin
                wr_count <= wr_count + 1'b1;
                if (ioctl_addr[26:11] > ioctl_max) ioctl_max <= ioctl_addr[26:11];
            end
        end
    end

    // ---- Sticky flags: no reset, no gating --------------------------------
    // Resolve the ambiguous zeros above: dl_index = 0 may mean ioctl_download
    // never rose, and wr_count = 0 may mean writes arrived while it was low.
    logic dl_ever;      // ioctl_download was high at least once
    logic wr_ever;      // ioctl_wr pulsed at least once, download or not
    always_ff @(posedge clk_sys) begin
        if (ioctl_download) dl_ever <= 1'b1;
        if (ioctl_wr)       wr_ever <= 1'b1;
    end

    // ---- Stuck-at / activity accumulators ---------------------------------
    // Per bus bit, OR-accumulators of "seen low" (_0) and "seen high" (_1):
    // only _0 = stuck low, only _1 = stuck high, both = toggling. Shown on the
    // Activity page; a live hex readout of a 57 MHz bus would be unreadable.
    logic [15:0] act_ia_0, act_ia_1;   // ioctl_addr[26:11]
    logic  [7:0] act_id_0, act_id_1;   // ioctl_dout
    logic [15:0] act_la_0, act_la_1;   // ldr_addr[24:9]
    logic [15:0] act_ld_0, act_ld_1;   // ldr_din
    logic [15:0] act_sd_0, act_sd_1;   // sdr_dout  (SDRAM read data)
    logic [15:0] act_ca_0, act_ca_1;   // dbg_cpu_addr[23:8]
    logic  [7:0] act_ct_0, act_ct_1;   // control strobes

    wire [7:0] ctrl_bus = {ioctl_download, ioctl_wr, ldr_we, ldr_ack,
                           sdr_rd, sdr_we, sdr_ready, dbg_cpu_as_n};

    always_ff @(posedge clk_sys) begin
        if (dbg_clear) begin
            act_ia_0 <= '0; act_ia_1 <= '0;
            act_id_0 <= '0; act_id_1 <= '0;
            act_la_0 <= '0; act_la_1 <= '0;
            act_ld_0 <= '0; act_ld_1 <= '0;
            act_sd_0 <= '0; act_sd_1 <= '0;
            act_ca_0 <= '0; act_ca_1 <= '0;
            act_ct_0 <= '0; act_ct_1 <= '0;
        end else begin
            act_ia_0 <= act_ia_0 | ~ioctl_addr[26:11];
            act_ia_1 <= act_ia_1 |  ioctl_addr[26:11];
            act_id_0 <= act_id_0 | ~ioctl_dout;
            act_id_1 <= act_id_1 |  ioctl_dout;
            act_la_0 <= act_la_0 | ~ldr_addr[24:9];
            act_la_1 <= act_la_1 |  ldr_addr[24:9];
            act_ld_0 <= act_ld_0 | ~ldr_din;
            act_ld_1 <= act_ld_1 |  ldr_din;
            act_sd_0 <= act_sd_0 | ~sdr_dout;
            act_sd_1 <= act_sd_1 |  sdr_dout;
            act_ca_0 <= act_ca_0 | ~dbg_cpu_addr[23:8];
            act_ca_1 <= act_ca_1 |  dbg_cpu_addr[23:8];
            act_ct_0 <= act_ct_0 | ~ctrl_bus;
            act_ct_1 <= act_ct_1 |  ctrl_bus;
        end
    end

    // Activity-page block colour.
    function automatic logic [23:0] act_col(input logic s0, input logic s1);
        if (s0 && s1)      act_col = 24'h00E000;   // toggling
        else if (s1)       act_col = 24'hE00000;   // stuck high
        else               act_col = 24'h101840;   // stuck low
    endfunction

    //------------------------------------------------------------------------
    // Video pipeline probes, sticky, sampled during active video only:
    //   pal_idx_nz  the mixer produced a non-zero palette index
    //   pal_rgb_nz  the palette produced a non-zero colour
    //------------------------------------------------------------------------
    wire vid_active = (vis_x < 336) && (vis_y < 240);

    logic pal_idx_nz, pal_rgb_nz;
    always_ff @(posedge clk_sys) begin
        if (dbg_clear) begin
            pal_idx_nz <= 1'b0;
            pal_rgb_nz <= 1'b0;
        end else if (vid_active) begin
            if (pal_index != '0)                 pal_idx_nz <= 1'b1;
            if ({pal_r, pal_g, pal_b} != 24'd0)  pal_rgb_nz <= 1'b1;
        end
    end

    //------------------------------------------------------------------------
    // Palette write count, and the largest palette index the mixer produced.
    // The palette has 1280 entries but PAL_AW is 11 bits, so an index >= 1280
    // silently reads zero.
    //------------------------------------------------------------------------
    logic [15:0] pal_wr_count;
    logic [10:0] pal_idx_max;
    always_ff @(posedge clk_sys) begin
        if (dbg_clear) begin
            pal_wr_count <= 16'd0;
            pal_idx_max  <= 11'd0;
        end else begin
            if (pal_wr_hi || pal_wr_lo) pal_wr_count <= pal_wr_count + 1'b1;
            if (vid_active && pal_index > pal_idx_max) pal_idx_max <= pal_index;
        end
    end

    //------------------------------------------------------------------------
    // Brightness probes. rgb_count cannot tell nearly-black pixels from
    // visible ones (palette $0001 decodes to RGB 0,0,8), so also record the
    // largest channel value (pal_max) and the pixels with any channel above
    // $1F (bright_count), per frame.
    //------------------------------------------------------------------------
    logic [7:0]  pal_max, pal_max_l;
    logic [16:0] bright_cnt, bright_count;

    wire [7:0] chan_max = (pal_r > pal_g)
                            ? ((pal_r > pal_b) ? pal_r : pal_b)
                            : ((pal_g > pal_b) ? pal_g : pal_b);
    wire       is_bright = (chan_max > 8'h1F);

    //------------------------------------------------------------------------
    // Per-layer pixel counts. The palette base identifies the layer that won
    // each pixel, so no probes inside the video modules are needed:
    //
    //     PAL_BASE_ALPHA $100   pal_index[9:8] == 01
    //     PAL_BASE_MO    $200   pal_index[9:8] == 10
    //     PAL_BASE_PF    $300   pal_index[9:8] == 11
    //------------------------------------------------------------------------
    logic [16:0] al_cnt, mo_cnt, pf_cnt;
    logic [16:0] al_count, mo_count, pf_count;

    //------------------------------------------------------------------------
    // Alpha pixels with al_pixel == 0, visible only through the opaque flag.
    // The mixer's test is al_visible = (al_pixel != 0) || al_opaque, and it
    // builds pal_index as PAL_BASE_ALPHA + {al_color, al_pixel}, so
    // pal_index[3:0] is al_pixel. The opaque flag is tile data[15], which is
    // also the top bit of the colour field (as in MAME).
    //------------------------------------------------------------------------
    logic [16:0] al_p0_cnt, al_p0_count;

    // Tile-channel grant counters and fetcher-busy stuck-at flags (see the
    // dbg_* ports in g1_video.sv).
    logic [15:0] al_ack_cnt, pf_ack_cnt;
    logic [15:0] map_nz_cnt;      // alpha map words with a non-zero code
    logic [15:0] map_word_seen;   // last non-zero map word read
    logic        albusy_s0, albusy_s1, pfbusy_s0, pfbusy_s1;
    always_ff @(posedge clk_sys) begin
        if (dbg_clear) begin
            al_ack_cnt <= '0;  pf_ack_cnt <= '0;
            map_nz_cnt <= '0;  map_word_seen <= '0;
            albusy_s0 <= 1'b0; albusy_s1 <= 1'b0;
            pfbusy_s0 <= 1'b0; pfbusy_s1 <= 1'b0;
        end else begin
            if (dbg_al_ack) al_ack_cnt <= al_ack_cnt + 1'b1;
            if (dbg_map_nz) map_nz_cnt <= map_nz_cnt + 1'b1;
            if (dbg_map_word != 16'd0) map_word_seen <= dbg_map_word;
            if (dbg_pf_ack) pf_ack_cnt <= pf_ack_cnt + 1'b1;
            albusy_s0 <= albusy_s0 | ~dbg_al_busy;
            albusy_s1 <= albusy_s1 |  dbg_al_busy;
            pfbusy_s0 <= pfbusy_s0 | ~dbg_pf_busy;
            pfbusy_s1 <= pfbusy_s1 |  dbg_pf_busy;
        end
    end

    // Per-frame counts over active video, latched at the end of line 239 (a
    // full 336x240 frame is 80,640 pixels): idx_count = non-zero palette
    // index, rgb_count = non-zero colour, plus the brightness, per-layer and
    // alpha counts above.
    logic [16:0] idx_cnt, rgb_cnt, idx_count, rgb_count;
    logic vblank_d;
    always_ff @(posedge clk_sys) begin
        vblank_d <= vid_active;

        if (vid_active) begin
            if (pal_index != '0)                idx_cnt <= idx_cnt + 1'b1;
            if ({pal_r, pal_g, pal_b} != 24'd0) rgb_cnt <= rgb_cnt + 1'b1;
            if (is_bright)                      bright_cnt <= bright_cnt + 1'b1;
            if (chan_max > pal_max)             pal_max <= chan_max;

            if (pal_index[9:8] == 2'b01 && pal_index[3:0] == 4'd0)
                al_p0_cnt <= al_p0_cnt + 1'b1;

            case (pal_index[9:8])
                2'b01: al_cnt <= al_cnt + 1'b1;
                2'b10: mo_cnt <= mo_cnt + 1'b1;
                2'b11: pf_cnt <= pf_cnt + 1'b1;
                default: ;
            endcase
        end

        // End of the last active line: latch and restart.
        if (vblank_d && !vid_active && vis_y == 8'd239) begin
            idx_count    <= idx_cnt;
            rgb_count    <= rgb_cnt;
            bright_count <= bright_cnt;
            pal_max_l    <= pal_max;
            idx_cnt      <= '0;
            rgb_cnt      <= '0;
            bright_cnt   <= '0;
            pal_max      <= '0;
            al_count     <= al_cnt;
            mo_count     <= mo_cnt;
            pf_count     <= pf_cnt;
            al_p0_count  <= al_p0_cnt;
            al_cnt       <= '0;
            mo_cnt       <= '0;
            pf_cnt       <= '0;
            al_p0_cnt    <= '0;
        end
    end

    // Boot-progress flags, MSB first:
    //   7 dl_ever       ioctl_download ever asserted
    //   6 wr_ever       ioctl_wr ever pulsed (ungated)
    //   5 cfg_valid     the MRA config blob (index 1) was captured
    //   4 rom_loaded    the loader saw the ROM download finish
    //   3 first_bad_set the CPU touched unmapped space
    //   2 cpu_ever_ran  the CPU executed at least one bus cycle
    //   1 pal_idx_nz    the mixer produced a non-zero palette index
    //   0 pal_rgb_nz    the palette produced a non-zero colour
    //
    // mem_rst_in_dl: rst_n_mem was low at some point during a download.
    logic mem_rst_in_dl;
    always_ff @(posedge clk_sys) begin
        if (dbg_clear)                        mem_rst_in_dl <= 1'b0;
        else if (ioctl_download && !rst_n_mem) mem_rst_in_dl <= 1'b1;
    end

    wire [7:0] dbg_flags = {dl_ever, wr_ever, cfg_valid, rom_loaded,
                            first_bad_set, cpu_ever_ran,
                            pal_idx_nz, pal_rgb_nz};

    // ---- Reset vector, captured from the loader's write stream ------------
    // SDR_PROG is at $000000, so the first four words written are the 68000
    // reset vector: SSP high, SSP low, PC high, PC low. This checks the MRA's
    // byte interleave independently of the SDRAM read path: a good Hydra image
    // gives an SSP in work RAM ($FFxxxx) and a PC in ROM; swapped bytes mean
    // the MRA's map="01"/map="10" pair is reversed.
    //
    // rv_seen marks which words were captured, so an all-zero row is not
    // ambiguous; ldr_max and first_nz summarise the whole load.
    logic [15:0] rv0, rv1, rv2, rv3;
    logic [3:0]  rv_seen;        // one bit per vector word actually captured
    logic [11:0] ldr_max;        // highest loader address seen, bits 24..13
    logic [24:0] first_nz;       // first loader address carrying non-zero data
    logic        first_nz_set;

    always_ff @(posedge clk_sys) begin
        if (dbg_clear) begin
            rv0 <= 16'd0; rv1 <= 16'd0; rv2 <= 16'd0; rv3 <= 16'd0;
            rv_seen      <= 4'd0;
            ldr_max      <= 12'd0;
            first_nz     <= 25'd0;
            first_nz_set <= 1'b0;
        end else if (loading && ldr_we) begin
            if (ldr_addr < 25'd8) begin
                case (ldr_addr[2:1])
                    2'd0: begin rv0 <= ldr_din; rv_seen[0] <= 1'b1; end
                    2'd1: begin rv1 <= ldr_din; rv_seen[1] <= 1'b1; end
                    2'd2: begin rv2 <= ldr_din; rv_seen[2] <= 1'b1; end
                    2'd3: begin rv3 <= ldr_din; rv_seen[3] <= 1'b1; end
                endcase
            end
            if (ldr_addr[24:13] > ldr_max) ldr_max <= ldr_addr[24:13];
            if (ldr_din != 16'd0 && !first_nz_set) begin
                first_nz     <= ldr_addr;
                first_nz_set <= 1'b1;
            end
        end
    end

    // ---- First unmapped address the CPU touched ---------------------------
    logic [23:0] first_bad;
    logic        first_bad_set;
    always_ff @(posedge clk_sys) begin
        if (dbg_clear) begin
            first_bad     <= '0;
            first_bad_set <= 1'b0;
        end else if (dbg_unmapped && !first_bad_set) begin
            first_bad     <= {dbg_cpu_addr, 1'b0};
            first_bad_set <= 1'b1;
        end
    end

    // Count completed 68000 bus cycles (falling edge of /AS).
    logic dbg_as_d;
    logic [23:0] cpu_cycles;
    always_ff @(posedge clk_sys) begin
        if (!rst_n) begin
            dbg_as_d   <= 1'b1;
            cpu_cycles <= '0;
        end else begin
            dbg_as_d <= dbg_cpu_as_n;
            if (dbg_as_d && !dbg_cpu_as_n) cpu_cycles <= cpu_cycles + 1'b1;
        end
    end

    // Cleared only by dbg_clear, so it survives watchdog resets of the CPU.
    logic cpu_ever_ran;
    always_ff @(posedge clk_sys) begin
        if (dbg_clear) begin
            cpu_ever_ran  <= 1'b0;
        end else begin
            if (cpu_cycles != 0) cpu_ever_ran <= 1'b1;
        end
    end

    // ---- Activity page block geometry -------------------------------------
    // dbg_bar: 8 columns of 42 px across the 336-pixel line.
    logic [2:0] dbg_bar;
    always_comb begin
        if      (vis_x < 42)  dbg_bar = 3'd0;
        else if (vis_x < 84)  dbg_bar = 3'd1;
        else if (vis_x < 126) dbg_bar = 3'd2;
        else if (vis_x < 168) dbg_bar = 3'd3;
        else if (vis_x < 210) dbg_bar = 3'd4;
        else if (vis_x < 252) dbg_bar = 3'd5;
        else if (vis_x < 294) dbg_bar = 3'd6;
        else                  dbg_bar = 3'd7;
    end

    // Block index for each field width. All tile 336 exactly:
    //   4 x 84 = 336, 12 x 28 = 336, 16 x 21 = 336, 24 x 14 = 336
    logic [4:0] bit4, bit12, bit16, bit24;
    always_comb begin
        bit4 = 5'd0; bit12 = 5'd0; bit16 = 5'd0; bit24 = 5'd0;
        for (int i = 0; i <  4; i++)
            if (vis_x >= i*84 && vis_x < (i+1)*84) bit4  = 5'(i);
        for (int i = 0; i < 12; i++)
            if (vis_x >= i*28 && vis_x < (i+1)*28) bit12 = 5'(i);
        for (int i = 0; i < 16; i++)
            if (vis_x >= i*21 && vis_x < (i+1)*21) bit16 = 5'(i);
        for (int i = 0; i < 24; i++)
            if (vis_x >= i*14 && vis_x < (i+1)*14) bit24 = 5'(i);
    end

    //------------------------------------------------------------------------
    // Text page: labelled hex readout, modelled on the Atari GT core's
    // overlay. Row order must match the LABELS table in g1_dbg_text.sv.
    //------------------------------------------------------------------------
    // Health counters:
    // MOGO  DDD00MMM  DDD = MOGO writes that found the sprite engine still
    //                       busy (that frame's sprites were not redrawn),
    //                       since reset
    //                 MMM = longest render since reset, in units of 4,096
    //                       clk_sys (71.5 us); a frame is $0E9
    // SND   RRRWWWLL  RRR = sound responses the 68000 has read, WWW = sound
    //                       commands it has written, LL = the last response.
    //                       Pit Fighter asks for the coin count ($03) every
    //                       frame, so both counters climb at ~60/s and LL is
    //                       the 6502's coin total.
    logic        mogo_prev;
    logic [11:0] mogo_drops;
    logic [11:0] rnd_units, rnd_max;
    logic [11:0] rnd_sub;
    logic [11:0] snd_rd_cnt, snd_wr_cnt;
    logic [7:0]  snd_last;
    logic        snd_cmd_wr_d;   // snd_cmd_wr can last several clocks per
                                 // write; count its rising edge
    always_ff @(posedge clk_sys) begin
        if (!rst_n) begin
            mogo_prev  <= 1'b0;
            mogo_drops <= '0;
            rnd_units  <= '0;
            rnd_max    <= '0;
            rnd_sub    <= '0;
            snd_rd_cnt <= '0;
            snd_wr_cnt <= '0;
            snd_last   <= '0;
            snd_cmd_wr_d <= 1'b0;
        end
        else begin
            if (rle_ctrl_wr) begin
                mogo_prev <= rle_ctrl[0];
                if (rle_ctrl[0] && !mogo_prev && render_busy && mogo_drops != 12'hFFF)
                    mogo_drops <= mogo_drops + 1'b1;
            end
            if (render_busy) begin
                rnd_sub <= rnd_sub + 1'b1;
                if (rnd_sub == 12'hFFF && rnd_units != 12'hFFF) rnd_units <= rnd_units + 1'b1;
            end
            else begin
                rnd_sub   <= '0;
                rnd_units <= '0;
                if (rnd_units > rnd_max) rnd_max <= rnd_units;
            end
            if (snd_resp_rd) begin
                snd_rd_cnt <= snd_rd_cnt + 1'b1;
                snd_last   <= snd_resp;
            end
            snd_cmd_wr_d <= snd_cmd_wr;
            if (snd_cmd_wr && !snd_cmd_wr_d) snd_wr_cnt <= snd_wr_cnt + 1'b1;
        end
    end

    //------------------------------------------------------------------------
    // BLD row: compile date YYMMDD then the three-digit G1_BUILD (g1_pkg.sv),
    // all BCD so they read as decimal, e.g. 260923108.
    //
    // Decoded from `BUILD_DATE, the "YYMMDD" string in build_id.v: each
    // character is an ASCII digit whose low nibble is the BCD digit.
    //------------------------------------------------------------------------
    localparam [47:0] BLD_DATE_ASCII = `BUILD_DATE;
    localparam [23:0] BLD_DATE_BCD   = {BLD_DATE_ASCII[43:40], BLD_DATE_ASCII[35:32],
                                        BLD_DATE_ASCII[27:24], BLD_DATE_ASCII[19:16],
                                        BLD_DATE_ASCII[11:8],  BLD_DATE_ASCII[3:0]};
    localparam [3:0]  BLD_H = (G1_BUILD / 100) % 10;
    localparam [3:0]  BLD_T = (G1_BUILD / 10)  % 10;
    localparam [3:0]  BLD_O =  G1_BUILD        % 10;
    localparam [35:0] BLD_BCD = {BLD_DATE_BCD, BLD_H, BLD_T, BLD_O};

    localparam int DBG_ROWS = 20;
    wire [32*DBG_ROWS-1:0] dbg_vals = {
        BLD_BCD[31:0]                                 , // BLD (ninth digit via row0_msn)
        {8'd0, dbg_cpu_addr, 1'b0}                    , // PC
        {16'd0, dbg_wd_count}                         , // WDOG
        {16'd0, pal_wr_count}                         , // PALW
        st_sum_w                                      , // SUMW
        st_sum_r                                      , // SUM2
        st_rep_err                                    , // REPE
        {16'd0, st_rep_ref}                           , // REPV
        {16'd0, st_sw_err[16*0 +: 16]}                , // S0
        {16'd0, st_sw_err[16*1 +: 16]}                , // S1
        {16'd0, st_sw_err[16*2 +: 16]}                , // S2
        {16'd0, st_sw_err[16*3 +: 16]}                , // S3
        {16'd0, st_sw_err[16*4 +: 16]}                , // S4
        {16'd0, st_sw_err[16*5 +: 16]}                , // S5
        {16'd0, st_sw_err[16*6 +: 16]}                , // S6
        {16'd0, st_sw_err[16*7 +: 16]}                , // S7
        // PHAS  0000ACMU  U = setting in use (S-row number), M = OSD manual
        //                 setting, C = 1 if the sweep's best setting read all
        //                 4,096 truth words correctly, A = 1 Auto / 0 Manual,
        //                 plus 8 when Self-test bus is Exclusive
        {16'd0, status[21], 2'd0, cap_auto, 3'd0, st_best_clean,
                1'b0, cap_manual, 1'b0, cap_sel}          ,
        // VFET  00OO0MMM  OO = scanlines whose tile fetch overran last frame
        //                 (each shows the line above it twice), MMM = longest
        //                 line fetch in clk_sys; the budget is $E40
        {8'd0, vid_fetch_ovr, 4'd0, vid_fetch_max}      , // VFET
        {mogo_drops, 8'd0, rnd_max}                     , // MOGO
        {snd_rd_cnt, snd_wr_cnt, snd_last}                // SND
    };

    wire dbg_txt_pix, dbg_txt_box;
    g1_dbg_text #(.N_ROWS(DBG_ROWS)) u_dbg_text
    (
        .clk     (clk_sys),
        .vis_x   (vis_x),
        .vis_y   (vis_y),
        .vals    (dbg_vals),
        .row0_msn(BLD_BCD[35:32]),
        .pix     (dbg_txt_pix),
        .in_box  (dbg_txt_box)
    );

    // Overlay colour for the selected page.
    logic [23:0] dbg_rgb;

    //------------------------------------------------------------------------
    // Registered overlay output. Unregistered, the paths from the raster
    // counters through the overlay to arcade_video's RGB_fix fail setup.
    // g1_dbg_text registers its own outputs; this register cuts the Activity
    // page's vis_y compare ladder, which is timed whichever page is selected.
    // The box select is registered with the data so the panel edge stays
    // aligned.
    //------------------------------------------------------------------------
    logic [23:0] dbg_rgb_r;
    logic        dbg_box_r;
    always_ff @(posedge clk_sys) begin
        dbg_rgb_r <= dbg_rgb;
        dbg_box_r <= dbg_txt_box;
    end

    // ------------------------------------------------------------------
    //  Activity page: one block per bus bit, MSB left (blue = stuck low,
    //  red = stuck high, green = toggling). Rows are in dataflow order, so
    //  the first solid-blue row locates a break:
    //
    //    0- 27  ioctl_addr[26:11]   HPS download address
    //   32- 59  ioctl_dout[7:0]     HPS download data
    //   64- 91  ldr_addr[24:9]      loader -> SDRAM address
    //   96-123  ldr_din[15:0]       loader -> SDRAM data
    //  128-155  sdr_dout[15:0]      SDRAM read data
    //  160-187  dbg_cpu_addr[23:8]  68000 address bus
    //  192-219  control             dl, wr, ldr_we, ldr_ack, sdr_rd, sdr_we,
    //                               sdr_ready, cpu_as_n
    //  224-239  green once the CPU has run
    //
    //  Full screen: the per-bit bars need the whole width.
    // ------------------------------------------------------------------
    always_comb begin
        if (dbg_page == 2'd2) begin
            if      (vis_y <  28)                 dbg_rgb = act_col(act_ia_0[15-bit16[3:0]], act_ia_1[15-bit16[3:0]]);
            else if (vis_y >=  32 && vis_y <  60) dbg_rgb = act_col(act_id_0[7-dbg_bar],     act_id_1[7-dbg_bar]);
            else if (vis_y >=  64 && vis_y <  92) dbg_rgb = act_col(act_la_0[15-bit16[3:0]], act_la_1[15-bit16[3:0]]);
            else if (vis_y >=  96 && vis_y < 124) dbg_rgb = act_col(act_ld_0[15-bit16[3:0]], act_ld_1[15-bit16[3:0]]);
            else if (vis_y >= 128 && vis_y < 156) dbg_rgb = act_col(act_sd_0[15-bit16[3:0]], act_sd_1[15-bit16[3:0]]);
            else if (vis_y >= 160 && vis_y < 188) dbg_rgb = act_col(act_ca_0[15-bit16[3:0]], act_ca_1[15-bit16[3:0]]);
            else if (vis_y >= 192 && vis_y < 220) dbg_rgb = act_col(act_ct_0[7-dbg_bar],     act_ct_1[7-dbg_bar]);
            else if (vis_y >= 224)                dbg_rgb = cpu_ever_ran ? 24'h00C000 : 24'h400000;
            else                                  dbg_rgb = 24'h000000;
        end
        else begin
            // Text page: white glyphs on an opaque black box. RGB_in selects
            // on the box, so the game shows undimmed everywhere else.
            dbg_rgb = dbg_txt_pix ? 24'hFFFFFF : 24'h000000;
        end
    end

    //========================================================================
    //  Palette and video output
    //========================================================================

    g1_palette u_palette
    (
        .clk       (clk_sys),
        .cpu_addr  (pal_addr),
        .cpu_din   (pal_din),
        .cpu_wr_hi (pal_wr_hi),
        .cpu_wr_lo (pal_wr_lo),
        .cpu_dout  (pal_dout),
        .vid_index (pal_index),
        .vid_r     (pal_r),
        .vid_g     (pal_g),
        .vid_b     (pal_b),
        .vid_raw   ()
    );

    // The mixer registers its output and the palette adds two clocks, so
    // blanking and sync are delayed three pixels to match; otherwise the
    // picture shifts right and loses pixels at the end of each line.
    localparam int VID_DELAY = 3;
    logic [VID_DELAY-1:0] hb_dly, vb_dly, hs_dly, vs_dly;

    always_ff @(posedge clk_sys) begin
        if (ce_pix) begin
            hb_dly <= {hb_dly[VID_DELAY-2:0], hblank};
            vb_dly <= {vb_dly[VID_DELAY-2:0], vblank};
            hs_dly <= {hs_dly[VID_DELAY-2:0], hsync};
            vs_dly <= {vs_dly[VID_DELAY-2:0], vsync};
        end
    end

    arcade_video #(.WIDTH(H_VISIBLE), .DW(24)) u_arcade_video
    (
        .clk_video (clk_sys),
        .ce_pix    (ce_pix),
        // Overlay compositing: the Activity page is full screen; the Text
        // panel is opaque inside its box, with the game at full brightness
        // elsewhere (dimming would make colour faults look like overlay ones).
        .RGB_in    ((dbg_page == 2'd2) ? dbg_rgb_r                     // full
                  : (dbg_page == 2'd1 && dbg_box_r) ? dbg_rgb_r        // panel
                  : {pal_r, pal_g, pal_b}),                            // game
        .HBlank    (hb_dly[VID_DELAY-1]),
        .VBlank    (vb_dly[VID_DELAY-1]),
        .HSync     (hs_dly[VID_DELAY-1]),
        .VSync     (vs_dly[VID_DELAY-1]),
        .CLK_VIDEO (CLK_VIDEO),
        .CE_PIXEL  (CE_PIXEL),
        .VGA_R     (VGA_R),
        .VGA_G     (VGA_G),
        .VGA_B     (VGA_B),
        .VGA_HS    (VGA_HS),
        .VGA_VS    (VGA_VS),
        .VGA_DE    (VGA_DE),
        .VGA_SL    (VGA_SL),
        .fx                 (status[4:2]),
        .forced_scandoubler (forced_scandoubler),
        .gamma_bus          (gamma_bus)
    );

    //========================================================================
    //  Audio
    //========================================================================
    assign AUDIO_L   = audio_l;
    assign AUDIO_R   = audio_r;
    assign AUDIO_S   = 1'b1;   // JSA II output is signed
    assign AUDIO_MIX = 2'd0;   // the board is mono; no stereo mix to apply

    //========================================================================
    //  Activity LED
    //========================================================================
    // On during the download, the SDRAM self-test and the RLE prescan; then
    // off if the self-test passed, fast blink if it failed. Stuck on means one
    // of those three never finished.
    logic [24:0] blink;
    always_ff @(posedge clk_sys) blink <= blink + 1'b1;

    assign LED_USER = loading | st_busy | prescan_busy
                    | (st_ran & ~st_result & blink[22]);

endmodule
