import Foundation
import PerifitCore

private var failures: [String] = []
private func expect(_ condition: @autoclosure () throws -> Bool, file: String = #fileID, line: Int = #line) {
    do { if try !condition() { failures.append("\(file):\(line): expectation failed") } }
    catch { failures.append("\(file):\(line): \(error)") }
}
private func expectThrows<T>(file: String = #fileID, line: Int = #line, _ body: () throws -> T) {
    do { _ = try body(); failures.append("\(file):\(line): expected an error") } catch { }
}

func pressurePacketAndCalibration() throws {
    let sample = try PressureSample(data: Data([0x12, 0x34, 0x05, 0x67]), time: 1)
    expect(sample.base == 0x1234 && sample.tip == 0x0567)
    expect(try sample.conditioned(baseline: 0x1200, gain: 2) == 104)
    expect(try sample.conditioned(baseline: 6000, gain: 1) == 0)
    expect(sample.hasPressure)
    expect(!PressureSample(base: 0, tip: 700, time: 0).hasPressure)
    expect(!PressureSample(base: 1000, tip: 0, time: 0).hasPressure)
    expect(!PressureSample(base: 0, tip: 0, time: 0).hasPressure)
    expect(try sample.conditioned(baseline: 0, gain: 100) == 65535)
    expectThrows { try PressureSample(data: Data([0, 1, 2]), time: 0) }
    expectThrows { try sample.conditioned(baseline: 0, gain: .nan) }
}

func originalPeakAccumulatorAndManualActions() throws {
    let engine = try Engine(settings: EngineSettings())
    try engine.arm(true, at: 0)
    _ = try engine.step(0, at: 0)
    expect(try engine.step(1000, at: 0.02).score == 0)
    expect(try engine.step(0, at: 0.04).score == 1000)
    expect(try engine.step(0, at: 0.06).score == 989)
    try engine.manualEdge(at: 0.07)
    let cool = try engine.step(0, at: 0.08)
    expect(!cool.wantsPower && cool.controlPhase == 1)
    expect(cool.score < 989) // No fabricated score to make the label agree.
    try engine.arm(false, at: 0.09)
    try engine.manualEdge(at: 0.10)
    expect(try !engine.step(0, at: 20).wantsPower)
}

func saturationAndClockBoundary() throws {
    var settings = EngineSettings(); settings.sensitivity = 65535; settings.decay = 99
    let engine = try Engine(settings: settings)
    try engine.arm(true, at: 0)
    _ = try engine.step(65535, at: 0)
    expect(try engine.step(0, at: 0.02).score == 65535)
    _ = try engine.step(65535, at: 0.04)
    expect(try engine.step(0, at: 0.06).score == 65535)
    expect(try !engine.step(0, at: 0.01).wantsPower)
    expectThrows { try engine.step(0, at: .nan) }
    settings.minimumPeaks = 9
    expectThrows { try Engine(settings: settings) }
}


private func reviewedSession(active: EngineSettings, candidate: EngineSettings?, count: Int = 10,
                             candidateLate: Bool = false) -> SessionRecord {
    var record = SessionRecord(profile: "real", simulated: false, settings: active, candidate: candidate,
                               seed: 1, baseline: 0, gain: 1)
    record.complete = true
    record.frames = [Frame(time: 0, base: 0, tip: 0, pressure: 0, armed: true, episode: 0, active: Snapshot(), shadow: Snapshot())]
    for i in 1...count {
        let time = Double(i * 10), good = i % 2 == 0
        var a = Snapshot(); a.edge = true
        var s = Snapshot(); s.edge = good && !candidateLate
        record.frames.append(Frame(time: time-1, base: 100, tip: 0, pressure: 100, armed: true,
                                   episode: i, active: a, shadow: candidate == nil ? nil : s))
        if candidateLate && good {
            var late = Snapshot(); late.edge = true
            record.frames.append(Frame(time: time+0.2, base: 100, tip: 0, pressure: 100, armed: true,
                                       episode: i, active: Snapshot(), shadow: late))
        }
        record.feedback.append(Feedback(time: time, episode: i, kind: good ? .aboutRight : .tooEarly, anchor: time))
        record.frames.append(Frame(time: time+4, base: 0, tip: 0, pressure: 0, armed: true,
                                   episode: i, active: Snapshot(), shadow: Snapshot()))
    }
    return record
}

func missingFeedbackDuplicatesAndSimulationsDoNotInflateConfidence() {
    let settings = EngineSettings()
    var record = reviewedSession(active: settings, candidate: nil, count: 2)
    record.feedback = []
    expect(Learner.evidence([record], settings: settings)[.peakScore]!.total == 0)
    record.feedback = [Feedback(time: 10, episode: 1, kind: .closer), Feedback(time: 10, episode: 1, kind: .edge),
                       Feedback(time: 10.1, episode: 1, kind: .edge)]
    expect(Learner.evidence([record], settings: settings)[.peakScore]!.total == 1)
    record.feedback[2].removed = true
    expect(Learner.evidence([record], settings: settings)[.peakScore]!.total == 1)
    record.simulated = true
    expect(Learner.evidence([record], settings: settings)[.peakScore]!.total == 0)
}

func confidenceCanFallAndSmallSamplesRemainLearning() {
    var evidence = Evidence(); evidence.matches = 2; evidence.sessions = [UUID(), UUID(), UUID()]
    expect(!evidence.supported)
    evidence.matches = 30
    expect(evidence.supported)
    evidence.contradictions = 20
    expect(!evidence.supported && evidence.status == "Mixed")
}

func onlyProspectiveSupportedCandidatesCanBePromoted() throws {
    let baseline = EngineSettings()
    var candidate = baseline; candidate.sensitivity = 630
    var profile = LearningProfile(key: "real", baseline: baseline); profile.candidate = candidate; profile.candidateVersion = UUID()
    let records = (0..<3).map { _ in
        var record = reviewedSession(active: baseline, candidate: candidate)
        record.candidateVersion = profile.candidateVersion
        return record
    }
    let promoted = try Learner.update(profile, records: records)
    expect(promoted.active == candidate && promoted.history.count == 1)
    expect(promoted.candidate == nil)
    expect(try Learner.update(profile, records: Array(records.prefix(2))).active == baseline)
    let late = (0..<3).map { _ in
        var record = reviewedSession(active: baseline, candidate: candidate, candidateLate: true)
        record.candidateVersion = profile.candidateVersion
        return record
    }
    expect(try Learner.update(profile, records: late).active == baseline)
    let retrospective = (0..<3).map { _ in reviewedSession(active: baseline, candidate: nil) }
    expect(try Learner.update(profile, records: retrospective).active == baseline)
    var versionChanged = profile; versionChanged.candidateVersion = UUID()
    expect(try Learner.update(versionChanged, records: records).active == baseline)
    profile.frozen = true
    expect(try Learner.update(profile, records: records).active == baseline)
}

func adjustmentsStayWithinOneFieldAndCumulativeBounds() {
    let baseline = EngineSettings()
    var current = baseline
    for _ in 0..<20 {
        let options = Learner.candidates(around: current, baseline: baseline)
        for option in options {
            let before = [current.sensitivity, current.sustainedThreshold, current.peakAmplitude]
            let after = [option.sensitivity, option.sustainedThreshold, option.peakAmplitude]
            expect(zip(before, after).filter { $0 != $1 }.count == 1)
            for (a, b) in zip(before, after) { expect(abs(Double(b-a)) <= Double(a) * 0.05 + 0.0001) }
            expect((450...750).contains(option.sensitivity))
            expect((150...250).contains(option.sustainedThreshold))
            expect((30...50).contains(option.peakAmplitude))
            expect(option.cooldown == baseline.cooldown && option.holdoff == baseline.holdoff)
        }
        if let next = options.first(where: { $0.sensitivity > current.sensitivity }) { current = next }
    }
}

func removingHumanLabelDoesNotRewritePhysicalActionOnReplay() throws {
    let settings = EngineSettings(), engine = try Engine(settings: EngineSettings())
    try engine.arm(true, at: 0)
    var record = SessionRecord(profile: "real", simulated: false, settings: settings, candidate: nil, seed: 1, baseline: 0, gain: 1)
    record.manualEdges = [1.01]
    var report = Feedback(time: 1.01, episode: 1, kind: .edge); report.removed = true; record.feedback = [report]
    for i in 0..<500 {
        let time = Double(i)/50
        if i == 51 { try engine.manualEdge(at: 1.01) }
        let result = try engine.step(0, at: time)
        record.frames.append(Frame(time: time, base: 0, tip: 0, pressure: 0, armed: true, episode: 1, active: result))
    }
    let replay = try Learner.replay(record, with: settings)
    expect(zip(record.frames, replay.frames).allSatisfy { $0.active == $1.active })
}

