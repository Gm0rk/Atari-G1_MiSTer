//============================================================================
//  Atari G1 for MiSTer
//  g1_slapstic.sv -- Atari 137412-1xx Slapstic protection, types 111..116
//
//  The Slapstic watches the 68000 address bus and switches a $2000-byte ROM
//  window between four banks. It never sees the data bus: banking is driven
//  only by the sequence of addresses the CPU emits. Port of MAME slapstic.cpp
//  (atari_slapstic_device).
//
//  MAME taps the whole address space (install_readwrite_tap over addrmask),
//  because for types 111-118 the 1st and 3rd steps of the alt sequence match
//  at any address. Feed this module every 68000 bus cycle, reads and writes,
//  in the window or not; an in-window-only feed boots and then fails.
//
//  cpu_addr is the 68000 byte address (A0 = 0). Matching uses
//  addr14 = cpu_addr[14:1], which absorbs MAME's shift of 1 for a 16-bit bus,
//  so the table constants are identical to slapstic.cpp. Checker primitives:
//      test_in(m, v)  = in_range && ((addr14 & m) == v)
//      test_any(m, v) =              (addr14 & m) == v
//      test_reset     = in_range && (addr14 == 0)
//      bank select    = in_range && (addr14 == bank_sel[b])
//
//  Clock domain: clk_sys; one access per acc_strobe.
//============================================================================

