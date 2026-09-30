import AppKit
import SwiftUI
import PerifitCore
import Darwin

@main
struct SmokeCheck {
    @MainActor static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AppError.invalid(message) }
    }
    @MainActor static func waitFor(_ message: String, seconds: Double = 4, condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= end { throw AppError.invalid(message) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    @MainActor static func pressureFeed(_ model: SessionModel) -> Task<Void, Never> {
        Task { @MainActor in
            var tick = 0
            while !Task.isCancelled {
                model.bluetooth.receivePacket(Data([3, UInt8(232 + tick % 2), 2, UInt8(188 + tick % 2)]))
                tick += 1
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
    @MainActor static func verifyPressureDeliveryDuringTracking() throws {
        let probe = BluetoothInput()
        DispatchQueue.global().async { probe.deliver { probe.receivePacket(Data([3, 232, 2, 188])) } }
        let deadline = Date().addingTimeInterval(0.5)
        while probe.packetCount == 0 && Date() < deadline {
            _ = RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
        }
        try require(probe.packetCount == 1, "Pressure delivery stalled during UI event tracking")
    }
    @MainActor static func verifyFullChartRendering(_ model: SessionModel, content: NSView) async throws {
        let points = [ChartPoint(id: 10, segment: 0, base: 0, tip: 0, pressure: 0, score: 0),
                      ChartPoint(id: 20, segment: 0, base: 50, tip: 0, pressure: 0, score: 0),
                      ChartPoint(id: 30, segment: 1, base: 100, tip: 0, pressure: 0, score: 0)]
        let path = LivePlot.signalPath(points, value: \.base, start: 10, end: 30,
                                       maximum: 100, size: CGSize(width: 200, height: 100))
        var moves = 0, vertices: [CGPoint] = []
        path.forEach {
            switch $0 {
            case .move(let point): moves += 1; vertices.append(point)
            case .line(let point): vertices.append(point)
            default: break
            }
        }
        try require(moves == 2 && vertices == [CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 50), CGPoint(x: 200, y: 0)],
                    "Chart scaling changed or bridged a missing-pressure segment")
        model.chart = (0..<600).map { index in
            ChartPoint(id: Double(index) / 10, segment: index < 300 ? 0 : 1,
                       base: 1000 + 300 * sin(Double(index) / 10), tip: 700,
                       pressure: 300, score: 200)
        }
        defer { model.chart = [] }
        var durations: [Double] = []
        for _ in 0..<30 {
            // Exercise the full production UI at its maximum chart history.
            model.chart[599] = ChartPoint(id: 59.9, segment: 1, base: 1000, tip: 700,
                                         pressure: 300, score: 200)
            let began = ProcessInfo.processInfo.systemUptime
            content.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            durations.append(ProcessInfo.processInfo.systemUptime - began)
        }
        let median = durations.sorted()[durations.count / 2], worst = durations.max()!
        print("Main-thread scheduling with full 600-point chart: median \(median)s, worst \(worst)s")
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let screenshot = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("full-chart-smoke.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: screenshot)
        }
        try require(median < 0.05 && worst < 0.25, "Live chart rendering starved the controller")
    }
    @MainActor static func verifyWorkspaceTabs(_ model: SessionModel, content: NSView) async throws {
        func segment(_ view: NSView, label: String) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl, control.segmentCount > 0, control.label(forSegment: 0) == label { return control }
            for child in view.subviews { if let found = segment(child, label: label) { return found } }
            return nil
        }
        func tabView(in view: NSView) -> NSSegmentedControl? {
            if let tabs = view as? NSSegmentedControl, tabs.segmentCount == 2,
               tabs.label(forSegment: 0) == "Main", tabs.label(forSegment: 1) == "Config" { return tabs }
            for child in view.subviews { if let tabs = tabView(in: child) { return tabs } }
            return nil
        }
        content.layoutSubtreeIfNeeded()
        guard let tabs = tabView(in: content) else { throw AppError.invalid("Workspace tabs were not rendered") }
        try require(tabs.selectedSegment == 0,
                    "Main was not the default workspace")
        let baseline = model.baseline, latestTime = model.chart.last?.id ?? 0
        guard let signals = segment(content, label: "Both pressure channels"), let seconds = segment(content, label: "20s") else {
            throw AppError.invalid("Chart controls missing")
        }
        signals.selectedSegment = 1; signals.sendAction(signals.action, to: signals.target)
        seconds.selectedSegment = 0; seconds.sendAction(seconds.action, to: seconds.target)
        for index in [1, 0] {
            tabs.selectedSegment = index
            tabs.sendAction(tabs.action, to: tabs.target)
            try await Task.sleep(for: .milliseconds(150))
            content.layoutSubtreeIfNeeded()
            if index == 1 { try require(segment(content, label: "Both pressure channels") == nil, "Hidden Main workspace still mounted") }
            else {
                try require(segment(content, label: "Both pressure channels")?.selectedSegment == 1 &&
                            segment(content, label: "20s")?.selectedSegment == 0, "Tab switch reset chart choices")
            }
            try require(tabs.selectedSegment == index && model.isArmed && model.calibrated && model.baseline == baseline && (model.chart.last?.id ?? 0) >= latestTime,
                        "Changing tabs reset or stopped the controller")
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let file = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
                    .appendingPathComponent(index == 1 ? "config-tab-smoke.png" : "main-tab-smoke.png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: file)
            }
        }
        print("PASS Main default, Config/Main tab switching during an armed session, calibration and controller continuity")
    }
    @MainActor static func verifyInputOutputWindows(directory: URL) async throws {
        let folder = directory.appendingPathComponent("io-windows")
        let model = SessionModel(dataDirectory: folder)
        model.selectInput(demo: false); model.selectOutput(.arduino)
        let views = (0..<2).map { _ in NSHostingView(rootView: MainView(model: model).frame(width: 1180, height: 900)) }
        let windows = views.map { view in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.ignoresMouseEvents = true; return window
        }
        func picker(in view: NSView, containing title: String) -> NSPopUpButton? {
            if let picker = view as? NSPopUpButton, picker.itemTitles.contains(title) { return picker }
            for child in view.subviews { if let found = picker(in: child, containing: title) { return found } }
            return nil
        }
        for view in views { view.layoutSubtreeIfNeeded() }
        try await Task.sleep(for: .milliseconds(150))
        for view in views {
            try require(picker(in: view, containing: "Perifit")?.titleOfSelectedItem == "Perifit" &&
                        picker(in: view, containing: OutputDestination.arduino.title)?.titleOfSelectedItem == OutputDestination.arduino.title,
                        "An open window lost the selected input/output")
        }
        guard let output = picker(in: views[0], containing: OutputDestination.simulation.title) else {
            throw AppError.invalid("Visible output selector missing")
        }
        output.selectItem(withTitle: OutputDestination.simulation.title)
        output.menu?.performActionForItem(at: output.indexOfSelectedItem)
        try await Task.sleep(for: .milliseconds(150))
        try require(model.output == .simulation && views.allSatisfy {
            picker(in: $0, containing: OutputDestination.simulation.title)?.titleOfSelectedItem == OutputDestination.simulation.title
        }, "Input/output selection did not synchronize across windows: model=\(model.output), windows=\(views.map { picker(in: $0, containing: OutputDestination.simulation.title)?.titleOfSelectedItem ?? "missing" })")
        model.calibrated = true
        model.selectInput(demo: false); model.selectOutput(.simulation)
        try require(model.calibrated, "Reselecting the same source reset calibration")
        model.isArmed = true
        model.selectInput(demo: true); model.selectOutput(.arduino)
        try require(!model.useDemo && model.output == .simulation, "Locked source selection changed during a session")
        model.isArmed = false
        await model.shutdown(); windows.forEach { $0.close() }
        let reopened = SessionModel(dataDirectory: folder)
        try require(!reopened.useDemo && reopened.output == .simulation && !reopened.isArmed &&
                    !reopened.usb.connected, "Reopen lost source choices or reactivated output")
        await reopened.shutdown()
        let legacyFolder = directory.appendingPathComponent("io-legacy"), store = try LocalStore(directory: legacyFolder)
        var record = SessionRecord(profile: "legacy", simulated: false, settings: EngineSettings(), candidate: nil, seed: 1, baseline: 1000, gain: 1)
        record.complete = true; record.outputTransport = "arduino"; try store.save(record)
        let migrated = SessionModel(dataDirectory: legacyFolder)
        try require(migrated.output == .arduino && !migrated.isArmed && !migrated.usb.connected &&
                    (try store.preferences()).lastOutput == .arduino, "Previous recorded output was not restored safely")
        await migrated.shutdown()
        print("PASS input/output visible in both windows, synchronized selection, no-op selection, armed guards, saved reopen and legacy output recovery without connection/arming")
    }
    @MainActor static func verifyFinder(directory: URL) async throws {
        let model = SessionModel(dataDirectory: directory.appendingPathComponent("finder"))
        model.finderEnabled = true; model.finderMotors = [0, 2]
        try require(model.startBlockedReason?.contains("target ceilings") == true, "Finder accepted zero targets")
        for index in 0..<3 { model.setVibrationTarget(channel: index, value: 30) }
        model.calibrated = true; model.baseline = 1000
        try await Task.sleep(for: .milliseconds(100))
        model.start()
        try await waitFor("Finder did not start in simulation") { model.isArmed && model.finderRunning }
        try require(model.activeVibrationSettings.two.target == 0 && model.vibrationRequested.two == 0,
                    "Finder energized an unselected channel")
        try require(model.canEditAutomaticCutoffs, "Finder did not allow a finish limit")
        // Synthetic scores exercise integration without physical devices or forty seconds of waiting.
        for level in 1...4 {
            let start = 100 + Double((level - 1) * 11)
            try model.advanceFinder(score: 20, time: start - 0.1, permitted: false)
            for step in 0...100 {
                try model.advanceFinder(score: 20 + Double(level * step) / 10, time: start + Double(step) / 10,
                                        permitted: true)
            }
        }
        try require(model.finderLearning && !model.finderStatus.contains("ramp-down"), "Finder ramped down before the no-improvement plateau")
        for trial in 0..<20 {
            let start = 144 + Double(trial * 11)
            try model.advanceFinder(score: 20, time: start - 0.1, permitted: false)
            for step in 0...100 { try model.advanceFinder(score: 20, time: start + Double(step) / 10, permitted: true) }
        }
        try require(model.finderLearning && model.finderStatus.contains("ramp-down"), "Finder did not begin the downward test after 20 trials")
        for step in 1...102 { try model.advanceFinder(score: 20 - Double(step) / 10, time: 363 + Double(step) / 10, permitted: true) }
        try model.advanceFinder(score: 0, time: 373.3, permitted: false)
        try require(model.isArmed && model.finderRunning && !model.finderLearning && model.finderResults.contains { $0.descent != nil },
                    "Finder did not transition from ramp-down measurement to maintenance")
        let savedCount = model.finderResults.count
        try await Task.sleep(for: .milliseconds(10300))
        try require(model.finderResults.contains { ($0.validationCount ?? 0) > 0 },
                    "Finder stopped validating rates after initial training")
        try require(model.preferences.effectiveVibration.two.target == 30, "Finder overwrote saved motor settings")
        let content = NSHostingView(rootView: MainView(model: model).frame(width: 1180, height: 900))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content; window.ignoresMouseEvents = true
        func tabs(_ view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl, control.segmentCount == 2, control.label(forSegment: 1) == "Config" { return control }
            for child in view.subviews { if let found = tabs(child) { return found } }
            return nil
        }
        for (index, name) in [(0, "finder-main-smoke.png"), (1, "finder-config-smoke.png")] {
            content.layoutSubtreeIfNeeded()
            guard let tab = tabs(content) else { throw AppError.invalid("Finder Config tab missing") }
            tab.selectedSegment = index; tab.sendAction(tab.action, to: tab.target)
            try await Task.sleep(for: .milliseconds(100)); content.layoutSubtreeIfNeeded()
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let url = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent(name)
                try bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        await model.shutdown(); window.close()
        let reopened = SessionModel(dataDirectory: directory.appendingPathComponent("finder"))
        reopened.finderMotors = [0, 2]
        try require(reopened.finderResults.count == savedCount && reopened.finderResults.contains { $0.descent != nil } &&
                    reopened.finderResults.contains { ($0.validationCount ?? 0) > 0 } && !reopened.isArmed,
                    "Finder rise/down library did not survive reopening safely")
        reopened.finderEnabled = true; reopened.calibrated = true; reopened.baseline = 1000
        try await Task.sleep(for: .milliseconds(100)); reopened.start()
        try await waitFor("Completed Finder training did not resume maintenance") { reopened.isArmed && reopened.finderRunning && !reopened.finderLearning }
        await reopened.shutdown()
        print("PASS Finder selected motors, 20-trial plateau, ramp-down measurement, continuing live rate validation, persistent library and Config table")
    }
    @MainActor static func verifyManualFinderEnd(directory: URL) async throws {
        let model = SessionModel(dataDirectory: directory.appendingPathComponent("finder-manual-end"))
        model.finderEnabled = true; model.finderMotors = [0]
        model.setVibrationTarget(channel: 0, value: 30)
        model.lockPressureThresholds()
        try require(model.setTimedEdging(seconds: 20), "Manual Finder timer setup failed")
        model.lockTimedEdging(); model.lockAutomaticCutoffs(10)
        model.calibrated = true; model.baseline = 1000
        try await Task.sleep(for: .milliseconds(100))
        model.start(); try await waitFor("Manual Finder fixture failed to start") { model.isArmed && model.finderSearching }
        let content = NSHostingView(rootView: MainView(model: model).frame(width: 1180, height: 1100))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content; window.ignoresMouseEvents = true
        content.layoutSubtreeIfNeeded()
        try require(!model.canEndFinderLearning, "Empty Finder learning could be ended without a pattern")
        model.endFinderLearning()
        try require(model.finderSearching && model.finderWaitingForSession, "Empty manual completion started the timer")
        try await waitFor("Finder did not finish a trial for manual completion", seconds: 15) { model.canEndFinderLearning }
        model.edgeCount = 5
        try await Task.sleep(for: .milliseconds(100)); content.layoutSubtreeIfNeeded()
        try require(model.canEndFinderLearning && model.finderTrainingLocked && model.timedEdgingLocked, "Locks incorrectly disabled the End learning action")
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let image = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("finder-manual-end-smoke.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: image)
        }
        model.endFinderLearning()
        try require(model.finderLearning && !model.finderSearching && !model.finderWaitingForSession && model.automaticCutoffsSoFar == 0,
                    "End learning did not start ramp-down and the session")
        model.edgeCount = 6
        try await Task.sleep(for: .milliseconds(1200))
        let elapsed = model.timedEdging!.elapsedSeconds
        try require(elapsed >= 1 && elapsed < 3 && model.finderLearning && model.automaticCutoffsSoFar == 1,
                    "Manual session timer/count waited for the fall-rate test")
        try model.advanceFinder(score: 20, time: 199.9, permitted: false)
        for step in 0...102 { try model.advanceFinder(score: 20 - Double(step) / 10, time: 200 + Double(step) / 10, permitted: true) }
        try model.advanceFinder(score: 0, time: 210.3, permitted: false)
        try require(!model.finderLearning && model.finderRunning && model.timedEdging!.elapsedSeconds >= elapsed && model.automaticCutoffsSoFar == 1,
                    "Completing fall-rate measurement restarted the manual session timer/count")
        model.stop(); await model.shutdown(); window.close()
        print("PASS manual Finder completion: empty-state guard, allowed under both locks, fall-rate test, immediate timer/count and no restart on completion")
    }
    @MainActor static func verifyBestPatternAfterLearning(directory: URL) async throws {
        let folder = directory.appendingPathComponent("finder-best")
        let model = SessionModel(dataDirectory: folder)
        model.finderEnabled = true; model.finderTargetLevel = 1
        model.setVibrationTarget(channel: 0, value: 30)
        model.setFinderBestPatternOnly(true)
        model.calibrated = true; model.baseline = 1000
        try require(model.lockFinderSetup(), "Best pattern training setup failed")
        try await Task.sleep(for: .milliseconds(100)); model.start()
        try await waitFor("Best pattern mode skipped learning") { model.isArmed && model.finderSearching }
        try require(!model.canStartOrgasmMode, "Orgasm mode was available before any pattern was measured")
        try require(model.timedEdging == nil && !model.canEditAutomaticCutoffs && !model.canEditTimedEdging,
                    "Best mode enabled timer or count cycles")
        for trial in 0...20 {
            let start = 100.0 + Double(trial) * 11
            try model.advanceFinder(score: 20, time: start - 0.1, permitted: false)
            for tick in 0...100 {
                try model.advanceFinder(score: 20 + (trial == 0 ? Double(tick) / 10 : 0),
                                        time: start + Double(tick) / 10, permitted: true)
            }
        }
        try require(!model.finderLearning && !model.finderSearching && model.isArmed && !model.finderResults.isEmpty,
                    "Final plateau did not enter best pattern mode")
        let best = model.activeVibrationSettings
        try require(best.one.target > 0 && best.two.target == 0 && best.three.target == 0, "Best pattern lost motor selection")
        try model.advanceFinder(score: 759, time: 400, permitted: true)
        try require(model.activeVibrationSettings == best, "Best mode resumed edging patterns")
        model.lockPressureThresholds()
        try require(model.canStartOrgasmMode, "Threshold locking blocked manual Orgasm mode")
        model.startOrgasmMode()
        try require(model.orgasmMode && !model.usesOrgasmPreset && model.activeVibrationSettings == best && !model.canStartOrgasmMode,
                    "Manual Orgasm mode did not retain the learned pattern")
        model.stop(); await model.shutdown()
        let reopened = SessionModel(dataDirectory: folder)
        reopened.calibrated = true; reopened.baseline = 1000
        try require(reopened.finderBestPatternOnly && reopened.hasSavedFinderProgress && reopened.timedEdging == nil,
                    "Best mode or training lost across restart")
        try await Task.sleep(for: .milliseconds(100)); reopened.start()
        try await waitFor("Completed best training did not resume") { reopened.isArmed }
        try require(!reopened.finderLearning && !reopened.orgasmMode && reopened.activeVibrationSettings == best,
                    "Reopening restarted completed training or retained the manual cutoff bypass")
        reopened.stop(); await reopened.shutdown()

        let locked = SessionModel(dataDirectory: directory.appendingPathComponent("best-timer-lock"))
        locked.finderEnabled = true; locked.setVibrationTarget(channel: 0, value: 30)
        locked.lockPressureThresholds()
        try require(locked.setTimedEdging(seconds: 60), "Timer lock fixture failed")
        locked.lockTimedEdging(); locked.setFinderBestPatternOnly(true)
        try require(locked.timedEdgingLocked && !locked.finderBestPatternOnly, "Best mode bypassed an unfinished timer lock")
        await locked.shutdown()
        print("PASS learn first, final plateau to best pattern, selected motors, resume completed training, no timer/count, lock bypass rejected")
    }
    @MainActor static func verifyFinderTrainingResume(directory: URL) async throws {
        let folder = directory.appendingPathComponent("finder-resume")
        let model = SessionModel(dataDirectory: folder)
        model.finderEnabled = true; model.setVibrationTarget(channel: 0, value: 30)
        try require(model.lockFinderSetup(), "Training resume fixture did not lock")
        model.calibrated = true; model.baseline = 1000
        try await Task.sleep(for: .milliseconds(100)); model.start()
        try await waitFor("Training resume fixture did not start") { model.isArmed }
        try model.advanceFinder(score: 100, time: 99.9, permitted: false)
        for tick in 0...100 { try model.advanceFinder(score: 100 + Double(tick) / 5, time: 100 + Double(tick) / 10, permitted: true) }
        try model.advanceFinder(score: 120, time: 110.1, permitted: false)
        try model.advanceFinder(score: 120, time: 110.2, permitted: true)
        model.startOrgasmMode()
        try require(model.orgasmMode && !model.finderRunning, "Manual Orgasm mode could not use a learned pattern during training")
        model.stop(); await model.shutdown()
        let saved = try LocalStore(directory: folder).preferences().finderProgress!.values.first!
        try require(saved.running && saved.results.count == 1, "Stop followed by quit erased unfinished training")
        let reopened = SessionModel(dataDirectory: folder)
        reopened.calibrated = true; reopened.baseline = 1000
        try require(!reopened.isArmed && reopened.finderTrainingLocked && reopened.hasSavedFinderProgress, "Reopening lost saved locked training or armed outputs")
        try await Task.sleep(for: .milliseconds(100)); reopened.start()
        try await waitFor("Saved training did not resume its completed level") { reopened.isArmed && reopened.finderStatus.contains("level 2/4") }
        reopened.resetFinderProgress()
        try require(reopened.hasSavedFinderProgress, "Locked running training could be reset")
        reopened.stop(); await reopened.shutdown()
        print("PASS training progress survives Stop/quit/reopen, resumes level 2, rejects reset under locks and never auto-arms")
    }
    @MainActor static func verifyLibraryMigration(directory: URL) async throws {
        let store = try LocalStore(directory: directory.appendingPathComponent("library-migration"))
        var settings = VibrationSettings(); settings.one.target = 30
        var preferences = Preferences()
        preferences.finderLibrary = ["old-setup": (1...64).map {
            FinderResult(level: 1, trial: $0, settings: settings, startScore: 0,
                         endScore: Double($0 * 10), seconds: 10, rate: Double($0))
        }]
        try store.save(preferences)
        let model = SessionModel(dataDirectory: store.directory)
        try require(model.preferences.finderLibrary?["old-setup"]?.count == 15 &&
                    (try store.preferences()).finderLibrary?["old-setup"]?.count == 15, "Old library was not pruned and saved")
        model.selectOutput(.arduino); model.isArmed = true
        model.usb.onFault?("Injected controller stall diagnostic")
        let diagnostic = store.directory.appendingPathComponent("last-controller-fault.json")
        try await waitFor("Controller fault reason was not persisted") { FileManager.default.fileExists(atPath: diagnostic.path) }
        let details = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: diagnostic))
        try require(!model.isArmed && details["reason"] == "Injected controller stall diagnostic" &&
                    details["controllerGapSeconds"].flatMap(Double.init) != nil && details["pressureAgeSeconds"] != nil,
                    "Controller diagnostic lost timing or bypassed disarming")
        await model.shutdown()
        print("PASS existing pattern library pruned to 15 and persisted; controller fault reason/timing saved after disarming")
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perifit-smoke-" + UUID().uuidString)
        let model = SessionModel(dataDirectory: directory)
        let content = NSHostingView(rootView: MainView(model: model).frame(width: 1180, height: 900))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Perifit Edge · isolated software check"
        window.contentView = content
        // Render our own view; no desktop capture or control of other apps.
        window.ignoresMouseEvents = true // Render offscreen; do not expose test controls on the user's desktop.
        Task { @MainActor in
            do {
                try verifyPressureDeliveryDuringTracking()
                print("PASS Bluetooth pressure delivery during UI tracking")
                try await verifyFullChartRendering(model, content: content)
                try await verifyInputOutputWindows(directory: directory)
                try await verifyLibraryMigration(directory: directory)
                try await verifyFinder(directory: directory)
                try await verifyFinderTrainingResume(directory: directory)
                try await verifyBestPatternAfterLearning(directory: directory)
                try await verifyManualFinderEnd(directory: directory)
                let thresholdDirectory = directory.appendingPathComponent("thresholds")
                let thresholds = SessionModel(dataDirectory: thresholdDirectory)
                thresholds.preferences.baselineSettings.edgeTarget = 420
                thresholds.preferences.baselineSettings.sensitivity = 900
                try require(thresholds.savePreferences() && thresholds.profile.active.effectiveEdgeTarget == 420 && thresholds.profile.active.sensitivity == 900,
                            "Manual Edge/cutoff thresholds did not become active")
                try require(thresholds.setPressureThresholds(edge: 430, cutoff: 910), "Live baseline edit failed")
                thresholds.lockPressureThresholds()
                thresholds.preferences.baselineSettings.edgeTarget = 440
                try require(!thresholds.setPressureThresholds(edge: 440, cutoff: 910) && !thresholds.savePreferences(),
                            "Threshold lock was bypassed through another settings path")
                try require(thresholds.setAutomaticCutoffLimit(2), "Threshold lock incorrectly locked the count")
                thresholds.lockAutomaticCutoffs(2)
                try require(!thresholds.setAutomaticCutoffLimit(3), "Count lock failed")
                await thresholds.shutdown()
                let restoredThresholds = SessionModel(dataDirectory: thresholdDirectory)
                try require(restoredThresholds.preferences.baselineSettings.effectiveEdgeTarget == 430 && restoredThresholds.profile.active.sensitivity == 910 &&
                            !restoredThresholds.pressureThresholdsLocked && !restoredThresholds.automaticCutoffCountLocked,
                            "Manual thresholds did not survive reopening")
                restoredThresholds.preferences.baselineSettings.edgeTarget = 911
                try require(!restoredThresholds.savePreferences(), "Inverted pressure thresholds were accepted")
                try require(try LocalStore(directory: thresholdDirectory).preferences().baselineSettings.effectiveEdgeTarget == 430,
                            "Invalid thresholds overwrote saved settings")
                await restoredThresholds.shutdown()
                print("PASS manual controller thresholds: activation, validation and persistence")
                model.calibrate()
                try await waitFor("Demo calibration failed: \(model.message)", seconds: 7) { model.calibrated }
                model.demoPattern = "Rest"
                model.start()
                try await waitFor("Demo failed to arm: \(model.message)") { model.isArmed }
                try await verifyWorkspaceTabs(model, content: content)
                if CommandLine.arguments.contains("--tabs-only") {
                    model.stop(); await model.shutdown()
                    try FileManager.default.removeItem(at: directory)
                    window.close(); exit(0)
                }
                try await Task.sleep(for: .seconds(1.6))
                try require(model.isArmed, "Demo unexpectedly disarmed: \(model.fault ?? model.message)")
                model.label(.closer)
                model.label(.edge)
                try require(model.isArmed && model.reportedPower == true, "Edge must preserve power in the target zone")
                model.label(.tooClose)
                try await Task.sleep(for: .milliseconds(200))
                try require(model.isArmed && model.reportedPower == false && model.snapshot.controlPhase == 1, "Too close failed to enter cooldown")
                try await waitFor("Cooldown failed to resume after risk cleared", seconds: 8) { model.reportedPower == true }
                model.demoPattern = "Waves"
                try await waitFor("Rising risk failed to cut power", seconds: 5) { model.edgeCount > 0 && model.reportedPower == false }
                model.label(.orgasm)
                try require(!model.isArmed && model.reportedPower == false, "Orgasm failed to disarm")
                try await waitFor("Session did not finish", seconds: 8) { !model.isFinishing && !model.learningBusy }
                let store = try LocalStore(directory: directory)
                let records = try store.sessions()
                try require(records.count == 1 && records[0].complete && records[0].simulated, "Demo archive incorrect")
                let record = records[0]
                let replay = try Learner.replay(record, with: record.settings)
                let diffs = zip(record.frames, replay.frames).filter { $0.active != $1.active }.count
                try require(diffs == 0, "Live-clock replay differed at \(diffs) frames")
                try require(model.chart.count > 20 && model.feedback.count == 4, "Streaming graph or labels missing")
                content.layoutSubtreeIfNeeded()
                guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw AppError.invalid("Cannot render application view") }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError.invalid("Cannot encode UI render") }
                try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
                model.removeLabel(model.feedback[0].id)
                try await waitFor("Historical correction failed") { !model.learningBusy }
                let corrected = try store.sessions()[0]
                try require(corrected.feedback[0].removed && corrected.manualEdges.count == 1, "Correction rewrote physical actions")
                model.resumeTuning()
                try require(!model.profile.frozen, "Learning did not resume after correction")
                if model.hasCutoffToReview {
                    model.label(.aboutRight)
                    try await waitFor("Saved-session review failed") { !model.learningBusy }
                    try require(try store.sessions()[0].feedback.contains { $0.kind == .aboutRight }, "Late cutoff review was not saved")
                    try require(!model.profile.frozen, "Adding a new review incorrectly froze learning")
                }
                print("PASS native demo: Edge stays ON, Too close/automatic risk cut OFF, quiet cooldown resumes, Orgasm disarms, graph, exact replay")

                let pressureDirectory = directory.appendingPathComponent("pressure-only")
                let pressureModel = SessionModel(dataDirectory: pressureDirectory)
                let pressureDevice = UUID(), pressureChoice = CharacteristicChoice(service: "AA40", characteristic: "AA41")
                pressureModel.bluetooth.connectedID = pressureDevice
                pressureModel.bluetooth.choices = [pressureChoice]; pressureModel.bluetooth.selectedCharacteristic = pressureChoice.id
                pressureModel.useDemo = false; pressureModel.inputChanged()
                try require(!pressureModel.feedbackEnabled && pressureModel.startBlockedReason?.contains("Calibrate") == true,
                            "Missing feedback did not explain calibration prerequisite")
                var feed = pressureFeed(pressureModel)
                try await Task.sleep(for: .milliseconds(100))
                pressureModel.calibrate()
                try await waitFor("Sensor-only baseline failed", seconds: 7) { pressureModel.calibrated }
                pressureModel.start()
                try await waitFor("Sensor-only session failed to start") { pressureModel.isArmed }
                try require(pressureModel.recordingOnly && pressureModel.feedbackEnabled, "Sensor-only feedback unavailable")
                pressureModel.label(.edge)
                usleep(400_000)
                try await Task.sleep(for: .milliseconds(150))
                try require(pressureModel.isArmed && pressureModel.calibrated && pressureModel.feedbackEnabled,
                            "UI pause stopped sensor-only recording or discarded calibration")
                feed.cancel()
                try await waitFor("Missing samples were not marked", seconds: 5) { pressureModel.pressurePaused }
                let count = pressureModel.chart.count
                pressureModel.label(.edge)
                try await Task.sleep(for: .milliseconds(150))
                try require(pressureModel.feedback.count == 2 && pressureModel.chart.count == count && pressureModel.isArmed,
                            "Missing samples fabricated readings or disabled feedback")
                feed = pressureFeed(pressureModel)
                try await waitFor("Pressure did not resume without recalibration") { !pressureModel.pressurePaused && pressureModel.chart.count > count }
                pressureModel.label(.edge)
                let pressureView = NSHostingView(rootView: MainView(model: pressureModel).frame(width: 1180, height: 900))
                window.contentView = pressureView; pressureView.layoutSubtreeIfNeeded()
                if let bitmap = pressureView.bitmapImageRepForCachingDisplay(in: pressureView.bounds) {
                    pressureView.cacheDisplay(in: pressureView.bounds, to: bitmap)
                    let path = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("pressure-only-smoke.png")
                    try bitmap.representation(using: .png, properties: [:])?.write(to: path)
                }
                try await Task.sleep(for: .seconds(3.4))
                pressureModel.label(.edge)
                pressureModel.stop()
                try await waitFor("Pressure-only archive did not finish", seconds: 8) { !pressureModel.isFinishing && !pressureModel.learningBusy }
                let capture = try LocalStore(directory: pressureDirectory).sessions()[0]
                try require(capture.complete && !capture.simulated && capture.eligible && capture.feedback.count == 4,
                            "Pressure-only archive lost feedback or discarded clean sections")
                try require(Learner.pressureExamples([capture]).count == 1 && pressureModel.profile.pressureExamples?.count == 1,
                            "Learning failed to keep the later clean mark and reject interrupted marks")
                try require((capture.recordingGaps?.count ?? 0) >= 2 && capture.recordingGaps?.contains { $0.reason == "Pressure readings missing" && $0.end != nil } == true,
                            "Recording gap metadata missing")
                let pressureReplay = try Learner.replay(capture, with: capture.settings)
                try require(zip(capture.frames, pressureReplay.frames).allSatisfy { $0.active == $1.active }, "Gap recording did not replay exactly")
                // Seed a second known pattern, then test the actual next-session prediction path.
                var orgasmExample = capture; orgasmExample.id = UUID()
                var orgasmLabel = capture.feedback.last!; orgasmLabel.id = UUID(); orgasmLabel.kind = .orgasm
                orgasmExample.feedback = [orgasmLabel]
                for i in orgasmExample.frames.indices {
                    orgasmExample.frames[i].base += 300; orgasmExample.frames[i].pressure += 300
                    orgasmExample.frames[i].tip += 100; orgasmExample.frames[i].active.score += 500
                }
                let pressureStore = try LocalStore(directory: pressureDirectory)
                try pressureStore.save(orgasmExample)
                let trained = try Learner.update(pressureModel.profile, records: [capture, orgasmExample])
                pressureModel.profiles[trained.key] = trained
                pressureModel.start()
                try await waitFor("Learned-pattern session did not start") { pressureModel.isArmed }
                try await Task.sleep(for: .seconds(3.4))
                pressureModel.label(.edge)
                try require(pressureModel.feedback.last?.predictedMark == .edge && pressureModel.feedback.last?.predictionModelID == trained.markModel?.id,
                            "New-session mark was not predicted from the prior learned model")
                pressureModel.stop()
                try await waitFor("Prediction session did not save", seconds: 8) { !pressureModel.isFinishing && !pressureModel.learningBusy }
                try require(Learner.markEvidence(try pressureStore.sessions())[.edge]!.matches == 1,
                            "Prospective recognition evidence did not persist")
                let savedBaseline = pressureModel.baseline
                feed.cancel(); await pressureModel.shutdown()
                let reopened = SessionModel(dataDirectory: pressureDirectory)
                try require(!reopened.useDemo && !reopened.calibrated && !reopened.isArmed && !reopened.canStart &&
                            reopened.preferences.pressureCalibration?.baseline == savedBaseline,
                            "Reopening lost calibration/input selection or restored readiness without fresh data")
                reopened.bluetooth.connectedID = UUID(); reopened.bluetooth.choices = [pressureChoice]
                reopened.bluetooth.selectedCharacteristic = pressureChoice.id
                reopened.bluetooth.receivePacket(Data([3, 232, 2, 188]))
                try require(!reopened.calibrated, "Another Perifit reused the saved baseline")
                reopened.bluetooth.connectedID = pressureDevice
                let wrongChoice = CharacteristicChoice(service: "AA40", characteristic: "AA42")
                reopened.bluetooth.choices = [wrongChoice]; reopened.bluetooth.selectedCharacteristic = wrongChoice.id
                reopened.bluetooth.receivePacket(Data([3, 232, 2, 188]))
                try require(!reopened.calibrated, "Another characteristic reused the saved baseline")
                reopened.bluetooth.choices = [pressureChoice]; reopened.bluetooth.selectedCharacteristic = pressureChoice.id
                reopened.bluetooth.onSample?(PressureSample(base: 1000, tip: 700, time: ProcessInfo.processInfo.systemUptime - 4))
                try require(!reopened.calibrated, "Stale data restored calibration")
                reopened.bluetooth.receivePacket(Data([3, 232, 2, 188]))
                try require(reopened.calibrated && reopened.calibrationRestored && reopened.baseline == savedBaseline && !reopened.isArmed,
                            "Matching fresh Perifit data failed to restore the saved baseline")
                reopened.inputChanged(); reopened.bluetooth.receivePacket(Data([3, 232, 2, 188]))
                try require(reopened.calibrated && reopened.baseline == savedBaseline, "Changing views/input state discarded the saved baseline")
                let legacyDirectory = directory.appendingPathComponent("legacy-calibration")
                let legacyStore = try LocalStore(directory: legacyDirectory)
                var legacyPrefs = try pressureStore.preferences(); legacyPrefs.pressureCalibration = nil
                legacyPrefs.verifiedPeripheral = pressureDevice.uuidString; legacyPrefs.verifiedService = pressureChoice.service
                legacyPrefs.verifiedCharacteristic = pressureChoice.characteristic
                try legacyStore.save(legacyPrefs); try legacyStore.save(capture)
                let migrated = SessionModel(dataDirectory: legacyDirectory)
                try require(migrated.preferences.pressureCalibration?.baseline == capture.baseline && !migrated.isArmed,
                            "Legacy matching-session calibration was not preserved")
                await migrated.shutdown()
                reopened.preferences.gain = 2; try require(reopened.savePreferences(), "Gain change failed")
                reopened.bluetooth.receivePacket(Data([3, 232, 2, 188]))
                try require(!reopened.calibrated, "A different gain reused the saved calibration")
                await reopened.shutdown()
                print("PASS Perifit calibration persistence: close/reopen, matching fresh input, mismatched identity/gain rejection and legacy recovery")
                print("PASS pressure-only recording: calibration guidance, UI stall survival, missing-data gap, live Edge labels, resume, archive and exact replay")

                await model.shutdown()
                try FileManager.default.removeItem(at: directory)
                window.close()
                exit(0)
            } catch {
                fputs("Smoke check failed: \(error.localizedDescription)\n", stderr)
                await model.shutdown()
                fputs("Isolated archive: \(directory.path)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }
}