func localStorageRoundTripAndReset() throws {
    expect(try JSONDecoder().decode(OutputDestination.self, from: Data(#""removed-output""#.utf8)) == .simulation)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LocalStore(directory: directory)
    var preferences = Preferences(); preferences.gain = 1.5
    try store.save(preferences)
    expect(try store.preferences().gain == 1.5)
    let record = reviewedSession(active: EngineSettings(), candidate: nil)
    try store.save(record)
    expect(try store.sessions().count == 1)
    try store.deleteLearningHistory()
    expect(try store.sessions().isEmpty)
    expect(try store.preferences().gain == 1.5)
    try Data("invalid json".utf8).write(to: directory.appendingPathComponent("session-broken.json"))
    expectThrows { try store.sessions() }
}


func edgeAndTooCloseBothTeachOneCycle() {
    let settings = EngineSettings()
    var candidate = settings; candidate.sensitivity = 630
    var record = reviewedSession(active: settings, candidate: candidate, count: 2)
    record.frames[1].active.edge = true; record.frames[1].shadow?.edge = false // Premature cutoff at Edge.
    record.frames[3].active.edge = true; record.frames[3].shadow?.edge = true // Cutoff by Too close.
    record.feedback = [Feedback(time: 10, episode: 1, kind: .edge), Feedback(time: 20, episode: 1, kind: .tooClose)]
    let before = Learner.evidence([record], settings: settings)[.peakScore]!
    let after = Learner.evidence([record], settings: candidate, shadow: true)[.peakScore]!
    expect(before.total == 1 && before.contradictions == 1)
    expect(after.total == 1 && after.matches == 1 && after.positives == 1 && after.corrections == 1)
}

func laterCutoffWithinWarningDeadlineCanImproveRiding() throws {
    let settings = EngineSettings()
    var candidate = settings; candidate.sensitivity = 630
    var profile = LearningProfile(key: "real", baseline: settings)
    profile.candidate = candidate; profile.candidateVersion = UUID()
    let records = (0..<3).map { _ in
        var record = reviewedSession(active: settings, candidate: candidate, candidateLate: true)
        record.candidateVersion = profile.candidateVersion
        for index in record.frames.indices where record.frames[index].shadow?.edge == true {
            record.frames[index].time -= 0.4 // Later than baseline, but before the reported warning.
        }
        return record
    }
    expect(try Learner.update(profile, records: records).active == candidate)
}

func liveThresholdsPreserveStateAndReplay() throws {
    var settings = EngineSettings()
    settings.sensitivity = 3000; settings.edgeTarget = 2000; settings.averaging = true; settings.jitter = 0
    let engine = try Engine(settings: settings, seed: 7), reference = try Engine(settings: settings, seed: 7)
    try engine.arm(true, at: 0); try reference.arm(true, at: 0)
    var record = SessionRecord(profile: "live-thresholds", simulated: true, settings: settings, candidate: nil,
                               seed: 7, baseline: 0, gain: 1)
    record.thresholdChanges = []
    for tick in 0..<600 {
        let time = Double(tick) / 50
        if tick == 30 || tick == 60 {
            let edge = tick == 30 ? 100 : 1000, cutoff = tick == 30 ? 200 : 3000
            try engine.updateThresholds(edge: edge, cutoff: cutoff)
            record.thresholdChanges!.append(ThresholdChange(time: time - 0.005, edge: edge, cutoff: cutoff))
        }
        let pressure: UInt16 = tick < 20 && tick % 10 < 5 ? 1000 : 0
        let active = try engine.step(pressure, at: time), unchanged = try reference.step(pressure, at: time)
        expect(active.score == unchanged.score)
        if tick == 30 { expect(active.score > 200 && active.edge && !active.wantsPower) }
        if tick == 60 { expect(active.controlPhase == 1 && !active.wantsPower) }
        record.frames.append(Frame(time: time, base: pressure, tip: 0, pressure: pressure, armed: true, episode: 0, active: active))
    }
    let before = engine.settings
    expectThrows { try engine.updateThresholds(edge: 3000, cutoff: 3000) }
    expectThrows { try engine.updateThresholds(edge: 1, cutoff: 65536) }
    expect(engine.settings == before)
    let replay = try Learner.replay(record, with: record.settings)
    expect(zip(record.frames, replay.frames).allSatisfy { $0.active == $1.active })
}
func targetEdgeDoesNotCutOffButUpperRiskDoes() throws {
    var settings = EngineSettings(); settings.jitter = 0; settings.holdoff = 60
    settings.edgeTarget = 300
    let engine = try Engine(settings: settings)
    try engine.arm(true, at: 0)
    _ = try engine.step(450, at: 0)
    let edge = try engine.step(0, at: 0.02)
    expect(edge.score >= settings.effectiveEdgeTarget && edge.score < settings.sensitivity)
    expect(edge.wantsPower && !edge.edge && edge.riskReason == nil)
    _ = try engine.step(900, at: 0.04)
    let risk = try engine.step(0, at: 0.06)
    expect(risk.edge && !risk.wantsPower && risk.controlPhase == 1)
    expect(risk.riskReason == "Upper score threshold") // Bypasses even a 60-second restart holdoff.
    expect(try !engine.step(0, at: 0.08).edge) // One cutoff, not one per sample.
    var resumed = false
    for tick in 5..<1000 {
        let output = try engine.step(0, at: Double(tick)/50)
        if output.wantsPower {
            expect(output.score <= settings.effectiveEdgeTarget)
            expect(Double(tick)/50 >= 5.06)
            resumed = true; break
        }
    }
    expect(resumed)
}

func rhythmicWarningCutsBeforeConfirmedDetection() throws {
    var settings = EngineSettings()
    settings.sensitivity = 60000; settings.edgeTarget = 30000
    settings.arousalGate = 0; settings.detectionMode = 2
    settings.minimumPeaks = 8
    let engine = try Engine(settings: settings)
    try engine.arm(true, at: 0)
    var warningSeen = false
    for tick in 0..<700 {
        let time = Double(tick)/50
        let pressure = time < 2 ? UInt16(0) : UInt16(600 + 350 * (1 + sin(time * 2 * .pi / 0.8)))
        let output = try engine.step(pressure, at: time)
        if output.detectionPhase == 2 {
            expect(output.score < settings.sensitivity)
            expect(!output.detected && !output.wantsPower && output.controlPhase == 1)
            expect(output.riskReason == "Rhythmic warning")
            warningSeen = true; break
        }
    }
    expect(warningSeen)
}

func revisedLabelsAndLegacyArchivesStaySeparate() throws {
    let settings = EngineSettings()
    var record = reviewedSession(active: settings, candidate: nil, count: 2)
    record.feedback = [Feedback(time: 10, episode: 1, kind: .edge)]
    expect(Learner.evidence([record], settings: settings)[.peakScore]!.contradictions == 1)
    record.feedback[0].kind = .tooClose
    expect(Learner.evidence([record], settings: settings)[.peakScore]!.matches == 1)
    record.feedback[0].kind = .orgasm
    expect(Learner.evidence([record], settings: settings)[.peakScore]!.matches == 1)
    record.policyVersion = nil
    expect(Learner.evidence([record], settings: settings)[.peakScore]!.total == 0)
    let legacy = try Engine(settings: settings, policy: .legacyEdgeCutoff)
    try legacy.arm(true, at: 0)
    record.frames = []
    for tick in 0..<100 {
        let time = Double(tick)/50
        let pressure: UInt16 = tick % 2 == 0 ? 800 : 0
        record.frames.append(Frame(time: time, base: pressure, tip: 0, pressure: pressure, armed: true,
                                   episode: 1, active: try legacy.step(pressure, at: time)))
    }
    let replay = try Learner.replay(record, with: settings)
    expect(zip(record.frames, replay.frames).allSatisfy { $0.active == $1.active })
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
    object.removeValue(forKey: "edgeTarget")
    let oldSettings = try JSONDecoder().decode(EngineSettings.self, from: JSONSerialization.data(withJSONObject: object))
    expect(oldSettings.effectiveEdgeTarget == 360)
    let profile = LearningProfile(key: "new-policy", baseline: oldSettings)
    expect(profile.active.edgeTarget == 360)
}

func replayPreservesSubTickActions() throws {
    let settings = EngineSettings(), engine = try Engine(settings: EngineSettings())
    var record = SessionRecord(profile: "real", simulated: false, settings: settings, candidate: nil, seed: 1, baseline: 0, gain: 1)
    record.armChanges = [ArmChange(time: 0, armed: true), ArmChange(time: 1.003, armed: false)]
    try engine.arm(true, at: 0)
    var stopped = false
    for i in 0..<150 {
        let time = 0.013 + Double(i)/50
        if time >= 1.003 && !stopped { try engine.arm(false, at: 1.003); stopped = true }
        let output = try engine.step(0, at: time)
        record.frames.append(Frame(time: time, base: 0, tip: 0, pressure: 0, armed: !stopped, episode: 1, active: output))
    }
    let replay = try Learner.replay(record, with: settings)
    expect(zip(record.frames, replay.frames).allSatisfy { $0.active == $1.active })
}

func incorrectEventCanTeachShadowRejection() {
    let settings = EngineSettings()
    var candidate = settings; candidate.sustainedThreshold = 210
    var record = reviewedSession(active: settings, candidate: candidate, count: 2)
    record.feedback = [Feedback(time: 10, episode: 1, kind: .eventIncorrect, anchor: 10, signal: .sustained)]
    record.frames[1].active.detected = true
    let before = Learner.evidence([record], settings: settings)[.sustained]!
    let after = Learner.evidence([record], settings: candidate, shadow: true)[.sustained]!
    expect(before.contradictions == 1 && after.matches == 1 && after.corrections == 1)
}

func buildupIsContextRatherThanACutoffLabel() {
    let settings = EngineSettings()
    var record = reviewedSession(active: settings, candidate: nil, count: 2)
    record.feedback = [Feedback(time: 10, episode: 1, kind: .closer)]
    record.frames[1].active.score = 700
    expect(Learner.buildupObservations([record], settings: settings)[.peakScore]!.matches == 1)
    expect(Learner.evidence([record], settings: settings)[.peakScore]!.total == 0)
}

func persistedCandidateCannotBypassBounds() throws {
    let settings = EngineSettings()
    var unsafe = settings; unsafe.sensitivity = 1000
    var profile = LearningProfile(key: "real", baseline: settings); profile.candidate = unsafe
    let records = (0..<3).map { _ in reviewedSession(active: settings, candidate: unsafe) }
    let result = try Learner.update(profile, records: records)
    expect(result.active == settings && result.candidate == nil)
}

func independentVibrationTargetsAndTiming() throws {
    var settings = VibrationSettings()
    settings.one.start = 0; settings.one.target = 100; settings.one.rampSeconds = 2
    settings.two.start = 0; settings.two.target = 50; settings.two.mode = .steps
    settings.two.stepPercent = 10; settings.two.stepSeconds = 0.5
    var envelope = VibrationEnvelope()
    let limits = VibrationLevels(255, 200)
    var levels = VibrationLevels.zero
    for tick in 0...100 {
        levels = try envelope.step(settings, limits: limits, permitted: true, time: Double(tick)/50)
        expect(levels.one <= 255 && levels.two <= 100)
        if tick == 24 { expect(levels.one > 40 && levels.two == 0) }
        if tick == 25 { expect(levels.two == 20) }
    }
    expect(levels.one == 255 && levels.two == 80)
    settings.one.target = 20
    levels = try envelope.step(settings, limits: limits, permitted: true, time: 2.02)
    expect(levels.one == 51 && levels.two == 80)
    settings.one.target = 60
    levels = try envelope.step(settings, limits: limits, permitted: true, time: 2.04)
    expect(levels.one > 51 && levels.one < 153 && levels.two == 80)
    expect(try envelope.step(settings, limits: limits, permitted: false, time: 2.06) == .zero)
    let restarted = try envelope.step(settings, limits: limits, permitted: true, time: 2.08)
    expect(restarted.one < 5 && restarted.two == 0)
}

func vibrationLimitsAndDisabledChannels() throws {
    var settings = VibrationSettings()
    settings.one.target = 0; settings.two.target = 80; settings.two.mode = .constant
    var envelope = VibrationEnvelope()
    expect(try envelope.step(settings, limits: VibrationLevels(120, 180), permitted: true, time: 0) == VibrationLevels(0, 144))
    settings.two.target = 0
    expect(try envelope.step(settings, permitted: true, time: 0.02) == .zero)
    expectThrows { try envelope.step(settings, limits: VibrationLevels(0, 255), permitted: true, time: 1) }
    settings.one.target = .nan
    expectThrows { try settings.validated() }
    settings.one.target = 1; settings.two.stepSeconds = 0
    expectThrows { try settings.validated() }
    let legacy = Data(#"{"gain":1,"baselineSettings":{"sensitivity":600,"sustainedThreshold":200,"peakAmplitude":40,"decay":60,"averaging":false,"smoothing":5,"cooldown":5,"jitter":1,"holdoff":1,"detectionMode":0,"sustainedDuration":5,"sustainedDropout":0.5,"minimumPeaks":4,"intervalMinimum":0.5,"intervalMaximum":1.2,"intervalVariance":0.2,"rhythmicTimeout":1.5,"arousalGate":70,"recovery":3,"clenchBoost":false,"boostAmount":5},"learning":true,"verifiedPeripheral":"","verifiedService":"","verifiedCharacteristic":"","profileGeneration":"old"}"#.utf8)
    expect(try JSONDecoder().decode(Preferences.self, from: legacy).effectiveVibration == VibrationSettings())
}

func boundedUSBProtocolAndFraming() throws {
    let session = String(repeating: "a", count: 32)
    let hello = try USBWire.command("HELLO", session: session)
    expect(String(decoding: hello, as: UTF8.self) == "PE1 HELLO \(session)\n")
    let set = try USBWire.command("SET", session: session, sequence: 2, levels: VibrationLevels(120, 80))
    expect(String(decoding: set, as: UTF8.self) == "PE1 SET \(session) 2 120 80\n")
    expect(try USBWire.parse("PE1 READY \(session) 2 200 180 1000") == .ready(session: session, limits: VibrationLevels(200, 180)))
    expect(try USBWire.parse("PE1 ACK \(session) 2 ARMED 120 80") == .ack(session: session, sequence: 2, armed: true, levels: VibrationLevels(120, 80)))
    var buffer = USBLineBuffer()
    var result: [String] = []
    for byte in "PE1 BOOT 1\r\nPE1 ACK \(session) 3 DISARMED 0 0\n".utf8 { result += try buffer.append(Data([byte])) }
    expect(result.count == 2 && result[0] == "PE1 BOOT 1")
    for line in ["PE1 READY \(session) 4 255 255 1000", "PE1 READY \(session) 2 255 255 2000",
                 "PE1 ACK \(session) 0 ARMED 0 0", "PE1 ACK \(session) 1 DISARMED 1 0",
                 "PE1 ACK \(session) 1 ARMED 999 0", "PE1 ACK bad 1 ARMED 0 0"] {
        expectThrows { try USBWire.parse(line) }
    }
    expectThrows { try buffer.append(Data(repeating: 65, count: 200)) }
    expectThrows { try USBWire.command("SET", session: session, sequence: 1, levels: VibrationLevels(-1, 0)) }
}

func motorDiscoveryRangesAndProtocol() throws {
    var channel = MotorDiscoveryChannel()
    channel.pwm = 100; _ = try channel.validatePulse(limit: 100)
    channel.pwm = 255; _ = try channel.validatePulse(limit: 255)
    channel.pwm = 101; expectThrows { try channel.validatePulse(limit: 100) }
    channel.pwm = 0; expectThrows { try channel.validatePulse(limit: 100) }
    channel.pwm = -1; expectThrows { try channel.validatePulse(limit: 100) }
    channel.pwm = 8; try channel.completed(pwm: 8, limit: 100)
    expectThrows { try channel.validatePulse(limit: 100) }
    channel.observe(runsNormally: false); expect(channel.minimum == 0)
    try channel.completed(pwm: 16, limit: 100); channel.observe(runsNormally: true)
    try channel.completed(pwm: 24, limit: 100); channel.observe(runsNormally: true)
    expect(channel.minimum == 16 && channel.maximum == 24)
    try channel.completed(pwm: 20, limit: 100); channel.observe(runsNormally: true)
    expect(channel.maximum == 20)
    var setup = MotorCalibration(port: "/dev/cu.test", boardLimits: VibrationLevels(100, 120),
        supplyVoltage: 6.2, minimums: VibrationLevels(16, 24), maximums: VibrationLevels(20, 80))
    _ = try setup.validated()
    var prefs = Preferences(); prefs.motorCalibration = setup
    expect(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs)).motorCalibration == setup)
    setup.supplyVoltage = 6.3; expectThrows { try setup.validated() }
    setup.supplyVoltage = .nan; expectThrows { try setup.validated() }
    setup.supplyVoltage = 6; setup.minimums.one = 21; expectThrows { try setup.validated() }
    var settings = VibrationSettings(); settings.one.target = 1; settings.two.target = 100
    settings.one.mode = .constant; settings.two.mode = .constant
    var envelope = VibrationEnvelope()
    let limits = VibrationLevels(20, 80), minimums = VibrationLevels(16, 24)
    expect(try envelope.step(settings, limits: limits, minimums: minimums, permitted: true, time: 0) == VibrationLevels(16, 80))
    expect(try envelope.step(settings, limits: limits, minimums: minimums, permitted: false, time: 1) == .zero)
    settings.one.target = 0
    expect(try envelope.step(settings, limits: limits, minimums: minimums, permitted: true, time: 2) == VibrationLevels(0, 80))
    expectThrows { try envelope.step(settings, limits: limits, minimums: VibrationLevels(21, 24), permitted: true, time: 3) }
    let session = String(repeating: "b", count: 32)
    expect(try USBWire.parse("PE1 READY \(session) 2 100 120 1000 TEST250") == .ready(session: session, limits: VibrationLevels(100, 120), discovery: true))
    expectThrows { try USBWire.parse("PE1 READY \(session) 2 100 120 1000 TEST999") }
    expect(try String(decoding: USBWire.command("TEST", session: session, sequence: 1, levels: VibrationLevels(8, 0)), as: UTF8.self) == "PE1 TEST \(session) 1 8 0\n")
    expectThrows { try USBWire.command("TEST", session: session, sequence: 1, levels: .zero) }
    expectThrows { try USBWire.command("TEST", session: session, sequence: 1, levels: VibrationLevels(8, 8)) }
}

func windowedPressureLearningAndProspectiveMarks() throws {
    let settings = EngineSettings()
    var record = SessionRecord(profile: "marks", simulated: false, settings: settings, candidate: nil, seed: 1, baseline: 1000, gain: 1)
    record.complete = true
    record.recordingGaps = [RecordingGap(start: 3, end: 4, reason: "Pressure readings missing")]
    for tick in 0...300 {
        let t = Double(tick)/10, pressure: UInt16 = t < 15 ? 100 : 800
        var snapshot = Snapshot(); snapshot.score = Int(pressure); snapshot.sustained = Double(pressure)/100
        record.frames.append(Frame(time: t, base: 1000+pressure, tip: 500+pressure, pressure: pressure, armed: true, episode: 1, active: snapshot))
    }
    record.feedback = [Feedback(time: 10, episode: 1, kind: .edge), Feedback(time: 20, episode: 1, kind: .orgasm)]
    let examples = Learner.pressureExamples([record])
    expect(examples.count == 2 && examples.first(where: { $0.kind == .edge })?.pressure == 100)
    expect(Learner.evidence([record], settings: settings)[.peakScore]!.total == 1)
    let learned = try Learner.update(LearningProfile(key: "marks", baseline: settings), records: [record])
    expect(learned.pressureExamples?.count == 2 && learned.history.isEmpty)
    let model = learned.markModel!
    expect(model.predict(Learner.markFeatures(Learner.markWindow(record, at: 10)!)) == .edge)
    expect(model.predict(Learner.markFeatures(Learner.markWindow(record, at: 20)!)) == .orgasm)
    expect(MarkModel.trained(on: examples, previous: model)?.id == model.id)
    expect(Learner.markEvidence([record])[.orgasm]!.total == 0) // No retrospective confidence.
    let decoded = try JSONDecoder().decode(LearningProfile.self, from: JSONEncoder().encode(learned))
    expect(decoded.markModel?.id == model.id && decoded.pressureExamples?.count == 2)

    var overlap = record; overlap.recordingGaps?.append(RecordingGap(start: 18, end: 19, reason: "missing"))
    expect(Learner.pressureExamples([overlap]).count == 1)
    expect(Learner.evidence([overlap], settings: settings)[.sustained]!.total == 0)
    overlap = record; overlap.frames.removeAll { $0.time > 18 && $0.time < 19 }
    expect(Learner.pressureExamples([overlap]).count == 1) // Unflagged holes also rejected.
    overlap = record; overlap.recordingGaps?.append(RecordingGap(start: 18, reason: "missing"))
    expect(Learner.pressureExamples([overlap]).count == 1)
    overlap = record; overlap.eligible = false
    expect(Learner.pressureExamples([overlap]).isEmpty)
    overlap = record; overlap.simulated = true
    expect(Learner.pressureExamples([overlap]).isEmpty)

    var future = record; future.id = UUID(); future.markModel = model
    for index in future.feedback.indices {
        future.feedback[index].id = UUID()
        future.feedback[index].predictedMark = model.predict(Learner.markFeatures(Learner.markWindow(future, at: future.feedback[index].time)!))
        future.feedback[index].predictionModelID = model.id
    }
    var evidence = Learner.markEvidence([future])
    expect(evidence[.edge]!.matches == 1 && evidence[.orgasm]!.matches == 1 && !evidence[.orgasm]!.supported)
    future.feedback.append(future.feedback[0])
    expect(Learner.markEvidence([future])[.edge]!.total == 1)
    future.feedback[1].predictedMark = .edge
    evidence = Learner.markEvidence([future])
    expect(evidence[.orgasm]!.contradictions == 1 && evidence[.edge]!.contradictions == 1)
    var unseen = future
    unseen.feedback = [future.feedback[1]]; unseen.feedback[0].kind = .closer
    expect(Learner.markEvidence([unseen])[.edge]!.contradictions == 1)
    expect(Learner.markEvidence([unseen])[.closer]!.total == 0)
    future.markModel?.id = UUID()
    expect(Learner.markEvidence([future])[.edge]!.total == 0)
    var frozen = learned; frozen.frozen = true
    expect(try Learner.update(frozen, records: [overlap]).pressureExamples?.isEmpty == true)
}

func repeatingPatternsRespectTimingAndCutoffs() throws {
    var pattern = VibrationPattern()
    pattern.minimum = 20; pattern.maximum = 100; pattern.riseSeconds = 2; pattern.fallSeconds = 4; pattern.curve = .linear
    expect(try pattern.level(at: 0, mode: .wave) == 20)
    expect(try pattern.level(at: 1, mode: .wave) == 60)
    expect(try pattern.level(at: 2, mode: .wave) == 100)
    expect(try pattern.level(at: 4, mode: .wave) == 60)
    expect(try pattern.level(at: 6, mode: .wave) == 20)
    expect(try pattern.level(at: 1.9, mode: .pulse) == 100)
    expect(try pattern.level(at: 2, mode: .pulse) == 20)
    pattern.curve = .sine
    let curved = try pattern.level(at: 0.5, mode: .wave)
    expect(curved > 31 && curved < 33)
    expectThrows { try pattern.level(at: .nan, mode: .wave) }
    pattern.minimum = 101; expectThrows { try pattern.validated() }
    pattern.minimum = 0; pattern.fallSeconds = 0.1; expectThrows { try pattern.validated() }

    var settings = VibrationSettings()
    pattern = VibrationPattern(); pattern.curve = .linear; pattern.riseSeconds = 2; pattern.fallSeconds = 2
    settings.one.mode = .wave; settings.one.target = 100; settings.one.pattern = pattern
    var pulses = pattern; pulses.riseSeconds = 0.2; pulses.fallSeconds = 0.6
    settings.two.mode = .pulse; settings.two.target = 50; settings.two.pattern = pulses
    var envelope = VibrationEnvelope()
    let limits = VibrationLevels(100, 200)
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 0) == VibrationLevels(0, 100))
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 0.2).two == 0)
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 1) == VibrationLevels(50, 0))
    expect(try pulses.level(at: 2.4, mode: .pulse) == 100)
    settings.one.pattern!.minimum = 40; settings.one.pattern!.maximum = 60
    settings.one.pattern!.riseSeconds = 1; settings.one.pattern!.fallSeconds = 1
    let mid = try envelope.step(settings, limits: limits, permitted: true, time: 1.1)
    expect((54...55).contains(mid.one) && mid.two == 0)
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 2).one == 60)
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 3.5).one == 25)
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 4).one == 40)
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 4.5).one == 50)
    expect(try envelope.step(settings, limits: limits, permitted: false, time: 4.6) == .zero)
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 10) == VibrationLevels(40, 100))
    settings.one.target = 0
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 10.1) == VibrationLevels(0, 100))
    settings.one.target = 100; settings.one.pattern!.minimum = 0; settings.one.pattern!.maximum = 0
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 10.5) == .zero)
    expectThrows { try envelope.step(settings, limits: limits, permitted: true, time: 9) }

    envelope.reset(); settings.one.target = 100; settings.two.target = 0; settings.one.pattern = pattern
    _ = try envelope.step(settings, limits: limits, permitted: true, time: 0)
    settings.one.pattern!.riseSeconds = 3; settings.one.pattern!.fallSeconds = 3
    _ = try envelope.step(settings, limits: limits, permitted: true, time: 1)
    // The new six-second period begins at the first old boundary (4s), even if ticks are skipped.
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 13).one == 100)

    envelope.reset(); settings.one.pattern = VibrationPattern(); settings.two.target = 0
    expect(try envelope.step(settings, limits: limits, minimums: VibrationLevels(15, 15), permitted: true, time: 0) == .zero)
    expect(try envelope.step(settings, limits: limits, minimums: VibrationLevels(15, 15), permitted: true, time: 0.01).one == 15)
    let legacy = Data(#"{"target":50,"start":4,"mode":"ramp","rampSeconds":30,"stepPercent":5,"stepSeconds":1}"#.utf8)
    expect(try JSONDecoder().decode(VibrationChannel.self, from: legacy).effectivePattern == VibrationPattern())
    let roundTrip = try JSONDecoder().decode(VibrationSettings.self, from: JSONEncoder().encode(settings))
    expect(roundTrip == settings)
    let change = VibrationTargetChange(time: 1, settings: settings)
    expect(try JSONDecoder().decode(VibrationTargetChange.self, from: JSONEncoder().encode(change)).settings == settings)
}

