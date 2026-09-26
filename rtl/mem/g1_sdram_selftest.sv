//============================================================================
//  Atari G1 for MiSTer
//  g1_sdram_selftest.sv -- SDRAM write/readback self-test and capture sweep
//
//  Checks that every word read back from SDRAM equals the word written, which
//  separates controller faults from core logic faults. Runs once per ROM load:
//    - during the download, snoops the loader's write port and accumulates two
//      checksums (no extra bandwidth or download time);
//    - sweeps the eight read-capture settings over 4,096 known words and picks
//      the best for the controller's Auto mode;
//    - reads the whole image back twice (contended, then exclusive) and reads
//      one address 65,536 times, all at the picked setting.
//  A plain sum catches wrong data; the address-mixed checksum also catches
//  swapped words and stuck address lines, which leave a plain sum unchanged.
//
//  A pass shows the data path is clean for these reads at the current
//  temperature; marginal timing can still fail under a running game's random
//  access pattern. A fail is conclusive.
//
//  Clock domain: clk_sys
//============================================================================

`default_nettype none

module g1_sdram_selftest
    import g1_pkg::*;
#(
    // End of the tested range (exclusive): every region the MRA populates,
    // ending just past the PROMs.
    parameter [24:0] TEST_END = 25'h390600
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- Snoop of the ROM loader's write port -----------------------------
    input  wire         load_active,
    input  wire [24:0]  load_addr,
    input  wire [15:0]  load_data,
    input  wire         load_we,       // held until the arbiter acks (see below)
    input  wire         load_complete,

    // ---- Read port (muxed onto the CPU channel while busy) ----------------
    output logic [24:0] rd_addr,
    output logic        rd_req,
    input  wire [15:0]  rd_dout,
    input  wire         rd_ack,

    // ---- Result -----------------------------------------------------------
    output logic        busy,          // running: game held in reset, test owns CPU channel
    output logic        done,
    output logic        pass,          // all checks matched (valid with done)
    output logic [31:0] sum_written,   // plain sum of the words written
    output logic [31:0] sum_read,      // plain sum read back (pass 2)
    output logic [31:0] mix_written,   // address-mixed checksum, written
    output logic [31:0] mix_read,      // address-mixed checksum, read (pass 2)

    // sum_read of pass 1. Both passes read the same unchanged memory:
    // different totals mean reads are non-deterministic; equal totals that
    // differ from sum_written mean a systematic data or addressing fault.
    output logic [31:0] sum_read_1,

    // High during the sweep, pass 2 and the repeat test: the arbiter then holds
    // the tile, RLE and OKI channels idle, so pass 1 reads contended and pass 2
    // exclusive.
    //   pass 2 correct, pass 1 wrong   contention is the fault
    //   both wrong                     contention is ruled out
    //   both correct                   memory is sound
    output logic        solo_pass,

    // Repeat test: 65,536 reads of address 0 on an exclusive bus, each
    // compared with the word written there. Errors here lie in the read data
    // path itself. If this is clean but the other checks fail, suspect row/bank
    // switching (tRP, tRCD, auto-precharge) rather than data capture.
    output logic [31:0] rep_err,       // mismatches
    output logic [15:0] rep_ref,       // first word read

    // Capture sweep: each {rd_half, rd_phase} setting reads 4,096 different
    // words (the first 8 KB of the image) and counts those that differ from
    // the written data, kept in block RAM. A marginal setting is right most of
    // the time, so a setting can only be rated over many reads.
    output logic [2:0]  sweep_sel,     // setting the controller uses while sweep_on
    output logic        sweep_on,      // sweep_sel overrides the OSD setting
    output logic [16*8-1:0] sweep_err, // 16-bit error count per setting

    // Result of the sweep, used by the controller in Auto.
    output logic [2:0]  best_sel,      // {rd_half, rd_phase}, numbered as sweep_err
    output logic        best_valid,    // sweep finished, best_sel is measured
    output logic        best_clean,    // best_sel read every truth word correctly
    output logic [24:0] first_bad_addr,  // unused, held at 0
    output logic        had_bad_addr     // unused, held at 0
);

    //------------------------------------------------------------------------
    // Write-side accumulation
    //------------------------------------------------------------------------
    logic load_active_d;
    logic load_we_d;
    logic arm;      // a download has begun but has not yet written anything

    always_ff @(posedge clk) begin
        load_active_d <= load_active;
        load_we_d     <= load_we;

        if (!rst_n) begin
            sum_written <= 32'd0;
            mix_written <= 32'd0;
            arm         <= 1'b0;
            load_we_d   <= 1'b0;
        end
        else begin
            // Restart on the first write of a download, not on its start: an
            // MRA performs several downloads, and the 9-byte config download
            // (index 1) writes nothing to SDRAM but must not clear the totals.
            if (load_active && !load_active_d)
                arm <= 1'b1;

            // One accumulation per write, on the edge of load_we: the loader
            // holds sdr_we until the arbiter acks, so counting the level would
            // add each word once per clock spent waiting for a grant.
            if (load_active && load_we && !load_we_d && load_addr < TEST_END) begin
                // Mix: rotate the running value, then fold in data + address.
                if (arm) begin
                    sum_written <= {16'd0, load_data};
                    mix_written <= {16'd0, load_data} + load_addr[24:0];
                    arm         <= 1'b0;
                end
                else begin
                    sum_written <= sum_written + {16'd0, load_data};
                    mix_written <= {mix_written[30:0], mix_written[31]}
                                 ^ ({16'd0, load_data} + load_addr[24:0]);
                end
            end
        end
    end

    //------------------------------------------------------------------------
    // Ground truth for the capture sweep
    //------------------------------------------------------------------------
    // The first 8 KB of the image (4,096 words, start of the program ROM) is
    // copied into block RAM as it is written, so each sweep read is checked
    // against the written data. 8 KB spans eight SDRAM rows, so row changes
    // are included.
    localparam [24:0] TRUTH_END = 25'h002000;

    logic [15:0] truth [4096];
    logic [15:0] truth_q;
    logic [12:0] sw_n;                    // reads done at this setting

    wire truth_we = load_active && load_we && !load_we_d && (load_addr < TRUTH_END);

    always_ff @(posedge clk) begin
        if (truth_we) truth[load_addr[12:1]] <= load_data;
        truth_q <= truth[sw_n[11:0]];
    end

    //------------------------------------------------------------------------
    // Test sequence
    //------------------------------------------------------------------------
    //   1. SWEEP   each capture setting reads the 4,096 truth words and counts
    //              the ones that come back wrong
    //   2. PICK    fewest errors; ties go to the fewest errors in the two
    //              neighbours in sample time (the centre of the clean window)
    //   3. PASS 1  whole image, contended            -> sum_read_1
    //   4. PASS 2  whole image, bus to itself        -> sum_read
    //   5. REPEAT  65,536 reads of address 0 vs the truth word -> rep_err
    //
    // Passes 1, 2 and the repeat test run at the setting the core then uses
    // (the pick, unless the OSD selects Manual). busy must cover the whole
    // sequence: with the CPUs released, their fetches would be counted as
    // test reads and the sweep would change the setting under a running CPU.
    typedef enum logic [3:0] {
        T_IDLE, T_REQ, T_WAIT, T_DONE, T_REP_REQ, T_REP_WAIT,
        T_SW_REQ, T_SW_WAIT, T_PICK, T_PICKED
    } state_t;
    localparam int REP_COUNT   = 65536;   // the single-setting deep test
    localparam int SWEEP_COUNT = 4096;    // words per setting (= truth size)
    logic [2:0]  sw_i;                    // which setting is being measured
    logic [16:0] rep_n;
    logic second_pass;
    state_t state;

    logic [24:0] cur;
    logic [15:0] expect_word;

    assign busy = (state != T_IDLE);

    //------------------------------------------------------------------------
    // Pick: walk the settings in sample-time order (tord: position -> setting).
    //     sample time  t6.5  t7.0  t7.5  t8.0  t8.5  t9.0  t9.5  t10.0
    //     setting        7     3     4     0     5     1     6     2
    // Score = {own errors, sum of both neighbours' errors}; lowest wins. A
    // missing neighbour at either end counts as 4,096 (unknown = bad).
    //------------------------------------------------------------------------
    function automatic [2:0] tord(input [2:0] k);
        case (k)
            3'd0: tord = 3'd7;   3'd1: tord = 3'd3;
            3'd2: tord = 3'd4;   3'd3: tord = 3'd0;
            3'd4: tord = 3'd5;   3'd5: tord = 3'd1;
            3'd6: tord = 3'd6;   default: tord = 3'd2;
        endcase
    endfunction

    logic [2:0]  pk;
    logic [32:0] best_score;
    wire  [2:0]  pk_s  = tord(pk);
    wire  [2:0]  pk_sl = tord(pk - 3'd1);
    wire  [2:0]  pk_sr = tord(pk + 3'd1);
    wire  [15:0] e_c   = sweep_err[16*pk_s +: 16];
    wire  [15:0] e_l   = (pk == 3'd0) ? 16'd4096 : sweep_err[16*pk_sl +: 16];
    wire  [15:0] e_r   = (pk == 3'd7) ? 16'd4096 : sweep_err[16*pk_sr +: 16];
    wire  [32:0] score = {e_c, {1'b0, e_l} + {1'b0, e_r}};

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= T_IDLE;
            rd_req         <= 1'b0;
            done           <= 1'b0;
            pass           <= 1'b0;
            had_bad_addr   <= 1'b0;
            first_bad_addr <= '0;
            sweep_on       <= 1'b0;
            solo_pass      <= 1'b0;
            best_valid     <= 1'b0;
            best_clean     <= 1'b0;
            best_sel       <= 3'd4;          // t7.5 until measured
            sw_n           <= '0;
        end
        else begin
            case (state)

            T_IDLE: begin
                if (load_complete && !done) begin
                    sweep_err  <= '0;
                    sw_i       <= 3'd0;
                    sw_n       <= '0;
                    sweep_sel  <= 3'd0;
                    sweep_on   <= 1'b1;
                    solo_pass  <= 1'b1;          // sweep has the bus alone
                    best_valid <= 1'b0;
                    state      <= T_SW_REQ;
                end
            end

            // ---- 1. Sweep (setting changes only between reads, controller idle)
            T_SW_REQ: begin
                sweep_sel <= sw_i;
                rd_addr   <= {11'd0, sw_n[11:0], 1'b0};
                rd_req    <= 1'b1;
                state     <= T_SW_WAIT;
            end

            T_SW_WAIT: begin
                // truth_q has been addressed by sw_n since the request went
                // out, many clocks before any acknowledge can arrive.
                if (rd_ack) begin
                    rd_req <= 1'b0;
                    if (rd_dout != truth_q)
                        sweep_err[16*sw_i +: 16] <= sweep_err[16*sw_i +: 16] + 1'b1;

                    if (sw_n == SWEEP_COUNT - 1) begin
                        sw_n <= '0;
                        if (sw_i == 3'd7) begin
                            sweep_on <= 1'b0;       // back to auto / OSD
                            pk       <= 3'd0;
                            state    <= T_PICK;
                        end else begin
                            sw_i  <= sw_i + 1'b1;
                            state <= T_SW_REQ;
                        end
                    end else begin
                        sw_n  <= sw_n + 1'b1;
                        state <= T_SW_REQ;
                    end
                end
            end

            // ---- 2. Pick, one setting per clock
            T_PICK: begin
                if (pk == 3'd0 || score < best_score) begin
                    best_score <= score;
                    best_sel   <= pk_s;
                end
                if (pk == 3'd7) state <= T_PICKED;
                else            pk    <= pk + 1'b1;
            end

            T_PICKED: begin
                // The controller now uses best_sel (in Auto), so the passes
                // below measure the setting the game runs on.
                best_valid  <= 1'b1;
                best_clean  <= (best_score[32:17] == 16'd0);
                cur         <= 25'd0;
                sum_read    <= 32'd0;
                mix_read    <= 32'd0;
                second_pass <= 1'b0;
                solo_pass   <= 1'b0;             // pass 1 runs contended
                state       <= T_REQ;
            end

            // ---- 3, 4. Whole-image read passes
            T_REQ: begin
                rd_addr <= cur;
                rd_req  <= 1'b1;
                state   <= T_WAIT;
            end

            T_WAIT: begin
                if (rd_ack) begin
                    rd_req   <= 1'b0;
                    sum_read <= sum_read + {16'd0, rd_dout};
                    mix_read <= {mix_read[30:0], mix_read[31]}
                              ^ ({16'd0, rd_dout} + cur);

                    if (cur + 25'd2 >= TEST_END) begin
                        state <= T_DONE;
                    end else begin
                        cur   <= cur + 25'd2;
                        state <= T_REQ;
                    end
                end
            end

            T_DONE: begin
                if (!second_pass) begin
                    // Keep pass 1's total and read the same memory again;
                    // nothing writes to it in between.
                    sum_read_1  <= sum_read;
                    sum_read    <= 32'd0;
                    mix_read    <= 32'd0;
                    cur         <= 25'd0;
                    second_pass <= 1'b1;
                    solo_pass   <= 1'b1;   // pass 2 runs with the bus to itself
                    state       <= T_REQ;
                end else begin
                    rep_n   <= '0;
                    rep_err <= 32'd0;
                    sw_n    <= '0;         // truth_q -> word 0
                    state   <= T_REP_REQ;
                end
            end

            // ---- 5. Repeat test: address 0 vs the truth word
            T_REP_REQ: begin
                rd_addr <= 25'd0;
                rd_req  <= 1'b1;
                state   <= T_REP_WAIT;
            end

            T_REP_WAIT: begin
                if (rd_ack) begin
                    rd_req <= 1'b0;
                    if (rep_n == '0) rep_ref <= rd_dout;
                    if (rd_dout != truth_q)
                        rep_err <= rep_err + 1'b1;

                    if (rep_n == REP_COUNT - 1) begin
                        solo_pass <= 1'b0;
                        done      <= 1'b1;
                        pass      <= (sum_read == sum_written)
                                  && (mix_read == mix_written)
                                  && (sum_read == sum_read_1)
                                  && (rep_err  == 32'd0);
                        state     <= T_IDLE;
                    end else begin
                        rep_n <= rep_n + 1'b1;
                        state <= T_REP_REQ;
                    end
                end
            end

            default: state <= T_IDLE;
            endcase
        end
    end

`ifdef SIMULATION
    // synthesis translate_off
    always_ff @(posedge clk) begin
        if (done) begin
            if (pass)
                $display("g1_sdram_selftest: PASS  sum=%08X mix=%08X",
                         sum_read, mix_read);
            else
                $display("g1_sdram_selftest: FAIL  sum %08X vs %08X, mix %08X vs %08X",
                         sum_read, sum_written, mix_read, mix_written);
        end
    end
    // synthesis translate_on
`endif

endmodule

`default_nettype wire
