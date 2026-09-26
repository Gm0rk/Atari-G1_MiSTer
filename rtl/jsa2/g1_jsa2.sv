//============================================================================
//  Atari G1 for MiSTer
//  g1_jsa2.sv -- Atari JSA II ("Stand-Alone Audio II") sound board
//
//  6502 @ 1.789773 MHz (T65), YM2151 @ 3.579545 MHz (JT51) and OKI6295 @
//  1.193182 MHz (JT6295), mono output. Follows MAME's atari_jsa_ii_device
//  (atarijsa.cpp) and the JSA II schematic (Pit Fighter manual, fig. 5-2).
//  The board has its own 3.579545 MHz crystal; see g1_ce.sv for why the
//  enables still come from the main counter.
//
//  6502 memory map (MAME atarijsa2_map):
//    $0000-$1FFF   RAM (8 KB)
//    $2000-$2001   YM2151                        mirror $07FE
//    $2800         read  OKI6295 status          mirror $01F9 ($28xx/$2Axx)
//    $2802         read  sound command from 68000
//    $2804         read  RDIO
//    $2806         read/write IRQ acknowledge
//    $2A00         write OKI6295
//    $2A02         write sound response to 68000
//    $2A04         write WRIO
//    $2A06         write MIX
//    $3000-$3FFF   banked program ROM window
//    $4000-$FFFF   fixed program ROM
//
//  RDIO ($2804), see rdio_value below:
//    0x80 self test, 1 = on         0x08 unused, reads 0
//    0x40 NMI line state, act. low  0x04 coin 3, active high
//    0x20 sound output full         0x02 coin 2, active high
//    0x10 unused, reads 0           0x01 coin 1, active high
//  The coins are read here, not by the 68000: the 6502 counts them and
//  reports the totals to the main CPU.
//
//  WRIO ($2A04, MAME wrio_w):
//    0xC0 program ROM bank          0x04 OKI6295 reset, active low
//    0x20 coin counter 2            0x02 (JSA III only)
//    0x10 coin counter 1            0x01 YM2151 reset, active low
//    0x08 OKI6295 PIN7 (sample rate). The game switches between the /132 and
//         /165 dividers at runtime, so it cannot be hard-wired.
//
//  MIX ($2A06):
//    0x20 low-pass filter enable (not emulated, nor by MAME)
//    0x0E YM2151 volume, 0-7
//    0x01 OKI6295 volume, 0 = half, 1 = full
//
//  Analog filtering is not modelled (nor by MAME); the real board sounds
//  duller than MAME, the ADPCM most of all. Schematic values:
//    YM   Sallen-Key low-pass 12K/12K, 2.2nF/1nF: ~8.9 kHz, Q 0.74 (MIX bit 5
//         adds 3.3nF via Q5: ~4.3 kHz, Q 0.36); 0.22uF coupling into the volume
//         summer: ~340 Hz high-pass at vol 7, lower at lower volumes.
//    OKI  twin-T notch ~7.1 kHz (6.8K, 3.3nF; the /165 rate is 7.23 kHz), gain
//         3, then poles at ~2.3 kHz (10K/6.8nF) and ~0.9-1.1 kHz (2K/0.1uF).
//
//  6502 IRQ = periodic timer (249.7 Hz) OR YM2151 IRQ, as MAME's
//  update_sound_irq(). $2806 acknowledges the timer.
//
//  Clock domain: clk_sys, gated by ce_6502 / ce_ym / ce_oki.
//============================================================================

