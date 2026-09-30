# Upstream provenance

The controller and event detector derive from Maus-Tec's Edge-o-Matic 3000,
commit `6769e4d64ce790696955223e32b572fbcb4c1e7e`:
https://github.com/MausTec/edge-o-matic-3000/tree/6769e4d64ce790696955223e32b572fbcb4c1e7e

The original reference files and MIT license are in `Vendor/EdgeOMatic`.
`python3 Tools/import_core.py` mechanically extracts the pinned algorithm bodies
into `Sources/EOMCore/EOMCore.c`. The portable context, configuration validation,
and I/O boundary are in `Tools/core_prefix.c` and `Tools/core_suffix.c`.

Intentional changes:

- Global state becomes per-engine state; time and pressure are explicit inputs.
- Firmware I/O and accessory/plugin hooks are removed. The default RampStop
  controller still calculates virtual speed; the host combines its pressure/risk
  permission with independent motor patterns.
- The moving-average buffer is initialized and attached correctly. The original
  initializer allocates memory without setting `*ra`, and leaves its contents and
  counters uninitialized. Its sum is widened from 16 to 32 bits.
- Arousal additions saturate at 65535 instead of wrapping. The detector's peak
  count saturates at 255 instead of wrapping during long unconfirmed episodes.
- Configuration is validated, non-monotonic time disarms, and independent
  engines use a seeded xorshift PRNG so active/shadow comparisons share jitter.
- Live threshold edits change only the validated sensitivity configuration in the C
  wrapper and the Swift Edge reference. They preserve accumulated engine state,
  and timestamped edits are applied during session replay.
- The current Swift control policy adds an upper-risk guard around the original
  engine: the upper score threshold, early rhythmic state, or detected event
  requests OFF even during restart holdoff. A quiet cooldown below the separate
  Edge reference is required before resuming. The original C algorithms remain
  available unchanged for comparison and replay of earlier policy recordings.
- Edge is now a target-zone report with no power action. Too close takes the
  cooldown path without fabricating pressure or detector events. Human Orgasm
  disarms. Old edge-cutoff labels are isolated from current-policy learning.

This project is not affiliated with Perifit or Maus-Tec. The application does not
claim physiological validation of either the upstream heuristics or its personal
feedback agreement measures.

USB vibration output uses the original RampStop increment through the exported
`eom_ramp_increment()` helper. Each channel runs its own envelope with its own
start, target, and timing; the pressure/risk controller supplies shared permission.
The stepped-ramp and constant-target modes are small new host-side policies.
The pinned upstream `PatternController.increment()` is explicitly unfinished and
returns zero, so this project does not claim to have ported a working StepPattern.
The additional upstream vibration-mode sources are retained as references.
