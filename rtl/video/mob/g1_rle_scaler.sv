//============================================================================
//  Atari G1 for MiSTer
//  g1_rle_scaler.sv -- per-object scaling arithmetic
//
//  Computes the destination origin, scaled size and Bresenham step sizes for
//  one object. Port of the setup half of MAME draw_rle_zoom():
//
//      scaled_xoffs = (scale * xoffs) >> 12
//      scaled_yoffs = (scale * yoffs) >> 12
//      if hflip: scaled_xoffs = ((scale * width) >> 12) - scaled_xoffs
//
//      sx = xpos - scaled_xoffs
//      sy = ypos - scaled_yoffs
//
//      scalex = scale << 4                       // 4.12 -> 16.16
//      scaled_width  = max(1, (scalex * width  + $7FFF) >> 16)
//      scaled_height = max(1, (scalex * height + $7FFF) >> 16)
//
//      dx = (width  << 16) / scaled_width        // source step per dest pixel
//      dy = (height << 16) / scaled_height
//
//  One scale field drives both axes: $1000 is 1:1, $0800 half, $2000 double.
//  Scale 0 skips the object. The +$7FFF rounds to nearest; truncating makes
//  objects a pixel narrow at some scales, visible as edge shimmer.
//
//  This runs once per object, so one shared multiplier and one sequential
//  divider suffice: about 70 clocks per object, for at most 256 objects per
//  frame. Pixel emission in g1_rle_render is the bottleneck.
//
//  Clock domain: clk_sys
//============================================================================

