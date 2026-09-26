//============================================================================
//  Atari G1 for MiSTer
//  g1_watchdog.sv -- watchdog timer at $F80000
//
//  MAME uses a WATCHDOG_TIMER with the default period: reset the CPU if no
//  write is seen for 3 seconds (180 frames at 59.923 Hz). Counts frames
//  rather than clk_sys cycles, like the board's watchdog, which is clocked
//  from video timing. The OSD can disable it.
//
//  Clock domain: clk_sys
//============================================================================

`default_nettype none

module g1_watchdog #(
    parameter int TIMEOUT_FRAMES = 180   // frames without a kick before reset
)(
    input  wire  clk,
    input  wire  rst_n,

    input  wire  disable_wd,   // OSD: hold the watchdog off entirely
    input  wire  kick,         // one clock per write to $F80000
    input  wire  frame_tick,   // one clock per frame (vblank_rise)

    output logic wd_reset      // level: hold the 68000 in reset
);

    localparam int CNT_W = $clog2(TIMEOUT_FRAMES + 1);

    logic [CNT_W-1:0] count;

    // Reset is held for several frames once it fires, like the board's RC
    // reset circuit.
    localparam int HOLD_FRAMES = 4;
    logic [2:0] hold;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            count    <= '0;
            hold     <= '0;
            wd_reset <= 1'b0;
        end
        else if (disable_wd) begin
            // Fully cleared, so re-enabling mid-game cannot fire a stale timeout
            count    <= '0;
            hold     <= '0;
            wd_reset <= 1'b0;
        end
        else begin
            if (kick) count <= '0;

            if (hold != 0) begin
                // Counting out the reset pulse
                if (frame_tick) begin
                    hold <= hold - 1'b1;
                    if (hold == 3'd1) wd_reset <= 1'b0;
                end
            end
            else if (frame_tick && !kick) begin
                if (count >= CNT_W'(TIMEOUT_FRAMES)) begin
                    wd_reset <= 1'b1;
                    hold     <= HOLD_FRAMES[2:0];
                    count    <= '0;
                end else begin
                    count <= count + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
