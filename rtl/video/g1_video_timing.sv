//============================================================================
//  Atari G1 for MiSTer
//  g1_video_timing.sv -- raster timing generator
//
//  456 x 262 raster, 336 x 240 visible, from a 7.159090 MHz dot enable
//  (MAME set_raw(14.318181 MHz / 2, 456, 0, 336, 262, 0, 240)). This is the
//  core's only raster timebase: the tile fetchers, MO framebuffer scan-out
//  and the 68000 VBLANK interrupt all key off its counters and strobes.
//
//  Clock domain: clk_sys, advanced by ce_pix (one pulse per dot).
//============================================================================

`default_nettype none

module g1_video_timing
    import g1_pkg::*;
#(
    // Porch/sync split. MAME's totals come from published specs; the split is
    // an estimate, so it is a parameter.
    parameter int P_H_FRONT = H_FRONT,
    parameter int P_H_SYNC  = H_SYNC,
    parameter int P_V_FRONT = V_FRONT,
    parameter int P_V_SYNC  = V_SYNC
)(
    input  wire                 clk,       // clk_sys
    input  wire                 rst_n,
    input  wire                 ce_pix,    // 7.159090 MHz dot enable

    // Raster position. Valid on every ce_pix.
    output logic [HCNT_W-1:0]   hcnt,      // 0 .. H_TOTAL-1
    output logic [VCNT_W-1:0]   vcnt,      // 0 .. V_TOTAL-1

    // Blanking, syncs (active high) and display enable, registered.
    output logic                hblank,
    output logic                vblank,
    output logic                hsync,
    output logic                vsync,
    output logic                de,        // active display area

    // Strobes, one clk_sys cycle wide.
    output logic                line_start,   // hcnt wrapped to 0
    output logic                frame_start,  // vcnt wrapped to 0
    output logic                vblank_rise,  // entering vertical blanking
    output logic                vblank_fall,  // leaving  vertical blanking

    // Position within the visible area; 0 during blanking.
    output logic [8:0]          vis_x,     // 0 .. H_VISIBLE-1  (0..335)
    output logic [7:0]          vis_y      // 0 .. V_VISIBLE-1  (0..239)
);

    // Derived edge positions. Active video occupies dots 0..H_VISIBLE-1, then
    // front porch, sync, back porch. Same ordering vertically.
    localparam int HS_START = H_VISIBLE + P_H_FRONT;
    localparam int HS_END   = HS_START  + P_H_SYNC;
    localparam int VS_START = V_VISIBLE + P_V_FRONT;
    localparam int VS_END   = VS_START  + P_V_SYNC;

    //------------------------------------------------------------------------
    // Raster counters
    //------------------------------------------------------------------------
    logic h_wrap, v_wrap;

    always_comb begin
        h_wrap = (hcnt == HCNT_W'(H_TOTAL - 1));
        v_wrap = h_wrap && (vcnt == VCNT_W'(V_TOTAL - 1));
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hcnt <= '0;
            vcnt <= '0;
        end else if (ce_pix) begin
            if (h_wrap) begin
                hcnt <= '0;
                vcnt <= v_wrap ? '0 : (vcnt + 1'b1);
            end else begin
                hcnt <= hcnt + 1'b1;
            end
        end
    end

    //------------------------------------------------------------------------
    // Blanking, sync and display enable
    //------------------------------------------------------------------------
    // Decoded from the counters and registered on ce_pix, so these lag
    // hcnt/vcnt by one dot. The *_n names mean "next", not active low.
    //------------------------------------------------------------------------
    logic hblank_n, vblank_n, hsync_n, vsync_n;

    always_comb begin
        hblank_n = (hcnt >= HCNT_W'(H_VISIBLE));
        vblank_n = (vcnt >= VCNT_W'(V_VISIBLE));
        hsync_n  = (hcnt >= HCNT_W'(HS_START)) && (hcnt < HCNT_W'(HS_END));
        vsync_n  = (vcnt >= VCNT_W'(VS_START)) && (vcnt < VCNT_W'(VS_END));
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hblank <= 1'b1;
            vblank <= 1'b1;
            hsync  <= 1'b0;
            vsync  <= 1'b0;
            de     <= 1'b0;
        end else if (ce_pix) begin
            hblank <= hblank_n;
            vblank <= vblank_n;
            hsync  <= hsync_n;
            vsync  <= vsync_n;
            de     <= !hblank_n && !vblank_n;
        end
    end

    //------------------------------------------------------------------------
    // Strobes
    //------------------------------------------------------------------------
    // vblank_rise sets the 68000's IRQ1 (cleared by a write to $FB0000) and
    // cues the MO framebuffer's end-of-frame erase.
    //------------------------------------------------------------------------
    logic vblank_d;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            vblank_d    <= 1'b1;
            line_start  <= 1'b0;
            frame_start <= 1'b0;
            vblank_rise <= 1'b0;
            vblank_fall <= 1'b0;
        end else begin
            line_start  <= 1'b0;
            frame_start <= 1'b0;
            vblank_rise <= 1'b0;
            vblank_fall <= 1'b0;

            if (ce_pix) begin
                vblank_d    <= vblank_n;
                line_start  <= h_wrap;
                frame_start <= v_wrap;
                vblank_rise <=  vblank_n && !vblank_d;
                vblank_fall <= !vblank_n &&  vblank_d;
            end
        end
    end

    //------------------------------------------------------------------------
    // Visible-area coordinates
    //------------------------------------------------------------------------
    // Forced to 0 in blanking, so a consumer that ignores de reads pixel 0
    // rather than indexing a buffer out of range.
    //------------------------------------------------------------------------
    always_comb begin
        vis_x = hblank ? 9'd0 : hcnt[8:0];
        vis_y = vblank ? 8'd0 : vcnt[7:0];
    end

`ifdef SIMULATION
    // The porch split must fill the blanking period exactly, or the frame
    // rate drifts from 59.923 Hz.
    initial begin
        if (H_VISIBLE + P_H_FRONT + P_H_SYNC + H_BACK != H_TOTAL)
            $fatal(1, "g1_video_timing: horizontal porches do not sum to H_TOTAL");
        if (V_VISIBLE + P_V_FRONT + P_V_SYNC + V_BACK != V_TOTAL)
            $fatal(1, "g1_video_timing: vertical porches do not sum to V_TOTAL");
    end
`endif

endmodule

`default_nettype wire
