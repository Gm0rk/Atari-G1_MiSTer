//============================================================================
//  Atari G1 for MiSTer
//  g1_addr_decode.sv -- 68000 address decode
//
//  Combinational decode of the 68000 address bus into one-hot device selects
//  and local addresses. This is the only module that knows the memory map.
//
//  Memory map (MAME atarig1.cpp main_map / pitfight_map / hydra_map):
//    $000000-$07FFFF  R   Program ROM (512 KB region)
//    $038000-$039FFF  R   Slapstic window, Pit Fighter, mirrored every $2000
//    $078000-$079FFF  R   Slapstic window, Hydra, mirrored every $2000
//    $F80000-$F80001  W   Watchdog reset
//    $F88000-$F8FFFF  W   EEPROM unlock (any write arms one EEPROM write)
//    $F90000          W   Sound command to JSA II (byte)
//    $F98000-$F98001  W   Sound CPU reset
//    $FA0001          W   RLE control register (byte: MOGO/ERASE/FRAME)
//    $FB0000-$FB0001  W   VBLANK IRQ acknowledge (clears IRQ1)
//    $FC0000-$FC0001  R   IN0
//    $FC8000-$FC8007  RW  Hydra: ADC0809. Pit Fighter: IN1
//    $FD0000          R   Sound response from JSA II (byte)
//    $FD8000-$FDFFFF  RW  EEPROM, 2 KB, low byte only (umask16 $00FF)
//    $FE0000-$FE7FFF  -   Open bus (decode space of the A048490-01 "G1 OOPS"
//                         daughter card at 10P, which carries the Slapstic)
//    $FE8000-$FE89FF  RW  Palette RAM, 1280 entries
//    $FF0000-$FFFFFF  RW  64 KB work RAM (video snoop regions inside)
//
//  Above $F80000 every device sits on an $8000 grid, so addr[19:15] is a
//  32-way slot number ($F80000 = 16 ... $FF8000 = 31) with no priority logic.
//  Work RAM covers slots 30-31 and is decoded as addr[19:16] == $F.
//============================================================================

