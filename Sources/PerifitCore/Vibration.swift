import Foundation
import CryptoKit
import EOMCore

public enum VibrationMode: String, Codable, CaseIterable, Sendable {
    case ramp, steps, constant, wave, pulse
    public var title: String {
        switch self {
        case .ramp: return "Ramp / Stop (original)"
        case .steps: return "Stepped ramp"
        case .constant: return "Hold target"
        case .wave: return "Customizable waves"
        case .pulse: return "Repeating pulses"
        }
    }
    public var isPattern: Bool { self == .wave || self == .pulse }
}

public enum WaveCurve: String, Codable, CaseIterable, Sendable {
    case sine, linear
    public var title: String { self == .sine ? "Smooth sine" : "Straight ramps" }
}

public struct VibrationPattern: Codable, Equatable, Sendable {
    public var minimum = 0.0
    public var maximum = 100.0
    public var riseSeconds = 5.0
    public var fallSeconds = 5.0
    public var curve = WaveCurve.sine
    public init() {}
    public var duration: Double { riseSeconds + fallSeconds }
    public func validated() throws -> Self {
        guard minimum.isFinite, maximum.isFinite, (0...100).contains(minimum), (minimum...100).contains(maximum),
              riseSeconds.isFinite, fallSeconds.isFinite, (0.2...600).contains(riseSeconds), (0.2...600).contains(fallSeconds) else {
            throw AppError.invalid("Pattern levels must be 0–100%, minimum ≤ maximum; each phase must last 0.2–600 seconds.")
        }
        return self
    }
    public func level(at time: Double, mode: VibrationMode) throws -> Double {
        _ = try validated()
        guard mode.isPattern, time.isFinite, time >= 0 else { throw AppError.invalid("Invalid pattern mode or clock.") }
        var phase = time.truncatingRemainder(dividingBy: duration)
        if duration - phase < 1e-9 { phase = 0 }
        if mode == .pulse { return phase < riseSeconds - 1e-9 ? maximum : minimum }
        let fraction = phase < riseSeconds ? phase / riseSeconds : 1 - (phase - riseSeconds) / fallSeconds
        let progress = curve == .sine ? (1 - cos(.pi * fraction)) / 2 : fraction
        return min(maximum, max(minimum, minimum + (maximum - minimum) * progress))
    }
}
public struct VibrationChannel: Codable, Equatable, Sendable {
    public var target = 0.0
    public var start = 4.0
    public var mode = VibrationMode.ramp
    public var rampSeconds = 30.0
    public var stepPercent = 5.0
    public var stepSeconds = 1.0
    public var pattern: VibrationPattern?
    public var effectivePattern: VibrationPattern { pattern ?? VibrationPattern() }
    public init() {}
    public func validated() throws -> Self {
        _ = try effectivePattern.validated()
        guard [target, start].allSatisfy({ $0.isFinite && (0...100).contains($0) }),
              rampSeconds.isFinite, (0.1...600).contains(rampSeconds),
              stepPercent.isFinite, (0.1...100).contains(stepPercent),
              stepSeconds.isFinite, (0.1...60).contains(stepSeconds) else {
            throw AppError.invalid("Channel levels must be 0–100%; ramp time 0.1–600s; step size 0.1–100%; step time 0.1–60s.")
        }
        return self
    }
}
public struct VibrationSettings: Codable, Equatable, Sendable {
    public var one = VibrationChannel()
    public var two = VibrationChannel()
    public var three = VibrationChannel()
    public init() {}
    private enum CodingKeys: String, CodingKey { case one, two, three }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        one = try values.decode(VibrationChannel.self, forKey: .one)
        two = try values.decode(VibrationChannel.self, forKey: .two)
        three = try values.decodeIfPresent(VibrationChannel.self, forKey: .three) ?? VibrationChannel()
    }
    public var channels: [VibrationChannel] { [one, two, three] }
    public subscript(index: Int) -> VibrationChannel {
        get { channels[index] }
        set { switch index { case 0: one = newValue; case 1: two = newValue; case 2: three = newValue; default: preconditionFailure("Invalid motor channel") } }
    }
    public func validated() throws -> Self { for channel in channels { _ = try channel.validated() }; return self }
    public var profileKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? (three == VibrationChannel() ? encoder.encode(["one": one, "two": two]) : encoder.encode(self)) else { return "invalid" }
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
public struct VibrationLevels: Codable, Equatable, Sendable {
    public var one: Int
    public var two: Int
    public var three: Int
    public init(_ one: Int = 0, _ two: Int = 0, _ three: Int = 0) { self.one = one; self.two = two; self.three = three }
    private enum CodingKeys: String, CodingKey { case one, two, three }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        one = try values.decode(Int.self, forKey: .one); two = try values.decode(Int.self, forKey: .two)
        three = try values.decodeIfPresent(Int.self, forKey: .three) ?? 0
    }
    public var values: [Int] { [one, two, three] }
    public subscript(index: Int) -> Int {
        get { values[index] }
        set { switch index { case 0: one = newValue; case 1: two = newValue; case 2: three = newValue; default: preconditionFailure("Invalid motor channel") } }
    }
    /// On advertised limits, a zero M3 cap means legacy two-channel firmware.
    public var channelCount: Int { three > 0 ? 3 : 2 }
    public static let zero = VibrationLevels()
    public var anyOn: Bool { values.contains { $0 > 0 } }
    public func validated(limits: VibrationLevels = VibrationLevels(255, 255, 255)) throws -> Self {
        guard (1...255).contains(limits.one), (1...255).contains(limits.two),
              (0...255).contains(limits.three), zip(values, limits.values).allSatisfy({ (0...$1).contains($0) }) else {
            throw AppError.invalid("Motor command exceeds the board's advertised limits.")
        }
        return self
    }
}
public struct VibrationTargetChange: Codable, Sendable {
    public var time: Double
    public var one: Double
    public var two: Double
    public var three: Double?
    public var settings: VibrationSettings?
    public var orgasmPreset: Bool?
    public init(time: Double, settings: VibrationSettings, orgasmPreset: Bool = false) {
        self.time = time; one = settings.one.target; two = settings.two.target; self.settings = settings
        three = settings.three.target
        self.orgasmPreset = orgasmPreset
    }
}

