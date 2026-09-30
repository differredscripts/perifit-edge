import Foundation

public struct FinderSetup: Codable, Sendable {
    public let motors: Set<Int>
    public let levels: Int
    public let easingPercent: Double
    public init(motors: Set<Int>, levels: Int, easingPercent: Double) {
        self.motors = motors; self.levels = levels; self.easingPercent = easingPercent
    }
    public func validated() throws -> Self {
        guard !motors.isEmpty, motors.allSatisfy({ (0..<3).contains($0) }), (1...20).contains(levels),
              easingPercent.isFinite, (0...50).contains(easingPercent) else { throw AppError.invalid("Invalid Finder training setup.") }
        return self
    }
}

public struct FinderResult: Identifiable, Codable, Sendable {
    public let id: UUID
    public let level: Int
    public let trial: Int
    public let settings: VibrationSettings
    public let startScore: Double
    public let endScore: Double
    public let seconds: Double
    public let rate: Double
    public let fallback: Bool?
    public let cutoffLimited: Bool?
    public var descent: FinderDescent?
    public var riseSamples: [Double]?
    public var fallSamples: [Double]?
    public var responseDelays: [Double]?
    public var validationCount: Int?
    public init(level: Int, trial: Int, settings: VibrationSettings, startScore: Double,
                endScore: Double, seconds: Double, rate: Double, fallback: Bool = false, cutoffLimited: Bool = false, id: UUID = UUID()) {
        self.id = id; self.level = level; self.trial = trial; self.settings = settings
        self.startScore = startScore; self.endScore = endScore; self.seconds = seconds; self.rate = rate
        self.fallback = fallback ? true : nil
        self.cutoffLimited = cutoffLimited ? true : nil
    }
    public func validated() throws -> Self {
        _ = try settings.validated()
        _ = try descent?.validated()
        for samples in [riseSamples, fallSamples, responseDelays].compactMap({ $0 }) {
            guard !samples.isEmpty, samples.count <= 12, samples.allSatisfy({ $0.isFinite }) else { throw AppError.invalid("Invalid Finder rate history.") }
        }
        guard responseDelays?.allSatisfy({ $0 >= 0 && $0 <= 3600 }) ?? true,
              (validationCount ?? 0) >= 0, (validationCount ?? 0) < Int.max else { throw AppError.invalid("Invalid Finder validation history.") }
        guard (1...20).contains(level), trial > 0, seconds.isFinite, seconds > 0, cutoffLimited == true || seconds >= 10,
              rate.isFinite, startScore.isFinite, endScore.isFinite,
              (0...65535).contains(startScore), (0...65535).contains(endScore),
              fallback == true || (rate > 0 && endScore > startScore),
              settings.channels.contains(where: { $0.target > 0 }) else { throw AppError.invalid("Invalid saved Finder pattern.") }
        return self
    }
    public func matches(settings ceilings: VibrationSettings, motors: Set<Int>) -> Bool {
        (try? validated()) != nil && (0..<3).allSatisfy { settings[$0].target == (motors.contains($0) ? ceilings[$0].target : 0) }
    }

    public static let libraryLimit = 15
    /// Credit only observed growth in a shortened trial; retain the raw slope separately.
    public var comparisonRate: Double { rate * min(1, seconds / PatternFinder.interval) }
    public static func prunedLibrary(_ patterns: [Self], keeping protected: Set<UUID> = []) -> [Self] {
        guard patterns.count > libraryLimit else { return patterns }
        var kept = Set(patterns.filter { protected.contains($0.id) }.prefix(libraryLimit).map(\.id))
        func keep(_ pattern: Self?) {
            if kept.count < libraryLimit, let pattern { kept.insert(pattern.id) }
        }
        let rising = patterns.filter { $0.riseRate > 0 }
        keep(rising.min { $0.riseRate < $1.riseRate })
        keep(rising.max { $0.riseRate < $1.riseRate })
        keep(patterns.filter { ($0.fallRate ?? 0) < 0 }.min { $0.fallRate! < $1.fallRate! })
        // Keep distinct response strengths, including gentle patterns near cutoff.
        while kept.count < libraryLimit {
            let rates = patterns.filter { kept.contains($0.id) }.map(\.riseRate)
            let next = patterns.filter { !kept.contains($0.id) }.max { a, b in
                let aGap = rates.map { abs($0 - a.riseRate) }.min() ?? 0
                let bGap = rates.map { abs($0 - b.riseRate) }.min() ?? 0
                return aGap == bGap ? (a.validationCount ?? 0) < (b.validationCount ?? 0) : aGap < bGap
            }
            guard let next else { break }
            kept.insert(next.id)
        }
        return patterns.filter { kept.contains($0.id) }
    }
}

