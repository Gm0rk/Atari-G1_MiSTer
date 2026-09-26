//============================================================================
//  Atari G1 for MiSTer
//  g1_rle_prescan.sv -- load-time object dimension table
//
//  The RLE ROM stores neither width nor height. After the ROM download this
//  walks every object once (MAME prescan_rle()) and fills a BRAM table that
//  the render engine reads in one clock per object:
//
//    height = number of rows before the terminator
//    width  = maximum over all rows of the sum of the row's run lengths
//
//  Object header, 4 words per object at the start of the ROM:
//    word 0  X hotspot offset, signed
//    word 1  Y hotspot offset, signed
//    word 2  [10:8] encoding mode, [7:0] data offset bits 23:16
//    word 3  data offset bits 15:0 (word offset into the ROM)
//
//  Each row is a count word followed by that many packet words (two RLE bytes
//  each, low byte first). $FFFF ends the object. MAME's general test is "bit
//  15 set, XOR with $FFFF"; in both G1 ROM sets $FFFF is the only value with
//  bit 15 set, so an equality test is used.
//
//  Expected statistics:
//                     Hydra   Pit Fighter
//    valid objects      691       1298
//    null objects        77         14
//    max width          513        256
//    max height         255        152
//    max entry_count    158         66
//
//  A full 2 MB walk takes roughly 40-70 ms, once, during loading.
//
//  Clock domain: clk_sys
//============================================================================

