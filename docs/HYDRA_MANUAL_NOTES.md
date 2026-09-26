# Hydra manual: what it means for the core

Source: *Hydra Universal Kit Installation Instructions*, Atari Games TM-354
(1st printing, 5/90). It covers the JAMMA wiring, the controls, game play,
the self-test, and the schematics. The schematics are the same game PCB and
JSA II drawings as in the Pit Fighter manual (see
[`PITFIGHTER_MANUAL_NOTES.md`](PITFIGHTER_MANUAL_NOTES.md)). On Hydra the
ADC0809 at 10A1 is fitted.

## The controls

From table 1-3 (JAMMA pin and wire connections) and "Game Play":

| JAMMA | Signal | Core |
|---|---|---|
| 19 | LT TRIGGER | `IN0` bit 0, active low |
| 18 | RT TRIGGER | `IN0` bit 1 |
| 21 | LT THUMB | `IN0` bit 2 |
| 20 | RT THUMB | `IN0` bit 3 |
| 22 | BOOST (both Boost buttons) | `IN0` bit 4 |
| W | STEER L/R (yoke potentiometer) | ADC channel 0 (IN0 of the ADC0809) |
| V | FLY UP/DOWN (yoke potentiometer) | ADC channel 1 |
| Y | FOOT PEDAL (potentiometer) | ADC channel 2 |
| 16 / T | LT COIN / RT COIN | JSA II coins 1 / 2 |
| 15 | SELF-TEST | `IN0` bit 14, and the JSA's RDIO bit 7 |

The 68000 bits agree with MAME's `hydra` ports and with the game PCB
schematic (buffer 70B, the same wiring as Pit Fighter's player 1). The ADC's
channel select is the 68000's A3–A1, so the channel is the word offset from
`$FC8000`. That is what `g1_adc0809.sv` does.

**What each control does** ("Game Play", page 1-8):

- The **triggers** fire the laser cannons.
- The **left thumb button** selects a special weapon from the arsenal, and
  the **right thumb button** fires it.
- The **Boost buttons** launch the Hydracraft into the air.
- The yoke's **handles set the altitude** while in flight.
- The **accelerator pedal** drives, and the attract screen's "Press PEDAL to
  start" makes it the start control too. There is no start button (JAMMA 17
  and U are "Not used").

## What that meant for the core (build 117)

Builds up to 116 took the pedal only from MiSTer's paddle input. No gamepad
produces that, so a game could never be started. `g1_hydra_controls.sv` now
builds the three ADC inputs from a pad:

- **Pedal** (channel 2) is the largest of three sources:
  - the MRA's **Pedal** button (joystick bit 9, default R), which ramps up
    16 per frame while held and down 32 after release, like MAME's keyboard
    pedal (`KEYDELTA 16`);
  - the **right stick** pushed up;
  - the paddle.
- **Steering** (channels 0/1) is the left analog stick. When the stick is
  centred, the **d-pad** also steers: 10 per frame out and 20 back, like
  MAME's `KEYDELTA 10`. A deflected analog stick always wins. That matters
  because MiSTer also sets the digital direction bits when the analog stick
  is pushed.
- **Stick scaling** (OSD → Controls → Analog sensitivity): Medium, 100%,
  is the default from build 119. Before that the default was Low (50%),
  and a signed-arithmetic bug sent every left or up deflection at Low and
  High to full right or down. That was almost certainly the "controls not
  correct" on the first hardware run.
- The MRA's sixth button is renamed from **Start** (which drove nothing) to
  **Pedal**. The defaults are now `A,B,X,Y,L,R,Select`: Pedal on R and Coin
  on Select.

The pedal's direction was checked in MAME before choosing it. The game takes
the pedal's rest position as it finds it, and a press from rest starts a
game in both of these cases:

- MAME's range: rest `$00`, pressed `$FF`. The core uses this.
- The real pot's range from the manual's Switch Test: rest `$AE`, pressed
  `$2E`.

With the pedal held at rest it never starts.

## Calibration: the Switch Test

The game keeps **limits** for the yoke and pedal in the EEPROM (figure 2-7):

```
CTRL R/L=(01, ,FC)   CTRL U/D=(05, ,FC)   PEDAL U/D=(AE, ,2E)
```

If steering, climbing or the pedal seem off-centre or fall short of full
travel, recalibrate:

1. Enter the service menu: OSD → Service Menu → On, then reset.
2. Choose SWITCH TEST.
3. Press **both thumb buttons together** to reset the limits.
4. Move the stick fully right, left, up and down until the white numbers
   next to the green ones stop changing.
5. Press the pedal fully and hold it until its number stops changing.
6. Press both triggers together to exit.

The limits are saved in the EEPROM, so they persist once the core has saved
it.

## The self-test, for checking the core

Turn on OSD → Service Menu, then reset. The power-up RAM and ROM tests
take about half a minute before the menu appears. The menu is **SELF TEST**,
dated OS 25APR1990, PROG 27APR1990 on the manual's set:

- Left and right trigger move up and down the menu.
- Boost runs the selected test.

| Screen | What to check |
|---|---|
| Statistics | Coin counts and times. Press all four triggers and thumbs to clear. |
| Coin Options / Game Options | Defaults in green. Triggers select the option, thumb buttons change it, the pedal restores factory settings, Boost saves. The settings must survive a core reload. |
| Alphanumeric | Scrolls with the yoke. |
| Motion Object | Left trigger + yoke moves the object; right trigger + up/down scales it; thumb buttons pick objects (all 700 pictures). |
| Switch Test | Every control highlights when used. Raw values for the yoke and pedal, and the calibration above. |
| Playfield | The yoke scrolls the whole picture. |
| Color RAM, Convergence | Bars and purity fields, as on Pit Fighter. |
| Sound Test | `NUMBER OF SOUNDS: 199`, `SOUND CPU STATUS: GOOD`. From build 115, `COIN MECH SWITCHES` show 1 only while a coin is held. The triggers select a sound, the right thumb plays it, and the left thumb stops it. |

A solid red, green or blue screen at power-up means bad working RAM,
playfield RAM or motion-object RAM, respectively (table 3-5).