/// A bounded-memory, four-level-by-default random search. Scores are observations, not causal evidence.
public struct PatternFinder: Codable, Sendable {
    public static let interval = 10.0
    public static let noImprovementLimit = 20
    public private(set) var candidate: VibrationSettings
    public private(set) var results: [FinderResult] = []
    public private(set) var running = true
    public private(set) var trial = 1
    public private(set) var discardedTrials = 0
    public private(set) var lastInterruption: String?
    public private(set) var trialsWithoutImprovement = 0
    public private(set) var endedForNoImprovement = false
    public private(set) var bestTrial: FinderResult?
    public private(set) var latestTrial: FinderResult?
    private var queuedCandidate: VibrationSettings?
    private var proposalIndex = 0
    private var explorationStep = 0
    private var lastPreferredTrial = -4
    public private(set) var secondsRemaining = interval
    public let targetLevel: Int
    public var currentLevel: Int { min(targetLevel, results.count + 1) }
    public var isFinalLevel: Bool { currentLevel == targetLevel }
    public var winner: FinderResult? { results.max { $0.comparisonRate < $1.comparisonRate } }
    public let motors: [Int]
    private let ceilings: VibrationSettings
    private var startedAt: Double?
    private var lastTime: Double?
    private var startScore = 0.0
    private var count = 0.0
    private var sumTime = 0.0, sumScore = 0.0, sumTimeSquared = 0.0, sumTimeScore = 0.0

    public init<R: RandomNumberGenerator>(settings: VibrationSettings, motors: Set<Int>, targetLevel: Int,
                                          availableChannels: Int = 3, random: inout R) throws {
        _ = try settings.validated()
        guard (1...20).contains(targetLevel), (1...3).contains(availableChannels), !motors.isEmpty,
              motors.allSatisfy({ (0..<availableChannels).contains($0) && settings[$0].target > 0 }) else {
            throw AppError.invalid("Choose 1–20 Finder levels and at least one available motor with a target above zero.")
        }
        self.targetLevel = targetLevel; self.motors = motors.sorted(); ceilings = settings
        candidate = VibrationSettings()
        candidate = nextCandidate(random: &random)
    }

    public func validated() throws -> Self {
        _ = try ceilings.validated()
        guard (1...20).contains(targetLevel), results.count <= targetLevel, trial > 0, trial < Int.max - 1,
              discardedTrials >= 0, (0...Self.noImprovementLimit).contains(trialsWithoutImprovement),
              (0..<3).contains(proposalIndex), (0..<6).contains(explorationStep), lastPreferredTrial >= -4, lastPreferredTrial <= trial,
              !motors.isEmpty, Set(motors).count == motors.count,
              motors.allSatisfy({ (0..<3).contains($0) && ceilings[$0].target > 0 }) else {
            throw AppError.invalid("Invalid saved Finder training progress.")
        }
        for result in results + [bestTrial, latestTrial].compactMap({ $0 }) {
            guard result.matches(settings: ceilings, motors: Set(motors)) else { throw AppError.invalid("Saved Finder progress has different motor limits.") }
        }
        for pattern in [running ? candidate : nil, queuedCandidate].compactMap({ $0 }) {
            _ = try pattern.validated()
            guard (0..<3).allSatisfy({ pattern[$0].target == (motors.contains($0) ? ceilings[$0].target : 0) }) else {
                throw AppError.invalid("Saved Finder candidate changed motor limits.")
            }
        }
        return self
    }
    public func resuming(settings: VibrationSettings, motors: Set<Int>, targetLevel: Int) throws -> Self {
        var copy = try validated()
        guard settings == ceilings, motors == Set(self.motors), targetLevel == self.targetLevel else {
            throw AppError.invalid("Finder setup changed since the saved training run.")
        }
        // Only the unfinished measurement and stale prediction are restarted.
        copy.resetWindow(); copy.lastTime = nil; copy.queuedCandidate = nil
        return copy
    }
    private mutating func nextCandidate<R: RandomNumberGenerator>(random: inout R) -> VibrationSettings {
        let explore = proposalIndex == 0 || winner == nil
        proposalIndex = (proposalIndex + 1) % 3
        if !explore, let winner {
            var next = winner.settings
            let index = motors.randomElement(using: &random)!
            var channel = next[index], shape = channel.effectivePattern
            switch Int.random(in: 0...5, using: &random) {
            case 0: channel.mode = channel.mode == .wave ? .pulse : .wave
            case 1: shape.minimum = min(shape.maximum, max(0, shape.minimum + Double.random(in: -20...20, using: &random)))
            case 2:
                shape.maximum = [10.0, 25, 50, 75, 100].randomElement(using: &random)!
                shape.minimum = min(shape.minimum, shape.maximum)
            case 3: shape.riseSeconds = min(4, max(0.2, shape.riseSeconds + Double.random(in: -1...1, using: &random)))
            case 4: shape.fallSeconds = min(4, max(0.2, shape.fallSeconds + Double.random(in: -1...1, using: &random)))
            default: shape.curve = shape.curve == .sine ? .linear : .sine
            }
            channel.pattern = shape; next[index] = channel
            if next == winner.settings { next[index].mode = channel.mode == .wave ? .pulse : .wave }
            return next
        }
        var next = VibrationSettings()
        let strengths = [25.0, 50, 75, 100, 10]
        for (offset, index) in motors.enumerated() {
            var channel = ceilings[index], shape = VibrationPattern()
            channel.mode = Bool.random(using: &random) ? .wave : .pulse
            let band = explorationStep == 5 ? 3 : (explorationStep + offset) % strengths.count
            shape.maximum = strengths[band]
            shape.minimum = shape.maximum * [0.0, 0.25, 0.5, 0.75, 0][band]
            shape.riseSeconds = Double.random(in: 0.2...4, using: &random)
            shape.fallSeconds = Double.random(in: 0.2...4, using: &random)
            shape.curve = Bool.random(using: &random) ? .sine : .linear
            channel.pattern = shape; next[index] = channel
        }
        explorationStep = (explorationStep + 1) % 6
        return next
    }

