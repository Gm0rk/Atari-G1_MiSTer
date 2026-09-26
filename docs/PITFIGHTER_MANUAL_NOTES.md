# Pit Fighter operator's manual: what it means for the core

Source: the Atari Games *Pit Fighter* operator's manual, with its schematics:
game PCB 045977-01 J (fig. 5-1), JSA Audio II PCB 046487-01 E (fig. 5-2) and
game wiring 048097-01 A (fig. 5-3). The JSA II and the game PCB are the same
boards Hydra uses, so the sound and test-switch findings apply to both games.

Where the manual and MAME disagree, the schematic plus a disassembly of the
game code decided it. MAME was then run (`tools/mame/`) to check what each
game actually does.

## Changed in build 115

| Area | What the manual shows | Change |
|---|---|---|
| **Test switch on the sound board** | One `/SELFTEST` net joins JAMMA pin 15, the game PCB (AUD-29) and the JSA II's own SW1 (J1-29). The game PCB reads it through 35A (74LS244, not inverting) as `IN0` bit 14, active low. The JSA II reads it through 2F (**74LS240, inverting**) as 6502 `RDIO` bit 7, **active high**. MAME's 6502 always reads 0 there: `main_test_read_line()` returns `!test` and `rdio_r()` XORs `0x80` as well. | The OSD service switch now drives both CPUs. The sound program (identical in both games) tests the bit at reset (`$4016`): with it set, the 6502 runs its power-up diagnostics before its boot `$FF` answer. These are a walking-bit RAM test, a checksum of all four ROM banks plus `$4000-$FFFF`, and an IRQ-timing check, and the result lands in RAM `$02`. The bit is tested again on every coin poll (`$5929`): with it set, the 6502 reports the coin switches raw instead of counting them. The Sound Test displays both results, as `SOUND CPU STATUS` and `COIN MECH SWITCHES`. |
| **Coin mechs** | Two per cabinet: COIN 1 on JAMMA pin 16 (left mech) and COIN 2 on pin T (right mech). The Sound Test, the coin options and the statistics know only LEFT and RIGHT. | Player 3's coin button used to drive the JSA's coin 3. The 6502 counts coin 3, but in MAME neither game credits it: Pit Fighter keeps showing `INSERT COINS` and Hydra `Insert 1 coin` (`tools/mame/coin_credit.lua`). Player 3's coin now drops into the right mech, and coin 3 reads 0. |
| **Mixer balance** | YM3012 L and R each drive the same inverting summer through **equal** resistors. These are switched in pairs by 4066 3B: 30K on MIX bit 1, 15K on bit 2, 7.5K on bit 3. So the output is L+R **summed**, and the gain is proportional to vol/7. | The structure now matches MAME, and so does the level. Builds ≤ 114 averaged L and R, divided vol by 8, and took a full-scale OKI voice as 0.25 of full scale. That left the YM:OKI ratio at **3.5, where MAME's is 1.6**: speech and samples were 6.8 dB too quiet. The new mixer measures 1.605 in `sim/tb_jsa_mixer.sv`. |
| **`IN0` bits 11:8** | 35A also buffers four of player 2's JAMMA lines onto the 68000's `FC0000`: bit 8 is Z (Punch 2), 9 is a (Kick 2), 10 is b (Jump 2), 11 is c (spare). MAME calls these bits unused. | Pit Fighter's `IN0` bits 10:8 now carry player 2's buttons. The game reads player 2 from `IN1`, so the only visible effect is the Switch Test's raw `FC0000` word. |

## Confirmed, nothing to change

- **Clocks.** Crystal X1 is 14.318 MHz on the game PCB, and the 68000 runs at the full crystal rate, as MAME has it. Its clock (68.CLK, sheet 5-4) comes from /14MP through 110B and R92. The alternative through R93 would give 7M2, half the rate, but R93 is absent from the parts list, so it is not fitted. This settles the question left open in the architecture document's §3.1. The JSA II has its own 3.579 MHz crystal, divided by 2 for the 6502 (1.79 MHz) and by 3 for the OKI (1.193 MHz, via 6F).
- **EEPROM.** A 28C16 (2 KB) at 30E, with the 120D unlock flip-flop. Every coin option, game option and statistic lives in it; there are no DIP switches. It persists through the MRAs' `<nvram index="2" size="2048"/>`.
- **Slapstic.** The manual's board is the 4-Mbit-PROM version: motion-object ROMs 136081-1065 to 1068, which is the `pitfight5` layout. Its parts list shows a 137412-**112** at 20E. MAME's `pitfight5` is `pfslap112`, which is what the MRA uses.
- **Controls.**
  - Three players: left is JAMMA player 1, centre is JAMMA player 2, and right is player 3 on connector JT (fig. 5-3).
  - Each player has an 8-way stick and Punch, Kick and Jump buttons.
  - The JAMMA start pins (17 and U) are unused: Jump is Start, as the "START/JUMP" plates show. The MRAs' separate Start button ORs into Jump.
  - "Start 1 & 2" in the test menus means P1 Jump + P2 Jump.
