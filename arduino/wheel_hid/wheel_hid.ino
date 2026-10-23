/*
 * Arduino steering wheel for Astra Racer
 * --------------------------------------
 * Turns a Pro Micro (or any ATmega32u4 board: Leonardo, Micro, SparkFun Pro
 * Micro) into a USB steering wheel that the game already understands. No driver,
 * no serial bridge: the board enumerates as a HID gamepad and Godot sees it as
 * one.
 *
 * Wiring (Pro Micro, 5V logic - use 10k linear pots, not audio-taper):
 *
 *   steering pot   wiper -> A0     ends -> 5V and GND
 *   throttle pot   wiper -> A1     ends -> 5V and GND
 *   brake pot      wiper -> A2     ends -> 5V and GND
 *
 *   handbrake button -> pin 4  and GND   (B)
 *   boost button     -> pin 5  and GND   (X)
 *   reset button     -> pin 6  and GND   (Y)
 *   pause button     -> pin 7  and GND   (Start)
 *   shift down       -> pin 8  and GND   (LB)
 *   shift up         -> pin 9  and GND   (RB)
 *
 * Buttons use the internal pull-ups, so no resistors are needed - one leg to the
 * pin, the other to GND.
 *
 * Library: "Joystick" by Matthew Heironimus (Library Manager -> search
 * "Joystick"), which builds the HID descriptor for us.
 *
 * Every axis is included in the descriptor and left at centre except the three
 * we drive, so the axis *numbers* the game sees are always the standard ones
 * (X = 0 steering, Z = 2 throttle, Rx = 3 brake) no matter how your pots are
 * wired. If your wheel is something else entirely, open CONTROLS & WHEEL in the
 * game and press "learn" beside the axis you want to bind.
 */

#include <Joystick.h>

// X = steering, Z = throttle, Rx = brake. Everything else is present in the
// descriptor but never moved, so it can never be mistaken for input.
Joystick_ Joystick(JOYSTICK_DEFAULT_REPORT_ID, JOYSTICK_TYPE_GAMEPAD,
                   8, 0,         // 8 buttons, no hat switch
                   true, true, true, true, true, true, true, true,
                   false, false, false);

const uint8_t PIN_STEER = A0;
const uint8_t PIN_THROTTLE = A1;
const uint8_t PIN_BRAKE = A2;
const uint8_t BUTTON_PINS[6] = {4, 5, 6, 7, 8, 9};
// Button indices the game expects: B handbrake, X boost, Y reset, Start pause,
// LB and RB for manual gears.
const uint8_t BUTTON_INDICES[6] = {1, 2, 3, 6, 9, 10};

// Pot readings are noisy; a light smoothing pass stops the car twitching when
// the wheel is held still.
const uint8_t SMOOTHING = 4;
int smoothed[3] = {512, 512, 512};

// If your steering pot is wired the other way round, flip this instead of
// rewiring: it mirrors only the steering axis.
const bool INVERT_STEERING = false;
// Readings inside this window count as centre, so a worn pot does not steer.
const int CENTRE_DEADZONE = 12;

int readPot(uint8_t pin, uint8_t slot) {
  int raw = analogRead(pin);
  smoothed[slot] = ((smoothed[slot] * (SMOOTHING - 1)) + raw) / SMOOTHING;
  return smoothed[slot];
}

void setup() {
  for (uint8_t i = 0; i < 6; i++) {
    pinMode(BUTTON_PINS[i], INPUT_PULLUP);
  }

  Joystick.setXAxisRange(0, 1023);
  Joystick.setZAxisRange(0, 1023);
  Joystick.setRxAxisRange(0, 1023);
  Joystick.begin();

  // Park every unused axis dead centre so it reads as "no input at all".
  Joystick.y(512);
  Joystick.ry(512);
  Joystick.rz(512);
  Joystick.throttle(512);
  Joystick.rudder(512);
  Joystick.z(512);
  Joystick.rx(512);
  Joystick.x(512);
}

void loop() {
  int steer = readPot(PIN_STEER, 0);
  if (abs(steer - 512) < CENTRE_DEADZONE) {
    steer = 512;
  }
  if (INVERT_STEERING) {
    steer = 1023 - steer;
  }
  Joystick.x(steer);

  Joystick.z(readPot(PIN_THROTTLE, 1));
  Joystick.rx(readPot(PIN_BRAKE, 2));

  for (uint8_t i = 0; i < 6; i++) {
    // Pull-up: a pressed button reads LOW.
    Joystick.setButton(BUTTON_INDICES[i], digitalRead(BUTTON_PINS[i]) == LOW);
  }

  // ~200 Hz: fast enough that the wheel never feels laggy.
  delay(5);
}