    private mutating func resetWindow() {
        startedAt = nil; secondsRemaining = Self.interval
        count = 0; sumTime = 0; sumScore = 0; sumTimeSquared = 0; sumTimeScore = 0
    }
    public mutating func queueNextPattern<R: RandomNumberGenerator>(preferred: VibrationSettings?, random: inout R) throws {
        guard running, queuedCandidate == nil else { return }
        if let preferred, preferred != candidate, proposalIndex != 0, trial - lastPreferredTrial >= 4 {
            _ = try preferred.validated()
            guard (0..<3).allSatisfy({ preferred[$0].target == (motors.contains($0) ? ceilings[$0].target : 0) }) else {
                throw AppError.invalid("Queued Finder pattern changed the selected motor ceilings.")
            }
            queuedCandidate = preferred
            lastPreferredTrial = trial; proposalIndex = (proposalIndex + 1) % 3
        } else { queuedCandidate = nextCandidate(random: &random) }
    }
    private mutating func takeNextCandidate<R: RandomNumberGenerator>(random: inout R) -> VibrationSettings {
        let next = queuedCandidate ?? nextCandidate(random: &random)
        queuedCandidate = nil; return next
    }

    /// An interrupted interval never becomes a winner; try another candidate after the existing cooldown.
    @discardableResult public mutating func interrupt<R: RandomNumberGenerator>(reason: String = "Controller cooldown", random: inout R) -> Bool {
        guard running, startedAt != nil else { return false }
        discardedTrials += 1; lastInterruption = reason; trial += 1; resetWindow()
        candidate = takeNextCandidate(random: &random)
        return true
    }

    /// Returns true when the candidate changes or the search completes.
    @discardableResult public mutating func observe<R: RandomNumberGenerator>(score: Double, time: Double,
                    permitted: Bool, interruptionReason: String = "Controller cooldown", actualCutoff: Bool = false, random: inout R) throws -> Bool {
        guard running else { return false }
        guard score.isFinite, (0...65535).contains(score), time.isFinite, time >= 0,
              lastTime == nil || time >= lastTime! else { throw AppError.invalid("Invalid Finder score or clock.") }
        var changed = false
        if let previous = lastTime, time - previous >= USBWire.controllerFreshnessSeconds {
            changed = interrupt(reason: "Controller timing gap", random: &random)
        }
        let duplicate = lastTime == time
        lastTime = time
        guard permitted || actualCutoff else { return interrupt(reason: interruptionReason, random: &random) || changed }
        if actualCutoff && startedAt == nil { return changed }
        guard !duplicate || actualCutoff else { return changed }
        if startedAt == nil { startedAt = time; startScore = score }
        let elapsed = time - startedAt!
        if !duplicate {
            count += 1; sumTime += elapsed; sumScore += score
            sumTimeSquared += elapsed * elapsed; sumTimeScore += elapsed * score
        }
        secondsRemaining = max(0, Self.interval - elapsed)
        guard elapsed >= Self.interval || actualCutoff else { return changed }
        let denominator = count * sumTimeSquared - sumTime * sumTime
        guard count >= 2, elapsed > 0, denominator > 0 else { return interrupt(reason: "Cutoff before enough samples", random: &random) || changed }
        let rate = denominator > 0 ? (count * sumTimeScore - sumTime * sumScore) / denominator : 0
        let positive = (count >= 20 || actualCutoff) && rate > 0 && score > startScore
        let result = FinderResult(level: min(targetLevel, results.count + 1), trial: trial, settings: candidate,
                                  startScore: startScore, endScore: score, seconds: elapsed, rate: rate, fallback: !positive, cutoffLimited: actualCutoff)
        latestTrial = result
        if bestTrial == nil || result.comparisonRate > bestTrial!.comparisonRate {
            bestTrial = result
        }
        // ponytail: one uninterrupted trial per winner; add repeated/counterbalanced trials before causal claims.
        if positive, elapsed >= 1, result.comparisonRate > (winner?.comparisonRate ?? 0) + 0.000001 {
            if results.count == targetLevel { results[results.count - 1] = result }
            else { results.append(result) }
            trialsWithoutImprovement = 0
        } else if isFinalLevel { trialsWithoutImprovement += 1 }
        endedForNoImprovement = isFinalLevel && trialsWithoutImprovement >= Self.noImprovementLimit
        if endedForNoImprovement { stop() }
        else { trial += 1; resetWindow(); candidate = takeNextCandidate(random: &random) }
        return true
    }

    public mutating func stop() {
        running = false; queuedCandidate = nil; candidate = VibrationSettings(); resetWindow()
    }
}
