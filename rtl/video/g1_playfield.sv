//============================================================================
//  Atari G1 for MiSTer
//  g1_playfield.sv -- playfield layer, 64 x 64 tiles of 8 x 8 at 5bpp
//
//  Tile RAM at CPU $FF4000-$FF5FFF. Scroll and tile bank come from g1_scroll,
//  which reads them from alpha tile RAM. Follows MAME get_playfield_tile_info.
//
//  Tile word:
//    bit    15   horizontal flip (tileinfo flags = TILE_FLIPX)
//    bits 14:12  colour bank
//    bits 11:0   tile code, low 12 bits
//  code = ((tile_bank << 12) | data[11:0]) & $3FFF. Only 16384 tiles exist
//  and MAME wraps with code % elements, so bank bit 2 is a don't-care; the
//  mask also keeps fetches inside the ROM region.
//  Palette index = $300 + (colour << 5) + pixel.
//
//  5bpp ROM layout (MAME pflayout + pftoplayout + blend_gfx(0, 2, $0F, $10)):
//  planeoffset {0, 0, 1, 2, 3} repeats offset 0 for the placeholder plane that
//  blend_gfx masks off, so the four real planes are four consecutive bits and
//  each nibble is one pixel, MSB first. With A = RGN_FRAC(2,5), xoffset
//  {A+0, A+4, 0, 4, A+8, A+12, 8, 12} gives a fixed permutation:
//      x0 = hi[15:12]   x1 = hi[11:8]   x2 = lo[15:12]  x3 = lo[11:8]
//      x4 = hi[7:4]     x5 = hi[3:0]    x6 = lo[7:4]    x7 = lo[3:0]
//  The MRA's <interleave output="32"> pairs the even/odd plane ROMs so hi and
//  lo are consecutive SDRAM words. Plane 4 is a separate region: one byte per
//  tile row, bit 7 leftmost, adding $10.
//
//  Clock domain: clk_sys.
//============================================================================

