//============================================================================
//  Atari G1 for MiSTer
//  g1_rle_sort.sv -- motion object priority ordering
//
//  The board's "256 priority levels" are the 8-bit order field of each
//  descriptor: draw order is the whole priority system, which is why the RLE
//  device's separate priority mask is zero on G1. Port of MAME
//  sort_and_render():
//
//      for objnum in 0 .. count-1:          // build 256 linked lists
//          bucket = order[objnum]
//          next[objnum] = head[bucket]      // push onto the front
//          head[bucket] = objnum
//      for order in 1 .. 255:               // render; order 0 is skipped
//          walk head[order] via next[]
//
//  Order 0 is never drawn; the games park unused objects there. Because each
//  list is pushed at the front, objects with equal order draw in descending
//  index order, so lower-numbered objects end up on top.
//
//  Build: 256 clocks of clear plus 5 per descriptor. Walk: 2 clocks per empty
//  bucket. walk_done is a level from the end of the walk until the next
//  build_start.
//
//  Clock domain: clk_sys
//============================================================================

`default_nettype none

module g1_rle_sort (
    input  wire         clk,
    input  wire         rst_n,

    // ---- Build phase ------------------------------------------------------
    input  wire         build_start,
    input  wire [10:0]  obj_count,     // from the MRA config: 768 or 1312

    // Descriptor port, shared with the render sequencer (see desc_sel).
    output logic [7:0]  desc_index,
    output logic        desc_sel,      // 1 = this module owns the descriptor port
    input  wire [7:0]   desc_order,

    // ---- Walk phase -------------------------------------------------------
    input  wire         walk_next,     // advance to the next object to render
    output logic [10:0] walk_obj,      // object index to render
    output logic        walk_valid,    // walk_obj is meaningful
    output logic        walk_done,     // the whole list has been walked

    output logic        busy
);

    //------------------------------------------------------------------------
    // Storage
    //------------------------------------------------------------------------
    // head[order] -> first object in that bucket, or NONE
    // next[obj]   -> next object in the same bucket, or NONE
    //
    // NONE is all-ones, beyond any real object index.
    //------------------------------------------------------------------------
    localparam [10:0] NONE = 11'h7FF;

    // head[] has one read and one write index so it infers as one M10K. Do not
    // add a second read (e.g. head[8'hFF] for end detection): it turns the
    // array into 2816 flip-flops. The walk ends on the order counter instead.
    logic [10:0] head [256];
    logic [10:0] nxt  [2048];

    logic [7:0]  head_waddr;
    logic [10:0] head_wdata;
    logic        head_we;
    logic [7:0]  head_raddr;
    logic [10:0] head_q;

    always_ff @(posedge clk) begin
        if (head_we) head[head_waddr] <= head_wdata;
        head_q <= head[head_raddr];
    end

    //------------------------------------------------------------------------
    // Build FSM
    //------------------------------------------------------------------------
    // Pass 1 clears the 256 heads. Pass 2 takes objects in ascending order
    // and pushes each onto the front of its bucket.
    //------------------------------------------------------------------------
    typedef enum logic [2:0] {
        B_IDLE, B_CLEAR, B_REQ, B_WAIT, B_PUSH, B_READY,
        B_WALK_SCAN, B_WALK_OUT
    } bstate_t;

    bstate_t     bstate;
    logic [10:0] idx;
    logic [7:0]  clear_i;
    logic [1:0]  desc_lat;   // descriptor read latency counter

    assign busy    = (bstate != B_IDLE) && (bstate != B_READY)
                  && (bstate != B_WALK_SCAN) && (bstate != B_WALK_OUT);
    assign desc_sel = (bstate == B_REQ) || (bstate == B_WAIT) || (bstate == B_PUSH);

    //------------------------------------------------------------------------
    // Walk state
    //------------------------------------------------------------------------
    logic [7:0]  walk_order;
    logic [10:0] walk_ptr;
    logic        walk_primed;   // head_q reflects the current walk_order

    // head[] address and write muxes, by phase: the clear pass and the bucket
    // pass share the write port.
    always_comb begin
        head_raddr = (bstate == B_WAIT || bstate == B_PUSH) ? desc_order
                                                            : walk_order;
        if (bstate == B_CLEAR) begin
            head_waddr = clear_i;
            head_wdata = NONE;
            head_we    = 1'b1;
        end else begin
            head_waddr = desc_order;
            head_wdata = idx;
            head_we    = (bstate == B_PUSH);
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bstate     <= B_IDLE;
            walk_valid <= 1'b0;
            walk_done  <= 1'b0;
        end
        else begin
            case (bstate)

            B_IDLE: begin
                walk_valid <= 1'b0;
                // walk_done holds until the next build is requested.
                if (build_start) begin
                    walk_done <= 1'b0;
                    clear_i   <= 8'd0;
                    bstate    <= B_CLEAR;
                end
            end

            // ---- Pass 1: clear the buckets ----------------------------
            B_CLEAR: begin
                if (clear_i == 8'hFF) begin
                    idx    <= 11'd0;
                    bstate <= B_REQ;
                end else begin
                    clear_i <= clear_i + 1'b1;
                end
            end

            // ---- Pass 2: bucket every object --------------------------
            B_REQ: begin
                // 256 descriptor slots; obj_count counts ROM object codes,
                // not slots.
                desc_index <= idx[7:0];
                desc_lat   <= 2'd0;
                bstate     <= B_WAIT;
            end

            B_WAIT: begin
                // g1_rle_objram has two clocks of read latency.
                if (desc_lat == 2'd2) bstate <= B_PUSH;
                else                  desc_lat <= desc_lat + 1'b1;
            end

            B_PUSH: begin
                // Push onto the front; head_q is head[desc_order], read during
                // B_WAIT. Order 0 is bucketed too but never walked.
                nxt[idx] <= head_q;

                if (idx >= obj_count - 1 || idx == 11'd255) begin
                    bstate <= B_READY;
                end else begin
                    idx    <= idx + 1'b1;
                    bstate <= B_REQ;
                end
            end

            // ---- Ready to walk ----------------------------------------
            B_READY: begin
                walk_order  <= 8'd1;         // order 0 is never rendered
                walk_ptr    <= NONE;
                walk_primed <= 1'b0;
                bstate      <= B_WALK_SCAN;
            end

            // ---- Walk: find the next non-empty bucket -----------------
            // head_q lags head_raddr by one clock, so each change of
            // walk_order is followed by one settling clock (walk_primed).
            B_WALK_SCAN: begin
                walk_valid <= 1'b0;
                if (walk_ptr != NONE) begin
                    bstate <= B_WALK_OUT;
                end
                else if (!walk_primed) begin
                    walk_primed <= 1'b1;
                end
                else if (head_q != NONE) begin
                    walk_ptr <= head_q;
                    bstate   <= B_WALK_OUT;
                end
                else if (walk_order == 8'hFF) begin
                    // Terminate on the counter, not on a second read of head[].
                    walk_done <= 1'b1;
                    bstate    <= B_IDLE;
                end
                else begin
                    walk_order  <= walk_order + 1'b1;
                    walk_primed <= 1'b0;
                end
            end

            // ---- Walk: emit and advance -------------------------------
            B_WALK_OUT: begin
                walk_obj   <= walk_ptr;
                walk_valid <= 1'b1;

                if (walk_next) begin
                    walk_valid <= 1'b0;
                    walk_ptr   <= nxt[walk_ptr];
                    if (nxt[walk_ptr] == NONE) begin
                        if (walk_order == 8'hFF) begin
                            walk_done <= 1'b1;
                            bstate    <= B_IDLE;
                        end else begin
                            walk_order  <= walk_order + 1'b1;
                            walk_primed <= 1'b0;
                            bstate      <= B_WALK_SCAN;
                        end
                    end
                end
            end

            default: bstate <= B_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