`default_nettype none

module g1_addr_decode
    import g1_pkg::*;
(
    // ---- 68000 bus ----
    input  wire [23:1]  addr,
    input  wire         as_n,      // address strobe
    input  wire         rw_n,      // 1 = read, 0 = write
    input  wire         uds_n,     // upper data strobe (D[15:8])
    input  wire         lds_n,     // lower data strobe (D[7:0])

    // ---- Configuration ----
    input  wire [7:0]   slap_base, // window base [23:16]: $03 or $07
    input  wire         slap_en,   // Slapstic fitted (0 for the hydrap
                                   // prototypes and the bootleg)
    input  wire [1:0]   slap_bank, // current bank from g1_slapstic

    // ---- Selects (qualified by a valid bus cycle) ----
    output logic        sel_rom,
    output logic        sel_ram,
    output logic        sel_palette,
    output logic        sel_eeprom,
    output logic        sel_eeprom_unlock,
    output logic        sel_watchdog,
    output logic        sel_snd_cmd,
    output logic        sel_snd_reset,
    output logic        sel_snd_resp,
    output logic        sel_rle_ctrl,
    output logic        sel_irq_ack,
    output logic        sel_in0,
    output logic        sel_in1_adc,
    output logic        sel_unmapped,

    // ---- Local addresses ----
    // Program ROM word address. In the Slapstic window the bank replaces
    // bits [14:13]: MAME configure_entries(0, 4, maincpu + $38000, $2000)
    // puts the four banks at ROM $38000-$3FFFF, the window's own range.
    output logic [18:1] rom_addr,

    output logic [15:1] ram_addr,     // 64 KB work RAM, word address
    output logic [10:0] pal_addr,     // palette entry 0..1279
    output logic [10:0] eeprom_addr,  // EEPROM byte 0..2047
    output logic [1:0]  adc_chan,     // ADC0809 channel from $FC8000-$FC8007

    // CPU is in the Slapstic window. Used only for the ROM bank substitution;
    // g1_slapstic itself must see every bus cycle.
    output logic        in_slap_window
);

    // Valid cycle: AS low and at least one data strobe active
    wire cyc = !as_n && (!uds_n || !lds_n);

    wire        is_rom_space = (addr[23:19] == 5'b00000);   // $000000-$07FFFF
    wire        is_io_space  = (addr[23:20] == 4'hF);       // $F00000-$FFFFFF
    wire [4:0]  io_slot      = addr[19:15];

    //------------------------------------------------------------------------
    // Slapstic window: $2000 long, mirrored every $2000 through $8000, so it
    // is a compare of addr[23:15]. Must match g1_slapstic's in_range test, or
    // the ROM is read from a bank the Slapstic has not selected.
    //------------------------------------------------------------------------
    wire [8:0] slap_tag = {slap_base[7:0], 1'b1};

    assign in_slap_window = slap_en && is_rom_space && (addr[23:15] == slap_tag);

    always_comb begin
        rom_addr = addr[18:1];
        if (in_slap_window) begin
            rom_addr[14:13] = slap_bank;
        end
    end

    //------------------------------------------------------------------------
    // Device selects
    //------------------------------------------------------------------------
    always_comb begin
        sel_rom           = 1'b0;
        sel_ram           = 1'b0;
        sel_palette       = 1'b0;
        sel_eeprom        = 1'b0;
        sel_eeprom_unlock = 1'b0;
        sel_watchdog      = 1'b0;
        sel_snd_cmd       = 1'b0;
        sel_snd_reset     = 1'b0;
        sel_snd_resp      = 1'b0;
        sel_rle_ctrl      = 1'b0;
        sel_irq_ack       = 1'b0;
        sel_in0           = 1'b0;
        sel_in1_adc       = 1'b0;
        sel_unmapped      = 1'b0;

        if (cyc) begin
            if (is_rom_space) begin
                // Read-only; a write is flagged unmapped
                sel_rom      = rw_n;
                sel_unmapped = !rw_n;
            end
            else if (is_io_space) begin
                // Work RAM: top 64 KB, slots 30 and 31
                if (addr[19:16] == 4'hF) begin
                    sel_ram = 1'b1;
                end
                else begin
                    case (io_slot)
                    5'd16: sel_watchdog      = !rw_n;               // $F80000
                    5'd17: sel_eeprom_unlock = !rw_n;               // $F88000
                    5'd18: sel_snd_cmd       = !rw_n;               // $F90000
                    5'd19: sel_snd_reset     = !rw_n;               // $F98000
                    5'd20: sel_rle_ctrl      = !rw_n;               // $FA0000
                    5'd22: sel_irq_ack       = !rw_n;               // $FB0000
                    5'd24: sel_in0           =  rw_n;               // $FC0000
                    5'd25: sel_in1_adc       = 1'b1;                // $FC8000
                    5'd26: sel_snd_resp      =  rw_n;               // $FD0000
                    5'd27: sel_eeprom        = 1'b1;                // $FD8000
                    5'd29: begin                                    // $FE8000
                        // Palette is $A00 bytes of the $8000 slot; above entry
                        // 1279 is unmapped, not aliased (MAME: 1280 words).
                        if (addr[14:12] == 3'b000 && addr[11:1] < 11'd1280)
                            sel_palette = 1'b1;
                        else
                            sel_unmapped = 1'b1;
                    end
                    // $FE0000-$FE7FFF is unmapped in MAME too (its map line is
                    // commented out). Hydra probes it at startup, so decode it
                    // as open bus rather than flag it as unmapped.
                    5'd28: ;                        // $FE0000, open bus

                    default: sel_unmapped = 1'b1;
                    endcase
                end
            end
            else begin
                sel_unmapped = 1'b1;
            end
        end
    end

    //------------------------------------------------------------------------
    // Local addresses
    //------------------------------------------------------------------------
    assign ram_addr = addr[15:1];
    assign pal_addr = addr[11:1];

    // 2816 EEPROM: 2 K x 8, one byte per 68000 word (umask16 $00FF), so it
    // spans $1000 and aliases through the rest of the $8000 slot, as on the board.
    assign eeprom_addr = addr[11:1];

    // Four words at $FC8000; Hydra uses channels 0 (stick X), 1 (stick Y) and
    // 2 (pedal).
    assign adc_chan = addr[2:1];

endmodule

`default_nettype wire