func calibrationPersistenceAndIdentity() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LocalStore(directory: directory), device = UUID()
    var calibration = PressureCalibration(peripheral: device.uuidString, service: "AA40", characteristic: "AA41", baseline: 1234.5, gain: 2)
    var prefs = Preferences(); prefs.pressureCalibration = calibration; prefs.lastInputWasDemo = false; prefs.lastOutput = .arduino
    prefs.motorCalibration = MotorCalibration(port: "/dev/cu.saved", boardLimits: VibrationLevels(200, 180), supplyVoltage: 6,
                                             minimums: VibrationLevels(15, 20), maximums: VibrationLevels(100, 120))
    try store.save(prefs)
    let reopened = try LocalStore(directory: directory).preferences()
    expect(reopened.pressureCalibration == calibration && reopened.lastInputWasDemo == false)
    expect(reopened.lastOutput == .arduino)
    expect(reopened.motorCalibration == prefs.motorCalibration)
    expect(calibration.matches(peripheral: device, service: "aa40", characteristic: "AA41", gain: 2))
    expect(!calibration.matches(peripheral: UUID(), service: "AA40", characteristic: "AA41", gain: 2))
    expect(!calibration.matches(peripheral: device, service: "AA40", characteristic: "AA42", gain: 2))
    expect(!calibration.matches(peripheral: device, service: "AA40", characteristic: "AA41", gain: 1))
    expect(!calibration.matches(peripheral: nil, service: "AA40", characteristic: "AA41", gain: 2))
    calibration.baseline = .nan; expectThrows { try calibration.validated() }
    calibration.baseline = 65536; expectThrows { try calibration.validated() }
}