`default_nettype none

module g1_rle_prescan
    import g1_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    // ---- Control ----------------------------------------------------------
    input  wire         start,          // pulse when the ROM download finishes
    input  wire [10:0]  obj_count,      // from the MRA config: 768 or 1312
    output logic        busy,
    output logic        done,

    // ---- SDRAM read port (RLE object ROM) ---------------------------------
    output logic [24:0] rom_addr,
    output logic        rom_req,
    input  wire [15:0]  rom_dout,
    input  wire         rom_ack,

    // ---- Dimension table read port ----------------------------------------
    input  wire [10:0]  q_index,
    output logic [9:0]  q_width,
    output logic [7:0]  q_height,
    output logic [2:0]  q_mode,         // encoding mode from the header
    output logic [23:0] q_dataoff,      // word offset of the object's data
    output logic signed [15:0] q_xoffs, // header word 0, signed hotspot offset
    output logic signed [15:0] q_yoffs, // header word 1, signed hotspot offset
    output logic        q_valid,        // 0 = null/invalid object

    // ---- Statistics (expected values in the header) -----------------------
    output logic [10:0] stat_valid,
    output logic [10:0] stat_null,
    output logic [9:0]  stat_max_w,
    output logic [7:0]  stat_max_h
);

    //------------------------------------------------------------------------
    // Table storage
    //------------------------------------------------------------------------
    // {valid, yoffs[15:0], xoffs[15:0], mode[2:0], dataoff[23:0],
    //  height[7:0], width[9:0]} = 78 bits x 2048 entries, about 16 M10K.
    // Keeping the hotspot offsets here saves two SDRAM reads per object per
    // frame at render time.
    //------------------------------------------------------------------------
    localparam int ENTRY_W = 1 + 16 + 16 + 3 + 24 + 8 + 10;

    logic [ENTRY_W-1:0] table_mem [2048];
    logic [ENTRY_W-1:0] q_entry;

    always_ff @(posedge clk) q_entry <= table_mem[q_index];

    assign q_width   = q_entry[9:0];
    assign q_height  = q_entry[17:10];
    assign q_dataoff = q_entry[41:18];
    assign q_mode    = q_entry[44:42];
    assign q_xoffs   = q_entry[60:45];
    assign q_yoffs   = q_entry[76:61];
    assign q_valid   = q_entry[77];

    //------------------------------------------------------------------------
    // Packet decode
    //------------------------------------------------------------------------
    logic [2:0] cur_mode;
    logic [7:0] pkt_byte;
    wire  [5:0] pkt_value;
    wire  [4:0] pkt_run;

    g1_rle_decode u_decode (
        .mode        (cur_mode),
        .packet      (pkt_byte),
        .value       (pkt_value),
        .run         (pkt_run),
        .transparent ()
    );

    //------------------------------------------------------------------------
    // Walk FSM
    //------------------------------------------------------------------------
    typedef enum logic [3:0] {
        P_IDLE,
        P_HDR_REQ, P_HDR_WAIT,          // read the 4 header words
        P_ROW_REQ, P_ROW_WAIT,          // read a row's entry_count
        P_PKT_REQ, P_PKT_WAIT,          // read a packet word
        P_NEXT_OBJ, P_DONE
    } pstate_t;

    pstate_t     pstate;
    logic [10:0] obj;
    logic [1:0]  hdr_word;
    logic [15:0] hdr [4];

    logic [23:0] data_ptr;      // word offset into the RLE ROM
    logic [9:0]  width;
    logic [7:0]  height;
    logic [9:0]  row_width;
    logic [7:0]  entries_left;
    logic        valid;

    // SDRAM is byte addressed; data_ptr is a word offset.
    wire [24:0] rom_byte_addr = SDR_RLE + {data_ptr, 1'b0};

    assign busy = (pstate != P_IDLE) && (pstate != P_DONE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pstate     <= P_IDLE;
            rom_req    <= 1'b0;
            done       <= 1'b0;
            stat_valid <= '0;
            stat_null  <= '0;
            stat_max_w <= '0;
            stat_max_h <= '0;
        end
        else begin
            case (pstate)

            P_IDLE: begin
                done <= 1'b0;
                if (start) begin
                    obj        <= 11'd0;
                    stat_valid <= '0;
                    stat_null  <= '0;
                    stat_max_w <= '0;
                    stat_max_h <= '0;
                    hdr_word   <= 2'd0;
                    pstate     <= P_HDR_REQ;
                end
            end

            //---- Header: 4 words per object at the start of the ROM -----
            P_HDR_REQ: begin
                rom_addr <= SDR_RLE + {12'd0, obj, hdr_word, 1'b0};
                rom_req  <= 1'b1;
                pstate   <= P_HDR_WAIT;
            end

            P_HDR_WAIT: begin
                if (rom_ack) begin
                    rom_req       <= 1'b0;
                    hdr[hdr_word] <= rom_dout;

                    if (hdr_word == 2'd3) begin
                        // word 2: [10:8] encoding mode, [7:0] dataoff[23:16]
                        // word 3: dataoff[15:0]
                        cur_mode <= hdr[2][10:8];
                        data_ptr <= {hdr[2][7:0], rom_dout};

                        // Null object (MAME prescan_rle): a data offset at or
                        // before the object's own header entry.
                        valid <= ({hdr[2][7:0], rom_dout} > {13'd0, obj, 2'd0});

                        width     <= 10'd0;
                        height    <= 8'd0;
                        row_width <= 10'd0;
                        hdr_word  <= 2'd0;

                        if ({hdr[2][7:0], rom_dout} > {13'd0, obj, 2'd0})
                            pstate <= P_ROW_REQ;
                        else
                            pstate <= P_NEXT_OBJ;
                    end else begin
                        hdr_word <= hdr_word + 1'b1;
                        pstate   <= P_HDR_REQ;
                    end
                end
            end

            //---- Row header ---------------------------------------------
            P_ROW_REQ: begin
                rom_addr <= rom_byte_addr;
                rom_req  <= 1'b1;
                pstate   <= P_ROW_WAIT;
            end

            P_ROW_WAIT: begin
                if (rom_ack) begin
                    rom_req  <= 1'b0;
                    data_ptr <= data_ptr + 1'b1;

                    // General form: count = rom_dout[15] ? ~rom_dout : rom_dout,
                    // and count == 0 ends the object. On G1 the only value
                    // with bit 15 set is $FFFF.
                    if (rom_dout == RLE_ROW_TERMINATOR || rom_dout == 16'd0) begin
                        pstate <= P_NEXT_OBJ;
                    end
                    else if (height == 8'hFF) begin
                        // MAME caps the walk at 1024 rows. The largest G1
                        // object has 255, so stopping at 255 only guards
                        // against corrupt data.
                        pstate <= P_NEXT_OBJ;
                    end
                    else begin
                        entries_left <= rom_dout[7:0];
                        row_width    <= 10'd0;
                        pstate       <= P_PKT_REQ;
                    end
                end
            end

            //---- Packets: two RLE bytes per word -------------------------
            P_PKT_REQ: begin
                if (entries_left == 8'd0) begin
                    // Row finished: fold its width into the object maximum.
                    if (row_width > width) width <= row_width;
                    height <= height + 1'b1;
                    pstate <= P_ROW_REQ;
                end else begin
                    rom_addr <= rom_byte_addr;
                    rom_req  <= 1'b1;
                    pstate   <= P_PKT_WAIT;
                end
            end

            P_PKT_WAIT: begin
                if (rom_ack) begin
                    rom_req  <= 1'b0;
                    data_ptr <= data_ptr + 1'b1;

                    // Both bytes' runs are added in one clock (run_of).
                    row_width <= row_width
                               + {5'd0, run_of(rom_dout[7:0])}
                               + {5'd0, run_of(rom_dout[15:8])};

                    entries_left <= entries_left - 1'b1;
                    pstate       <= P_PKT_REQ;
                end
            end

            //---- Store and advance --------------------------------------
            P_NEXT_OBJ: begin
                // hdr[0]/hdr[1] are the X/Y hotspot offsets. They are signed
                // (often negative) and the scaler treats them as such.
                table_mem[obj] <= {valid, hdr[1], hdr[0], cur_mode,
                                   data_ptr_at_start, height, width};

                if (valid) begin
                    stat_valid <= stat_valid + 1'b1;
                    if (width  > stat_max_w) stat_max_w <= width;
                    if (height > stat_max_h) stat_max_h <= height;
                end else begin
                    stat_null <= stat_null + 1'b1;
                end

                if (obj >= obj_count - 1) begin
                    pstate <= P_DONE;
                end else begin
                    obj      <= obj + 1'b1;
                    hdr_word <= 2'd0;
                    pstate   <= P_HDR_REQ;
                end
            end

            P_DONE: begin
                done   <= 1'b1;
                pstate <= P_IDLE;
            end

            default: pstate <= P_IDLE;
            endcase
        end
    end

    // data_ptr advances during the walk; the table stores the start offset.
    logic [23:0] data_ptr_at_start;
    always_ff @(posedge clk) begin
        if (pstate == P_HDR_WAIT && rom_ack && hdr_word == 2'd3)
            data_ptr_at_start <= {hdr[2][7:0], rom_dout};
    end

    // Run length of a packet byte (same as g1_rle_decode), for both bytes of
    // a packet word in one clock.
    function automatic [4:0] run_of(input [7:0] b);
        logic [2:0] bpp; logic sp;
        begin
            bpp = rle_mode_bpp(cur_mode);
            sp  = rle_mode_special(cur_mode);
            if ((sp && b[3:0] == 4'h0) || bpp == 3'd4) run_of = {1'b0, b[7:4]} + 5'd1;
            else if (bpp == 3'd5)                      run_of = {2'd0, b[7:5]} + 5'd1;
            else                                       run_of = {3'd0, b[7:6]} + 5'd1;
        end
    endfunction

endmodule

`default_nettype wire
