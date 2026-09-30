#!/usr/bin/env python3
"""Offline PWM/score forecasting. Never connects to or changes the app or motors.

uv venv .venv-ml --python 3.14
uv pip install --python .venv-ml/bin/python -r Tools/requirements-ml.txt
.venv-ml/bin/python Tools/train_pwm.py --self-check
.venv-ml/bin/python Tools/train_pwm.py --output dist/pwm-ml-3s
"""
import argparse
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import sys
from datetime import datetime, timezone

# Keep training from competing with the live controller for all CPU cores.
os.environ.setdefault("OMP_NUM_THREADS", "2")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "2")
import joblib
import numpy as np
import sklearn
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.linear_model import Ridge
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from threadpoolctl import threadpool_limits

LOOKBACK = 10.0
MAX_GAP = 0.7


def extract(record, horizon):
    """Past-only features, one decision/second; exclude broken control windows."""
    frames = record.get("frames", [])
    if not frames:
        return []
    t = np.array([f["time"] for f in frames], float)
    if not np.isfinite(t).all() or (np.diff(t) < 0).any():
        return []
    signals = {name: np.array(values, float) for name, values in {
        "score": [f["active"]["score"] for f in frames],
        "pressure": [f["pressure"] for f in frames],
        "tip": [f["tip"] for f in frames],
        "pwm1": [(f.get("vibrationReported") or {}).get("one", np.nan) for f in frames],
        "pwm2": [(f.get("vibrationReported") or {}).get("two", np.nan) for f in frames],
        "pwm3": [(f.get("vibrationReported") or {}).get("three", 0) for f in frames],
    }.items()}
    age = np.array([f.get("pressureAge", np.nan) for f in frames], float)
    valid = np.array([f.get("armed", False) for f in frames]) & (age >= 0) & (age <= 0.5)
    for name, values in signals.items():
        valid &= np.isfinite(values) & (values >= 0)
        if name.startswith("pwm"):
            valid &= values <= 255
    valid[1:] &= (np.diff(t) > 0) & (np.diff(t) <= MAX_GAP)
    for gap in record.get("recordingGaps") or []:
        end = gap.get("end") if gap.get("end") is not None else t[-1]
        valid &= ~((t >= gap["start"]) & (t <= end))
    bad = np.r_[0, np.cumsum(~valid)]
    rows = []
    settings = dict(record["settings"])
    changes = sorted(record.get("thresholdChanges") or [], key=lambda change: change["time"])
    change_index = 0
    for at in np.arange(math.ceil(t[0] + LOOKBACK), t[-1] - horizon, 1.0):
        i = np.searchsorted(t, at, side="right") - 1
        lo = max(0, np.searchsorted(t, t[i] - LOOKBACK, side="right") - 1)
        j = np.searchsorted(t, t[i] + horizon)
        if j >= len(t) or at - t[i] > 0.35 or t[j] - t[i] - horizon > 0.35:
            continue
        if bad[j + 1] != bad[lo] or t[i] - t[lo] < LOOKBACK:
            continue
        while change_index < len(changes) and changes[change_index]["time"] <= t[i]:
            change = changes[change_index]
            settings["edgeTarget"] = change["edge"]; settings["sensitivity"] = change["cutoff"]
            change_index += 1
        active = frames[i]["active"]
        features = {"control_phase": active["controlPhase"], "detection_phase": active["detectionPhase"],
                    "sustained": active["sustained"], "peaks": active["peaks"],
                    "edge_reference": settings.get("edgeTarget", settings["sensitivity"] * 0.6),
                    "cutoff": settings["sensitivity"], "sample_age": age[i]}
        for name, values in signals.items():
            features[name] = values[i]
            for seconds in (1, 3, 10):
                grid = np.linspace(t[i] - seconds, t[i], seconds * 5 + 1)
                # Both interpolation endpoints are from the already-observed past.
                history = np.interp(grid, t[lo:i + 1], values[lo:i + 1])
                features[f"{name}_mean_{seconds}s"] = history.mean()
                features[f"{name}_std_{seconds}s"] = history.std()
                features[f"{name}_change_{seconds}s"] = history[-1] - history[0]
        rows.append({"session": record["id"], "date": record["date"], "time": t[i],
                     "target_time": t[j], "target": signals["score"][j], "features": features})
    return rows


