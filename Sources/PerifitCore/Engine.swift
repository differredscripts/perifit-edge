import Foundation
import EOMCore

public enum AppError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

public struct EngineSettings: Codable, Equatable, Sendable {
    public var sensitivity = 600
    public var edgeTarget: Int? = 360
    public var effectiveEdgeTarget: Int { edgeTarget ?? max(1, sensitivity * 3 / 5) }
    public var sustainedThreshold = 200
    public var peakAmplitude = 40
    public var decay = 60
    public var averaging = false
    public var smoothing = 5
    public var cooldown = 5.0
    public var jitter = 1.0
    public var holdoff = 1.0
    public var detectionMode = 0
    public var sustainedDuration = 5.0
    public var sustainedDropout = 0.5
    public var minimumPeaks = 4
    public var intervalMinimum = 0.5
    public var intervalMaximum = 1.2
    public var intervalVariance = 0.2
    public var rhythmicTimeout = 1.5
    public var arousalGate = 70
    public var recovery = 3.0
    public var clenchBoost = false
    public var boostAmount = 5
    // Missing in historical recordings: their original decision path stays replayable.
    public var pendingPeakGuard: Bool?
    public init() {}

    public func validated() throws -> EngineSettings {
        let ints = [sensitivity, sustainedThreshold, peakAmplitude, decay, smoothing,
                    detectionMode, minimumPeaks, arousalGate, boostAmount]
        let seconds = [cooldown, jitter, holdoff, sustainedDuration, sustainedDropout,
                       intervalMinimum, intervalMaximum, intervalVariance, rhythmicTimeout, recovery]
        guard ints.allSatisfy({ (0...65535).contains($0) }),
              seconds.allSatisfy({ $0.isFinite && (0...3600).contains($0) }), cooldown >= 3,
              effectiveEdgeTarget >= 1, effectiveEdgeTarget < sensitivity,
              eom_valid_config(cConfig) else { throw AppError.invalid("The Edge reference must be below the near-orgasm cutoff. Minimum controller cooldown is three seconds.") }
        return self
    }

    var cConfig: EOMConfig {
        var c = eom_default_config()
        c.sensitivity_threshold = Int32(sensitivity)
        c.od_sustained_threshold = Int32(sustainedThreshold)
        c.od_peak_min_amplitude = Int32(peakAmplitude)
        c.arousal_decay_rate = Int32(decay)
        c.use_average_values = averaging
        c.pressure_smoothing = Int32(smoothing)
        c.cooldown_delay_ms = Int32(cooldown * 1000)
        c.cooldown_random_ms = Int32(jitter * 1000)
        c.arousal_holdoff_ms = Int32(holdoff * 1000)
        c.od_mode = Int32(detectionMode)
        c.od_sustained_fallback_ms = Int32(sustainedDuration * 1000)
        c.od_sustained_dropout_ms = Int32(sustainedDropout * 1000)
        c.od_rhythmic_min_peaks = Int32(minimumPeaks)
        c.od_rhythmic_interval_min_ms = Int32(intervalMinimum * 1000)
        c.od_rhythmic_interval_max_ms = Int32(intervalMaximum * 1000)
        c.od_rhythmic_interval_variance_ms = Int32(intervalVariance * 1000)
        c.od_rhythmic_timeout_ms = Int32(rhythmicTimeout * 1000)
        c.od_arousal_gate_percent = Int32(arousalGate)
        c.od_recovery_ms = Int32(recovery * 1000)
        c.od_clench_arousal_boost = clenchBoost
        c.od_clench_arousal_boost_amount = Int32(boostAmount)
        return c
    }
}

public struct Snapshot: Codable, Sendable, Equatable {
    public var score: Int = 0
    public var controlPhase: Int = 2
    public var detectionPhase: Int = 0
    public var wantsPower = false
    public var edge = false
    public var detected = false
    public var rhythmic = false
    public var speed = 0.0
    public var sustained = 0.0
    public var peaks = 0
    public var interval = 0.0
    // Optional keeps pre-policy archives decodable and exactly replayable.
    public var riskReason: String?
    public var pendingPeak: Int?
    public var peakTrough: Int?
    public var guardScore: Int?
    public init() {}
    public var phaseName: String { ["Running", "Cooldown", "Resuming"][max(0, min(2, controlPhase))] }
    public var detectionName: String { ["Idle", "Sustained", "Rhythmic", "Detected"][max(0, min(3, detectionPhase))] }
}

public enum ControlPolicy: Int, Codable, Sendable {
    case legacyEdgeCutoff = 1
    case rideEdge = 2
}

