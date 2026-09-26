//============================================================================
//  Atari G1 for MiSTer
//  g1_adc0809.sv -- ADC0809 analog converter (Hydra only)
//
//  Hydra reads three channels through an ADC0808/0809 at $FC8000-$FC8007:
//      channel 0   stick X    centre $80
//      channel 1   stick Y    centre $80
//      channel 2   pedal      rest   $00
//  A write selects the channel by word offset and starts a conversion; a read
//  returns the result in D[15:8]. IN0 bit 13 is EOC (active high). On Pit
//  Fighter these addresses are IN1 and this block is bypassed (game_id).
//
//  Timing follows MAME adc0808.cpp. The ADC clock is 14.318181 MHz / 16
//  (894.9 kHz, atarig1.cpp) = 64 clk_sys. From the start write, in ADC clocks:
//      +2   input sampled into the result register, EOC low
//      +66  conversion ends, input sampled again, EOC high
//  Hydra does not poll EOC: it starts the next channel, runs other code and
//  then reads, so the result must update at the early sample point.
//
//  MiSTer sticks report signed -127..+127; offset binary 0..255 is the sign
//  bit inverted.
//
//  Clock domain: clk_sys
//============================================================================

`default_nettype none

module g1_adc0809 #(
    // In clk_sys cycles: 2 and 66 ADC clocks of 64 clk_sys each
    parameter int SAMPLE_CYCLES = 128,
    parameter int CONV_CYCLES   = 4224
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- Analog sources ----
    input  wire [15:0] stick,        // {Y[15:8], X[7:0]}, signed -127..+127
    input  wire [7:0]  pedal,        // unsigned 0..255
    input  wire [1:0]  sensitivity,  // OSD: 0 medium (100%), 1 high, 2/3 low

    // ---- CPU side ----
    input  wire [1:0]  chan_sel,     // word offset from $FC8000
    input  wire        start,        // a write to $FC8000-$FC8007
    output logic [7:0] data,
    output logic       eoc           // end of conversion, active high
);

    //------------------------------------------------------------------------
    // Sensitivity scaling: Low 50%, Medium 100% (default, full stick = full
    // yoke), High 150%. Scaling happens before the offset conversion so the
    // centre stays exactly $80. The axis must be in a signed variable first:
    // a concatenation is unsigned, which breaks >>> and * for left and up.
    //------------------------------------------------------------------------
    function automatic [7:0] to_adc(input signed [7:0] axis);
        logic signed [9:0] a, scaled;
        begin
            a = axis;                                        // sign-extends
            case (sensitivity)
                2'd0:    scaled = a;                         // Medium, 100%
                2'd1:    scaled = (a * 10'sd3) >>> 1;        // High, 150%
                default: scaled = a >>> 1;                   // Low, 50%
            endcase
            // Saturate, then invert the sign bit for offset binary
            if      (scaled >  10'sd127) to_adc = 8'hFF;
            else if (scaled < -10'sd128) to_adc = 8'h00;
            else                         to_adc = {~scaled[7], scaled[6:0]};
        end
    endfunction

    wire [7:0] ch0 = to_adc(stick[7:0]);    // X
    wire [7:0] ch1 = to_adc(stick[15:8]);   // Y
    wire [7:0] ch2 = pedal;

    //------------------------------------------------------------------------
    // Conversion sequencer
    //------------------------------------------------------------------------
    localparam int CNT_W = $clog2(CONV_CYCLES + 1);

    logic [CNT_W-1:0] cnt;
    logic             converting;
    logic [1:0]       cur_chan;

    logic [7:0] chan_value;
    always_comb begin
        case (cur_chan)
            2'd0:    chan_value = ch0;
            2'd1:    chan_value = ch1;
            2'd2:    chan_value = ch2;
            default: chan_value = 8'h00;   // channel 3 unused on Hydra
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            converting <= 1'b0;
            cnt        <= '0;
            data       <= 8'h80;   // centred until the first conversion
            eoc        <= 1'b1;
        end
        else if (start) begin
            // EOC keeps its state until the sample point, as in MAME
            cur_chan   <= chan_sel;
            converting <= 1'b1;
            cnt        <= '0;
        end
        else if (converting) begin
            if (cnt == CNT_W'(SAMPLE_CYCLES)) begin
                data <= chan_value;
                eoc  <= 1'b0;
            end
            if (cnt >= CNT_W'(CONV_CYCLES)) begin
                converting <= 1'b0;
                eoc        <= 1'b1;
                data       <= chan_value;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