def split_sessions(rows):
    ordered = sorted({(r["date"], r["session"]) for r in rows})
    if len(ordered) < 10:
        raise ValueError("At least 10 usable sessions are needed for chronological validation and test sets.")
    a, b = int(len(ordered) * 0.6), int(len(ordered) * 0.8)
    groups = [set(s for _, s in part) for part in (ordered[:a], ordered[a:b], ordered[b:])]
    assert not any(groups[i] & groups[j] for i in range(3) for j in range(i))
    return [np.array([r["session"] in group for r in rows]) for group in groups], groups


def metrics(y, prediction, current, low, high, sessions):
    errors = np.abs(y - prediction)
    near = (current >= low * 0.5) & (current <= high * 1.5)
    upper = y > high
    return {"rows": len(y), "mae": float(errors.mean()),
            "rmse": float(np.sqrt(mean_squared_error(y, prediction))),
            "r2": float(r2_score(y, prediction)),
            "session_mean_mae": float(np.mean([errors[sessions == s].mean() for s in np.unique(sessions)])),
            "near_band_rows": int(near.sum()), "near_band_mae": float(errors[near].mean()) if near.any() else None,
            "above_band_rows": int(upper.sum()),
            "above_band_recall": float((prediction[upper] > high).mean()) if upper.any() else None,
            "band_accuracy": float(np.mean(((y >= low) & (y <= high)) == ((prediction >= low) & (prediction <= high))))}


def estimator(name):
    if name == "Linear state + PWM":
        return make_pipeline(StandardScaler(), Ridge(alpha=100.0))
    return HistGradientBoostingRegressor(max_iter=200, max_leaf_nodes=7, min_samples_leaf=30,
                                        learning_rate=0.05, l2_regularization=10,
                                        early_stopping=False, random_state=17)


def self_check():
    record = {"id": "synthetic", "date": 0, "settings": {"sensitivity": 600}, "frames": []}
    for i in range(600):
        record["frames"].append({"time": i / 10, "armed": True, "pressureAge": 0.01,
            "pressure": i, "tip": 700, "vibrationReported": {"one": 100, "two": 150},
            "active": {"score": i * 2, "controlPhase": 0, "detectionPhase": 0, "sustained": 0, "peaks": 0}})
    first = extract(record, 3)[0]
    assert first["time"] == 10 and first["target_time"] == 13 and first["target"] == 260
    modified = json.loads(json.dumps(record))
    for frame in modified["frames"]:
        if frame["time"] > first["time"]:
            frame["active"]["score"] += 1000
            frame["vibrationReported"]["one"] = 0
    changed = extract(modified, 3)[0]
    assert first["features"] == changed["features"] and first["target"] != changed["target"], "Future leakage"
    record["thresholdChanges"] = [{"time": 12.5, "edge": 200, "cutoff": 500}]
    changed_rows = extract(record, 3)
    assert changed_rows[0]["features"]["cutoff"] == 600
    assert next(r for r in changed_rows if r["time"] == 13)["features"]["cutoff"] == 500, "Live threshold metadata ignored"
    record["frames"][150]["pressureAge"] = 3
    assert all(not (r["time"] - LOOKBACK <= 15 <= r["target_time"]) for r in extract(record, 3)), "Stale-window leakage"
    rows = [{"session": str(i), "date": i} for i in range(15) for _ in range(2)]
    masks, groups = split_sessions(rows)
    assert np.all(np.sum(masks, axis=0) == 1)
    assert max(map(int, groups[0])) < min(map(int, groups[1])) < min(map(int, groups[2]))
    print("PASS past-only features, horizon alignment, stale-window rejection and whole-session chronological splits")


