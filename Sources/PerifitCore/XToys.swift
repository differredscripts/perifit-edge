import Foundation

/// Versioned, flat JSON for an XToys Private Webhook. No device or user identifiers.
public struct XToysTelemetry: Encodable, Sendable {
    public let action = "perifit"
    public let schema = 1
    public let timestampMs: Int64
    public let pressureBase, pressureTip, pressure, arousal, edge, cutoff: Int
    public let arousalPercent: Double
    public let fresh, calibrated, armed, permitted, automaticCutoffs, simulated: Bool

    public init(sample: PressureSample?, snapshot: Snapshot, settings: EngineSettings,
                baseline: Double, gain: Double, now: Double, calibrated: Bool, armed: Bool,
                permitted: Bool, automaticCutoffs: Bool, simulated: Bool, timestamp: Date = Date()) {
        let valid = now.isFinite && sample.map {
            $0.time.isFinite && now >= $0.time && now - $0.time <= PressureFreshness.outputMaximumAge && $0.hasPressure
        } == true
        let conditioned = calibrated && valid ? sample.flatMap { try? $0.conditioned(baseline: baseline, gain: gain) } : nil
        self.timestampMs = Int64(timestamp.timeIntervalSince1970 * 1000)
        self.fresh = valid; self.calibrated = calibrated && conditioned != nil
        self.armed = armed; self.permitted = permitted && armed && valid && self.calibrated
        self.automaticCutoffs = automaticCutoffs; self.simulated = simulated
        self.pressureBase = valid ? Int(sample!.base) : 0
        self.pressureTip = valid ? Int(sample!.tip) : 0
        self.pressure = Int(conditioned ?? 0)
        self.arousal = self.calibrated ? max(0, min(65535, snapshot.score)) : 0
        self.edge = settings.effectiveEdgeTarget; self.cutoff = settings.sensitivity
        self.arousalPercent = min(100, Double(arousal) * 100 / Double(max(1, cutoff)))
    }
}

/// XToys' JSON protocol for a custom two-channel vibrator, with Steps set to 100.
public struct XToysCommand: Decodable {
    public let channel: Int
    public let vibrate: Double
    private struct Payload: Decodable { var channel: Int?; var vibrate: Double }
    public static func parse(_ data: Data, mappedChannel: Int? = nil) throws -> Self {
        guard !data.isEmpty, data.count <= 512 else { throw AppError.invalid("XToys message exceeds the size limit.") }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let channel = mappedChannel ?? payload.channel ?? 0
        guard (mappedChannel == nil ? (1...2).contains(channel) : channel == 3), payload.vibrate.isFinite, (0...100).contains(payload.vibrate),
              mappedChannel == nil || payload.channel == nil || payload.channel == 1 else {
            throw AppError.invalid("XToys requires a valid motor channel and vibration from 0 to 100. Set Steps to 100 in XToys.")
        }
        return Self(channel: channel, vibrate: payload.vibrate)
    }
}

public struct XToysDemand: Equatable, Sendable {
    public private(set) var one = 0.0
    public private(set) var two = 0.0
    public private(set) var three = 0.0
    public init() {}
    public mutating func apply(_ command: XToysCommand) {
        switch command.channel { case 1: one = command.vibrate; case 2: two = command.vibrate; default: three = command.vibrate }
    }
    public func addingM3(_ source: Self) -> Self {
        var result = self; result.three = source.three; return result
    }
    public func levels(settings: VibrationSettings, limits: VibrationLevels, minimums: VibrationLevels,
                       permitted: Bool) throws -> VibrationLevels {
        _ = try settings.validated(); _ = try minimums.validated(limits: limits)
        guard permitted else { return .zero }
        func pwm(_ request: Double, _ settings: VibrationChannel, _ limit: Int, _ minimum: Int) -> Int {
            guard request > 0, settings.target > 0 else { return 0 }
            let ceiling = max(minimum, Int((settings.target * Double(limit) / 100).rounded(.down)))
            return min(ceiling, max(minimum, Int((Double(ceiling) * request / 100).rounded(.down))))
        }
        return VibrationLevels(pwm(one, settings.one, limits.one, minimums.one),
                               pwm(two, settings.two, limits.two, minimums.two),
                               pwm(three, settings.three, limits.three, minimums.three))
    }
}
