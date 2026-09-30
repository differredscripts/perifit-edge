import SwiftUI
import PerifitCore

struct FinderControls: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        GroupBox("Pattern Finder") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Use Finder for this session", isOn: $model.finderEnabled)
                    .disabled(!model.canEditFinderSetup)
                Picker("After learning", selection: Binding(get: { model.finderBestPatternOnly }, set: model.setFinderBestPatternOnly)) {
                    Text("Maintain Edge–cutoff band").tag(false)
                    Text("Best pattern · no edging").tag(true)
                }.disabled(!model.canChangeFinderMode || !model.finderEnabled)
                HStack {
                    ForEach(0..<3, id: \.self) { index in
                        Toggle("M\(index + 1)", isOn: Binding(
                            get: { model.finderMotors.contains(index) },
                            set: { if $0 { model.finderMotors.insert(index) } else { model.finderMotors.remove(index) } }))
                    }
                }.disabled(!model.canEditFinderSetup || !model.finderEnabled)
                Stepper("Refinement levels: \(model.finderTargetLevel)", value: $model.finderTargetLevel, in: 1...20)
                    .disabled(!model.canEditFinderSetup || !model.finderEnabled)
                Stepper("Easing strength: \(Int(model.finderEasingPercent))%", value: $model.finderEasingPercent, in: 0...50, step: 5)
                    .disabled(!model.canEditFinderSetup || !model.finderEnabled)
                if model.finderTrainingLocked {
                    Label("Training locked", systemImage: "lock.fill")
                    Button("Unlock training") { model.unlockFinderSetup() }.disabled(!model.canUnlockFinderSetup)
                } else {
                    Button("Lock training setup") { model.lockFinderSetup() }.disabled(!model.finderEnabled || !model.canEditFinderSetup)
                }
                Text("Set selected motors’ target ceilings below, then use Start / Arm. Other motors stay OFF during Finder.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.hasSavedFinderProgress && !model.finderRunning {
                    Text("Start resumes saved training for this setup. Only an unfinished trial restarts.").font(.caption).foregroundStyle(.secondary)
                    Button("Reset training progress") { model.resetFinderProgress() }.disabled(!model.canEditFinderSetup)
                }
                Text(model.finderStatus).font(.caption).monospacedDigit()
                Button(model.orgasmMode ? "Orgasm mode active" : "Start Orgasm mode now") { model.startOrgasmMode() }
                    .disabled(!model.canStartOrgasmMode)
                if let reason = model.orgasmModeBlockedReason, !model.orgasmMode {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Text("Uses the best learned pattern without automatic edging cutoffs. Stop, Too close, pressure loss and disconnect protections stay active.")
                    .font(.caption).foregroundStyle(.secondary)
                if let forecast = model.finderForecast { Text(forecast).font(.caption).monospacedDigit() }
                if let reason = model.finderInterruption { Text(reason).font(.caption).foregroundStyle(.secondary) }
                if model.finderSearching {
                    Button(model.finderBestPatternOnly ? "End learning & run best pattern" : "End learning & start session") { model.endFinderLearning() }
                        .disabled(!model.canEndFinderLearning)
                    Text(model.canEndFinderLearning ? (model.finderBestPatternOnly ? "Runs the best measured pattern continuously, with safety stops active." : "Starts the best pattern’s fall-rate test and any configured session timer now.") : "Available after one completed trial, or when a saved pattern is available.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.finderRunning {
                    Button("Stop Finder and session") { model.stop() }
                }
                if !model.orgasmMode {
                Text(model.finderBestPatternOnly ? "Learns or resumes saved training, then runs the best pattern until Stop. No edging routine, session timer or restart penalty cycles. Pressure safety remains active." : "Every third proposal explores low, medium and high motor ranges within your ceilings; other trials refine the best pattern. Training progress is saved. Automatic training ends after 20 trials without improvement on the final level, then measures ramp-down for 10 seconds before starting the timer. End learning starts the fall-rate test and timer immediately.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Prediction has extra smoothing and only queues the next pattern. It does not interrupt the current trial. Actual controller cutoffs and safety stops still act immediately; cutoff-ended measurements are retained. Rates keep updating during the session.")
                    .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(5)
        }
    }
}

struct FinderResults: View {
    @ObservedObject var model: SessionModel
    private func pattern(_ result: FinderResult) -> String {
        result.settings.channels.enumerated().filter { $0.element.target > 0 }.map { index, channel in
            let p = channel.effectivePattern
            return String(format: "M%d %@ · cap %.0f%% · %.0f–%.0f%% · %.1f/%.1fs", index + 1,
                          channel.mode == .wave ? (p.curve == .sine ? "sine" : "ramp") : "pulse",
                          channel.target, p.minimum, p.maximum, p.riseSeconds, p.fallSeconds)
        }.joined(separator: "\n")
    }
    var body: some View {
        GroupBox("Finder pattern library · this setup") {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.finderStatus).font(.caption)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Pattern"); Text("Settings"); Text("↑ / s"); Text("↓ / s"); Text("Live updates")
                    }.font(.caption.bold())
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(model.finderResults.enumerated()), id: \.element.id) { index, result in
                        GridRow {
                            Text("\(index + 1)\(result.fallback == true ? "*" : "")\(result.cutoffLimited == true || result.descent?.cutoffLimited == true ? "†" : "")")
                            Text(pattern(result)).font(.caption)
                            Text(String(format: "%+.2f", result.riseRate)).monospacedDigit()
                                .help(String(format: "Original observation: %+.2f/s over %.2fs. Short cutoff trials are weighted by their measured duration for comparison.", result.rate, result.seconds))
                            Text(result.fallRate.map { String(format: "%+.2f", $0) } ?? "—").monospacedDigit()
                            Text("\(result.validationCount ?? 0)").monospacedDigit()
                        }.font(.caption).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.finderResults.isEmpty { Text("No pattern found yet.").foregroundStyle(.secondary) }
                if model.finderResults.contains(where: { $0.fallback == true }) {
                    Text("* Best available trial after training timed out; a score increase was not demonstrated.").font(.caption).foregroundStyle(.secondary)
                }
                if model.finderResults.contains(where: { $0.cutoffLimited == true || $0.descent?.cutoffLimited == true }) {
                    Text("† Includes a shorter cutoff measurement, weighted to a 10-second comparison window. Trials shorter than 1 second are saved but cannot advance a training level.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Rates are score points/second. Trials normally last 10 seconds; actual cutoffs retain the shorter observation. Downward response is measured after the final-level plateau or End learning. Maintenance validates rates over 10 seconds to include pressure peaks and decay; + in the down column means the score still rose.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Patterns and live rate updates are saved for the same sensor, calibration, controller settings and motor setup. Initial trials are exploratory; validation continues during maintenance. Demo scores do not respond to motors. Prediction cannot guarantee no overshoot; the hard cutoff remains the fallback.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(5)
        }
    }
}