def run(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    snapshot = output / "sessions"
    snapshot.mkdir(mode=0o700)
    all_rows, manifest, excluded, raw_seconds, labels = [], [], {}, 0.0, {}
    for path in sorted(args.data.glob("session-*.json")):
        content = path.read_bytes()
        record = json.loads(content)
        reason = ("simulated" if record.get("simulated") is not False else
                  "not_arduino" if record.get("outputTransport") != "arduino" else
                  "incomplete" if not record.get("complete") else None)
        if reason:
            excluded[reason] = excluded.get(reason, 0) + 1
            continue
        (snapshot / path.name).write_bytes(content)
        os.chmod(snapshot / path.name, 0o600)
        frames = record.get("frames", [])
        raw_seconds += frames[-1]["time"] - frames[0]["time"] if frames else 0
        for mark in record.get("feedback", []):
            if not mark.get("removed", False):
                labels[mark["kind"]] = labels.get(mark["kind"], 0) + 1
        rows = extract(record, args.horizon)
        usable = len(rows) >= 20
        manifest.append({"file": path.name, "sha256": hashlib.sha256(content).hexdigest(),
                         "id": record["id"], "date": record["date"], "raw_frames": len(frames),
                         "valid_windows": len(rows), "included": usable, "app_eligible": record.get("eligible")})
        if usable:
            all_rows.extend(rows)
        else:
            excluded["fewer_than_20_valid_windows"] = excluded.get("fewer_than_20_valid_windows", 0) + 1
    rows = sorted(all_rows, key=lambda r: (r["date"], r["session"], r["time"]))
    masks, groups = split_sessions(rows)
    train, validation, test = masks
    names = list(rows[0]["features"])
    X = np.array([[r["features"][name] for name in names] for r in rows], float)
    y = np.array([r["target"] for r in rows])
    current = X[:, names.index("score")]
    sessions = np.array([r["session"] for r in rows])
    pwm = np.array([name.startswith("pwm") for name in names])
    columns = {"PWM only": pwm, "State history": ~pwm, "State + PWM": np.ones(len(names), bool),
               "Linear state + PWM": np.ones(len(names), bool)}
    models, predictions, validation_metrics, test_metrics = {}, {"Persistence": current[test]}, {}, {}
    with threadpool_limits(limits=2):
        for name, features in columns.items():
            model = estimator(name)
            target = y if name == "PWM only" else y - current
            offset = np.zeros(len(y)) if name == "PWM only" else current
            model.fit(X[train][:, features], target[train])
            val = np.clip(model.predict(X[validation][:, features]) + offset[validation], 0, 65535)
            validation_metrics[name] = metrics(y[validation], val, current[validation], args.low, args.high, sessions[validation])
            # Choices use validation only; final test sessions never enter a fit.
            model.fit(X[train | validation][:, features], target[train | validation])
            predictions[name] = np.clip(model.predict(X[test][:, features]) + offset[test], 0, 65535)
            models[name] = model
    selected = min(("State + PWM", "Linear state + PWM"), key=lambda name: validation_metrics[name]["mae"])
    for name, predicted in predictions.items():
        test_metrics[name] = metrics(y[test], predicted, current[test], args.low, args.high, sessions[test])
    selected_error = np.abs(predictions[selected] - y[test])
    state_error = np.abs(predictions["State history"] - y[test])
    by_session = []
    for session in sorted(groups[2]):
        mask = sessions[test] == session
        by_session.append({"session": session, "rows": int(mask.sum()),
                           "state_mae": float(state_error[mask].mean()), "pwm_mae": float(selected_error[mask].mean())})
    differences = np.array([(r["state_mae"] - r["pwm_mae"]) * r["rows"] for r in by_session])
    counts = np.array([r["rows"] for r in by_session])
    draws = np.random.default_rng(17).integers(len(counts), size=(2000, len(counts)))
    intervals = np.quantile(differences[draws].sum(axis=1) / counts[draws].sum(axis=1), [0.025, 0.975])
    channel_stats = {}
    for channel in (1, 2, 3):
        values, count = np.unique(X[:, names.index(f"pwm{channel}")], return_counts=True)
        order = np.argsort(count)[-5:][::-1]
        channel_stats[f"M{channel}"] = {"unique_levels": len(values), "min": float(values.min()), "max": float(values.max()),
                                      "most_common": [[float(values[i]), int(count[i])] for i in order]}
    result = {"created_utc": datetime.now(timezone.utc).isoformat(), "sklearn": sklearn.__version__,
              "horizon_seconds": args.horizon, "target_band": [args.low, args.high], "lookback_seconds": LOOKBACK,
              "completed_usb_sessions": len(manifest), "completed_usb_minutes": raw_seconds / 60,
              "usable_sessions": len(set(sessions)), "windows": len(rows), "excluded": excluded, "human_marks": labels,
              "split_sessions": {name: sorted(group) for name, group in zip(("train", "validation", "test"), groups)},
              "split_windows": {name: int(mask.sum()) for name, mask in zip(("train", "validation", "test"), masks)},
              "selected_using_validation": selected, "validation": validation_metrics, "test": test_metrics,
              "pwm_mae_improvement_over_state": float(state_error.mean() - selected_error.mean()),
              "pwm_improvement_session_bootstrap_95ci": intervals.tolist(), "test_sessions": by_session,
              "pwm_levels": channel_stats, "feature_names": names,
              "deployment": "offline_research_only; predictive validation does not identify causal PWM effects"}
    (output / "metrics.json").write_text(json.dumps(result, indent=2))
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2))
    joblib.dump({"models": models, "columns": columns, "feature_names": names, "metadata": result}, output / "models.joblib")
    with (output / "test_predictions.csv").open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["session", "time", "target_time", "score_now", "score_future", *predictions])
        for i, source in enumerate(np.flatnonzero(test)):
            writer.writerow([rows[source]["session"], rows[source]["time"], rows[source]["target_time"], current[source], y[source],
                             *[p[i] for p in predictions.values()]])
    plot_result(output, rows, test, y, predictions, selected, result)
    table = "\n".join(f"| {name} | {value['mae']:.1f} | {value['rmse']:.1f} | "
                      f"{format(value['near_band_mae'], '.1f') if value['near_band_mae'] is not None else 'n/a'} |"
                      for name, value in test_metrics.items())
    report = f"""# PWM-to-score experiment

Target: configured heuristic score **{args.low:g}–{args.high:g}**, forecast **{args.horizon:g} seconds** ahead.
This is the app's score band, not a measured physiological Edge/Orgasm band.

## Data and validation

- {len(manifest)} completed, non-demo Arduino sessions ({raw_seconds / 60:.1f} minutes); {len(set(sessions))} sessions supplied at least 20 clean windows, yielding {len(rows):,} one-second-spaced decisions.
- Whole sessions in date order: {len(groups[0])} train / {len(groups[1])} validation / {len(groups[2])} final test. Models were selected on validation, then refit on train+validation. Final test sessions stayed unseen.
- Features use only the preceding 10 seconds of score, pressure, tip, controller state and acknowledged PWM. No future PWM, future pressure, session IDs or dates are model inputs.
- Windows crossing disarming, missing PWM, pressure older than 0.5 seconds, declared recording gaps or timing gaps over 0.7 seconds are excluded. Incomplete current sessions and simulation output are excluded.
- App `eligible=false` records are retained only where these window checks pass: that flag can reflect a target adjustment or interrupted session, rather than invalid sensor data. Source files and checksums are frozen in this private run directory.
- Recorded motor-session human marks: `{json.dumps(labels, sort_keys=True)}`. These do not establish a personalized physiological range.

## Unseen-session forecast errors

Lower error is better. All errors are heuristic score units. Near-band decisions start at 0.5× the lower bound through 1.5× the upper bound.

| Model | MAE | RMSE | Near-band MAE |
|---|---:|---:|---:|
{table}

The validation-selected PWM model is **{selected}**. Its MAE improvement over state history alone is **{result['pwm_mae_improvement_over_state']:.1f}** points; a whole-session bootstrap 95% interval is **[{intervals[0]:.1f}, {intervals[1]:.1f}]**. Positive means PWM helped. Only {len(groups[2])} independent final-test sessions underpin this interval.

## Control interpretation

This experiment measures prediction under the historical controller, not the effect of choosing different PWM values. That controller changes PWM in response to pressure/score, and future PWM also changes during each forecast window. A fitted model can learn that feedback relationship with the wrong sign for control. No counterfactual PWM optimization or claimed improvement in time-in-band follows from these results.

No live app settings, model, PWM command, saved calibration, cutoff lock or watchdog were changed. A controller trial would require supported PWM response estimates and a separately tested, bounded control rule; the saved model is for offline investigation only.

Files: `metrics.json`, `test_predictions.csv`, `models.joblib`, `validation.png`, `manifest.json`, and the frozen `sessions/` input snapshot. Load only this locally generated model artifact with joblib.

## Reproduce

Python {sys.version.split()[0]}, scikit-learn {sklearn.__version__}, NumPy {np.__version__}. Dependencies: `Tools/requirements-ml.txt`.

```sh
.venv-ml/bin/python Tools/train_pwm.py --self-check
.venv-ml/bin/python Tools/train_pwm.py --data '{snapshot}' --output dist/pwm-ml-rerun --horizon {args.horizon:g} --low {args.low:g} --high {args.high:g}
```

Method references: [scikit-learn data leakage guidance](https://scikit-learn.org/stable/common_pitfalls.html#data-leakage), [time-series and grouped validation](https://scikit-learn.org/stable/modules/cross_validation.html), [gradient-boosted regression](https://scikit-learn.org/stable/modules/generated/sklearn.ensemble.HistGradientBoostingRegressor.html).
"""
    (output / "report.md").write_text(report)
    print(json.dumps({"output": str(output), "selected": selected, "windows": len(rows), "test": test_metrics,
                      "pwm_improvement_ci": intervals.tolist()}, indent=2))


