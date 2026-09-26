//============================================================================
//  Atari G1 for MiSTer
//  g1_mainram.sv -- 64 KB work RAM at $FF0000-$FFFFFF
//
//  One contiguous 64 KB RAM, as on the board; the video hardware snoops
//  sub-ranges of it:
//    $FF0000-$FF0FFF  MO object RAM   (256 objects x 8 words)
//    $FF1000-$FF1FFF  work RAM
//    $FF2000-$FF2001  MO command latch (also readable as ordinary RAM)
//    $FF2002-$FF3FFF  work RAM
//    $FF4000-$FF5FFF  Playfield tile RAM (64 x 64 words)
//    $FF6000-$FF6FFF  Alpha tile RAM (64 x 32 words)
//    $FF7000-$FFFFFF  work RAM
//  Do not split it per region: the games write across the boundaries, and the
//  playfield scroll registers are columns 48-49 of the alpha tile RAM
//  (g1_scroll).
//
//  Port A is the 68000. Port B is read-only for the video side (playfield,
//  alpha and scroll fetchers, MO object RAM snapshot), time-multiplexed
//  upstream. The RLE checksum write-back shares port A's write path (ext_*)
//  while the 68000 waits on the command, so the RAM has a single write port:
//  a 32 K x 16 array with two write ports does not infer as M10K on
//  Cyclone V.
//
//  Clock domain: clk_sys (both ports)
//============================================================================

`default_nettype none

module g1_mainram (
    input  wire         clk,

    // ---- Port A: 68000 ----
    input  wire [14:0]  cpu_addr,   // word address, 0..32767
    input  wire [15:0]  cpu_din,
    input  wire         cpu_wr_hi,  // UDS-qualified write, D[15:8]
    input  wire         cpu_wr_lo,  // LDS-qualified write, D[7:0]
    output logic [15:0] cpu_dout,

    // ---- Port A write override: RLE checksum write-back ----
    // Priority over the CPU; word-wide
    input  wire [14:0]  ext_addr,
    input  wire [15:0]  ext_din,
    input  wire         ext_we,

    // ---- Port B: video / RLE engine, read-only ----
    input  wire [14:0]  vid_addr,
    output logic [15:0] vid_dout
);

    // Two byte-wide arrays give reliable per-byte write enables; a single
    // 16-bit array with masked writes can infer without them, turning 68000
    // byte writes into word writes.
    logic [7:0] ram_hi [32768];
    logic [7:0] ram_lo [32768];

    logic [7:0] cpu_q_hi, cpu_q_lo;
    logic [7:0] vid_q_hi, vid_q_lo;

    // Single write port: CPU or checksum write-back
    wire [14:0] wa    = ext_we ? ext_addr    : cpu_addr;
    wire [7:0]  wd_hi = ext_we ? ext_din[15:8] : cpu_din[15:8];
    wire [7:0]  wd_lo = ext_we ? ext_din[7:0]  : cpu_din[7:0];
    wire        we_hi = ext_we | cpu_wr_hi;
    wire        we_lo = ext_we | cpu_wr_lo;

    always_ff @(posedge clk) begin
        if (we_hi) ram_hi[wa] <= wd_hi;
        if (we_lo) ram_lo[wa] <= wd_lo;
        cpu_q_hi <= ram_hi[cpu_addr];
        cpu_q_lo <= ram_lo[cpu_addr];
    end

    always_ff @(posedge clk) begin
        vid_q_hi <= ram_hi[vid_addr];
        vid_q_lo <= ram_lo[vid_addr];
    end

    assign cpu_dout = {cpu_q_hi, cpu_q_lo};
    assign vid_dout = {vid_q_hi, vid_q_lo};

endmodule

`default_nettype wire
