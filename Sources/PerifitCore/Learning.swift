import Foundation

public enum FeedbackKind: String, Codable, CaseIterable, Sendable {
    case closer, edge, tooClose, orgasm, tooEarly, aboutRight, eventCorrect, eventIncorrect
    public var title: String {
        switch self {
        case .closer: return "Getting closer"
    case .edge: return "Edge"
    case .tooClose: return "Too close"
        case .orgasm: return "Orgasm"
        case .tooEarly: return "Too early"
        case .aboutRight: return "About right"
        case .eventCorrect: return "Event correct"
        case .eventIncorrect: return "Event incorrect"
        }
    }
}
public struct Feedback: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var time: Double
    public var episode: Int
    public var kind: FeedbackKind
    public var anchor: Double?
    public var signal: Signal?
    public var removed = false
    public var predictedMark: FeedbackKind?
    public var predictionModelID: UUID?
    public init(time: Double, episode: Int, kind: FeedbackKind, anchor: Double? = nil, signal: Signal? = nil) {
        self.time = time; self.episode = episode; self.kind = kind; self.anchor = anchor; self.signal = signal
    }
}
public struct Frame: Codable, Sendable {
    public var time: Double
    public var base: UInt16
    public var tip: UInt16
    public var pressure: UInt16
    public var armed: Bool
    public var episode: Int
    public var active: Snapshot
    public var shadow: Snapshot?
    public var confirmedPower: Bool?
    public var vibrationRequested: VibrationLevels?
    public var vibrationReported: VibrationLevels?
    public var pressureSafetyHeld: Bool?
    public var pressureAge: Double?
    public init(time: Double, base: UInt16, tip: UInt16, pressure: UInt16, armed: Bool,
                episode: Int, active: Snapshot, shadow: Snapshot? = nil, confirmedPower: Bool? = nil) {
        self.time=time; self.base=base; self.tip=tip; self.pressure=pressure; self.armed=armed
        self.episode=episode; self.active=active; self.shadow=shadow; self.confirmedPower=confirmedPower
    }
}
public struct RecordingGap: Codable, Sendable {
    public var start: Double
    public var end: Double?
    public var reason: String
    public init(start: Double, end: Double? = nil, reason: String) {
        self.start = start; self.end = end; self.reason = reason
    }
}

