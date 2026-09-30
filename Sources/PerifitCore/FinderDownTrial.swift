import Foundation

public struct FinderDescent: Codable, Sendable {
    public let startScore: Double
    public let endScore: Double
    public let seconds: Double
    public let rate: Double
    public let secondsToFall: Double?
    public let cutoffLimited: Bool?
    public func validated() throws -> Self {
        guard startScore.isFinite, endScore.isFinite, (0...65535).contains(startScore), (0...65535).contains(endScore),
              seconds.isFinite, seconds > 0, cutoffLimited == true || seconds >= 10, rate.isFinite,
              secondsToFall == nil || (secondsToFall!.isFinite && (0...seconds).contains(secondsToFall!)) else {
            throw AppError.invalid("Invalid Finder ramp-down measurement.")
        }
        return self
    }
}

/// Measures the same pattern while its output multiplier ramps from 100% to zero over ten seconds.
public struct FinderDownTrial: Sendable {
    public let pattern: FinderResult
    public private(set) var result: FinderDescent?
    public private(set) var scale = 1.0
    public private(set) var secondsRemaining = PatternFinder.interval
    public private(set) var interruptions = 0
    public private(set) var lastInterruption: String?
    private var startedAt: Double?
    private var lastTime: Double?
    private var startScore = 0.0
    private var firstFall: Double?
    private var count = 0.0, sumTime = 0.0, sumScore = 0.0, sumTimeSquared = 0.0, sumTimeScore = 0.0
    public init(pattern: FinderResult) throws { self.pattern = try pattern.validated() }

    public mutating func interrupt(_ reason: String) {
        guard result == nil else { return }
        if startedAt != nil { interruptions += 1; lastInterruption = reason }
        startedAt = nil; lastTime = nil; firstFall = nil; scale = 1; secondsRemaining = PatternFinder.interval
        count = 0; sumTime = 0; sumScore = 0; sumTimeSquared = 0; sumTimeScore = 0
    }
    public mutating func observe(score: Double, time: Double, permitted: Bool, interruptionReason: String, actualCutoff: Bool = false) throws {
        guard result == nil else { return }
        guard score.isFinite, (0...65535).contains(score), time.isFinite, time >= 0,
              lastTime == nil || time >= lastTime! else { throw AppError.invalid("Invalid Finder ramp-down sample.") }
        if let previous = lastTime, time - previous >= USBWire.controllerFreshnessSeconds { interrupt("Controller timing gap") }
        guard permitted || actualCutoff else { interrupt(interruptionReason); return }
        if actualCutoff && startedAt == nil { return }
        let duplicate = lastTime == time
        guard !duplicate || actualCutoff else { return }
        lastTime = time
        if startedAt == nil { startedAt = time; startScore = score }
        let elapsed = time - startedAt!
        scale = max(0, 1 - elapsed / PatternFinder.interval)
        secondsRemaining = max(0, PatternFinder.interval - elapsed)
        if firstFall == nil && score < startScore { firstFall = elapsed }
        if !duplicate {
            count += 1; sumTime += elapsed; sumScore += score
            sumTimeSquared += elapsed * elapsed; sumTimeScore += elapsed * score
        }
        if elapsed >= PatternFinder.interval || actualCutoff {
            let denominator = count * sumTimeSquared - sumTime * sumTime
            guard elapsed > 0, count >= 2, denominator > 0 else { interrupt("Insufficient ramp-down samples"); return }
            result = FinderDescent(startScore: startScore, endScore: score, seconds: elapsed,
                rate: (count * sumTimeScore - sumTime * sumScore) / denominator, secondsToFall: firstFall,
                cutoffLimited: actualCutoff ? true : nil)
        }
    }
}