- **Input bits.** `FC0000` and `FC8000` agree with the schematic bit for bit: player 1 through 70B, player 2 through 10A2, player 3 through 75B. Bit 13 is the ADC's EOC; the ADC (10A1) is not fitted on Pit Fighter, so the bit is pulled up.
- **Palette.** Each colour channel goes through a 6-bit R2R DAC (RN1–RN3). D5–D1 carry the channel's 5 bits, and D0 carries the shared intensity bit, which is MAME's IRGB-1555.
- **JSA II registers.**
  - WRIO is latched by 4D (74LS273): bits 7:6 bank, bit 5 coin counter 2, bit 4 coin counter 1, bit 3 VFREQ (OKI pin 7), bit 2 /OKIRES, bit 0 /YAMRES.
  - MIX is latched by 3C (74LS174): bit 5 LPF, bits 3:1 YM0–2, bit 0 SP0.
  - The sound program clears VFREQ at boot, so the OKI normally runs at /165 (7.23 kHz).

## Found but not changed (candidates for later)

- **Analog audio filtering.** The core does not model it, and neither does MAME. The real board is much duller than MAME, the ADPCM most of all.
  - YM path: a unity-gain Sallen-Key low-pass (12K/12K, 2.2 nF/1 nF) at about 8.9 kHz, Q 0.74. MIX bit 5 (LPF) switches another 3.3 nF in through Q5, taking it to about 4.3 kHz.
  - YM path: the 0.22 µF coupling into the volume summer makes a high-pass of about 340 Hz at vol 7. It falls at lower volumes, because the input resistance rises.
  - OKI path: an active twin-T notch at about 7.1 kHz (6.8K/6.8K with 3.3 nF/3.3 nF), gain 3. It sits on the /165 sample rate, so it removes the sample-clock whine.
  - OKI path: then a 10K/6.8 nF pole (about 2.3 kHz) and a 2K/0.1 µF pole (about 0.9–1.1 kHz).
  - This could become an OSD option ("PCB" vs "MAME"), decided after the MAME A/B listen.
- **OKI half/full ratio.** SP0 puts 7.5K in parallel with 15K. With the 2K/0.1 µF network in front, that is about 2.4:1 at DC, against MAME's 2:1. The difference is 1.7 dB on "half" only, so MAME's value is kept.
- **CT1.** MAME gates the OKI with the YM2151's CT1 pin, which it carried over from the JSA I (where CT1 and CT2 gate the POKEY and the TMS5220). On the JSA II schematic, CT1 and CT2 (3A pins 8 and 9) are not connected. The gating is kept because it is inaudible: both games write `$C0` to YM register `$1B` once at boot and never clear it. Over 9,000 frames, none of 380 OKI starts in Pit Fighter or 100 in Hydra happened with CT1 = 0 (`tools/mame/ct1_probe.lua`).
- **RGB output stage.** Each channel's DAC drives an emitter follower (Q1–Q3) biased by 2.2K to +5 V. A 5-input NOR (45B/65B, F260) of the channel's 5 bits drives an open-collector inverter (55B, 7406), which pulls the base down through 1K **only when all 5 bits are zero**. The result, relative to black:
  - A zero channel is black, about 0.3 V, the same level as blanking.
  - Any non-zero value is lifted by a pedestal of roughly 14% of full scale. The first step (5-bit value 1) comes out at about 17% of full scale, against about 3% on a linear DAC.
  - MAME's IRGB-1555 is linear, so dark colours in the photographs would look lighter on the cabinet, if its brightness is set so black is black. An operator who turns brightness down would get close to linear again.
  - A "PCB colour curve" option would be possible, but this depends on the monitor's setup, so it is only a candidate.

## Checking the core against the manual's self-test

Turn on OSD → Service Menu and reset. Flipping it on mid-game without a reset also switches the 6502's coin reporting to raw, as it would on the cabinet, so coins inserted then can credit oddly. The power-up RAM/ROM test prints a
message only on an error. A solid red, green or blue screen means bad working
RAM, playfield RAM or motion-object RAM, respectively. In the menu, the
joystick selects and Punch runs the test. From build 115 the sound CPU
also runs its own diagnostics whenever it is reset with the switch on. In
simulation they take about 1.9 s before its first answer, and they pass
on the real ROM.

| Screen | Expected |
|---|---|
| Switch Test | With test on and nothing pressed: `FC0000 = BFFF`, `FC8000 = FFFF`, `FD0000 = 00FF`. From build 115, player 2's buttons also change `FC0000`. Left Kick + Punch exits. |
| Sound Test | `NUMBER OF SOUNDS: 80`, `SOUND CPU STATUS: GOOD`. This is the 6502's status byte (RAM `$02`, sent by `$44F6`). It always flags a stalled IRQ or main loop; from build 115 it also carries the result of the 6502's own RAM and ROM checks. `COIN MECH SWITCHES` LEFT/RIGHT read 1 **while** a coin is held and 0 otherwise, from build 115; before that they showed the 6502's counters. Jump plays a sound, Punch exits. |
| Coin / Game Options | Defaults are in green. P1 Jump + P2 Jump restores factory settings, and Punch saves. The settings must survive a core reload (NVRAM). |
| Statistics | Coin counts and the OS/PG creation dates. The manual's board shows 05AUG1990. |
| Alphanumeric | The character set, scrollable. A fault here means the 15L ROM. |
| Motion Object | The ROM status squares must all be **green**; they are the motion-object ROM checksums (`g1_rle_checksum.sv`). The left stick moves the object, the centre stick scales it, and Jump/Kick select the object and picture. |
| Playfield | The left stick scrolls the whole picture. |
| Color | Seven screens. The first shows red, green, blue and white bands, bright to dark; then yellow, cyan and magenta; then purity fields. Kick or Jump moves on. |
| Convergence | Four grids. |
