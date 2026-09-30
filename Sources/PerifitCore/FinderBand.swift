import Foundation

/// Prediction schedules the next pattern; only the real controller can interrupt the current one.
public struct FinderBand: Sendable {
    public enum Phase: String, Sendable { case building = "Building", easing = "Easing", off = "Cutoff OFF", cooldown = "Cooldown" }
    public private(set) var phase = Phase.cooldown
    public private(set) var candidate = VibrationSettings()
    public private(set) var selectedRate: Double?
    public private(set) var rate = 0.0
    public private(set) var predictionScore = 0.0
    public private(set) var outputScale = 1.0
    public private(set) var selectedPatternID: UUID?
    public private(set) var forecastScore = 0.0
    public private(set) var lookaheadSeconds = 0.0
    public private(set) var queuedCandidate: VibrationSettings?
    public private(set) var queuedPhase: Phase?
    private var queuedPatternID: UUID?
    private let ceilings: VibrationSettings
    private let motors: Set<Int>
    private let easingFloor: Double
    private var lastTime: Double?
    private var phaseAt = 0.0
    private var patternAt: Double?
    private var wasLearning = false

    public init(settings: VibrationSettings, motors: Set<Int>, easingPercent: Double = 15) throws {
        _ = try settings.validated()
        guard !motors.isEmpty, motors.allSatisfy({ (0..<3).contains($0) && settings[$0].target > 0 }),
              easingPercent.isFinite, (0...50).contains(easingPercent) else { throw AppError.invalid("Invalid Finder motors or easing strength.") }
        ceilings = settings; self.motors = motors; easingFloor = easingPercent / 100
    }
    public mutating func pause() {
        phase = .cooldown; candidate = VibrationSettings(); selectedRate = nil; selectedPatternID = nil
        lastTime = nil; rate = 0; outputScale = 0; patternAt = nil
    }
    private func bounded(_ settings: VibrationSettings) -> VibrationSettings {
        var result = settings
        for index in 0..<3 { result[index].target = motors.contains(index) ? min(result[index].target, ceilings[index].target) : 0 }
        return result
    }
    private mutating func apply(_ settings: VibrationSettings, phase next: Phase, pattern: FinderResult?, time: Double) {
        if next != phase || settings != candidate { phaseAt = time }
        candidate = bounded(settings); phase = next; selectedPatternID = pattern?.id
        selectedRate = next == .easing ? pattern?.fallRate : pattern?.riseRate
        patternAt = time
    }

    @discardableResult public mutating func update(score: Double, time: Double, permitted: Bool,
            edge: Double, cutoff: Double, library: [FinderResult], learning: VibrationSettings? = nil,
            pressureAge: Double = 0) throws -> Bool {
        guard score.isFinite, (0...65535).contains(score), time.isFinite, time >= 0,
              edge.isFinite, cutoff.isFinite, 0 < edge, edge < cutoff, cutoff <= 65535,
              pressureAge.isFinite, pressureAge >= 0, lastTime == nil || time >= lastTime! else {
            throw AppError.invalid("Invalid Finder band or pressure sample.")
        }
        let old = candidate
        guard permitted else { pause(); return candidate != old }
        // The actual score, never the smoothed prediction, owns this immediate stop.
        if score >= cutoff { pause(); phase = .off; return candidate != old }
        if let previous = lastTime, time - previous >= USBWire.controllerFreshnessSeconds {
            pause(); return candidate != old
        }
        if let previous = lastTime, time > previous {
            let dt = time - previous, oldPrediction = predictionScore
            predictionScore += dt / (2 + dt) * (score - predictionScore)
            rate += dt / (1.5 + dt) * ((predictionScore - oldPrediction) / dt - rate)
        } else if lastTime == nil { predictionScore = score }
        lastTime = time
        let matching = library.filter { $0.matches(settings: ceilings, motors: motors) }
        let applied = matching.first { $0.settings == (learning ?? candidate) } ?? matching.first { $0.id == selectedPatternID }
        let ceiling = cutoff - max(1, cutoff * 0.001)
        let floor = min(ceiling, max(edge, cutoff * 0.99))
        let target = (floor + ceiling) / 2
        let remaining = patternAt.map { max(0, PatternFinder.interval - (time - $0)) } ?? 0
        lookaheadSeconds = remaining + USBWire.controllerFreshnessSeconds + pressureAge + (applied?.responseDelay ?? 2)
        let knownRise = applied?.upperRiseRate ?? 0
        let expectedRate = phase == .easing ? max(rate, applied?.fallRate ?? min(0, rate)) : max(rate, knownRise)
        forecastScore = max(0, predictionScore + expectedRate * lookaheadSeconds)
        // A holding pattern is useful inside the band, but must not strand the
        // score below it just because every rising pattern exceeds the ideal rate.
        let rising = matching.filter { predictionScore < floor ? $0.riseRate > 0 : $0.riseRate >= 0 }
        let patterns = (rising.isEmpty ? matching : rising).sorted { $0.riseRate < $1.riseRate }
        let desired = max(0, (target - forecastScore) / PatternFinder.interval)
        let nextRise = patterns.last(where: { $0.riseRate <= desired }) ?? patterns.first

        if let learning {
            _ = try learning.validated()
            candidate = bounded(learning); phase = .building; selectedPatternID = nil; selectedRate = nil; outputScale = 1
            if candidate != old || patternAt == nil { phaseAt = time; patternAt = time }
            wasLearning = true
            if forecastScore >= target {
                queuedCandidate = patterns.first?.settings; queuedPatternID = patterns.first?.id; queuedPhase = .building
            } else { queuedCandidate = nil; queuedPatternID = nil; queuedPhase = nil }
            return candidate != old
        }

        if wasLearning {
            patternAt = nil; queuedCandidate = nil; queuedPatternID = nil; queuedPhase = nil; wasLearning = false
        }
        // Queue a gentler/holding pattern first. Ease only if that next full trial
        // would exceed the upper band; falling forecasts can queue recovery early.
        let nextPeak = forecastScore + (nextRise?.upperRiseRate ?? 0) * PatternFinder.interval
        let wantsEase = forecastScore >= ceiling || (forecastScore >= floor && nextPeak >= ceiling)
        let next = wantsEase && applied != nil ? Phase.easing : Phase.building
        let proposed = next == .easing ? applied : nextRise
        if patternAt == nil || time - patternAt! >= PatternFinder.interval {
            let pending = matching.first { $0.id == queuedPatternID }
            if let settings = queuedCandidate, let nextPhase = queuedPhase {
                apply(settings, phase: nextPhase, pattern: pending, time: time)
            } else if let proposed {
                apply(proposed.settings, phase: next, pattern: proposed, time: time)
            } else { pause(); return candidate != old }
            queuedCandidate = nil; queuedPatternID = nil; queuedPhase = nil
        }
        // Rate updates and forecasts change only this queue, never an in-flight pattern.
        if let proposed, proposed.settings != candidate || next != phase {
            queuedCandidate = proposed.settings; queuedPatternID = proposed.id; queuedPhase = next
        } else { queuedCandidate = nil; queuedPatternID = nil; queuedPhase = nil }
        outputScale = phase == .easing ? max(easingFloor, 1 - (time - phaseAt) / PatternFinder.interval) : 1
        if let current = matching.first(where: { $0.id == selectedPatternID }) {
            selectedRate = phase == .easing ? current.fallRate : current.riseRate
        }
        return candidate != old
    }
}
