//============================================================================
//  Atari G1 for MiSTer
//  g1_rle_checksum.sv -- RLE ROM checksums for Pit Fighter's self-test
//
//  Pit Fighter's ROM test issues a CHECKSUM command and reads a table of RLE
//  ROM checksums back from object RAM. MAME atarirle.cpp:
//
//    device_start():
//      for each $20000-byte chunk of the RLE ROM:
//          checksums[chunk] = sum of the $10000 words in the chunk, mod $10000
//    compute_checksum():
//      reqsums = objram[0] + 1        (capped at 256)
//      for i in 0 .. reqsums-1:
//          objram[i] = checksums[i]
//
//  The sums are accumulated by snooping the ROM loader's SDRAM writes during
//  the download, so no extra pass over SDRAM is needed; the loader itself is
//  unchanged. Hydra's RLE ROM is 1 MB (8 chunks), Pit Fighter's 2 MB (16).
//
//  Clock domain: clk_sys
//============================================================================

`default_nettype none

module g1_rle_checksum
    import g1_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,        // core reset: the write-back only
    // Accumulator reset: tie to PLL lock. Not the core reset, which is held
    // for the whole ROM download and would keep the table cleared.
    input  wire         acc_rst_n,

    // ---- Snoop of the ROM loader's SDRAM write port -----------------------
    // load_active: ROM (index 0) download only. Its rising edge restarts the
    // clear, so later config/nvram downloads must not assert it.
    input  wire         load_active,
    input  wire [24:0]  load_addr,
    input  wire [15:0]  load_data,
    input  wire         load_we,

    // ---- Checksum table read ----------------------------------------------
    input  wire [7:0]   q_index,
    output logic [15:0] q_sum,

    // ---- Write-back on a CHECKSUM command ---------------------------------
    // Writes the table into object RAM words 0 .. reqsums-1 through the work
    // RAM video-side port (write path in g1_mainram).
    input  wire         cksum_start,
    input  wire [15:0]  objram_word0,   // the game's requested count, minus 1
    output logic [14:0] wr_addr,
    output logic [15:0] wr_data,
    output logic        wr_en,
    output logic        busy,
    output logic        done
);

    //------------------------------------------------------------------------
    // Accumulation during the load
    //------------------------------------------------------------------------
    // Chunks are $20000 bytes, so the chunk index is (load_addr - SDR_RLE)
    // bits 24:17. Words are summed with 16-bit wraparound.
    //
    // One muxed read port and one muxed write port, so sums[] infers as RAM.
    // Accumulate (ROM download) and write-back (CHECKSUM) never overlap.
    logic [15:0] sums [256];

    logic [7:0]  sum_raddr, sum_waddr;
    logic [15:0] sum_wdata, sum_q;
    logic        sum_we;

    always_ff @(posedge clk) begin
        if (sum_we) sums[sum_waddr] <= sum_wdata;
        sum_q <= sums[sum_raddr];
    end

    wire        in_rle_region = load_active
                             && (load_addr >= SDR_RLE)
                             && (load_addr <  SDR_RLE + 25'h200000);
    wire [24:0] rle_offset    = load_addr - SDR_RLE;
    wire [7:0]  chunk         = rle_offset[24:17];

    // 256-clock clear at the start of each ROM download and after acc_rst_n.
    logic [7:0] clear_i;
    logic       clearing;
    logic       load_active_d;

    always_ff @(posedge clk) begin
        load_active_d <= load_active;

        if (!acc_rst_n) begin
            clearing <= 1'b1;
            clear_i  <= 8'd0;
        end
        else if (load_active && !load_active_d) begin
            // Download started: restart the clear.
            clearing <= 1'b1;
            clear_i  <= 8'd0;
        end
        else if (clearing) begin
            if (clear_i == 8'hFF) clearing <= 1'b0;
            else                  clear_i  <= clear_i + 1'b1;
        end
    end

    // load_we is a level, held with stable address and data until the SDRAM
    // arbiter accepts the word (three clocks or more). Each word is added once:
    //   rising edge of load_we   read sums[chunk]; capture chunk and data
    //   next clock (acc_v)       sums[chunk] <= sum_q + data
    // sum_q is always the current total: load_we falls between words, so the
    // previous write lands at least one clock before this read.
    logic        load_we_d, acc_v;
    logic [7:0]  acc_chunk;
    logic [15:0] acc_data;

    always_ff @(posedge clk) begin
        if (!acc_rst_n) begin
            load_we_d <= 1'b0;
            acc_v     <= 1'b0;
        end else begin
            load_we_d <= load_we;
            acc_v     <= in_rle_region && load_we && !load_we_d;
        end
        acc_chunk <= chunk;
        acc_data  <= load_data;
    end

    always_comb begin
        sum_raddr = (wstate == W_IDLE) ? chunk : wr_i[7:0];

        if (clearing) begin
            sum_waddr = clear_i;
            sum_wdata = 16'd0;
            sum_we    = 1'b1;
        end else begin
            sum_waddr = acc_chunk;
            sum_wdata = sum_q + acc_data;
            sum_we    = acc_v;
        end
    end

    assign q_sum = sum_q;

    //------------------------------------------------------------------------
    // Write-back
    //------------------------------------------------------------------------
    typedef enum logic [1:0] { W_IDLE, W_READ, W_WRITE, W_DONE } wstate_t;
    wstate_t wstate;

    logic [8:0] req_count;   // objram[0] + 1, capped at 256
    logic [8:0] wr_i;

    assign busy = (wstate != W_IDLE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wstate <= W_IDLE;
            wr_en  <= 1'b0;
            done   <= 1'b0;
        end
        else begin
            wr_en <= 1'b0;
            done  <= 1'b0;

            case (wstate)

            W_IDLE:
                if (cksum_start) begin
                    req_count <= (objram_word0 >= 16'd255)
                               ? 9'd256
                               : ({1'b0, objram_word0[7:0]} + 9'd1);
                    wr_i   <= 9'd0;
                    wstate <= W_READ;
                end

            W_READ: begin
                // One clock of sums[] read latency (sum_raddr = wr_i here).
                wstate <= W_WRITE;
            end

            W_WRITE: begin
                // Object RAM starts at work RAM word 0.
                wr_addr <= {6'd0, wr_i};
                wr_data <= sum_q;
                wr_en   <= 1'b1;

                if (wr_i + 1 >= req_count) begin
                    wstate <= W_DONE;
                end else begin
                    wr_i   <= wr_i + 1'b1;
                    wstate <= W_READ;
                end
            end

            W_DONE: begin
                done   <= 1'b1;
                wstate <= W_IDLE;
            end

            default: wstate <= W_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
