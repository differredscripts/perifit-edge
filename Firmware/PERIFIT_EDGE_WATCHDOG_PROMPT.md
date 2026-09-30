# Firmware development checklist

Use [README.md](README.md) for normal setup. When changing the watchdog or
protocol, run the host checks, validate startup OFF and every fault-to-OFF path,
and perform explicit real-board acceptance with motor power disconnected.
Never change Timer0 timing as part of M3 PWM configuration.
