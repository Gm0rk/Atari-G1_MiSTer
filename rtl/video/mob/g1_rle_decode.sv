//============================================================================
//  Atari G1 for MiSTer
//  g1_rle_decode.sv -- RLE packet decoder
//
//  Decodes one 8-bit RLE packet into a pixel value and a run length. MAME
//  builds lookup tables for this (build_rle_tables()), but every entry is a
//  bit-slice of its index, e.g. for 4bpp:
//
//      table[0][i] = (((i & 0xF0) + 0x10) << 4) | (i & 0x0F)
//      value = entry & 0xFF   ->  i[3:0]
//      run   = entry >> 8     ->  i[7:4] + 1
//
//  so the tables reduce to a few gates. Encoding modes (object header word 2,
//  bits 10:8):
//
//    mode  bpp  special   value       run
//      0    4     no      b[3:0]      b[7:4] + 1   (1..16)
//      1    5    yes      see below
//      2    5     no      b[4:0]      b[7:5] + 1   (1..8)
//      3    5     no      (same as 2)
//      4    6    yes      see below
//      5    6     no      b[5:0]      b[7:6] + 1   (1..4)
//      6    6    yes      (same as 4)
//      7    6     no      (same as 5)
//
//  A special mode uses the 4bpp form when the packet's low nibble is zero,
//  which gives transparent runs of up to 16 in a 5/6bpp object. Only modes
//  0, 2 and 5 occur in the G1 ROM sets (Hydra 420/270/1 objects, Pit Fighter
//  399/898/1); the special modes are implemented because the same engine is
//  used by Atari G42, GX2 and GT.
//
//  Combinational; no clock.
//============================================================================

`default_nettype none

module g1_rle_decode
    import g1_pkg::*;
(
    input  wire [2:0]  mode,       // object header word 2, bits 10:8

    // One RLE packet. Each ROM word holds two, low byte first; the callers
    // (g1_rle_render, g1_rle_prescan) handle the ordering.
    input  wire [7:0]  packet,

    output logic [5:0] value,      // pixel value, 0 = transparent
    output logic [4:0] run,        // run length, 1..16
    output logic       transparent // convenience: value == 0
);

    // Mode attributes come from g1_pkg so every decoder copy agrees.
    wire [2:0] bpp     = rle_mode_bpp(mode);
    wire       special = rle_mode_special(mode);

    // A "special" packet takes the 4bpp form when its low nibble is zero.
    wire       use_4bpp_form = special && (packet[3:0] == 4'h0);

    always_comb begin
        if (use_4bpp_form || (bpp == 3'd4)) begin
            // 4bpp form: 4-bit value, 4-bit run field. In a special mode the
            // low nibble is zero here, so this is a transparent run.
            value = {2'b00, packet[3:0]};
            run   = {1'b0, packet[7:4]} + 5'd1;   // 1..16
        end else if (bpp == 3'd5) begin
            // 5bpp: 5-bit value, 3-bit run field.
            value = {1'b0, packet[4:0]};
            run   = {2'b00, packet[7:5]} + 5'd1;  // 1..8
        end else begin
            // 6bpp: 6-bit value, 2-bit run field.
            value = packet[5:0];
            run   = {3'b000, packet[7:6]} + 5'd1; // 1..4
        end
    end

    assign transparent = (value == 6'd0);

`ifdef SIMULATION
    //------------------------------------------------------------------------
    // Simulation self-check against the arithmetic of MAME build_rle_tables()
    //------------------------------------------------------------------------
    // synthesis translate_off
    task automatic check(input [2:0] m, input [7:0] p,
                         input [5:0] exp_v, input [4:0] exp_r,
                         input string label);
        logic [5:0] v; logic [4:0] r; logic [2:0] b; logic sp;
        begin
            b  = rle_mode_bpp(m);
            sp = rle_mode_special(m);
            if ((sp && p[3:0] == 0) || b == 4) begin
                v = {2'b0, p[3:0]}; r = {1'b0, p[7:4]} + 1;
            end else if (b == 5) begin
                v = {1'b0, p[4:0]}; r = {2'b0, p[7:5]} + 1;
            end else begin
                v = p[5:0];         r = {3'b0, p[7:6]} + 1;
            end
            if (v !== exp_v || r !== exp_r)
                $fatal(1, "g1_rle_decode %s: mode=%0d packet=%02X -> v=%0d r=%0d, expected v=%0d r=%0d",
                       label, m, p, v, r, exp_v, exp_r);
        end
    endtask

    initial begin
        check(3'd0, 8'hF5, 6'd5,  5'd16, "4bpp");
        check(3'd2, 8'hE3, 6'h03, 5'd8,  "5bpp");
        check(3'd5, 8'hC1, 6'h01, 5'd4,  "6bpp");
        // Mode 1 (special): low nibble zero -> 4bpp form, else 5bpp form.
        check(3'd1, 8'hF0, 6'd0,  5'd16, "5bpp-special-transparent");
        check(3'd1, 8'hF1, 6'h11, 5'd8,  "5bpp-special-normal");
        $display("g1_rle_decode: all decode self-checks passed");
    end
    // synthesis translate_on
`endif

endmodule

`default_nettype wire
