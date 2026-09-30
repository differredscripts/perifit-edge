# Arduino Uno + three-motor shield setup

This folder is the separate hardware project for Perifit Edge v1.0.0. The Mac
app computes pressure feedback and patterns; the Arduino only applies bounded
M1/M2/M3 PWM commands and enforces its own fail-off protocol. Firmware does not
calculate the pressure score or communicate directly with XToys.

## Required hardware and software

- Arduino Uno REV3 / ATmega328P (or a compatible clone with the correct bootloader).
- Adafruit Motor Shield **v1-compatible L293D shield**, such as an electrically
  compatible clone. This firmware uses `AFMotor.h`; it is **not** the I2C/PCA9685
  Motor Shield v2 driver. Do not flash it for a different board/shield unchanged.
- Up to three compatible low-voltage brushed DC vibration motors, connected to
  M1, M2 and M3. M4 is unused. The firmware is not an AC, servo or stepper driver.
- An external motor supply matched to the motors and shield current/thermal
  limits; USB data connection to the Mac. Select wire, fuse and supply ratings
  from the actual components, not from the app’s PWM number.
- Python 3, Arduino CLI, Arduino AVR core and the Adafruit Motor Shield v1 library.

Before wiring, flashing or testing, disconnect motor power. Remove the shield’s
PWR/VIN jumper for a separately powered motor supply, and follow the shield’s
polarity and common-ground wiring instructions. Do not connect an external
motor supply to the Arduino 5V pin. Keep a physical motor-power disconnect
accessible. PWM is not current limiting or thermal protection.

See the [official v1 shield guide](https://learn.adafruit.com/adafruit-motor-shield)
and [AFMotor library](https://github.com/adafruit/Adafruit-Motor-Shield-library).
Check your clone’s labels and circuit; appearance alone is not compatibility.

## Install the build dependencies

The reproducible setup used for these sources is Arduino AVR **1.8.6** and
Adafruit Motor Shield library **1.0.1**. Arduino CLI 1.5.1 was used for validation.
Install Arduino CLI using your platform’s normal installer, then:

```sh
arduino-cli core update-index
arduino-cli core install arduino:avr@1.8.6
arduino-cli lib install 'Adafruit Motor Shield library@1.0.1'
```

No library, compiler installation, firmware image or local Arduino configuration
is included in the source release. The app and firmware can be built separately.

## Build without a board

From the repository root:

```sh
python3 Firmware/flash_arduino.py --self-check
python3 Firmware/flash_arduino.py --build-only
```

This creates local build output in ignored `dist/uno-m3/`; `--build-only` does not
upload. The sketch is `PerifitEdgeUno/PerifitEdgeUno.ino` and the board target is
`arduino:avr:uno`.

Review `PerifitEdgeUno/Config.h` before powering motors. Its `PE1_MAX_M1`,
`PE1_MAX_M2` and `PE1_MAX_M3` values are protocol ceilings (default 255), **not**
validated power/current ratings for your motor assembly. Lower them for a more
restricted build. This sketch requires all three ceilings to be nonzero, or all
three to be zero for a locked-output build. Test-only builds require explicit
nonzero ceilings, allow bounded TEST pulses, and reject normal ARM/SET operations.

## Flash when the board is connected

1. Stop and quit Perifit Edge and any serial monitor. Disconnect motor power and
   verify the PWR jumper arrangement. Leave only the required USB connection.
2. Connect exactly one Uno, then run:

   ```sh
   python3 Firmware/flash_arduino.py --wait 300
   ```

3. The script builds, waits up to five minutes for a matching Uno USB serial port,
   checks that the port is not in use, uploads and verifies the image. Multiple
   boards are rejected; they are never selected arbitrarily.
4. For a clone not automatically identified as an Uno, inspect `arduino-cli board
   list`, then select its actual local serial port explicitly:

   ```sh
   python3 Firmware/flash_arduino.py --port /dev/cu.YOUR_UNO --wait 30
   ```

   Replace the placeholder with your board’s port. Do not copy a port from another
   person’s machine. Explicit selection still rejects network ports or boards
   identified as a different model.
5. Keep motor power disconnected while checking the USB handshake and Stop.
   Only then connect a suitable motor supply and test one motor at a low target.

Flashing replaces the connected board’s firmware. The source release does not
perform this automatically, and no physical board is flashed by the host checks.

## Connect the app

Build the Finder app using the root README. Under **USB · M1/M2/M3**, select your
board and connect PE1 firmware. The board must report all outputs zero before
arming. Confirm that the motors, wiring and supply match the setup, choose low
motor targets, connect/calibrate Perifit, then explicitly Start / Arm.

Connecting or receiving a HELLO never arms the board. Every ARM starts at zero.
Optional discovery uses separate 250 ms TEST pulses; discovery is not a
substitute for checking motor electrical ratings. A USB port change or different
reported limits can invalidate saved motor calibration.

## Protocol and implementation

- USB serial: **115200 baud, 8N1**; bounded ASCII PE1 messages with per-connection
  nonce, increasing sequence number and acknowledgements.
- HELLO discovers two- or three-channel limits; ARM begins at zero; SET applies
  independent PWM; STOP releases all channels; TEST250 is a bounded test pulse.
- Missing valid control traffic for one second stops/disarms the board. Invalid
  traffic, serial output stalls and other protocol faults also fail off.
- The ATmega hardware watchdog resets a stalled loop; startup releases motors.
- M1 uses D11/OC2A, M2 D3/OC2B, M3 D6/OC0A. M3 must not change Timer0’s prescaler,
  because `millis()` and the watchdog timing depend on it. Zero PWM explicitly
  detaches hardware PWM and drives enable low; nonzero output reattaches it.
- See [`../USB_PROTOCOL.md`](../USB_PROTOCOL.md) for commands, ordering, states
  and timings. `LoopHealth.h` independently checks timebase/transmit progress.

## Checks and remaining acceptance work

```sh
# Host-only parser, state-machine and clock/watchdog tests; no device required.
python3 Firmware/check_board.py

# Explicit real-board test, with motor power DISCONNECTED; replace the port.
sh Firmware/check_mac.sh /dev/cu.YOUR_UNO --full-range-check
```

Before relying on your assembly, verify M1/M2/M3 mapping, OFF at boot/connect,
independent target changes, Stop, loss of USB/control traffic, and pressure loss.
Verify temperature and supply behavior under your intended combined load using
appropriate instruments. Software emulator/transport checks cannot establish
safe powered motor current, heating, mechanical compatibility or physiological
outcomes. Revalidate after changing the supply, wiring, motors or shield.

`check_board.py --port ...` and the diagnostic watchdog/timebase options are for
explicit hardware development; read `--help` and use locked diagnostic firmware
as documented in the source. They are not part of normal flashing.

## Files

- `PerifitEdgeUno/`: sketch, PWM limits, parser and watchdog implementation.
- `flash_arduino.py`: conservative Uno discovery, local build, upload and verify.
- `Checks.cpp`, `check_board.py`: portable host checks and explicit board checks.
- `MacProbe.swift`, `check_mac.sh`: production Mac transport acceptance probe.

No personal port, device ID, private diagnostic log or precompiled firmware is
required or shipped. The project MIT license and dependency attribution are in
the repository root; AFMotor is installed as a separate dependency.