func pressureFreshnessKeepsTransientPausesSeparateFromLoss() {
    expect(PressureFreshness.evaluate(sampleTime: 10, now: 13) == .fresh)
    expect(PressureFreshness.evaluate(sampleTime: 10, now: 10.5, controllingOutput: true) == .fresh)
    expect(PressureFreshness.evaluate(sampleTime: 10, now: 10.501, controllingOutput: true) == .waiting)
    expect(PressureFreshness.evaluate(sampleTime: 10, now: 15.001, controllingOutput: true) == .lost)
    expect(PressureFreshness.evaluate(sampleTime: 10, now: 13.001) == .waiting)
    expect(PressureFreshness.evaluate(sampleTime: 10, now: 15) == .waiting)
    expect(PressureFreshness.evaluate(sampleTime: 10, now: 15.001) == .lost)
    expect(PressureFreshness.evaluate(sampleTime: nil, now: 10) == .lost)
    expect(PressureFreshness.evaluate(sampleTime: 11, now: 10) == .lost)
    expect(PressureFreshness.evaluate(sampleTime: .nan, now: 10) == .lost)
}

func timedEdgingPenaltyAndCompletion() throws {
    var timer = TimedEdging(seconds: 60, edge: 350, cutoff: 570)
    timer.locked = true; timer.sessionOpen = true
    timer.advance(seconds: 20)
    expect(timer.remaining == 40 && !timer.completed)
    let encoded = try JSONEncoder().encode(timer)
    timer = try JSONDecoder().decode(TimedEdging.self, from: encoded)
    timer.recoverInterruptedSession()
    expect(timer.locked && !timer.sessionOpen && timer.penaltyEdgesRemaining == 5 && timer.remaining == 60)
    timer.recoverInterruptedSession()
    expect(timer.penaltyEdgesRemaining == 5)
    timer.sessionOpen = true
    for remaining in stride(from: 4, through: 0, by: -1) {
        timer.advance(seconds: 100)
        expect(timer.remaining == 60 && !timer.completed)
        timer.advance(seconds: 0, automaticEdge: true)
        expect(timer.penaltyEdgesRemaining == remaining)
    }
    timer.advance(seconds: 59.9); expect(!timer.completed)
    timer.advance(seconds: 0.1); expect(timer.completed && timer.remaining == 0)
    timer.recoverInterruptedSession(); expect(timer.completed && timer.penaltyEdgesRemaining == 0)
    var invalid = timer; invalid.seconds = .nan
    expectThrows { try invalid.validated() }
    invalid = timer; invalid.elapsedSeconds = 61
    expectThrows { try invalid.validated() }
    var repeated = TimedEdging(seconds: 1, edge: 350, cutoff: 570)
    repeated.sessionOpen = true; repeated.recoverInterruptedSession()
    repeated.sessionOpen = true; repeated.recoverInterruptedSession()
    expect(repeated.penaltyEdgesRemaining == 10)
    var preferences = Preferences(); preferences.timedEdging = timer
    expect(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)).timedEdging == timer)
}