public struct SessionRecord: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var profile: String
    public var simulated: Bool
    public var settings: EngineSettings
    public var candidate: EngineSettings?
    public var candidateVersion: UUID?
    public var policyVersion: Int?
    public var outputTransport: String?
    public var automaticCutoffLimit: Int?
    public var timedEdging: TimedEdging?
    public var orgasmVibrationSettings: VibrationSettings?
    public var orgasmModeAt: Double?
    public var automaticCutoffChanges: [AutomaticCutoffChange]?
    public var thresholdChanges: [ThresholdChange]?
    public var vibrationSettings: VibrationSettings?
    public var vibrationSource: String?
    public var vibrationLimits: VibrationLevels?
    public var motorCalibration: MotorCalibration?
    public var recordingGaps: [RecordingGap]?
    public var pressureSafetyEvents: [PressureSafetyEvent]?
    public var markModel: MarkModel?
    public var vibrationTargetChanges: [VibrationTargetChange]?
    public var seed: UInt32
    public var baseline: Double
    public var gain: Double
    public var complete = false
    public var eligible = true
    public var feedback: [Feedback] = []
    public var manualEdges: [Double] = []
    public var armChanges: [ArmChange] = [ArmChange(time: 0, armed: true)]
    public var frames: [Frame] = []
    public init(profile: String, simulated: Bool, settings: EngineSettings, candidate: EngineSettings?,
                seed: UInt32, baseline: Double, gain: Double) {
        self.profile=profile; self.simulated=simulated; self.settings=settings; self.candidate=candidate
        self.seed=seed; self.baseline=baseline; self.gain=gain
        self.policyVersion = ControlPolicy.rideEdge.rawValue
    }
}
public struct ThresholdChange: Codable, Sendable {
    public var time: Double
    public var edge: Int
    public var cutoff: Int
    public init(time: Double, edge: Int, cutoff: Int) { self.time = time; self.edge = edge; self.cutoff = cutoff }
}
public struct AutomaticCutoffChange: Codable, Sendable {
    public var time: Double
    public var limit: Int?
    public init(time: Double, limit: Int?) { self.time = time; self.limit = limit }
}
public struct ArmChange: Codable, Sendable {
    public var time: Double
    public var armed: Bool
    public init(time: Double, armed: Bool) { self.time = time; self.armed = armed }
}
public enum Signal: String, Codable, CaseIterable, Sendable {
    case peakScore, sustained, rhythmic
    public var title: String {
        switch self { case .peakScore: return "Near-orgasm cutoff"; case .sustained: return "Sustained event"; case .rhythmic: return "Rhythmic warning" }
    }
}
public struct Evidence: Sendable {
    public init() {}
    public var matches = 0
    public var contradictions = 0
    public var sessions: Set<UUID> = []
    public var positives = 0
    public var corrections = 0
    private var episodeResults: [String: Bool] = [:]
    private var positiveEpisodes: Set<String> = []
    private var correctiveEpisodes: Set<String> = []
    mutating func record(agreement: Bool, positive: Bool, session: UUID, episode: Int) {
        let key = "\(session.uuidString):\(episode)"
        if let previous = episodeResults[key] {
            if previous && !agreement { matches -= 1; contradictions += 1 }
            episodeResults[key] = previous && agreement
        } else {
            episodeResults[key] = agreement
            if agreement { matches += 1 } else { contradictions += 1 }
        }
        sessions.insert(session)
        if positive {
            if positiveEpisodes.insert(key).inserted { positives += 1 }
        } else if correctiveEpisodes.insert(key).inserted { corrections += 1 }
    }
    public var total: Int { matches + contradictions }
    public var lowerBound: Double {
        guard total > 0 else { return 0 }
        let n = Double(total), p = Double(matches) / n, z2 = 1.96 * 1.96
        return (p + z2/(2*n) - 1.96 * sqrt((p*(1-p)+z2/(4*n))/n)) / (1+z2/n)
    }
    public var supported: Bool { total >= 20 && sessions.count >= 3 && lowerBound >= 0.70 }
    public var status: String { supported ? "Supported" : (total >= 20 && sessions.count >= 3 ? "Mixed" : "Learning") }
}

public struct Adjustment: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var from: EngineSettings
    public var to: EngineSettings
    public var reason: String
    public init(from: EngineSettings, to: EngineSettings, reason: String) { self.from=from; self.to=to; self.reason=reason }
}
public struct PressureExample: Codable, Identifiable, Sendable {
    public var id: UUID
    public var session: UUID
    public var kind: FeedbackKind
    public var time: Double
    public var base: Double
    public var tip: Double
    public var pressure: Double
    public var peak: Double
    public var features: [Double]
}

/// Nearest learned pattern, separate from the EOM motor controller. Confidence is
/// measured against subsequent user reports, never inferred from distance alone.
public struct MarkModel: Codable, Sendable {
    public struct Center: Codable, Equatable, Sendable {
        public var kind: FeedbackKind
        public var features: [Double]
    }
    public var id: UUID
    public var exampleIDs: [UUID]
    public var centers: [Center]
    public var scales: [Double]
    public func predict(_ features: [Double]) -> FeedbackKind? {
        // ponytail: nearest median patterns; revisit the model if prospective recognition stays poor with sufficient labelled sessions.
        guard centers.count >= 2, features.count == 6, scales.count == 6,
              features.allSatisfy(\.isFinite), scales.allSatisfy({ $0.isFinite && $0 > 0 }),
              centers.allSatisfy({ $0.features.count == 6 && $0.features.allSatisfy(\.isFinite) }) else { return nil }
        func distance(_ center: Center) -> Double {
            zip(zip(features, center.features), scales).reduce(0) { sum, pair in
                let value = (pair.0.0 - pair.0.1) / pair.1
                return sum + value * value
            }
        }
        return centers.min { distance($0) < distance($1) }?.kind
    }
    public static func trained(on examples: [PressureExample], previous: Self?) -> Self? {
        let kinds = Learner.markKinds.filter { kind in examples.contains { $0.kind == kind } }
        guard kinds.count >= 2, examples.allSatisfy({ $0.features.count == 6 && $0.features.allSatisfy(\.isFinite) }) else { return nil }
        let ids = examples.map(\.id)
        let centers = kinds.map { kind in
            Center(kind: kind, features: (0..<6).map { index in
                Learner.median(examples.filter { $0.kind == kind }.map { $0.features[index] })
            })
        }
        let floors = [50.0, 50, 50, 100, 0.5, 1]
        let scales = (0..<6).map { index in
            let values = examples.map { $0.features[index] }, middle = Learner.median(examples.map { $0.features[index] })
            return max(floors[index], Learner.median(values.map { abs($0 - middle) }))
        }
        if let previous, previous.exampleIDs == ids, previous.centers == centers, previous.scales == scales { return previous }
        return Self(id: UUID(), exampleIDs: ids, centers: centers, scales: scales)
    }
}

