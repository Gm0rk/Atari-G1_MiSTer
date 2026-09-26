//============================================================================
//  Atari G1 for MiSTer
//  g1_rom_loader.sv -- MRA/ioctl download to SDRAM, plus config capture
//
//  Packs the ioctl byte stream into 16-bit words and writes them to SDRAM,
//  and latches the MRA configuration bytes that select per-game behaviour.
//
//    ioctl_index 0 : ROM image
//    ioctl_index 1 : 9 configuration bytes (g1_pkg::g1_cfg_t)
//
//  No data is transformed: ioctl_addr maps straight to the SDRAM address and
//  the MRA does all ROM arrangement. Playfield planes 0-3 are paired with
//  <interleave output="32"> so a tile row's four bytes are contiguous; plane
//  4 and the alpha ROM (gfx_8x8x4_packed_msb) load linearly. The nibble
//  permutation into pixels is done by the playfield fetcher.
//
//  Clock domain: clk_sys (ioctl is synchronous to it via hps_io).
//============================================================================

`default_nettype none

module g1_rom_loader
    import g1_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    // ---- ioctl download bus (hps_io) ----
    input  wire         ioctl_download,
    input  wire [15:0]  ioctl_index,
    input  wire         ioctl_wr,
    input  wire [26:0]  ioctl_addr,
    input  wire [7:0]   ioctl_dout,
    output logic        ioctl_wait,

    // ---- SDRAM write port ----
    // Hold sdr_we, sdr_addr and sdr_din until sdr_ack (one clock) accepts it.
    output logic [24:0] sdr_addr,     // byte address
    output logic [15:0] sdr_din,
    output logic        sdr_we,
    input  wire         sdr_ack,

    // ---- Status and configuration ----
    output g1_cfg_t     cfg,          // latched MRA configuration
    output logic        cfg_valid,    // config bytes received
    output logic        rom_loaded,   // a ROM download has completed
    output logic        loading       // any download in progress
);

    //------------------------------------------------------------------------
    // Download type. ioctl_index[5:0] is the MRA <rom index="N">; the upper
    // bits carry the file-extension index, so an MRA load can arrive as $40.
    // Compare only the low six bits.
    //------------------------------------------------------------------------
    wire is_rom = ioctl_download && (ioctl_index[5:0] == 6'd0);
    wire is_cfg = ioctl_download && (ioctl_index[5:0] == 6'd1);

    assign loading = ioctl_download;

    //------------------------------------------------------------------------
    // Configuration capture. Bytes are stored by ioctl_addr, not a local
    // counter, so a short or padded blob cannot shift the fields.
    //------------------------------------------------------------------------
    logic [7:0] cfg_bytes [CFG_BYTES];

    //------------------------------------------------------------------------
    // Download start edges. cfg_valid and rom_loaded are not cleared by rst_n:
    // the framework asserts reset as soon as ioctl_download drops, which would
    // wipe them. Each is cleared only when a new download of its own kind
    // starts, since the MRA sends ROM and config as separate transfers.
    //------------------------------------------------------------------------
    logic is_rom_dd, is_cfg_dd;
    always_ff @(posedge clk) begin
        is_rom_dd <= is_rom;
        is_cfg_dd <= is_cfg;
    end
    wire rom_dl_start = is_rom && !is_rom_dd;
    wire cfg_dl_start = is_cfg && !is_cfg_dd;

    always_ff @(posedge clk) begin
        if (cfg_dl_start) begin
            cfg_valid <= 1'b0;
            // Defaults (Hydra, no Slapstic, no ADC) for fields the blob omits
            for (int i = 0; i < CFG_BYTES; i++) cfg_bytes[i] <= 8'h00;
            cfg_bytes[2] <= 8'h07;   // window base $078000 (Hydra)
            cfg_bytes[4] <= 8'hFF;   // MO right clip 255
        end
        else if (is_cfg && ioctl_wr && (ioctl_addr < CFG_BYTES)) begin
            cfg_bytes[ioctl_addr[3:0]] <= ioctl_dout;
            cfg_valid <= 1'b1;
        end
    end

    always_comb begin
        cfg.game_id       = cfg_bytes[0];
        cfg.slap_type     = cfg_bytes[1];
        cfg.slap_base     = cfg_bytes[2];
        cfg.mo_left       = cfg_bytes[3];
        cfg.mo_right      = cfg_bytes[4];
        cfg.pf_xoffset    = cfg_bytes[5];
        cfg.flags         = cfg_bytes[6];
        cfg.rle_objects_h = cfg_bytes[7];
        cfg.rle_objects_l = cfg_bytes[8];
    end

    //------------------------------------------------------------------------
    // Byte pairing. The 68000 is big-endian and ROM_LOAD16_BYTE puts file
    // offset 0 in the high byte, so the even ioctl byte becomes D[15:8].
    // ioctl is held off with ioctl_wait while a write is unacknowledged.
    //------------------------------------------------------------------------
    logic [7:0] byte_hi;
    logic       have_hi;
    logic       wr_pending;   // SDRAM write issued, not yet acknowledged

    assign ioctl_wait = wr_pending;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            byte_hi    <= 8'h00;
            have_hi    <= 1'b0;
            wr_pending <= 1'b0;
            sdr_we     <= 1'b0;
            sdr_addr   <= '0;
            sdr_din    <= '0;
            // rom_loaded has its own block below, with no reset
        end
        else begin
            if (wr_pending && sdr_ack) begin
                wr_pending <= 1'b0;
                sdr_we     <= 1'b0;
            end

            if (is_rom && ioctl_wr) begin
                if (!ioctl_addr[0]) begin
                    // Even byte: hold as the high half
                    byte_hi <= ioctl_dout;
                    have_hi <= 1'b1;
                end else begin
                    // Odd byte: emit the word. Pairing on ioctl_addr[0] rather
                    // than a toggle keeps it correct for a restarted download.
                    sdr_addr   <= {ioctl_addr[24:1], 1'b0};
                    sdr_din    <= {have_hi ? byte_hi : 8'h00, ioctl_dout};
                    sdr_we     <= 1'b1;
                    wr_pending <= 1'b1;
                    have_hi    <= 1'b0;
                end
            end

        end
    end

    wire rom_dl_falling = is_rom_dd && !is_rom;

    //------------------------------------------------------------------------
    // rom_loaded: separate block with no reset term. rom_dl_falling occurs in
    // the same cycle the memory reset releases (rst_n_mem includes
    // ioctl_download), so a reset branch here would miss it.
    //------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rom_dl_start)   rom_loaded <= 1'b0;
        if (rom_dl_falling) rom_loaded <= 1'b1;
    end

`ifdef SIMULATION
    // synthesis translate_off
    // Flag an SDRAM write that is never acknowledged (the download would stall)
    int stall_count;
    always_ff @(posedge clk) begin
        if (wr_pending && !sdr_ack) begin
            stall_count <= stall_count + 1;
            if (stall_count > 10000)
                $fatal(1, "g1_rom_loader: SDRAM write not acknowledged after 10000 clocks");
        end else begin
            stall_count <= 0;
        end
    end
    // synthesis translate_on
`endif

endmodule

`default_nettype wire
