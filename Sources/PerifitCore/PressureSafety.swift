import Foundation

public struct PressureSafetyContext: Sendable {
    public let baseline: Double
    public let gain: Double
    public let score: Int
    public let peakTrough: Int
    public let cutoff: Int
    public let permitted: Bool
    public let peakGuardEnabled: Bool
    public let time: Double
    public let acknowledgedPause: UUID?
    public init(baseline: Double, gain: Double, score: Int, peakTrough: Int, cutoff: Int,
                permitted: Bool, peakGuardEnabled: Bool, time: Double, acknowledgedPause: UUID?) throws {
        guard baseline.isFinite, (0...65535).contains(baseline), gain.isFinite, (0.01...100).contains(gain),
              (0...65535).contains(score), (0...65535).contains(peakTrough), (10...65535).contains(cutoff),
              time.isFinite, time >= 0 else { throw AppError.invalid("Invalid pressure safety context.") }
        self.baseline=baseline; self.gain=gain; self.score=score; self.peakTrough=peakTrough
        self.cutoff=cutoff; self.permitted=permitted; self.peakGuardEnabled=peakGuardEnabled
        self.time=time; self.acknowledgedPause=acknowledgedPause
    }
}

public struct PressureSafetyEvent: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case pendingPeak, stalePressure, zeroPressure, invalidPressure, disconnected }
    public var id = UUID()
    public var time: Double
    public var handledAt: Double?
    public var actionTime: Double?
    public var countedAsCutoff: Bool?
    public var pressureTime: Double?
    public var scoreTime: Double
    public var kind: Kind
    public var score: Int
    public var pendingPeak: Int
    public var pressure: Double
    public var cutoff: Int
    public var guardScore: Int { min(65535, score + pendingPeak) }
    public var requiresDisarm: Bool { [.zeroPressure, .invalidPressure, .disconnected].contains(kind) }
    public var reason: String {
        switch kind {
        case .pendingPeak: return "Incoming pressure peak: \(score) + \(pendingPeak) ≥ cutoff \(cutoff)"
        case .stalePressure: return "Pressure stream paused; all motor outputs held OFF"
        case .zeroPressure: return "Perifit pressure dropped to zero; all motor outputs stopped"
        case .invalidPressure: return "Invalid pressure input; all motor outputs stopped"
        case .disconnected: return "Perifit disconnected; all motor outputs stopped"
        }
    }
}

/// Serial-worker-owned guard. The filter uses elapsed time, never a UI-dependent sample count.
public struct PressureSafety: Sendable {
    public static let smoothingSeconds = 0.15
    public private(set) var context: PressureSafetyContext?
    public private(set) var sample: PressureSample?
    public private(set) var filteredPressure: Double?
    public private(set) var pause: PressureSafetyEvent?
    public init() {}
    public mutating func configure(_ context: PressureSafetyContext) { self.context = context }
    public mutating func reset() { self = Self() }
    private var pendingPeak: Int {
        guard let context, let pressure=filteredPressure else { return 0 }
        let rise=max(0, Int(pressure)-context.peakTrough)
        return rise >= context.cutoff / 10 ? rise : 0
    }
    public mutating func fail(_ kind: PressureSafetyEvent.Kind, at now: Double) {
        guard let context, pause == nil || (pause?.requiresDisarm == false && [.zeroPressure, .invalidPressure, .disconnected].contains(kind)) else { return }
        pause=PressureSafetyEvent(time: now, pressureTime: sample?.time, scoreTime: context.time, kind: kind, score: context.score,
                                  pendingPeak: pendingPeak, pressure: filteredPressure ?? 0, cutoff: context.cutoff)
    }
    public mutating func observe(_ incoming: PressureSample, at now: Double) {
        guard let context else { return }
        guard incoming.time.isFinite, incoming.time >= 0, incoming.time <= now else { fail(.invalidPressure, at: now); return }
        if let sample, incoming.time <= sample.time { return } // Delayed UI delivery cannot refresh an old packet.
        let previous=sample
        sample=incoming
        guard incoming.hasPressure else { fail(.zeroPressure, at: now); return }
        guard let pressure=try? incoming.conditioned(baseline: context.baseline, gain: context.gain) else { fail(.invalidPressure, at: now); return }
        if let previous, let filtered=filteredPressure, incoming.time-previous.time <= PressureFreshness.outputMaximumAge {
            let dt=incoming.time-previous.time
            filteredPressure=filtered+dt/(Self.smoothingSeconds+dt)*(Double(pressure)-filtered)
        } else { filteredPressure=Double(pressure) }
        evaluate(at: now)
    }
    public mutating func evaluate(at now: Double) {
        guard let context else { return }
        guard now.isFinite, now >= context.time, sample == nil || now >= sample!.time else { fail(.invalidPressure, at: max(0, context.time)); return }
        guard let sample, now-sample.time <= PressureFreshness.outputMaximumAge else {
            if now-(sample?.time ?? context.time) >= PressureFreshness.outputMaximumAge { fail(.stalePressure, at: now) }
            return
        }
        guard sample.hasPressure else { fail(.zeroPressure, at: now); return }
        let risk=context.peakGuardEnabled && context.score+pendingPeak >= context.cutoff
        if let event=pause, !event.requiresDisarm, context.acknowledgedPause == event.id, context.permitted, !risk {
            pause=nil
        }
        if context.permitted && risk { fail(.pendingPeak, at: now) }
    }
    public func allowsOutput(at now: Double) -> Bool {
        guard let context, let sample else { return false }
        return context.permitted && pause == nil && sample.hasPressure && now-sample.time <= PressureFreshness.outputMaximumAge
    }
}