def plot_result(output, rows, test, y, predictions, selected, result):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({"font.size": 10, "axes.spines.top": False, "axes.spines.right": False})
    fig, axes = plt.subplots(3, 1, figsize=(11, 10), layout="constrained")
    test_rows = [r for r, keep in zip(rows, test) if keep]
    session = max(result["test_sessions"], key=lambda r: r["rows"])["session"]
    mask = np.array([r["session"] == session for r in test_rows])
    times = np.array([r["target_time"] for r in test_rows])[mask]
    axes[0].axhspan(*result["target_band"], color="#34a68a", alpha=0.15, label="Configured target band")
    axes[0].plot(times, y[test][mask], color="#202938", label="Recorded future score", lw=1.5)
    axes[0].plot(times, predictions[selected][mask], color="#307ac4", label=selected, lw=1.2)
    axes[0].set(title=f"Longest unseen session · {result['horizon_seconds']:g}-second forecast", xlabel="Session seconds", ylabel="Heuristic score")
    axes[0].legend(loc="upper right", fontsize=8)
    names = list(predictions)
    axes[1].barh(names, [result["test"][n]["mae"] for n in names], color=["#aaa", "#bbb", "#34a68a", "#307ac4", "#6f62a6"])
    axes[1].invert_yaxis()
    axes[1].set(title="All unseen sessions · mean absolute forecast error (lower is better)", xlabel="Heuristic score units")
    comparisons = result["test_sessions"]
    values = [r["state_mae"] - r["pwm_mae"] for r in comparisons]
    axes[2].bar([r["session"][:8] for r in comparisons], values, color=["#34a68a" if v > 0 else "#bc6161" for v in values])
    axes[2].axhline(0, color="#777", lw=0.8)
    axes[2].set(title="Does PWM add value beyond pressure and score history?", xlabel="Unseen session", ylabel="MAE improvement (+ helps)")
    fig.suptitle("Perifit Edge · offline PWM forecasting", fontsize=16)
    fig.savefig(output / "validation.png", dpi=170)
    fig.savefig(output / "validation.svg")
    plt.close(fig)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=Path.home() / "Library/Application Support/PerifitEdge")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--horizon", type=float, default=3.0)
    parser.add_argument("--low", type=float, default=350.0)
    parser.add_argument("--high", type=float, default=570.0)
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    if args.self_check:
        self_check()
    else:
        if not args.output or not (0 < args.horizon <= 60 and 0 <= args.low < args.high <= 65535):
            parser.error("Supply a new --output directory, 0 < horizon <= 60 and 0 <= low < high <= 65535")
        run(args)
