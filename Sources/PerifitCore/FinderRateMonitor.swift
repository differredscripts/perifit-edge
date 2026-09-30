import Foundation

public extension FinderResult {
    var riseRate: Double { let values = riseSamples ?? [comparisonRate]; return values.reduce(0, +) / Double(values.count) }
    var fallRate: Double? {
        guard let values = fallSamples ?? descent.map({ [$0.rate] }) else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
    var upperRiseRate: Double {
        // A brief pressure peak is not a sustained slope for the entire lookahead.
        let mean = riseRate
        return max(0, mean + max(0.05, abs(mean) * 0.25))
    }
    var responseDelay: Double {
        if let observed = responseDelays?.max() { return observed }
        guard let descent else { return 2 }
        return descent.rate < 0 && descent.endScore < descent.startScore ? (descent.secondsToFall ?? descent.seconds) : max(2, descent.seconds)
    }
    mutating func validateLiveRate(_ update: FinderRateUpdate) {
        if update.falling {
            fallSamples = Array(((fallSamples ?? descent.map({ [$0.rate] }) ?? []) + [update.rate]).suffix(12))
            if let delay = update.responseDelay {
                responseDelays = Array(((responseDelays ?? [descent?.secondsToFall ?? 2]) + [delay]).suffix(12))
            }
        } else { riseSamples = Array(((riseSamples ?? [comparisonRate]) + [update.rate]).suffix(12)) }
        validationCount = (validationCount ?? 0) + 1
    }
}

public struct FinderRateUpdate: Sendable {
    public let patternID: UUID
    public let rate: Double
    public let falling: Bool
    public let responseDelay: Double?
}

/// Validate over a complete trial so pressure peaks and the following decay share one estimate.
public struct FinderRateMonitor: Sendable {
    private var patternID: UUID?
    private var falling = false
    private var phaseAt = 0.0, phaseScore = 0.0
    private var firstFall: Double?
    private var startedAt = 0.0
    private var lastTime: Double?
    private var count = 0.0, sumTime = 0.0, sumScore = 0.0, sumTimeSquared = 0.0, sumTimeScore = 0.0
    public init() {}
    public mutating func reset() { self = Self() }
    private mutating func clearWindow(at time: Double) {
        startedAt = time; count = 0; sumTime = 0; sumScore = 0; sumTimeSquared = 0; sumTimeScore = 0
    }
    private mutating func sample(_ score: Double, time: Double) {
        let t = time - startedAt
        count += 1; sumTime += t; sumScore += score; sumTimeSquared += t * t; sumTimeScore += t * score
        if firstFall == nil && score < phaseScore { firstFall = time - phaseAt }
    }
    private func result(at time: Double) -> FinderRateUpdate? {
        let denominator = count * sumTimeSquared - sumTime * sumTime
        guard let patternID, time - startedAt >= 1, count >= 3, denominator > 0 else { return nil }
        return FinderRateUpdate(patternID: patternID, rate: (count * sumTimeScore - sumTime * sumScore) / denominator,
                                falling: falling, responseDelay: falling ? (firstFall ?? min(3600, time - phaseAt)) : nil)
    }
    public mutating func observe(score: Double, time: Double, patternID id: UUID?, falling down: Bool) -> FinderRateUpdate? {
        guard score.isFinite, time.isFinite, time >= 0 else { reset(); return nil }
        if let previous = lastTime, time < previous || time - previous >= USBWire.controllerFreshnessSeconds { reset() }
        guard lastTime != time else { return nil }
        var update: FinderRateUpdate?
        if patternID != id || falling != down {
            if patternID != nil { sample(score, time: time); update = result(at: time) }
            patternID = id; falling = down; phaseAt = time; phaseScore = score; firstFall = nil
            clearWindow(at: time)
        }
        lastTime = time
        guard id != nil else { return update }
        sample(score, time: time)
        if time - startedAt >= PatternFinder.interval { update = result(at: time); clearWindow(at: time); sample(score, time: time) }
        return update
    }
}
