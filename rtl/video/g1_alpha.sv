//============================================================================
//  Atari G1 for MiSTer
//  g1_alpha.sv -- alpha (text) layer, 64 x 32 tiles of 8 x 8 at 4bpp
//
//  Tile RAM at CPU $FF6000-$FF6FFF; the layer does not scroll. Follows MAME
//  get_alpha_tile_info.
//
//  Tile word:
//    bit    15   opaque: pen 0 is drawn, not transparent (TILE_FORCE_LAYER0)
//    bits 15:12  colour bank -- four bits including the opaque bit, as in
//                MAME's (data >> 12) & $0F
//    bits 11:0   character code
//  Palette index = $100 + (colour << 4) + pixel.
//
//  Character ROM is gfx_8x8x4_packed_msb: 32 bytes per tile, row r at byte
//  4r, high nibble leftmost. The layout is linear, so it loads verbatim.
//  Character codes are ASCII ($41 = 'A').
//
//  Line N+1 is fetched into a ping-pong buffer while line N is displayed:
//  42 tiles x 3 accesses (map word, two ROM words) per 3648-clock line.
//
//  Clock domain: clk_sys.
//============================================================================

`default_nettype none

module g1_alpha
    import g1_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    // Fetch 'line' into the back buffer.
    input  wire         start,
    input  wire [8:0]   line,

    // ---- Work RAM read port (tile map) ------------------------------------
    output logic [14:0] vram_addr,
    output logic        vram_req,
    input  wire [15:0]  vram_dout,
    input  wire         vram_ack,

    // ---- SDRAM read port (character ROM) ----------------------------------
    output logic [24:0] rom_addr,
    output logic        rom_req,
    input  wire [15:0]  rom_dout,
    input  wire         rom_ack,

    // ---- Display side -----------------------------------------------------
    input  wire [8:0]   disp_x,       // 0..335
    output logic [3:0]  disp_pixel,   // 4bpp pen
    output logic [3:0]  disp_color,   // colour bank
    output logic        disp_opaque,  // pen 0 is drawn
    output logic        busy,

    // ---- Debug: alpha map contents ----------------------------------------
    output logic        dbg_map_nz,     // last map word read had a non-zero code
    output logic [15:0] dbg_map_word    // last non-zero map word read
);

    // Alpha tile RAM at CPU $FF6000 -> work RAM word offset $3000.
    localparam [14:0] ALPHA_WORD_BASE = 15'h3000;

    // 336 visible pixels = 42 tiles of 8.
    localparam int TILES_PER_LINE = 42;

    //------------------------------------------------------------------------
    // Ping-pong line buffers, {opaque, colour[3:0], pixel[3:0]}
    //------------------------------------------------------------------------
    // One pixel written per clock (8 clocks per tile): writing a whole tile
    // row at once needs eight write ports, which will not infer as block RAM.
    // A flat 1-D array with the buffer select as the top address bit infers
    // more reliably than [2][N]. 1024 deep, not 672: the address
    // {sel, x} = sel*512 + x reaches 847.
    logic [8:0] lbuf [1024];     // 2 buffers x 512 slots, 336 used per buffer
    logic       wr_sel;
    wire        rd_sel = ~wr_sel;

    logic [8:0] rd_data;
    always_ff @(posedge clk) rd_data <= lbuf[{rd_sel, disp_x}];

    assign disp_pixel  = rd_data[3:0];
    assign disp_color  = rd_data[7:4];
    assign disp_opaque = rd_data[8];

    //------------------------------------------------------------------------
    // Fetch engine
    //------------------------------------------------------------------------
    typedef enum logic [2:0] {
        F_IDLE, F_MAP_REQ, F_MAP_WAIT, F_ROM0_REQ, F_ROM0_WAIT,
        F_ROM1_REQ, F_ROM1_WAIT, F_STORE
    } fstate_t;

    fstate_t     fstate;
    logic [2:0]  px;            // pixel within the tile row, 0..7
    logic [5:0]  tile_col;      // 0..41
    logic [8:0]  cur_line;
    logic [11:0] code;
    logic [3:0]  color;
    logic        opaque;
    logic [15:0] rom_w0;        // pixels 0..3
    logic [15:0] rom_w1;        // pixels 4..7

    wire [2:0] row_in_tile = cur_line[2:0];
    wire [4:0] tile_row    = cur_line[7:3];   // 0..31 (240 lines / 8 = 30)

    assign busy = (fstate != F_IDLE);

    // Pixel nibble selected by the store counter.
    logic [3:0] nib;
    always_comb begin
        case (px)
            3'd0: nib = rom_w0[15:12];
            3'd1: nib = rom_w0[11:8];
            3'd2: nib = rom_w0[7:4];
            3'd3: nib = rom_w0[3:0];
            3'd4: nib = rom_w1[15:12];
            3'd5: nib = rom_w1[11:8];
            3'd6: nib = rom_w1[7:4];
            3'd7: nib = rom_w1[3:0];
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fstate   <= F_IDLE;
            vram_req <= 1'b0;
            rom_req  <= 1'b0;
            wr_sel   <= 1'b0;
            tile_col <= 6'd0;
        end
        else if (start && fstate != F_IDLE) begin
            // Restart while busy: same per-line setup as F_IDLE. Unsafe with
            // a tile ROM word in flight, whose ack would be taken as the next
            // word's data, so g1_video only pulses start when both fetchers
            // are idle.
            cur_line <= line;
            tile_col <= 6'd0;
            px       <= 3'd0;
            wr_sel   <= ~wr_sel;
            vram_req <= 1'b0;
            rom_req  <= 1'b0;
            fstate   <= F_MAP_REQ;
        end
        else begin
            case (fstate)

            F_IDLE: begin
                if (start) begin
                    cur_line <= line;
                    tile_col <= 6'd0;
                    // Swap at fetch start: the buffer filled during the last
                    // line goes to display.
                    wr_sel   <= ~wr_sel;
                    px       <= 3'd0;
                    fstate   <= F_MAP_REQ;
                end
            end

            // ---- Read the tile map word -------------------------------
            F_MAP_REQ: begin
                dbg_map_nz <= 1'b0;
                // 64 words per tilemap row, of which 42 are displayed.
                vram_addr <= ALPHA_WORD_BASE
                           + {4'd0, tile_row, 6'd0}   // tile_row * 64
                           + {9'd0, tile_col};
                vram_req  <= 1'b1;
                fstate    <= F_MAP_WAIT;
            end

            F_MAP_WAIT: begin
                if (vram_ack) begin
                    vram_req     <= 1'b0;
                    dbg_map_nz   <= (vram_dout[11:0] != 12'd0);
                    if (vram_dout != 16'd0) dbg_map_word <= vram_dout;
                    code     <= vram_dout[11:0];
                    // Colour includes bit 15, which is also the opaque flag.
                    color    <= vram_dout[15:12];
                    opaque   <= vram_dout[15];
                    fstate   <= F_ROM0_REQ;
                end
            end

            // ---- Read the two ROM words for this tile row -------------
            // 32 bytes per tile, row r at byte 4r.
            F_ROM0_REQ: begin
                rom_addr <= SDR_ALPHA
                          + {8'd0, code, 5'd0}              // code * 32
                          + {20'd0, row_in_tile, 2'd0};     // row * 4
                rom_req  <= 1'b1;
                fstate   <= F_ROM0_WAIT;
            end

            F_ROM0_WAIT: begin
                if (rom_ack) begin
                    rom_req <= 1'b0;
                    rom_w0  <= rom_dout;
                    fstate  <= F_ROM1_REQ;
                end
            end

            F_ROM1_REQ: begin
                rom_addr <= SDR_ALPHA
                          + {8'd0, code, 5'd0}
                          + {20'd0, row_in_tile, 2'd0}
                          + 25'd2;
                rom_req  <= 1'b1;
                fstate   <= F_ROM1_WAIT;
            end

            F_ROM1_WAIT: begin
                if (rom_ack) begin
                    rom_req <= 1'b0;
                    rom_w1  <= rom_dout;
                    fstate  <= F_STORE;
                end
            end

            // ---- Unpack eight nibbles into the line buffer ------------
            // High nibble leftmost: w0 = {px0..px3}, w1 = {px4..px7}.
            F_STORE: begin
                lbuf[{wr_sel, {tile_col, 3'd0} + {6'd0, px}}] <= {opaque, color, nib};

                if (px == 3'd7) begin
                    px <= 3'd0;
                    if (tile_col == TILES_PER_LINE - 1) begin
                        fstate <= F_IDLE;
                    end else begin
                        tile_col <= tile_col + 1'b1;
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
