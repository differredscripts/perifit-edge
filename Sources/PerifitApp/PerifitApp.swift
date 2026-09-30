import SwiftUI
import AppKit
import Charts
import PerifitCore

private let appTitle = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Perifit Edge"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: SessionModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

#if !PERIFIT_SMOKE_CHECK
@main
struct PerifitEdgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: SessionModel
    init() {
        #if FINDER_PROTOTYPE
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PerifitEdgeFinder", isDirectory: true)
        let restored = SessionModel(dataDirectory: directory)
        #else
        let restored = SessionModel()
        #endif
        if CommandLine.arguments.contains("--pressure-only") {
            restored.selectInput(demo: false); restored.selectOutput(.simulation)
        }
        _model = StateObject(wrappedValue: restored)
    }
    var body: some Scene {
        WindowGroup(appTitle) {
            MainView(model: model)
                .onAppear {
                    delegate.model = model
                    if !model.useDemo && !model.bluetooth.hasStarted { model.bluetooth.scan() }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .frame(minWidth: 1020, minHeight: 760)
        }
        .defaultSize(width: 1180, height: 900)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Open Local Data Folder") { model.revealData() }
            }
            CommandMenu("Session") {
                Button("Stop and Disarm") { model.stop() }.keyboardShortcut(.escape, modifiers: [])
                Button("Getting Closer") { model.label(.closer) }.keyboardShortcut("1", modifiers: .command)
                Button("Edge") { model.label(.edge) }.keyboardShortcut("2", modifiers: .command)
                Button("Too Close — Power OFF") { model.label(.tooClose) }.keyboardShortcut("4", modifiers: .command)
                Button("Mark orgasm & stop") { model.label(.orgasm) }.keyboardShortcut("3", modifiers: .command)
            }
        }
    }
}

#endif