/// User-observed operating range; not an electrical rating or a current measurement.
public struct MotorCalibration: Codable, Equatable, Sendable {
    public var port: String
    public var boardLimits: VibrationLevels
    public var supplyVoltage: Double
    public var minimums: VibrationLevels
    public var maximums: VibrationLevels
    public var date = Date()
    public init(port: String, boardLimits: VibrationLevels, supplyVoltage: Double,
                minimums: VibrationLevels, maximums: VibrationLevels) {
        self.port = port; self.boardLimits = boardLimits; self.supplyVoltage = supplyVoltage
        self.minimums = minimums; self.maximums = maximums
    }
    public func validated() throws -> Self {
        guard !port.isEmpty, supplyVoltage.isFinite, (4.5...6.2).contains(supplyVoltage),
              minimums.one > 0, minimums.two > 0, boardLimits.three == 0 || minimums.three > 0 else {
            throw AppError.invalid("Discovery needs a verified 4.5–6.2 V supply and starting levels for all motors.")
        }
        _ = try maximums.validated(limits: boardLimits)
        _ = try minimums.validated(limits: maximums)
        return self
    }
    public var profileKey: String {
        let old = "\(supplyVoltage):\(minimums.one),\(minimums.two):\(maximums.one),\(maximums.two)"
        return boardLimits.three == 0 ? old : old + ":m3:\(minimums.three),\(maximums.three)"
    }
}

