//============================================================================
//  Atari G1 for MiSTer
//  g1_ce.sv -- clock enable generator
//
//  The whole core runs on clk_sys with clock enables (one clock domain, no
//  CDC). clk_sys = 57.272724 MHz = 4 x the 14.318181 MHz master oscillator
//  = 8 x the 7.159090 MHz dot clock, so every main-board enable is an exact
//  integer divide.
//
//  fx68k takes two phase enables, enPhi1 and enPhi2, pulsed alternately half
//  a CPU clock apart. The CPU frequency is the enPhi1 rate, not the combined
//  rate of both.
//
//  The board clocks the 68000 from the 14.318 MHz oscillator at x1 (as MAME
//  does), though the fitted part is an MC68HC000P12F (12.5 MHz grade);
//  cpu_div2 selects 7.159 MHz instead at runtime.
//============================================================================

`default_nettype none

module g1_ce (
    input  wire  clk,         // clk_sys, 57.272724 MHz
    input  wire  rst_n,

    // 0 = 68000 at 14.318181 MHz (MAME, default)
    // 1 = 68000 at  7.159090 MHz
    // Safe to change at any time: the divider is free-running.
    input  wire  cpu_div2,

    output logic ce_pix,      //  7.159090 MHz dot clock

    // fx68k phase enables; the ce_cpu_p1 rate is the 68000 frequency
    output logic ce_cpu_p1,
    output logic ce_cpu_p2,

    output logic ce_14m,      // 14.318181 MHz master rate
    output logic ce_ym,       //  3.579545 MHz JSA II master / YM2151
    output logic ce_6502,     //  1.789773 MHz JSA II 6502
    output logic ce_oki       //  1.193182 MHz OKI6295 (JSA XTAL / 3)
);

    //------------------------------------------------------------------------
    // Main divider: div[1:0] == 0 -> 14.318181 MHz, div[2:0] == 0 -> 7.159 MHz
    //------------------------------------------------------------------------
    logic [2:0] div;

    always_ff @(posedge clk) begin
        if (!rst_n) div <= '0;
        else        div <= div + 1'b1;
    end

    always_comb begin
        ce_14m = (div[1:0] == 2'd0);
        ce_pix = (div[2:0] == 3'd0);

        if (cpu_div2) begin
            // 7.159090 MHz: phases 4 clk_sys apart
            ce_cpu_p1 = (div[2:0] == 3'd0);
            ce_cpu_p2 = (div[2:0] == 3'd4);
        end else begin
            // 14.318181 MHz: phases 2 clk_sys apart
            ce_cpu_p1 = (div[1:0] == 2'd0);
            ce_cpu_p2 = (div[1:0] == 2'd2);
        end
    end

    //------------------------------------------------------------------------
    // JSA II sound rates. The JSA II has its own 3.579545 MHz crystal,
    // independent of the main oscillator (the exact 4:1 ratio is the NTSC
    // colour burst relationship). Deriving it from clk_sys ignores the drift
    // between the two, which is inaudible, and keeps a single clock domain.
    //   clk_sys / 16 = 3.579545 MHz  (YM2151)
    //   clk_sys / 32 = 1.789773 MHz  (6502)
    //   YM rate / 3  = 1.193182 MHz  (OKI6295, PIN7 high)
    //------------------------------------------------------------------------
    logic [4:0] snd_div;
    logic [1:0] oki_div;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            snd_div <= '0;
            oki_div <= '0;
            ce_ym   <= 1'b0;
            ce_6502 <= 1'b0;
            ce_oki  <= 1'b0;
        end else begin
            snd_div <= snd_div + 1'b1;

            ce_ym   <= (snd_div[3:0] == 4'd0);
            ce_6502 <= (snd_div[4:0] == 5'd0);

            // OKI: modulo-3 count of YM-rate ticks
            ce_oki <= 1'b0;
            if (snd_div[3:0] == 4'd0) begin
                if (oki_div == 2'd2) begin
                    oki_div <= 2'd0;
                    ce_oki  <= 1'b1;
                end else begin
                    oki_div <= oki_div + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