`default_nettype none

module g1_jsa2
    import g1_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        board_reset,   // 68000 write to $F98000

    // ---- Clock enables ----------------------------------------------------
    input  wire        ce_6502,       // 1.789773 MHz
    input  wire        ce_ym,         // 3.579545 MHz
    input  wire        ce_oki,        // 1.193182 MHz

    // ---- 68000 interface --------------------------------------------------
    input  wire [7:0]  main_din,
    input  wire        main_wr,       // $F90000
    input  wire        main_rd,       // $FD0000
    output logic [7:0] main_dout,
    output logic       main_irq,      // -> IRQ2
    output logic       main_to_sound_ready,  // command latch full (raw flag)

    // ---- Cabinet inputs ---------------------------------------------------
    input  wire        coin1,         // active high
    input  wire        coin2,         // active high
    input  wire        coin3,         // active high
    input  wire        self_test,     // active high: 1 = test switch on

    // ---- Program ROM (SDRAM byte address, 16-bit data) --------------------
    output logic [24:0] prog_addr,
    output logic        prog_req,
    input  wire [15:0]  prog_dout,
    input  wire         prog_ack,

    // ---- OKI6295 sample ROM (SDRAM byte address, 16-bit data) -------------
    output logic [24:0] oki_addr,
    output logic        oki_req,
    input  wire [15:0]  oki_dout,
    input  wire         oki_ack,

    // ---- Audio out (mono: both channels carry the same mix) ---------------
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r
);

    //========================================================================
    //  Communication latches
    //========================================================================
    wire [7:0] snd_from_main;
    wire       snd_nmi, sound_to_main_ready;
    logic      snd_rd_cmd, snd_wr_resp;

    g1_sound_comm u_comm (
        .clk                 (clk),
        .rst_n               (rst_n),
        .main_din            (main_din),
        .main_wr             (main_wr),
        .main_rd             (main_rd),
        .main_dout           (main_dout),
        .main_irq            (main_irq),
        .snd_din             (cpu_do),
        .snd_wr              (snd_wr_resp),
        .snd_rd              (snd_rd_cmd),
        .snd_dout            (snd_from_main),
        .snd_nmi             (snd_nmi),
        .main_to_sound_ready (main_to_sound_ready),
        .sound_to_main_ready (sound_to_main_ready),
        .sound_reset         (board_reset)
    );

    //========================================================================
    //  6502
    //========================================================================
    wire [23:0] cpu_a;
    wire [7:0]  cpu_do;
    logic [7:0] cpu_di;
    wire        cpu_rw_n;

    logic sound_irq;

    // Bus-cycle enable: the ce_6502 grid, held back while a program-ROM byte
    // is still in flight from SDRAM (see Program ROM). All bus-cycle strobes
    // in this module use it.
    logic cpu_ce;

    T65 u_cpu (
        .Mode    (2'b00),          // 6502
        .BCD_en  (1'b1),
        .Res_n   (rst_n & ~board_reset),
        .Enable  (cpu_ce),
        .Clk     (clk),
        .Rdy     (1'b1),
        .Abort_n (1'b1),
        .IRQ_n   (~sound_irq),
        .NMI_n   (~snd_nmi),
        .SO_n    (1'b1),
        .R_W_n   (cpu_rw_n),
        .Sync    (),
        .EF      (), .MF (), .XF (), .ML_n (), .VP_n (), .VDA (), .VPA (),
        .A       (cpu_a),
        .DI      (cpu_di),
        .DO      (cpu_do)
    );

    wire [15:0] a  = cpu_a[15:0];
    wire        wr = ~cpu_rw_n;
    wire        rd =  cpu_rw_n;

    //========================================================================
    //  Address decode
    //========================================================================
    // The I/O block is mirrored as in MAME ($07FE for the YM, $01F9 for the
    // rest). Only the significant bits are decoded: the self-test accesses
    // the mirrors.
    wire in_io   = (a[15:12] == 4'h2);

    // YM2151: $2000-$2001 mirrored by $07FE answers all of $2000-$27FF, with
    // a[0] selecting register/data. Cannot collide with the $2800/$2A00 blocks,
    // which need a[11] = 1.
    wire io_2000 = (a[15:11] == 5'b00100);                    // $2000-$27FF

    // $2800/$2A00 blocks, mirror $01F9: a[11:9] picks the block, a[2:1] the
    // register; bits 0 and 3-8 are don't-care.
    wire io_28   = in_io && (a[11:9] == 3'b100);              // $2800 block
    wire io_2a   = in_io && (a[11:9] == 3'b101);              // $2A00 block

    wire [1:0] io_sel = a[2:1];

    wire sel_ram  = (a[15:13] == 3'b000);                     // $0000-$1FFF
    wire sel_bank = (a[15:12] == 4'h3);                       // $3000-$3FFF
    wire sel_rom  = (a[15:14] >= 2'b01);                      // $4000-$FFFF

    wire sel_ym     = io_2000;
    wire rd_oki     = io_28 && rd && (io_sel == 2'd0);        // $2800
    wire rd_cmd     = io_28 && rd && (io_sel == 2'd1);        // $2802
    wire rd_rdio    = io_28 && rd && (io_sel == 2'd2);        // $2804
    wire irq_ack    = io_28 && (io_sel == 2'd3);              // $2806
    wire wr_oki     = io_2a && wr && (io_sel == 2'd0);        // $2A00
    wire wr_resp    = io_2a && wr && (io_sel == 2'd1);        // $2A02
    wire wr_wrio    = io_2a && wr && (io_sel == 2'd2);        // $2A04
    wire wr_mix     = io_2a && wr && (io_sel == 2'd3);        // $2A06

    // Comm latch accesses are single-clock strobes: the 6502 holds its address
    // for a whole bus cycle.
    logic rd_cmd_d, wr_resp_d;
    always_ff @(posedge clk) begin
        if (cpu_ce) begin
            rd_cmd_d  <= rd_cmd;
            wr_resp_d <= wr_resp;
        end
    end
    assign snd_rd_cmd  = cpu_ce && rd_cmd  && !rd_cmd_d;
    assign snd_wr_resp = cpu_ce && wr_resp && !wr_resp_d;

    //========================================================================
    //  WRIO / MIX registers
    //========================================================================
    logic [1:0] rom_bank;
    logic       oki_pin7;      // "voice frequency": 1 = /132, 0 = /165
    logic       oki_reset_n;
    logic       ym_reset_n;
    logic [2:0] ym_volume;
    logic       oki_volume;    // 0 = half, 1 = full

    // YM2151 CT1 output pin; gates the OKI as in MAME (see Mixer).
    wire        ym_ct1;

    always_ff @(posedge clk) begin
        if (!rst_n || board_reset) begin
            rom_bank    <= 2'd0;
            oki_pin7    <= 1'b1;
            oki_reset_n <= 1'b0;
            ym_reset_n  <= 1'b0;
            ym_volume   <= 3'd7;
            oki_volume  <= 1'b1;
        end
        else if (cpu_ce) begin
            if (wr_wrio) begin
                rom_bank    <= cpu_do[7:6];
                oki_pin7    <= cpu_do[3];
                oki_reset_n <= cpu_do[2];
                ym_reset_n  <= cpu_do[0];
                // Bits 5:4 (coin counters) have nothing to drive.
            end
            if (wr_mix) begin
                ym_volume  <= cpu_do[3:1];
                oki_volume <= cpu_do[0];
                // Bit 5 (low-pass filter enable) is not emulated; see header.
            end
        end
    end

    //========================================================================
    //  Interrupts
    //========================================================================
    // Periodic IRQ: JSA_MASTER_CLOCK / 4 / 16 / 16 / 14 = 3579545 / 14336
    // = 249.69 Hz, counted on ce_ym so it tracks the sound clock exactly.
    localparam int IRQ_DIV = 14336;

    logic [13:0] irq_cnt;
    logic        timed_int;
    wire         ym_irq_n;

    always_ff @(posedge clk) begin
        if (!rst_n || board_reset) begin
            irq_cnt   <= '0;
            timed_int <= 1'b0;
        end
        else begin
            if (ce_ym) begin
                if (irq_cnt >= IRQ_DIV - 1) begin
                    irq_cnt   <= '0;
                    timed_int <= 1'b1;
                end else begin
                    irq_cnt <= irq_cnt + 1'b1;
                end
            end
            if (cpu_ce && irq_ack) timed_int <= 1'b0;
        end
    end

    always_comb sound_irq = timed_int | ~ym_irq_n;

    //========================================================================
    //  Program ROM
    //========================================================================
    // $3000-$3FFF is a 4 KB window into the first 16 KB of the 64 KB ROM
    // (WRIO bits 7:6); $4000-$FFFF maps straight through. A byte fetch reads
    // the containing 16-bit SDRAM word and picks a half.
    wire [15:0] rom_off = sel_bank ? {2'b00, rom_bank, a[11:0]} : a;
    wire [24:0] rom_byte = SDR_JSA + {9'd0, rom_off};

    logic [7:0]  rom_data;
    logic        rom_have;     // rom_data holds the byte for the current address
    logic        ce_pend;      // a ce_6502 tick is waiting for that byte

    //------------------------------------------------------------------------
    // Fetch timing. T65 drives a new address just after an Enable clock and
    // samples DI at the next one, so the SDRAM request goes out in the clock
    // after the enable and holds until the ack. The enable ending a ROM-read
    // cycle waits for the byte (ce_pend): a slow grant stretches that cycle
    // (rare: the arbiter's CPU channel leaves about 30 clocks of slack).
    // Requesting only in the ce_6502 clock would deliver every byte a cycle late.
    //
    // A bus cycle is at least two clocks: cpu_ce_q blocks an enable in the clock
    // after one (the tick waits in ce_pend). Otherwise a stretched enable just
    // before a grid tick makes a one-clock cycle whose RAM read returns ram_q
    // for the previous address. This also lets Enable use the registered
    // rom_cycle_q, keeping T65's Enable (which fans out to the whole CPU) off
    // T65's address adder and the decode; prog_req uses rom_cycle directly.
    //------------------------------------------------------------------------
    wire  rom_cycle = (sel_bank | sel_rom) && rd;
    logic rom_cycle_q;
    logic cpu_ce_q;

    assign prog_addr = {rom_byte[24:1], 1'b0};
    // Never high in an enable clock (cpu_ce needs rom_have on a ROM cycle), so
    // it always presents the address the 6502 is waiting on.
    assign prog_req  = rom_cycle && !rom_have && rst_n && !board_reset;

    always_comb cpu_ce = (ce_6502 || ce_pend) && !cpu_ce_q && (!rom_cycle_q || rom_have);

    always_ff @(posedge clk) begin
        if (!rst_n || board_reset) begin
            rom_have    <= 1'b0;
            ce_pend     <= 1'b0;
            cpu_ce_q    <= 1'b0;
            rom_cycle_q <= 1'b0;
        end
        else begin
            cpu_ce_q    <= cpu_ce;
            rom_cycle_q <= rom_cycle;
            if (prog_ack) begin
                rom_data <= rom_byte[0] ? prog_dout[7:0] : prog_dout[15:8];
                rom_have <= 1'b1;
            end
            if (cpu_ce) begin
                rom_have <= 1'b0;
                ce_pend  <= 1'b0;
            end
            else if (ce_6502) begin
                ce_pend  <= 1'b1;
            end
        end
    end

    //========================================================================
    //  Work RAM
    //========================================================================
    // Registered read: ram_q follows the address one clock later.
    logic [7:0] ram [8192];
    logic [7:0] ram_q;

    always_ff @(posedge clk) begin
        if (cpu_ce && sel_ram && wr) ram[a[12:0]] <= cpu_do;
        ram_q <= ram[a[12:0]];
    end

    //========================================================================
    //  YM2151 (jotego JT51)
    //========================================================================
    wire signed [15:0] ym_left, ym_right;
    wire [7:0] ym_dout;

    // JT51 needs a second enable, cen_p1, at half the cen rate. Some tools tie
    // it low silently if unconnected, and the chip then produces nothing.
    logic ce_ym_p1_tog;
    always_ff @(posedge clk) begin
        if (!rst_n) ce_ym_p1_tog <= 1'b0;
        else if (ce_ym) ce_ym_p1_tog <= ~ce_ym_p1_tog;
    end
    wire ce_ym_p1 = ce_ym & ce_ym_p1_tog;

    jt51 u_ym (
        .rst   (~(rst_n & ym_reset_n)),
        .clk   (clk),
        .cen    (ce_ym),
        .cen_p1 (ce_ym_p1),
        .cs_n  (~(cpu_ce & sel_ym)),
        .wr_n  (~wr),
        .a0    (a[0]),
        .din   (cpu_do),
        .dout  (ym_dout),
        .ct1   (ym_ct1), .ct2 (),   // CT1 gates the OKI, see Mixer
        .irq_n (ym_irq_n),
        .sample(),
        .left  (), .right (),
        .xleft (ym_left), .xright (ym_right)
    );

    //========================================================================
    //  OKI6295 (jotego JT6295)
    //========================================================================
    wire signed [13:0] oki_snd;
    wire [7:0] oki_status;
    wire [17:0] oki_rom_addr;

    // Sample ROM fetch state (see OKI sample fetch; used by the instance).
    logic [7:0]  oki_rom_byte;
    wire         oki_rom_ok;
    logic [17:0] oki_addr_d;    // address oki_rom_byte belongs to
    logic        oki_valid;     // oki_addr_d/oki_rom_byte hold a real read
    logic [17:0] oki_req_a;     // address of the fetch in flight
    logic        oki_pend;

    // INTERPOL=0: the 4x upsampling FIR (INTERPOL=1) needs jtframe_fir_mono.v
    // from the JTFRAME repository. 0 keeps JTFRAME out of the build, at the
    // cost of a slightly harsher ADPCM high end.
    jt6295 #(.INTERPOL(0)) u_oki (
        .rst      (~(rst_n & oki_reset_n)),
        .clk      (clk),
        .cen      (ce_oki),
        .ss       (oki_pin7),        // PIN7: 1 = /132, 0 = /165
        .wrn      (~(cpu_ce & wr_oki)),
        .din      (cpu_do),
        .dout     (oki_status),
        .rom_addr (oki_rom_addr),
        .rom_data (oki_rom_byte),
        .rom_ok   (oki_rom_ok),
        .sound    (oki_snd),
        .sample   ()
    );

    // OKI sample fetch. No OKI banking on JSA II: the 256 KB sample ROM fits the
    // 18-bit address. JT6295 switches between the ADPCM stream and its control
    // reads every ~200 clocks, so the address is latched when the request goes
    // out (oki_req_a) and the byte is tagged with it (oki_addr_d). oki_valid
    // covers the first read after reset, which may be for address 0.

    wire [24:0] oki_byte = SDR_OKI + {7'd0, oki_req_a};

    assign oki_addr = {oki_byte[24:1], 1'b0};
    assign oki_req  = oki_pend;

    // Valid when the held byte is for the address JT6295 asks for now. Kept
    // combinational: a registered flag could stay low when the address returns
    // to the held byte, stalling the control reads until the next switch.
    assign oki_rom_ok = oki_valid && (oki_rom_addr == oki_addr_d);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            oki_addr_d <= '0;
            oki_valid  <= 1'b0;
            oki_req_a  <= '0;
            oki_pend   <= 1'b0;
        end else begin
            if (oki_ack) begin
                oki_rom_byte <= oki_req_a[0] ? oki_dout[7:0] : oki_dout[15:8];
                oki_addr_d   <= oki_req_a;
                oki_valid    <= 1'b1;
                oki_pend     <= 1'b0;
            end
            else if (!oki_pend && (!oki_valid || oki_rom_addr != oki_addr_d)) begin
                oki_req_a <= oki_rom_addr;
                oki_pend  <= 1'b1;
            end
        end
    end

    //========================================================================
    //  Read multiplexer
    //========================================================================
    always_comb begin
        cpu_di = 8'hFF;

        // T65 requires DO fed back to DI while R_W_n = 0: some (undocumented)
        // read-modify-write opcodes re-read the value being written.
        if (!cpu_rw_n)                 cpu_di = cpu_do;
        else if (sel_ram)              cpu_di = ram_q;
        else if (sel_bank || sel_rom)  cpu_di = rom_data;
        else if (sel_ym)               cpu_di = ym_dout;
        else if (rd_oki)               cpu_di = oki_status;
        else if (rd_cmd)               cpu_di = snd_from_main;
        else if (rd_rdio)              cpu_di = rdio_value;
    end

    // RDIO. All polarities are applied here (MAME jsa_ii_ioports). Bits 4:3
    // read 0, not "+5V" as the rdio_r() comment says: the 6502's coin routine
    // ($5952) treats bits 0-3 as coin switches, so a 1 is a switch held closed.
    // Coin 3 is counted by the 6502 but credited by neither game (tied to 0).
    //
    // Bit 7 follows the schematic, not MAME (which always reads 0): the
    // SELF-TEST net (low = test; shared with the game PCB and JAMMA pin 15)
    // reaches SD7 through 2F, an inverting 74LS240, so test mode reads 1. The
    // sound program checks it at reset ($4016: run the power-up diagnostics,
    // result in $02 = Sound Test "SOUND CPU STATUS") and in the coin poll
    // ($5929: raw switch states into $6B = "COIN MECH SWITCHES").
    wire [7:0] rdio_value = {
        self_test,               // 0x80 self test, active high (via 74LS240)
        ~main_to_sound_ready,    // 0x40 NMI line state, active low
        sound_to_main_ready,     // 0x20 sound output full
        1'b0,                    // 0x10 unused
        1'b0,                    // 0x08 unused
        coin3,                   // 0x04 coin 3
        coin2,                   // 0x02 coin 2
        coin1                    // 0x01 coin 1
    };

    //========================================================================
    //  Mixer
    //========================================================================
    // MAME (atarijsa.cpp, JSA II), mono:
    //     out = 0.60 * (L + R) * vol/7  +  0.75 * g * oki
    // vol = MIX bits 3:1, g = 1.0 or 0.5 from MIX bit 0, one full-scale OKI
    // voice = 1.0 (okim6295.cpp: 12-bit sample x volume 32 / 2).
    //
    // The schematic (fig. 5-2) has the same structure: YM3012 L and R are
    // summed by 6B through equal resistor pairs switched 1:2:4 by MIX bits 1-3
    // (4066 3B), i.e. (L+R) * vol/7; the OKI half/full switch is ~2.4:1 at DC
    // vs MAME's 2:1. The YM:OKI balance depends on DAC swings the schematic
    // does not give, so MAME's 0.60/0.75 are used.
    //
    // MAME's ratio, halved for headroom:
    //   YM   0.30 * (L+R) * vol/7  -> (L+R) * vol * 11 / 256   (+0.3%)
    //   OKI  0.375 * g * voice     -> oki_snd * 6 (full), * 3 (half)
    // jt6295 sums four 12-bit voices into 14 bits, so one full-scale voice is
    // 2048 = 1/16 of 32768. Full-scale YM at vol 7 gives 0.60 of full scale,
    // one OKI voice 0.375; four loud voices can clip, as in MAME.
    wire signed [16:0] ym_sum = {ym_left[15], ym_left} + {ym_right[15], ym_right};
    wire signed [20:0] ym_v   = ym_sum * $signed({1'b0, ym_volume});
    wire signed [25:0] ym_term = (ym_v * 26'sd11) >>> 8;

    //------------------------------------------------------------------------
    // OKI gated by YM2151 CT1, as in MAME's update_all_volumes()
    // (gain = overall * oki volume * ct1). CT1 is set by YM register $1B and
    // resets to 0. On the JSA II schematic CT1/CT2 are not connected (3A pins 8
    // and 9); MAME's gating comes from the JSA I. It makes no difference here:
    // both games write $C0 to $1B during boot, before any OKI sample, and never
    // clear it. Kept so the core matches MAME; removing it would match the board.
    //------------------------------------------------------------------------
    wire signed [25:0] oki_term = ym_ct1 ? oki_snd * (oki_volume ? 26'sd6 : 26'sd3)
                                         : 26'sd0;

    wire signed [25:0] mixed = ym_term + oki_term;

    always_ff @(posedge clk) begin
        // Saturate rather than wrap: a wrapped mix cracks on every peak.
        if      (mixed >  26'sd32767) begin audio_l <= 16'sd32767;  audio_r <= 16'sd32767;  end
        else if (mixed < -26'sd32768) begin audio_l <= -16'sd32768; audio_r <= -16'sd32768; end
        else                          begin audio_l <= mixed[15:0]; audio_r <= mixed[15:0]; end
    end

endmodule

`default_nettype wire