public struct MotorDiscoveryChannel: Sendable {
    public var pwm = 8
    public private(set) var highestTested = 0
    public private(set) var awaitingObservation: Int?
    public private(set) var minimum = 0
    public private(set) var maximum = 0
    public init() {}
    public func validatePulse(limit: Int) throws {
        guard awaitingObservation == nil, (1...255).contains(limit),
              pwm > 0, pwm <= limit else {
            throw AppError.invalid("Review the last pulse, then choose a test level from 1 to the firmware limit (\(limit) PWM).")
        }
    }
    public mutating func completed(pwm: Int, limit: Int) throws {
        self.pwm = pwm; try validatePulse(limit: limit)
        highestTested = max(highestTested, pwm); awaitingObservation = pwm
    }
    public mutating func observe(runsNormally: Bool) {
        guard let tested = awaitingObservation else { return }
        if runsNormally {
            minimum = minimum == 0 ? tested : min(minimum, tested)
            maximum = tested
        }
        awaitingObservation = nil
    }
}

public struct VibrationEnvelope: Sendable {
    private struct ChannelState: Sendable {
        var active = false
        var value: Float = 0
        var stepAt = 0.0
        var mode: VibrationMode?
        var cycle = VibrationPattern()
        mutating func advance(_ settings: VibrationChannel, limit: Int, minimum: Int, permitted: Bool, time: Double) throws -> Int {
            guard permitted && settings.target > 0 else { self = Self(); return 0 }
            if mode != settings.mode { self = Self(); mode = settings.mode }
            let target = Float(max(minimum, Int((settings.target * Double(limit) / 100).rounded(.down))))
            let start = Float(max(minimum, Int((min(settings.start, settings.target) * Double(limit) / 100).rounded(.down))))
            if !active { active = true; value = start; stepAt = time; cycle = settings.effectivePattern }
            value = min(value, target) // Target reductions take effect immediately.
            switch settings.mode {
            case .constant: value = target
            case .ramp:
                let increment = eom_ramp_increment(UInt8(start), UInt8(target), Float(settings.rampSeconds), 50)
                value = value < target - increment ? value + increment : target
            case .steps:
                let count = floor(max(0, time - stepAt) / settings.stepSeconds)
                if count >= 1 {
                    value = min(target, value + Float(count * settings.stepPercent * Double(limit) / 100))
                    stepAt += count * settings.stepSeconds
                }
            case .wave, .pulse:
                let elapsed = time - stepAt
                if elapsed >= cycle.duration {
                    stepAt += cycle.duration
                    cycle = settings.effectivePattern
                    stepAt += floor(max(0, time - stepAt) / cycle.duration) * cycle.duration
                }
                // Live shape/timing edits take effect at a cycle boundary. Lower ceilings apply immediately.
                let percent = min(settings.effectivePattern.maximum, try cycle.level(at: max(0, time - stepAt), mode: settings.mode))
                guard percent > 0 else { value = 0; return 0 }
                value = max(Float(minimum), target * Float(percent / 100))
            }
            return min(Int(target), max(0, Int(value.rounded(.down))))
        }
    }
    private var one = ChannelState()
    private var two = ChannelState()
    private var three = ChannelState()
    private var lastTime: Double?
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func step(_ settings: VibrationSettings, limits: VibrationLevels = VibrationLevels(255, 255, 255),
                              minimums: VibrationLevels = .zero,
                              permitted: Bool, time: Double, outputScale: Double = 1) throws -> VibrationLevels {
        _ = try settings.validated(); _ = try minimums.validated(limits: limits)
        guard time.isFinite, time >= 0, lastTime == nil || time >= lastTime!, outputScale.isFinite, (0...1).contains(outputScale) else {
            reset(); throw AppError.invalid("Invalid vibration clock.")
        }
        lastTime = time
        var scaled = settings
        if outputScale != 1 { for index in 0..<3 { scaled[index].target *= outputScale; scaled[index].start *= outputScale } }
        return try VibrationLevels(one.advance(scaled.one, limit: limits.one, minimum: minimums.one, permitted: permitted, time: time),
                               two.advance(scaled.two, limit: limits.two, minimum: minimums.two, permitted: permitted, time: time),
                               three.advance(scaled.three, limit: limits.three, minimum: minimums.three, permitted: permitted, time: time))
    }
}