func xtoysCommandsAndMotorCaps() throws {
    var demand = XToysDemand()
    try demand.apply(XToysCommand.parse(Data(#"{"channel":1,"vibrate":50}"#.utf8)))
    try demand.apply(XToysCommand.parse(Data(#"{"channel":2,"vibrate":100}"#.utf8)))
    var settings = VibrationSettings(); settings.one.target = 80; settings.two.target = 50
    expect(try demand.levels(settings: settings, limits: VibrationLevels(200, 180), minimums: .zero, permitted: true) == VibrationLevels(80, 90))
    expect(try demand.levels(settings: settings, limits: VibrationLevels(200, 180), minimums: .zero, permitted: false) == .zero)
    try demand.apply(XToysCommand.parse(Data(#"{"channel":1,"vibrate":0}"#.utf8)))
    expect(try demand.levels(settings: settings, limits: VibrationLevels(200, 180), minimums: VibrationLevels(100, 100), permitted: true) == VibrationLevels(0, 100))
    for invalid in [#"{"channel":0,"vibrate":50}"#, #"{"channel":3,"vibrate":50}"#,
                    #"{"channel":1,"vibrate":101}"#, #"{"channel":1,"vibrate":-1}"#,
                    #"{"channel":1,"vibrate":true}"#, #"{"channel":true,"vibrate":50}"#,
                    #"{"channel":1,"vibrate":"50"}"#, #"{"vibrate":50}"#, "[]"] {
        expectThrows { try XToysCommand.parse(Data(invalid.utf8)) }
    }
    expectThrows { try XToysCommand.parse(Data(repeating: 65, count: 513)) }
}

func thirdMotorControlAndLegacyMigration() throws {
    let legacy = try JSONDecoder().decode(VibrationLevels.self, from: Data(#"{"one":12,"two":34}"#.utf8))
    expect(legacy == VibrationLevels(12, 34, 0))
    var settings = VibrationSettings(); settings.one.target = 20; settings.two.target = 40
    settings.one.mode = .constant; settings.two.mode = .constant
    let oldData = try JSONEncoder().encode(["one": settings.one, "two": settings.two])
    let restored = try JSONDecoder().decode(VibrationSettings.self, from: oldData)
    expect(restored.three.target == 0 && restored.profileKey == settings.profileKey)
    settings.three.target = 100; settings.three.mode = .wave
    var shape = VibrationPattern(); shape.curve = .linear; shape.riseSeconds = 2; shape.fallSeconds = 2
    settings.three.pattern = shape
    var envelope = VibrationEnvelope(); let limits = VibrationLevels(200, 180, 160)
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 0) == VibrationLevels(40, 72, 0))
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 1) == VibrationLevels(40, 72, 80))
    settings.three.mode = .constant; settings.three.target = 50
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 1.1) == VibrationLevels(40, 72, 80))
    settings.three.target = 0
    expect(try envelope.step(settings, limits: limits, permitted: true, time: 1.2) == VibrationLevels(40, 72, 0))
    expect(try envelope.step(settings, limits: limits, permitted: false, time: 1.3) == .zero)
    settings.three.target = 100
    expect(try envelope.step(settings, limits: VibrationLevels(200, 180), permitted: true, time: 1.4).three == 0)
    let nonce = String(repeating: "a", count: 32)
    expect(try String(decoding: USBWire.command("SET", session: nonce, sequence: 1, levels: VibrationLevels(1, 2, 3), channels: 3), as: UTF8.self) == "PE1 SET \(nonce) 1 1 2 3\n")
    expect(try USBWire.parse("PE1 READY \(nonce) 3 200 180 160 1000 TEST250") == .ready(session: nonce, limits: limits, discovery: true))
    expect(try USBWire.parse("PE1 ACK \(nonce) 1 ARMED 1 2 3", expectedChannels: 3) == .ack(session: nonce, sequence: 1, armed: true, levels: VibrationLevels(1, 2, 3)))
    expectThrows { try USBWire.parse("PE1 ACK \(nonce) 1 ARMED 1 2", expectedChannels: 3) }
    expectThrows { try USBWire.command("SET", session: nonce, sequence: 1, levels: VibrationLevels(0, 0, 1)) }
    expectThrows { try USBWire.command("TEST", session: nonce, sequence: 1, levels: VibrationLevels(1, 0, 1), channels: 3) }
    var demand = XToysDemand()
    try demand.apply(XToysCommand.parse(Data(#"{"vibrate":50}"#.utf8), mappedChannel: 3))
    expect(demand.three == 50 && demand.one == 0 && demand.two == 0)
    expect(try demand.levels(settings: settings, limits: limits, minimums: .zero, permitted: true).three == 80)
    expectThrows { try XToysCommand.parse(Data(#"{"channel":2,"vibrate":50}"#.utf8), mappedChannel: 3) }
}

func finderIntervalsRefinementAndMotorSelection() throws {
    var random = SystemRandomNumberGenerator()
    var settings = VibrationSettings()
    settings.one.target = 40; settings.two.target = 75; settings.three.target = 30
    for motors: Set<Int> in [[], [-1], [3]] {
        expectThrows { try PatternFinder(settings: settings, motors: motors, targetLevel: 4, random: &random) }
    }
    expectThrows { try PatternFinder(settings: settings, motors: [2], targetLevel: 4, availableChannels: 2, random: &random) }
    expectThrows { try PatternFinder(settings: VibrationSettings(), motors: [0], targetLevel: 4, random: &random) }
    expectThrows { try PatternFinder(settings: settings, motors: [0], targetLevel: 0, random: &random) }
    var finder = try PatternFinder(settings: settings, motors: [0, 2], targetLevel: 4, random: &random)
    var time = 0.0
    func trial(_ rate: Double) throws {
        let original = finder.candidate
        _ = try original.validated()
        expect(original.one.target == 40 && original.two.target == 0 && original.three.target == 30)
        for step in 0...100 {
            let t = Double(step) / 10
            try finder.observe(score: 100 + rate * t, time: time + t, permitted: true, random: &random)
            if step < 100 { expect(finder.candidate == original) }
        }
        time += 11
    }
    for _ in 0..<21 { try trial(0) }
    expect(finder.running && finder.currentLevel == 1 && !finder.isFinalLevel && finder.trialsWithoutImprovement == 0)
    try trial(-1); expect(finder.results.isEmpty)
    try trial(2); expect(finder.results.count == 1 && abs(finder.results[0].rate - 2) < 1e-8)
    try trial(1); expect(finder.results.count == 1) // Positive but slower is not an improvement.
    for _ in 0..<21 { try trial(0) }
    expect(finder.running && finder.currentLevel == 2 && finder.trialsWithoutImprovement == 0)
    try trial(3)
    for _ in 0..<21 { try trial(0) }
    expect(finder.running && finder.currentLevel == 3 && finder.trialsWithoutImprovement == 0)
    try trial(4)
    expect(finder.currentLevel == 4 && finder.isFinalLevel && finder.trialsWithoutImprovement == 0)
    try trial(0); expect(finder.trialsWithoutImprovement == 1)
    try trial(5)
    expect(finder.running && finder.trialsWithoutImprovement == 0)
    for _ in 0..<19 { try trial(0) }
    expect(finder.running && finder.trialsWithoutImprovement == 19)
    try trial(6); expect(finder.running && finder.results.count == 4 && finder.trialsWithoutImprovement == 0)
    for _ in 0..<20 { try trial(0) }
    expect(finder.endedForNoImprovement && finder.trialsWithoutImprovement == 20)
    expect(!finder.running && finder.results.count == 4 && finder.candidate.channels.allSatisfy { $0.target == 0 })
    expect(finder.results.map(\.level) == [1, 2, 3, 4])
    expect(finder.results.allSatisfy { $0.seconds >= 10 && $0.settings.two.target == 0 })
    var envelope = VibrationEnvelope()
    let winner = finder.results.last!.settings
    for step in 0...100 {
        let value = try envelope.step(winner, permitted: true, time: Double(step) / 10)
        expect(value.two == 0 && value.one <= 102 && value.three <= 76)
    }
    expect(try envelope.step(winner, permitted: false, time: 10.1) == .zero)
    var interrupted = try PatternFinder(settings: settings, motors: [2], targetLevel: 1, random: &random)
    for step in 0...50 { try interrupted.observe(score: Double(step), time: Double(step) / 10, permitted: true, random: &random) }
    try interrupted.observe(score: 60, time: 5.1, permitted: false, random: &random)
    expect(interrupted.results.isEmpty && interrupted.discardedTrials == 1 && interrupted.secondsRemaining == 10)
    for step in 0...50 { try interrupted.observe(score: Double(step), time: 6 + Double(step) / 10, permitted: true, random: &random) }
    try interrupted.observe(score: 100, time: 12, permitted: true, random: &random)
    expect(interrupted.results.isEmpty && interrupted.discardedTrials == 2)
    for step in 1...100 { try interrupted.observe(score: 100 + Double(step), time: 12 + Double(step) / 10, permitted: true, random: &random) }
    expect(interrupted.running && interrupted.results.count == 1)
    var invalid = try PatternFinder(settings: settings, motors: [0], targetLevel: 1, random: &random)
    expectThrows { try invalid.observe(score: .nan, time: 0, permitted: true, random: &random) }
    try invalid.observe(score: 0, time: 1, permitted: true, random: &random)
    expectThrows { try invalid.observe(score: 0, time: 0, permitted: true, random: &random) }
    invalid.stop(); expect(!invalid.running && invalid.candidate.channels.allSatisfy { $0.target == 0 })
    var irregular = try PatternFinder(settings: settings, motors: [0], targetLevel: 1, random: &random)
    for step in 0...30 {
        try irregular.observe(score: Double(step), time: Double(step) * 0.35, permitted: true, random: &random)
    }
    expect(irregular.results.count == 1 && irregular.discardedTrials == 0)
}

func finderBandLibraryAndBraking() throws {
    var settings = VibrationSettings(); settings.one.target = 40; settings.two.target = 80; settings.three.target = 30
    var library: [FinderResult] = [0.25, 2, 10].enumerated().map { index, rate in
        var pattern = settings; pattern.two.target = 0
        for motor in [0, 2] {
            pattern[motor].mode = .wave
            var shape = VibrationPattern(); shape.riseSeconds = Double(index + 1); pattern[motor].pattern = shape
        }
        return FinderResult(level: index + 1, trial: index + 1, settings: pattern, startScore: 0, endScore: rate * 10, seconds: 10, rate: rate)
    }
    var downProbe = try FinderDownTrial(pattern: library[0])
    for step in 0...100 { try downProbe.observe(score: 500 - Double(step), time: Double(step) / 10, permitted: true, interruptionReason: "test") }
    for index in library.indices { library[index].descent = downProbe.result }
    for result in library { _ = try result.validated() }
    var band = try FinderBand(settings: settings, motors: [0, 2])
    try band.update(score: 100, time: 0, permitted: true, edge: 360, cutoff: 600, library: library)
    expect(band.phase == .building && band.selectedRate == 10 && band.candidate.two.target == 0)
    var near = try FinderBand(settings: settings, motors: [0, 2])
    try near.update(score: 596, time: 0, permitted: true, edge: 360, cutoff: 600, library: library)
    expect(near.selectedRate == 0.25) // Use a gentler learned rise in the final 1%.
    var down = try FinderBand(settings: settings, motors: [0, 2])
    try down.update(score: 596, time: 0, permitted: true, edge: 360, cutoff: 600, library: library)
    let upwardPattern = down.candidate
    try down.update(score: 596.2, time: 0.1, permitted: true, edge: 360, cutoff: 600, library: library)
    expect(down.phase == .building) // One small jump is not sustained acceleration.
    try down.update(score: 596.8, time: 0.2, permitted: true, edge: 360, cutoff: 600, library: library)
    expect(down.phase == .building && down.queuedPhase == .easing && down.candidate == upwardPattern)
    try down.update(score: 596.85, time: 0.3, permitted: true, edge: 360, cutoff: 600, library: library)
    expect(down.outputScale == 1 && down.candidate.two.target == 0)
    for step in 4..<100 {
        try down.update(score: 596.85, time: Double(step) / 10, permitted: true, edge: 360, cutoff: 600, library: library)
        expect(down.phase == .building && down.candidate == upwardPattern)
    }
    try down.update(score: 596.85, time: 10, permitted: true, edge: 360, cutoff: 600, library: library)
    expect(down.phase == .easing && down.candidate == upwardPattern)
    try down.update(score: 596.85, time: 10.1, permitted: true, edge: 360, cutoff: 600, library: library)
    expect(down.outputScale < 1)
    try down.update(score: 600, time: 10.2, permitted: true, edge: 360, cutoff: 600, library: library)
    expect(down.phase == .off && down.candidate.channels.allSatisfy { $0.target == 0 })
    var rising = try FinderBand(settings: settings, motors: [0, 2])
    for step in 0...10 { try rising.update(score: 450 + Double(step * 10), time: Double(step) / 10, permitted: true, edge: 360, cutoff: 600, library: library) }
    expect(rising.phase == .building && rising.candidate.channels.contains { $0.target > 0 })
    try rising.update(score: 590, time: 1.1, permitted: true, edge: 360, cutoff: 600, library: library)
    expect(rising.candidate.channels.contains { $0.target > 0 })
    try rising.update(score: 600, time: 1.2, permitted: true, edge: 360, cutoff: 600, library: library)
    expect(rising.candidate.channels.allSatisfy { $0.target == 0 })
    try band.update(score: 100, time: 0.35, permitted: true, edge: 360, cutoff: 600, library: library)
    expect(band.phase == .building) // Normal scheduling gaps are not pressure loss.
    try band.update(score: 100, time: 1.35, permitted: true, edge: 360, cutoff: 600, library: library)
    expect(band.phase == .cooldown && band.candidate.channels.allSatisfy { $0.target == 0 })
    try near.update(score: 400, time: 0.1, permitted: false, edge: 360, cutoff: 600, library: library)
    expect(near.phase == .cooldown && near.candidate.channels.allSatisfy { $0.target == 0 })
    var noMatch = try FinderBand(settings: settings, motors: [1])
    try noMatch.update(score: 100, time: 0, permitted: true, edge: 360, cutoff: 600, library: library)
    expect(noMatch.candidate.channels.allSatisfy { $0.target == 0 })
    var preferences = Preferences(); preferences.finderLibrary = ["real-sensor-profile": library]
    preferences.finderSetup = FinderSetup(motors: [0, 2], levels: 4, easingPercent: 15)
    let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)).validated()
    expect(restored.finderLibrary?["real-sensor-profile"]?.map(\.id) == library.map(\.id))
    expect(restored.finderLibrary?["demo"] == nil)
    expect(restored.finderSetup?.motors == [0, 2] && restored.finderSetup?.levels == 4)
    expectThrows { try band.update(score: .nan, time: 2, permitted: true, edge: 360, cutoff: 600, library: library) }
}

func finderPlateauDownwardResponseAndLiveRates() throws {
    var settings = VibrationSettings(); settings.one.target = 100
    var random = SystemRandomNumberGenerator()
    var finder = try PatternFinder(settings: settings, motors: [0], targetLevel: 1, random: &random)
    for trial in 0..<20 {
        for step in 0...100 { try finder.observe(score: 100, time: Double(trial * 11) + Double(step) / 10, permitted: true, random: &random) }
    }
    expect(!finder.running && finder.results.isEmpty && finder.bestTrial?.fallback == true && finder.endedForNoImprovement)
    var down = try FinderDownTrial(pattern: finder.bestTrial!)
    for step in 0...100 {
        try down.observe(score: 100 - Double(step) * 0.3, time: Double(step) / 10, permitted: true, interruptionReason: "test")
        expect(abs(down.scale - (1 - Double(step) / 100)) < 1e-8)
    }
    expect(abs(down.result!.rate + 3) < 1e-8 && down.result!.endScore == 70 && down.result!.secondsToFall != nil)
    var wave = VibrationPattern(); wave.curve = .linear; wave.riseSeconds = 2; wave.fallSeconds = 2
    settings.one.mode = .wave; settings.one.pattern = wave
    var envelope = VibrationEnvelope()
    _ = try envelope.step(settings, permitted: true, time: 0)
    expect(try envelope.step(settings, permitted: true, time: 1, outputScale: 0.5).one == 63)
    expect(try envelope.step(settings, permitted: true, time: 2, outputScale: 0.5).one == 127)
    expect(try envelope.step(settings, permitted: true, time: 3, outputScale: 0.25).one == 31)
    expect(try envelope.step(settings, permitted: true, time: 4, outputScale: 0) == .zero)
    var observed = FinderResult(level: 1, trial: 1, settings: settings, startScore: 0, endScore: 10, seconds: 10, rate: 1)
    observed.descent = down.result
    var discretePeak = try FinderBand(settings: settings, motors: [0])
    try discretePeak.update(score: 0, time: 0, permitted: true, edge: 500, cutoff: 760, library: [observed])
    try discretePeak.update(score: 152, time: 0.195, permitted: true, edge: 500, cutoff: 760, library: [observed])
    expect(discretePeak.phase == .building && discretePeak.forecastScore < 760 && discretePeak.candidate.one.target > 0)
    expect(discretePeak.predictionScore > 0 && discretePeak.predictionScore < 152)
    var band = try FinderBand(settings: settings, motors: [0])
    try band.update(score: 767, time: 0, permitted: true, edge: 400, cutoff: 770, library: [observed])
    expect(band.phase == .building && band.forecastScore < 769)
    var monitor = FinderRateMonitor()
    for step in 0...100 {
        if let update = monitor.observe(score: 100 + Double(step) * 0.8, time: Double(step) / 10, patternID: observed.id, falling: false) {
            observed.validateLiveRate(update)
        }
    }
    expect(observed.validationCount == 1 && observed.riseRate > 4 && observed.upperRiseRate > observed.riseRate && observed.upperRiseRate < 8)
    try band.update(score: 767, time: 0.1, permitted: true, edge: 400, cutoff: 770, library: [observed])
    expect(band.phase == .building && band.forecastScore >= 770 && band.queuedPhase == .easing && band.candidate.one.target > 0)
    try band.update(score: 770, time: 0.2, permitted: true, edge: 400, cutoff: 770, library: [observed])
    expect(band.phase == .off && band.candidate.channels.allSatisfy { $0.target == 0 })
    var changedCutoff = try FinderBand(settings: settings, motors: [0])
    try changedCutoff.update(score: 763, time: 0, permitted: true, edge: 400, cutoff: 760, library: [observed])
    expect(changedCutoff.phase == .off)
    expect(monitor.observe(score: 500, time: 4, patternID: observed.id, falling: false) == nil)
    let restored = try JSONDecoder().decode(FinderResult.self, from: JSONEncoder().encode(observed)).validated()
    expect(restored.validationCount == 1 && restored.descent?.rate == observed.descent?.rate)
}

func finderCutoffMeasurementsAndQueuedTrials() throws {
    var settings = VibrationSettings(); settings.one.target = 40
    var random = SystemRandomNumberGenerator()
    var finder = try PatternFinder(settings: settings, motors: [0], targetLevel: 4, random: &random)
    let original = finder.candidate
    var next = original; next.one.mode = original.one.mode == .wave ? .pulse : .wave
    try finder.queueNextPattern(preferred: next, random: &random)
    for step in 0..<20 {
        try finder.observe(score: 100 + Double(step) * 33, time: Double(step) / 10, permitted: true, random: &random)
        expect(finder.candidate == original)
    }
    try finder.observe(score: 760, time: 2, permitted: false, actualCutoff: true, random: &random)
    let measured = try finder.latestTrial!.validated()
    expect(measured.cutoffLimited == true && measured.seconds == 2 && abs(measured.rate - 330) < 1e-8)
    expect(finder.results.count == 1 && finder.candidate == next && finder.discardedTrials == 0)
    let restored = try JSONDecoder().decode(FinderResult.self, from: JSONEncoder().encode(measured)).validated()
    expect(restored.cutoffLimited == true && restored.seconds == 2)
    var falling = try FinderDownTrial(pattern: measured)
    try falling.observe(score: 700, time: 0, permitted: true, interruptionReason: "test")
    try falling.observe(score: 730, time: 0.5, permitted: true, interruptionReason: "test")
    try falling.observe(score: 760, time: 1, permitted: false, interruptionReason: "cutoff", actualCutoff: true)
    expect(try falling.result?.validated().cutoffLimited == true)
    expect(falling.result?.seconds == 1 && abs(falling.result!.rate - 60) < 1e-8)
}

func finderLibraryPruningAndLongRun() throws {
    var settings = VibrationSettings(); settings.one.target = 40
    var library = (1...64).map { index -> FinderResult in
        var pattern = settings; pattern.one.mode = .wave
        var shape = VibrationPattern(); shape.maximum = Double(index); pattern.one.pattern = shape
        return FinderResult(level: 1, trial: index, settings: pattern, startScore: 0,
                            endScore: Double(index * 10), seconds: 10, rate: Double(index))
    }
    library[31].fallSamples = [-8]
    let protected: Set<UUID> = [library[5].id, library[6].id]
    let original = library
    library = FinderResult.prunedLibrary(library, keeping: protected)
    expect(library.count == 15 && protected.isSubset(of: Set(library.map(\.id))))
    expect(library.contains { $0.id == original[0].id } && library.contains { $0.id == original[63].id })
    expect(library.contains { $0.id == original[31].id })
    expect(FinderResult.prunedLibrary(library).map(\.id) == library.map(\.id))
    expect(FinderResult.prunedLibrary(original, keeping: protected).map(\.id) == library.map(\.id))
    var band = try FinderBand(settings: settings, motors: [0]), monitor = FinderRateMonitor()
    // Two virtual hours: selection and continuing learning stay bounded after pruning.
    for step in 0...72_000 {
        let time = Double(step) / 10, score = 550 + 150 * sin(time / 20)
        try band.update(score: score, time: time, permitted: true, edge: 500, cutoff: 770, library: library)
        if let update = monitor.observe(score: score, time: time, patternID: band.selectedPatternID, falling: band.phase == .easing),
           let index = library.firstIndex(where: { $0.id == update.patternID }) { library[index].validateLiveRate(update) }
    }
    expect(library.contains { ($0.validationCount ?? 0) > 100 })
    expect(library.allSatisfy { ($0.riseSamples?.count ?? 0) <= 12 && ($0.fallSamples?.count ?? 0) <= 12 && ($0.responseDelays?.count ?? 0) <= 12 })
    for pattern in library { _ = try pattern.validated() }
}

func finderSmoothedApproachAndShorterCooldown() throws {
    var settings = VibrationSettings(); settings.one.target = 40
    let library: [FinderResult] = [0, 0.25, 2, 10].enumerated().map { index, rate in
        var pattern = settings; pattern.one.mode = .wave
        var shape = VibrationPattern(); shape.maximum = Double(25 * (index + 1)); pattern.one.pattern = shape
        var result = FinderResult(level: 1, trial: index + 1, settings: pattern, startScore: 100,
                                  endScore: 100 + rate * 10, seconds: 10, rate: rate, fallback: rate == 0)
        result.fallSamples = [-1]; return result
    }
    var noisy = library[2]
    noisy.riseSamples = [-29.07, 172.59, 0, -6.19, 25.55, -49.77, 6.99, -29.54, -12.85, -7.85, -0.21, -29.14]
    expect(noisy.upperRiseRate < 5 && noisy.upperRiseRate > noisy.riseRate)
    var approach = try FinderBand(settings: settings, motors: [0])
    for step in 0...200 {
        try approach.update(score: 200, time: Double(step) / 10, permitted: true, edge: 500, cutoff: 760, library: library + [noisy])
        expect(approach.phase == .building && approach.selectedRate == 10)
    }
    var jump = try FinderBand(settings: settings, motors: [0])
    try jump.update(score: 0, time: 0, permitted: true, edge: 500, cutoff: 760, library: library)
    try jump.update(score: 152, time: 0.195, permitted: true, edge: 500, cutoff: 760, library: library)
    expect(jump.predictionScore < 15 && jump.forecastScore < 500)
    var belowBand = try FinderBand(settings: settings, motors: [0])
    for step in 0...300 {
        try belowBand.update(score: 749, time: Double(step) / 10, permitted: true, edge: 500, cutoff: 760, library: [library[0], library[2]])
        expect(belowBand.selectedPatternID != library[0].id)
    }
    // Known-response simulation: reach the band, then hold without a hard cutoff.
    var closedLoop = try FinderBand(settings: settings, motors: [0]), simulatedScore = 200.0
    var inside = 0
    for step in 0...6000 {
        try closedLoop.update(score: simulatedScore, time: Double(step) / 10, permitted: true, edge: 500, cutoff: 760, library: library)
        expect(closedLoop.phase != .off)
        simulatedScore += (closedLoop.selectedRate ?? 0) * 0.1
        if step >= 4800 && (752.4..<760).contains(simulatedScore) { inside += 1 }
    }
    expect(inside > 1100)
    var hold = try FinderBand(settings: settings, motors: [0])
    for step in 0...300 {
        try hold.update(score: 756, time: Double(step) / 10, permitted: true, edge: 500, cutoff: 760, library: library)
        expect(hold.phase == .building && hold.selectedPatternID == library[0].id)
    }
    try hold.update(score: 760, time: 30.1, permitted: true, edge: 500, cutoff: 760, library: library)
    expect(hold.phase == .off && hold.outputScale == 0)
    var easing = try FinderBand(settings: settings, motors: [0])
    for step in 0...100 { try easing.update(score: 759, time: Double(step) / 10, permitted: true, edge: 500, cutoff: 760, library: library) }
    expect(easing.phase == .easing)
    for step in 101...150 { try easing.update(score: 759 - Double(step - 100) / 10, time: Double(step) / 10, permitted: true, edge: 500, cutoff: 760, library: library) }
    expect(easing.phase == .easing && easing.forecastScore < easing.predictionScore && easing.queuedPhase == .building)
    var control = EngineSettings(); control.cooldown = 3; control.jitter = 0
    let engine = try Engine(settings: control)
    try engine.arm(true, at: 0); _ = try engine.step(0, at: 0); try engine.manualEdge(at: 1)
    expect(try engine.step(0, at: 3.99).controlPhase == 1)
    expect(try engine.step(0, at: 4).controlPhase != 1)
    control.cooldown = 2.99; expectThrows { try control.validated() }
    var timer = TimedEdging(seconds: 100, edge: 500, cutoff: 760)
    timer.locked = true; timer.elapsedSeconds = 25; timer.sessionOpen = false
    timer.recoverInterruptedSession()
    expect(timer.locked && timer.elapsedSeconds == 25 && timer.penaltyEdgesRemaining == 0)
    timer.sessionOpen = true; timer.recoverInterruptedSession()
    expect(timer.locked && timer.elapsedSeconds == 0 && timer.penaltyEdgesRemaining == 5)
}

func finderExplorationAndTrainingResume() throws {
    var settings = VibrationSettings(); settings.one.target = 40; settings.three.target = 30
    var random = SystemRandomNumberGenerator()
    var finder = try PatternFinder(settings: settings, motors: [0,2], targetLevel: 4, random: &random)
    var preferred = settings
    for motor in [0,2] { preferred[motor].mode = .wave; var p = VibrationPattern(); p.maximum = 10; preferred[motor].pattern = p }
    var coverage = [Set<Double>(), Set<Double>()], preferredTrials = 0, combinedHigh = false
    for trial in 0..<20 {
        let candidate = finder.candidate
        expect(candidate.two.target == 0 && candidate.one.target == 40 && candidate.three.target == 30)
        for (slot,motor) in [0,2].enumerated() { coverage[slot].insert(candidate[motor].effectivePattern.maximum) }
        if candidate == preferred { preferredTrials += 1 }
        if [0,2].allSatisfy({ candidate[$0].effectivePattern.maximum == 100 && candidate[$0].effectivePattern.minimum >= 75 }) { combinedHigh = true }
        try finder.queueNextPattern(preferred: preferred, random: &random)
        for tick in 0...100 { try finder.observe(score: 100 + (trial == 0 ? Double(tick) / 5 : 0), time: Double(trial * 11) + Double(tick) / 10, permitted: true, random: &random) }
    }
    expect(coverage.allSatisfy { Set([10.0,25,50,75,100]).isSubset(of: $0) } && combinedHigh)
    expect(preferredTrials <= 5 && finder.currentLevel == 2)
    try finder.observe(score: 100, time: 220, permitted: true, random: &random)
    let trial = finder.trial, ids = finder.results.map(\.id)
    var prefs = Preferences(); prefs.finderProgress = ["setup": finder]
    let saved = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs)).validated()
    var resumed = try saved.finderProgress!["setup"]!.resuming(settings: settings, motors: [0,2], targetLevel: 4)
    expect(resumed.currentLevel == 2 && resumed.trial == trial && resumed.results.map(\.id) == ids && resumed.secondsRemaining == 10)
    for tick in 0...100 { try resumed.observe(score: 100 + Double(tick) * 0.3, time: Double(tick) / 10, permitted: true, random: &random) }
    expect(resumed.results.count == 2 && resumed.discardedTrials == finder.discardedTrials)
    expectThrows { try saved.finderProgress!["setup"]!.resuming(settings: settings, motors: [0], targetLevel: 4) }
    var short = try PatternFinder(settings: settings, motors: [0,2], targetLevel: 4, random: &random)
    for tick in 0..<3 { try short.observe(score: 100 + Double(tick) * 100, time: Double(tick) / 10, permitted: true, random: &random) }
    try short.observe(score: 760, time: 0.3, permitted: false, actualCutoff: true, random: &random)
    expect(short.results.isEmpty && short.latestTrial?.cutoffLimited == true)
    expect(short.latestTrial!.comparisonRate < short.latestTrial!.rate / 20 && short.latestTrial!.riseRate == short.latestTrial!.comparisonRate)
    var band = try FinderBand(settings: settings, motors: [0,2])
    for tick in 0...100 { try band.update(score: 100, time: Double(tick)/10, permitted: true, edge: 500, cutoff: 760, library: [short.latestTrial!], learning: preferred) }
    expect(band.forecastScore == 100 && band.queuedPhase == nil)
}

func pendingPeakAndIndependentPressureSafety() throws {
    var settings = EngineSettings(); settings.sensitivity = 760; settings.edgeTarget = 500; settings.averaging = false
    let legacy = try Engine(settings: settings)
    settings.pendingPeakGuard = true
    let guarded = try Engine(settings: settings)
    try legacy.arm(true, at: 0); try guarded.arm(true, at: 0)
    for (time, pressure) in [(0.0, 0), (0.02, 400), (0.04, 800)] {
        let old = try legacy.step(UInt16(pressure), at: time), current = try guarded.step(UInt16(pressure), at: time)
        expect(old.score == current.score)
        if pressure == 800 { expect(current.guardScore == 800 && current.score == 0 && !current.wantsPower && current.edge) }
    }
    expect(try legacy.step(0, at: 0.06).score == guarded.step(0, at: 0.06).score)
    var guardState = PressureSafety()
    func context(_ time: Double, permitted: Bool = true, ack: UUID? = nil) throws -> PressureSafetyContext {
        try PressureSafetyContext(baseline: 1000, gain: 1, score: 680, peakTrough: 0, cutoff: 760,
                                  permitted: permitted, peakGuardEnabled: true, time: time, acknowledgedPause: ack)
    }
    guardState.configure(try context(10))
    guardState.observe(PressureSample(base: 1000, tip: 700, time: 10), at: 10)
    expect(guardState.allowsOutput(at: 10))
    guardState.observe(PressureSample(base: 1200, tip: 700, time: 10.15), at: 10.15)
    expect(abs(guardState.filteredPressure! - 100) < 0.001)
    let pause = guardState.pause!
    expect(pause.kind == .pendingPeak && !guardState.allowsOutput(at: 10.15))
    guardState.configure(try context(10.3, permitted: false, ack: pause.id))
    guardState.observe(PressureSample(base: 1000, tip: 700, time: 10.3), at: 10.3)
    expect(guardState.pause != nil)
    guardState.configure(try context(10.4, ack: pause.id))
    guardState.evaluate(at: 10.4)
    expect(guardState.pause == nil && guardState.allowsOutput(at: 10.4))
    guardState.observe(PressureSample(base: 1200, tip: 700, time: 10.3), at: 10.7)
    expect(guardState.sample?.time == 10.3)
    guardState.evaluate(at: 10.81)
    expect(guardState.pause?.kind == .stalePressure && !guardState.allowsOutput(at: 10.81))
    guardState.observe(PressureSample(base: 0, tip: 700, time: 10.82), at: 10.82)
    expect(guardState.pause?.requiresDisarm == true)
    guardState.configure(try context(10.9, ack: guardState.pause!.id))
    guardState.observe(PressureSample(base: 1000, tip: 700, time: 10.9), at: 10.9)
    expect(!guardState.allowsOutput(at: 10.9))
    guardState.reset(); guardState.configure(try context(11)); guardState.evaluate(at: 10)
    expect(guardState.pause?.kind == .invalidPressure)

    var random = SystemRandomNumberGenerator(), vibration = VibrationSettings(); vibration.one.target = 50
    var finder = try PatternFinder(settings: vibration, motors: [0], targetLevel: 1, random: &random)
    for tick in 0...20 { _ = try finder.observe(score: Double(tick), time: Double(tick)/10, permitted: true, random: &random) }
    _ = try finder.observe(score: 20, time: 2, permitted: false, actualCutoff: true, random: &random)
    expect(finder.latestTrial != nil && finder.latestTrial!.seconds == 2)

    var record = SessionRecord(profile: "safety-check", simulated: true, settings: settings,
                               candidate: nil, seed: 1, baseline: 1000, gain: 1)
    record.armChanges = [ArmChange(time: 0, armed: true)]
    var action = pause
    action.time = 0.03; action.actionTime = 0.03; action.handledAt = 0.04; action.countedAsCutoff = true
    record.pressureSafetyEvents = [action]
    let live = try Engine(settings: settings, seed: 1)
    try live.arm(true, at: 0)
    for tick in 1...5 {
        let time = Double(tick) * 0.02
        if tick == 2 { try live.manualEdge(at: 0.03) }
        var value = try live.step(0, at: time)
        if tick == 2 { value.edge = true; value.riskReason = action.reason; value.guardScore = action.guardScore }
        record.frames.append(Frame(time: time, base: 1000, tip: 700, pressure: 0, armed: true, episode: 0, active: value))
    }
    let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
    let replay = try Learner.replay(decoded, with: settings)
    expect(zip(record.frames, replay.frames).allSatisfy { $0.active == $1.active })
}

let checks: [(String, () throws -> Void)] = [
    ("pendingPeakAndIndependentPressureSafety", pendingPeakAndIndependentPressureSafety),
    ("finderExplorationAndTrainingResume", finderExplorationAndTrainingResume),
    ("finderSmoothedApproachAndShorterCooldown", finderSmoothedApproachAndShorterCooldown),
    ("finderLibraryPruningAndLongRun", finderLibraryPruningAndLongRun),
    ("finderCutoffMeasurementsAndQueuedTrials", finderCutoffMeasurementsAndQueuedTrials),
    ("finderPlateauDownwardResponseAndLiveRates", finderPlateauDownwardResponseAndLiveRates),
    ("finderBandLibraryAndBraking", finderBandLibraryAndBraking),
    ("finderIntervalsRefinementAndMotorSelection", finderIntervalsRefinementAndMotorSelection),
    ("thirdMotorControlAndLegacyMigration", thirdMotorControlAndLegacyMigration),
    ("xtoysCommandsAndMotorCaps", xtoysCommandsAndMotorCaps),
    ("timedEdgingPenaltyAndCompletion", timedEdgingPenaltyAndCompletion),
    ("liveThresholdsPreserveStateAndReplay", liveThresholdsPreserveStateAndReplay),
    ("pressureFreshnessKeepsTransientPausesSeparateFromLoss", pressureFreshnessKeepsTransientPausesSeparateFromLoss),
    ("calibrationPersistenceAndIdentity", calibrationPersistenceAndIdentity),
    ("repeatingPatternsRespectTimingAndCutoffs", repeatingPatternsRespectTimingAndCutoffs),
    ("windowedPressureLearningAndProspectiveMarks", windowedPressureLearningAndProspectiveMarks),
    ("motorDiscoveryRangesAndProtocol", motorDiscoveryRangesAndProtocol),
    ("independentVibrationTargetsAndTiming", independentVibrationTargetsAndTiming),
    ("vibrationLimitsAndDisabledChannels", vibrationLimitsAndDisabledChannels),
    ("boundedUSBProtocolAndFraming", boundedUSBProtocolAndFraming),
    ("edgeAndTooCloseBothTeachOneCycle", edgeAndTooCloseBothTeachOneCycle),
    ("laterCutoffWithinWarningDeadlineCanImproveRiding", laterCutoffWithinWarningDeadlineCanImproveRiding),
    ("targetEdgeDoesNotCutOffButUpperRiskDoes", targetEdgeDoesNotCutOffButUpperRiskDoes),
    ("rhythmicWarningCutsBeforeConfirmedDetection", rhythmicWarningCutsBeforeConfirmedDetection),
    ("revisedLabelsAndLegacyArchivesStaySeparate", revisedLabelsAndLegacyArchivesStaySeparate),
    ("replayPreservesSubTickActions", replayPreservesSubTickActions),
    ("incorrectEventCanTeachShadowRejection", incorrectEventCanTeachShadowRejection),
    ("buildupIsContextRatherThanACutoffLabel", buildupIsContextRatherThanACutoffLabel),
    ("persistedCandidateCannotBypassBounds", persistedCandidateCannotBypassBounds),
    ("pressurePacketAndCalibration", pressurePacketAndCalibration),
    ("originalPeakAccumulatorAndManualActions", originalPeakAccumulatorAndManualActions),
    ("saturationAndClockBoundary", saturationAndClockBoundary),
    ("missingFeedbackDuplicatesAndSimulationsDoNotInflateConfidence", missingFeedbackDuplicatesAndSimulationsDoNotInflateConfidence),
    ("confidenceCanFallAndSmallSamplesRemainLearning", confidenceCanFallAndSmallSamplesRemainLearning),
    ("onlyProspectiveSupportedCandidatesCanBePromoted", onlyProspectiveSupportedCandidatesCanBePromoted),
    ("adjustmentsStayWithinOneFieldAndCumulativeBounds", adjustmentsStayWithinOneFieldAndCumulativeBounds),
    ("removingHumanLabelDoesNotRewritePhysicalActionOnReplay", removingHumanLabelDoesNotRewritePhysicalActionOnReplay),
    ("localStorageRoundTripAndReset", localStorageRoundTripAndReset)
]
for (name, check) in checks {
    let before = failures.count
    do { try check() } catch { failures.append("\(name): \(error)") }
    print("\(failures.count == before ? "PASS" : "FAIL") \(name)")
}
for failure in failures { fputs(failure + "\n", stderr) }
print("\(checks.count) checks; \(failures.count) failures")
exit(failures.isEmpty ? 0 : 1)
