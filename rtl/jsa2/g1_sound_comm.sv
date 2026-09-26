//============================================================================
//  Atari G1 for MiSTer
//  g1_sound_comm.sv -- 68000 <-> 6502 communication latches
//
//  Port of MAME's atari_sound_comm_device: two single-byte latches, each with
//  a full flag that drives an interrupt line (as a level, not a pulse).
//
//      68000 writes $F90000 -> main_to_sound latch, flag set, 6502 NMI asserted
//      6502  reads  $2802   -> byte taken, flag cleared
//      6502  writes $2A02   -> sound_to_main latch, flag set, 68000 IRQ2 asserted
//      68000 reads  $FD0000 -> byte taken, flag cleared
//
//  The flags are output raw (1 = full). Polarity is applied where they are read:
//      main_to_sound_ready: 68000 IN0 bit 12 and 6502 RDIO bit 6, both active low
//      sound_to_main_ready: 6502 RDIO bit 5, active high
//
//  Clock domain: clk_sys
//============================================================================

`default_nettype none

module g1_sound_comm (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 68000 side -------------------------------------------------------
    input  wire [7:0]  main_din,
    input  wire        main_wr,       // write to $F90000
    input  wire        main_rd,       // read  of $FD0000
    output logic [7:0] main_dout,
    output logic       main_irq,      // -> 68000 IRQ2

    // ---- 6502 side --------------------------------------------------------
    input  wire [7:0]  snd_din,
    input  wire        snd_wr,        // write to $2A02
    input  wire        snd_rd,        // read  of $2802
    output logic [7:0] snd_dout,
    output logic       snd_nmi,       // -> 6502 NMI

    // ---- Latch-full flags, raw (no polarity applied) ----------------------
    output logic       main_to_sound_ready,
    output logic       sound_to_main_ready,

    input  wire        sound_reset    // sound board reset ($F98000): clears both latches
);

    logic [7:0] m2s_data, s2m_data;

    //------------------------------------------------------------------------
    // Main -> sound
    //------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n || sound_reset) begin
            m2s_data            <= 8'h00;
            main_to_sound_ready <= 1'b0;
        end
        else begin
            if (main_wr) begin
                m2s_data            <= main_din;
                main_to_sound_ready <= 1'b1;
            end
            // Write and read in the same clock: the write wins and the flag
            // stays set, as on a real latch.
            else if (snd_rd) begin
                main_to_sound_ready <= 1'b0;
            end
        end
    end

    assign snd_dout = m2s_data;
    assign snd_nmi  = main_to_sound_ready;

    //------------------------------------------------------------------------
    // Sound -> main
    //------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n || sound_reset) begin
            s2m_data            <= 8'h00;
            sound_to_main_ready <= 1'b0;
        end
        else begin
            if (snd_wr) begin
                s2m_data            <= snd_din;
                sound_to_main_ready <= 1'b1;
            end
            else if (main_rd) begin
                sound_to_main_ready <= 1'b0;
            end
        end
    end

    assign main_dout = s2m_data;
    assign main_irq  = sound_to_main_ready;

endmodule

`default_nettype wire
