//============================================================================
//  Atari G1 for MiSTer
//  g1_palette.sv -- 1280-entry palette RAM, IRGB-1555 to RGB888
//
//  CPU $FE8000-$FE89FF: 1280 16-bit entries in MAME palette format IRGB_1555.
//  Dual-port BRAM: port A is the 68000 (read/write, byte lanes), port B the
//  video scan-out (read only). A CPU write and a video read of the same entry
//  in one cycle return the old value to the video port.
//
//  Clock domain: clk_sys (both ports).
//============================================================================

`default_nettype none

module g1_palette
    import g1_pkg::*;
(
    input  wire                  clk,

    // ---- Port A: 68000 -----------------------------------------------------
    input  wire [PAL_AW-1:0]     cpu_addr,    // entry index 0..1279 (word address)
    input  wire [15:0]           cpu_din,
    input  wire                  cpu_wr_hi,   // write D[15:8]  (68000 /UDS)
    input  wire                  cpu_wr_lo,   // write D[7:0]   (68000 /LDS)
    output logic [15:0]          cpu_dout,

    // ---- Port B: video scan-out -------------------------------------------
    // vid_r/g/b and vid_raw follow vid_index by two clocks (BRAM, conversion).
    input  wire [PAL_AW-1:0]     vid_index,
    output logic [7:0]           vid_r,
    output logic [7:0]           vid_g,
    output logic [7:0]           vid_b,
    output logic [15:0]          vid_raw      // raw entry, for debug overlays
);

    // Clocks from vid_index to vid_r/g/b.
    localparam int VID_LATENCY = 2;

    //------------------------------------------------------------------------
    // Storage: two byte-wide arrays, so Quartus infers the CPU byte enables
    // reliably.
    //------------------------------------------------------------------------
    logic [7:0] ram_hi [PAL_ENTRIES];
    logic [7:0] ram_lo [PAL_ENTRIES];

    logic [7:0] cpu_q_hi, cpu_q_lo;
    logic [7:0] vid_q_hi, vid_q_lo;

    // Port A: CPU read/write.
    always_ff @(posedge clk) begin
        if (cpu_wr_hi) ram_hi[cpu_addr] <= cpu_din[15:8];
        if (cpu_wr_lo) ram_lo[cpu_addr] <= cpu_din[7:0];
        cpu_q_hi <= ram_hi[cpu_addr];
        cpu_q_lo <= ram_lo[cpu_addr];
    end

    assign cpu_dout = {cpu_q_hi, cpu_q_lo};

    // Port B: video read.
    always_ff @(posedge clk) begin
        vid_q_hi <= ram_hi[vid_index];
        vid_q_lo <= ram_lo[vid_index];
    end

    wire [15:0] entry = {vid_q_hi, vid_q_lo};

    //------------------------------------------------------------------------
    // IRGB-1555 to RGB888
    //------------------------------------------------------------------------
    // MAME raw_to_rgb_converter::IRRRRRGGGGGBBBBB_decoder. The intensity bit
    // is the shared LSB of three 6-bit channels, not a brightness flag:
    //     r6 = { raw[14:10], i }   g6 = { raw[9:5], i }   b6 = { raw[4:0], i }
    // pal6bit then expands 6 bits to 8 by repeating the top two: { x, x[5:4] }.
    //------------------------------------------------------------------------
    wire       i_bit = entry[15];
    wire [5:0] r6    = {entry[14:10], i_bit};
    wire [5:0] g6    = {entry[9:5],   i_bit};
    wire [5:0] b6    = {entry[4:0],   i_bit};

    always_ff @(posedge clk) begin
        vid_r   <= {r6, r6[5:4]};
        vid_g   <= {g6, g6[5:4]};
        vid_b   <= {b6, b6[5:4]};
        vid_raw <= entry;
    end

`ifdef SIMULATION
    // Reference values from MAME's decoder: $7C00 -> R = $FB (r6 = 62),
    // $FC00 -> R = $FF (r6 = 63).
    initial begin
        $display("g1_palette: IRGB1555 decode is combinational; "
                 "verify $7C00 -> R=0xFB and $FC00 -> R=0xFF in the testbench");
    end
`endif

endmodule

`default_nettype wire