`default_nettype none

module g1_rle_scaler (
    input  wire                clk,
    input  wire                rst_n,

    // ---- Request ----------------------------------------------------------
    input  wire                start,
    input  wire [15:0]         scale,      // 4.12 fixed point
    input  wire [9:0]          width,      // from the prescan table
    input  wire [7:0]          height,     // from the prescan table
    input  wire signed [15:0]  xoffs,      // ROM header word 0, signed
    input  wire signed [15:0]  yoffs,      // ROM header word 1, signed
    input  wire signed [15:0]  xpos,       // descriptor word 2, sign extended
    input  wire signed [15:0]  ypos,       // descriptor word 3, sign extended
    input  wire                hflip,

    // ---- Result -----------------------------------------------------------
    output logic signed [15:0] sx,         // destination origin
    output logic signed [15:0] sy,
    output logic [15:0]        sw,         // scaled width, >= 1
    output logic [15:0]        sh,         // scaled height, >= 1
    output logic [25:0]        dx,         // 16.16 source step per dest pixel
    output logic [25:0]        dy,
    output logic               skip,       // scale == 0: do not render
    output logic               done,
    output logic               busy
);

    //------------------------------------------------------------------------
    // Shared signed multiplier
    //------------------------------------------------------------------------
    // One 26 x 17 signed multiply, sequenced. Registered operands make Quartus
    // infer a single DSP block rather than one per expression.
    //------------------------------------------------------------------------
    logic signed [25:0] mul_a;
    logic signed [16:0] mul_b;
    logic signed [42:0] mul_r;

    always_ff @(posedge clk) mul_r <= mul_a * mul_b;

    //------------------------------------------------------------------------
    // Shared restoring divider: 26-bit dividend / 16-bit divisor
    //------------------------------------------------------------------------
    // This block is the only driver of div_rem, div_quo, div_bit, div_run and
    // div_done; the sequencer drives div_num, div_den and the div_start pulse.
    // Do not assign these from the sequencer: two always_ff drivers on one
    // signal simulate but fail in Quartus. div_start both loads and launches.
    //------------------------------------------------------------------------
    logic [41:0] div_rem;
    logic [25:0] div_quo;
    logic [25:0] div_num;
    logic [15:0] div_den;
    logic [5:0]  div_bit;
    logic        div_run, div_done, div_start;

    // One trial subtraction per clock, MSB first.
    wire [41:0] div_shift = {div_rem[40:0], div_num[div_bit]};
    wire        div_fits  = (div_shift >= {26'd0, div_den});

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            div_run  <= 1'b0;
            div_done <= 1'b0;
            div_rem  <= '0;
            div_quo  <= '0;
            div_bit  <= '0;
        end
        else begin
            div_done <= 1'b0;

            if (div_start) begin
                // div_num and div_den are set before div_start and held for
                // the whole division.
                div_rem <= '0;
                div_quo <= '0;
                div_bit <= 6'd25;
                div_run <= 1'b1;
            end
            else if (div_run) begin
                div_rem          <= div_fits ? (div_shift - {26'd0, div_den})
                                             : div_shift;
                div_quo[div_bit] <= div_fits;

                if (div_bit == 6'd0) begin
                    div_run  <= 1'b0;
                    div_done <= 1'b1;
                end else begin
                    div_bit <= div_bit - 1'b1;
                end
            end
        end
    end

    //------------------------------------------------------------------------
    // Sequencer
    //------------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE,
        S_MUL_XOFF,  S_MUL_XOFF_R,
        S_MUL_YOFF,  S_MUL_YOFF_R,
        S_MUL_HFLIP, S_MUL_HFLIP_R,
        S_MUL_W,     S_MUL_W_R,
        S_MUL_H,     S_MUL_H_R,
        S_DIV_X,     S_DIV_X_W,
        S_DIV_Y,     S_DIV_Y_W,
        S_DONE
    } state_t;

    state_t state;

    logic signed [15:0] scaled_xoffs, scaled_yoffs;
    logic [19:0]        scalex;      // scale << 4, 16.16

    assign busy = (state != S_IDLE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            done      <= 1'b0;
            skip      <= 1'b0;
            div_start <= 1'b0;
        end
        else begin
            done      <= 1'b0;
            div_start <= 1'b0;   // single-clock pulse

            case (state)

            S_IDLE:
                if (start) begin
                    if (scale == 16'd0) begin
                        // MAME: if (scale == 0) continue
                        skip  <= 1'b1;
                        done  <= 1'b1;
                    end else begin
                        skip   <= 1'b0;
                        scalex <= {scale, 4'd0};
                        mul_a  <= {{10{xoffs[15]}}, xoffs};
                        mul_b  <= {1'b0, scale};
                        state  <= S_MUL_XOFF;
                    end
                end

            // ---- scaled_xoffs = (scale * xoffs) >> 12 -----------------
            S_MUL_XOFF: state <= S_MUL_XOFF_R;
            S_MUL_XOFF_R: begin
                scaled_xoffs <= mul_r[27:12];
                mul_a        <= {{10{yoffs[15]}}, yoffs};
                mul_b        <= {1'b0, scale};
                state        <= S_MUL_YOFF;
            end

            // ---- scaled_yoffs = (scale * yoffs) >> 12 -----------------
            S_MUL_YOFF: state <= S_MUL_YOFF_R;
            S_MUL_YOFF_R: begin
                scaled_yoffs <= mul_r[27:12];
                if (hflip) begin
                    mul_a <= {16'd0, width};
                    mul_b <= {1'b0, scale};
                    state <= S_MUL_HFLIP;
                end else begin
                    mul_a <= {6'd0, scalex};
                    mul_b <= {7'd0, width};
                    state <= S_MUL_W;
                end
            end

            // ---- hflip: scaled_xoffs = ((scale*width)>>12) - scaled_xoffs
            // The hotspot mirrors about the object's own scaled width.
            S_MUL_HFLIP: state <= S_MUL_HFLIP_R;
            S_MUL_HFLIP_R: begin
                scaled_xoffs <= mul_r[27:12] - scaled_xoffs;
                mul_a        <= {6'd0, scalex};
                mul_b        <= {7'd0, width};
                state        <= S_MUL_W;
            end

            // ---- scaled_width = max(1, (scalex*width + $7FFF) >> 16) --
            S_MUL_W: state <= S_MUL_W_R;
            S_MUL_W_R: begin
                sw    <= (mul_r[31:0] + 32'h7FFF) >> 16;
                mul_a <= {6'd0, scalex};
                mul_b <= {9'd0, height};
                state <= S_MUL_H;
            end

            S_MUL_H: state <= S_MUL_H_R;
            S_MUL_H_R: begin
                sh <= (mul_r[31:0] + 32'h7FFF) >> 16;

                // Clamp both sizes to at least 1: a sub-pixel object still
                // draws one pixel, and the divider never sees zero.
                if (sw == 16'd0) sw <= 16'd1;

                sx <= xpos - scaled_xoffs;
                sy <= ypos - scaled_yoffs;

                // dx = (width << 16) / scaled_width
                div_num <= {width, 16'd0};
                div_den <= (sw == 16'd0) ? 16'd1 : sw;
                state   <= S_DIV_X;
            end

            S_DIV_X: begin
                div_start <= 1'b1;      // one clock; the divider loads and runs
                state     <= S_DIV_X_W;
            end

            S_DIV_X_W:
                if (div_done) begin
                    dx <= div_quo;
                    if (sh == 16'd0) sh <= 16'd1;
                    div_num <= {8'd0, height, 16'd0};
                    div_den <= (sh == 16'd0) ? 16'd1 : sh;
                    state   <= S_DIV_Y;
                end

            S_DIV_Y: begin
                div_start <= 1'b1;
                state     <= S_DIV_Y_W;
            end

            S_DIV_Y_W:
                if (div_done) begin
                    dy    <= div_quo;
                    state <= S_DONE;
                end

            S_DONE: begin
                done  <= 1'b1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
