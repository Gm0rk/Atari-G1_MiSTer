//============================================================================
//  Atari G1 for MiSTer
//  g1_eeprom.sv -- 2816 parallel EEPROM (2 K x 8) with unlock protection
//
//  CPU $FD8000-$FDFFFF, low byte only (MAME umask16 $00FF). Holds operator
//  settings and high scores, saved and loaded through MiSTer nvram.
//
//  MAME: EEPROM_2816 with lock_after_write(true). Writes are ignored unless
//  the CPU has first written anything to $F88000-$F8FFFF, and the lock re-arms
//  after each accepted write. This guards the settings against a runaway CPU.
//
//  Clock domain: clk_sys
//============================================================================

`default_nettype none

module g1_eeprom (
    input  wire         clk,
    input  wire         rst_n,

    // ---- 68000 side ----
    input  wire [10:0]  cpu_addr,     // byte address 0..2047
    input  wire [7:0]   cpu_din,      // D[7:0] only
    input  wire         cpu_sel,      // $FD8000-$FDFFFF decoded
    input  wire         cpu_wr,       // write strobe, one clock
    input  wire         cpu_unlock,   // write seen at $F88000-$F8FFFF
    output logic [7:0]  cpu_dout,

    // ---- MiSTer nvram (hps_io ioctl upload/download) ----
    // Save: the HPS walks nv_addr and reads nv_dout. Load: it drives nv_din/nv_wr.
    input  wire         nv_active,    // nvram load or save in progress
    input  wire [10:0]  nv_addr,
    input  wire [7:0]   nv_din,
    input  wire         nv_wr,
    output logic [7:0]  nv_dout,

    output logic        nv_dirty      // one-clock pulse per accepted CPU write
);

    logic [7:0] mem [2048];

    // Power up as $FF like a blank part and MAME (eeprom.cpp nvram_default is
    // ~0; atarig1 gives no default region). Both games' EEPROM records use a
    // byte-wise correcting code (Pit Fighter $5888, Hydra $5E0E) that accepts
    // all-$00 as a corrected record but rejects all-$FF. Becomes the M10K
    // initial contents; a loaded .nvm file overwrites it.
    initial begin
        for (int i = 0; i < 2048; i++) mem[i] = 8'hFF;
    end

    //------------------------------------------------------------------------
    // Unlock: set by any write to $F88000-$F8FFFF, cleared by the next
    // accepted EEPROM write (a read does not consume it).
    //------------------------------------------------------------------------
    logic unlocked;

    wire write_accepted = cpu_sel && cpu_wr && unlocked;

    // One write port shared by the CPU and nvram restore (simple dual-port RAM).
    // They never overlap: nv_wr is only driven during a load, with the core in
    // reset. nvram writes bypass the unlock.
    wire [10:0] wa = (nv_active && nv_wr) ? nv_addr : cpu_addr;
    wire [7:0]  wd = (nv_active && nv_wr) ? nv_din  : cpu_din;
    wire        we = (nv_active && nv_wr) | write_accepted;

    always_ff @(posedge clk) begin
        nv_dirty <= 1'b0;

        if (!rst_n) begin
            unlocked <= 1'b0;
        end else begin
            if (cpu_unlock) unlocked <= 1'b1;

            if (write_accepted) begin
                unlocked <= 1'b0;        // lock_after_write(true)
                nv_dirty <= 1'b1;
            end
        end

        if (we) mem[wa] <= wd;
        cpu_dout <= mem[cpu_addr];
    end

    // nvram read port
    always_ff @(posedge clk) begin
        nv_dout <= mem[nv_addr];
    end

`ifdef SIMULATION
    // synthesis translate_off
    // Occasional blocked writes are normal (self-test checks the lock); a long
    // run of them points at the unlock decode.
    int blocked;
    always_ff @(posedge clk) begin
        if (cpu_sel && cpu_wr && !unlocked) begin
            blocked <= blocked + 1;
            if (blocked == 64)
                $display("g1_eeprom: 64 writes blocked by the lock. "
                         "Check the $F88000-$F8FFFF unlock decode.");
        end
    end
    // synthesis translate_on
`endif

endmodule

`default_nettype wire
