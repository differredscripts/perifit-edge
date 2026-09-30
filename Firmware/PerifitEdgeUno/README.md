# Perifit Edge Uno sketch

Start with [the Arduino setup guide](../README.md) for hardware requirements,
build dependencies, motor-power precautions, flashing and acceptance checks.

`Config.h` defines per-channel PWM ceilings. `PE1.h` implements the bounded
three-channel protocol; `LoopHealth.h` checks loop/timebase health. The sketch
binds those checks to AFMotor and the AVR watchdog. The full wire protocol is
in [USB_PROTOCOL.md](../../USB_PROTOCOL.md).
