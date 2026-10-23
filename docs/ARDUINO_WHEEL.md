# Wiring up an Arduino steering wheel

The game is built to take a home-made wheel as its primary controller, and the
wheel is expected to look like a HID gamepad to the operating system. That means
**no driver, no serial bridge and no plugin**: the Arduino enumerates as a
joystick and Godot picks it up.

There are two ways to get there.

## Route 1 — the included sketch (recommended)

`arduino/wheel_hid/wheel_hid.ino` is written for a **Pro Micro, Leonardo or
Micro** (any ATmega32u4 board — these can act as a USB device; an Uno or Nano
cannot, so on those boards use route 2).

| control | Arduino pin | pot/button |
|---|---|---|
| steering | A0 | 10 kΩ **linear** pot |
| throttle | A1 | 10 kΩ linear pot |
| brake | A2 | 10 kΩ linear pot |
| handbrake | 4 → GND | push button |
| boost | 5 → GND | push button |
| reset car | 6 → GND | push button |
| pause | 7 → GND | push button |
| gear down (LB) | 8 → GND | push button |
| gear up (RB) | 9 → GND | push button |

Pot ends go to 5 V and GND, wiper to the analogue pin. Buttons need no resistors:
the sketch uses the internal pull-ups, so one leg to the pin and the other to
GND is enough.

Flash it with the Arduino IDE. You need the **Joystick** library by Matthew
Heironimus (Tools → Manage Libraries → search "Joystick"). Then open the game's
**CONTROLS & WHEEL** screen: the wheel appears under "Detected" and every axis is
shown live. Turn the wheel and you will see the axis move.

If the wheel steers the wrong way, set `INVERT_STEERING = true` in the sketch (or
tick **invert** on the game's controls screen) instead of rewiring the pot. If the
parked position drifts, raise `CENTRE_DEADZONE`.

## Route 2 — any wheel, wheelbase or gamepad you already own

Anything that shows up as a joystick works. The game ships with sensible
bindings:

- steering — axis 0 (X)
- throttle — axis 2 (Z), 5 (R2) or 1 (left stick up)
- brake — axis 3 (Rx), 4 (L2) or 1 (left stick down)

If your device uses something else, open **CONTROLS & WHEEL** in the game, press
**learn** next to Steering, Throttle or Brake, and then move that control. The
game records which axis moved and whether it needs inverting, and switches itself
to wheel mode. Nothing to type in, and it is saved to `user://settings.cfg`.

## How the game treats a wheel

- **Wheel mode** reads the calibrated axes directly, with a deadzone and a
  rescale so the first millimetre of travel is not a step. No steering assist is
  applied on a wheel — you get the raw thing, which is the point of having one.
- **Keyboard/gamepad mode** (the default) reads the action map and applies a
  gentle counter-steer assist, because a keyboard has no proportional steering.
- Force feedback is not supported: Godot has no cross-platform FFB API, and a
  pot-and-button wheel has nothing to push back with.

## Sanity checks

- The wheel must be plugged in **before** the game starts for wheel mode to find
  it; the controls screen will tell you if nothing is detected.
- Steering is ignored while the countdown runs, so you can hold the wheel at full
  lock on the grid without the car creeping.
- If an axis jitters and the car creeps on the grid, raise the **deadzone**
  slider on the controls screen (0.04–0.08 suits most pots).
