//============================================================================
//  Atari G1 for MiSTer
//  g1_hydra_controls.sv -- Hydra yoke and pedal from a MiSTer pad
//
//  Hydra has an X-Y flight yoke and a foot pedal, all potentiometers read
//  through the ADC0809 (g1_adc0809). The pedal is also the start control;
//  there is no start button (manual TM-354 table 1-3, MAME hydra ports).
//
//  Stick (ADC channels 0/1): the left analog stick. Inside its dead zone the
//  d-pad ramps the axis out by 10 per frame and back to centre by 20 (MAME
//  KEYDELTA 10). Once the analog stick leaves the dead zone it takes over and
//  the ramp clears, so the d-pad bits MiSTer derives from a deflected stick
//  never snap the axis to full lock.
//
//  Pedal (ADC channel 2): the largest of the Pedal button (ramps up 16 per
//  frame while held, MAME KEYDELTA 16, down 32 after release), the right
//  stick pushed up, and the paddle. All rest at 0 (MAME's rest value). The
//  game accepts either range: rest $00 / press $FF, or the pot's $AE / $2E.
//
//  Clock domain: clk_sys; frame_tick is one clock per frame (VBLANK start).
//============================================================================

`default_nettype none

module g1_hydra_controls #(
    parameter int DEADZONE   = 16,   // |analog| below this counts as centred
    parameter int STICK_OUT  = 10,   // d-pad ramp out, per frame
    parameter int STICK_BACK = 20,   // d-pad ramp back to centre, per frame
    parameter int PEDAL_UP   = 16,   // Pedal button ramp while held
    parameter int PEDAL_DOWN = 32,   // ... and after release
    parameter int RS_DEAD    = 8     // right-stick pedal dead zone
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_tick,

    input  wire [3:0]  dpad,         // MiSTer order: [0] right [1] left [2] down [3] up
    input  wire        pedal_btn,
    input  wire [15:0] l_analog,     // {Y[15:8], X[7:0]}, signed -127..+127
    input  wire [15:0] r_analog,     // same layout
    input  wire [7:0]  paddle,       // 0..255

    output logic [15:0] stick,       // {Y, X} signed, to g1_adc0809
    output logic [7:0]  pedal        // 0 = rest
);

    //------------------------------------------------------------------------
    // Stick: analog, with a d-pad ramp inside the dead zone
    //------------------------------------------------------------------------
    wire signed [7:0] ax = l_analog[7:0];
    wire signed [7:0] ay = l_analog[15:8];

    // Signed copies of the parameters: an unsigned operand would make the
    // comparisons below unsigned.
    localparam logic signed [7:0] DZ   = 8'(DEADZONE);
    localparam logic signed [9:0] OUT  = 10'(STICK_OUT);
    localparam logic signed [9:0] BACK = 10'(STICK_BACK);
    localparam logic signed [9:0] LIM  = 10'sd127;

    function automatic logic live(input logic signed [7:0] v);
        live = (v >= DZ) || (v <= -DZ);
    endfunction

    // One axis of ramp; pos/neg are the axis's two d-pad directions
    function automatic logic signed [7:0] step_axis(input logic signed [7:0] cur,
                                                    input logic pos, input logic neg,
                                                    input logic analog_live);
        logic signed [9:0] c, n;
        begin
            c = cur;                          // sign-extends: both signed
            if (analog_live)        n = '0;
            else if (pos && !neg)   n = c + OUT;
            else if (neg && !pos)   n = c - OUT;
            else if (c >  BACK)     n = c - BACK;
            else if (c < -BACK)     n = c + BACK;
            else                    n = '0;
            if      (n >  LIM) step_axis =  8'sd127;
            else if (n < -LIM) step_axis = -8'sd127;
            else               step_axis = n[7:0];
        end
    endfunction

    logic signed [7:0] rx, ry;
    wire lx = live(ax);
    wire ly = live(ay);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rx <= 8'sd0;
            ry <= 8'sd0;
        end
        else if (frame_tick) begin
            rx <= step_axis(rx, dpad[0], dpad[1], lx);   // right +, left -
            ry <= step_axis(ry, dpad[2], dpad[3], ly);   // down +, up -
        end
    end

    // Analog outside the dead zone wins; inside it an active ramp wins, else
    // the small analog value passes through for fine control near centre.
    wire [7:0] sx = lx ? ax : (rx != 8'sd0 ? rx : ax);
    wire [7:0] sy = ly ? ay : (ry != 8'sd0 ? ry : ay);
    assign stick = {sy, sx};

    //------------------------------------------------------------------------
    // Pedal
    //------------------------------------------------------------------------
    logic [7:0] pbtn;
    always_ff @(posedge clk) begin
        if (!rst_n)
            pbtn <= 8'd0;
        else if (frame_tick) begin
            if (pedal_btn)
                pbtn <= (pbtn > 8'(255 - PEDAL_UP))  ? 8'd255 : pbtn + 8'(PEDAL_UP);
            else
                pbtn <= (pbtn < 8'(PEDAL_DOWN))      ? 8'd0   : pbtn - 8'(PEDAL_DOWN);
        end
    end

    // Right stick up is negative Y. 9 bits so -(-128) does not overflow; x9/4
    // stretches the travel past the dead zone to the full 0..255.
    localparam logic signed [8:0] RSD = 9'(RS_DEAD);
    wire signed [8:0] rs_up  = -$signed({r_analog[15], r_analog[15:8]});
    wire signed [8:0] rs_net = rs_up - RSD;
    wire        [11:0] rs_mag = (rs_net > 9'sd0) ? ({3'd0, rs_net} * 12'd9) >> 2 : 12'd0;
    wire [7:0] prs = (rs_mag > 12'd255) ? 8'd255 : rs_mag[7:0];

    wire [7:0] p_ab = (pbtn > prs) ? pbtn : prs;
    assign pedal    = (p_ab > paddle) ? p_ab : paddle;

endmodule

`default_nettype wire