`default_nettype none

module g1_playfield
    import g1_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    // Fetch 'line' into the back buffer. Pulse only after g1_scroll has
    // latched this line's scroll values, or the playfield shears by a line.
    input  wire         start,
    input  wire [8:0]   line,

    // ---- Scroll state (from g1_scroll) ------------------------------------
    input  wire [8:0]   xscroll,
    input  wire [8:0]   yscroll,
    input  wire [2:0]   tile_bank,

    // ---- Work RAM read port (tile map) ------------------------------------
    output logic [14:0] vram_addr,
    output logic        vram_req,
    input  wire [15:0]  vram_dout,
    input  wire         vram_ack,

    // ---- SDRAM read port (tile ROM) ---------------------------------------
    output logic [24:0] rom_addr,
    output logic        rom_req,
    input  wire [15:0]  rom_dout,
    input  wire         rom_ack,

    // ---- Display side -----------------------------------------------------
    input  wire [8:0]   disp_x,
    output logic [4:0]  disp_pixel,    // 5bpp pen
    output logic [2:0]  disp_color,
    output logic        disp_prio,     // tile bit 15 = X flip; the mixer ignores it
    output logic        busy
);

    // Playfield tile RAM at CPU $FF4000 -> work RAM word offset $2000.
    localparam [14:0] PF_WORD_BASE = 15'h2000;

    // 336 visible pixels plus one tile of slop for the fine scroll offset.
    localparam int TILES_PER_LINE = 43;
    localparam int LBUF_SIZE      = 344;

    //------------------------------------------------------------------------
    // Ping-pong line buffers, {prio, colour[2:0], pixel[4:0]}
    //------------------------------------------------------------------------
    // One pixel written per clock (8 clocks per tile): writing a whole tile
    // row at once needs eight write ports, which will not infer as block RAM.
    // A flat 1-D array with the buffer select as the top address bit infers
    // more reliably than [2][N]. Sized to the addressing ({sel, x} =
    // sel*512 + x), not to the entry count.
    logic [8:0] lbuf [1024];
    logic       wr_sel;
    wire        rd_sel = ~wr_sel;

    // Fine horizontal scroll. The fetcher starts at the tile containing
    // source pixel xscroll, and writes tile n at buffer position n*8, so the
    // display reads at disp_x + (xscroll & 7).
    logic [2:0] fine_x;
    logic [8:0] rd_data;

    always_ff @(posedge clk)
        rd_data <= lbuf[{rd_sel, (disp_x + {6'd0, fine_x})}];

    assign disp_pixel = rd_data[4:0];
    assign disp_color = rd_data[7:5];
    assign disp_prio  = rd_data[8];

    //------------------------------------------------------------------------
    // Fetch engine
    //------------------------------------------------------------------------
    typedef enum logic [3:0] {
        F_IDLE, F_MAP_REQ, F_MAP_WAIT,
        F_HI_REQ, F_HI_WAIT, F_LO_REQ, F_LO_WAIT,
        F_P4_REQ, F_P4_WAIT, F_STORE
    } fstate_t;

    fstate_t     fstate;
    logic [2:0]  px;            // pixel within the tile row, 0..7
    logic [5:0]  tile_idx;      // 0..42, position along the line
    logic [8:0]  src_y;         // scrolled source row
    logic [5:0]  first_col;     // tilemap column of tile_idx 0
    logic [13:0] code;
    logic [2:0]  color;
    logic        prio;
    logic        flip_x;
    logic [15:0] w_hi, w_lo;
    logic [7:0]  p4;

    wire [2:0] row_in_tile = src_y[2:0];
    wire [5:0] tile_row    = src_y[8:3];              // 0..63
    wire [5:0] tile_col    = first_col + tile_idx;    // wraps at 64 naturally

    assign busy = (fstate != F_IDLE);

    //------------------------------------------------------------------------
    // Pixel select: pflayout column permutation (see header), indexed by the
    // store counter. Tile bit 15 is the flags argument of MAME's
    // tileinfo.set, i.e. TILE_FLIPX; a flip just reverses the pixel index.
    //------------------------------------------------------------------------
    wire [2:0] px_f = flip_x ? ~px : px;

    logic [3:0] nib;
    logic       p4_bit;
    always_comb begin
        case (px_f)
            3'd0: begin nib = w_hi[15:12]; p4_bit = p4[7]; end
            3'd1: begin nib = w_hi[11:8];  p4_bit = p4[6]; end
            3'd2: begin nib = w_lo[15:12]; p4_bit = p4[5]; end
            3'd3: begin nib = w_lo[11:8];  p4_bit = p4[4]; end
            3'd4: begin nib = w_hi[7:4];   p4_bit = p4[3]; end
            3'd5: begin nib = w_hi[3:0];   p4_bit = p4[2]; end
            3'd6: begin nib = w_lo[7:4];   p4_bit = p4[1]; end
            3'd7: begin nib = w_lo[3:0];   p4_bit = p4[0]; end
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fstate   <= F_IDLE;
            vram_req <= 1'b0;
            rom_req  <= 1'b0;
            wr_sel   <= 1'b0;
        end
        else if (start && fstate != F_IDLE) begin
            // Restart while busy: same per-line setup as F_IDLE (tile_col is
            // a wire here, so tile_idx is reset instead). Unsafe with a tile
            // ROM word in flight, whose ack would be taken as the next word's
            // data, so g1_video only pulses start when both fetchers are idle.
            src_y     <= (line + yscroll) & 9'h1FF;
            first_col <= xscroll[8:3];
            fine_x    <= xscroll[2:0];
            tile_idx  <= 6'd0;
            px        <= 3'd0;
            wr_sel    <= ~wr_sel;
            vram_req  <= 1'b0;
            rom_req   <= 1'b0;
            fstate    <= F_MAP_REQ;
        end
        else begin
            case (fstate)

            F_IDLE: begin
                if (start) begin
                    // Source row = display line + Y scroll, wrapped to the
                    // 512-pixel playfield. g1_scroll has already folded the
                    // per-scanline bias into yscroll.
                    src_y     <= (line + yscroll) & 9'h1FF;
                    first_col <= xscroll[8:3];
                    fine_x    <= xscroll[2:0];
                    tile_idx  <= 6'd0;
                    px        <= 3'd0;
                    wr_sel    <= ~wr_sel;
                    fstate    <= F_MAP_REQ;
                end
            end

            // ---- Tile map -------------------------------------------------
            F_MAP_REQ: begin
                vram_addr <= PF_WORD_BASE
                           + {3'd0, tile_row, 6'd0}    // tile_row * 64
                           + {9'd0, tile_col};
                vram_req  <= 1'b1;
                fstate    <= F_MAP_WAIT;
            end

            F_MAP_WAIT: begin
                if (vram_ack) begin
                    vram_req <= 1'b0;
                    // code = (bank << 12) | data[11:0], wrapped to 16384 tiles
                    code   <= ({tile_bank, vram_dout[11:0]}) & PF_CODE_MASK[13:0];
                    color  <= vram_dout[14:12];
                    prio   <= vram_dout[15];
                    flip_x <= vram_dout[15];   // TILE_FLIPX
                    fstate <= F_HI_REQ;
                end
            end

            // ---- Planes 0-3: two words, 32 bytes per tile, row r at 4r ----
            // The MRA puts the "even" ROM first: first word hi, second lo.
            F_HI_REQ: begin
                rom_addr <= SDR_PF03
                          + {6'd0, code, 5'd0}             // code * 32
                          + {20'd0, row_in_tile, 2'd0};    // row * 4
                rom_req  <= 1'b1;
                fstate   <= F_HI_WAIT;
            end

            F_HI_WAIT: begin
                if (rom_ack) begin
                    rom_req <= 1'b0;
                    w_hi    <= rom_dout;
                    fstate  <= F_LO_REQ;
                end
            end

            F_LO_REQ: begin
                rom_addr <= SDR_PF03
                          + {6'd0, code, 5'd0}
                          + {20'd0, row_in_tile, 2'd0}
                          + 25'd2;
                rom_req  <= 1'b1;
                fstate   <= F_LO_WAIT;
            end

            F_LO_WAIT: begin
                if (rom_ack) begin
                    rom_req <= 1'b0;
                    w_lo    <= rom_dout;
                    fstate  <= F_P4_REQ;
                end
            end

            // ---- Plane 4: one byte per tile row ---------------------------
            // 8 bytes per tile. Read the containing 16-bit word and pick the
            // byte: even address -> D[15:8], odd -> D[7:0] (big-endian load).
            F_P4_REQ: begin
                rom_addr <= SDR_PF4
                          + {8'd0, code, 3'd0}             // code * 8
                          + {22'd0, row_in_tile};
                rom_req  <= 1'b1;
                fstate   <= F_P4_WAIT;
            end

            F_P4_WAIT: begin
                if (rom_ack) begin
                    rom_req <= 1'b0;
                    p4      <= row_in_tile[0] ? rom_dout[7:0] : rom_dout[15:8];
                    fstate  <= F_STORE;
                end
            end

            // ---- Column permute and store ---------------------------------
            F_STORE: begin
                lbuf[{wr_sel, ({tile_idx,3'd0} + {6'd0, px})}]
                    <= {prio, color, p4_bit, nib};

                if (px == 3'd7) begin
                    px <= 3'd0;
                    if (tile_idx == TILES_PER_LINE - 1) begin
                        fstate <= F_IDLE;
                    end else begin
                        tile_idx <= tile_idx + 1'b1;
                        fstate   <= F_MAP_REQ;
                    end
                end else begin
                    px <= px + 1'b1;
                end
            end

            default: fstate <= F_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