public final class Engine {
    private let pointer: OpaquePointer
    public private(set) var settings: EngineSettings
    public let policy: ControlPolicy
    private var armed = false
    public init(settings: EngineSettings, seed: UInt32 = 1, policy: ControlPolicy = .rideEdge) throws {
        self.settings = try settings.validated()
        self.policy = policy
        guard let pointer = eom_create(settings.cConfig, seed) else { throw AppError.invalid("Cannot initialize the control engine.") }
        self.pointer = pointer
    }
    deinit { eom_destroy(pointer) }
    public func updateThresholds(edge: Int, cutoff: Int) throws {
        var updated = settings
        updated.edgeTarget = edge; updated.sensitivity = cutoff
        _ = try updated.validated()
        guard eom_set_sensitivity(pointer, Int32(cutoff)) else { throw AppError.invalid("Invalid cutoff threshold.") }
        settings = updated
    }
    private func milliseconds(_ time: Double) throws -> UInt64 {
        guard time.isFinite, time >= 0, time < Double(UInt64.max / 1000) else {
            throw AppError.invalid("Invalid monotonic timestamp.")
        }
        return UInt64((time * 1000).rounded())
    }
    public func arm(_ armed: Bool, at time: Double) throws {
        let timestamp = try milliseconds(time)
        eom_set_armed(pointer, armed, timestamp)
        self.armed = armed
    }
    public func manualEdge(at time: Double) throws { eom_manual_edge(pointer, try milliseconds(time)) }
    public func step(_ pressure: UInt16, at time: Double) throws -> Snapshot {
        let c = eom_step(pointer, pressure, try milliseconds(time))
        var s = Snapshot()
        s.score = Int(c.arousal); s.controlPhase = Int(c.control_phase); s.detectionPhase = Int(c.detection_phase)
        s.wantsPower = c.wants_power; s.edge = c.events & 1 != 0; s.detected = c.events & 2 != 0
        s.rhythmic = c.rhythmic; s.speed = Double(c.motor_speed); s.sustained = Double(c.sustained_ms) / 1000
        s.peaks = Int(c.peak_count); s.interval = Double(c.last_interval_ms) / 1000
        if settings.pendingPeakGuard == true {
            s.pendingPeak = Int(c.pending_peak); s.peakTrough = Int(c.peak_trough)
            s.guardScore = min(65535, s.score + Int(c.pending_peak))
        }
        if policy == .rideEdge {
            if s.detected || s.detectionPhase == 3 { s.riskReason = "Detected contraction pattern" }
            else if s.detectionPhase == 2 { s.riskReason = "Rhythmic warning" }
            else if s.score >= settings.sensitivity { s.riskReason = "Upper score threshold" }
            else if let guarded = s.guardScore, guarded >= settings.sensitivity { s.riskReason = "Incoming pressure peak" }
            // The lower Edge reference is a target, not an OFF trigger. Following
            // a cutoff, wait below that reference for a complete quiet cooldown.
            if armed && (s.riskReason != nil || (s.controlPhase == 1 && s.score > settings.effectiveEdgeTarget)) {
                if s.wantsPower { s.edge = true }
                eom_hold_cooldown(pointer, try milliseconds(time))
                s.wantsPower = false; s.speed = 0; s.controlPhase = 1
            }
        }
        return s
    }
}

public enum PressureFreshness: Equatable, Sendable {
    case fresh, waiting, lost
    public static let maximumAge = 3.0
    public static let outputMaximumAge = 0.5
    public static let lossAge = maximumAge + 2
    public static func evaluate(sampleTime: Double?, now: Double, controllingOutput: Bool = false) -> Self {
        guard let sampleTime, sampleTime.isFinite, now.isFinite, sampleTime >= 0, now >= sampleTime else { return .lost }
        let age = now - sampleTime
        return age <= (controllingOutput ? outputMaximumAge : maximumAge) ? .fresh : (age <= lossAge ? .waiting : .lost)
    }
}

public struct PressureSample: Sendable {
    public let base: UInt16
    public let tip: UInt16
    public let time: Double
    // Raw sensor presence, not the baseline-subtracted control signal (which can normally be zero).
    public var hasPressure: Bool { base > 0 && tip > 0 }
    public init(data: Data, time: Double) throws {
        guard data.count == 4, time.isFinite, time >= 0 else { throw AppError.invalid("Expected a verified four-byte pressure packet.") }
        let bytes = Array(data)
        base = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        tip = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        self.time = time
    }
    public init(base: UInt16, tip: UInt16, time: Double) { self.base = base; self.tip = tip; self.time = time }
    public func conditioned(baseline: Double, gain: Double) throws -> UInt16 {
        guard baseline.isFinite, (0...65535).contains(baseline), gain.isFinite, (0.01...100).contains(gain) else {
            throw AppError.invalid("Invalid pressure calibration.")
        }
        return UInt16(min(65535, max(0, ((Double(base) - baseline) * gain).rounded())))
    }
}
