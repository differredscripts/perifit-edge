import AppKit
import Foundation
import Combine
import PerifitCore

struct ChartPoint: Identifiable {
    let id: Double
    let segment: Int
    let base: Double
    let tip: Double
    let pressure: Double
    let score: Double
}

@MainActor
final class SessionModel: ObservableObject {
    let bluetooth = BluetoothInput()
    let usb: ArduinoUSB
    let xtoys = XToysBridge()
    let xtoysM3 = XToysBridge(mappedChannel: 3)
    let xtoysExport = XToysExport()
    var xtoysEnabled: Bool { xtoys.enabled || xtoysM3.enabled }
    private let automaticallyReconnectUSB: Bool
    private var usbConnectionWanted = false
    private var usbConnectionGeneration = 0
    private var usbRetryBudget = 3
    private var usbReconnectTask: Task<Void, Never>?
    @Published var usbReconnecting = false
    @Published var debugExportBusy = false
    @Published var debugExportMessage = ""
    var usbDebugContext: USBDebugLog.Context {
        .init(selectedPort: preferences.arduinoPort ?? "", connectedPort: usb.port, ready: usb.ready,
              boardLimits: usb.limits, savedCalibration: storedPreferences.motorCalibration,
              appliedCalibration: motorCalibration, vibration: activeVibrationSettings,
              output: output.rawValue)
    }
    @Published var preferences = Preferences()
    @Published var profiles: [String: LearningProfile] = [:]
    @Published var useDemo = true
    @Published var output = OutputDestination.simulation
    var useUSB: Bool { output == .arduino }
    var physicalOutput: Bool { output != .simulation }
    var recordingOnly: Bool { !useDemo && !physicalOutput }
    var feedbackEnabled: Bool { isArmed || isFinishing }
    @Published var pressurePaused = false
    @Published var recordingNotice: String?
    var outputDescription: String {
        switch output {
        case .simulation: return recordingOnly ? "Perifit pressure recording · no device output" : "Simulated output · no physical switching"
        case .arduino: return "USB · three independent vibration targets"
        }
    }
    var vibrationRequested = VibrationLevels.zero
    var vibrationReported: VibrationLevels? = .zero
    @Published var finderEnabled = false
    @Published var finderMotors: Set<Int> = [0]
    @Published var finderTargetLevel = 4
    @Published var finderEasingPercent = 15.0
    @Published private(set) var finderTrainingLocked = false
    private var finder: PatternFinder?
    private var finderBand: FinderBand?
    private var bestContinuousPattern: FinderResult?
    private var lastSafetyEventID: UUID?
    private var safetyFrameEvent: PressureSafetyEvent?
    private var lastControlTime = 0.0
    private var lastControlSnapshot = Snapshot()
    var finderBestPatternOnly: Bool { finderEnabled && storedPreferences.finderBestPatternOnly == true }
    var canChangeFinderMode: Bool { !configurationLocked && (!timedEdgingLocked || timedEdging?.completed == true) }
    func setFinderBestPatternOnly(_ enabled: Bool) {
        guard canChangeFinderMode else { return }
        if enabled, timedEdging != nil, !saveTimedEdging(nil) { return }
        storedPreferences.finderBestPatternOnly = enabled; preferences.finderBestPatternOnly = enabled
        if enabled { automaticCutoffLimit = nil; automaticCutoffCountLocked = false }
        schedulePreferencesSave()
    }
    var pressureSafetyStatus: String? {
        if let pause = usb.pressureSafetyPause, isArmed { return pause.reason }
        if isArmed, !automaticEdgingFinished, let guarded = snapshot.guardScore, guarded >= controllerSettings.sensitivity {
            return "Pressure safety OFF · measured score \(snapshot.score) + pending peak \(snapshot.pendingPeak ?? 0) ≥ cutoff \(controllerSettings.sensitivity)"
        }
        return nil
    }
    private enum FinderStage { case search, rampDown, maintain }
    private var finderStage = FinderStage.search
    private var finderDown: FinderDownTrial?
    private var finderRateMonitor = FinderRateMonitor()
    private var finderSessionMotors: Set<Int>?
    private var finderSessionEdgeStart = 0
    private var finderSessionStartedAt: Double?
    private var finderRandom = SystemRandomNumberGenerator()
    var finderRunning: Bool { finderBand != nil }
    var finderLearning: Bool { finderRunning && finderStage != .maintain }
    var finderSearching: Bool { finderRunning && finderStage == .search }
    var finderWaitingForSession: Bool { finderLearning && finderSessionStartedAt == nil }
    private var finderBestAvailable: FinderResult? {
        finder?.winner ?? finder?.bestTrial ?? finderResults.max(by: { $0.riseRate < $1.riseRate })
    }
    var canEndFinderLearning: Bool { isArmed && finderSearching && finderBestAvailable != nil }
    var orgasmModeBlockedReason: String? {
        if !isArmed || recordingOnly { return "Start a Finder session first." }
        if orgasmMode { return "Orgasm mode is active." }
        if automaticCutoffLimit != nil && !automaticCutoffsComplete { return "Finish the active cutoff limit first." }
        if let timer = timedEdging, !timer.completed { return "Finish the active timer first." }
        if !finderEnabled || (bestContinuousPattern == nil && finderBestAvailable == nil) { return "Complete at least one Finder trial first." }
        return nil
    }
    var canStartOrgasmMode: Bool { orgasmModeBlockedReason == nil }
    var canEditFinderSetup: Bool { !configurationLocked && !finderTrainingLocked }
    var hasSavedFinderProgress: Bool { storedPreferences.finderProgress?[profileKey] != nil }
    func resetFinderProgress() {
        guard canEditFinderSetup else { return }
        storedPreferences.finderProgress?.removeValue(forKey: profileKey)
        preferences.finderProgress = storedPreferences.finderProgress
        schedulePreferencesSave(); message = "Training progress reset. Saved patterns remain available; Start begins a new search."
    }
    var canUnlockFinderSetup: Bool { finderTrainingLocked && !configurationLocked && (!timedEdgingLocked || timedEdging?.completed == true) }
    var automaticCutoffsSoFar: Int {
        finderSessionMotors == nil ? edgeCount : (finderWaitingForSession ? 0 : max(0, edgeCount - finderSessionEdgeStart))
    }
    var finderResults: [FinderResult] {
        (storedPreferences.finderLibrary?[profileKey] ?? []).filter {
            $0.matches(settings: storedPreferences.effectiveVibration, motors: finderSessionMotors ?? finderMotors)
        }
    }
    var finderInterruption: String? {
        if let down = finderDown, down.interruptions > 0 {
            return "\(down.interruptions) ramp-down trials restarted · last reason: \(down.lastInterruption ?? "Controller cooldown")"
        }
        guard let finder, finder.discardedTrials > 0 else { return nil }
        return "\(finder.discardedTrials) trials restarted · last reason: \(finder.lastInterruption ?? "Controller cooldown")"
    }
    var finderStatus: String {
        if bestContinuousPattern != nil {
            return orgasmMode ? "Orgasm mode · best learned pattern · automatic edging cutoffs off" : "Best pattern · continuous output · safety cutoffs remain active"
        }
        if let band = finderBand {
            let phase = band.phase.rawValue + (band.selectedRate.map { String(format: " · pattern rate %+.2f/s", $0) } ?? "")
            if let down = finderDown {
                return "Measuring best pattern’s ramp-down · \(Int(ceil(down.secondsRemaining)))s · output \(Int(down.scale * 100))% · \(phase)"
            }
            if let finder, finder.running {
                let plateau = finder.isFinalLevel ? " · \(finder.trialsWithoutImprovement)/\(PatternFinder.noImprovementLimit) without improvement" : ""
                return "Learning level \(finder.currentLevel)/\(finder.targetLevel) · trial \(finder.trial) · \(Int(ceil(finder.secondsRemaining)))s\(plateau) · \(phase)"
            }
            return "Target: within 1% below cutoff \(controllerSettings.sensitivity) · \(phase) · \(finderResults.count) library patterns"
        }
        if isArmed, finderSessionMotors != nil { return "Finder finished · \(orgasmMode ? "Orgasm preset" : "continuous mode") · selected motors only" }
        return "\(finderResults.count) saved patterns for this setup. Learn, then maintain until the count limit, timer or Stop."
    }
    var finderForecast: String? {
        guard let band = finderBand else { return nil }
        let queued = band.queuedPhase.map { " · next: \($0.rawValue) at the pattern boundary" } ?? ""
        return String(format: "Smoothed lookahead %.2fs · projected %.1f · cutoff %d", band.lookaheadSeconds, band.forecastScore, controllerSettings.sensitivity) + queued
    }
    private var finderBlockedReason: String? {
        guard finderEnabled else { return nil }
        if recordingOnly { return "Finder needs Arduino output, or Demo with Simulation output." }
        if xtoysEnabled { return "Turn off XToys control before using Finder." }
        if !finderEasingPercent.isFinite || !(0...50).contains(finderEasingPercent) { return "Choose an easing strength from 0–50% of the selected motor targets." }
        let channels = useUSB ? usb.limits.channelCount : 3
        guard (1...20).contains(finderTargetLevel), !finderMotors.isEmpty,
              finderMotors.allSatisfy({ (0..<channels).contains($0) && storedPreferences.effectiveVibration[$0].target > 0 }) else {
            return "Choose 1–20 Finder levels and available motors with target ceilings above zero."
        }
        return nil
    }
    @Published var isDiscovering = false
    @Published var discoveryPulseBusy = false
    @Published var discoveryElectricalChecked = false
    @Published var discoverySupplyVoltage = 6.0
    @Published var discoveryChannels = [MotorDiscoveryChannel(), MotorDiscoveryChannel()]
    @Published var motorSetupConfirmed = false
    private var nextDiscoveryPulse = 0.0
    var motorCalibration: MotorCalibration? {
        guard let value = storedPreferences.motorCalibration, (try? value.validated()) != nil,
              value.port == usb.port, value.boardLimits.one == usb.limits.one, value.boardLimits.two == usb.limits.two,
              value.boardLimits.three == 0 || value.boardLimits.three == usb.limits.three else { return nil }
        return value
    }
    var vibrationLimits: VibrationLevels {
        guard useUSB else { return VibrationLevels(255, 255, 255) }
        guard let saved = motorCalibration else { return usb.limits }
        return VibrationLevels(saved.maximums.one, saved.maximums.two,
                               saved.boardLimits.three == 0 ? usb.limits.three : saved.maximums.three)
    }
    @Published var demoPattern = "Rest"
    @Published var message = "Simulation selected. Calibrate, then start; no physical device will be switched."
    @Published var isArmed = false
    @Published var isStarting = false
    @Published var isCalibrating = false
    @Published var calibrated = false
    @Published var calibrationRestored = false
    private var allowCalibrationRestore = true
    @Published var isFinishing = false
    @Published var learningBusy = false
    @Published var baseline = 0.0
    @Published var sampleBase = 0
    @Published var sampleTip = 0
    @Published var snapshot = Snapshot()
    @Published var chart: [ChartPoint] = []
    @Published var feedback: [Feedback] = []
    @Published var evidence: [Signal: Evidence] = [:]
    @Published var markEvidence: [FeedbackKind: Evidence] = [:]
    @Published var predictedMark: FeedbackKind?
    @Published var buildup: [Signal: Evidence] = [:]
    @Published var logs: [String] = []
    @Published var reportedPower: Bool? = false
    @Published var requestedPower = false
    @Published var fault: String?
    @Published var edgeCount = 0
    @Published private(set) var automaticCutoffLimit: Int?
    @Published private(set) var automaticCutoffCountLocked = false
    @Published private(set) var pressureThresholdsLocked = false
    @Published private(set) var automaticCutoffsComplete = false
    @Published private(set) var orgasmMode = false
    @Published private(set) var timedEdgingRemaining = 0
    private var explicitCooldown = false
    @Published var detectionCount = 0
    @Published var hasCutoffToReview = false
    @Published var hasEventToReview = false
    @Published var storageError: String?
    private var store: LocalStore?
    private let disk = DispatchQueue(label: "PerifitEdge.archive", qos: .utility)
    private var checkpointInFlight = false
    private var storedPreferences = Preferences()
    private var records: [SessionRecord] = []
    private var timer: Timer?
    private var sample: PressureSample?
    private var calibrationValues: [UInt16] = []
    private var calibrationStart = 0.0
    private var epoch = ProcessInfo.processInfo.systemUptime
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var latestTickGap = 0.0
    private var lastUI = 0.0
    private var chartSegment = 0
    private var lastCheckpoint = 0.0
    private var engine: Engine?
    private var shadow: Engine?
    private var archive: SessionRecord?
    private var recordingEnabled = false
    private var envelope = VibrationEnvelope()
    private var preferenceSaveTask: Task<Void, Never>?
    private var displayedSession: UUID?
    private var finishAt: Double?
    private var episode = 0
    private var previousWant = false
    private var lastCutoff: (Double, Int)?
    private var lastEvent: (Double, Int, Signal)?
    private var controlGeneration = 0
    private var activity: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    var profileKey: String {
        if let archive { return archive.profile }
        let savedDevice = storedPreferences.verifiedPeripheral.isEmpty ? (storedPreferences.pressureCalibration?.peripheral ?? "unconnected") : storedPreferences.verifiedPeripheral
        let device = useDemo ? "demo" : (bluetooth.connectedID?.uuidString ?? savedDevice)
        // Earlier profiles learned to stop at Edge. Keep that history separate.
        return device + ":" + storedPreferences.profileGeneration + ":ride-edge-v2" +
            (useUSB ? ":usb:" + usb.port + ":\(usb.limits.one),\(usb.limits.two)" + (usb.limits.three > 0 ? ",\(usb.limits.three)" : "") + ":" + storedPreferences.effectiveVibration.profileKey + ":" + (motorCalibration?.profileKey ?? "undiscovered") : "")
    }
    var profile: LearningProfile { profiles[profileKey] ?? LearningProfile(key: profileKey, baseline: storedPreferences.baselineSettings) }
    var canStart: Bool { startBlockedReason == nil }
    var startBlockedReason: String? {
        if isArmed { return "Session is running; feedback is available." }
        if isStarting { return "Session is starting…" }
        if usbReconnecting { return "Reconnecting to Arduino; your settings are retained." }
        if isFinishing || learningBusy { return "Wait for the previous session to finish saving." }
        if isDiscovering { return "Finish motor discovery first, or cancel it to record pressure only." }
        if let reason = finderBlockedReason { return reason }
        if useUSB && xtoysEnabled && !xtoys.connected && !xtoysM3.connected { return "Connect XToys before starting, or turn off XToys control." }
        if timedEdging != nil && !pressureThresholdsLocked { return "Lock pressure thresholds before starting timed edging." }
        if let storageError { return "Resolve the local storage error: \(storageError)" }
        if isCalibrating { return "Recording your resting baseline; wait five seconds." }
        if !calibrated { return "Calibrate resting pressure (5s), then start the session to enable feedback." }
        guard PressureFreshness.evaluate(sampleTime: sample?.time, now: now, controllingOutput: physicalOutput) == .fresh else { return "Waiting for fresh pressure readings. Check the Bluetooth subscription." }
        if !useDemo && sample?.hasPressure != true { return "Both Perifit pressure channels must report nonzero raw readings before starting." }
        let testUSB = useUSB && usb.isPseudoTerminalTest
        if useDemo && physicalOutput && !testUSB { return "Demo cannot control devices. Select Simulation output." }
        if physicalOutput && !protocolVerified && !testUSB { return "In Config → Perifit Bluetooth, verify both pressure channels and choose Save protocol verification." }
        if useUSB && (!usb.ready || usb.reported != .zero || usb.boardArmed || !usb.supportsDiscovery || !motorSetupConfirmed) {
            return "Connect the Arduino and confirm its motor setup, or select Simulation to record pressure only."
        }
        let startingVibration = timedEdging?.completed == true ? storedPreferences.effectiveOrgasmVibration : storedPreferences.effectiveVibration
        if useUSB && startingVibration.channels.prefix(usb.limits.channelCount).allSatisfy({ $0.target == 0 }) { return "Set a motor target, or select Simulation to record pressure only." }
        return nil
    }
    var dataLocation: String { store?.directory.path ?? "Unavailable" }
    var estimatedZone: String {
        if isArmed && orgasmMode && !pressurePaused && !explicitCooldown { return "Orgasm mode" }
        if isArmed && automaticCutoffsComplete && !explicitCooldown { return "Continuous" }
        guard isArmed else { return "Disarmed" }
        if pressurePaused { return "Pressure paused" }
        if snapshot.controlPhase == 1 { return "Cooldown" }
        if snapshot.riskReason != nil { return "Too close" }
        return snapshot.score >= controllerSettings.effectiveEdgeTarget ? "Edge zone" : "Building"
    }
    private var configuredControllerSettings: EngineSettings {
        var settings = profile.active
        settings.pendingPeakGuard = true
        if let timedEdging, timedEdging.locked {
            settings.edgeTarget = timedEdging.edge; settings.sensitivity = timedEdging.cutoff
        }
        return settings
    }
    var controllerSettings: EngineSettings { engine?.settings ?? configuredControllerSettings }
    var timedEdging: TimedEdging? { storedPreferences.timedEdging }
    var timedEdgingLocked: Bool { timedEdging?.locked == true }
    var canUnlockTimedEdging: Bool { timedEdgingLocked && timedEdging?.completed == true && !configurationLocked }
    var activeVibrationSettings: VibrationSettings {
        if let band = finderBand { return band.candidate }
        if let best = bestContinuousPattern {
            var settings = best.settings
            for index in 0..<3 { settings[index].target = min(settings[index].target, storedPreferences.effectiveVibration[index].target) }
            return settings
        }
        var settings = orgasmMode ? storedPreferences.effectiveOrgasmVibration : storedPreferences.effectiveVibration
        if let motors = finderSessionMotors { for index in 0..<3 where !motors.contains(index) { settings[index].target = 0 } }
        return settings
    }
    var automaticEdgingFinished: Bool { orgasmMode || automaticCutoffsComplete }
    var usesOrgasmPreset: Bool { orgasmMode && bestContinuousPattern == nil }
    private var liveControlsEditable: Bool { !isStarting && !isFinishing && !learningBusy && !isDiscovering }
    var canEditPressureThresholds: Bool { liveControlsEditable && !pressureThresholdsLocked }
    var canEditAutomaticCutoffs: Bool { liveControlsEditable && !orgasmMode && !finderBestPatternOnly && !automaticCutoffCountLocked && (timedEdging == nil || finderEnabled) }
    var canEditVibration: Bool { liveControlsEditable }
    var canEditTimedEdging: Bool { pressureThresholdsLocked && !finderBestPatternOnly && !timedEdgingLocked && !configurationLocked }
    var configurationLocked: Bool { isArmed || isStarting || isFinishing || learningBusy || isDiscovering }
    var protocolVerified: Bool {
        useDemo || (bluetooth.connectedID?.uuidString == storedPreferences.verifiedPeripheral &&
                    bluetooth.activeChoice?.service == storedPreferences.verifiedService &&
                    bluetooth.activeChoice?.characteristic == storedPreferences.verifiedCharacteristic)
    }

