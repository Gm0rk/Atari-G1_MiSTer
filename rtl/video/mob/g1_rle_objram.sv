//============================================================================
//  Atari G1 for MiSTer
//  g1_rle_objram.sv -- motion object descriptor snapshot and field extraction
//
//  The 256 descriptors live at CPU $FF0000-$FF0FFF, inside the 64 KB work RAM
//  (there is no separate object RAM). MAME reads them live during
//  sort_and_render(); here a DRAW copies all 2048 words into BRAM in one burst
//  and releases the work RAM video port, which would otherwise be contended
//  with the tile fetchers for most of a frame. The game does not modify
//  object RAM while a render runs, so the result is the same.
//
//  Descriptor, 8 words per object:
//    word 0  [14:0] code, [15] hflip
//    word 1  [7:4] color
//    word 2  [15:6] X position, 10-bit signed
//    word 3  [15:6] Y position, 10-bit signed
//    word 4  scale, 4.12 fixed point ($1000 = 1:1, 0 = skip)
//    word 5  [7:0] order (Hydra)
//    word 6  [7:0] order (Pit Fighter)
//    word 7  unused
//  G1 does not use the RLE device's priority or vram_target fields (both
//  masks are zero in the driver).
//
//  Clock domain: clk_sys
//============================================================================

`default_nettype none

module g1_rle_objram
    import g1_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    input  wire         snap_start,    // pulse: copy object RAM (DRAW)
    output logic        snap_busy,

    // ---- Work RAM read port (arbitrated in g1_video) ----------------------
    output logic [14:0] vram_addr,
    output logic        vram_req,
    input  wire [15:0]  vram_dout,
    input  wire         vram_ack,

    // ---- Configuration ----------------------------------------------------
    input  wire         is_pitfight,   // order field is in word 6, not word 5

    // ---- Descriptor read --------------------------------------------------
    // Present an object index; the decoded fields appear two clocks later.
    input  wire [7:0]   obj_index,
    output logic [14:0] obj_code,
    output logic        obj_hflip,
    output logic [3:0]  obj_color,
    output logic signed [15:0] obj_xpos,
    output logic signed [15:0] obj_ypos,
    output logic [15:0] obj_scale,
    output logic [7:0]  obj_order
);

    // Object RAM at CPU $FF0000 -> work RAM word offset 0.
    localparam [14:0] OBJ_WORD_BASE = 15'h0000;
    localparam int    OBJ_WORDS     = 2048;   // 256 objects x 8 words

    //------------------------------------------------------------------------
    // Snapshot storage: one array per descriptor word
    //------------------------------------------------------------------------
    // The descriptor read needs all eight words of an object at once. Split by
    // word, each array has one read and one write port and infers as one M10K
    // (256 x 16); a single 2048-entry array read at eight indices would become
    // 32,768 registers.
    //------------------------------------------------------------------------
    logic [15:0] snap0 [256];
    logic [15:0] snap1 [256];
    logic [15:0] snap2 [256];
    logic [15:0] snap3 [256];
    logic [15:0] snap4 [256];
    logic [15:0] snap5 [256];
    logic [15:0] snap6 [256];
    logic [15:0] snap7 [256];

    // Copy counter: bits 2:0 select the array (word), bits 10:3 the object.
    wire [7:0] copy_obj  = copy_idx[10:3];
    wire [2:0] copy_word = copy_idx[2:0];

    //------------------------------------------------------------------------
    // Snapshot FSM
    //------------------------------------------------------------------------
    logic [11:0] copy_idx;

    typedef enum logic [1:0] { C_IDLE, C_REQ, C_WAIT } cstate_t;
    cstate_t cstate;

    assign snap_busy = (cstate != C_IDLE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cstate   <= C_IDLE;
            vram_req <= 1'b0;
            copy_idx <= '0;
        end
        else begin
            case (cstate)
            C_IDLE:
                if (snap_start) begin
                    copy_idx <= '0;
                    cstate   <= C_REQ;
                end

            C_REQ: begin
                vram_addr <= OBJ_WORD_BASE + {3'd0, copy_idx};
                vram_req  <= 1'b1;
                cstate    <= C_WAIT;
            end

            C_WAIT:
                if (vram_ack) begin
                    vram_req <= 1'b0;
                    case (copy_word)
                        3'd0: snap0[copy_obj] <= vram_dout;
                        3'd1: snap1[copy_obj] <= vram_dout;
                        3'd2: snap2[copy_obj] <= vram_dout;
                        3'd3: snap3[copy_obj] <= vram_dout;
                        3'd4: snap4[copy_obj] <= vram_dout;
                        3'd5: snap5[copy_obj] <= vram_dout;
                        3'd6: snap6[copy_obj] <= vram_dout;
                        3'd7: snap7[copy_obj] <= vram_dout;
                    endcase
                    if (copy_idx == OBJ_WORDS - 1) begin
                        cstate <= C_IDLE;
                    end else begin
                        copy_idx <= copy_idx + 1'b1;
                        cstate   <= C_REQ;
                    end
                end

            default: cstate <= C_IDLE;
            endcase
        end
    end

    //------------------------------------------------------------------------
    // Descriptor read and field extraction (two clocks)
    //------------------------------------------------------------------------
    logic [15:0] w0, w1, w2, w3, w4, w5, w6;

    // One read port per array, all at the same index (simple dual-port RAM).
    always_ff @(posedge clk) begin
        w0 <= snap0[obj_index];
        w1 <= snap1[obj_index];
        w2 <= snap2[obj_index];
        w3 <= snap3[obj_index];
        w4 <= snap4[obj_index];
        w5 <= snap5[obj_index];
        w6 <= snap6[obj_index];
    end

    always_ff @(posedge clk) begin
        obj_code  <= w0[14:0];
        obj_hflip <= w0[15];
        obj_color <= w1[7:4];
        obj_scale <= w4;
        obj_order <= is_pitfight ? w6[7:0] : w5[7:0];

        // X and Y: 10-bit signed fields in bits 15:6, sign extended
        // (MAME: if (x & 0x200) x |= ~0x3ff). Objects often sit partly off
        // the left or top edge.
        obj_xpos <= {{6{w2[15]}}, w2[15:6]};
        obj_ypos <= {{6{w3[15]}}, w3[15:6]};
    end

endmodule

`default_nettype wire
