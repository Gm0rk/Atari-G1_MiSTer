# Atari G1 for MiSTer FPGA

A work-in-progress FPGA implementation of Atari Games' **G1** arcade hardware:
board **A047896**, the platform under **Pit Fighter** and **Hydra**, written 
for the [MiSTer](https://github.com/MiSTer-devel) platform.

## Contents

- [The hardware](#the-hardware)
- [Status](#status)
  - [Measured on hardware](#measured-on-hardware)
  - [Where the core deliberately differs from MAME](#where-the-core-deliberately-differs-from-mame)
- [Using the core](#using-the-core)
  - [Controls](#controls)
  - [Game settings](#game-settings)
  - [OSD menu](#osd-menu)
- [Building](#building)
  - [The debug overlay](#the-debug-overlay)
- [Repository layout](#repository-layout)
- [How it is verified](#how-it-is-verified)
- [Credits and references](#credits-and-references)
- [License](#license)

**Both games run.** Tested on a DE10-Nano, Pit Fighter boots and
runs its attract mode. It draws all three layers: the scrolling playfield,
the digitised fighters and crowd, and the text.  Music, speech and effects play. 
**Hydra** runs too: its attract mode, title and gameplay demo draw correctly, and it has sound. 
The compile meets timing, and each game's ROM image reads back from SDRAM
exactly as it was written. See [Status](#status).

> **This core was made with AI.** The RTL, testbenches, reference models and
> documentation were written in collaboration with an AI assistant (Claude, by
> Anthropic). It worked from MAME's source, from the operator's
> manual and its schematics. Every change was verified in simulation
> against a reference and then on a DE10-Nano before being accepted.
> This is disclosed here so you can make your decision to use this core accordingly.

---

## The hardware

Atari G1 was a short-lived board: a 68000 behind Atari's Slapstic bank
controller, Atari's RLE "growth renderer" motion-object engine, and the
separate JSA II sound board. Only two games shipped on it.

Board photographs, chip listings and the wider family context are catalogued at
[System 16 — Atari G1 Hardware](https://www.system16.com/hardware.php?id=773).

| Game | Year | Players |
|---|---|---|
| Pit Fighter | 1990 | 3 (2-player sets exist): 8-way stick, Punch / Kick / Jump |
| Hydra | 1990 | 1: X-Y flight yoke with triggers and thumb buttons, two Boost buttons, foot pedal |

| | |
|---|---|
| Main CPU | Motorola 68000 (MC68HC000) @ 14.318181 MHz, the crystal undivided. The schematic shows a ÷2 option through resistor R93, which is not fitted. |
| Protection | Atari Slapstic II banking an 8 KB ROM window: 137412-111 to -114 depending on the Pit Fighter revision, -116 on Hydra |
| Sound | JSA II: 6502 @ 1.789773 MHz, YM2151 @ 3.579545 MHz, OKI6295 @ 1.193182 MHz. The OKI's sample rate is set by the sound program, normally /165. |
| Video | 336×240 visible in a 456×262 raster, 59.9227 Hz |
| Layers | scrolling playfield tilemap, fixed alpha (text) tilemap, RLE motion objects |
| Objects | RLE-compressed and scaled, drawn from a 2 MB object ROM |
| Palette | 1,280 entries, IRGB-1555 with a shared intensity bit |
| Settings | 2 KB EEPROM (2816) behind an unlock sequence. It holds every operator setting and statistic; there are no DIP switches. |

---

## Status

| Area | State |
|---|---|
| **Pit Fighter** | **Runs on hardware.** Boots and runs its attract mode, with every layer drawn, clean photos, credits and sound.|
| **Hydra** | **Runs on hardware.** Attract mode, title and gameplay demo draw correctly; sound plays; the memory check passes.|
| 68000 + Slapstic | **Working on hardware.** Every Slapstic type is vector-matched against MAME (400,000 accesses per seed, 0 mismatches) |
| Memory (SDRAM) | **Working.** The whole-image readback equals what was written, and repeat reads give 0 errors. A self-test measures every capture setting on each boot, and the core picks the best one by default |
| Video timing | **Working.** Stable 59.92 Hz on a real display |
| Tilemaps | **Working on hardware.** Confirmed on hardware |
| Motion objects (RLE) | **Working on hardware.** Fighters and crowd draw and animate. In simulation, the engine running on the real ROMs is pixel-exact against a port of MAME's `atarirle.cpp` |
| JSA II sound | **Working on hardware.** Music, speech and effects play. |
| Controls and coins | **Working on hardware** for Pit Fighter. Player 3's coin credit is mapped to the right coin mech, because the cabinets have only two coin mechs. **Hydra**: a Pedal button (it ramps like MAME's keyboard pedal), pedal from the right stick pushed up, and d-pad steering while the left stick is centred. Pushing the analog stick left or up used to steer hard right or down at the default sensitivity; that is fixed, and the default is now the stick's full range. Checked in simulation, not yet on hardware |
| EEPROM | Implemented and saved as NVRAM. Persistence across reloads. |
| Service menu | Reached with **OSD → Service Menu → On**, then reset. The sound CPU sees the switch too, as on the real board, so the Sound Test shows its own RAM/ROM check and live coin switches. The screens have not yet been walked through; see the checklists in [`docs/PITFIGHTER_MANUAL_NOTES.md`](docs/PITFIGHTER_MANUAL_NOTES.md) and [`docs/HYDRA_MANUAL_NOTES.md`](docs/HYDRA_MANUAL_NOTES.md) |
| MRAs | **Working.** 13 sets (10 Pit Fighter, 3 Hydra), each byte-exact at 3,737,088 bytes, with a validated 68000 reset vector. The interleave layout is checked by MiSTer's own loader rules. Merged (torrentzipped) ROM sets are supported |

### Measured on hardware

Read off the debug overlay. These are from build 113 with the build-114 MRAs:

* **Compile:** timing met, 440 of 553 M10K blocks used.
* **Memory:** the read-back checksum equals the write-side one, with `REPE 0`
  repeat-read errors: `SUMW = SUM2 = 0B10FC09` for Pit Fighter and
  `0F878C54` for Hydra.
* **Line fetch:** no scanline skipped in either game. The longest
  playfield + text fetch took 2,657 of the 3,648 clocks in a line on Pit
  Fighter (`VFET 00000A61`), and 2,678 on Hydra (`00000A76`).
* **Sound CPU:** it answers the game's per-frame coin query every frame, with
  no phantom coins (1,009 answers in a row).
* **Sprites:** no dropped redraws in either game (`MOGO`).
* **Watchdog:** it never fires (`WDOG 0`).
* **Clocks:** all six within 1 ppm of MAME's values.



### Where the core deliberately differs from MAME

Each of these follows the board schematics in the Pit Fighter operator's
manual, and was checked against the game code before changing
(`docs/MAME_REVIEW.md` #21–#24):

* **The sound CPU sees the test switch.** The JSA II reads it through an
  inverting buffer (1 = test on). MAME reads it as 0 always, because it
  inverts twice.
* **Player 3's coin drops into the right coin mech.** Neither game credits
  the sound board's third coin input.
* **Pit Fighter's `IN0` bits 8–10 carry player 2's buttons**, as the game PCB
  wires them. MAME calls those bits unused.

---

## Using the core

ROMs are not distributed with this core. Put the `.mra` files from `mra/` in
`_Arcade`, and the MAME ROM sets (`pitfight.zip`, `hydra.zip`; merged sets
work) where your MRAs look for them.

### Controls

**Pit Fighter** (the MRA defaults): stick, **Punch** A, **Kick** B,
**Jump** X, **Start** Start, **Coin** R. On the cabinet the Jump button is
also Start, so Start and Jump do the same thing. Pressing Punch + Kick + Jump
together is the Super Move. Player 1's coin goes to the left mech, and
players 2 and 3 go to the right.

**Hydra** (the MRA defaults): the **left analog stick** is the
flight yoke. Left and right steer; up and down set the altitude while in the
air. The d-pad also steers when the stick is centred. There is no start
button: **the pedal starts a game** and is the throttle. Use the **Pedal**
button (R), which ramps up while held, or push the **right stick** up for
analog throttle.

| Pad | Hydra control | What it does |
|---|---|---|
| A | Left Trigger | fire the laser cannons |
| B | Right Trigger | fire the laser cannons |
| X | Left Thumb | select a special weapon |
| Y | Right Thumb | fire the special weapon |
| L | Boost | launch the Hydracraft into the air |
| R | Pedal | start, and accelerate |
| Select | Coin | |

A game starts with Coin, then the pedal. On the mission select screen, the
yoke chooses the level and Boost starts play. If steering or the pedal feels
off-centre or short of full travel, the game's own calibration is to blame:
recalibrate in the service menu's Switch Test (see
[`docs/HYDRA_MANUAL_NOTES.md`](docs/HYDRA_MANUAL_NOTES.md)). The result is
kept in the EEPROM. To make the yoke finer or quicker, change
**OSD → Controls → Analog sensitivity**.

### Game settings

Coinage, free play, difficulty, the attract-mode sound and so on are set in
each game's own service menu, not the OSD:

1. Turn on **OSD → Service Menu** and reset.
2. Change the settings. Save with Punch in Pit Fighter, or Boost in Hydra.
3. Turn **Service Menu** off and reset to play.

The settings are stored in the game's EEPROM, which the core saves to the SD
card.

### OSD menu

**Main page**

| Option | Settings | What it does |
|---|---|---|
| Aspect ratio | Original, Full Screen, [ARC1], [ARC2] | MiSTer's standard aspect options |
| Scandoubler Fx | None, HQ2x, CRT 25%, CRT 50%, CRT 75% | MiSTer's standard scandoubler filters |
| Service Menu | **Off**, On | The game's own service (test) menu. Takes effect at the next reset. |
| Debug | page | Bring-up and diagnosis options, below |
| Controls | page | Analog sensitivity, below |
| Reset | | Resets the game |

**Controls page**

| Option | Settings | What it does |
|---|---|---|
| Analog sensitivity | **Medium**, High, Low | Hydra's yoke. Medium: the full stick gives the full yoke. High: the full yoke at about two-thirds of the stick. Low: half the yoke's travel, for finer steering. No effect on Pit Fighter. |

**Debug page.** These options are for bring-up and diagnosis, and the
defaults are correct:

| Option | Settings | What it does |
|---|---|---|
| CPU clock | **14.318MHz (MAME)**, 7.159MHz | The 68000's clock. The board runs it at the full crystal rate; half speed is a diagnostic. |
| SDRAM capture | **Auto (self-test)**, Manual | Auto uses the read timing that the boot-time memory self-test measured best. |
| Manual read phase | **t8**, t9, t10, t7 | The read timing to use when SDRAM capture is Manual |
| Manual sample edge | **Falling**, Rising | The capture edge to use when SDRAM capture is Manual |
| Self-test bus | **Shared**, Exclusive | Exclusive runs the whole boot-time memory self-test with nothing else on the bus. |
| Watchdog | **Enabled**, Disabled | The board's watchdog, which resets a stalled game after about 3 seconds |
| Slapstic | **Enabled**, Bootleg mode | Bootleg mode reads the protected ROM window as plain ROM, as the bootleg board does. |
| Motion objects | **On**, Off | Off hides the sprites, to look at the playfield alone. |
| Diagnostic | **Off**, Text, Activity | The [debug overlay](#the-debug-overlay) |

Defaults are in **bold**.

---

## Building

Use Quartus Prime 17.0.x, the MiSTer standard. Before the first compile:

1. Run `python tools/setup_deps.py` once from the project root. It clones the
   parts this repository does not carry (`sys/`, fx68k, T65, JT51, JT6295)
   and wires them into `files.qip`. It needs only git.
2. Create the PLL in Quartus's MegaWizard (`BUILD.md`, step 1).

Then open `Arcade-AtariG1.qpf` and compile.

The PLL provides three clocks from the 50 MHz reference:

| Output | Frequency | Use |
|---|---|---|
| outclk0 | 57.272724 MHz | `clk_sys`: CPU, video pipeline, SDRAM arbiter |
| outclk1 | 114.545448 MHz | SDRAM controller |
| outclk2 | 114.545448 MHz, **−90°** | `SDRAM_CLK` |

The PLL is integer-N exact: M=126, N=5, VCO=1260, C0=22, C1=C2=11. 57.0 MHz is
*not* close enough; it lands the frame rate 0.5% slow.

The memory map spans 3,737,088 bytes, so any MiSTer SDRAM module is enough.

Run the one-second checks before compiling. Each one exists because the fault
it catches once cost a full compile cycle or worse:

```
bash   sim/syntax_check.sh           # parses every file with iverilog
python tools/gen_files_qip.py --check  # every .sv is actually in the build
python sim/port_audit.py             # connections vs port lists
python sim/driver_audit.py           # signals driven from two blocks
python sim/ram_audit.py              # arrays that will not infer as block RAM
python sim/sv_portability_audit.py   # constructs that crash Quartus 17.0
python sim/sdc_audit.py              # unbraced Tcl bracket patterns
python sim/implicit_net_audit.py     # use-before-declare (29 known, harmless)
python sim/mra_vector_check.py --zipdir <romdir>   # each MRA's reset vector
python sim/mra_image.py --check mra <romdir>       # each MRA's byte layout,
                                     # by MiSTer's own loader rules
bash   sim/tcl_syntax_check.sh       # actually runs timing_report.tcl
python tools/check_qip.py            # every path in the .qsf/.qip resolves
                                     # (after setup_deps.py)
```

Three are worth singling out:

- `sv_portability_audit.py` catches unpacked array ports. They are legal
  SystemVerilog and accepted by every simulator, but fatal to `quartus_map`:
  it fails with an Access Violation whose stack trace names nothing connected
  to the design.
- `syntax_check.sh` parses every file with a real front end, which regex-based
  checks cannot replace. This project once shipped a concatenation whose
  separators had landed inside the trailing comments, and balanced-brace
  counting saw nothing wrong with it.
- `mra_image.py --check` exists because the MRAs once loaded the playfield
  ROMs byte-reversed. The layout had only ever been checked against the RTL's
  own assumption.

### The debug overlay

OSD → Debug → Diagnostic → Text shows twenty labelled 32-bit hardware
counters in a small white-on-black panel, in the style of the Atari GT core's.
The game keeps running behind it at full brightness. That is deliberate: a
tinted picture makes colour faults look like overlay artefacts.

| Rows | Meaning |
|---|---|
| `BLD` | compile date (`YYMMDD`) and three-digit build number |
| `PC`, `WDOG`, `PALW` | last 68000 bus address, watchdog count, palette writes |
| `SUMW`, `SUM2`, `REPE`, `REPV` | memory self-test: write-side and read-back checksums, repeat-read errors |
| `S0`–`S7`, `PHAS` | error count at each SDRAM capture setting, and the setting in use |
| `VFET` | scanlines whose tile fetch overran, and the longest fetch |
| `MOGO` | sprite redraws dropped, and the longest render |
| `SND` | 68000 ↔ sound CPU traffic: reads, writes, and the last byte |

The build number goes up on every set of changed files and appears in the
name of the zip they ship in. That way a screenshot can always be tied back to
the sources that produced it. A second page (Diagnostic → Activity) colours
each bit of the whole dataflow chain: blue for stuck low, red for stuck high,
green for toggling.

---

## Repository layout

```
Arcade-AtariG1.sv     core top level, OSD, inputs, video output, debug overlay
rtl/
  g1_pkg.sv           shared parameters, build number, SDRAM memory map
  cpu/                68000 support
    g1_slapstic.sv      Atari Slapstic II bank controller (types 111-114, 116)
    g1_addr_decode.sv   the 32-slot address decode
  board/              board-level glue
    g1_top.sv           memory map, CPU, interrupts, bus
    g1_ce.sv            clock enable chain
    g1_mainram.sv       work RAM (tilemaps, object RAM, scratch)
    g1_eeprom.sv        EEPROM and its unlock sequence
    g1_adc0809.sv       ADC0809: Hydra's analogue controls
    g1_hydra_controls.sv  Hydra's yoke and pedal from a MiSTer pad
    g1_watchdog.sv      watchdog timer
  video/              raster and tilemaps
    g1_video_timing.sv  456x262 raster, ~59.9 Hz
    g1_video.sv         layer wiring and line-fetch arbitration
    g1_playfield.sv     scrolling playfield tilemap
    g1_alpha.sv         fixed alpha (text) tilemap
    g1_scroll.sv        per-line scroll registers
    g1_mixer.sv         layer priority, palette index generation
    g1_palette.sv       1,280 entries, IRGB-1555 to RGB888
    mob/                motion objects: the RLE "growth renderer"
      g1_rle.sv           engine top level and command register
      g1_rle_prescan.sv   object ROM prescan
      g1_rle_objram.sv    object RAM
      g1_rle_sort.sv      display-list sort
      g1_rle_decode.sv    RLE stream decoder
      g1_rle_scaler.sv    horizontal and vertical scaling
      g1_rle_render.sv    span renderer with a row cache
      g1_rle_fb.sv        object framebuffer
      g1_rle_checksum.sv  ROM checksums for Pit Fighter's self-test
  jsa2/               the JSA II sound board (a separate PCB)
    g1_jsa2.sv          6502, YM2151, OKI6295, mixer
    g1_sound_comm.sv    68000 <-> 6502 command and response
  mem/                FPGA-side only; no counterpart on the real board
    sdram.sv            SDRAM controller
    g1_sdram_arb.sv     arbiter
    g1_sdram_iface.sv   controller selection wrapper
    g1_sdram_selftest.sv memory image readback check
    g1_rom_loader.sv    ioctl download to SDRAM
  debug/
    g1_dbg_text.sv      labelled hex overlay
sim/                  audits, reference models, testbenches
tools/                dependency fetch, generators, timing report
mra/                  13 MRA files
docs/                 architecture notes, the MAME review, and notes on the
                      Pit Fighter and Hydra manuals
```

`rtl/` is laid out by section of the A047896 board, so a file's location says
which part of the hardware it models. `mem/` and `debug/` are the exceptions,
and are marked as such: the real board used mask ROMs and had no overlay.

## How it is verified

Each block is checked against a reference derived from MAME, or from the
board's schematics, rather than against expectations:

* **Slapstic.** Randomised accesses against a port of `slapstic.cpp` for every
  type, then confirmed on hardware by the game reaching code that only a
  working bank window exposes.
* **Video.** The line fetch runs on tile, scroll and palette RAM dumped from
  MAME, with the ROM image built exactly as MiSTer's loader builds it from the
  MRA. The frames come out pixel-identical to MAME's snapshots, with the SDRAM
  bus loaded or idle.
* **Motion objects.** The whole engine runs on the real ROMs. It is
  pixel-exact against a port of `atarirle.cpp` over hundreds of
  object/scale/flip cases and on MAME's own fight-screen object RAM.
* **Sound.** The real 6502 program runs on the JSA model (T65 converted with
  GHDL) behind an SDRAM latency model, and answers the 68000 byte for byte as
  MAME's does. The sound CPU's own power-up diagnostics pass on it. The mixer
  is checked against MAME's formula and music/speech ratio.
* **MAME itself.** Where behaviour over time mattered, Ubuntu's MAME 0.264 was
  run headless with Lua probes (`tools/mame/`) for reference data: the coin
  protocol, which coin inputs credit, the sprite command timing, and dumps of
  video memory.
* **The schematics.** The Pit Fighter operator's manual's schematics settled
  what MAME could not: the test-switch polarity on the sound board, the coin
  mechs, the mixer's structure, and the 68000 clock. The Hydra manual gave
  the control wiring and how the game starts.
* **Controls.** Hydra's pad handling (`g1_hydra_controls.sv`) is unit-tested
  for the analog pass-through, the d-pad and pedal ramps, and the case where
  the analog stick also sets the digital direction bits. How the game treats
  the pedal was checked in MAME first: it starts on a press from rest, with
  either the pedal polarity MAME uses or the real pot's.
* **MRAs.** Every set is byte-exact, with part names resolved against the real
  archives and a validated reset vector. Each one's byte layout is checked by
  a port of MiSTer's own loader code.
* **Hardware.** The debug overlay. Every open fault gets a counter before it
  gets a theory.

That last point was learned the hard way. Reference models verify function,
not plumbing, and the bugs that actually blocked bring-up were structural:

- a reset term dropped during a tidy-up, which held the loader inert for a
  whole download while the transfer reported success;
- one-clock pulses generated in the exact cycle their consumer left reset;
- a duplicate SDRAM access after every request;
- a sound CPU fed each program byte one cycle late;
- MRAs whose layout had only been checked against the RTL's own assumption.

The corollary is now applied throughout: **a diagnostic must itself be shown
capable of reporting the failure it is looking for** before its output is
trusted.

Every decision, its verification, and every conclusion later retracted (with
the reason) is kept in [PROGRESS.md](PROGRESS.md) and [BUILD.md](BUILD.md).
[`docs/MAME_REVIEW.md`](docs/MAME_REVIEW.md) lists every point checked
against MAME and every place the core differs from it.

---

## Credits and references

This core is a reimplementation. It would not have been possible without:

**[MAME](https://www.mamedev.org/)**, the reference for essentially all
hardware behaviour. Specifically:

| File | Author | Used for |
|---|---|---|
| `atarig1.cpp`, `atarig1.h` | Aaron Giles | memory map, machine configuration, interrupt levels, MO command register, input ports |
| `atarig1_v.cpp` | Aaron Giles | video registers, tilemap layout, per-scanline scroll, colour mixing |
| `atarirle.cpp`, `atarirle.h` | Aaron Giles | the RLE object engine: list scan, object table, decode, scaling, flip |
| `slapstic.cpp` | Aaron Giles | the Slapstic bank controller state machine |
| `atarijsa.cpp` | Aaron Giles | JSA II sound board configuration, comm registers and mixing |
| `eeprom.cpp` | Aaron Giles | EEPROM behaviour and the unlock sequence |

MAME is a reference for *behaviour*; no MAME code is compiled into this core.

**The *Pit Fighter* operator's manual** (Atari Games), with its game PCB,
JSA Audio II and wiring schematics. It is the source for everything in
`docs/PITFIGHTER_MANUAL_NOTES.md`.

**The *Hydra* Universal Kit installation instructions** (Atari Games,
TM-354): control wiring, game play, self-test and schematics. It is the source
for `docs/HYDRA_MANUAL_NOTES.md`.

**[fx68k](https://github.com/ijor/fx68k)** by Jorge Cwik: the 68000 core, a
cycle-accurate implementation derived from the original microcode. Its source
and accompanying notes settled the interrupt acknowledge timing when nothing
else could.

**T65** by Daniel Wallner, Mike Johnson, Wolfgang Scherr and Morten Leikvoll:
the 6502 core on the JSA II board.

**[JT51 and JT6295](https://github.com/jotego)** by Jose Tejada (**jotego**):
the YM2151 and OKI6295 implementations used on the JSA II board.

**[MiSTer](https://github.com/MiSTer-devel/Main_MiSTer)**: the framework, and
`Template_MiSTer` by Alexey Melnikov (**Sorgelig**), whose `sys/` directory
provides the HPS interface, video scaler and SDRAM pin handling this core builds
on. `sys/` is unmodified. MiSTer's MRA loader (`mra_loader.cpp`) is the
reference for `sim/mra_image.py`.

The MiSTer community's existing arcade cores were a useful model for project
structure and MRA conventions. The Atari GT core's debug overlay is the direct
model for this one's.

## License

The core RTL is released under the GNU General Public License v2.0 or later,
consistent with the MiSTer framework it builds on. See `LICENSE`.

`sys/`, fx68k, T65, JT51 and JT6295 retain their original licences and
authorship.

No ROM data is included or distributed.