`default_nettype none

module g1_slapstic (
    input  wire        clk,
    input  wire        rst_n,

    // ---- Configuration (MRA config bytes) ----
    input  wire [7:0]  chip_type,   // 111..116, or 0 for the bootleg banking
    // Window start address bits [23:16]: $03 Pit Fighter ($038000),
    // $07 Hydra ($078000)
    input  wire [7:0]  window_base,

    // ---- 68000 bus snoop ----
    // acc_strobe: one clock per completed bus cycle (read or write, any
    // address), with cpu_addr stable.
    input  wire [23:0] cpu_addr,
    input  wire        acc_strobe,

    // ---- Output ----
    output logic [1:0] bank,        // current ROM bank, 0..3
    output logic       bank_changed // one-cycle pulse when bank updates
);

    //------------------------------------------------------------------------
    // Type tables: (mask, value) pairs tested against addr14, copied from
    // slapstic.cpp. Kept as a flat case so they diff directly against it.
    //------------------------------------------------------------------------
    logic [13:0] bank_sel [4];   // direct bank-select addresses
    logic [13:0] alt1_m, alt1_v; // alt sequence step 1 (any address)
    logic [13:0] alt2_m, alt2_v; // alt sequence step 2 (in range)
    logic [13:0] alt3_m, alt3_v; // alt sequence step 3 (any address)
    logic [13:0] alt4_m, alt4_v; // alt sequence step 4 / commit (in range)
    logic [2:0]  alt_shift;      // extra shift to extract the bank from step 3
    logic [13:0] add1_m, add1_v; // additive sequence start   (in range)
    logic [13:0] add2_m, add2_v; // additive sequence load    (in range)
    logic [13:0] ap1_m,  ap1_v;  // additive +1               (in range)
    logic [13:0] ap2_m,  ap2_v;  // additive +2               (in range)
    logic [13:0] add3_m, add3_v; // additive end              (in range)

    always_comb begin
        // All-ones defaults keep an unknown chip_type inert.
        bank_sel = '{default: 14'h3FFF};
        {alt1_m, alt1_v} = {14'h3FFF, 14'h3FFF};
        {alt2_m, alt2_v} = {14'h3FFF, 14'h3FFF};
        {alt3_m, alt3_v} = {14'h3FFF, 14'h3FFF};
        {alt4_m, alt4_v} = {14'h3FFF, 14'h3FFF};
        alt_shift        = 3'd0;
        {add1_m, add1_v} = {14'h3FFF, 14'h3FFF};
        {add2_m, add2_v} = {14'h3FFF, 14'h3FFF};
        {ap1_m,  ap1_v}  = {14'h3FFF, 14'h3FFF};
        {ap2_m,  ap2_v}  = {14'h3FFF, 14'h3FFF};
        {add3_m, add3_v} = {14'h3FFF, 14'h3FFF};

        case (chip_type)
        8'd111: begin   // Pit Fighter, Aug 09 1990 - Aug 22 1990 (revs 2,3,4)
            bank_sel = '{14'h0042, 14'h0052, 14'h0062, 14'h0072};
            {alt1_m, alt1_v} = {14'h007f, 14'h000a};
            {alt2_m, alt2_v} = {14'h3fff, 14'h28a4};
            {alt3_m, alt3_v} = {14'h0784, 14'h0080};
            {alt4_m, alt4_v} = {14'h3fcf, 14'h0042};
            alt_shift        = 3'd0;
            {add1_m, add1_v} = {14'h3fff, 14'h00a1};
            {add2_m, add2_v} = {14'h3fff, 14'h00a2};
            {ap1_m,  ap1_v}  = {14'h3c4f, 14'h284d};
            {ap2_m,  ap2_v}  = {14'h3a5f, 14'h285d};
            {add3_m, add3_v} = {14'h3ff8, 14'h2800};
        end
        8'd112: begin   // Pit Fighter, Aug 22 1990 - Oct 01 1990 (revs 5,7)
            bank_sel = '{14'h002c, 14'h003c, 14'h006c, 14'h007c};
            {alt1_m, alt1_v} = {14'h007f, 14'h0014};
            {alt2_m, alt2_v} = {14'h3fff, 14'h29a0};
            {alt3_m, alt3_v} = {14'h0073, 14'h0010};
            {alt4_m, alt4_v} = {14'h3faf, 14'h002c};
            alt_shift        = 3'd2;
            {add1_m, add1_v} = {14'h3fff, 14'h2dce};
            {add2_m, add2_v} = {14'h3fff, 14'h2dcf};
            {ap1_m,  ap1_v}  = {14'h3def, 14'h15e2};
            {ap2_m,  ap2_v}  = {14'h3fbf, 14'h15a2};
            {add3_m, add3_v} = {14'h3ffc, 14'h1450};
        end
        8'd113: begin   // Pit Fighter rev 6
            bank_sel = '{14'h0008, 14'h0018, 14'h0028, 14'h0038};
            {alt1_m, alt1_v} = {14'h007f, 14'h0059};
            {alt2_m, alt2_v} = {14'h3fff, 14'h11a5};
            {alt3_m, alt3_v} = {14'h0860, 14'h0800};
            {alt4_m, alt4_v} = {14'h3fcf, 14'h0008};
            alt_shift        = 3'd3;
            {add1_m, add1_v} = {14'h3fff, 14'h049b};
            {add2_m, add2_v} = {14'h3fff, 14'h049c};
            {ap1_m,  ap1_v}  = {14'h3fcf, 14'h3ec7};
            {ap2_m,  ap2_v}  = {14'h3edf, 14'h3ed7};
            {add3_m, add3_v} = {14'h3fff, 14'h3fb2};
        end
        8'd114: begin   // Pit Fighter rev 9
            bank_sel = '{14'h0040, 14'h0048, 14'h0050, 14'h0058};
            {alt1_m, alt1_v} = {14'h007f, 14'h0016};
            {alt2_m, alt2_v} = {14'h3fff, 14'h24de};
            {alt3_m, alt3_v} = {14'h3871, 14'h0000};
            {alt4_m, alt4_v} = {14'h3fe7, 14'h0040};
            alt_shift        = 3'd1;
            {add1_m, add1_v} = {14'h3fff, 14'h0ab7};
            {add2_m, add2_v} = {14'h3fff, 14'h0ab8};
            {ap1_m,  ap1_v}  = {14'h3f63, 14'h0d40};
            {ap2_m,  ap2_v}  = {14'h3fd9, 14'h0dc8};
            {add3_m, add3_v} = {14'h3fff, 14'h0ab0};
        end
        8'd116: begin   // Hydra
            bank_sel = '{14'h0044, 14'h004c, 14'h0054, 14'h005c};
            {alt1_m, alt1_v} = {14'h007f, 14'h0069};
            {alt2_m, alt2_v} = {14'h3fff, 14'h2bab};
            {alt3_m, alt3_v} = {14'h387c, 14'h0808};
            {alt4_m, alt4_v} = {14'h3fe7, 14'h0044};
            alt_shift        = 3'd0;
            {add1_m, add1_v} = {14'h3fff, 14'h3f7c};
            {add2_m, add2_v} = {14'h3fff, 14'h3f7d};
            {ap1_m,  ap1_v}  = {14'h3db2, 14'h3c12};
            {ap2_m,  ap2_v}  = {14'h3fe3, 14'h3e43};
            {add3_m, add3_v} = {14'h3fff, 14'h2ba8};
        end
        default: ; // 0 = bootleg mode, handled separately below
        endcase
    end

    //------------------------------------------------------------------------
    // Address decode
    //------------------------------------------------------------------------
    wire [13:0] addr14 = cpu_addr[14:1];

    // The $2000 window mirrors every $2000 through $8000, so in_range compares
    // the top nine address bits: 9'h007 for Pit Fighter, 9'h00F for Hydra.
    wire [8:0]  range_tag = {window_base[7:0], 1'b1};
    wire        in_range  = (cpu_addr[23:15] == range_tag);

    // MAME checker primitives
    function automatic logic test_in (input [13:0] m, input [13:0] v);
        test_in  = in_range && ((addr14 & m) == v);
    endfunction
    function automatic logic test_any(input [13:0] m, input [13:0] v);
        test_any =             ((addr14 & m) == v);
    endfunction
    wire test_reset = in_range && (addr14 == 14'h0000);

    //------------------------------------------------------------------------
    // Sequence recognition FSM (types 111..118), after the slapstic.cpp
    // state classes:
    //   IDLE       wait for a reset access (offset 0 in range)
    //   ACTIVE     direct bank select, or start alt (alt1, any address) or
    //              additive (add1, in range)
    //   ALT_VALID  alt2 advances, add1 switches to additive, else break
    //   ALT_SELECT alt3 (any address) latches the bank from the address bits
    //   ADD_LOAD   add2 loads the current bank as the additive start value
    //   ADD_SET    any number of +1 / +2 accesses, then add3
    //   COMMIT     alt4 commits the pending bank (shared by alt and additive)
    // A break returns to ACTIVE. A reset access also returns to ACTIVE, not
    // IDLE, so a sequence can restart without re-arming.
    //------------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE, S_ACTIVE, S_ALT_VALID, S_ALT_SELECT, S_ADD_LOAD, S_ADD_SET, S_COMMIT
    } state_t;

    state_t     state;
    logic [1:0] loaded_bank;   // pending bank, committed by alt4

    // MAME: loaded_bank = (addr >> (1 + altshift)) & 3, i.e. addr14 >> altshift
    wire [1:0] alt_bank = (addr14 >> alt_shift) & 2'b11;

    //------------------------------------------------------------------------
    // Bootleg banking (chip_type 0): the simple scheme driven by the patched
    // program ROMs of the pitfightb set. Works only with those ROMs.
    //------------------------------------------------------------------------
    logic bs_primed;
    wire [13:0] bs_off = addr14 & 14'h1FFF;   // MAME: byte offset & 0x3FFF

    always_ff @(posedge clk) begin
        bank_changed <= 1'b0;

        if (!rst_n) begin
            // Types 111+ reset to bank 0 (bankstart is 0 for all supported types)
            state        <= S_IDLE;
            bank         <= 2'd0;
            loaded_bank  <= 2'd0;
            bs_primed    <= 1'b0;
            bank_changed <= 1'b1;
        end
        else if (acc_strobe) begin

            if (chip_type == 8'd0) begin
                // ---- Bootleg: access to offset 0, then a bank address ----
                if (bs_off == 14'h0000) begin
                    bs_primed <= 1'b1;
                end else if (bs_primed) begin
                    bs_primed <= 1'b0;
                    case (bs_off)
                        14'h0021: begin bank <= 2'd0; bank_changed <= 1'b1; end // $42>>1
                        14'h0029: begin bank <= 2'd1; bank_changed <= 1'b1; end // $52>>1
                        14'h0031: begin bank <= 2'd2; bank_changed <= 1'b1; end // $62>>1
                        14'h0039: begin bank <= 2'd3; bank_changed <= 1'b1; end // $72>>1
                        default:       bs_primed <= 1'b1;
                    endcase
                end
            end
            else begin
                // ---- Real sequence recognition ----
                case (state)

                S_IDLE: begin
                    if (test_reset) state <= S_ACTIVE;
                end

                S_ACTIVE: begin
                    // Direct bank select
                    if      (in_range && addr14 == bank_sel[0]) begin
                        bank <= 2'd0; bank_changed <= 1'b1; state <= S_IDLE;
                    end
                    else if (in_range && addr14 == bank_sel[1]) begin
                        bank <= 2'd1; bank_changed <= 1'b1; state <= S_IDLE;
                    end
                    else if (in_range && addr14 == bank_sel[2]) begin
                        bank <= 2'd2; bank_changed <= 1'b1; state <= S_IDLE;
                    end
                    else if (in_range && addr14 == bank_sel[3]) begin
                        bank <= 2'd3; bank_changed <= 1'b1; state <= S_IDLE;
                    end
                    // alt1 matches at any address
                    else if (test_any(alt1_m, alt1_v)) state <= S_ALT_VALID;
                    else if (test_in (add1_m, add1_v)) state <= S_ADD_LOAD;
                    // Anything else: stay in ACTIVE (no break)
                end

                S_ALT_VALID: begin
                    if      (test_reset)               state <= S_ACTIVE;
                    else if (test_in(alt2_m, alt2_v))  state <= S_ALT_SELECT;
                    else if (test_in(add1_m, add1_v))  state <= S_ADD_LOAD;
                    else                               state <= S_ACTIVE; // break
                end

                S_ALT_SELECT: begin
                    if      (test_reset)                state <= S_ACTIVE;
                    else if (test_any(alt3_m, alt3_v)) begin
                        loaded_bank <= alt_bank;
                        state       <= S_COMMIT;
                    end
                    else                                state <= S_ACTIVE; // break
                end

                S_ADD_LOAD: begin
                    if      (test_reset)               state <= S_ACTIVE;
                    else if (test_in(add2_m, add2_v)) begin
                        // Starts from the currently selected bank, not zero
                        loaded_bank <= bank;
                        state       <= S_ADD_SET;
                    end
                    else                               state <= S_ACTIVE; // break
                end

                S_ADD_SET: begin
                    // No break: other accesses are ignored, so the CPU can run
                    // arbitrary code between increments.
                    if      (test_reset)               state <= S_ACTIVE;
                    else if (test_in(ap1_m, ap1_v))    loaded_bank <= loaded_bank + 2'd1;
                    else if (test_in(ap2_m, ap2_v))    loaded_bank <= loaded_bank + 2'd2;
                    else if (test_in(add3_m, add3_v))  state <= S_COMMIT;
                end

                S_COMMIT: begin
                    if      (test_reset)               state <= S_ACTIVE;
                    else if (test_in(alt4_m, alt4_v)) begin
                        bank         <= loaded_bank;
                        bank_changed <= 1'b1;
                        state        <= S_IDLE;
                    end
                    // No break: keep waiting for alt4
                end

                default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
