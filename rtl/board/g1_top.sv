//============================================================================
//  Atari G1 for MiSTer
//  g1_top.sv -- A047896-01 main board: 68000, memory map, interrupts, bus
//
//  The 68000 (fx68k) with program ROM behind the Slapstic (fetched from SDRAM
//  through the arbiter), work RAM, palette write port, EEPROM, watchdog,
//  input ports and the Hydra ADC, plus the register interfaces to the RLE
//  object engine and the JSA II sound board. Follows MAME atarig1.cpp.
//
//  Interrupts: IRQ1 = VBLANK (acknowledged by a write to $FB0000), IRQ2 =
//  JSA II. The acknowledge cycle is ended with DTACK and an explicit vector.
//
//  The dbg_* outputs are sticky diagnostic probes shown by the OSD overlay.
//
//  Clock domain: clk_sys, gated by clock enables from g1_ce.
//============================================================================

`default_nettype none

module g1_top
    import g1_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    // ---- Clock enables ----------------------------------------------------
    input  wire         ce_cpu_p1,
    input  wire         ce_cpu_p2,
    input  wire         ce_pix,

    // ---- Configuration from the MRA ---------------------------------------
    input  g1_cfg_t     cfg,
    input  wire         disable_wd,      // OSD: watchdog off

    // Clears the sticky diagnostic probes. Pulsed at the start of a ROM
    // download so they describe the currently loaded game.
    input  wire         dbg_clr,

    // Re-arms only the ROM read probes (dbg_rv_pk / dbg_ra_pk): pulsed on a
    // PLL unlock or an OSD change of the SDRAM read phase.
    input  wire         rd_probe_rearm,
    input  wire         force_bootleg,   // OSD: bypass the Slapstic (plain ROM window)

    // ---- Video timing (from g1_video_timing) ------------------------------
    input  wire         vblank_rise,

    // ---- Inputs -----------------------------------------------------------
    input  wire [15:0]  in0,
    input  wire [15:0]  in1,
    input  wire [7:0]   adc_data,        // Hydra: selected ADC channel value
    input  wire         adc_eoc,         // ADC end-of-conversion
    output logic [1:0]  adc_chan_sel,
    output logic        adc_start,

    // ---- Program ROM fetch (via the SDRAM arbiter) ------------------------
    output logic [24:0] rom_addr,        // SDRAM byte address
    output logic        rom_req,         // held until rom_ack
    input  wire [15:0]  rom_dout,
    input  wire         rom_ack,

    // ---- Palette (lives in the top level, shared with video scan-out) -----
    output logic [10:0] pal_addr,
    output logic [15:0] pal_din,
    output logic        pal_wr_hi,
    output logic        pal_wr_lo,
    input  wire [15:0]  pal_dout,

    // ---- Work RAM video / engine port -------------------------------------
    // vram_snoop_addr / dout: read-only port B. vram_snoop_din_addr / din / we:
    // CHECKSUM write-back, sharing the CPU write port.
    input  wire [14:0]  vram_snoop_addr,
    input  wire [14:0]  vram_snoop_din_addr,
    input  wire [15:0]  vram_snoop_din,
    input  wire         vram_snoop_we,
    output logic [15:0] vram_snoop_dout,

    // ---- Sound board ------------------------------------------------------
    output logic [7:0]  snd_cmd,         // $F90000 command byte
    output logic        snd_cmd_wr,      // one clock per command write
    output logic        snd_reset,       // high during a write to $F98000
    // One-clock strobe: the 68000 has read the response latch at $FD0000
    // (the latch lives on the sound side).
    output logic        snd_resp_rd,
    input  wire [7:0]   snd_resp,
    input  wire         snd_int,         // JSA II -> 68000 IRQ2
    input  wire         snd_ready,       // main-to-sound latch full, IN0 bit 12

    // ---- RLE engine interface ---------------------------------------------
    output logic [2:0]  rle_ctrl,        // $FA0001 {FRAME, ERASE, MOGO}
    output logic        rle_ctrl_wr,
    // MO command latch at $FF2000. It is ordinary work RAM that the video
    // hardware snoops, so it is captured from CPU writes, not decoded.
    output logic [15:0] rle_cmd,
    output logic        rle_cmd_wr,      // high while $FF2000 is written
    // Work RAM word 0: the number of checksums the CHECKSUM command computes.
    output logic [15:0] rle_objram_w0,

    // ---- NVRAM (EEPROM save / load) ---------------------------------------
    input  wire         nv_active,
    input  wire [10:0]  nv_addr,
    input  wire [7:0]   nv_din,
    input  wire         nv_wr,
    output logic [7:0]  nv_dout,
    output logic        nv_dirty,

    // ---- Debug ------------------------------------------------------------
    // All probes below are sticky: cleared only by dbg_clr, never by reset,
    // so they survive the watchdog resetting the CPU during a failed boot.
    output logic [23:1] dbg_cpu_addr,
    output logic        dbg_cpu_as_n,
    output logic        dbg_unmapped,    // access to unmapped space

    // Boot progress: each bit latches the first time the 68000 touches a
    // region, showing how far into startup the game gets.
    //   7 palette write    6 watchdog kick    5 IRQ ack ($FB0000)
    //   4 RLE control      3 sound command    2 EEPROM
    //   1 IN0 read         0 work RAM
    output logic [7:0]  dbg_hit,

    output logic [15:0] dbg_wd_count,    // watchdog resets

    // Last bus cycle before the watchdog fired: its address, and the region it
    // decoded to {snd_resp, eeprom, in1_adc, rom}, which separates a stalled
    // I/O wait from a loop in ROM.
    output logic [23:1] dbg_wd_addr,
    output logic  [3:0] dbg_wd_sel,

    // IACK cycles detected, and a bitmap of every IPL level presented (bit N =
    // level N; only levels 0-2 can be encoded).
    output logic [15:0] dbg_iack_cnt,
    output logic  [7:0] dbg_ipl_seen,

    // Addresses of the last eight bus cycles, frozen when the CPU fetches the
    // halt handler at $000300 (stop #$2700) that the processor exception
    // vectors lead to. Entry i is at bits [23*i +: 23]; entry 0 is the oldest,
    // entry 7 the fetch of $000300.
    // Packed because Quartus 17.0 Lite crashes in quartus_map on unpacked
    // array ports; the other multi-entry probes are packed the same way.
    output logic [8*23-1:0] dbg_trace,

    // The first four ROM words delivered to the CPU after dbg_clr or a re-arm,
    // i.e. the reset vector: expected $00FF, $FFFE, $0000, $0408 (SSP, PC).
    // Word i at bits [16*i +: 16].
    output logic [63:0] dbg_rv_pk,

    // Byte addresses of those four reads, 24 bits each.
    output logic [95:0] dbg_ra_pk,
    output logic [15:0] dbg_ack_count,   // ROM acknowledges
    output logic [15:0] dbg_cyc_count    // bus cycles that selected ROM
);

    //========================================================================
    //  68000
    //========================================================================
    wire [23:1] cpu_a;
    wire [15:0] cpu_do;
    logic [15:0] cpu_di;
    wire        cpu_rw_n, cpu_as_n, cpu_uds_n, cpu_lds_n;
    wire        cpu_e, cpu_vma_n;
    wire [2:0]  cpu_fc;
    logic       cpu_dtack_n;
    wire        cpu_bg_n;

    // Interrupt levels (vectors supplied by iack_vector below):
    //   IRQ1 -- VBLANK, cleared by a write to $FB0000
    //   IRQ2 -- JSA II sound board
    logic irq1;
    wire  irq2 = snd_int;

    // Registered: the combinational encoding glitches to 3 on a 2->1 change.
    // fx68k samples IPL asynchronously and needs it stable across successive
    // samples, so a transient level can disturb interrupt recognition.
    logic [2:0] ipl;
    always_ff @(posedge clk)
        ipl <= irq2 ? 3'd2 : (irq1 ? 3'd1 : 3'd0);

    // Interrupt acknowledge cycle: FC = 111 while AS is asserted. The AS term
    // is required: is_iack overrides the read data (cpu_di) and suppresses all
    // decoder selects, and FC can read 111 outside a bus cycle. Without it,
    // iack_vector can replace ROM data, e.g. during the reset vector fetch.
    wire       is_iack = (cpu_fc == 3'b111) && !cpu_as_n;

    // Interrupt vector, driven on the data bus and acknowledged with DTACK
    // instead of asserting VPAn. VPAn autovectoring is a slow E/VMA-synchronous
    // 6800-style cycle; with DTACK withheld it did not terminate on hardware.
    // The CPU puts the level on A3..A1 and the autovector number is
    // 24 + level = {5'b00011, level}: 25 ($64) for VBLANK, 26 ($68) for JSA II.
    wire [15:0] iack_vector = {8'h00, 5'b00011, cpu_a[3:1]};

    fx68k u_cpu (
        .clk        (clk),
        .extReset   (!rst_n || wd_reset),
        .pwrUp      (!rst_n),
        .enPhi1     (ce_cpu_p1),
        .enPhi2     (ce_cpu_p2),

        .eab        (cpu_a),
        .oEdb       (cpu_do),
        .iEdb       (cpu_di),

        .eRWn       (cpu_rw_n),
        .ASn        (cpu_as_n),
        .LDSn       (cpu_lds_n),
        .UDSn       (cpu_uds_n),
        .E          (cpu_e),
        .VMAn       (cpu_vma_n),
        .FC0        (cpu_fc[0]),
        .FC1        (cpu_fc[1]),
        .FC2        (cpu_fc[2]),

        .BGn        (cpu_bg_n),
        .oRESETn    (),
        .oHALTEDn   (),

        .VPAn       (1'b1),            // unused: vector driven on the data bus
        .DTACKn     (cpu_dtack_n),
        .BERRn      (1'b1),
        .HALTn      (1'b1),
        .BRn        (1'b1),
        .BGACKn     (1'b1),

        .IPL0n      (~ipl[0]),
        .IPL1n      (~ipl[1]),
        .IPL2n      (~ipl[2])
    );

    assign dbg_cpu_addr = cpu_a;
    assign dbg_cpu_as_n = cpu_as_n;

    //========================================================================
    //  Slapstic
    //========================================================================
    // The Slapstic sees every bus cycle, not just those in its window: types
    // 111-118 accept two unlock-sequence steps at any address (see
    // g1_slapstic.sv). acc_strobe is one clock per bus cycle, on the falling
    // edge of AS, so the address is stable and each cycle counts once.
    logic cpu_as_n_d;
    always_ff @(posedge clk) cpu_as_n_d <= cpu_as_n;
    wire acc_strobe = cpu_as_n_d && !cpu_as_n;   // AS falling edge

    wire [1:0] slap_bank;
    wire [7:0] slap_type = force_bootleg ? 8'd0 : cfg.slap_type;

    // No Slapstic on the two Hydra prototypes and the bootleg: the window is a
    // plain unbanked ROM read.
    wire slap_present = (cfg.slap_type != 8'd0) && !force_bootleg;

    g1_slapstic u_slapstic (
        .clk          (clk),
        .rst_n        (rst_n),
        .chip_type    (slap_type),
        .window_base  (cfg.slap_base),
        .cpu_addr     ({cpu_a, 1'b0}),
        .acc_strobe   (acc_strobe),
        .bank         (slap_bank),
        .bank_changed ()
    );

    //========================================================================
    //  Address decode
    //========================================================================
    wire sel_rom, sel_ram, sel_palette, sel_eeprom, sel_eeprom_unlock;
    wire sel_watchdog, sel_snd_cmd, sel_snd_reset, sel_snd_resp;
    wire sel_rle_ctrl, sel_irq_ack, sel_in0, sel_in1_adc, sel_unmapped;
    wire [18:1] dec_rom_addr;
    wire [15:1] dec_ram_addr;
    wire [10:0] dec_pal_addr, dec_eeprom_addr;
    wire [1:0]  dec_adc_chan;
    wire        in_slap_window;

    g1_addr_decode u_decode (
        .addr              (cpu_a),
        // No selects during IACK: it drives A23-A4 high, which decodes as work
        // RAM and would drive the data bus during the acknowledge.
        .as_n              (cpu_as_n | is_iack),
        .rw_n              (cpu_rw_n),
        .uds_n             (cpu_uds_n),
        .lds_n             (cpu_lds_n),

        .slap_base         (cfg.slap_base),
        .slap_en           (slap_present),
        .slap_bank         (slap_bank),

        .sel_rom           (sel_rom),
        .sel_ram           (sel_ram),
        .sel_palette       (sel_palette),
        .sel_eeprom        (sel_eeprom),
        .sel_eeprom_unlock (sel_eeprom_unlock),
        .sel_watchdog      (sel_watchdog),
        .sel_snd_cmd       (sel_snd_cmd),
        .sel_snd_reset     (sel_snd_reset),
        .sel_snd_resp      (sel_snd_resp),
        .sel_rle_ctrl      (sel_rle_ctrl),
        .sel_irq_ack       (sel_irq_ack),
        .sel_in0           (sel_in0),
        .sel_in1_adc       (sel_in1_adc),
        .sel_unmapped      (sel_unmapped),

        .rom_addr          (dec_rom_addr),
        .ram_addr          (dec_ram_addr),
        .pal_addr          (dec_pal_addr),
        .eeprom_addr       (dec_eeprom_addr),
        .adc_chan          (dec_adc_chan),
        .in_slap_window    (in_slap_window)
    );

    assign dbg_unmapped = sel_unmapped;

    // Boot-progress flags (dbg_hit), sticky.
    always_ff @(posedge clk) begin
        if (dbg_clr) dbg_hit <= 8'd0;
        if (sel_palette)  dbg_hit[7] <= 1'b1;
        if (sel_watchdog) dbg_hit[6] <= 1'b1;
        if (sel_irq_ack)  dbg_hit[5] <= 1'b1;
        if (sel_rle_ctrl) dbg_hit[4] <= 1'b1;
        if (sel_snd_cmd)  dbg_hit[3] <= 1'b1;
        if (sel_eeprom)   dbg_hit[2] <= 1'b1;
        if (sel_in0)      dbg_hit[1] <= 1'b1;
        if (sel_ram)      dbg_hit[0] <= 1'b1;
    end

    // Per-lane write strobes: a 68000 byte write asserts only UDS or LDS.
    wire cpu_wr    = !cpu_rw_n;
    wire wr_hi     = cpu_wr && !cpu_uds_n;
    wire wr_lo     = cpu_wr && !cpu_lds_n;

    //========================================================================
    //  Work RAM
    //========================================================================
    wire [15:0] ram_dout;

    g1_mainram u_ram (
        .clk       (clk),
        .cpu_addr  (dec_ram_addr),
        .cpu_din   (cpu_do),
        .cpu_wr_hi (sel_ram && wr_hi),
        .cpu_wr_lo (sel_ram && wr_lo),
        .cpu_dout  (ram_dout),
        // CHECKSUM write-back shares the CPU write port (port B is read only,
        // see g1_mainram.sv).
        .ext_addr  (vram_snoop_din_addr),
        .ext_din   (vram_snoop_din),
        .ext_we    (vram_snoop_we),
        .vid_addr  (vram_snoop_addr),
        .vid_dout  (vram_snoop_dout)
    );

    //========================================================================
    //  Work RAM write snoops for the RLE engine
    //========================================================================
    // $FF2000 is work RAM word offset $1000, $FF0000 word offset 0. Mirroring
    // them saves the RLE engine a read port. rle_cmd_wr is high exactly while
    // rle_cmd holds a freshly written value; g1_rle latches its command on it
    // (MAME: mo_command_w -> command_write on every write).
    always_ff @(posedge clk) begin
        rle_cmd_wr <= 1'b0;
        if (!rst_n) begin
            rle_cmd       <= 16'd0;
            rle_objram_w0 <= 16'd0;
        end else if (sel_ram && (wr_hi || wr_lo)) begin
            if (dec_ram_addr == 15'h1000) begin
                rle_cmd    <= cpu_do;
                rle_cmd_wr <= 1'b1;
            end
            if (dec_ram_addr == 15'h0000) rle_objram_w0 <= cpu_do;
        end
    end

    //========================================================================
    //  Palette
    //========================================================================
    assign pal_addr  = dec_pal_addr;
    assign pal_din   = cpu_do;
    assign pal_wr_hi = sel_palette && wr_hi;
    assign pal_wr_lo = sel_palette && wr_lo;

    //========================================================================
    //  EEPROM
    //========================================================================
    wire [7:0] eeprom_dout;

    g1_eeprom u_eeprom (
        .clk        (clk),
        .rst_n      (rst_n),
        .cpu_addr   (dec_eeprom_addr),
        .cpu_din    (cpu_do[7:0]),
        .cpu_sel    (sel_eeprom),
        .cpu_wr     (sel_eeprom && wr_lo),
        .cpu_unlock (sel_eeprom_unlock),
        .cpu_dout   (eeprom_dout),
        .nv_active  (nv_active),
        .nv_addr    (nv_addr),
        .nv_din     (nv_din),
        .nv_wr      (nv_wr),
        .nv_dout    (nv_dout),
        .nv_dirty   (nv_dirty)
    );

    //========================================================================
    //  Watchdog and diagnostic probes
    //========================================================================
    wire wd_reset;

    // Start of a bus cycle (AS falling edge). Also arms the ROM request.
    logic as_n_d1;
    always_ff @(posedge clk) as_n_d1 <= cpu_as_n;
    wire  cyc_start = as_n_d1 && !cpu_as_n;

    // ---- Address trace (dbg_trace) ----
    logic trace_frozen;
    always_ff @(posedge clk) begin
        if (dbg_clr) begin
            trace_frozen <= 1'b0;
            dbg_trace    <= '0;
        end
        // One entry per bus cycle, not per clock: a cycle spans many clk_sys
        // clocks and would otherwise fill the trace with copies of itself.
        else if (!trace_frozen && cyc_start) begin
            // Shift down one 23-bit slot and drop the new address in at the top.
            dbg_trace <= {cpu_a, dbg_trace[8*23-1 : 23]};
            // Freeze on the halt handler fetch, so later watchdog resets
            // cannot overwrite the capture.
            if (cpu_a == 23'h000180) trace_frozen <= 1'b1;   // $000300 >> 1
        end
    end

    // ---- First four ROM words received (dbg_rv_pk / dbg_ra_pk) ----
    // Sampled on the rising edge of rom_have: once per completed read, at the
    // moment rom_data holds the word the CPU latches.
    logic rom_have_d;
    logic [2:0] rv_count;
    always_ff @(posedge clk) begin
        rom_have_d <= rom_have;

        if (dbg_clr || rd_probe_rearm) begin
            dbg_rv_pk <= 64'd0;
            dbg_ra_pk <= 96'd0;
            rv_count  <= 3'd0;
        end
        else if (rom_have && !rom_have_d && rv_count < 3'd4) begin
            dbg_rv_pk[16*rv_count +: 16] <= rom_data;
            dbg_ra_pk[24*rv_count +: 24] <= {cpu_a, 1'b0};
            rv_count <= rv_count + 3'd1;
        end
    end

    // ---- ROM handshake counters ----
    // ROM acks vs. bus cycles that selected ROM. Equal counts confirm the
    // handshake is one-to-one; acks running ahead mean duplicate completions.
    always_ff @(posedge clk) begin
        if (dbg_clr) begin
            dbg_ack_count <= 16'd0;
            dbg_cyc_count <= 16'd0;
        end else begin
            if (rom_ack)                dbg_ack_count <= dbg_ack_count + 1'b1;
            if (cyc_start && sel_rom)   dbg_cyc_count <= dbg_cyc_count + 1'b1;
        end
    end

    // ---- Interrupt probes ----
    logic iack_d;
    always_ff @(posedge clk) begin
        if (dbg_clr) begin
            dbg_iack_cnt <= 16'd0;
            dbg_ipl_seen <= 8'd0;
        end
        iack_d <= is_iack;
        if (is_iack && !iack_d) dbg_iack_cnt <= dbg_iack_cnt + 1'b1;
        dbg_ipl_seen[ipl] <= 1'b1;
    end

    // ---- Watchdog probes ----
    // Count rising edges of wd_reset and capture the last bus cycle at each.
    logic wd_reset_d;
    logic [23:1] last_addr;
    logic  [3:0] last_sel;

    always_ff @(posedge clk) begin
        // Track the most recent bus cycle; same condition as `cyc` in
        // g1_addr_decode (AS low with at least one data strobe).
        if (!cpu_as_n && (!cpu_uds_n || !cpu_lds_n)) begin
            last_addr <= cpu_a;
            last_sel  <= {sel_snd_resp, sel_eeprom, sel_in1_adc, sel_rom};
        end

        wd_reset_d <= wd_reset;
        if (dbg_clr) dbg_wd_count <= 16'd0;
        if (wd_reset && !wd_reset_d) begin
            dbg_wd_count <= dbg_wd_count + 1'b1;
            dbg_wd_addr  <= last_addr;
            dbg_wd_sel   <= last_sel;
        end
    end

    g1_watchdog u_watchdog (
        .clk        (clk),
        .rst_n      (rst_n),
        .disable_wd (disable_wd),
        .kick       (sel_watchdog),
        .frame_tick (vblank_rise),
        .wd_reset   (wd_reset)
    );

    //========================================================================
    //  Interrupts
    //========================================================================
    // IRQ1: set at VBLANK start, cleared by a write to $FB0000.
    always_ff @(posedge clk) begin
        if (!rst_n)             irq1 <= 1'b0;
        else if (sel_irq_ack)   irq1 <= 1'b0;
        else if (vblank_rise)   irq1 <= 1'b1;
    end

    //========================================================================
    //  Sound board interface
    //========================================================================
    // sel_snd_resp is a level for the whole bus cycle; the response latch needs
    // a one-clock pulse or it would consume several bytes.
    logic sel_snd_resp_d;
    always_ff @(posedge clk) begin
        if (!rst_n) sel_snd_resp_d <= 1'b0;
        else        sel_snd_resp_d <= sel_snd_resp;
    end
    assign snd_resp_rd = sel_snd_resp && !sel_snd_resp_d;

    always_ff @(posedge clk) begin
        snd_cmd_wr <= 1'b0;
        if (!rst_n) begin
            snd_cmd   <= 8'h00;
            snd_reset <= 1'b0;
        end else begin
            // $F90000 is a byte handler on an even address in MAME
            // (map(0xf90000, 0xf90000)): D15:8 with UDS. Both games write it
            // with move.b d0,$F90000.
            if (sel_snd_cmd && wr_hi) begin
                snd_cmd    <= cpu_do[15:8];
                snd_cmd_wr <= 1'b1;
            end
            if (sel_snd_reset) snd_reset <= 1'b1;
            else               snd_reset <= 1'b0;
        end
    end

    //========================================================================
    //  RLE control register ($FA0001, byte)
    //========================================================================
    // bit0 MOGO (rising edge starts the pending command), bit1 ERASE,
    // bit2 FRAME (selects the displayed buffer).
    //
    // As in MAME control_write, a write that leaves the byte unchanged is
    // ignored, comparing all eight bits (Hydra ORs game state into bits 7:3 on
    // its second write). rle_ctrl_wr is one clock per changed byte, which
    // g1_rle_fb relies on.
    logic [7:0] rle_ctrl_byte;
    always_ff @(posedge clk) begin
        rle_ctrl_wr <= 1'b0;
        if (!rst_n) begin
            rle_ctrl      <= 3'b000;
            rle_ctrl_byte <= 8'h00;
        end
        else if (sel_rle_ctrl && wr_lo && (cpu_do[7:0] != rle_ctrl_byte)) begin
            rle_ctrl_byte <= cpu_do[7:0];
            rle_ctrl      <= cpu_do[2:0];
            rle_ctrl_wr   <= 1'b1;
        end
    end

    //========================================================================
    //  ADC0809 (Hydra only)
    //========================================================================
    // A write to $FC8000-$FC8007 starts a conversion on the channel selected
    // by the word offset; a read returns the result in D15:8. On Pit Fighter
    // the same addresses are IN1.
    wire has_adc = cfg.flags[0];

    assign adc_chan_sel = dec_adc_chan;
    assign adc_start    = has_adc && sel_in1_adc && cpu_wr;

    //========================================================================
    //  Program ROM fetch
    //========================================================================
    // One outstanding request at a time; DTACK holds the CPU until the arbiter
    // returns the word.
    assign rom_addr = {6'd0, dec_rom_addr, 1'b0} + SDR_PROG;

    // Exactly one request per bus cycle: armed when a cycle that selects ROM
    // starts, cleared by its own ack, and unable to re-arm until the next
    // cycle. Do not derive the request from a level such as sel_rom &&
    // !rom_have: it re-asserts in the clock the previous fetch completes, and
    // the second completion hands the CPU another transaction's data.
    logic rom_pending;
    always_ff @(posedge clk) begin
        if (!rst_n)                    rom_pending <= 1'b0;
        else if (cyc_start && sel_rom) rom_pending <= 1'b1;
        else if (rom_ack)              rom_pending <= 1'b0;
    end

    assign rom_req = rom_pending;

    // rom_have: rom_data belongs to the bus cycle in progress (DTACK source).
    logic        rom_have;
    logic [15:0] rom_data;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rom_have <= 1'b0;
            rom_data <= 16'h0000;
        end else begin
            if (rom_ack) begin
                rom_data <= rom_dout;
                rom_have <= 1'b1;
            end

            // Cleared while AS is high and at the start of every cycle, and
            // last, so it beats an ack in the same clock. Otherwise a new cycle
            // could be acknowledged at once with the previous cycle's data
            // (or rom_data's reset value $0000).
            if (cpu_as_n || cyc_start) rom_have <= 1'b0;
        end
    end

    //========================================================================
    //  Read data multiplexer and DTACK
    //========================================================================
    // Everything except ROM answers within a clock (BRAM or a register), so
    // its DTACK is immediate; ROM waits on the SDRAM arbiter.
    //
    // Unmapped space also asserts DTACK and reads $0000, as in MAME (the G1
    // map does not set unmap_value_high). That includes $FE0000, whose MAME
    // handler is commented out: Hydra tests bit 0 of $FE0001 at $70E2 and
    // only enters its bit-bang routine when it reads 1. Unused byte lanes of
    // byte-wide devices read 0 likewise.
    //
    // $FD0000 (sound response) is a byte handler on an even address, so the
    // byte is on D15:8 (both games read it with move.b $FD0000,d1).
    always_comb begin
        cpu_di = 16'h0000;

        // IACK wins over every select (the decoder is also gated during IACK).
        if      (is_iack)     cpu_di = iack_vector;
        else if (sel_rom)     cpu_di = rom_data;
        else if (sel_ram)     cpu_di = ram_dout;
        else if (sel_palette) cpu_di = pal_dout;
        else if (sel_eeprom)  cpu_di = {8'h00, eeprom_dout};
        else if (sel_snd_resp)cpu_di = {snd_resp, 8'h00};
        else if (sel_in0)     cpu_di = in0;
        else if (sel_in1_adc) cpu_di = has_adc ? {adc_data, 8'h00} : in1;
    end

    always_comb begin
        // IACK takes the normal no-wait DTACK, with the vector on the data bus.
        if (sel_rom) cpu_dtack_n = !rom_have;
        else         cpu_dtack_n = cpu_as_n;         // everything else: no wait
    end

endmodule

`default_nettype wire
