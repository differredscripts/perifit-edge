import AppKit
import SwiftUI
import PerifitCore
import Darwin

@main
struct USBProbe {
    @MainActor static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AppError.invalid(message) }
    }
    @MainActor static func waitFor(_ message: String, seconds: Double = 4, _ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= end { throw AppError.invalid(message) }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    static func control(_ object: [String: Bool]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
    }
    static func boardZero() -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let levels = object["levels"] as? [Int] else { return false }
        return !levels.contains(where: { $0 != 0 }) && object["armed"] as? Bool == false
    }
    @MainActor static func trackVibrationEdit(_ model: SessionModel, settings: VibrationChannel) throws {
        let epoch = model.usb.snapshotForTesting().epoch
        model.setVibrationChannel(0, value: settings)
        // A picker or slider runs the event-tracking loop, not the default loop.
        let deadline = Date().addingTimeInterval(1.1)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02))
        }
        try require(model.preferences.effectiveVibration.one == settings && model.usb.reported?.one == 60 &&
                    model.isArmed && model.usb.boardArmed && model.usb.snapshotForTesting().epoch == epoch && model.fault == nil,
                    "Vibration editing/menu tracking stalled telemetry or restarted the controller")
    }
    @MainActor static func checkTimedEdging(port: String, directory: URL) async throws {
        let first = SessionModel(dataDirectory: directory, allowPseudoTerminal: true, automaticallyReconnectUSB: false)
        first.output = .arduino; first.preferences.arduinoPort = port
        try require(!first.setTimedEdging(seconds: 1), "Timer was accessible before threshold lock")
        first.lockPressureThresholds()
        try require(first.setTimedEdging(seconds: 1), "Timer setup failed after threshold lock")
        first.lockTimedEdging(); first.unlockTimedEdging()
        try require(first.timedEdgingLocked && !first.setTimedEdging(seconds: 2), "Timer unlocked before completion")
        var edging = VibrationChannel(); edging.mode = .constant; edging.target = 10
        var orgasm = edging; orgasm.target = 30
        first.setVibrationChannel(0, value: edging, forOrgasm: false)
        first.setVibrationChannel(1, value: edging, forOrgasm: false)
        first.setVibrationChannel(0, value: orgasm, forOrgasm: true)
        orgasm.target = 40; first.setVibrationChannel(1, value: orgasm, forOrgasm: true)
        first.connectUSB(); try await waitFor("Timer fixture failed to connect", seconds: 7) { first.usb.ready }
        first.motorSetupConfirmed = true; first.calibrate()
        try await waitFor("Timer fixture failed to calibrate", seconds: 7) { first.calibrated }
        first.start(); try await waitFor("Timer fixture failed to arm") { first.isArmed }
        await first.shutdown()

        let model = SessionModel(dataDirectory: directory, allowPseudoTerminal: true, automaticallyReconnectUSB: false)
        try require(!model.isArmed && !model.usb.connected && model.timedEdgingLocked && model.pressureThresholdsLocked &&
                    model.timedEdging?.penaltyEdgesRemaining == 5 && model.timedEdgingRemaining == 1,
                    "Restart lost the persistent lock/penalty or energized output")
        model.unlockTimedEdging()
        try require(model.timedEdgingLocked && !model.canEditPressureThresholds, "Restart bypassed timer lock")
        model.output = .arduino; model.connectUSB()
        try await waitFor("Restarted timer fixture failed to reconnect", seconds: 7) { model.usb.ready }
        model.motorSetupConfirmed = true; model.calibrate()
        try await waitFor("Restarted timer fixture failed to calibrate", seconds: 7) { model.calibrated }
        model.start(); try await waitFor("Penalty session failed to start") { model.isArmed }
        model.label(.edge)
        try require(model.timedEdging?.penaltyEdgesRemaining == 5, "User Edge mark counted as an automatic penalty edge")
        for remaining in stride(from: 4, through: 0, by: -1) {
            model.demoPattern = "Waves"
            try await waitFor("Automatic penalty edge was not counted", seconds: 5) { model.timedEdging?.penaltyEdgesRemaining == remaining }
            try require(!model.orgasmMode && model.timedEdgingRemaining == 1, "Timer ran before all penalty edges completed")
            if remaining > 0 {
                model.demoPattern = "Rest"
                try await waitFor("Penalty cooldown failed to resume", seconds: 8) { model.usb.reported?.anyOn == true }
            }
        }
        let expected = VibrationLevels(Int(Double(model.usb.limits.one) * 0.3), Int(Double(model.usb.limits.two) * 0.4))
        try await waitFor("Timer failed to select Orgasm mode and its separate preset", seconds: 3) {
            model.orgasmMode && model.timedEdging?.completed == true && model.usb.reported == expected
        }
        try require(model.edgeCount == 5 && model.isArmed && model.usb.boardArmed, "Timed transition restarted the controller")
        model.setVibrationTarget(channel: 0, value: 20)
        try await waitFor("Orgasm preset could not be edited under timer/threshold locks") {
            model.usb.reported?.one == Int(Double(model.usb.limits.one) * 0.2)
        }
        let panel = NSHostingView(rootView: MainView(model: model).frame(width: 1180, height: 900))
        panel.frame = NSRect(x: 0, y: 0, width: 1180, height: 900); panel.layoutSubtreeIfNeeded()
        if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
            panel.cacheDisplay(in: panel.bounds, to: bitmap)
            let path = URL(fileURLWithPath: CommandLine.arguments[4]).deletingLastPathComponent().appendingPathComponent("timed-edging-smoke.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: path)
        }
        model.label(.tooClose)
        try await waitFor("Too close failed in Orgasm mode") { model.usb.reported == .zero }
        try require(model.isArmed, "Manual cooldown unexpectedly ended the timer session")
        model.stop()
        try await waitFor("Timer Stop failed") { !model.usb.boardArmed && model.usb.reported == .zero }
        try await waitFor("Timer archive did not finish", seconds: 8) { !model.isFinishing && !model.learningBusy }
        try require(model.canUnlockTimedEdging, "Completed timer could not be unlocked after Stop")
        await model.shutdown()
        let reopened = SessionModel(dataDirectory: directory)
        try require(reopened.canUnlockTimedEdging && reopened.timedEdging?.penaltyEdgesRemaining == 0 &&
                    reopened.preferences.effectiveOrgasmVibration.one.target == 20,
                    "Completed timer or separate preset did not survive reopen")
        reopened.unlockTimedEdging()
        try require(!reopened.timedEdgingLocked && reopened.setTimedEdging(seconds: nil), "Completed timer unlock failed")
        let record = try LocalStore(directory: directory).sessions().last!
        try require(record.timedEdging?.penaltyEdgesRemaining == 5 && record.orgasmModeAt != nil &&
                    record.orgasmVibrationSettings?.two.target == 40, "Timed session provenance was lost")
        let replay = try Learner.replay(record, with: record.settings)
        try require(zip(record.frames, replay.frames).allSatisfy { $0.active == $1.active }, "Timed session detector replay changed")
        await reopened.shutdown()
        print("PASS timed edging: threshold gate, persistent lock, close/reopen +5 penalty, five automatic edges, saved duration, separate Orgasm preset, live edits, manual OFF, Stop, completion-only unlock and replay")
    }
    @MainActor static func checkPressureLoss(port: String, directory: URL) async throws {
        for (index, packet) in [Data([0, 0, 2, 188]), Data([3, 232, 0, 0])].enumerated() {
            let model = SessionModel(dataDirectory: directory.appendingPathComponent("channel-\(index)"),
                allowPseudoTerminal: true, automaticallyReconnectUSB: false)
            model.output = .arduino; model.preferences.arduinoPort = port
            var channel = VibrationChannel(); channel.mode = .constant; channel.target = 30
            model.setVibrationChannel(0, value: channel); model.setVibrationChannel(1, value: channel)
            model.lockPressureThresholds(); try require(model.setTimedEdging(seconds: 1), "Pressure-loss timer setup failed")
            model.lockTimedEdging()
            model.connectUSB(); try await waitFor("Pressure-loss fixture did not connect", seconds: 7) { model.usb.ready }
            model.motorSetupConfirmed = true; model.calibrate()
            try await waitFor("Pressure-loss fixture did not calibrate", seconds: 7) { model.calibrated }
            model.start()
            try await waitFor("Pressure-loss fixture did not reach Orgasm mode") { model.orgasmMode && model.usb.reported?.anyOn == true }
            model.useDemo = false
            model.bluetooth.receivePacket(Data([3, 232, 2, 188]))
            try require(model.isArmed, "Normal resting/baseline pressure stopped the session")
            let lostAt = ProcessInfo.processInfo.systemUptime
            if index == 0 {
                try await waitFor("Missing pressure did not zero Orgasm-mode output", seconds: 0.85) {
                    model.pressurePaused && model.usb.reported == .zero
                }
                try require(ProcessInfo.processInfo.systemUptime - lostAt < 0.85, "Pressure-stop deadline exceeded")
                let feed = Task { @MainActor in
                    while !Task.isCancelled {
                        model.bluetooth.receivePacket(Data([3, 232, 2, 188]))
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                try await waitFor("Fresh pressure did not clear the pause") { !model.pressurePaused }
                try require(model.usb.reported == .zero, "Pressure return bypassed cooldown in Orgasm mode")
                try await waitFor("Fresh pressure did not resume after cooldown", seconds: 8) { model.usb.reported?.anyOn == true }
                feed.cancel()
            }
            model.bluetooth.receivePacket(packet)
            try require(!model.isArmed && model.fault?.contains("pressure dropped to zero") == true,
                        "Zero pressure did not synchronously disarm Orgasm mode")
            try await waitFor("Zero-pressure shutdown did not stop both motors", seconds: 0.5) {
                model.usb.reported == .zero && !model.usb.boardArmed
            }
            model.start()
            try require(!model.isStarting, "Zero pressure permitted rearming")
            model.bluetooth.receivePacket(Data([3, 232, 2, 188]))
            try await Task.sleep(for: .milliseconds(250))
            try require(!model.isArmed && model.usb.reported == .zero && model.timedEdgingLocked,
                        "Pressure return restarted output or cleared the timer lock")
            try await waitFor("Pressure-loss archive did not save") { !model.learningBusy }
            await model.shutdown()
        }
        print("PASS Perifit pressure loss: either raw channel zero immediately disarms; missing packets zero both motors within 0.85s; Orgasm/lock override, quiet recovery and manual restart")
    }
    @MainActor static func checkXToys(port: String, directory: URL) async throws {
        let model = SessionModel(dataDirectory: directory, allowPseudoTerminal: true, automaticallyReconnectUSB: false)
        model.output = .arduino; model.preferences.arduinoPort = port
        var one = VibrationChannel(); one.target = 80
        var two = VibrationChannel(); two.target = 60
        model.setVibrationChannel(0, value: one); model.setVibrationChannel(1, value: two)
        model.connectUSB(); try await waitFor("XToys fixture failed to connect", seconds: 7) { model.usb.ready }
        model.motorSetupConfirmed = true; model.calibrate()
        try await waitFor("XToys fixture failed to calibrate", seconds: 7) { model.calibrated }
        try model.xtoys.start(port: 0)
        try await waitFor("XToys listener did not bind") { !model.xtoys.endpoint.isEmpty }
        try require(model.xtoys.endpoint.hasPrefix("ws://127.0.0.1:"), "XToys listener was not loopback-only")
        var denied = URLRequest(url: URL(string: model.xtoys.endpoint)!)
        denied.setValue("https://example.com", forHTTPHeaderField: "Origin")
        let stranger = URLSession.shared.webSocketTask(with: denied); stranger.resume()
        var rejected = false
        do { _ = try await stranger.receive() } catch { rejected = true }
        try require(rejected && !model.xtoys.connected, "Non-XToys origin was accepted")
        stranger.cancel(with: .goingAway, reason: nil)
        try await waitFor("Rejected peer was not cleared") { model.xtoys.status.contains("stopped") }
        var request = URLRequest(url: URL(string: model.xtoys.endpoint)!)
        request.setValue("https://xtoys.app", forHTTPHeaderField: "Origin")
        let peer = URLSession.shared.webSocketTask(with: request); peer.resume()
        let reader = Task { while !Task.isCancelled { do { _ = try await peer.receive() } catch { return } } }
        defer { reader.cancel(); peer.cancel(with: .goingAway, reason: nil) }
        try await waitFor("XToys JSON client did not connect") { model.xtoys.connected }
        try await peer.send(.string(#"{"channel":1,"vibrate":100}"#))
        try await Task.sleep(for: .milliseconds(150))
        try require(!model.isArmed && boardZero() && model.xtoys.demand == XToysDemand(), "XToys armed output or retained pre-arm commands")
        model.start(); try await waitFor("XToys session failed to arm") { model.isArmed }
        model.lockPressureThresholds()
        try await peer.send(.string(#"{"channel":1,"vibrate":50}"#))
        try await peer.send(.string(#"{"channel":2,"vibrate":100}"#))
        let expected = VibrationLevels(Int(Double(model.usb.limits.one) * 0.4), Int(Double(model.usb.limits.two) * 0.6))
        try await waitFor("XToys channel mapping or local target caps failed") { model.usb.reported == expected }
        try await Task.sleep(for: .seconds(3.2))
        try require(model.xtoys.connected && model.usb.reported == expected, "Constant XToys output lost its websocket keepalive")
        let stream = Task {
            while !Task.isCancelled {
                do {
                    try await peer.send(.string(#"{"channel":1,"vibrate":50}"#))
                    try await peer.send(.string(#"{"channel":2,"vibrate":100}"#))
                    try await Task.sleep(for: .milliseconds(100))
                } catch { return }
            }
        }
        model.demoPattern = "Waves"
        try await waitFor("XToys bypassed the threshold cutoff", seconds: 5) { model.edgeCount > 0 && model.usb.reported == .zero }
        try await Task.sleep(for: .milliseconds(500))
        try require(model.usb.reported == .zero && model.isArmed && model.xtoys.connected,
                    "Repeated XToys commands overrode the cooldown")
        model.demoPattern = "Rest"
        try await waitFor("XToys did not resume after the controller's quiet cooldown", seconds: 8) { model.usb.reported == expected }
        let panel = NSHostingView(rootView: XToysControls(model: model, bridge: model.xtoys, third: model.xtoysM3).padding(20).frame(width: 500))
        panel.frame = NSRect(x: 0, y: 0, width: 500, height: 460); panel.layoutSubtreeIfNeeded()
        if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
            panel.cacheDisplay(in: panel.bounds, to: bitmap)
            let path = URL(fileURLWithPath: CommandLine.arguments[4]).deletingLastPathComponent().appendingPathComponent("xtoys-smoke.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: path)
        }
        model.stop()
        try await waitFor("Stop did not disarm XToys output") { boardZero() }
        try await Task.sleep(for: .milliseconds(250))
        try require(model.xtoys.demand == XToysDemand() && !model.isArmed, "XToys restarted output after Stop")
        try await waitFor("XToys session did not save", seconds: 8) { !model.isFinishing && !model.learningBusy }
        model.start(); try await waitFor("XToys could not rearm without restarting the app") { model.isArmed && model.usb.reported == expected }
        model.useDemo = false; model.bluetooth.receivePacket(Data([0, 0, 2, 188]))
        try require(!model.isArmed, "XToys bypassed the raw-pressure-loss stop")
        try await waitFor("XToys pressure loss did not zero both motors") { boardZero() }
        stream.cancel()
        try await waitFor("XToys pressure-loss session did not save") { !model.learningBusy }
        model.useDemo = true; model.calibrate()
        try await waitFor("XToys fixture could not recalibrate", seconds: 7) { model.calibrated }
        model.start(); try await waitFor("XToys final session did not arm") { model.isArmed }
        try await peer.send(.string(#"{"channel":1,"vibrate":100}"#))
        try await waitFor("XToys final session did not establish output") { model.usb.reported?.anyOn == true }
        peer.cancel(with: .goingAway, reason: nil)
        try await waitFor("XToys disconnect did not stop and disarm the motors") { !model.isArmed && boardZero() }
        try await waitFor("XToys final archive did not save") { !model.learningBusy }
        let records = try LocalStore(directory: directory).sessions()
        try require(records.count == 3 && records.allSatisfy { $0.vibrationSource == "xtoys" && !$0.eligible },
                    "XToys source was missing from archives or contaminated automatic tuning")
        await model.shutdown()
        print("PASS XToys websocket: origin restriction, explicit arming, independent channels, target caps, constant holds, threshold cutoff under continuous commands, quiet recovery, Stop, pressure loss, disconnect and archives")
    }
    @MainActor static func checkFinder(port: String, directory: URL) async throws {
        let model = SessionModel(dataDirectory: directory, allowPseudoTerminal: true, automaticallyReconnectUSB: false)
        model.output = .arduino; model.preferences.arduinoPort = port
        model.finderEnabled = true; model.finderMotors = [1]
        for i in 0..<3 { model.setVibrationTarget(channel: i, value: 30) }
        model.connectUSB(); try await waitFor("Finder fixture failed to connect", seconds: 7) { model.usb.ready }
        model.motorSetupConfirmed = true; model.calibrated = true; model.baseline = 1000
        model.start()
        try await waitFor("Finder selected motor did not run") { model.usb.reported?.two ?? 0 > 0 }
        try require(model.usb.reported?.one == 0 && model.usb.reported?.three == 0 && model.usb.reported!.two <= 54,
                    "Finder exceeded a target or drove an unselected motor")
        model.demoPattern = "Waves"
        try await waitFor("Finder bypassed the pressure cutoff", seconds: 5) { model.edgeCount > 0 && model.usb.reported == .zero }
        try require(model.finderRunning && model.finderResults.contains { $0.cutoffLimited == true },
                    "Actual cutoff discarded the Finder measurement")
        model.demoPattern = "Rest"
        try await waitFor("Finder did not resume after cooldown", seconds: 8) { model.usb.reported?.two ?? 0 > 0 }
        model.setVibrationTarget(channel: 1, value: 20)
        try await waitFor("Finder edit did not stop/disarm") { !model.finderRunning && !model.isArmed && boardZero() }
        try require(model.preferences.effectiveVibration.two.target == 20 && model.usb.ready,
                    "Finder edit lost settings or required a controller restart")
        try await waitFor("Finder archive did not finish", seconds: 8) { !model.isFinishing && !model.learningBusy }
        model.start(); try await waitFor("Finder could not restart") { model.isArmed && model.finderRunning }
        model.useDemo = false
        model.bluetooth.receivePacket(Data([0, 0, 2, 188]))
        try await waitFor("Finder ignored zero raw pressure") { !model.isArmed && !model.finderRunning && boardZero() }
        await model.shutdown()
        let records = try LocalStore(directory: directory).sessions()
        try require(records.count == 2 && records.allSatisfy { !$0.eligible && $0.vibrationSource == "finder" },
                    "Finder sessions contaminated tuning or lost their source tag")
        try await checkFinderCompletion(port: port, directory: directory.appendingPathComponent("completion"))
        try await checkManualOrgasmMode(port: port, directory: directory.appendingPathComponent("manual-orgasm"))
        print("PASS Finder USB: selected motor only, target cap, cutoff/cooldown, interrupted trial, live edit stop/restart, raw pressure loss and archives")
    }
    @MainActor static func checkFinderCompletion(port: String, directory: URL) async throws {
        let setup = SessionModel(dataDirectory: directory, allowPseudoTerminal: true, automaticallyReconnectUSB: false)
        setup.output = .arduino; setup.preferences.arduinoPort = port
        setup.finderEnabled = true; setup.finderMotors = [1]; setup.finderTargetLevel = 1
        for i in 0..<3 {
            var value = VibrationChannel(); value.mode = .constant; value.target = 25
            setup.setVibrationChannel(i, value: value)
            value.target = 60; setup.setVibrationChannel(i, value: value, forOrgasm: true)
        }
        try require(setup.savePreferences(), "Finder lock fixture settings failed to save")
        setup.lockPressureThresholds(); setup.lockAutomaticCutoffs(1)
        try require(setup.lockFinderSetup(), "Training could not be locked alongside the count")
        try require(setup.setTimedEdging(seconds: 1), "Timer could not be configured alongside training/count locks")
        setup.lockTimedEdging()
        try require(setup.finderTrainingLocked && setup.timedEdgingLocked && !setup.canEditFinderSetup && !setup.canUnlockFinderSetup,
                    "Training and timer were not locked together")
        await setup.shutdown()
        let model = SessionModel(dataDirectory: directory, allowPseudoTerminal: true, automaticallyReconnectUSB: false)
        try require(model.finderEnabled && model.finderTrainingLocked && model.timedEdgingLocked && model.finderMotors == [1] && model.finderTargetLevel == 1,
                    "Combined training/timer lock did not survive reopening")
        model.lockAutomaticCutoffs(1)
        model.connectUSB(); try await waitFor("Finder timer fixture did not connect", seconds: 7) { model.usb.ready }
        model.motorSetupConfirmed = true; model.calibrated = true; model.baseline = 1000
        model.start(); try await waitFor("Locked Finder training could not start") { model.isArmed && model.finderLearning }
        try await Task.sleep(for: .milliseconds(1300))
        try require(model.timedEdgingRemaining == 1 && model.timedEdging?.elapsedSeconds == 0 && !model.orgasmMode,
                    "Session timer consumed training time")
        model.startOrgasmMode()
        try require(!model.orgasmMode && !model.canStartOrgasmMode, "Manual Orgasm mode bypassed the active locked timer/count")
        func finishTraining(realRamp: Bool = false) async throws {
            try model.advanceFinder(score: 0, time: 99.9, permitted: false)
            for step in 0...100 { try model.advanceFinder(score: Double(step) / 10, time: 100 + Double(step) / 10, permitted: true) }
            try require(model.finderLearning && !model.finderStatus.contains("ramp-down"), "Training ended before the plateau")
            for trial in 0..<20 {
                let start = 111 + Double(trial * 11)
                try model.advanceFinder(score: 20, time: start - 0.1, permitted: false)
                for step in 0...100 { try model.advanceFinder(score: 20, time: start + Double(step) / 10, permitted: true) }
            }
            try require(model.finderLearning && model.finderStatus.contains("ramp-down") && model.timedEdging?.elapsedSeconds == 0,
                        "Session timer started before ramp-down training")
            if realRamp {
                try model.advanceFinder(score: 0, time: 330.1, permitted: false)
                try await waitFor("Ramp-down never drove the selected emulator channel") { model.usb.reported?.two ?? 0 > 0 }
                try await Task.sleep(for: .seconds(5))
                try require(model.finderLearning && model.timedEdging?.elapsedSeconds == 0 &&
                            model.usb.reported?.one == 0 && model.usb.reported?.three == 0 && (model.usb.reported?.two ?? 256) <= 25,
                            "Ramp-down failed to reduce output or started the timer early")
                try await waitFor("Measured ramp-down did not finish", seconds: 8) { !model.finderLearning }
            } else {
                for step in 1...102 { try model.advanceFinder(score: 20 - Double(step) / 10, time: 330 + Double(step) / 10, permitted: true) }
                try model.advanceFinder(score: 0, time: 340.3, permitted: false)
            }
            try require(!model.finderLearning && model.finderRunning && model.isArmed, "Training did not begin the maintenance session")
        }
        try await finishTraining(realRamp: true)
        try await waitFor("Session timer did not hand Finder over to its learned pattern", seconds: 4) {
            model.orgasmMode && !model.finderRunning && (model.usb.reported?.two ?? 0) > 0
        }
        try require(!model.usesOrgasmPreset && model.finderResults.contains { $0.settings == model.activeVibrationSettings },
                    "Finder timer completion selected the unrelated Orgasm preset")
        try require(model.isArmed && model.automaticCutoffsSoFar == 0, "Timer completion ended the session or enabled unselected motors")
        model.stop(); try await waitFor("Timer completion Stop failed") { boardZero() }
        try await waitFor("Finder timer archive did not finish", seconds: 8) { !model.isFinishing && !model.learningBusy }
        let completedBest = model.finderResults.max(by: { $0.comparisonRate < $1.comparisonRate })!.settings
        model.start()
        try await waitFor("Completed timer did not restore best-pattern Orgasm mode") {
            model.isArmed && model.orgasmMode && !model.finderRunning && !model.usesOrgasmPreset
        }
        try require(model.activeVibrationSettings == completedBest, "Completed timer resumed a different pattern")
        model.stop()
        try await waitFor("Completed-timer restart did not stop and save", seconds: 8) { !model.isFinishing && !model.learningBusy && boardZero() }
        model.unlockFinderSetup(); model.unlockTimedEdging()
        try require(!model.finderTrainingLocked && !model.timedEdgingLocked, "Completed training/timer setup could not be unlocked")
        try require(model.setTimedEdging(seconds: 100), "Second timer setup failed")
        model.lockTimedEdging() // The combined action also locks training when the timer is locked first.
        model.lockAutomaticCutoffs(1)
        try require(model.finderTrainingLocked && model.timedEdgingLocked && model.automaticCutoffCountLocked,
                    "Combined lock failed in the other setup order")
        model.start(); try await waitFor("Count fixture did not reuse completed training") { model.isArmed && model.finderRunning && !model.finderLearning }
        try require(model.finderResults.contains { $0.descent != nil }, "Resumed count session lost its measured fall response")
        model.demoPattern = "Waves"
        try await waitFor("Finder count fixture did not record a cutoff", seconds: 5) { model.automaticCutoffsSoFar > 0 && model.usb.reported == .zero }
        model.demoPattern = "Rest"
        try await waitFor("Count did not hand Finder over after cooldown", seconds: 8) {
            model.automaticCutoffsComplete && !model.finderRunning && model.usb.reported == VibrationLevels(0, 45, 0)
        }
        try require(model.isArmed && !model.orgasmMode && model.timedEdgingRemaining > 80, "Count did not finish before the timer")
        model.stop(); try await waitFor("Count completion Stop failed") { boardZero() }
        await model.shutdown()
        print("PASS Finder combined locks/reopen, training before timer, timer-first Orgasm handoff, completed-training reuse, count-first continuous handoff and selected-motor mask")
    }
    @MainActor static func checkManualOrgasmMode(port: String, directory: URL) async throws {
        let model = SessionModel(dataDirectory: directory, allowPseudoTerminal: true, automaticallyReconnectUSB: false)
        model.output = .arduino; model.preferences.arduinoPort = port
        model.finderEnabled = true; model.finderMotors = [0, 2]
        for index in 0..<3 { model.setVibrationTarget(channel: index, value: 30) }
        model.lockPressureThresholds()
        try require(model.setTimedEdging(seconds: 60), "Manual-mode timer fixture failed")
        model.connectUSB(); try await waitFor("Manual-mode fixture did not connect", seconds: 7) { model.usb.ready }
        model.motorSetupConfirmed = true; model.calibrated = true; model.baseline = 1000
        model.start(); try await waitFor("Manual-mode fixture did not arm") { model.isArmed }
        try model.advanceFinder(score: 20, time: 99.9, permitted: false)
        for tick in 0...100 { try model.advanceFinder(score: 20 + Double(tick)/10, time: 100 + Double(tick)/10, permitted: true) }
        model.startOrgasmMode()
        try require(!model.canStartOrgasmMode && !model.orgasmMode && !model.timedEdgingLocked,
                    "An unlocked active timer allowed manual Orgasm mode")
        model.stop(); try await waitFor("Timer fixture did not stop and save", seconds: 8) { !model.isFinishing && !model.learningBusy && boardZero() }
        model.lockPressureThresholds()
        try require(model.setTimedEdging(seconds: nil), "Stopped timer could not be removed")
        model.start(); try await waitFor("Manual-mode fixture did not resume") { model.isArmed && model.finderLearning }
        let best = model.finderResults.max(by: { $0.comparisonRate < $1.comparisonRate })!.settings
        try require(model.setAutomaticCutoffLimit(2), "Cutoff-limit fixture failed")
        model.startOrgasmMode()
        try require(!model.canStartOrgasmMode && !model.orgasmMode && !model.automaticCutoffCountLocked,
                    "An unlocked active cutoff limit allowed manual Orgasm mode")
        try require(model.setAutomaticCutoffLimit(nil), "Unlocked cutoff limit could not be cleared")
        try require(model.canStartOrgasmMode, "Manual Orgasm mode remained unavailable after limits were removed")
        model.startOrgasmMode()
        try require(model.orgasmMode && model.activeVibrationSettings == best && !model.finderRunning,
                    "Manual Orgasm mode did not use the best learned pattern")
        try require(!model.setAutomaticCutoffLimit(2) && model.automaticCutoffLimit == nil,
                    "An active Orgasm mode accepted a conflicting cutoff limit")
        model.demoPattern = "Waves"
        try await waitFor("Orgasm mode still cut off at the pressure threshold", seconds: 6) {
            (model.snapshot.guardScore ?? model.snapshot.score) >= model.controllerSettings.sensitivity && model.usb.reported?.anyOn == true
        }
        try require(model.usb.reported?.two == 0 && model.activeVibrationSettings == best, "Orgasm mode changed pattern or enabled an unselected motor")
        model.label(.tooClose); model.demoPattern = "Rest"
        try await waitFor("Too close did not stop Orgasm mode output") { model.usb.reported == .zero }
        try require(model.isArmed && model.orgasmMode, "Too close unexpectedly disarmed the session")
        try await waitFor("Orgasm mode did not resume after the explicit quiet cooldown", seconds: 8) { model.usb.reported?.anyOn == true }
        model.setVibrationTarget(channel: 0, value: 5)
        try require(model.activeVibrationSettings.one.target <= 5 && model.isArmed && model.usb.ready,
                    "Live target edit used the wrong preset or restarted the controller")
        model.useDemo = false
        try await waitFor("Orgasm mode bypassed stale-pressure protection", seconds: 2) { model.pressurePaused && model.usb.reported == .zero }
        model.bluetooth.receivePacket(Data([0, 0, 2, 188]))
        try await waitFor("Orgasm mode bypassed zero-pressure disarm") { !model.isArmed && boardZero() }
        await model.shutdown()
        let records = try LocalStore(directory: directory).sessions()
        guard let record = records.first(where: { $0.orgasmModeAt != nil }) else { throw AppError.invalid("Manual Orgasm mode was not archived") }
        let replay = try Learner.replay(record, with: record.settings)
        try require(zip(record.frames, replay.frames).allSatisfy { $0.active == $1.active }, "Manual Orgasm mode archive did not replay exactly")
        print("PASS manual Orgasm mode: learned pattern, active timer/count blocks, cutoff bypass, selected motors, live target edit, Too close, pressure gap/zero stops and replay")
    }
    @MainActor static func checkM3(port: String, directory: URL) async throws {
        let model = SessionModel(dataDirectory: directory, allowPseudoTerminal: true, automaticallyReconnectUSB: false)
        model.output = .arduino; model.preferences.arduinoPort = port
        model.connectUSB(); try await waitFor("M3 firmware did not connect", seconds: 7) { model.usb.ready }
        try require(model.usb.limits == VibrationLevels(200, 180, 160), "M3 READY limits were not negotiated")
        model.beginDiscovery(); model.discoveryElectricalChecked = true
        for channel in 0..<3 {
            model.discoveryChannels[channel].pwm = 16; model.testMotor(channel)
            try await waitFor("M3 discovery pulse did not complete") { !model.discoveryPulseBusy }
            try require(model.usb.reported == .zero && !model.usb.boardArmed, "Discovery failed to stop all three channels")
            model.observeMotor(channel, runsNormally: true)
            try await Task.sleep(for: .milliseconds(2100))
        }
        model.saveMotorDiscovery()
        try require(model.motorCalibration?.minimums == VibrationLevels(16, 16, 16), "M3 discovery range was not saved")
        model.preferences.motorCalibration = nil; try require(model.savePreferences(), "M3 full-range setup failed")
        for i in 0..<3 {
            var channel = VibrationChannel(); channel.target = Double(20 + i * 10); channel.mode = .constant
            model.setVibrationChannel(i, value: channel)
        }
        model.motorSetupConfirmed = true; model.calibrate()
        try await waitFor("M3 calibration failed", seconds: 7) { model.calibrated }
        model.start(); try await waitFor("Independent three-motor output failed") { model.usb.reported == VibrationLevels(40, 54, 64) }
        model.lockPressureThresholds()
        model.setVibrationTarget(channel: 2, value: 50)
        try await waitFor("Live M3 target edit failed under lock") { model.usb.reported == VibrationLevels(40, 54, 80) }
        model.setVibrationTarget(channel: 2, value: 0)
        try await waitFor("Zero M3 changed another channel") { model.usb.reported == VibrationLevels(40, 54, 0) }
        var third = model.preferences.effectiveVibration.three; third.target = 100; third.mode = .pulse
        var shape = VibrationPattern(); shape.riseSeconds = 0.3; shape.fallSeconds = 0.3; third.pattern = shape
        model.setVibrationChannel(2, value: third)
        try await waitFor("M3 pulse did not reach high") { model.usb.reported?.three == 160 }
        try await waitFor("M3 pulse did not reach zero") { model.usb.reported?.three == 0 }
        model.label(.tooClose)
        try await waitFor("Shared cutoff did not stop M3") { model.usb.reported == .zero }
        try require(model.usb.boardArmed, "Cutoff unexpectedly disarmed M3 session")
        model.stop(); try await waitFor("Stop did not disarm all three motors") { boardZero() }
        try await waitFor("M3 archive did not save", seconds: 8) { !model.isFinishing && !model.learningBusy }
        try model.xtoys.start(port: 0); try model.xtoysM3.start(port: 0)
        try await waitFor("M3 XToys endpoints did not bind") { !model.xtoys.endpoint.isEmpty && !model.xtoysM3.endpoint.isEmpty }
        func socket(_ url: String) -> URLSessionWebSocketTask {
            var request = URLRequest(url: URL(string: url)!); request.setValue("https://xtoys.app", forHTTPHeaderField: "Origin")
            let socket = URLSession.shared.webSocketTask(with: request); socket.resume(); return socket
        }
        let pair = socket(model.xtoys.endpoint), m3 = socket(model.xtoysM3.endpoint)
        let readers = [pair, m3].map { socket in Task { while !Task.isCancelled { do { _ = try await socket.receive() } catch { return } } } }
        defer { readers.forEach { $0.cancel() }; pair.cancel(with: .goingAway, reason: nil); m3.cancel(with: .goingAway, reason: nil) }
        try await waitFor("Separate M3 XToys toy failed to connect") { model.xtoys.connected && model.xtoysM3.connected }
        model.start(); try await waitFor("Three-channel XToys session did not arm") { model.isArmed }
        try await pair.send(.string(#"{"channel":1,"vibrate":100}"#))
        try await pair.send(.string(#"{"channel":2,"vibrate":50}"#))
        try await m3.send(.string(#"{"vibrate":75}"#))
        try await waitFor("XToys M3 single-channel routing failed") { model.usb.reported == VibrationLevels(40, 27, 120) }
        model.demoPattern = "Waves"
        try await waitFor("Pressure threshold failed to stop three XToys motors", seconds: 5) { model.edgeCount > 0 && model.usb.reported == .zero }
        model.demoPattern = "Rest"
        try await waitFor("Three-channel XToys cooldown failed to resume", seconds: 8) { model.usb.reported == VibrationLevels(40, 27, 120) }
        let view = NSHostingView(rootView: VibrationPanel(model: model, usb: model.usb).padding(18)
            .frame(width: 500, height: 2100).background(Color(nsColor: .windowBackgroundColor)))
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 2100); view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let path = URL(fileURLWithPath: CommandLine.arguments[4]).deletingLastPathComponent().appendingPathComponent("m3-smoke.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: path)
        }
        m3.cancel(with: .goingAway, reason: nil)
        try await waitFor("M3 XToys disconnect did not stop all motors") { !model.isArmed && boardZero() }
        try await waitFor("M3 XToys archive did not save") { !model.learningBusy }
        let records = try LocalStore(directory: directory).sessions()
        try require(records.count == 2 && records.allSatisfy { $0.vibrationLimits?.three == 160 } &&
                    records[1].frames.contains { $0.vibrationReported?.three == 120 }, "M3 telemetry was not archived")
        await model.shutdown()
        let reopened = SessionModel(dataDirectory: directory)
        try require(reopened.preferences.effectiveVibration.three.mode == .pulse && !reopened.isArmed, "M3 settings did not survive reopening")
        await reopened.shutdown()
        print("PASS M3: negotiated protocol, three-channel discovery, independent output/pattern/zero, live locked edits, shared cutoff/Stop, separate XToys toy, disconnect, archive and persistence")
    }
    @MainActor static func checkDebugExport(_ model: SessionModel, directory: URL) async throws {
        let log = model.usb.debugLog
        model.setUSBDebugLogging(false)
        let count = log.entries.count
        log.record("ignored", "disabled logging must retain the existing capture")
        try require(count > 10 && log.entries.count == count, "Debug capture disabled/retention behavior failed")
        let folder = try await log.export(to: directory, context: model.usbDebugContext)
        let trace = try String(contentsOf: folder.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        let entries = try trace.split(separator: "\n").map { try JSONDecoder().decode(USBDebugLog.Entry.self, from: Data($0.utf8)) }
        for kind in ["tx", "rx", "fault", "context", "request", "emergencyStop"] {
            try require(entries.contains { $0.kind == kind }, "Debug trace omitted \(kind)")
        }
        for kind in ["tx", "rx"] {
            let bytes = entries.filter { $0.kind == kind }.reduce(into: Data()) { result, entry in
                if let encoded = entry.bytesBase64, let chunk = Data(base64Encoded: encoded) { result.append(chunk) }
            }
            let wire = String(decoding: bytes, as: UTF8.self)
            try require(wire.contains(kind == "tx" ? "PE1 SET " : "PE1 ACK "), "Debug export lost exact serial bytes")
        }
        try require(zip(entries, entries.dropFirst()).allSatisfy { $0.seconds <= $1.seconds }, "Debug event ordering changed")
        let contextData = try Data(contentsOf: folder.appendingPathComponent("context.json"))
        let context = try JSONDecoder().decode(USBDebugLog.Context.self, from: contextData)
        try require(context == model.usbDebugContext && !trace.contains("pressureCalibration"), "Debug context/privacy regression")
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("trace.jsonl").path)[.posixPermissions] as? NSNumber
        try require(permissions?.intValue == 0o600, "Debug export is not private")
        try require(FileManager.default.fileExists(atPath: folder.appendingPathComponent("HANDOFF.md").path), "Firmware handoff missing")

        var floor = context
        floor.savedCalibration = MotorCalibration(port: "fixture", boardLimits: VibrationLevels(255, 255), supplyVoltage: 6,
            minimums: VibrationLevels(100, 255), maximums: VibrationLevels(255, 255))
        floor.appliedCalibration = floor.savedCalibration
        var settings = VibrationSettings(); settings.two.mode = .constant; settings.two.target = 75
        var envelope = VibrationEnvelope()
        let levels = try envelope.step(settings, limits: VibrationLevels(255, 255), minimums: VibrationLevels(100, 255), permitted: true, time: 0)
        try require(floor.warnings.count == 1 && floor.warnings[0].contains("M2") && levels.two == 255, "M2 floor diagnostic missed the host-side clamp")
        let bounded = USBDebugLog(); bounded.setEnabled(true, context: floor)
        let malformed = Data([0xff, 0x00, 0x0a]); bounded.wire("rx", malformed)
        try require(bounded.entries.last?.bytesBase64 == malformed.base64EncodedString(), "Malformed RX bytes were lost")
        for _ in 0...USBDebugLog.maximumEntries { bounded.record("test", "entry") }
        try require(!bounded.enabled && bounded.entries.count == USBDebugLog.maximumEntries && bounded.entries.last?.detail.contains("limit") == true,
                    "Debug capture did not stop at its bound")
        bounded.setEnabled(true, context: floor)
        try require(bounded.enabled && bounded.entries.count == 2, "New debug capture did not reset old events")
        print("PASS USB debug handoff: opt-in, exact TX/RX, faults, context, private export, M2 floor warning and bounded capture")
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perifit-usb-test-" + UUID().uuidString)
        let model = SessionModel(dataDirectory: directory, allowPseudoTerminal: true, automaticallyReconnectUSB: false)
        model.output = .arduino
        let view = NSHostingView(rootView: MainView(model: model).frame(width: 1180, height: 900))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Perifit Edge · isolated USB check"; window.contentView = view
        window.ignoresMouseEvents = true // Keep the fixture offscreen and separate from the user's live app.
        Task { @MainActor in
            do {
                let port = CommandLine.arguments[1]
                if CommandLine.arguments.contains("--finder-only") {
                    await model.shutdown()
                    try await checkFinder(port: port, directory: directory.appendingPathComponent("finder"))
                    try FileManager.default.removeItem(at: directory)
                    window.close(); exit(0)
                }
                if CommandLine.arguments.contains("--m3-only") {
                    await model.shutdown()
                    try await checkM3(port: port, directory: directory.appendingPathComponent("m3"))
                    try FileManager.default.removeItem(at: directory)
                    window.close(); exit(0)
                }
                if CommandLine.arguments.contains("--xtoys-only") {
                    await model.shutdown()
                    try await checkXToys(port: port, directory: directory.appendingPathComponent("xtoys"))
                    try FileManager.default.removeItem(at: directory)
                    window.close(); exit(0)
                }
                if CommandLine.arguments.contains("--pressure-loss-only") {
                    await model.shutdown()
                    try await checkPressureLoss(port: port, directory: directory.appendingPathComponent("pressure-loss"))
                    try FileManager.default.removeItem(at: directory)
                    window.close(); exit(0)
                }
                if CommandLine.arguments.contains("--timed-only") {
                    await model.shutdown()
                    try await checkTimedEdging(port: port, directory: directory.appendingPathComponent("timed"))
                    try FileManager.default.removeItem(at: directory)
                    window.close(); exit(0)
                }
                model.preferences.arduinoPort = port
                var vibration = VibrationSettings()
                vibration.one.start = 10; vibration.one.target = 60; vibration.one.rampSeconds = 2
                vibration.two.start = 5; vibration.two.target = 40; vibration.two.mode = .steps
                vibration.two.stepSeconds = 0.25; vibration.two.stepPercent = 10
                model.preferences.vibration = vibration
                try require(!model.usb.debugLog.enabled && !model.usb.debugLog.hasCapture, "USB logging was not opt-in")
                model.setUSBDebugLogging(true)
                model.connectUSB()
                try await waitFor("USB handshake failed: \(model.usb.status)", seconds: 7) { model.usb.ready }
                try require(model.usb.limits == VibrationLevels(200, 180), "Board limits ignored")
                try require(model.usb.supportsDiscovery && !model.canStart, "Uncalibrated session could start")
                model.beginDiscovery(); model.testMotor(0)
                try require(!model.discoveryPulseBusy && boardZero(), "Unverified bench setup energized a motor")
                model.discoveryElectricalChecked = true
                model.discoveryChannels[0].pwm = 201; model.testMotor(0)
                try require(!model.discoveryPulseBusy && model.discoveryChannels[0].highestTested == 0,
                            "Discovery accepted a level above the firmware limit")
                model.discoveryChannels[0].pwm = 180; model.testMotor(0)
                try require(model.discoveryPulseBusy, "Discovery rejected a direct jump to an arbitrary valid PWM")
                try await waitFor("Arbitrary-level discovery pulse did not finish") { !model.discoveryPulseBusy }
                try require(model.isDiscovering && model.discoveryChannels[0].awaitingObservation == 180 && model.usb.reported == .zero,
                            "Arbitrary-level pulse was not confirmed OFF")
                model.observeMotor(0, runsNormally: false)
                try await Task.sleep(for: .milliseconds(2100))
                for channel in 0..<2 {
                    for pwm in [8, 16] {
                        model.discoveryChannels[channel].pwm = pwm; model.testMotor(channel)
                        try require(model.discoveryPulseBusy, "Discovery pulse failed to start: \(model.message)")
                        try await waitFor("Discovery pulse did not finish") { !model.discoveryPulseBusy }
                        try require(model.isDiscovering && model.usb.reported == .zero && !model.usb.boardArmed,
                                    "Discovery did not confirm OFF: \(model.message)")
                        model.observeMotor(channel, runsNormally: true)
                        try await Task.sleep(for: .milliseconds(2100))
                    }
                }
                try require(try LocalStore(directory: directory).sessions().isEmpty, "Bench discovery contaminated learning")
                let discoveryView = NSHostingView(rootView: MotorDiscoveryView(model: model, usb: model.usb))
                discoveryView.frame = NSRect(x: 0, y: 0, width: 630, height: 740); discoveryView.layoutSubtreeIfNeeded()
                if let bitmap = discoveryView.bitmapImageRepForCachingDisplay(in: discoveryView.bounds) {
                    discoveryView.cacheDisplay(in: discoveryView.bounds, to: bitmap)
                    let path = URL(fileURLWithPath: CommandLine.arguments[4]).deletingLastPathComponent().appendingPathComponent("discovery-smoke.png")
                    try bitmap.representation(using: .png, properties: [:])?.write(to: path)
                }
                model.saveMotorDiscovery()
                try require(!model.isDiscovering && model.motorCalibration?.maximums == VibrationLevels(16, 16), "Ranges were not saved")
                try require(model.preferences.effectiveVibration.channels.allSatisfy { $0.target == 0 }, "Saving discovery retained nonzero targets")
                model.beginDiscovery(); model.discoveryElectricalChecked = true; model.testMotor(0)
                try await waitFor("Test did not reach the board") { model.usb.requested.anyOn }
                model.stop()
                try await waitFor("Stop failed to cancel discovery") { model.usb.reported == .zero && !model.usb.boardArmed }
                try require(!model.isDiscovering && model.discoveryChannels[0].highestTested == 0, "Cancelled pulse became calibration evidence")
                model.disconnectUSB()
                let reopened = SessionModel(dataDirectory: directory, allowPseudoTerminal: true)
                try require(reopened.preferences.motorCalibration?.maximums == VibrationLevels(16, 16) && !reopened.isArmed && !reopened.motorSetupConfirmed,
                            "Reopening lost saved Arduino calibration or armed output")
                reopened.output = .arduino
                try await reopened.usb.connect(path: port)
                try require(reopened.motorCalibration?.minimums == VibrationLevels(8, 8) && reopened.vibrationLimits == VibrationLevels(16, 16),
                            "Matching Arduino connection failed to restore saved ranges")
                await reopened.shutdown()
                model.connectUSB()
                try await waitFor("Discovery reconnect failed") { model.usb.ready }
                try require(!model.motorSetupConfirmed, "Reconnect reused motor confirmation")
                vibration.one.target = 100; vibration.two.target = 100
                let discoveredCalibration = model.motorCalibration
                model.preferences.motorCalibration = nil // Full board range does not require discovery.
                model.preferences.vibration = vibration; try require(model.savePreferences(), "Could not save session settings")
                model.calibrate()
                try await waitFor("Calibration failed", seconds: 7) { model.calibrated }
                model.start(); try require(!model.isStarting, "Unconfirmed motor setup started a session")
                model.motorSetupConfirmed = true
                try require(model.motorCalibration == nil && model.vibrationLimits == model.usb.limits && model.canStart,
                            "Full board range incorrectly requires motor discovery")
                model.demoPattern = "Rest"
                model.start(); model.label(.tooClose)
                try await Task.sleep(for: .milliseconds(150))
                try require(!model.isArmed && !model.isStarting && !model.usb.boardArmed, "Too close failed to cancel a pending Start")
                model.start()
                try await waitFor("USB session did not arm: \(model.message)") { model.isArmed }
                try await waitFor("Channels did not start") { (model.usb.reported?.one ?? 0) >= 12 && (model.usb.reported?.two ?? 0) >= 12 }
                let priorThresholds = model.controllerSettings, priorBaseline = model.baseline
                let priorChartTime = model.chart.last?.id ?? 0, priorPWM = model.usb.reported!.one
                try require(model.setPressureThresholds(edge: priorThresholds.effectiveEdgeTarget - 10,
                                                       cutoff: priorThresholds.sensitivity + 10), "Live threshold edit failed while armed")
                try await Task.sleep(for: .milliseconds(250))
                try require(model.isArmed && model.calibrated && model.baseline == priorBaseline && model.usb.boardArmed &&
                            (model.chart.last?.id ?? 0) >= priorChartTime && (model.usb.reported?.one ?? 0) >= priorPWM,
                            "Threshold edit restarted calibration, session timing, USB arming or the motor ramp")
                let liveThresholds = model.controllerSettings
                try require(!model.setPressureThresholds(edge: liveThresholds.sensitivity, cutoff: liveThresholds.sensitivity) &&
                            model.controllerSettings == liveThresholds, "Invalid thresholds changed the live engine")
                model.lockPressureThresholds()
                try require(model.setAutomaticCutoffLimit(3) && model.setAutomaticCutoffLimit(4), "Threshold lock blocked live count edits")
                model.lockAutomaticCutoffs(4)
                try require(!model.setAutomaticCutoffLimit(nil) &&
                            !model.setPressureThresholds(edge: priorThresholds.effectiveEdgeTarget, cutoff: priorThresholds.sensitivity),
                            "Independent live control locks failed")
                let secondBefore = model.usb.reported!.two
                let priorMode = model.preferences.effectiveVibration.one
                var liveMode = priorMode; liveMode.mode = .constant; liveMode.target = 30
                try trackVibrationEdit(model, settings: liveMode)
                try require(model.preferences.effectiveVibration.one == liveMode,
                            "Threshold/count locks blocked a live vibration mode change")
                try await waitFor("Live hold-target did not reach the board") { model.usb.reported?.one == 60 }
                for mode in VibrationMode.allCases {
                    liveMode.mode = mode; liveMode.start = 10; liveMode.rampSeconds = 0.5
                    liveMode.stepPercent = 10; liveMode.stepSeconds = 0.1
                    var shape = VibrationPattern(); shape.minimum = 25; shape.maximum = 75
                    shape.riseSeconds = 0.3; shape.fallSeconds = 0.4; liveMode.pattern = shape
                    model.setVibrationChannel(0, value: liveMode)
                    try await Task.sleep(for: .milliseconds(180))
                    try require(model.preferences.effectiveVibration.one == liveMode && model.isArmed && model.usb.boardArmed &&
                                model.pressureThresholdsLocked && model.automaticCutoffCountLocked && model.fault == nil,
                                "Live vibration mode/timing edit failed under locks")
                }
                var invalid = liveMode; invalid.rampSeconds = 0
                model.setVibrationChannel(0, value: invalid)
                try require(model.preferences.effectiveVibration.one == liveMode && model.isArmed,
                            "Invalid vibration edit corrupted the controller")
                model.setVibrationChannel(0, value: priorMode)
                model.setVibrationTarget(channel: 0, value: 20)
                try await waitFor("Independent target reduction failed") { model.usb.reported?.one == 40 }
                try require(model.usb.reported!.two >= secondBefore, "M1 target reset M2's envelope")
                model.setVibrationTarget(channel: 0, value: 0)
                try await waitFor("M1 zero did not preserve M2") { model.usb.reported?.one == 0 && (model.usb.reported?.two ?? 0) > 0 }
                model.label(.edge)
                try require(model.isArmed && model.reportedPower == true, "Edge changed output permission")
                model.label(.tooClose)
                try await waitFor("Shared cutoff did not zero both channels") { model.usb.reported == .zero }
                try require(model.usb.boardArmed, "Cooldown incorrectly destroyed the session")
                try await waitFor("Cooldown failed to resume M2", seconds: 8) { (model.usb.reported?.two ?? 0) > 0 }
                model.demoPattern = "Waves"
                try await waitFor("Automatic risk did not zero USB outputs", seconds: 5) { model.edgeCount > 0 && model.usb.reported == .zero }
                model.label(.orgasm)
                try await waitFor("Stop did not disarm board") { !model.usb.boardArmed && model.usb.reported == .zero }
                try await waitFor("Recording did not finish", seconds: 8) { !model.isFinishing && !model.learningBusy }
                let records = try LocalStore(directory: directory).sessions()
                try require(records.count == 1 && records[0].outputTransport == "arduino", "USB archive metadata missing")
                try require(records[0].thresholdChanges?.count == 1 && records[0].automaticCutoffChanges?.last?.limit == 4 &&
                            !model.pressureThresholdsLocked && !model.automaticCutoffCountLocked,
                            "Live changes or session-end lock reset were lost")
                try require(records[0].motorCalibration == nil, "Manual range invented discovery metadata")
                try require(records[0].vibrationLimits == VibrationLevels(200, 180), "Full board limits missing from recording")
                try require(records[0].frames.allSatisfy { ($0.vibrationRequested?.one ?? 0) <= 200 && ($0.vibrationRequested?.two ?? 0) <= 180 }, "Board caps were exceeded")
                try require(!records[0].eligible && (records[0].vibrationTargetChanges?.count ?? 0) >= 8, "Live vibration edits were lost or contaminated tuning")
                try require(records[0].frames.contains { $0.vibrationRequested?.anyOn == true }, "Vibration telemetry missing")
                let replay = try Learner.replay(records[0], with: records[0].settings)
                try require(zip(replay.frames, records[0].frames).allSatisfy { $0.active == $1.active }, "USB pressure replay changed")
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
                }
                print("PASS native USB app: independent targets, ramp/steps, per-channel zero, shared cutoffs, resume, STOP, telemetry and replay")
                print("PASS motor discovery: preflight gate, timed single-channel pulses, cancellation, saved bounds, reconnect confirmation, no learning data")

                model.lockAutomaticCutoffs(0)
                try require(model.automaticCutoffLimit == nil, "Invalid cutoff count was accepted")
                try require(model.setAutomaticCutoffLimit(2), "Could not set an unlocked count")
                model.demoPattern = "Rest"; model.start()
                try await waitFor("Locked-count session did not start") { model.isArmed && model.usb.reported?.anyOn == true }
                try require(model.setAutomaticCutoffLimit(3) && model.setAutomaticCutoffLimit(2) &&
                            model.isArmed && !model.automaticCutoffsComplete, "Running count edit restarted the session")
                model.demoPattern = "Waves"
                try await waitFor("Counted cutoff did not stop the motors", seconds: 5) { model.edgeCount == 1 && model.usb.reported == .zero }
                try require(model.setAutomaticCutoffLimit(1), "Live count reduction failed")
                try require(model.automaticCutoffLimit == 1 && model.edgeCount == 1 && model.isArmed,
                            "Live count reduction reset completed cutoffs or the session")
                try require(!model.automaticCutoffsComplete, "Last cutoff skipped its cooldown")
                model.demoPattern = "Rest"
                try await waitFor("Final cooldown did not enable continuous output", seconds: 8) { model.automaticCutoffsComplete && model.usb.reported?.anyOn == true }
                model.demoPattern = "Waves"
                try await waitFor("Continuous session did not encounter new risk", seconds: 5) { model.snapshot.riskReason != nil }
                try await Task.sleep(for: .milliseconds(400))
                try require(model.isArmed && model.usb.boardArmed && model.usb.reported?.anyOn == true && model.edgeCount == 1,
                            "Automatic detection stopped the motors after the locked count")
                try require(model.setAutomaticCutoffLimit(2), "Live count increase failed after continuous output")
                try await waitFor("Increasing the count did not restore and count the next cutoff") {
                    model.edgeCount == 2 && model.usb.reported == .zero && model.isArmed
                }
                model.lockAutomaticCutoffs(2); model.lockAutomaticCutoffs(3)
                try require(model.automaticCutoffLimit == 2 && model.edgeCount == 2, "Live count lock reset progress or allowed edits")
                let thresholdsBeforeCountLock = model.controllerSettings
                try require(model.setPressureThresholds(edge: thresholdsBeforeCountLock.effectiveEdgeTarget + 1,
                                                       cutoff: thresholdsBeforeCountLock.sensitivity + 1) &&
                            model.setPressureThresholds(edge: thresholdsBeforeCountLock.effectiveEdgeTarget,
                                                       cutoff: thresholdsBeforeCountLock.sensitivity),
                            "Count lock incorrectly locked pressure thresholds")
                model.demoPattern = "Rest"
                try await waitFor("Increased count did not complete its final cooldown", seconds: 8) {
                    model.automaticCutoffsComplete && model.usb.reported?.anyOn == true
                }
                model.demoPattern = "Waves"
                try await waitFor("Locked increased count did not encounter new risk", seconds: 5) { model.snapshot.riskReason != nil }
                try require(model.isArmed && model.usb.reported?.anyOn == true && model.edgeCount == 2,
                            "Locked increased count did not retain continuous output")
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let screenshot = URL(fileURLWithPath: CommandLine.arguments[4]).deletingLastPathComponent().appendingPathComponent("locked-cutoffs-smoke.png")
                    try bitmap.representation(using: .png, properties: [:])?.write(to: screenshot)
                }
                model.label(.tooClose)
                try await waitFor("Too close failed after the locked count") { model.usb.reported == .zero }
                try await Task.sleep(for: .milliseconds(300))
                try require(model.usb.reported == .zero && model.isArmed, "Continuous output bypassed explicit cooldown")
                model.demoPattern = "Rest"
                try await waitFor("Explicit cooldown failed to resume continuous output", seconds: 8) { model.usb.reported?.anyOn == true }
                model.useDemo = false
                try await waitFor("Continuous output bypassed pressure freshness", seconds: 5) { model.pressurePaused && model.usb.reported == .zero }
                model.useDemo = true
                try await Task.sleep(for: .milliseconds(250))
                try require(model.usb.reported == .zero, "Fresh pressure skipped cooldown after continuous-output pause")
                try await waitFor("Continuous output failed to resume after fresh-pressure cooldown", seconds: 8) { model.usb.reported?.anyOn == true }
                model.stop()
                try await waitFor("Locked-count Stop did not turn off/disarm") { model.usb.reported == .zero && !model.usb.boardArmed }
                try await waitFor("Locked-count session did not save", seconds: 8) { !model.isFinishing && !model.learningBusy }
                try require(model.automaticCutoffLimit == nil && !model.automaticCutoffsComplete, "Ended session retained its count lock")
                let limitedRecord = try LocalStore(directory: directory).sessions().last!
                try require(limitedRecord.automaticCutoffLimit == 2 && limitedRecord.automaticCutoffChanges?.last?.limit == 2 &&
                            limitedRecord.automaticCutoffChanges?.contains(where: { $0.limit == 1 }) == true,
                            "Archive lost initial or live cutoff counts")
                let limitedReplay = try Learner.replay(limitedRecord, with: limitedRecord.settings)
                try require(zip(limitedRecord.frames, limitedReplay.frames).allSatisfy { $0.active == $1.active }, "Count-limited session changed detector replay")
                print("PASS locked automatic cutoff count: validation, immutable limit, final cooldown, continuous output, manual cooldown, pressure freshness, Stop and replay")

                model.demoPattern = "Rest"
                model.preferences.motorCalibration = discoveredCalibration
                try require(model.savePreferences(), "Could not restore optional discovery limits")
                var wave = VibrationChannel(); wave.mode = .wave; wave.target = 100
                var waveShape = VibrationPattern(); waveShape.riseSeconds = 0.6; waveShape.fallSeconds = 0.8; waveShape.curve = .linear
                wave.pattern = waveShape
                var pulseSettings = wave; pulseSettings.mode = .pulse
                pulseSettings.pattern!.riseSeconds = 0.3; pulseSettings.pattern!.fallSeconds = 0.4
                model.setVibrationChannel(0, value: wave); model.setVibrationChannel(1, value: pulseSettings)
                model.start()
                try await waitFor("Pattern session did not arm") { model.isArmed }
                var oneValues: Set<Int> = [], twoValues: Set<Int> = []
                let until = ProcessInfo.processInfo.systemUptime + 2.2
                while ProcessInfo.processInfo.systemUptime < until {
                    if let levels = model.usb.reported { oneValues.insert(levels.one); twoValues.insert(levels.two) }
                    try await Task.sleep(for: .milliseconds(40))
                }
                try require(oneValues.count >= 3 && twoValues.contains(0) && twoValues.contains(16), "Independent wave/pulse PWM did not reach the board")
                wave.pattern!.maximum = 20; model.setVibrationChannel(0, value: wave)
                try await waitFor("Live wave ceiling did not clamp to the calibrated starting floor") { (model.usb.reported?.one ?? 99) <= 8 }
                model.label(.tooClose)
                try await waitFor("Shared cutoff failed during patterns") { model.usb.reported == .zero }
                try require(model.usb.boardArmed, "Pattern cooldown ended the USB session")
                try await waitFor("Patterns failed to restart after quiet cooldown", seconds: 8) { model.usb.reported?.two == 16 }
                model.stop()
                try await waitFor("Patterns failed to disarm") { model.usb.reported == .zero && !model.usb.boardArmed }
                try await waitFor("Pattern archive did not finish", seconds: 8) { !model.isFinishing && !model.learningBusy }
                let patternRecord = try LocalStore(directory: directory).sessions().first { $0.vibrationSettings?.one.mode == .wave }!
                try require(patternRecord.vibrationTargetChanges?.last?.settings?.one.pattern?.maximum == 20 && !patternRecord.eligible,
                            "Pattern edits were not archived or contaminated tuning")
                let panel = NSHostingView(rootView: VibrationPanel(model: model, usb: model.usb).padding(18)
                    .frame(width: 440, height: 1500).background(Color(nsColor: .windowBackgroundColor)))
                panel.frame = NSRect(x: 0, y: 0, width: 440, height: 1500); panel.layoutSubtreeIfNeeded()
                if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
                    panel.cacheDisplay(in: panel.bounds, to: bitmap)
                    let path = URL(fileURLWithPath: CommandLine.arguments[4]).deletingLastPathComponent().appendingPathComponent("patterns-smoke.png")
                    try bitmap.representation(using: .png, properties: [:])?.write(to: path)
                }
                print("PASS pattern playback: independent wave/pulse USB values, live ceiling, shared cutoff/resume, stop and archived configuration")

                model.disconnectUSB()
                try await checkTimedEdging(port: port, directory: directory.appendingPathComponent("timed"))
                try await checkPressureLoss(port: port, directory: directory.appendingPathComponent("pressure-loss"))
                try await checkXToys(port: port, directory: directory.appendingPathComponent("xtoys"))
                model.connectUSB(); try await waitFor("Main fixture did not reconnect after timer tests", seconds: 7) { model.usb.ready }
                model.motorSetupConfirmed = true

                model.start()
                try await waitFor("Pressure-gap test failed to arm") { model.isArmed && model.usb.reported?.anyOn == true }
                // Stop demo packets while the real USB control loop keeps running.
                model.useDemo = false
                try await Task.sleep(for: .milliseconds(200))
                try require(model.isArmed && !model.pressurePaused, "Pressure younger than half a second was rejected")
                try await waitFor("Pressure gap failed to stop outputs promptly", seconds: 0.8) { model.pressurePaused && model.usb.reported == .zero }
                try await Task.sleep(for: .milliseconds(350))
                try require(model.isArmed && model.calibrated && model.usb.boardArmed && model.usb.reported == .zero,
                            "Brief pressure gap ended the session or left motor output ON")
                let resumedAt = ProcessInfo.processInfo.systemUptime
                let pressureFeed = Task { @MainActor in
                    while !Task.isCancelled {
                        model.bluetooth.receivePacket(Data([3, 232, 2, 188]))
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                try await waitFor("Fresh pressure did not clear the pause") { !model.pressurePaused }
                try require(model.usb.reported == .zero, "Fresh pressure bypassed cooldown")
                try await waitFor("Pressure recovery did not resume after cooldown", seconds: 8) { model.usb.reported?.anyOn == true }
                try require(ProcessInfo.processInfo.systemUptime - resumedAt >= 4.9, "Pressure recovery shortened the quiet cooldown")
                pressureFeed.cancel()
                try await waitFor("Sustained pressure loss did not disarm", seconds: 7) { !model.isArmed && model.fault?.contains("Pressure stream lost") == true }
                try await waitFor("Sustained pressure loss did not confirm OFF") { model.usb.reported == .zero && !model.usb.boardArmed }
                try await waitFor("Pressure-loss archive did not finish") { !model.learningBusy && !model.isFinishing }
                let gapRecord = try LocalStore(directory: directory).sessions().last!
                let gapReplay = try Learner.replay(gapRecord, with: gapRecord.settings)
                try require(zip(gapRecord.frames, gapReplay.frames).allSatisfy { $0.active == $1.active }, "Pressure-gap cooldown did not replay exactly")
                try require(gapRecord.frames.allSatisfy { $0.pressureAge != nil }, "Sample-age diagnostics missing")
                model.useDemo = true; model.inputChanged()
                // Let SwiftUI finish its source-selection onChange before starting calibration.
                view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(200))
                model.calibrate()
                try await waitFor("Demo recalibration after loss failed", seconds: 7) { model.calibrated }
                model.motorSetupConfirmed = true // The fixture explicitly switched input modes above.
                print("PASS pressure gaps: zero-output pause, retained session, fresh-data cooldown, sustained-loss disarm and exact replay")

                model.demoPattern = "Rest"; model.start()
                try await waitFor("Physical-output timing check did not arm") { model.isArmed }
                try await waitFor("Physical-output timing check did not turn on") { model.usb.reported?.anyOn == true }
                usleep(600_000)
                try await Task.sleep(for: .milliseconds(100))
                try require(model.isArmed && model.usb.connected, "600 ms UI delay incorrectly disarmed USB")
                usleep(850_000)
                try require(boardZero(), "USB worker did not stop output while MainActor was blocked")
                usleep(350_000)
                try await waitFor("Physical USB output survived a stalled controller") { !model.isArmed && model.fault != nil }
                try await waitFor("Physical output remained ON after timing failure") { boardZero() }
                try await waitFor("Faulted session did not save") { !model.learningBusy && !model.isFinishing }
                print("PASS physical-output timing failures still disarm and stop both motors")

                model.disconnectUSB()
                let reconnectModel = SessionModel(dataDirectory: directory.appendingPathComponent("reconnect"), allowPseudoTerminal: true)
                reconnectModel.output = .arduino; reconnectModel.preferences.arduinoPort = port
                reconnectModel.preferences.vibration = model.preferences.vibration
                reconnectModel.preferences.motorCalibration = model.preferences.motorCalibration
                reconnectModel.setUSBDebugLogging(true)
                reconnectModel.connectUSB()
                try await waitFor("Reconnect fixture failed to connect") { reconnectModel.usb.ready }
                reconnectModel.motorSetupConfirmed = true; reconnectModel.calibrate()
                try await waitFor("Reconnect fixture failed to calibrate", seconds: 7) { reconnectModel.calibrated }
                let retainedSettings = reconnectModel.preferences.effectiveVibration
                let retainedCalibration = reconnectModel.preferences.motorCalibration
                reconnectModel.start()
                try await waitFor("Reconnect fixture did not establish output") { reconnectModel.isArmed && reconnectModel.usb.reported?.anyOn == true }
                try control(["reset": true])
                try await waitFor("Brief board reset did not schedule reconnect") { reconnectModel.usbReconnecting }
                try await waitFor("Arduino did not reconnect automatically", seconds: 10) { reconnectModel.usb.ready && !reconnectModel.usbReconnecting }
                try require(!reconnectModel.isArmed && !reconnectModel.usb.boardArmed && reconnectModel.usb.reported == .zero,
                            "Automatic reconnect unexpectedly restarted motor output")
                try require(reconnectModel.preferences.effectiveVibration == retainedSettings && reconnectModel.preferences.motorCalibration == retainedCalibration && reconnectModel.motorSetupConfirmed,
                            "Automatic reconnect lost previous settings or matching setup confirmation")
                try control([:]); try await Task.sleep(for: .milliseconds(80)); try control(["reset": true])
                try await waitFor("Second reset did not schedule reconnect") { reconnectModel.usbReconnecting }
                reconnectModel.disconnectUSB()
                try await Task.sleep(for: .milliseconds(2300))
                try require(!reconnectModel.usb.connected && !reconnectModel.usbReconnecting, "Manual disconnect did not cancel reconnect")
                try control([:]); try await Task.sleep(for: .milliseconds(80))
                reconnectModel.connectUSB()
                try await waitFor("Stop fixture failed to connect") { reconnectModel.usb.ready }
                try control(["reset": true])
                try await waitFor("Stop fixture did not schedule reconnect") { reconnectModel.usbReconnecting }
                reconnectModel.stop()
                try await Task.sleep(for: .milliseconds(2300))
                try require(!reconnectModel.usb.connected && !reconnectModel.usbReconnecting, "Manual Stop did not cancel reconnect")
                try control([:]); try await Task.sleep(for: .milliseconds(80))
                reconnectModel.connectUSB()
                try await waitFor("Sleep fixture failed to connect") { reconnectModel.usb.ready }
                try control(["reset": true])
                try await waitFor("Sleep fixture did not schedule reconnect") { reconnectModel.usbReconnecting }
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
                try await waitFor("Sleep did not cancel reconnect") { !reconnectModel.usbReconnecting }
                try await Task.sleep(for: .milliseconds(2300))
                try require(!reconnectModel.usb.connected && !reconnectModel.isArmed, "Sleep revived an old connection or output")
                print("PASS sleep invalidates output and cancels pending USB reconnect")
                await reconnectModel.shutdown(); try control([:]); try await Task.sleep(for: .milliseconds(80))
                try require(reconnectModel.usb.debugLog.entries.contains { $0.kind == "reconnect" }, "Reconnect events missing from debug log")
                print("PASS Arduino reconnect: transient reset, retained targets/patterns/calibration, zero/disarmed return and manual cancellation")

                try control(["legacy": true]); try await Task.sleep(for: .milliseconds(80))
                try await model.usb.connect(path: port)
                try require(!model.usb.supportsDiscovery, "Legacy firmware claimed timed tests")
                model.beginDiscovery(); try require(!model.isDiscovering, "Legacy firmware enabled discovery")
                var rejected = false
                do { try await model.usb.testPulse(VibrationLevels(8, 0)) } catch { rejected = true }
                try require(rejected && boardZero(), "Legacy firmware accepted a pulse")
                try control([:]); try await Task.sleep(for: .milliseconds(80))
                try await model.usb.connect(path: port)
                let pulse = Task { @MainActor in try await model.usb.testPulse(VibrationLevels(8, 0)) }
                try await waitFor("Independent pulse test did not turn on") { model.usb.requested.anyOn && !boardZero() }
                // Intentionally stop the Mac event loop; the emulated board must stop itself.
                usleep(350_000)
                try require(boardZero(), "Pulse depended on the Mac event loop to turn OFF")
                try await pulse.value
                try control(["drop_ack": true]); try await Task.sleep(for: .milliseconds(80))
                rejected = false
                do { try await model.usb.testPulse(VibrationLevels(0, 8)) } catch { rejected = true }
                try require(rejected && !model.usb.connected && boardZero(), "Missing test ACK did not fail closed")
                try control([:]); try await Task.sleep(for: .milliseconds(80))
                try await model.usb.connect(path: port)
                print("PASS discovery firmware capability, independent pulse deadline during Mac stall, and lost completion ACK")

                try await model.usb.arm()
                try model.usb.drive(VibrationLevels(20, 30))
                try await waitFor("Freshness guard did not stop an abandoned controller", seconds: 2) { !model.usb.connected }
                try await waitFor("Emulated motors remained on after host stop", seconds: 2) { boardZero() }
                print("PASS USB control freshness guard")

                for mode in ["drop_ack", "bad_ack"] {
                    try control([:])
                    try await model.usb.connect(path: port); try await model.usb.arm()
                    try control([mode: true])
                    let updates = Task { @MainActor in
                        while !Task.isCancelled && model.usb.connected {
                            try? model.usb.drive(VibrationLevels(25, 35))
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                    }
                    try await waitFor("\(mode) was not rejected", seconds: 3) { !model.usb.connected }
                    updates.cancel()
                    try await waitFor("\(mode) did not leave the peer OFF", seconds: 2) { boardZero() }
                }
                print("PASS USB missing and incorrect acknowledgement handling")
                try control([:]); try await model.usb.connect(path: port); try await model.usb.arm()
                let updates = Task { @MainActor in
                    while !Task.isCancelled && model.usb.connected {
                        try? model.usb.drive(VibrationLevels(30, 45))
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                try await waitFor("Unplug test did not establish outputs") { model.usb.reported == VibrationLevels(30, 45) }
                try control(["unplug": true])
                try await waitFor("Cable loss not detected") { !model.usb.connected }
                updates.cancel()
                try await waitFor("Board watchdog did not stop outputs independently", seconds: 2) { boardZero() }
                print("PASS USB cable loss and independent peer watchdog")

                try await checkDebugExport(model, directory: directory)
                await model.shutdown()
                try FileManager.default.removeItem(at: directory)
                window.close(); exit(0)
            } catch {
                fputs("USB check failed: \(error.localizedDescription)\nStatus: \(model.usb.status)\nApp: \(model.message) · calibrating \(model.isCalibrating) · calibrated \(model.calibrated)\nArchive: \(directory.path)\n", stderr)
                await model.shutdown(); exit(1)
            }
        }
        app.run()
    }
}