public struct LearningProfile: Codable, Sendable {
    public var key: String
    public var baseline: EngineSettings
    public var active: EngineSettings
    public var candidate: EngineSettings?
    public var candidateVersion: UUID?
    public var history: [Adjustment] = []
    public var frozen = false
    public var pressureExamples: [PressureExample]?
    public var markModel: MarkModel?
    public init(key: String, baseline: EngineSettings) {
        var fixed = baseline
        fixed.edgeTarget = baseline.effectiveEdgeTarget
        self.key=key; self.baseline=fixed; self.active=fixed
    }
}

public enum Learner {
    public static let markKinds: [FeedbackKind] = [.closer, .edge, .tooClose, .orgasm]
    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle-1] + sorted[middle])/2 : sorted[middle]
    }
    private static func capturedWindow(_ record: SessionRecord, from lo: Double, to hi: Double) -> [Frame]? {
        let lo = max(0, lo)
        guard lo.isFinite, hi.isFinite, hi >= lo,
              let first = record.frames.first, let last = record.frames.last,
              first.time <= lo, last.time >= hi else { return nil }
        if let gaps = record.recordingGaps {
            guard !gaps.contains(where: { gap in
                !gap.start.isFinite || gap.start < 0 ||
                gap.end.map { !$0.isFinite || $0 < gap.start } == true ||
                (gap.start < hi && (gap.end ?? .infinity) > lo)
            }) else { return nil }
            // New recordings also reject missing frames that were not explicitly flagged.
            var previous: Double?
            for frame in record.frames {
                if frame.time <= lo { previous = frame.time; continue }
                guard let before = previous, frame.time > before, frame.time - before <= 0.250_001 else { return nil }
                previous = frame.time
                if frame.time >= hi { break }
            }
        }
        let frames = record.frames.filter { $0.time >= lo && $0.time <= hi }
        return frames.isEmpty ? nil : frames
    }
    public static func markWindow(_ record: SessionRecord, at time: Double) -> [Frame]? {
        guard let last = record.frames.last(where: { $0.time <= time }), last.time >= 3, time - last.time <= 0.25 else { return nil }
        return capturedWindow(record, from: last.time - 3, to: last.time)
    }
    public static func markFeatures(_ frames: [Frame]) -> [Double] {
        let pressures = frames.map { Double($0.pressure) }, middle = median(pressures)
        return [middle, (pressures.max() ?? 0) - middle,
                Double((frames.map(\.tip).max() ?? 0) - (frames.map(\.tip).min() ?? 0)),
                median(frames.map { Double($0.active.score) }),
                frames.map(\.active.sustained).max() ?? 0,
                Double(frames.map(\.active.peaks).max() ?? 0)]
    }
    public static func pressureExamples(_ records: [SessionRecord]) -> [PressureExample] {
        var result: [PressureExample] = []
        for record in records where record.complete && record.eligible && !record.simulated && record.policyVersion == ControlPolicy.rideEdge.rawValue {
            var seen: Set<String> = []
            for label in record.feedback.reversed() where !label.removed && markKinds.contains(label.kind) {
                guard let frames = markWindow(record, at: label.time),
                      seen.insert("\(label.episode):\(label.kind.rawValue)").inserted else { continue }
                result.append(PressureExample(id: label.id, session: record.id, kind: label.kind, time: label.time,
                    base: median(frames.map { Double($0.base) }), tip: median(frames.map { Double($0.tip) }),
                    pressure: median(frames.map { Double($0.pressure) }), peak: Double(frames.map(\.pressure).max() ?? 0),
                    features: markFeatures(frames)))
            }
        }
        return result
    }
    public static func markEvidence(_ records: [SessionRecord]) -> [FeedbackKind: Evidence] {
        var result = Dictionary(uniqueKeysWithValues: markKinds.map { ($0, Evidence()) })
        for record in records where record.complete && record.eligible && !record.simulated && record.policyVersion == ControlPolicy.rideEdge.rawValue {
            guard let model = record.markModel else { continue }
            var seen: Set<String> = []
            for label in record.feedback.reversed() where !label.removed && markKinds.contains(label.kind) {
                guard let predicted = label.predictedMark, label.predictionModelID == model.id,
                      model.centers.contains(where: { $0.kind == predicted }), result[predicted] != nil,
                      markWindow(record, at: label.time) != nil,
                      seen.insert("\(label.episode):\(label.kind.rawValue)").inserted else { continue }
                if model.centers.contains(where: { $0.kind == label.kind }) {
                    result[label.kind]!.record(agreement: predicted == label.kind, positive: true, session: record.id, episode: label.episode)
                }
                if predicted != label.kind {
                    result[predicted]!.record(agreement: false, positive: false, session: record.id, episode: label.episode)
                }
            }
        }
        return result
    }
    private static func supervisionLabels(_ feedback: [Feedback]) -> [Feedback] {
        feedback.flatMap { label in
            guard label.kind == .orgasm else { return [label] }
            // An actual orgasm also reports that the upper boundary was reached.
            // Evaluate an OFF warning before the report, never after it; this is
            // a training target, not a fabricated sensor event or saved button press.
            var warning = label
            warning.kind = .tooClose
            warning.anchor = max(0, (label.anchor ?? label.time) - 1)
            warning.signal = nil
            return [warning, label]
        }
    }
    // Both Edge and Too close matter within a cycle. An episode earns one
    // agreement only if all its reviewed phases agree, avoiding sample inflation.
    public static func evidence(_ records: [SessionRecord], settings: EngineSettings,
                                shadow: Bool = false) -> [Signal: Evidence] {
        var results = Dictionary(uniqueKeysWithValues: Signal.allCases.map { ($0, Evidence()) })
        for record in records where record.complete && record.eligible && !record.simulated && record.policyVersion == ControlPolicy.rideEdge.rawValue &&
            (shadow ? record.candidate == settings : record.settings == settings) {
            var seen: Set<String> = []
            for label in supervisionLabels(record.feedback).reversed() where !label.removed && label.kind != .closer {
                let target = [.edge, .tooClose, .tooEarly, .aboutRight].contains(label.kind) ? "edge" : "event"
                let positive = ![.edge, .tooEarly, .eventIncorrect].contains(label.kind)
                let anchor = label.anchor ?? label.time
                let lo = anchor - 3, hi = target == "edge" ? anchor : anchor + 3
                guard let window = capturedWindow(record, from: lo, to: hi),
                      seen.insert("\(label.episode):\(target):\(positive)").inserted else { continue }
                let snapshots = window.compactMap { shadow ? $0.shadow : $0.active }
                guard !snapshots.isEmpty else { continue }
                let signals: [Signal] = target == "edge" ? [.peakScore] : [.sustained, .rhythmic]
                for signal in signals {
                    if let reviewedSignal = label.signal, reviewedSignal != signal { continue }
                    let fired = snapshots.contains { snapshot in
                        switch signal {
                        case .peakScore: return snapshot.edge
                        case .sustained: return snapshot.detected && !snapshot.rhythmic
                        case .rhythmic: return snapshot.detected && snapshot.rhythmic
                        }
                    }
                    // A positive report can reveal a missed detector. Negative event reviews
                    // only contradict the detector actually responsible for the reviewed event.
                    if !positive && target == "event" && label.signal == nil { continue }
                    var e = results[signal]!
                    e.record(agreement: fired == positive, positive: positive, session: record.id, episode: label.episode)
                    results[signal] = e
                }
            }
        }
        return results
    }

    public static func candidates(around current: EngineSettings, baseline: EngineSettings) -> [EngineSettings] {
        let fields: [WritableKeyPath<EngineSettings, Int>] = [\.sensitivity, \.sustainedThreshold, \.peakAmplitude]
        return fields.flatMap { key -> [EngineSettings] in
            [-1.0, 1.0].compactMap { direction in
                var next = current
                let value = current[keyPath: key], base = baseline[keyPath: key]
                let delta = max(1, Int((Double(value) * 0.05).rounded(.down)))
                // Integer rounding must never exceed the 5% budget.
                guard Double(delta) <= Double(value) * 0.05 else { return nil }
                next[keyPath: key] = value + Int(direction) * delta
                guard Double(next[keyPath:key]) >= Double(base)*0.75,
                      Double(next[keyPath:key]) <= Double(base)*1.25,
                      (try? next.validated()) != nil else { return nil }
                return next
            }
        }
    }

    public static func replay(_ record: SessionRecord, with settings: EngineSettings) throws -> SessionRecord {
        guard let policy = ControlPolicy(rawValue: record.policyVersion ?? 1) else {
            throw AppError.invalid("This recording uses an unsupported control policy.")
        }
        let engine = try Engine(settings: settings, seed: record.seed, policy: policy)
        var copy = record
        copy.settings = settings; copy.candidate = nil; copy.frames = []
        let manual = record.manualEdges.sorted()
        let arms = record.armChanges.sorted { $0.time < $1.time }
        let thresholds = (record.thresholdChanges ?? []).sorted { $0.time < $1.time }
        let safety = (record.pressureSafetyEvents ?? []).sorted { ($0.handledAt ?? $0.time) < ($1.handledAt ?? $1.time) }
        let safetyActions = safety.filter { $0.actionTime != nil }.sorted { $0.actionTime! < $1.actionTime! }
        var manualIndex = 0, armIndex = 0, thresholdIndex = 0
        var safetyActionIndex = 0, safetyFrameIndex = 0
        for frame in record.frames {
            // Actual action times are independent of later corrections to human labels.
            while true {
                let armTime = armIndex < arms.count ? arms[armIndex].time : Double.infinity
                let edgeTime = manualIndex < manual.count ? manual[manualIndex] : Double.infinity
                let thresholdTime = thresholdIndex < thresholds.count ? thresholds[thresholdIndex].time : Double.infinity
                let safetyTime = safetyActionIndex < safetyActions.count ? safetyActions[safetyActionIndex].actionTime! : Double.infinity
                guard min(armTime, edgeTime, thresholdTime, safetyTime) <= frame.time else { break }
                if safetyTime <= min(armTime, edgeTime, thresholdTime) {
                    try engine.manualEdge(at: safetyTime); safetyActionIndex += 1
                } else if thresholdTime <= min(armTime, edgeTime) {
                    let change = thresholds[thresholdIndex]
                    try engine.updateThresholds(edge: change.edge, cutoff: change.cutoff); thresholdIndex += 1
                } else if armTime <= edgeTime {
                    try engine.arm(arms[armIndex].armed, at: armTime); armIndex += 1
                } else {
                    try engine.manualEdge(at: edgeTime); manualIndex += 1
                }
            }
            var next = frame
            next.active = try engine.step(frame.pressure, at: frame.time)
            while safetyFrameIndex < safety.count, (safety[safetyFrameIndex].handledAt ?? safety[safetyFrameIndex].time) <= frame.time {
                let event = safety[safetyFrameIndex]
                if event.countedAsCutoff == true {
                    next.active.edge = true; next.active.riskReason = event.reason
                    next.active.guardScore = max(next.active.guardScore ?? 0, event.guardScore)
                }
                safetyFrameIndex += 1
            }
            next.shadow = nil
            copy.frames.append(next)
        }
        return copy
    }

    public static func buildupObservations(_ records: [SessionRecord], settings: EngineSettings) -> [Signal: Evidence] {
        var result = Dictionary(uniqueKeysWithValues: Signal.allCases.map { ($0, Evidence()) })
        for record in records where record.complete && record.eligible && !record.simulated && record.policyVersion == ControlPolicy.rideEdge.rawValue && record.settings == settings {
            var seen: Set<Int> = []
            for label in record.feedback.reversed() where !label.removed && label.kind == .closer {
                guard let before = capturedWindow(record, from: label.time-3, to: label.time),
                      seen.insert(label.episode).inserted else { continue }
                guard let first = before.first, let last = before.last else { continue }
                for signal in Signal.allCases {
                    let present: Bool
                    switch signal {
                    case .peakScore: present = last.active.score > first.active.score || before.contains { $0.active.score >= settings.sensitivity }
                    case .sustained: present = before.contains { $0.active.detectionPhase == 1 }
                    case .rhythmic: present = before.contains { $0.active.detectionPhase == 2 || ($0.active.detected && $0.active.rhythmic) }
                    }
                    var e = result[signal]!
                    if present { e.matches += 1 } else { e.contradictions += 1 }
                    e.sessions.insert(record.id); result[signal] = e
                }
            }
        }
        return result
    }

    public static func update(_ profile: LearningProfile, records: [SessionRecord]) throws -> LearningProfile {
        var result = profile
        let relevant = records.filter { $0.profile == profile.key && $0.complete && $0.eligible && !$0.simulated && $0.policyVersion == ControlPolicy.rideEdge.rawValue }.suffix(20)
        let data = Array(relevant)
        result.pressureExamples = pressureExamples(data)
        result.markModel = MarkModel.trained(on: result.pressureExamples ?? [], previous: profile.markModel)
        guard !profile.frozen else { return result }
        if let candidate = profile.candidate {
            guard candidates(around: profile.active, baseline: profile.baseline).contains(candidate) else {
                result.candidate = nil; result.candidateVersion = nil
                return result
            }
            guard let version = profile.candidateVersion else {
                result.candidateVersion = UUID()
                return result
            }
            // Only prospectively recorded shadow outputs authorize promotion.
            let paired = data.filter { $0.candidate == candidate && $0.candidateVersion == version && $0.settings == profile.active }
            let before = evidence(paired, settings: profile.active)
            let after = evidence(paired, settings: candidate, shadow: true)
            // Every permitted adjustment must improve the actual cutoff policy;
            // the user need not experience orgasms to teach an earlier boundary.
            let a = after[.peakScore]!, b = before[.peakScore]!
            let improves = a.supported && a.positives >= 5 && a.corrections >= 5 && a.contradictions < b.contradictions
            let doesNotRegress = Signal.allCases.allSatisfy { after[$0]!.contradictions <= before[$0]!.contradictions }
            if improves && doesNotRegress && !addsMisses(paired, active: profile.active, candidate: candidate) {
                result.history.append(Adjustment(from: profile.active, to: candidate,
                    reason: "Validated in observation mode: \(a.matches)/\(a.total) reviewed episodes across \(a.sessions.count) sessions."))
                result.active = candidate; result.candidate = nil; result.candidateVersion = nil
                return result
            }
            // Keep a fixed candidate so fresh validation cannot become retrospective training.
            if a.total < 20 || a.sessions.count < 3 { return result }
            result.candidate = nil; result.candidateVersion = nil
        }
        guard data.count >= 2 else { return result }
        let baseCost = try replayCost(data, settings: result.active)
        var bestCost = baseCost
        for candidate in candidates(around: result.active, baseline: result.baseline) {
            let cost = try replayCost(data, settings: candidate)
            if cost < bestCost { result.candidate = candidate; bestCost = cost }
        }
        if result.candidate != nil { result.candidateVersion = UUID() }
        return result
    }

    private static func replayCost(_ records: [SessionRecord], settings: EngineSettings) throws -> Int {
        let replayed = try records.map { try replay($0, with: settings) }
        return evidence(replayed, settings: settings)[.peakScore]!.contradictions
    }
    private static func addsMisses(_ records: [SessionRecord], active: EngineSettings, candidate: EngineSettings) -> Bool {
        for record in records {
            for label in supervisionLabels(record.feedback) where !label.removed && [.tooClose, .aboutRight, .orgasm, .eventCorrect].contains(label.kind) {
                let anchor = label.anchor ?? label.time
                let cutoff = [.tooClose, .aboutRight].contains(label.kind)
                guard let window = capturedWindow(record, from: anchor-3, to: anchor+(cutoff ? 0 : 3)) else { continue }
                let old = window.first { cutoff ? $0.active.edge : $0.active.detected }?.time
                let new = window.first { cutoff ? ($0.shadow?.edge ?? false) : ($0.shadow?.detected ?? false) }?.time
                // Later than a premature cutoff is allowed within the reviewed
                // warning window. Missing its deadline is never an improvement.
                if old != nil && new == nil { return true }
            }
        }
        return false
    }
}
