//============================================================================
//  Atari G1 for MiSTer
//  g1_mixer.sv -- layer compositing
//
//  Fixed order, no inter-layer priority, as MAME atarig1_state::screen_update
//  (playfield draw, copybitmap_trans of the MO bitmap with colour 0
//  transparent, alpha draw). Bottom to top:
//      playfield        opaque, pen 0 is drawn
//      motion objects   index 0 transparent
//      alpha            pen 0 transparent unless the opaque flag is set
//  The RLE priority mask is 0 on G1; the RLE order field (the "256 priority
//  levels") only sorts objects within the MO layer.
//
//  Palette bases:
//      $100 + (colour << 4) + pixel   alpha, 16 banks x 16
//      $200 + (colour << 4) + pixel   motion objects
//      $300 + (colour << 5) + pixel   playfield, 8 banks x 32
//  The MO index arrives as a full 10-bit palette offset: a 6bpp object can
//  reach $200 + $F0 + $3F = $32F (see g1_pkg::MO_FB_BPP).
//
//  Clock domain: clk_sys, one registered stage.
//============================================================================

`default_nettype none

module g1_mixer
    import g1_pkg::*;
(
    input  wire         clk,
    input  wire         de,           // active display area

    // ---- Playfield --------------------------------------------------------
    input  wire [4:0]   pf_pixel,
    input  wire [2:0]   pf_color,
    input  wire         pf_prio,      // tile bit 15 (X flip); unused

    // ---- Motion objects ---------------------------------------------------
    // Full palette offset including the $200 base and colour bank; 0 = none.
    input  wire [9:0]   mo_index,
    input  wire         mo_enable,    // motion object layer enable

    // ---- Alpha ------------------------------------------------------------
    input  wire [3:0]   al_pixel,
    input  wire [3:0]   al_color,
    input  wire         al_opaque,

    // ---- Output -----------------------------------------------------------
    output logic [PAL_AW-1:0] pal_index
);

    //------------------------------------------------------------------------
    // Transparency. The playfield has none. The MO framebuffer holds 0 where
    // nothing is drawn (including erased pixels). Alpha pen 0 is transparent
    // unless the tile's opaque flag is set (TILE_FORCE_LAYER0).
    //------------------------------------------------------------------------
    wire mo_visible = mo_enable && (mo_index != 10'd0);
    wire al_visible = (al_pixel != 4'd0) || al_opaque;

    always_ff @(posedge clk) begin
        if (!de) begin
            // Entry 0 outside the active area: the scaler can sample during
            // blanking, and a stale index shows as a coloured border.
            pal_index <= '0;
        end
        else if (al_visible) begin
            pal_index <= PAL_BASE_ALPHA + {3'd0, al_color, al_pixel};
        end
        else if (mo_visible) begin
            // Already a complete palette offset.
            pal_index <= {1'b0, mo_index};
        end
        else begin
            pal_index <= PAL_BASE_PF + {3'd0, pf_color, pf_pixel};
        end
    end

endmodule

`default_nettype wire
