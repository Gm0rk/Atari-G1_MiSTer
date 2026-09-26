//============================================================================
//  Atari G1 for MiSTer
//  g1_scroll.sv -- playfield scroll and tile bank, read from alpha tile RAM
//
//  G1 has no scroll registers. The playfield X scroll, Y scroll and tile bank
//  are stored per scanline in columns 48 and 49 of the alpha tilemap. From
//  MAME atarig1_state::scanline_update:
//
//      offset = (scanline / 8) * 64 + 48
//      for i in 0..7:
//          word = alpha_ram[offset++]              // column 48 + 2i
//          if word[15]:
//              xscroll = ((word >> 6) + pf_xoffset) & 0x1FF
//          word = alpha_ram[offset++]              // column 49 + 2i
//          if word[15]:
//              yscroll = ((word >> 6) - (scanline + i)) & 0x1FF
//              tile_bank = word & 7
//
//  so scanline S's words are at alpha word offsets
//  (S >> 3) * 64 + 48 + 2 * (S & 7) and the one after.
//
//  - A value latches only when its word has bit 15 set; otherwise the
//    previous value holds.
//  - Y scroll is relative to the scanline, so one stored value gives a
//    different scroll on each line (used for raster effects).
//  - Both scrolls wrap at 9 bits: the playfield is 512 x 512 pixels.
//  - The tile bank may change mid-frame; it only feeds later tile fetches.
//  - Columns 48-49 are also drawn as characters by the alpha layer (the games
//    keep them blank); g1_alpha does not special-case them.
//
//  Clock domain: clk_sys.
//============================================================================

`default_nettype none

module g1_scroll
    import g1_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    // Read the control words for scanline 'line', before the playfield fetch.
    input  wire         start,
    input  wire [8:0]   line,

    input  wire [7:0]   pf_xoffset,   // X scroll bias (MRA): 0 Hydra, 2 Pit Fighter

    // ---- Work RAM read port (arbitrated in g1_video) ----------------------
    output logic [14:0] vram_addr,
    output logic        vram_req,
    input  wire [15:0]  vram_dout,
    input  wire         vram_ack,

    // ---- Latched scroll state ---------------------------------------------
    output logic [8:0]  xscroll,
    output logic [8:0]  yscroll,
    output logic [2:0]  tile_bank,
    output logic        done
);

    // Alpha tile RAM at CPU $FF6000 -> work RAM word offset $3000.
    localparam [14:0] ALPHA_WORD_BASE = 15'h3000;

    typedef enum logic [2:0] {
        S_IDLE, S_REQ_X, S_WAIT_X, S_REQ_Y, S_WAIT_Y, S_DONE
    } state_t;

    state_t state;
    logic [8:0] cur_line;

    // Work RAM address of this scanline's X control word.
    wire [14:0] x_offset = ALPHA_WORD_BASE
                         + {cur_line[8:3], 6'd0}          // (S >> 3) * 64
                         + 15'd48
                         + {11'd0, cur_line[2:0], 1'b0};  // 2 * (S & 7)

    // MAME's "if (offset >= 0x800) return": alpha RAM is 2048 words. Never
    // true for the lines g1_video fetches (0-239).
    wire in_bounds = (x_offset - ALPHA_WORD_BASE) < 15'h800;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            xscroll   <= 9'd0;
            yscroll   <= 9'd0;
            tile_bank <= 3'd0;
            vram_req  <= 1'b0;
            done      <= 1'b0;
            cur_line  <= 9'd0;
        end
        else begin
            done <= 1'b0;

            case (state)

            S_IDLE: begin
                if (start) begin
                    cur_line <= line;
                    state    <= S_REQ_X;
                end
            end

            S_REQ_X: begin
                if (!in_bounds) begin
                    state <= S_DONE;
                end else begin
                    vram_addr <= x_offset;
                    vram_req  <= 1'b1;
                    state     <= S_WAIT_X;
                end
            end

            S_WAIT_X: begin
                if (vram_ack) begin
                    vram_req <= 1'b0;
                    if (vram_dout[15]) begin
                        xscroll <= (vram_dout[15:6] + {2'd0, pf_xoffset})
                                   & 9'h1FF;
                    end
                    state <= S_REQ_Y;
                end
            end

            S_REQ_Y: begin
                vram_addr <= x_offset + 15'd1;
                vram_req  <= 1'b1;
                state     <= S_WAIT_Y;
            end

            S_WAIT_Y: begin
                if (vram_ack) begin
                    vram_req <= 1'b0;
                    if (vram_dout[15]) begin
                        // Relative to the scanline; the 9-bit wrap is intended.
                        yscroll   <= (vram_dout[15:6] - cur_line) & 9'h1FF;
                        tile_bank <= vram_dout[2:0];
                    end
                    state <= S_DONE;
                end
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
