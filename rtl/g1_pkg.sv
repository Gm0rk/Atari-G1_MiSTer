//============================================================================
//  Atari G1 for MiSTer
//  g1_pkg.sv -- shared constants, types and SDRAM map
//
//  Everything more than one module must agree on: video timing, palette and
//  framebuffer geometry, the SDRAM region map, the RLE encoding modes and the
//  MRA configuration byte layout. Per-game behaviour comes from the MRA
//  config bytes at runtime (g1_cfg_t), not from separate builds.
//============================================================================

`ifndef G1_PKG_SV
`define G1_PKG_SV

package g1_pkg;

    //------------------------------------------------------------------------
    // Video timing
    //------------------------------------------------------------------------
    // MAME set_raw(14.318181MHz/2, 456, 0, 336, 262, 0, 240): 7.159 MHz dot
    // clock, 15.700 kHz line, 59.923 Hz frame. MAME's totals come from published
    // specs; the porch/sync split of the blanking is chosen for a standard
    // 15 kHz CRT.
    //------------------------------------------------------------------------
    localparam int H_TOTAL    = 456;
    localparam int H_VISIBLE  = 336;
    localparam int H_FRONT    = 16;   // dots between end of active and HSYNC
    localparam int H_SYNC     = 36;   // ~5.0 us at 7.159 MHz
    localparam int H_BACK     = H_TOTAL - H_VISIBLE - H_FRONT - H_SYNC; // 68

    localparam int V_TOTAL    = 262;
    localparam int V_VISIBLE  = 240;
    localparam int V_FRONT    = 6;
    localparam int V_SYNC     = 3;
    localparam int V_BACK     = V_TOTAL - V_VISIBLE - V_FRONT - V_SYNC; // 13

    localparam int HCNT_W     = 9;    // 0..455
    localparam int VCNT_W     = 9;    // 0..261

    //------------------------------------------------------------------------
    // Palette: 1280 entries of 16-bit IRGB-1555 at CPU $FE8000-$FE89FF.
    // Layer bases: $100 alpha (16 banks x 16), $200 motion objects,
    // $300 playfield (8 banks x 32). $000-$0FF and $400-$4FF are spare.
    //------------------------------------------------------------------------
    localparam int PAL_ENTRIES = 1280;
    localparam int PAL_AW      = 11;  // 0..1279

    localparam [9:0] PAL_BASE_ALPHA = 10'h100;
    localparam [9:0] PAL_BASE_MO    = 10'h200;
    localparam [9:0] PAL_BASE_PF    = 10'h300;

    //------------------------------------------------------------------------
    // Motion object framebuffer: 336 x 240, double buffered, 10 bits per pixel.
    // A 6bpp object can reach palette index $200 + (color<<4) + $3F = $32F,
    // which needs more than 8 bits (only the self-test pattern, object 2, is
    // 6bpp in either game).
    //------------------------------------------------------------------------
    localparam int MO_FB_W     = H_VISIBLE;          // 336
    localparam int MO_FB_H     = V_VISIBLE;          // 240
    localparam int MO_FB_BPP   = 10;
    localparam int MO_FB_PIXELS= MO_FB_W * MO_FB_H;  // 80,640
    localparam int MO_FB_AW    = 17;

    //------------------------------------------------------------------------
    // Tile geometry
    //------------------------------------------------------------------------
    localparam int PF_TILES    = 16384;  // playfield tiles present in ROM
    localparam int PF_CODE_W   = 14;
    localparam int ALPHA_TILES = 4096;

    // The playfield code is (bank[2:0] << 12) | data[11:0], 15 bits, but only
    // 16384 tiles exist. MAME gfx_element::get_data wraps (code % elements), so
    // bank bit 2 is ignored.
    localparam [14:0] PF_CODE_MASK = 15'h3FFF;

    // Build number, shown as BLD on the diagnostic overlay so a screenshot
    // identifies its sources. Incremented with every release of changed files.
    localparam [15:0] G1_BUILD = 16'd126;

    //------------------------------------------------------------------------
    // SDRAM region map (byte addresses). One layout for both games; the MRA
    // zero-fills regions a game does not use (Pit Fighter fills only 5 of the
    // 10 playfield ROMs). About 3.7 MB, within the base 32 MB SDRAM.
    //------------------------------------------------------------------------
    localparam [24:0] SDR_PROG     = 25'h000000; // 512 KB  68000 program ROM
    localparam [24:0] SDR_RLE      = 25'h080000; //   2 MB  RLE object ROM
    localparam [24:0] SDR_PF03     = 25'h280000; // 512 KB  playfield planes 0-3
    localparam [24:0] SDR_PF4      = 25'h300000; // 128 KB  playfield plane 4
    localparam [24:0] SDR_ALPHA    = 25'h320000; // 128 KB  alpha characters
    localparam [24:0] SDR_OKI      = 25'h340000; // 256 KB  OKI6295 samples
    localparam [24:0] SDR_JSA      = 25'h380000; //  64 KB  JSA II 6502 ROM
    localparam [24:0] SDR_PROM     = 25'h390000; // 1.5 KB  growth renderer PROMs

    //------------------------------------------------------------------------
    // RLE encoding modes: object header word 2, bits [10:8]. MAME's lookup
    // tables all reduce to bit slicing (see g1_rle_decode.sv).
    //
    //   mode  bpp  special   meaning
    //     0    4     no      value = b[3:0], run = b[7:4]+1
    //     1    5    yes      low nibble 0 -> 4bpp form (long transparent run)
    //     2    5     no      value = b[4:0], run = b[7:5]+1
    //     3    5     no      (duplicate of mode 2)
    //     4    6    yes
    //     5    6     no      value = b[5:0], run = b[7:6]+1
    //     6    6    yes      (duplicate of mode 4)
    //     7    6     no      (duplicate of mode 5)
    //
    // Both G1 ROM sets use only modes 0, 2 and 5; the rest are kept for
    // completeness (the same engine is used by Atari G42 / GX2 / GT).
    //------------------------------------------------------------------------
    function automatic [2:0] rle_mode_bpp(input [2:0] mode);
        case (mode)
            3'd0:            rle_mode_bpp = 3'd4;
            3'd1,3'd2,3'd3:  rle_mode_bpp = 3'd5;
            default:         rle_mode_bpp = 3'd6;
        endcase
    endfunction

    function automatic rle_mode_special(input [2:0] mode);
        rle_mode_special = (mode == 3'd1) || (mode == 3'd4) || (mode == 3'd6);
    endfunction

    // End-of-object row header. In both ROM sets every object ends with one
    // $FFFF, the only value with bit 15 set. MAME's general form is "if bit 15,
    // XOR with $FFFF".
    localparam [15:0] RLE_ROW_TERMINATOR = 16'hFFFF;

    //------------------------------------------------------------------------
    // MRA configuration bytes (ioctl_index == 1). Everything that differs
    // between games and ROM revisions, so one .rbf serves all of them.
    //------------------------------------------------------------------------
    typedef struct packed {
        logic [7:0] game_id;      // 0 = Hydra, 1 = Pit Fighter
        logic [7:0] slap_type;    // 0 = none/bootleg, else 111..116
        logic [7:0] slap_base;    // window base >> 16 ($03 or $07)
        logic [7:0] mo_left;      // MO clip left  (0 Hydra, 40 Pit Fighter)
        logic [7:0] mo_right;     // MO clip right bits [7:0]; bit 8 in flags[2]
                                  // (Pit Fighter: 295)
        logic [7:0] pf_xoffset;   // playfield scroll X bias (0 or 2)
        logic [7:0] flags;        // bit0 = has ADC0809
                                  // bit1 = 3-player
                                  // bit2 = MO clip right bit 8
        logic [7:0] rle_objects_h;// precomputed object count, high byte
        logic [7:0] rle_objects_l;// precomputed object count, low byte
    } g1_cfg_t;

    localparam int CFG_BYTES = 9;

    // RLE header entries per game, for checking the load-time prescan:
    //   Hydra       : 768 entries,  691 valid, 77 null
    //   Pit Fighter : 1312 entries, 1298 valid, 14 null
    localparam [15:0] RLE_OBJCOUNT_HYDRA    = 16'd768;
    localparam [15:0] RLE_OBJCOUNT_PITFIGHT = 16'd1312;

endpackage

`endif