struct MainView: View {
    enum WorkspaceTab: Hashable { case main, config }
    @ObservedObject var model: SessionModel
    @State private var showDelete = false
    @State private var automaticCutoffDraft = 5
    @State private var selectedTab = WorkspaceTab.main
    @State private var rawChannels = true
    @State private var plotSeconds = 60.0
    @State private var editingOrgasm = false
    @State private var deviceID: UUID?
    @State private var characteristicChoice = ""
    @State private var checkedChannels = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text(appTitle).font(.title2.bold())
                    inputOutputControls
                }
                Spacer()
            Button(model.isArmed ? (model.recordingOnly ? "Recording" : "Armed") : (model.isStarting ? "Starting…" : (model.recordingOnly ? "Start recording" : "Start / Arm"))) { model.start() }
                .buttonStyle(.borderedProminent).tint(.teal).controlSize(.large).disabled(!model.canStart)
                .help(model.startBlockedReason ?? "Start a session to record pressure and feedback.")
                Button("Stop") { model.stop() }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                    .accessibilityHint("Stop all motor outputs and disarm. Escape is the keyboard shortcut.")
            }.padding(20)
            Divider()
            if !model.isArmed && !model.isStarting, let reason = model.startBlockedReason {
                Label("Cannot start: \(reason)", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(.orange.opacity(0.08))
            }
            if let fault = model.fault {
                Label(fault, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 20)
            }
            if let error = model.storageError {
                Text("Local storage: \(error)").foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 20)
            }
            Picker("Workspace", selection: $selectedTab) {
                Text("Main").tag(WorkspaceTab.main)
                Text("Config").tag(WorkspaceTab.config)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 250).padding(.vertical, 12)
            if selectedTab == .main { mainWorkspace } else { configWorkspace }

            Divider()
            HStack {
                if model.learningBusy { ProgressView().controlSize(.small) }
                Text(model.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
            }.padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Delete local learning records and restore the manual baseline?", isPresented: $showDelete) {
            Button("Delete Learning History", role: .destructive) { model.deleteHistory() }
        }
    }
    private var mainWorkspace: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FinderControls(model: model)
                    XToysExportControls(exporter: model.xtoysExport)
                    if !model.recordingOnly { VibrationPanel(model: model, usb: model.usb, editingOrgasm: $editingOrgasm) }
                    else { Text("Pressure recording only. Choose a device output in Config to use the vibrators.").foregroundStyle(.secondary) }
                }.padding(18)
            }.frame(minWidth: 320, idealWidth: 350, maxWidth: 410)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                    metric(model.recordingOnly ? "Closest learned mark" : "Estimated zone", model.recordingOnly ? (model.predictedMark?.title ?? "Learning") : model.estimatedZone)
                    metric(model.recordingOnly ? "Session" : "Requested", model.recordingOnly ? (model.isArmed ? "Recording" : "Idle") : (model.requestedPower ? "ON" : "OFF"))
                    metric(model.recordingOnly ? "Device output" : (model.useUSB ? "Board outputs" : "Reported power"), model.recordingOnly ? "None" : (model.reportedPower.map { $0 ? "ON" : "OFF" } ?? "Unknown"))
                        metric("Heuristic score", "\(model.snapshot.score)")
                    }
                    LivePlot(model: model, rawChannels: $rawChannels, seconds: $plotSeconds)
                    sensitivityControls
                    PressureThresholdPanel(model: model)
                    cutoffCountControls
                    feedbackControls
                }.padding(18)
            }.frame(minWidth: 620)
        }
    }
    private var configWorkspace: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionControls
                    BluetoothPanel(model: model, bluetooth: model.bluetooth, deviceID: $deviceID,
                                   choice: $characteristicChoice, checkedChannels: $checkedChannels)
                    calibrationControls
                    SettingsPanel(model: model)
                }.padding(18)
            }.frame(minWidth: 320, idealWidth: 350, maxWidth: 410)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FinderResults(model: model)
                    pressureLearningControls
                    learningControls
                    GroupBox("Session reports") {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("\(model.edgeCount) automatic cutoffs · \(model.detectionCount) heuristic events")
                                Spacer()
                                if model.isFinishing { ProgressView().controlSize(.small); Text("Finishing recording…") }
                            }.font(.caption).foregroundStyle(.secondary)
                            if model.feedback.isEmpty { Text("Your reports appear here, separately from sensor detections.").foregroundStyle(.secondary) }
                            ForEach(model.feedback.filter { !$0.removed }.suffix(8).reversed()) { item in
                                HStack {
                                    Text(String(format: "%6.1fs", item.anchor ?? item.time)).monospacedDigit().foregroundStyle(.secondary)
                                    Text(item.kind.title)
                                    Spacer()
                                    Button("−1s") { model.shiftLabel(item.id, seconds: -1) }.help("Correct the report timestamp; power is unchanged")
                                    Button("+1s") { model.shiftLabel(item.id, seconds: 1) }
                                    Button("Remove") { model.removeLabel(item.id) }
                                }.font(.caption).disabled(model.learningBusy)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                    }
                    DisclosureGroup("Recent activity") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in Text(line).font(.caption).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(18)
            }.frame(minWidth: 620)
        }
    }
    private var sensitivityControls: some View {
        GroupBox("Pressure sensitivity") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Input gain")
                    TextField("Input gain", value: $model.preferences.gain, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 75)
                    Stepper("Adjust input gain", value: $model.preferences.gain, in: 0.01...100, step: 0.25)
                        .labelsHidden().accessibilityLabel("Adjust input gain")
                    Button("Save settings") { model.savePreferences() }
                }.disabled(model.configurationLocked)
                Text("Higher gain amplifies pressure changes. Stop to change it, save, then recalibrate in Config.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.calibrated {
                    Button("Open Config for setup and calibration") { selectedTab = .config }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.headline, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
    private var inputOutputControls: some View {
        HStack(spacing: 16) {
            Picker("Input", selection: Binding(get: { model.useDemo }, set: { model.selectInput(demo: $0) })) {
                Text("Demo").tag(true); Text("Perifit").tag(false)
            }.frame(width: 170)
            Picker("Output", selection: Binding(get: { model.output }, set: { model.selectOutput($0) })) {
                ForEach(OutputDestination.allCases, id: \.self) { Text($0.title).tag($0) }
            }.frame(width: 245)
        }.pickerStyle(.menu).controlSize(.small).disabled(model.configurationLocked)
    }
    private var connectionControls: some View {
        GroupBox("Session setup") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Input and output can be selected in the header of either tab.").font(.caption).foregroundStyle(.secondary)
                if model.useDemo {
                    Picker("Pattern", selection: $model.demoPattern) {
                        ForEach(["Rest", "Waves", "Sustained", "Rhythmic"], id: \.self) { Text($0) }
                    }
                    Text("Demo sessions never train your real-device profile.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(5)
        }
    }
    private var calibrationControls: some View {
        GroupBox(model.useDemo ? "Demo calibration" : "Perifit calibration") {
            VStack(alignment: .leading, spacing: 12) {
                Button(model.isCalibrating ? "Recording baseline…" : "Calibrate resting pressure (5s)") { model.calibrate() }
                .disabled(model.configurationLocked || model.isCalibrating)
                Label(model.calibrated ? "Baseline: \(Int(model.baseline)) · \(model.calibrationRestored ? "restored" : "calibrated")" : (!model.useDemo && model.preferences.pressureCalibration != nil ? "Saved baseline · reconnect Perifit to restore" : "Calibration required"),
                      systemImage: model.calibrated ? "checkmark.circle" : "circle")
                    .font(.caption).foregroundStyle(model.calibrated ? .teal : .secondary)
                if !model.useDemo && model.preferences.pressureCalibration != nil {
                    Text("Resting calibration is saved across app restarts. Recalibrate after repositioning the Perifit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(5)
        }
    }
    private var cutoffCountControls: some View {
        GroupBox("Automatic edging count") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Limit automatic cutoffs", isOn: Binding(
                    get: { model.automaticCutoffLimit != nil },
                    set: { model.setAutomaticCutoffLimit($0 ? automaticCutoffDraft : nil) }))
                    .disabled(!model.canEditAutomaticCutoffs)
                NumberButtons(title: "Cutoffs", value: Binding(
                    get: { model.automaticCutoffLimit ?? automaticCutoffDraft },
                    set: { if model.setAutomaticCutoffLimit($0) { automaticCutoffDraft = $0 } }),
                    range: 1...Int.max, step: 1)
                    .disabled(!model.canEditAutomaticCutoffs || model.automaticCutoffLimit == nil)
                Button {
                    if let limit = model.automaticCutoffLimit { model.lockAutomaticCutoffs(limit) }
                } label: {
                    Label(model.automaticCutoffCountLocked ? "Count locked" : "Lock count",
                          systemImage: model.automaticCutoffCountLocked ? "lock.fill" : "lock.open")
                }.disabled(!model.canEditAutomaticCutoffs || model.automaticCutoffLimit == nil)
                if let limit = model.automaticCutoffLimit {
                    Text("\(model.isArmed ? model.automaticCutoffsSoFar : 0) / \(limit) automatic cutoffs")
                        .font(.caption).monospacedDigit()
                    Text(model.automaticEdgingFinished ? "Automatic cutoffs finished. Motors continue until you stop." : "After the last cutoff and cooldown, motors keep running through automatic detections.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.timedEdging != nil ? "Timed edging controls this session; the cutoff-count limit is unavailable." : "Automatic cutoffs continue throughout the session. Enable a limit to adjust its count live.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("The count lock lasts until the session ends. Too close still requests cooldown; pressure loss and watchdog shutdown remain active.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(5)
        }
    }
    private var feedbackControls: some View {
        GroupBox("Your feedback") {
            VStack(alignment: .leading, spacing: 12) {
                if !model.feedbackEnabled {
                    Label(model.startBlockedReason ?? "Ready. Press Start recording to enable feedback.", systemImage: "info.circle")
                        .font(.callout).textSelection(.enabled)
                }
                if let notice = model.recordingNotice {
                    Label(notice, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Getting closer  ⌘1") { model.label(.closer) }
                    Button("Edge  ⌘2") { model.label(.edge) }.tint(.teal)
                    Button("Too close  ⌘4") { model.label(.tooClose) }.tint(.orange)
                    Button("Mark orgasm & stop  ⌘3") { model.label(.orgasm) }.tint(.red)
                }.controlSize(.large).buttonStyle(.bordered).disabled(!model.feedbackEnabled)
                Text("Edge marks the target zone. Too close requests OFF and cooldown. Orgasm requests OFF and disarms.").font(.caption).foregroundStyle(.secondary)
                Text(model.automaticEdgingFinished ? "Automatic edging finished. Stop, Too close and connection protections remain active." : "Automatic OFF: upper score threshold or a rhythmic/event warning. Pressure signals cannot guarantee prevention.").font(.caption).foregroundStyle(.secondary)
                if model.hasCutoffToReview {
                    HStack { Text("Last automatic cutoff:"); Button("Too early") { model.label(.tooEarly) }; Button("About right") { model.label(.aboutRight) } }.font(.caption)
                }
                if model.hasEventToReview {
                    HStack { Text("Last detected event:"); Button("Correct") { model.label(.eventCorrect) }; Button("Incorrect") { model.label(.eventIncorrect) } }.font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
        }
    }
    private var pressureLearningControls: some View {
        GroupBox("Learned pressure patterns") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Use the hotkeys to mark what you feel. New examples are learned when the session ends and saved for future sessions.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Learner.markKinds, id: \.self) { kind in
                    let examples = (model.profile.pressureExamples ?? []).filter { $0.kind == kind }
                    let evidence = model.markEvidence[kind] ?? Evidence()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(kind.title).font(.subheadline.bold())
                            Text("\(examples.count) learned · \(Set(examples.map(\.session)).count) sessions").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(evidence.supported ? "High confidence" : "Learning").font(.caption.bold()).foregroundStyle(evidence.supported ? .teal : .secondary)
                        }
                        if !examples.isEmpty {
                            Text("Typical pre-mark counts: base \(Learner.median(examples.map(\.base)), specifier: "%.0f") · tip \(Learner.median(examples.map(\.tip)), specifier: "%.0f") · above rest \(Learner.median(examples.map(\.pressure)), specifier: "%.0f")")
                                .font(.caption).monospacedDigit()
                        }
                        Text("Later marks: \(evidence.matches) agree · \(evidence.contradictions) disagree · \(evidence.sessions.count) validation sessions")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Only complete three-second windows are learned; gaps elsewhere do not discard the session. At least two mark types are needed to compare patterns. High confidence requires repeated agreement in later sessions, not just many button presses.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("These pressure-pattern estimates do not control motors. The existing cutoff controller and its safeguards remain separate.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(5)
        }
    }
    private var learningControls: some View {
        GroupBox("Confidence from your reports") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Signal.allCases, id: \.self) { signal in
                    let e = model.evidence[signal] ?? Evidence()
                    HStack {
                        VStack(alignment: .leading) {
                            Text(signal.title).font(.subheadline)
                            Text("\(e.matches) agree · \(e.contradictions) contradict · \(e.sessions.count) sessions")
                                .font(.caption).foregroundStyle(.secondary)
                            if let context = model.buildup[signal], context.total > 0 {
                                Text("Present before \(context.matches)/\(context.total) buildup reports")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(e.status).font(.caption.bold()).foregroundStyle(e.supported ? .teal : .secondary)
                    }
                }
                Text("Confidence describes reviewed agreement, not a probability of orgasm. Missing feedback stays unknown.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Edge reference \(model.controllerSettings.effectiveEdgeTarget) · near-orgasm cutoff \(model.controllerSettings.sensitivity) · sustained \(model.profile.active.sustainedThreshold) · peak \(model.profile.active.peakAmplitude)")
                    .font(.caption).monospacedDigit()
                if let candidate = model.profile.candidate {
                    Text("Observation only: \(candidate.sensitivity) / \(candidate.sustainedThreshold) / \(candidate.peakAmplitude). This candidate cannot control power.")
                        .font(.caption).foregroundStyle(.indigo)
                }
                if let adjustment = model.profile.history.last { Text(adjustment.reason).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button(model.preferences.learning ? "Pause learning" : "Enable learning") { model.toggleLearning() }
                    Button("Revert adjustment") { model.revertTuning() }.disabled(model.configurationLocked || model.pressureThresholdsLocked || model.profile.history.last?.to != model.profile.active)
                    if model.profile.frozen { Button("Resume tuning") { model.resumeTuning() }.disabled(model.configurationLocked || model.pressureThresholdsLocked) }
                    Spacer()
                    Button("Delete history…", role: .destructive) { showDelete = true }.disabled(model.configurationLocked || model.pressureThresholdsLocked)
                }.font(.caption)
            }.padding(5)
        }
    }
}

struct BluetoothPanel: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var bluetooth: BluetoothInput
    @Binding var deviceID: UUID?
    @Binding var choice: String
    @Binding var checkedChannels: Bool
    var body: some View {
        if !model.useDemo {
            GroupBox("Perifit Bluetooth") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Button("Scan") { bluetooth.scan() }; Button("Disconnect") { bluetooth.disconnect(); model.inputChanged() } }
                        .disabled(model.configurationLocked)
                    Picker("Device", selection: $deviceID) {
                        Text("Select…").tag(nil as UUID?)
                        ForEach(bluetooth.devices) { Text("\($0.name) (\($0.rssi))").tag(Optional($0.id)) }
                    }.disabled(model.configurationLocked)
                    Button("Connect selected device") { if let deviceID { bluetooth.connect(deviceID); model.inputChanged() } }
                        .disabled(deviceID == nil || model.configurationLocked)
                    Picker("Notify characteristic", selection: $choice) {
                        Text("Select…").tag("")
                        ForEach(bluetooth.choices) { Text($0.id).tag($0.id) }
                    }.disabled(model.configurationLocked)
                    Button("Subscribe") { bluetooth.subscribe(choice); checkedChannels = false; model.inputChanged() }
                        .disabled(choice.isEmpty || model.configurationLocked)
                    Text(bluetooth.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("\(bluetooth.packetCount) packets · \(bluetooth.sampleRate, specifier: "%.1f") Hz · \(bluetooth.malformedCount) malformed")
                        .font(.caption).monospacedDigit()
                    Text("Base \(bluetooth.baseRange) · Tip \(bluetooth.tipRange)").font(.caption)
                    Text("Packet: \(bluetooth.lastHex)").font(.caption.monospaced()).textSelection(.enabled)
                    Toggle("I verified separate base and tip presses change the expected channels", isOn: $checkedChannels).font(.caption)
                    Button(model.protocolVerified ? "Protocol verified" : "Save protocol verification") { model.verifyProtocol() }
                        .disabled(!checkedChannels || !bluetooth.canVerify || model.configurationLocked)
                    Text("Close the phone's Perifit app while connecting. Only the verified pressure notification is used for live output.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(5)
            }
        }
    }
}


private struct NumberButtons: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Button { value -= min(step, value - range.lowerBound) } label: { Image(systemName: "minus") }
                .disabled(value <= range.lowerBound)
                .accessibilityLabel("Decrease \(title)").help("Decrease \(title) by \(step)")
            TextField(title, value: $value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 75).monospacedDigit()
            Button { value += min(step, range.upperBound - value) } label: { Image(systemName: "plus") }
                .disabled(value >= range.upperBound)
                .accessibilityLabel("Increase \(title)").help("Increase \(title) by \(step)")
        }.buttonStyle(.bordered)
    }
}
struct PressureThresholdPanel: View {
    @ObservedObject var model: SessionModel
    @State private var timerMinutes = 60.0
    private var settings: EngineSettings { model.controllerSettings }
    var body: some View {
        GroupBox("Edge-o-Matic pressure thresholds") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    NumberButtons(title: "Edge target", value: Binding(
                        get: { settings.effectiveEdgeTarget },
                        set: { model.setPressureThresholds(edge: $0, cutoff: settings.sensitivity) }),
                        range: 1...(settings.sensitivity - 1), step: 10)
                    NumberButtons(title: "Cutoff", value: Binding(
                        get: { settings.sensitivity },
                        set: { model.setPressureThresholds(edge: settings.effectiveEdgeTarget, cutoff: $0) }),
                        range: max(10, settings.effectiveEdgeTarget + 1)...65535, step: 10)
                }.disabled(!model.canEditPressureThresholds)
                Button { model.lockPressureThresholds() } label: {
                    Label(model.pressureThresholdsLocked ? "Thresholds locked" : "Lock thresholds",
                          systemImage: model.pressureThresholdsLocked ? "lock.fill" : "lock.open")
                }.disabled(!model.canEditPressureThresholds)
                Text(model.automaticEdgingFinished ? "Automatic cutoffs are disabled for this session. These thresholds remain visible as a reference." : "Edge marks the lower target; reaching cutoff stops all motor outputs. Other enabled detectors can also stop output.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Changes apply live without restarting the controller and are saved across launches. The threshold lock is separate from the cutoff-count lock.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                if let safety = model.pressureSafetyStatus {
                    Label(safety, systemImage: "hand.raised.fill").foregroundStyle(.orange)
                }
                if model.finderBestPatternOnly {
                    Text("Best pattern mode: timer and restart penalty cycles are off. Pressure safety stops remain active.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.pressureThresholdsLocked {
                    Toggle("Timed edging → Orgasm mode", isOn: Binding(
                        get: { model.timedEdging != nil },
                        set: { model.setTimedEdging(seconds: $0 ? timerMinutes * 60 : nil) }))
                    .disabled(!model.canEditTimedEdging || (model.automaticCutoffCountLocked && !model.finderEnabled))
                    if let timer = model.timedEdging {
                        HStack {
                            Text("Edging duration (minutes)")
                            TextField("Edging duration in minutes", value: Binding(
                                get: { timer.seconds / 60 },
                                set: { if model.setTimedEdging(seconds: $0 * 60) { timerMinutes = $0 } }), format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 75)
                                .disabled(!model.canEditTimedEdging)
                            if timer.locked {
                                Label("Timer locked", systemImage: "lock.fill")
                                Button("Unlock timer") { model.unlockTimedEdging() }.disabled(!model.canUnlockTimedEdging)
                            } else {
                            Button(model.finderEnabled ? "Lock training + timer" : "Lock timer") { model.lockTimedEdging() }.disabled(!model.canEditTimedEdging)
                            }
                        }
                        if timer.penaltyEdgesRemaining > 0 {
                            Text("Penalty: \(timer.penaltyEdgesRemaining) automatic edges remaining, then the full saved duration starts.")
                                .foregroundStyle(.orange)
                        } else if timer.completed {
                            Text(model.finderEnabled ? "Duration complete · Orgasm mode uses the best learned pattern. Stop to unlock the timer." : "Duration complete · Orgasm mode uses its own M1/M2/M3 preset. Stop to unlock the timer.")
                        } else {
                            Text("Time remaining: \(model.timedEdgingRemaining / 60):\(String(format: "%02d", model.timedEdgingRemaining % 60))")
                                .monospacedDigit()
                        }
                        if model.finderWaitingForSession { Text("Session timer is waiting for training to finish.").font(.caption) }
                        Text("Closing an unfinished session adds 5 automatic penalty edges and restarts the saved duration after them. The lock survives reopening; unlocking is available only after completion. Stop always turns outputs off. " + (model.finderEnabled ? "Finder starts the timer and count after training; the first completed limit takes over." : "Timer mode replaces the cutoff-count limit."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if model.automaticCutoffCountLocked && !model.finderEnabled {
                        Text("End the count-locked session before choosing timed edging.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Lock pressure thresholds to access timed edging.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
    }
}

struct SettingsPanel: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        GroupBox("Manual baseline settings") {
            VStack(alignment: .leading, spacing: 10) {
                integer("Sustained threshold", $model.preferences.baselineSettings.sustainedThreshold)
                integer("Peak amplitude", $model.preferences.baselineSettings.peakAmplitude)
                number("Cooldown (seconds, ≥3)", $model.preferences.baselineSettings.cooldown)
                number("Cooldown jitter (seconds)", $model.preferences.baselineSettings.jitter)
                number("Restart holdoff (seconds)", $model.preferences.baselineSettings.holdoff)
                DisclosureGroup("Original algorithm settings") {
                    VStack(spacing: 8) {
                        integer("Decay retained per second (%)", $model.preferences.baselineSettings.decay)
                        Toggle("Use averaged pressure", isOn: $model.preferences.baselineSettings.averaging)
                        integer("Averaging samples", $model.preferences.baselineSettings.smoothing)
                        Picker("Event detector", selection: $model.preferences.baselineSettings.detectionMode) {
                            Text("Auto").tag(0); Text("Sustained").tag(1); Text("Rhythmic").tag(2)
                        }
                        number("Sustained duration (s)", $model.preferences.baselineSettings.sustainedDuration)
                        number("Sustained dropout (s)", $model.preferences.baselineSettings.sustainedDropout)
                        integer("Minimum rhythmic peaks", $model.preferences.baselineSettings.minimumPeaks)
                        number("Minimum interval (s)", $model.preferences.baselineSettings.intervalMinimum)
                        number("Maximum interval (s)", $model.preferences.baselineSettings.intervalMaximum)
                        number("Interval variation (s)", $model.preferences.baselineSettings.intervalVariance)
                        number("Rhythmic timeout (s)", $model.preferences.baselineSettings.rhythmicTimeout)
                        integer("Arousal gate (%)", $model.preferences.baselineSettings.arousalGate)
                        number("Recovery (s)", $model.preferences.baselineSettings.recovery)
                        Toggle("Clench score boost", isOn: $model.preferences.baselineSettings.clenchBoost)
                        integer("Boost per tick", $model.preferences.baselineSettings.boostAmount)
                    }
                }
                Button("Save settings") { model.savePreferences() }.buttonStyle(.borderedProminent)
                Text("A changed gain, sensor, or manual baseline starts a new learning profile.").font(.caption).foregroundStyle(.secondary)
            }.padding(5).disabled(model.configurationLocked)
        }
    }
    private func number(_ title: String, _ binding: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, value: binding, format: .number).frame(width: 75).textFieldStyle(.roundedBorder) }.font(.caption)
    }
    private func integer(_ title: String, _ binding: Binding<Int>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, value: binding, format: .number).frame(width: 75).textFieldStyle(.roundedBorder) }.font(.caption)
    }
}
