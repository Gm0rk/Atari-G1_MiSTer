//============================================================================
//  Atari G1 for MiSTer
//  g1_sdram_iface.sv -- SDRAM controller selection wrapper
//
//  Selects the SDRAM controller with one .qsf macro, so builds with either
//  controller are otherwise identical:
//    default            sdram.sv, this core's own controller
//    USE_ALT_SDRAM=1    a vendored controller as sdram_alt.sv (also enable it
//                       in files.qip and adapt its instantiation below)
//
//  Contract towards g1_sdram_arb:
//    - addr is a 25-bit byte address, bit 0 ignored; 16-bit accesses only
//    - rd / we are held, with addr (and din) stable, until ready
//    - ready pulses once per completed access and must be seen by the
//      clk_sys domain at clk_ram / 2 (see the ready stretcher)
//
//  Clock domain: clk_ram, synchronous 2:1 with clk_sys.
//============================================================================

`default_nettype none

module g1_sdram_iface (
    // ---- SDRAM pins -------------------------------------------------------
    inout  wire [15:0]  SDRAM_DQ,
    output wire [12:0]  SDRAM_A,
    output wire [1:0]   SDRAM_BA,
    output wire         SDRAM_DQML,
    output wire         SDRAM_DQMH,
    output wire         SDRAM_nCS,
    output wire         SDRAM_nRAS,
    output wire         SDRAM_nCAS,
    output wire         SDRAM_nWE,
    output wire         SDRAM_CKE,

    // ---- Control ----------------------------------------------------------
    input  wire         init,       // hold high until the PLL is locked
    input  wire  [1:0]  rd_phase,   // read capture step (see sdram.sv)
    input  wire         rd_half,    // sample half a clock earlier (see sdram.sv)
    output logic [31:0] dbg_refresh_count,  // AUTO REFRESH commands issued
    output logic [15:0] dbg_dq7, dbg_dq8, dbg_dq9, dbg_dq10,  // DQ at read steps t7-t10
    input  wire         clk,        // clk_ram

    // ---- Request port (to g1_sdram_arb) -----------------------------------
    input  wire [24:0]  addr,
    input  wire [15:0]  din,
    output wire [15:0]  dout,
    input  wire         rd,
    input  wire         we,
    output wire         ready,

    // ---- Identification ---------------------------------------------------
    output wire         which_controller   // 0 = own controller, 1 = vendored
);

`ifndef USE_ALT_SDRAM
    //========================================================================
    //  Default: this core's controller
    //========================================================================
    assign which_controller = 1'b0;

    sdram u_sdram (
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
        .init       (init),
        .rd_phase   (rd_phase),
        .rd_half    (rd_half),
        .dbg_refresh_count (dbg_refresh_count),
        .dbg_dq7    (dbg_dq7),  .dbg_dq8  (dbg_dq8),
        .dbg_dq9    (dbg_dq9),  .dbg_dq10 (dbg_dq10),
        .clk        (clk),
        .addr       (addr),
        .din        (din),
        .dout       (dout),
        .rd         (rd),
        .we         (we),
        .ready      (ready)
    );

`else
    //========================================================================
    //  USE_ALT_SDRAM: vendored controller
    //========================================================================
    assign which_controller = 1'b1;

    wire        alt_ready_raw;
    wire [15:0] alt_dout;

    //------------------------------------------------------------------------
    // Controller-specific: replace with the vendored controller's port list.
    // Controllers differ: some take a word address (pass addr[24:1]); 8-bit
    // ones are not a drop-in (16-bit access is needed); some expect rd/we as
    // single-cycle strobes (edge-detect them here); some have extra read,
    // write or per-client ports (tie the unused ones off).
    //------------------------------------------------------------------------
    sdram_alt u_sdram_alt (
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
        .init       (init),
        .rd_phase   (rd_phase),
        .rd_half    (rd_half),
        .dbg_dq7    (dbg_dq7),  .dbg_dq8  (dbg_dq8),
        .dbg_dq9    (dbg_dq9),  .dbg_dq10 (dbg_dq10),
        .clk        (clk),
        .addr       (addr),
        .din        (din),
        .dout       (alt_dout),
        .rd         (rd),
        .we         (we),
        .ready      (alt_ready_raw)
    );
    // ---- End of controller-specific block ----

    assign dout = alt_dout;

    //------------------------------------------------------------------------
    // Ready stretcher
    //------------------------------------------------------------------------
    // Holds ready for at least two clk_ram cycles so the clk_sys side sees it
    // exactly once; a single-cycle ready can fall between clk_sys edges and
    // hang the core on its first ROM fetch. Harmless if the controller already
    // holds ready for two: the extension only covers a cycle in which ready
    // would be low anyway.
    logic ready_d;
    always_ff @(posedge clk) begin
        if (init) ready_d <= 1'b0;
        else      ready_d <= alt_ready_raw & ~ready_d;
    end
    assign ready = alt_ready_raw | ready_d;
`endif

endmodule

`default_nettype wire