    init(dataDirectory: URL? = nil, allowPseudoTerminal: Bool = false, automaticallyReconnectUSB: Bool = true) {
        self.automaticallyReconnectUSB = automaticallyReconnectUSB
        usb = ArduinoUSB(allowPseudoTerminal: allowPseudoTerminal)
        do {
            let store = try LocalStore(directory: dataDirectory); self.store = store
            preferences = try store.preferences(); storedPreferences = preferences
            if preferences.baselineSettings.pendingPeakGuard != true {
                preferences.baselineSettings.pendingPeakGuard = true
                try store.save(preferences); storedPreferences = preferences
            }
            if let library = preferences.finderLibrary, library.values.contains(where: { $0.count > FinderResult.libraryLimit }) {
                preferences.finderLibrary = library.mapValues { FinderResult.prunedLibrary($0) }
                try store.save(preferences); storedPreferences = preferences
            }
            if let setup = preferences.finderSetup {
                finderEnabled = true; finderTrainingLocked = true; finderMotors = setup.motors
                finderTargetLevel = setup.levels; finderEasingPercent = setup.easingPercent
            }
            profiles = try store.profiles(); records = try store.sessions()
            var changedSafetyPolicy = false
            for key in Array(profiles.keys) where profiles[key]!.active.pendingPeakGuard != true {
                profiles[key]!.baseline.pendingPeakGuard = true; profiles[key]!.active.pendingPeakGuard = true
                profiles[key]!.candidate?.pendingPeakGuard = true; changedSafetyPolicy = true
            }
            if changedSafetyPolicy { try store.save(profiles: profiles) }
            // Older builds kept the resting baseline only in session archives.
            if preferences.pressureCalibration == nil, !preferences.verifiedPeripheral.isEmpty,
               !preferences.verifiedService.isEmpty, !preferences.verifiedCharacteristic.isEmpty,
               let previous = records.last(where: { !$0.simulated && $0.complete && $0.gain == preferences.gain &&
                   $0.profile.hasPrefix(preferences.verifiedPeripheral + ":" + preferences.profileGeneration + ":ride-edge-v2") }) {
                preferences.pressureCalibration = try PressureCalibration(peripheral: preferences.verifiedPeripheral,
                    service: preferences.verifiedService, characteristic: preferences.verifiedCharacteristic,
                    baseline: previous.baseline, gain: previous.gain, date: previous.date).validated()
                try store.save(preferences)
            }
            storedPreferences = preferences
            if var saved = preferences.timedEdging, saved.sessionOpen {
                saved.recoverInterruptedSession()
                preferences.timedEdging = saved; try store.save(preferences); storedPreferences = preferences
                if saved.penaltyEdgesRemaining > 0 { message = "Interrupted timed session: \(saved.penaltyEdgesRemaining) automatic penalty edges remain before the saved duration restarts." }
            }
            pressureThresholdsLocked = timedEdgingLocked
            timedEdgingRemaining = timedEdging?.remaining ?? 0
            useDemo = preferences.lastInputWasDemo ?? (preferences.pressureCalibration == nil)
            output = preferences.lastOutput ?? records.reversed().compactMap {
                $0.outputTransport.flatMap(OutputDestination.init(rawValue:))
            }.first ?? .simulation
            if preferences.lastOutput == nil {
                preferences.lastOutput = output; storedPreferences.lastOutput = output
                try store.save(storedPreferences)
            }
            if output != .simulation && (timedEdging?.penaltyEdgesRemaining ?? 0) == 0 {
                message = "Restored \(output.title) selection. Outputs are OFF; connect and press Start manually."
            }
        } catch { storageError = error.localizedDescription; message = error.localizedDescription }
        bluetooth.onSample = { [weak self] sample in self?.receive(sample) }
        xtoys.onFault = { [weak self] reason in
            guard let self, self.useUSB else { return }
            if self.isArmed || self.isStarting { self.trip(reason) }
        }
        xtoysM3.onFault = xtoys.onFault
        bluetooth.onDisconnect = { [weak self] reason in
            guard let self, !self.useDemo else { return }
            self.calibrated = false; self.isCalibrating = false
            if self.isArmed || self.isStarting || self.isFinishing { self.trip(reason) }
        }
        bluetooth.onProtocolError = { [weak self] reason in
            guard let self, !self.useDemo else { return }
            self.calibrated = false
            if self.isArmed || self.isStarting || self.isFinishing { self.trip(reason) }
        }
        usb.onFault = { [weak self] reason in
            guard let self, self.useUSB else { return }
            let confirmedSetup = self.motorSetupConfirmed, port = self.usb.port, limits = self.usb.limits
            self.motorSetupConfirmed = false
            self.vibrationReported = nil; self.reportedPower = nil
            if self.isArmed || self.isStarting || self.isFinishing || self.isDiscovering { self.trip(reason) }
            else { self.fault = reason; self.message = reason }
            self.reconnectUSB(port: port, limits: limits, confirmedSetup: confirmedSetup)
        }
        usb.onReported = { [weak self] levels in
            guard let self, self.useUSB else { return }
            self.usb.debugLog.recordContext(self.usbDebugContext)
            self.vibrationReported = levels
            if self.reportedPower != levels.anyOn { self.reportedPower = levels.anyOn }
            else if !self.isArmed { self.objectWillChange.send() }
        }
        usb.onPressureSafety = { [weak self] event in self?.handlePressureSafety(event) }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.calibrated = false
                self?.cancelUSBReconnect()
                self?.trip("Mac is going to sleep. Saved calibrations are retained; reconnect and restart manually after waking.")
            }
        }
        timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        refreshEvidence()
    }
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var elapsed: Double { max(0, now - epoch) }
    private func log(_ text: String) { logs.insert(text, at: 0); if logs.count > 25 { logs.removeLast() } }
    func selectInput(demo: Bool) {
        guard !configurationLocked, useDemo != demo else { return }
        useDemo = demo; inputChanged()
    }
    func selectOutput(_ destination: OutputDestination) {
        guard !configurationLocked, output != destination else { return }
        let previous = output; output = destination; outputChanged(from: previous)
    }
    func inputChanged() {
        guard !configurationLocked else { return }
        calibrationRestored = false; allowCalibrationRestore = true
        if storedPreferences.lastInputWasDemo != useDemo || storedPreferences.lastOutput != output {
            preferences.lastInputWasDemo = useDemo; storedPreferences.lastInputWasDemo = useDemo
            preferences.lastOutput = output; storedPreferences.lastOutput = output
            do { try store?.save(storedPreferences) } catch { storageFailed(error.localizedDescription) }
        }
        pressurePaused = false; recordingNotice = nil
        motorSetupConfirmed = false
        calibrated = false; sample = nil; engine = nil; shadow = nil; chart = []; snapshot = Snapshot()
        isCalibrating = false; fault = nil; reportedPower = physicalOutput ? nil : false
        envelope.reset(); vibrationRequested = .zero; vibrationReported = physicalOutput ? nil : .zero
        refreshEvidence()
    }
    func outputChanged(from previous: OutputDestination) {
        guard !configurationLocked else { return }
        if previous == .arduino { cancelUSBReconnect(); xtoys.stop(); xtoysM3.stop(); usb.disconnect() }
        inputChanged()
    }
    func connectUSB() {
        guard !configurationLocked, savePreferences() else { return }
        cancelUSBReconnect(); usbRetryBudget = 3
        motorSetupConfirmed = false
        let path = storedPreferences.arduinoPort ?? ""
        let generation = usbConnectionGeneration
        Task {
            do {
                try await usb.connect(path: path)
                guard generation == usbConnectionGeneration else { return }
                usbConnectionWanted = true; fault = nil; refreshEvidence(); message = "Arduino connected with all channels OFF."
            } catch {
                if generation == usbConnectionGeneration { message = error.localizedDescription }
                usb.debugLog.record("fault", "Connect failed: \(error.localizedDescription)")
            }
        }
    }
    func disconnectUSB() {
        guard !configurationLocked || usbReconnecting else { return }
        cancelUSBReconnect()
        motorSetupConfirmed = false
        usb.disconnect(); vibrationReported = nil; reportedPower = nil
    }
    private func cancelUSBReconnect() {
        usbConnectionWanted = false; usbConnectionGeneration += 1
        let wasReconnecting = usbReconnecting
        usbReconnectTask?.cancel(); usbReconnectTask = nil; usbReconnecting = false
        if wasReconnecting { usb.disconnect() }
    }
    private func reconnectUSB(port: String, limits: VibrationLevels, confirmedSetup: Bool) {
        guard automaticallyReconnectUSB, usbConnectionWanted, useUSB, !port.isEmpty,
              usbReconnectTask == nil, usbRetryBudget > 0 else { return }
        let generation = usbConnectionGeneration
        usbReconnecting = true
        usbReconnectTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == usbConnectionGeneration { usbReconnectTask = nil; usbReconnecting = false }
            }
            while usbRetryBudget > 0 {
                let delay = 1 << (3 - usbRetryBudget); usbRetryBudget -= 1
                message = "Arduino disconnected. Reconnecting in \(delay)s; targets and patterns are retained."
                usb.debugLog.record("reconnect", "Retry in \(delay)s on \(port); settings retained; output stays disarmed.")
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled, generation == usbConnectionGeneration, usbConnectionWanted, useUSB,
                      preferences.arduinoPort == port else { return }
                do {
                    try await usb.connect(path: port)
                    try await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, generation == usbConnectionGeneration else { return }
                    guard usb.ready, usb.port == port, usb.reported == .zero, !usb.boardArmed else {
                        throw AppError.invalid("Arduino connection did not remain ready and OFF.")
                    }
                    let sameLimits = usb.limits == limits
                    usb.debugLog.record("reconnect", "Ready and OFF; board limits unchanged: \(sameLimits). Manual Start required.")
                    motorSetupConfirmed = confirmedSetup && sameLimits
                    fault = nil; refreshEvidence()
                    message = sameLimits ? "Arduino reconnected with outputs OFF. Settings retained; press Start to resume." :
                        "Arduino reconnected OFF with different firmware limits. Settings retained; confirm the motor setup before Start."
                    return
                } catch {
                    if Task.isCancelled || generation != usbConnectionGeneration { return }
                    usb.debugLog.record("reconnect", error.localizedDescription)
                    log("Arduino reconnect failed: \(error.localizedDescription)")
                }
            }
            message = "Automatic Arduino reconnect attempts ended. Settings are retained; reconnect manually when ready."
        }
    }
    func beginDiscovery() {
        guard useUSB, !configurationLocked, usb.ready, usb.supportsDiscovery,
              usb.reported == .zero, !usb.boardArmed else {
            message = "Connect firmware with TEST250 discovery support and all motors OFF."; return
        }
        motorSetupConfirmed = false; discoveryElectricalChecked = false
        isCalibrating = false; calibrated = false; engine = nil; shadow = nil
        discoverySupplyVoltage = 6.0
        discoveryChannels = (0..<usb.limits.channelCount).map { var channel = MotorDiscoveryChannel(); channel.pwm = min(8, usb.limits[$0]); return channel }
        isDiscovering = true; fault = nil; controlGeneration += 1
        message = "Bench discovery: test one motor at a time; no pressure sensor is required."
    }
    func testMotor(_ channel: Int) {
        guard isDiscovering, !discoveryPulseBusy, discoveryChannels.indices.contains(channel), discoveryElectricalChecked,
              discoverySupplyVoltage.isFinite, (4.5...6.2).contains(discoverySupplyVoltage), now >= nextDiscoveryPulse,
              discoveryChannels.allSatisfy({ $0.awaitingObservation == nil }) else {
            message = "Verify the bench setup, review the last test, and allow two seconds between pulses."; return
        }
        let limit = usb.limits[channel]
        do { try discoveryChannels[channel].validatePulse(limit: limit) }
        catch { message = error.localizedDescription; return }
        let pwm = discoveryChannels[channel].pwm, generation = controlGeneration
        var levels = VibrationLevels.zero; levels[channel] = pwm
        discoveryPulseBusy = true; vibrationRequested = levels; vibrationReported = nil; reportedPower = nil
        Task {
            do {
                guard generation == controlGeneration, isDiscovering else { return }
                try await usb.testPulse(levels)
                guard generation == controlGeneration, isDiscovering else { return }
                try discoveryChannels[channel].completed(pwm: pwm, limit: limit)
                discoveryPulseBusy = false; vibrationRequested = .zero; nextDiscoveryPulse = now + 2
                message = "All motors OFF. Record whether M\(channel+1) started and ran normally."
            } catch {
                if generation == controlGeneration { trip("Discovery stopped: \(error.localizedDescription)") }
            }
        }
    }
    func observeMotor(_ channel: Int, runsNormally: Bool) {
        guard isDiscovering, !discoveryPulseBusy, discoveryChannels.indices.contains(channel) else { return }
        discoveryChannels[channel].observe(runsNormally: runsNormally)
    }
    func saveMotorDiscovery() {
        guard isDiscovering, !discoveryPulseBusy, discoveryElectricalChecked,
              discoveryChannels.allSatisfy({ $0.awaitingObservation == nil }), usb.reported == .zero, !usb.boardArmed else { return }
        do {
            let value = try MotorCalibration(port: usb.port, boardLimits: usb.limits, supplyVoltage: discoverySupplyVoltage,
                minimums: VibrationLevels(discoveryChannels[0].minimum, discoveryChannels[1].minimum, discoveryChannels.count == 3 ? discoveryChannels[2].minimum : 0),
                maximums: VibrationLevels(discoveryChannels[0].maximum, discoveryChannels[1].maximum, discoveryChannels.count == 3 ? discoveryChannels[2].maximum : 0)).validated()
            var updated = storedPreferences; updated.motorCalibration = value
            // Discovery never starts a session or inherits a previously nonzero target.
            var settings = updated.effectiveVibration; settings.one.target = 0; settings.two.target = 0; settings.three.target = 0
            updated.vibration = settings
            preferenceSaveTask?.cancel(); try store?.save(updated)
            storedPreferences = updated; preferences = updated; isDiscovering = false
            usb.debugLog.recordContext(usbDebugContext)
            envelope.reset(); refreshEvidence()
            message = "Motor ranges saved; targets reset to zero. Verify combined load and heating before confirming this setup."
        } catch { message = error.localizedDescription }
    }
    func setVibrationTarget(channel: Int, value: Double, forOrgasm: Bool? = nil) {
        guard (0..<3).contains(channel) else { return }
        let preset = forOrgasm ?? usesOrgasmPreset
        var updated = (preset ? storedPreferences.effectiveOrgasmVibration : storedPreferences.effectiveVibration).channels[channel]
        updated.target = value
        setVibrationChannel(channel, value: updated, forOrgasm: preset)
    }
    func setVibrationChannel(_ channel: Int, value: VibrationChannel, forOrgasm: Bool? = nil) {
        guard canEditVibration, (0..<3).contains(channel) else { return }
        let preset = forOrgasm ?? usesOrgasmPreset
        var settings = preset ? storedPreferences.effectiveOrgasmVibration : storedPreferences.effectiveVibration
        let old = settings.channels[channel]
        guard value != old else { return }
        settings[channel] = value
        do { _ = try settings.validated() }
        catch { message = error.localizedDescription; return }
        if finderRunning { stop() }
        if preset { preferences.orgasmVibration = settings; storedPreferences.orgasmVibration = settings }
        else { preferences.vibration = settings; storedPreferences.vibration = settings }
        usb.debugLog.recordContext(usbDebugContext)
        if archive != nil {
            archive!.eligible = false // Changing stimulation invalidates that session's tuning comparison.
            if archive!.vibrationTargetChanges == nil { archive!.vibrationTargetChanges = [] }
            archive!.vibrationTargetChanges!.append(VibrationTargetChange(time: elapsed, settings: settings, orgasmPreset: preset))
            message = "Vibration settings updated. This session is recorded but excluded from automatic tuning."
        }
        schedulePreferencesSave()
    }
    private func schedulePreferencesSave() {
        preferenceSaveTask?.cancel()
        preferenceSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self else { return }
            do {
                try self.store?.save(self.storedPreferences)
                if !self.configurationLocked { self.refreshEvidence() }
            } catch { self.storageFailed(error.localizedDescription) }
        }
    }
    func verifyProtocol() {
        guard !configurationLocked, !useDemo, bluetooth.canVerify,
              let id = bluetooth.connectedID, let choice = bluetooth.activeChoice else { return }
        preferences.verifiedPeripheral = id.uuidString
        preferences.verifiedService = choice.service
        preferences.verifiedCharacteristic = choice.characteristic
        if savePreferences() { message = "Protocol verified for this peripheral and characteristic. Calibrate before control." }
    }
    @discardableResult func savePreferences() -> Bool {
        guard !configurationLocked else { return false }
        preferences.baselineSettings.pendingPeakGuard = true
        preferences.lastInputWasDemo = useDemo; preferences.lastOutput = output
        guard preferences.timedEdging == storedPreferences.timedEdging else {
            message = "Use the timed edging controls to change its saved settings."; return false
        }
        guard !pressureThresholdsLocked ||
                (preferences.baselineSettings.effectiveEdgeTarget == storedPreferences.baselineSettings.effectiveEdgeTarget &&
                 preferences.baselineSettings.sensitivity == storedPreferences.baselineSettings.sensitivity) else {
            message = "Pressure thresholds are locked until the session ends."; return false
        }
        do {
            _ = try preferences.validated()
            if preferences.gain != storedPreferences.gain || preferences.baselineSettings != storedPreferences.baselineSettings ||
                preferences.verifiedPeripheral != storedPreferences.verifiedPeripheral ||
                preferences.verifiedCharacteristic != storedPreferences.verifiedCharacteristic ||
                preferences.verifiedService != storedPreferences.verifiedService {
                preferences.profileGeneration = UUID().uuidString; calibrated = false
            }
            try store?.save(preferences)
            storedPreferences = preferences; engine = nil; refreshEvidence()
            usb.debugLog.recordContext(usbDebugContext)
            message = "Settings saved. Learning uses a separate profile for changed calibration or baseline settings."
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func calibrate() {
        guard !configurationLocked else { return }
        if !useDemo && PressureFreshness.evaluate(sampleTime: sample?.time, now: now) != .fresh { message = "Connect and subscribe to Perifit notifications first."; return }
        isCalibrating = true; calibrated = false; calibrationStart = now; calibrationValues = []
        calibrationRestored = false; allowCalibrationRestore = false
        message = "Recording a five-second resting baseline…"
    }
    private func receive(_ value: PressureSample) {
        sample = value
        if useUSB && isArmed { usb.receivePressure(value) }
        if !useDemo && !value.hasPressure {
            if physicalOutput && (isArmed || isStarting || isDiscovering) {
                trip("Perifit pressure dropped to zero. All motor outputs stopped and session disarmed. Check the sensor, then press Start manually.")
            } else if isCalibrating {
                isCalibrating = false; calibrationValues = []; calibrated = false
                message = "Calibration stopped: a Perifit channel reported zero raw pressure."
            }
            return
        }
        if isCalibrating { calibrationValues.append(value.base) }
        else { restorePressureCalibration() }
    }
    private func restorePressureCalibration() {
        guard !useDemo, !calibrated, !isCalibrating, !configurationLocked, allowCalibrationRestore,
              sample?.hasPressure == true,
              PressureFreshness.evaluate(sampleTime: sample?.time, now: now) == .fresh, let saved = storedPreferences.pressureCalibration,
              saved.matches(peripheral: bluetooth.connectedID, service: bluetooth.activeChoice?.service,
                            characteristic: bluetooth.activeChoice?.characteristic, gain: storedPreferences.gain) else { return }
        do {
            engine = try Engine(settings: configuredControllerSettings); baseline = saved.baseline
            envelope.reset(); epoch = now; chart = []; snapshot = Snapshot()
            calibrated = true; calibrationRestored = true
            message = "Saved Perifit baseline restored. Recalibrate if its position or fit has changed; Start is still manual."
        } catch { message = error.localizedDescription }
    }
    private func persistPressureCalibration() throws {
        guard !useDemo, let id = bluetooth.connectedID, let choice = bluetooth.activeChoice else { return }
        let saved = try PressureCalibration(peripheral: id.uuidString, service: choice.service,
            characteristic: choice.characteristic, baseline: baseline, gain: storedPreferences.gain).validated()
        guard let store else { throw AppError.invalid("Local storage is unavailable; calibration could not be saved.") }
        var updated = storedPreferences; updated.pressureCalibration = saved; updated.lastInputWasDemo = false
        try store.save(updated)
        storedPreferences = updated; preferences.pressureCalibration = saved; preferences.lastInputWasDemo = false
    }
    private func demoSample(at time: Double) -> PressureSample {
        let t = time - epoch
        let extra: Double
        switch isCalibrating ? "Rest" : demoPattern {
        case "Waves": extra = max(0, sin(t * 2 * .pi / 2.4)) * 850
        case "Sustained": extra = 600
        case "Rhythmic": extra = 500 + 280 * (1 + sin(t * 2 * .pi / 0.8))
        default: extra = 0
        }
        return PressureSample(base: UInt16(1000 + extra), tip: UInt16(700 + extra * 0.2), time: time)
    }
    private func tick() {
        if useUSB, let event = usb.pressureSafetyPause { handlePressureSafety(event) }
        let time = now
        defer { exportXToysTelemetry(at: time) }
        let previousTick = lastTick
        latestTickGap = time - previousTick
        let delayed = time - lastTick >= (useUSB ? USBWire.controllerFreshnessSeconds : 0.25)
        lastTick = time
        if useDemo { receive(demoSample(at: time)) }
        if delayed && isArmed {
            if physicalOutput { trip("Controller timing stalled. Device output stopped; session disarmed.") }
            else if !pressurePaused {
                recordGap(start: max(0, previousTick - epoch), end: elapsed, reason: "Controller timing pause")
                recordingNotice = "Timing pause marked. Pressure and feedback recording continue; learning will use complete windows around your marks."
            }
        }
        if isDiscovering { return }
        if isCalibrating && time - calibrationStart >= 5 {
            isCalibrating = false
            if calibrationValues.count >= 20, PressureFreshness.evaluate(sampleTime: sample?.time, now: time) == .fresh {
                let sorted = calibrationValues.sorted(); baseline = Double(sorted[sorted.count/2])
                calibrated = true; fault = nil
                do {
                    engine = try Engine(settings: configuredControllerSettings); envelope.reset(); epoch = time; chart = []; snapshot = Snapshot()
                    try persistPressureCalibration(); allowCalibrationRestore = true
                    message = "Baseline \(Int(baseline)). \(useDemo ? "Choose a demo pattern and start simulation." : "Calibration complete; saved for this Perifit when device identification is available.")"
                } catch { calibrated = false; message = error.localizedDescription }
            } else { message = "Calibration failed: insufficient fresh pressure samples." }
        }
        let freshness = PressureFreshness.evaluate(sampleTime: sample?.time, now: time, controllingOutput: physicalOutput)
        let fresh = freshness == .fresh
        if isArmed && !fresh {
            if physicalOutput && freshness == .lost {
                trip("Pressure stream lost for \(Int(PressureFreshness.lossAge)) seconds. Outputs stopped; saved calibration retained. Reconnect and press Start when readings return.")
            } else {
                if !pressurePaused {
                    pressurePaused = true; predictedMark = nil
                    recordGap(start: max(0, (sample?.time ?? time) - epoch), reason: "Pressure readings missing")
                    if physicalOutput {
                        requestCooldownOff()
                        recordingNotice = "No fresh pressure for \(PressureFreshness.outputMaximumAge)s. All motor outputs are OFF; fresh readings will begin a full cooldown before resuming."
                    } else {
                        recordingNotice = "Pressure readings paused. Feedback remains available; incomplete windows are excluded from learning."
                        requestedPower = false; reportedPower = false
                        envelope.reset(); vibrationRequested = .zero; vibrationReported = .zero
                    }
                }
                if useUSB && isArmed {
                    do { try usb.drive(.zero) } catch { trip(error.localizedDescription) }
                }
            }
        }
        if pressurePaused && fresh {
            pressurePaused = false
            if let index = archive?.recordingGaps?.lastIndex(where: { $0.end == nil }) { archive!.recordingGaps![index].end = elapsed }
            if physicalOutput && isArmed {
                // Record the real cooldown action for exact replay; no human label is fabricated.
                let t = max(0, time - epoch); archive?.manualEdges.append(t)
                do { try engine?.manualEdge(at: t); try shadow?.manualEdge(at: t) }
                catch { trip(error.localizedDescription) }
                recordingNotice = "Pressure readings resumed. Outputs remain OFF through the normal quiet cooldown."
            } else { recordingNotice = "Pressure readings resumed. Learning uses complete windows around your marks." }
        }
        guard let sample, fresh, calibrated, let engine else {
            if let sample, fresh { updatePlot(sample: sample, pressure: 0, active: Snapshot(), time: time) }
            if isFinishing, let finishAt, elapsed >= finishAt { finishSession(eligible: false) }
            return
        }
        do {
            let pressure = try sample.conditioned(baseline: baseline, gain: storedPreferences.gain)
            let t = max(0, time - epoch)
            var active = try engine.step(pressure, at: t)
            let externalCutoff = safetyFrameEvent?.countedAsCutoff == true
            if var event = safetyFrameEvent {
                event.handledAt = t
                if let index = archive?.pressureSafetyEvents?.firstIndex(where: { $0.id == event.id }) {
                    archive!.pressureSafetyEvents![index].handledAt = t
                }
                if externalCutoff {
                    active.edge = true; active.riskReason = event.reason
                    active.guardScore = max(active.guardScore ?? 0, event.guardScore)
                }
            }
            let observed = try shadow?.step(pressure, at: t)
            if isArmed && !finderWaitingForSession {
                advanceTimedEdging(seconds: max(0, time - max(previousTick, finderSessionStartedAt ?? previousTick)))
            }
            // Finish the last quiet cooldown before releasing automatic cutoffs.
            // Explicit cooldowns still require the engine's normal permission.
            if active.wantsPower {
                explicitCooldown = false
                if isArmed, !finderWaitingForSession, timedEdging == nil || finderSessionMotors != nil, !automaticCutoffsComplete, let limit = automaticCutoffLimit, automaticCutoffsSoFar >= limit {
                    automaticCutoffsComplete = true
                    message = "\(limit) automatic cutoffs completed. Automatic cutoffs are disabled for the rest of this session."
                    log(message)
                }
            }
            let engineWantsPower = active.wantsPower || (automaticEdgingFinished && !explicitCooldown)
            if useUSB && isArmed {
                try updatePressureSafety(active, at: time, permitted: engineWantsPower)
            }
            let wantsPower = engineWantsPower && (!useUSB || usb.pressureSafetyPause == nil)
            if wantsPower && !previousWant { episode += 1 }
            let automaticCutoff = !externalCutoff && (active.edge || (previousWant && !wantsPower && !explicitCooldown))
            let finderCutoff = finderRunning && isArmed && automaticCutoff && !automaticEdgingFinished
            previousWant = wantsPower
            if isArmed && automaticCutoff && !automaticEdgingFinished {
                requestCooldownOff(automatic: true, preserveFinderMeasurement: finderCutoff)
                edgeCount += 1; lastCutoff = (t, episode); hasCutoffToReview = true
                advanceTimedEdging(seconds: 0, automaticEdge: true)
                log("Near-orgasm cutoff · \(active.riskReason ?? "upper score threshold") · score \(active.score)")
            }
            if active.detected && archive != nil {
                detectionCount += 1; lastEvent = (t, episode, active.rhythmic ? .rhythmic : .sustained); hasEventToReview = true
                log("Heuristic event · \(active.rhythmic ? "rhythmic" : "sustained")")
            }
            try advanceFinder(score: Double(active.score), time: t, permitted: isArmed && wantsPower, actualCutoff: finderCutoff)
            if let best = bestContinuousPattern,
               let update = finderRateMonitor.observe(score: Double(active.score), time: t, patternID: isArmed && wantsPower ? best.id : nil, falling: false),
               var saved = finderResults.first(where: { $0.id == best.id || $0.settings == best.settings }) {
                saved.validateLiveRate(update); saveFinderResult(saved)
            }
            let permitted = isArmed && wantsPower
            let minimums = useUSB ? (motorCalibration?.minimums ?? .zero) : .zero
            let levels: VibrationLevels
            if useUSB && xtoysEnabled {
                levels = try xtoys.demand.addingM3(xtoysM3.demand).levels(settings: activeVibrationSettings, limits: vibrationLimits,
                                                minimums: minimums, permitted: permitted && (xtoys.connected || xtoysM3.connected))
            } else {
                levels = try envelope.step(activeVibrationSettings, limits: vibrationLimits, minimums: minimums,
                                           permitted: permitted, time: t, outputScale: finderDown?.scale ?? finderBand?.outputScale ?? 1)
            }
            if vibrationRequested != levels { vibrationRequested = levels }
            if useUSB && isArmed { try usb.drive(levels) }
            if !physicalOutput && vibrationReported != levels { vibrationReported = levels }
            if archive != nil && recordingEnabled {
                // ponytail: cap RAM at 100,000 frames (~33 minutes); stream archives if long sessions need learning.
                if archive!.frames.count < 100_000 {
                    var frame = Frame(time: t, base: sample.base, tip: sample.tip, pressure: pressure,
                        armed: isArmed, episode: episode, active: active, shadow: observed, confirmedPower: reportedPower)
                    frame.pressureAge = max(0, time - sample.time)
                    if useUSB || !physicalOutput { frame.vibrationRequested = levels; frame.vibrationReported = vibrationReported }
                    if useUSB { frame.pressureSafetyHeld = usb.pressureSafetyPause != nil }
                    archive!.frames.append(frame)
                } else {
                    archive!.eligible = false
                    recordingEnabled = false
                    message = "Learning recording limit reached; this session will not tune settings. Control remains active."
                }
            }
            let desired = isArmed && (useUSB ? levels.anyOn : wantsPower)
            if requestedPower != desired { requestedPower = desired }
            if !useUSB && reportedPower != desired { reportedPower = desired }
            updatePlot(sample: sample, pressure: pressure, active: active, time: time)
            lastControlTime = t; lastControlSnapshot = active; safetyFrameEvent = nil
            if archive != nil && recordingEnabled && t - lastCheckpoint >= 10 { checkpoint(); lastCheckpoint = t }
            if let finishAt, t >= finishAt { finishSession(eligible: true) }
        } catch { trip(error.localizedDescription) }
    }
    func advanceFinder(score: Double, time: Double, permitted: Bool, actualCutoff: Bool = false) throws {
        guard finderRunning else { return }
        if automaticEdgingFinished {
            finder?.stop(); finderDown = nil; finderBand = nil; finderRateMonitor.reset(); finderPatternChanged()
            message = "Finder finished · \(orgasmMode ? "Orgasm preset" : "continuous mode") · selected motors only."
            return
        }
        if finderStage == .rampDown, finderDown?.result != nil {
            finderDown = nil; finderStage = .maintain; finderRateMonitor.reset()
            let alreadyStarted = finderSessionStartedAt != nil
            beginFinderSession()
            message = "Ramp-down training complete. Maintaining within 1% below the configured cutoff. " +
                (alreadyStarted ? "The session continues without restarting its timer or count." : "The session timer and count now begin.")
        }
        var changed = try updateFinderBand(score: score, time: time, permitted: permitted)
        let phase = finderBand!.phase
        let reason = actualCutoff ? "Actual controller cutoff" : "Controller cooldown"
        var learningChanged = false
        switch finderStage {
        case .search:
            if finderBand?.queuedPhase != nil {
                try finder?.queueNextPattern(preferred: finderBand?.queuedCandidate, random: &finderRandom)
            }
            let priorTrial = finder?.latestTrial?.id
            learningChanged = try finder?.observe(score: score, time: time, permitted: permitted && phase == .building,
                                                  interruptionReason: reason, actualCutoff: actualCutoff, random: &finderRandom) ?? false
            if let result = finder?.latestTrial, result.id != priorTrial, result.fallback != true || actualCutoff { saveFinderResult(result) }
            if finder?.endedForNoImprovement == true, let best = finder?.winner ?? finder?.bestTrial {
                if finderBestPatternOnly { beginBestPattern(best) }
                else {
                    try beginFinderRampDown(best)
                    message = "20 completed trials without a new best. Now ramping down the best observed pattern and measuring the score’s response."
                }
            }
            if learningChanged && finderRunning { changed = try updateFinderBand(score: score, time: time, permitted: permitted) || changed }
        case .rampDown:
            try finderDown?.observe(score: score, time: time, permitted: permitted && phase == .building,
                                    interruptionReason: reason, actualCutoff: actualCutoff)
            if let down = finderDown, let measurement = down.result {
                var result = finderResults.first(where: { $0.id == down.pattern.id }) ?? down.pattern
                result.descent = measurement; saveFinderResult(result)
            }
        case .maintain:
            if let update = finderRateMonitor.observe(score: score, time: time, patternID: finderBand?.selectedPatternID, falling: phase == .easing),
               var result = finderResults.first(where: { $0.id == update.patternID }) {
                result.validateLiveRate(update); saveFinderResult(result)
                changed = try updateFinderBand(score: score, time: time, permitted: permitted) || changed
            }
        }
        if changed { finderPatternChanged() }
        else if learningChanged { objectWillChange.send() }
        if learningChanged { rememberFinderProgress() }
    }
    private func beginFinderRampDown(_ best: FinderResult) throws {
        let observed = finderResults.first(where: { $0.settings == best.settings }) ?? best
        if !finderResults.contains(where: { $0.id == observed.id }) { saveFinderResult(observed) }
        finderDown = try FinderDownTrial(pattern: observed); finderStage = .rampDown
    }
    private func beginBestPattern(_ best: FinderResult) {
        let saved = finderResults.first { $0.id == best.id || $0.settings == best.settings } ?? best
        if !finderResults.contains(where: { $0.id == saved.id }) { saveFinderResult(saved) }
        bestContinuousPattern = saved
        finder?.stop(); finderDown = nil; finderBand = nil; finderStage = .maintain
        finderRateMonitor.reset(); envelope.reset(); beginFinderSession(); rememberFinderProgress()
        message = "Learning complete. Running the best pattern without edging routines or a timer; safety cutoffs remain active."
    }
    private func beginFinderSession() {
        guard finderSessionStartedAt == nil else { return }
        finderSessionStartedAt = now; finderSessionEdgeStart = edgeCount
    }
    func endFinderLearning() {
        guard canEndFinderLearning, let best = finderBestAvailable else { return }
        if finderBestPatternOnly { beginBestPattern(best); return }
        do {
            try beginFinderRampDown(best)
            finder?.stop(); beginFinderSession()
            rememberFinderProgress()
            finderBand?.pause(); finderPatternChanged()
            message = "Upward learning ended manually. Measuring the best pattern’s ramp-down; the configured session timer and count start now."
            log(message)
        } catch { message = error.localizedDescription }
    }
    func startOrgasmMode() {
        if let reason = orgasmModeBlockedReason { message = reason; return }
        beginOrgasmMode()
    }
    private func beginOrgasmMode() {
        let best = bestContinuousPattern ?? (finderEnabled ? finderBestAvailable : nil)
        rememberFinderProgress() // Preserve unfinished training for the next session.
        finder = nil; finderDown = nil; finderBand = nil; finderRateMonitor.reset()
        bestContinuousPattern = best
        orgasmMode = true; archive?.orgasmModeAt = elapsed
        archive?.orgasmVibrationSettings = activeVibrationSettings
        finderPatternChanged()
        usb.debugLog.recordContext(usbDebugContext)
        message = "Orgasm mode · \(best != nil ? "best learned pattern" : "configured motor preset"). Automatic edging cutoffs are off. Stop, Too close, pressure loss and disconnect protections remain active."
        log(message)
    }
    private func saveFinderResult(_ result: FinderResult) {
        var library = storedPreferences.finderLibrary ?? [:], patterns = storedPreferences.finderLibrary?[profileKey] ?? []
        if let index = patterns.firstIndex(where: { $0.id == result.id || $0.settings == result.settings }) {
            var updated = result
            if patterns[index].id != result.id {
                updated.riseSamples = Array(((patterns[index].riseSamples ?? [patterns[index].comparisonRate]) + [result.comparisonRate]).suffix(12))
                updated.descent = patterns[index].descent; updated.fallSamples = patterns[index].fallSamples
                updated.responseDelays = patterns[index].responseDelays; updated.validationCount = patterns[index].validationCount
            }
            patterns[index] = updated
        }
        else { patterns.append(result) }
        let activeSettings = [finder?.candidate, finder?.winner?.settings,
                              finderBand?.queuedCandidate, finderDown?.pattern.settings].compactMap { $0 }
        var protected = Set(patterns.filter { activeSettings.contains($0.settings) }.map(\.id))
        protected.insert(result.id)
        if let id = finderBand?.selectedPatternID { protected.insert(id) }
        library[profileKey] = FinderResult.prunedLibrary(patterns, keeping: protected)
        storedPreferences.finderLibrary = library; preferences.finderLibrary = library
        schedulePreferencesSave()
    }
    private func updateFinderBand(score: Double, time: Double, permitted: Bool) throws -> Bool {
        try finderBand!.update(score: score, time: time, permitted: permitted,
            edge: Double(controllerSettings.effectiveEdgeTarget), cutoff: Double(controllerSettings.sensitivity),
            library: finderResults, learning: finderDown?.pattern.settings ?? (finder?.running == true ? finder?.candidate : nil),
            pressureAge: max(0, now - (sample?.time ?? now)))
    }
    private func rememberFinderProgress() {
        guard let finder else { return }
        var saved = storedPreferences.finderProgress ?? [:]
        saved[profileKey] = finder
        storedPreferences.finderProgress = saved; preferences.finderProgress = saved
        schedulePreferencesSave()
    }
    private func interruptFinder(_ reason: String, keepValidation: Bool = false) {
        guard finderRunning else { return }
        finder?.interrupt(reason: reason, random: &finderRandom)
        finderDown?.interrupt(reason)
        if !keepValidation { finderRateMonitor.reset() }
        finderBand?.pause(); finderPatternChanged()
    }
    private func finderPatternChanged() {
        envelope.reset()
        if archive != nil {
            archive!.eligible = false
            if archive!.vibrationTargetChanges == nil { archive!.vibrationTargetChanges = [] }
            archive!.vibrationTargetChanges!.append(VibrationTargetChange(time: elapsed, settings: activeVibrationSettings))
        }
        objectWillChange.send()
    }
    private func recordGap(start: Double, end: Double? = nil, reason: String) {
        interruptFinder(reason)
        guard archive != nil else { return }
        chartSegment += 1
        if archive!.recordingGaps == nil { archive!.recordingGaps = [] }
        archive!.recordingGaps!.append(RecordingGap(start: start, end: end, reason: reason))
        log(reason); checkpoint()
    }
    private func updatePlot(sample: PressureSample, pressure: UInt16, active: Snapshot, time: Double) {
        guard time - lastUI >= 0.1 else { return }
        if isArmed, var recent = archive, let model = recent.markModel {
            recent.frames = Array(recent.frames.suffix(200))
            predictedMark = Learner.markWindow(recent, at: elapsed).flatMap { model.predict(Learner.markFeatures($0)) }
        } else { predictedMark = nil }
        lastUI = time; snapshot = active; sampleBase = Int(sample.base); sampleTip = Int(sample.tip)
        chart.append(ChartPoint(id: max(0, time-epoch), segment: chartSegment, base: Double(sample.base), tip: Double(sample.tip), pressure: Double(pressure), score: Double(active.score)))
        if chart.count > 600 { chart.removeFirst(chart.count-600) }
    }
    func start() {
        if let reason = startBlockedReason { message = reason; return }
        refreshEvidence()
        isStarting = true; fault = nil; controlGeneration += 1
        let generation = controlGeneration
        Task {
            do {
                guard generation == controlGeneration, isStarting else { return }
                if var value = timedEdging {
                    value.sessionOpen = true
                    try persistTimedProgress(value)
                }
                if useUSB { usbConnectionWanted = true; usbRetryBudget = 3; try await usb.arm() }
                guard generation == controlGeneration else { return }
                if useUSB && (!motorSetupConfirmed || !usb.supportsDiscovery) {
                    throw AppError.invalid("Motor setup changed during arming; confirm the connection.")
                }
                let time = now; epoch = time; lastTick = time; lastCheckpoint = 0
                lastSafetyEventID = nil; safetyFrameEvent = nil; lastControlTime = 0; lastControlSnapshot = Snapshot()
                bestContinuousPattern = nil
                pressurePaused = false; recordingNotice = nil
                let p = profile; profiles[p.key] = p
                let seed = UInt32.random(in: 1...UInt32.max)
                let settings = configuredControllerSettings
                engine = try Engine(settings: settings, seed: seed)
                envelope.reset()
                shadow = storedPreferences.learning && !p.frozen ? try p.candidate.map { try Engine(settings: $0, seed: seed) } : nil
                if timedEdgingLocked { try shadow?.updateThresholds(edge: settings.effectiveEdgeTarget, cutoff: settings.sensitivity) }
                try engine?.arm(true, at: 0); try shadow?.arm(true, at: 0)
                isArmed = true; isStarting = false; isFinishing = false; finishAt = nil
                if useUSB && xtoysEnabled {
                    if xtoys.connected { try xtoys.beginSession() }
                    if xtoysM3.connected { try xtoysM3.beginSession() }
                }
                orgasmMode = timedEdging?.completed == true; timedEdgingRemaining = timedEdging?.remaining ?? 0
                archive = SessionRecord(profile: p.key, simulated: useDemo, settings: settings,
                    candidate: shadow == nil ? nil : p.candidate, seed: seed, baseline: baseline, gain: storedPreferences.gain)
                archive!.candidateVersion = shadow == nil ? nil : p.candidateVersion
                archive!.recordingGaps = []
                archive!.markModel = p.markModel
            archive!.outputTransport = output.rawValue
            archive!.automaticCutoffLimit = automaticCutoffLimit
                archive!.vibrationSource = finderEnabled ? (finderBestPatternOnly ? "finder-best" : "finder") : (useUSB && xtoysEnabled ? "xtoys" : "native")
                archive!.timedEdging = timedEdging
                archive!.orgasmVibrationSettings = timedEdging == nil ? nil : storedPreferences.effectiveOrgasmVibration
                if orgasmMode { archive!.orgasmModeAt = 0 }
                if finderEnabled {
                    finderStage = .search; finderDown = nil; finderRateMonitor.reset()
                    finderSessionStartedAt = nil
                    finder = try PatternFinder(settings: storedPreferences.effectiveVibration, motors: finderMotors,
                                               targetLevel: finderTargetLevel, availableChannels: useUSB ? usb.limits.channelCount : 3,
                                               random: &finderRandom)
                    if let saved = storedPreferences.finderProgress?[profileKey],
                       let resumed = try? saved.resuming(settings: storedPreferences.effectiveVibration,
                                                       motors: finderMotors, targetLevel: finderTargetLevel) {
                        finder = resumed
                    }
                    finderSessionMotors = finderMotors
                    finderSessionEdgeStart = 0
                    finderBand = try FinderBand(settings: storedPreferences.effectiveVibration, motors: finderMotors,
                                                easingPercent: finderEasingPercent)
                }
                archive!.vibrationSettings = (useUSB || !physicalOutput) ? activeVibrationSettings : nil
                archive!.vibrationLimits = vibrationLimits
                archive!.motorCalibration = useUSB ? motorCalibration : nil
                recordingEnabled = storedPreferences.learning
                displayedSession = archive!.id
                archive!.eligible = storedPreferences.learning && timedEdging == nil && !xtoysEnabled && !finderEnabled
                feedback = []; episode = 0; previousWant = false; edgeCount = 0; detectionCount = 0
                lastCutoff = nil; lastEvent = nil; hasCutoffToReview = false; hasEventToReview = false
                chart = []
                activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Active Perifit pressure control")
                if orgasmMode { beginOrgasmMode() }
                else if finderEnabled, finder?.running == false, let best = finderBestAvailable {
                    if finderBestPatternOnly { beginBestPattern(best) }
                    else {
                        let saved = finderResults.first { $0.id == best.id || $0.settings == best.settings }
                        if saved?.descent != nil { finderStage = .maintain; beginFinderSession() }
                        else { try beginFinderRampDown(best) }
                    }
                }
                if useUSB {
                    try updatePressureSafety(Snapshot(), at: time, permitted: false)
                    if let sample { usb.receivePressure(sample) }
                    if !useDemo, let peripheral = bluetooth.connectedID, let choice = bluetooth.activeChoice {
                        bluetooth.safetyTap.bind(peripheral: peripheral, service: choice.service, characteristic: choice.characteristic,
                                                 sink: usb.pressureSafetySink())
                    }
                }
                rememberFinderProgress()
                checkpoint(); message = useUSB ? "Armed · independent M1/M2/M3 targets · shared risk cutoff" : "Simulation running · physical output disabled"
            } catch { if generation == controlGeneration { isStarting = false; trip(error.localizedDescription) } }
        }
    }
    @discardableResult func setPressureThresholds(edge: Int, cutoff: Int) -> Bool {
        guard canEditPressureThresholds else { return false }
        var updated = storedPreferences.baselineSettings
        updated.edgeTarget = edge; updated.sensitivity = cutoff
        do {
            _ = try updated.validated()
            guard edge != controllerSettings.effectiveEdgeTarget || cutoff != controllerSettings.sensitivity ||
                    updated != storedPreferences.baselineSettings else { return true }
            if finderRunning { stop() }
            try engine?.updateThresholds(edge: edge, cutoff: cutoff)
            try shadow?.updateThresholds(edge: edge, cutoff: cutoff)
            preferences.baselineSettings.edgeTarget = edge; preferences.baselineSettings.sensitivity = cutoff
            storedPreferences.baselineSettings = updated
            // Preserve this session's original profile for replay; future sessions use the new baseline.
            let generation = UUID().uuidString
            preferences.profileGeneration = generation; storedPreferences.profileGeneration = generation
            if archive != nil {
                archive!.eligible = false
                if archive!.thresholdChanges == nil { archive!.thresholdChanges = [] }
                archive!.thresholdChanges!.append(ThresholdChange(time: elapsed, edge: edge, cutoff: cutoff))
            }
            schedulePreferencesSave()
            message = "Pressure thresholds updated live: Edge \(edge), cutoff \(cutoff). Controller state and calibration retained."
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func lockPressureThresholds() {
        let current = controllerSettings
        guard setPressureThresholds(edge: current.effectiveEdgeTarget, cutoff: current.sensitivity) else { return }
        pressureThresholdsLocked = true
        message = "Pressure thresholds locked until the session ends. The automatic cutoff count has its own lock."
    }
    @discardableResult func setTimedEdging(seconds: Double?) -> Bool {
        guard canEditTimedEdging, !automaticCutoffCountLocked || finderEnabled else { return false }
        let settings = controllerSettings
        let value = seconds.map { TimedEdging(seconds: $0, edge: settings.effectiveEdgeTarget, cutoff: settings.sensitivity) }
        return saveTimedEdging(value)
    }
    func lockTimedEdging() {
        guard canEditTimedEdging, var value = timedEdging else { return }
        if finderEnabled && !finderTrainingLocked, !lockFinderSetup() { return }
        value.edge = controllerSettings.effectiveEdgeTarget; value.cutoff = controllerSettings.sensitivity
        value.locked = true
        if saveTimedEdging(value) { message = "Timer and pressure thresholds locked. This lock survives quitting and reopening." }
    }
    func unlockTimedEdging() {
        guard canUnlockTimedEdging, var value = timedEdging else { return }
        value.locked = false
        value.completed = false; value.elapsedSeconds = 0; value.sessionOpen = false
        if saveTimedEdging(value) { message = "Timer unlocked. Pressure thresholds remain locked until Stop." }
    }
    private func saveTimedEdging(_ value: TimedEdging?) -> Bool {
        do {
            _ = try value?.validated()
            var updated = storedPreferences; updated.timedEdging = value
            if value != nil && updated.orgasmVibration == nil { updated.orgasmVibration = updated.effectiveVibration }
            try store?.save(updated)
            storedPreferences = updated; preferences.timedEdging = value; preferences.orgasmVibration = updated.orgasmVibration
            timedEdgingRemaining = value?.remaining ?? 0
            if value != nil && !finderEnabled { automaticCutoffLimit = nil; automaticCutoffsComplete = false }
            return true
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult func lockFinderSetup() -> Bool {
        guard finderEnabled, canEditFinderSetup else { return false }
        guard finderBlockedReason == nil else { message = finderBlockedReason!; return false }
        do {
            let setup = try FinderSetup(motors: finderMotors, levels: finderTargetLevel, easingPercent: finderEasingPercent).validated()
            var updated = storedPreferences; updated.finderSetup = setup
            try store?.save(updated); storedPreferences = updated; preferences.finderSetup = setup
            finderTrainingLocked = true
            message = "Training setup locked. The session timer starts after training completes."
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func unlockFinderSetup() {
        guard canUnlockFinderSetup else { return }
        do {
            var updated = storedPreferences; updated.finderSetup = nil
            try store?.save(updated); storedPreferences = updated; preferences.finderSetup = nil
            finderTrainingLocked = false
        } catch { message = error.localizedDescription }
    }
    private func persistTimedProgress(_ value: TimedEdging) throws {
        var updated = storedPreferences; updated.timedEdging = try value.validated()
        try store?.save(updated)
        storedPreferences = updated; preferences.timedEdging = value
    }
    private func advanceTimedEdging(seconds: Double, automaticEdge: Bool = false) {
        guard var value = timedEdging else { return }
        let previous = value
        value.advance(seconds: seconds, automaticEdge: automaticEdge)
        storedPreferences.timedEdging = value
        if timedEdgingRemaining != value.remaining || previous.penaltyEdgesRemaining != value.penaltyEdgesRemaining {
            timedEdgingRemaining = value.remaining; preferences.timedEdging = value
        }
        if previous.penaltyEdgesRemaining != value.penaltyEdgesRemaining || previous.completed != value.completed {
            do { try persistTimedProgress(value) } catch { storageFailed(error.localizedDescription); return }
        }
        if value.completed && !orgasmMode {
            beginOrgasmMode()
        }
    }
    @discardableResult func setAutomaticCutoffLimit(_ count: Int?) -> Bool {
        guard canEditAutomaticCutoffs else { return false }
        guard count == nil || count! > 0 else { message = "Choose a positive number of automatic cutoffs."; return false }
        guard count != automaticCutoffLimit else { return true }
        automaticCutoffLimit = count
        if count == nil || automaticCutoffsSoFar < count! { automaticCutoffsComplete = false }
        if archive != nil {
            archive!.eligible = false
            if archive!.automaticCutoffChanges == nil { archive!.automaticCutoffChanges = [] }
            archive!.automaticCutoffChanges!.append(AutomaticCutoffChange(time: elapsed, limit: count))
        }
        message = count.map { "Automatic cutoff limit updated live to \($0). Completed cutoffs are retained." } ??
            "Automatic cutoffs will continue throughout this session."
        return true
    }
    func lockAutomaticCutoffs(_ count: Int) {
        guard setAutomaticCutoffLimit(count) else { return }
        automaticCutoffCountLocked = true
        message = "Locked for this session: \(count) automatic cutoffs, then continuous output after the final cooldown."
    }
    func stop() {
        cancelUSBReconnect()
        disarm()
        message = "Stopped. Power OFF requested; a new start requires manual arming."
        emergencyOff()
        if archive != nil { isFinishing = true; finishAt = elapsed + 3.2 }
    }
    private func disarm(closingApp: Bool = false) {
        rememberFinderProgress()
        bluetooth.safetyTap.clear(); bestContinuousPattern = nil
        finder = nil; finderDown = nil; finderBand = nil; finderRateMonitor.reset(); finderSessionMotors = nil
        finderSessionStartedAt = nil
        xtoys.endSession(); xtoysM3.endSession()
        pressureThresholdsLocked = timedEdgingLocked; automaticCutoffCountLocked = false
        orgasmMode = false; timedEdgingRemaining = timedEdging?.remaining ?? 0
        automaticCutoffLimit = nil; automaticCutoffsComplete = false; explicitCooldown = false
        pressurePaused = false
        isDiscovering = false; discoveryPulseBusy = false
        let at = elapsed
        if isArmed { archive?.armChanges.append(ArmChange(time: at, armed: false)) }
        controlGeneration += 1; isArmed = false; isStarting = false; requestedPower = false
        envelope.reset(); vibrationRequested = .zero
        if useUSB { usb.prepareStop() }
        try? engine?.arm(false, at: at); try? shadow?.arm(false, at: at)
        if var value = timedEdging, value.sessionOpen, !closingApp {
            value.sessionOpen = false
            do { try persistTimedProgress(value) } catch { storageError = error.localizedDescription }
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    private func trip(_ reason: String) {
        if fault == reason && !isArmed && !isStarting && !isDiscovering { return }
        if useUSB { usb.debugLog.record("controllerFault", reason) }
        let diagnostic = ["reason": reason, "date": ISO8601DateFormatter().string(from: Date()),
                          "port": useUSB ? usb.port : "", "output": output.rawValue,
                          "controllerGapSeconds": String(max(latestTickGap, now - lastTick)),
                          "pressureAgeSeconds": sample.map { String(max(0, now - $0.time)) } ?? "missing"]
        fault = reason; log(reason); disarm(); calibrated = false; reportedPower = physicalOutput ? nil : false
        emergencyOff()
        if let store { disk.async { try? store.saveControllerFault(diagnostic) } }
        if archive != nil { finishSession(eligible: false) }
        message = reason
    }
    private func emergencyOff() {
        guard useUSB else { reportedPower = false; return }
        Task {
            do {
                try await usb.stop()
                vibrationReported = usb.reported; reportedPower = usb.reported.map(\.anyOn)
            } catch { vibrationReported = nil; reportedPower = nil; fault = "USB OFF unconfirmed: \(error.localizedDescription)" }
        }
    }
    func label(_ kind: FeedbackKind) {
        // Emergency feedback is effective even before an arming handshake finishes.
        if archive == nil && (kind == .tooClose || kind == .orgasm) { stop(); return }
        var targetEpisode = episode
        var anchor: Double?, signal: Signal?
        if kind == .tooEarly || kind == .aboutRight {
            guard let lastCutoff else { return }; anchor = lastCutoff.0; targetEpisode = lastCutoff.1
        }
        if kind == .eventCorrect || kind == .eventIncorrect {
            guard let lastEvent else { return }; anchor = lastEvent.0; targetEpisode = lastEvent.1; signal = lastEvent.2
        }
        let t = elapsed
        var label = Feedback(time: t, episode: targetEpisode, kind: kind, anchor: anchor, signal: signal)
        if Learner.markKinds.contains(kind), let record = archive, let model = record.markModel,
           let window = Learner.markWindow(record, at: t) {
            label.predictedMark = model.predict(Learner.markFeatures(window))
            label.predictionModelID = model.id
        }
        guard archive != nil else {
            if [.tooEarly, .aboutRight, .eventCorrect, .eventIncorrect].contains(kind), !configurationLocked,
               let r = records.firstIndex(where: { $0.id == displayedSession }) {
                records[r].feedback.append(label)
                persistCorrection(records[r], invalidatesPriorLearning: false)
            } else { message = "Start a session to record live feedback." }
            return
        }
        archive!.feedback.append(label); feedback = archive!.feedback
        if kind == .tooClose {
            archive!.manualEdges.append(t)
            try? engine?.manualEdge(at: t); try? shadow?.manualEdge(at: t)
            requestCooldownOff()
        } else if kind == .orgasm { stop() }
        checkpoint(); log("User report: \(kind.title)")
    }
    private func updatePressureSafety(_ value: Snapshot, at time: Double, permitted: Bool) throws {
        let context = try PressureSafetyContext(baseline: baseline, gain: storedPreferences.gain,
            score: value.score, peakTrough: value.peakTrough ?? 0, cutoff: controllerSettings.sensitivity,
            permitted: permitted, peakGuardEnabled: !automaticEdgingFinished, time: time,
            acknowledgedPause: lastSafetyEventID)
        usb.updatePressureSafety(context)
    }
    private func handlePressureSafety(_ incoming: PressureSafetyEvent) {
        guard useUSB, isArmed, incoming.id != lastSafetyEventID else { return }
        lastSafetyEventID = incoming.id
        var event = incoming
        event.time = max(0, incoming.time - epoch)
        event.scoreTime = max(0, incoming.scoreTime - epoch)
        event.pressureTime = incoming.pressureTime.map { max(0, $0 - epoch) }
        event.handledAt = elapsed
        if !event.requiresDisarm {
            let newCutoff = event.kind == .pendingPeak && !automaticEdgingFinished && !explicitCooldown && lastControlSnapshot.controlPhase != 1
            event.countedAsCutoff = newCutoff
            do {
                if newCutoff {
                    try advanceFinder(score: Double(lastControlSnapshot.score), time: lastControlTime,
                                      permitted: false, actualCutoff: true)
                    edgeCount += 1; lastCutoff = (elapsed, episode); hasCutoffToReview = true
                    advanceTimedEdging(seconds: 0, automaticEdge: true)
                }
                if newCutoff || event.kind == .stalePressure {
                    let actionTime = max(elapsed, lastControlTime + 0.000001)
                    try engine?.manualEdge(at: actionTime); try shadow?.manualEdge(at: actionTime)
                    event.actionTime = actionTime
                    requestCooldownOff(automatic: newCutoff, preserveFinderMeasurement: newCutoff)
                }
                previousWant = false
                safetyFrameEvent = event
            } catch { trip(error.localizedDescription); return }
        }
        if recordingEnabled, archive != nil {
            if archive!.pressureSafetyEvents == nil { archive!.pressureSafetyEvents = [] }
            archive!.pressureSafetyEvents!.append(event)
            // ponytail: full-rate packets aren't archived; exclude these sessions from pressure tuning until they are.
            archive!.eligible = false
        }
        log(event.reason)
        if event.requiresDisarm { trip(event.reason) }
    }
    private func requestCooldownOff(automatic: Bool = false, preserveFinderMeasurement: Bool = false) {
        if !preserveFinderMeasurement {
            interruptFinder(automatic ? "Automatic pressure cutoff" : "Manual or pressure-loss cooldown", keepValidation: automatic)
        }
        if !automatic { explicitCooldown = true }
        requestedPower = false
        guard isArmed else { emergencyOff(); return }
        envelope.reset(); vibrationRequested = .zero
        if useUSB { usb.zeroNow() }
        else { reportedPower = false }
    }
    func removeLabel(_ id: UUID) {
        editLabel(id) { $0.removed = true }
    }
    func shiftLabel(_ id: UUID, seconds: Double) {
        editLabel(id) {
            $0.time = max(0, $0.time + seconds)
            if let anchor = $0.anchor { $0.anchor = max(0, anchor + seconds) }
        }
    }
    private func editLabel(_ id: UUID, edit: (inout Feedback) -> Void) {
        guard !learningBusy else { return }
        if let index = archive?.feedback.firstIndex(where: { $0.id == id }) {
            edit(&archive!.feedback[index]); archive!.feedback[index].predictedMark = nil; archive!.feedback[index].predictionModelID = nil; feedback = archive!.feedback; checkpoint(); return
        }
        guard !configurationLocked,
              let r = records.firstIndex(where: { $0.feedback.contains { $0.id == id } }),
              let i = records[r].feedback.firstIndex(where: { $0.id == id }) else { return }
        edit(&records[r].feedback[i]); records[r].feedback[i].predictedMark = nil; records[r].feedback[i].predictionModelID = nil
        feedback = records[r].feedback
        persistCorrection(records[r])
    }
    private func persistCorrection(_ record: SessionRecord, invalidatesPriorLearning: Bool = true) {
        guard let store else { return }
        feedback = record.feedback
        var updated = profiles
        if invalidatesPriorLearning, var p = updated[record.profile] {
            p.active = p.baseline; p.candidate = nil; p.candidateVersion = nil; p.frozen = true
            p.markModel = nil; updated[p.key] = p
        }
        let history = records, shouldLearn = storedPreferences.learning
        learningBusy = true
        disk.async { [weak self, updated] in
            do {
                var next = updated
                if let p = next[record.profile], shouldLearn || invalidatesPriorLearning {
                    next[p.key] = try Learner.update(p, records: history)
                }
                try store.save(record); try store.save(profiles: next)
                let accepted = next
                Task { @MainActor in
                    self?.profiles = accepted; self?.learningBusy = false; self?.refreshEvidence()
                    self?.message = invalidatesPriorLearning ? "Report corrected. Tuning paused; review and resume it when ready." : "Review saved and learning updated."
                }
            } catch { Task { @MainActor in self?.learningBusy = false; self?.storageFailed(error.localizedDescription) } }
        }
    }
    private func checkpoint() {
        guard !checkpointInFlight, let record = archive, let store else { return }
        checkpointInFlight = true
        disk.async { [weak self] in
            let failure: String?
            do { try store.save(record); failure = nil }
            catch { failure = error.localizedDescription }
            Task { @MainActor in
                self?.checkpointInFlight = false
                if let failure { self?.storageFailed(failure) }
            }
        }
    }
    private func storageFailed(_ reason: String) {
        storageError = reason
        if isArmed || isStarting { trip("Local recording failed: \(reason)") }
        else { message = "Local recording failed: \(reason)" }
    }
    private func finishSession(eligible: Bool) {
        guard var record = archive, let store else { return }
        record.complete = true; record.eligible = record.eligible && eligible
        archive = nil; recordingEnabled = false; finishAt = nil; isFinishing = false; learningBusy = true
        let currentProfiles = profiles
        disk.async { [weak self] in
            do {
                try store.save(record)
                let records = try store.sessions()
                var nextProfiles = currentProfiles
                if let profile = nextProfiles[record.profile] { nextProfiles[record.profile] = try Learner.update(profile, records: records) }
                let resultProfiles = nextProfiles
                Task { @MainActor in
                    guard let self else { return }
                    let accepted = self.storedPreferences.learning ? resultProfiles : currentProfiles
                    self.records = records; self.profiles = accepted; self.refreshEvidence()
                    self.disk.async { [weak self] in
                        do {
                            try store.save(profiles: accepted)
                            Task { @MainActor in
                                self?.learningBusy = false
                                if self?.fault == nil { self?.message = "Session saved. Any validated adjustment applies at the next start." }
                            }
                        } catch { Task { @MainActor in self?.learningBusy = false; self?.storageFailed(error.localizedDescription) } }
                    }
                }
            } catch {
                Task { @MainActor in self?.learningBusy = false; self?.storageFailed(error.localizedDescription) }
            }
        }
    }
    private func refreshEvidence() {
        let recent = Array(records.filter { $0.profile == profileKey }.suffix(20))
        markEvidence = Learner.markEvidence(recent)
        evidence = Learner.evidence(recent, settings: profile.active)
        let prospective = Learner.evidence(recent.filter { $0.settings != profile.active }, settings: profile.active, shadow: true)
        for signal in Signal.allCases {
            guard let extra = prospective[signal], var current = evidence[signal] else { continue }
            current.matches += extra.matches; current.contradictions += extra.contradictions
            current.positives += extra.positives; current.corrections += extra.corrections
            current.sessions.formUnion(extra.sessions); evidence[signal] = current
        }
        buildup = Learner.buildupObservations(recent, settings: profile.active)
    }
    func toggleLearning() {
        preferences.learning.toggle(); storedPreferences.learning = preferences.learning
        if !preferences.learning { archive?.eligible = false; recordingEnabled = false }
        do { try store?.save(storedPreferences) } catch { storageFailed(error.localizedDescription) }
        message = preferences.learning ? "Learning enabled for the next session." : "Learning paused. Existing control settings remain active."
    }
    func revertTuning() {
        guard !configurationLocked, !pressureThresholdsLocked, var p = profiles[profileKey], let last = p.history.last, p.active == last.to else { return }
        p.active = last.from; p.candidate = nil; p.candidateVersion = nil; p.frozen = true; profiles[p.key] = p
        do { try store?.save(profiles: profiles); refreshEvidence(); message = "Reverted the last adjustment; automatic tuning is paused." }
        catch { storageFailed(error.localizedDescription) }
    }
    func resumeTuning() {
        guard !configurationLocked, !pressureThresholdsLocked, var p = profiles[profileKey] else { return }
        p.frozen = false
        do {
            var updated = profiles; updated[p.key] = try Learner.update(p, records: records)
            try store?.save(profiles: updated); profiles = updated; refreshEvidence()
            message = "Learning resumed using usable saved reports."
        } catch { storageFailed(error.localizedDescription) }
    }
    func deleteHistory() {
        guard !configurationLocked, !pressureThresholdsLocked, let store else { return }
        learningBusy = true
        disk.async { [weak self] in
            do {
                try store.deleteLearningHistory()
                Task { @MainActor in
                    self?.records = []; self?.profiles = [:]; self?.feedback = []; self?.learningBusy = false
                    self?.refreshEvidence(); self?.message = "Learning history deleted; manual baseline restored."
                }
            } catch { Task { @MainActor in self?.learningBusy = false; self?.storageFailed(error.localizedDescription) } }
        }
    }
    func setUSBDebugLogging(_ enabled: Bool) {
        usb.debugLog.setEnabled(enabled, context: usbDebugContext)
    }
    func exportUSBDebugLog() {
        guard !debugExportBusy, let directory = store?.directory else { return }
        debugExportBusy = true; debugExportMessage = "Exporting…"
        Task {
            defer { debugExportBusy = false }
            do {
                let folder = try await usb.debugLog.export(to: directory.appendingPathComponent("arduino-debug"), context: usbDebugContext)
                debugExportMessage = "Exported HANDOFF.md, context.json and trace.jsonl."
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch { debugExportMessage = "Debug export failed: \(error.localizedDescription)" }
        }
    }
    func revealData() { if let directory = store?.directory { NSWorkspace.shared.open(directory) } }
    func setXToysEnabled(_ enabled: Bool) {
        guard !configurationLocked, useUSB else { return }
        if enabled {
            do { try xtoys.start(); try xtoysM3.start(port: 48972) }
            catch { xtoys.stop(); xtoysM3.stop(); message = "Could not start XToys control: \(error.localizedDescription)" }
        } else { xtoys.stop(); xtoysM3.stop() }
        objectWillChange.send()
    }
    private func exportXToysTelemetry(at time: Double) {
        guard xtoysExport.enabled else { return }
        let permitted = !pressurePaused && fault == nil && (!useUSB || usb.pressureSafetyPause == nil) &&
            (lastControlSnapshot.wantsPower || (automaticEdgingFinished && !explicitCooldown))
        xtoysExport.publish(XToysTelemetry(sample: sample, snapshot: lastControlSnapshot, settings: controllerSettings,
            baseline: baseline, gain: storedPreferences.gain, now: time, calibrated: calibrated,
            armed: isArmed, permitted: permitted, automaticCutoffs: !automaticEdgingFinished, simulated: useDemo), at: time)
    }
    func shutdown() async {
        xtoysExport.stop()
        cancelUSBReconnect()
        timer?.invalidate(); timer = nil; disarm(closingApp: true)
        if useUSB { try? await usb.stop() }
        preferenceSaveTask?.cancel()
        do { try store?.save(storedPreferences) } catch { log("Could not save final preferences.") }
        if var record = archive, let store {
            record.complete = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                disk.async { do { try store.save(record) } catch { NSLog("Perifit Edge could not save its final local archive.") }; continuation.resume() }
            }
        }
        xtoys.stop(); xtoysM3.stop(); usb.disconnect(); bluetooth.disconnect()
    }
}
