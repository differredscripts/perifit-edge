# Perifit Edge — v1.0.0

**Vibe-coded, and it works.** This is a working macOS pressure-feedback and
three-motor control app, developed iteratively with AI coding assistance. It has
been used with hardware during development and has repeatable native-app,
controller-emulator, firmware and replay checks. It is not a mock-up. That does
not make its physiological predictions, every motor assembly, or every network
integration independently validated.

**v1.0.0 adds opt-in pressure and arousal-score export to XToys.** The release is
source only: no app bundle, installer, firmware binary, personal recording,
trained model, saved settings, device identifier or credential is distributed.

This is an independent project; the heuristic is adapted from
[Maus-Tec’s Edge-o-Matic 3000](https://github.com/MausTec/edge-o-matic-3000).
The score is an engineering heuristic, not a medical measurement or a guarantee
of detecting or preventing an orgasm.

## What it does

- Reads two pressure channels from a user-selected Perifit Bluetooth peripheral.
- Displays raw pressure, conditioned pressure and the Edge-o-Matic heuristic score.
- Controls up to three independently selected motors through an Arduino Uno and
  an L293D/Adafruit Motor Shield **v1-compatible** shield.
- Provides per-motor targets, calibration, native patterns, live target edits,
  threshold locks, cutoff-count limits and optional timed sessions.
- Learns useful patterns with Finder, saves progress and measures rise/fall rates.
- Can run the best learned pattern, or maintain an Edge-to-cutoff band.
- Accepts local XToys vibration commands for M1/M2 and a separate M3 endpoint.
- Exports live pressure/heuristic data to an XToys Private Webhook when explicitly
  enabled. Export is independent of the motor-control connection.
- Also supports simulation and pressure-only recording. No Arduino is needed to compile or try simulation.

## Build locally

Requirements: macOS 14 or later, Swift 6-capable Xcode/Command Line Tools,
Python 3 for check scripts, and a C/C++ compiler for the native checks. The app
uses Apple frameworks and Swift Package Manager; it has no third-party Swift
package dependencies. Tests currently use an Apple-silicon release build.

```sh
git clone https://github.com/differredscripts/perifit-edge.git
cd perifit-edge
sh Tools/build-app.sh 'dist/Perifit Edge Finder.app' --finder
open 'dist/Perifit Edge Finder.app'
```

`--finder` enables the full Finder interface and its separate application-data
namespace. The script compiles locally and ad-hoc signs the bundle; it does not
publish, install globally, flash a board, or start a motor session. `dist/` and
`.build/` are excluded from source releases. No prebuilt app is supplied.

For just the executables:

```sh
swift build -c release --scratch-path .build/finder -Xswiftc -DFINDER_PROTOTYPE
```

The historical build without `--finder` remains supported, with a separate app
identity and data directory. Use the Finder build above for this release’s main
workflow. Quit the old local app before replacing your own compiled bundle.

## First run

1. Start with **Demo → Simulation**, choose a demo signal and run calibration.
   Demo is blocked from driving real devices. Explicit Start / Arm is required;
   launching or reconnecting never automatically arms output.
2. On **Main**, use the graph, input gain, motor controls, pressure thresholds and
   Finder controls. **Config** contains Bluetooth, calibration, sensor/detector
   settings, learning details and the pattern-rate tables.
3. For real pressure, connect the intended Perifit under Config, select a notifying
   pressure characteristic, verify that both channels change plausibly, and save
   protocol verification. Identifiers and calibration are recorded only on your
   computer; the source release contains none.
4. Calibrate while pressure is at its intended resting level. Increase input gain
   to amplify changes, then recalibrate after changing gain. The default packet
   parser expects four bytes: two unsigned, big-endian 16-bit readings. Do not
   assume every Perifit model/firmware uses the same characteristic or encoding.
5. For motor control, complete [the separate Arduino setup](Firmware/README.md)
   first. Connect the board, verify the motor setup and start with low targets.
   Motors not selected in Finder remain off.

## How pressure control works

The input is approximately `max(0, (basePressure - restingBaseline) * gain)`,
saturated to 16 bits. The second raw channel is displayed and checked for loss
of pressure. The C adaptation accumulates qualifying pressure excursions into
an arousal-like score and applies decay; optional averaging and contraction
pattern detectors affect the result. The original upstream numerical traces
are checked by `Tools/check_upstream.py`.

**Edge** is the lower target/reference. **Cutoff** is the upper stop threshold.
In ordinary edging mode, reaching the upper risk threshold, a relevant detector
warning, or the pending-peak guard requests output off. The pending-peak guard
accounts for a rising pressure excursion before the older falling-edge score
update credits it. It does not redefine the displayed historical score.

A second guard runs on the USB worker, independently of UI rendering, with a
150 ms time-based pressure filter. It holds motor output at zero until the
controller acknowledges the pause, fresh pressure is safe and cooldown permits
output. Raw zero/invalid input and loss of the verified Bluetooth connection
stop/disarm output. A pressure gap over 0.5 seconds holds output off; sustained
loss disarms the session.

The USB controller lease expires after 700 ms without fresh controller updates;
ACK timeout is 900 ms. Firmware also has its own one-second command watchdog
and a hardware watchdog. Pressure packets cannot renew the controller lease.
These are fault protections, not a medical or electrical safety certification.

## Finder, limits and modes

Finder tests patterns for normally 10 seconds, compares measured score rise
rates and refines through the selected number of levels. Every third proposal
explores motor ranges within the configured ceilings. Shortened cutoff trials
retain the real measurements, with duration weighting. A plateau of 20 trials
without improvement applies **only at the final level**.

Band-maintenance mode then measures ramp-down response and uses a library of
rising/easing patterns to try to approach the configured cutoff. Smoothed
lookahead queues the next pattern; routine prediction does not interrupt the
current trial. Actual risk guards can stop it. Live observations continue to
validate rates. Libraries are capped at 15 patterns per setup.

- **Best pattern:** learns/resumes first, then repeats the best learned pattern;
  automatic pressure safety cutoffs still apply. No timer or restart-penalty
  cycles are configured in this mode.
- **Start Orgasm mode now:** uses the best learned pattern and disables automatic
  edging cutoffs for that session. It requires an armed session and a measured
  pattern, and is unavailable while a cutoff limit or timer is unfinished,
  whether locked or unlocked. Stop, Too close, pressure-loss/disconnect and
  watchdog protections remain. It does not persist into a new untimed session.
- **Mark orgasm & stop:** records feedback and stops/disarms; it does not activate
  Orgasm mode.
- A cutoff-count limit hands over after its final cooldown. Timed Finder sessions
  start counting down after learning; completion selects the learned pattern
  in Orgasm mode. Without Finder, the existing separate motor preset is used.
- Threshold, training and count locks are separate. A locked timer persists
  across restarts. Quitting an ongoing locked timed session adds five automatic
  cutoff cycles before the saved duration restarts. Press Stop before quitting
  to save a clean interruption. The Stop control remains available.

Unsupported legacy output selections fall back to Simulation; calibration and training remain saved.

Completed trials and training progress survive normal app updates. Changing
sensor identity, gain/profile generation or motor setup can create a different
learning profile; unrelated setups should not share learned responses.

## XToys

See [XToys setup and the v1 telemetry schema](docs/XToys.md).

The existing **XToys pattern control** receives motor commands on loopback only
and keeps the local controller in charge of the Arduino. The new **Export
pressure / arousal to XToys** control sends data over HTTPS to XToys only after
you enter your Private Webhook ID and press Start sharing readings. Export and
Finder can run together. There is no embedded webhook ID or automatic upload.

A separate toy controlled directly by XToys does not inherit the Arduino’s
physical watchdog. Its receiving script must check validity/control flags and
stop on missing updates. Cloud telemetry is not a hard-real-time safety channel.

## Local data and privacy

The Finder app stores preferences, calibration, sessions and learned patterns
under `~/Library/Application Support/PerifitEdgeFinder/`. The historical build
uses `~/Library/Application Support/PerifitEdge/`. The XToys export ID is held in memory only and export starts
disabled on every launch. Debug exports and session JSON can contain sensitive
readings and local paths: do not commit or attach them publicly without review.

No analytics service is included. Optional XToys connections
are explicitly configured by the person running the app. A source release is
made from an allowlist, with a privacy scan, normalized ZIP metadata and no Git
history, build outputs, recorded sessions or local configuration.

## Checks and source packaging

After compiling the Finder release:

```sh
.build/finder/arm64-apple-macosx/release/perifit-checks
python3 Tools/check_upstream.py
python3 Tools/check_app.py --finder
python3 Tools/check_usb.py --finder-only
python3 Tools/check_watchdog.py --finder
python3 Tools/check_xtoys_export.py
python3 Firmware/check_board.py
python3 Firmware/flash_arduino.py --self-check
python3 Tools/source_release.py
```

Native/USB checks use temporary app data and emulated serial devices; they do
not start a session on your physical hardware. Firmware’s `check_board.py`
without `--port` is a host-only check. Real-board tests and flashing are separate,
explicit operations described in [Firmware/README.md](Firmware/README.md).
The XToys export test uses a local mock, not a live account. Follow the XToys
setup guide to verify receipt with your own account before using it in a script.

`source_release.py` produces `dist/perifit-edge-v1.0.0-source.zip` and a clean
source folder. It fails if a source file contains a detected personal path,
credential or forbidden artifact. Review the archive before publishing.

The optional offline scikit-learn experiment is `Tools/train_pwm.py`; its
requirements are in `Tools/requirements-ml.txt`. It is not a dependency of the
app or a trained model included with this release. Supply your own data locally.

## Layout and license

| Path | Contents |
| --- | --- |
| `Sources/PerifitApp/` | macOS UI, Bluetooth, serial worker and XToys connections |
| `Sources/PerifitCore/` | conditioning, controller wrapper, Finder, storage and replay |
| `Sources/EOMCore/` | generated C adaptation of the upstream heuristic |
| `Vendor/EdgeOMatic/` | pinned upstream source and original license |
| `Firmware/` | independent Arduino source, setup and flash/check tools |
| `Tests/`, `Tools/` | repeatable checks, local build and source-release tools |

MIT licensed; retain [LICENSE](LICENSE) and the upstream notices.
[PROVENANCE.md](PROVENANCE.md) describes the pinned dependency and adaptation.
No binaries or personal training data are part of the open-source release.
