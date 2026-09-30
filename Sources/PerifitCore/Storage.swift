import Foundation

public enum OutputDestination: String, CaseIterable, Codable, Sendable {
    case simulation, arduino
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .simulation // Unsupported legacy outputs never activate hardware.
    }
    public var title: String {
        switch self { case .simulation: return "Simulation"; case .arduino: return "USB · M1/M2/M3" }
    }
}

public struct PressureCalibration: Codable, Equatable, Sendable {
    public var peripheral: String
    public var service: String
    public var characteristic: String
    public var baseline: Double
    public var gain: Double
    public var date: Date
    public init(peripheral: String, service: String, characteristic: String, baseline: Double, gain: Double, date: Date = Date()) {
        self.peripheral = peripheral; self.service = service; self.characteristic = characteristic
        self.baseline = baseline; self.gain = gain; self.date = date
    }
    public func validated() throws -> Self {
        guard UUID(uuidString: peripheral) != nil, !service.isEmpty, !characteristic.isEmpty,
              baseline.isFinite, (0...65535).contains(baseline), gain.isFinite, (0.01...100).contains(gain),
              date.timeIntervalSinceReferenceDate.isFinite else { throw AppError.invalid("Invalid saved Perifit calibration.") }
        return self
    }
    public func matches(peripheral: UUID?, service: String?, characteristic: String?, gain: Double) -> Bool {
        (try? validated()) != nil && peripheral == UUID(uuidString: self.peripheral) &&
            service?.uppercased() == self.service.uppercased() && characteristic?.uppercased() == self.characteristic.uppercased() && gain == self.gain
    }
}

public struct TimedEdging: Codable, Equatable, Sendable {
    public var seconds: Double
    public var locked = false
    public var edge: Int
    public var cutoff: Int
    public var elapsedSeconds = 0.0
    public var penaltyEdgesRemaining = 0
    public var sessionOpen = false
    public var completed = false
    public init(seconds: Double, edge: Int, cutoff: Int) {
        self.seconds = seconds; self.edge = edge; self.cutoff = cutoff
    }
    public func validated() throws -> Self {
        guard seconds.isFinite, (1...86400).contains(seconds), elapsedSeconds.isFinite,
              (0...seconds).contains(elapsedSeconds), penaltyEdgesRemaining >= 0, penaltyEdgesRemaining <= Int.max - 5,
              !completed || (elapsedSeconds == seconds && penaltyEdgesRemaining == 0), edge >= 1, edge < cutoff,
              (10...65535).contains(cutoff) else { throw AppError.invalid("Choose 1 second to 24 hours and valid locked pressure thresholds.") }
        return self
    }
    public var remaining: Int { Int(ceil(max(0, seconds - elapsedSeconds))) }
    public mutating func recoverInterruptedSession() {
        guard sessionOpen else { return }
        sessionOpen = false
        if !completed {
            penaltyEdgesRemaining += 5; elapsedSeconds = 0; locked = true
        }
    }
    public mutating func advance(seconds delta: Double, automaticEdge: Bool = false) {
        guard sessionOpen, !completed, delta.isFinite, delta >= 0 else { return }
        if penaltyEdgesRemaining > 0 {
            if automaticEdge { penaltyEdgesRemaining -= 1 }
            return
        }
        elapsedSeconds = min(seconds, elapsedSeconds + delta)
        completed = elapsedSeconds >= seconds
    }
}

public struct Preferences: Codable, Sendable {
    public var gain = 1.0
    public var baselineSettings = EngineSettings()
    public var learning = true
    public var verifiedPeripheral = ""
    public var verifiedService = ""
    public var verifiedCharacteristic = ""
    public var profileGeneration = UUID().uuidString
    public var arduinoPort: String?
    public var vibration: VibrationSettings?
    public var motorCalibration: MotorCalibration?
    public var pressureCalibration: PressureCalibration?
    public var lastInputWasDemo: Bool?
    public var lastOutput: OutputDestination?
    public var finderLibrary: [String: [FinderResult]]?
    public var finderProgress: [String: PatternFinder]?
    public var finderBestPatternOnly: Bool?
    public var finderSetup: FinderSetup?
    public var timedEdging: TimedEdging?
    public var orgasmVibration: VibrationSettings?
    public var effectiveOrgasmVibration: VibrationSettings { orgasmVibration ?? effectiveVibration }
    public var effectiveVibration: VibrationSettings { vibration ?? VibrationSettings() }
    public init() {}
    public func validated() throws -> Preferences {
        _ = try baselineSettings.validated()
        _ = try effectiveVibration.validated()
        _ = try motorCalibration?.validated()
        _ = try pressureCalibration?.validated()
        _ = try timedEdging?.validated()
        _ = try orgasmVibration?.validated()
        _ = try finderSetup?.validated()
        for progress in (finderProgress ?? [:]).values { _ = try progress.validated() }
        for patterns in (finderLibrary ?? [:]).values {
            for pattern in patterns { _ = try pattern.validated() }
        }
        guard gain.isFinite, (0.01...100).contains(gain) else { throw AppError.invalid("Gain must be between 0.01 and 100.") }
        return self
    }
}

public final class LocalStore: @unchecked Sendable {
    public let directory: URL
    public init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PerifitEdge", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
    }
    private func read<T: Decodable>(_ type: T.Type, _ file: String) throws -> T? {
        let url = directory.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, _ file: String) throws {
        let data = try JSONEncoder().encode(value)
        let url = directory.appendingPathComponent(file)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func preferences() throws -> Preferences { try (read(Preferences.self, "preferences.json") ?? Preferences()).validated() }
    public func save(_ preferences: Preferences) throws { try write(preferences.validated(), "preferences.json") }
    public func profiles() throws -> [String: LearningProfile] { try read([String: LearningProfile].self, "profiles.json") ?? [:] }
    public func save(profiles: [String: LearningProfile]) throws { try write(profiles, "profiles.json") }
    public func save(_ session: SessionRecord) throws { try write(session, "session-\(session.id.uuidString).json") }
    public func saveControllerFault(_ details: [String: String]) throws { try write(details, "last-controller-fault.json") }
    public func sessions() throws -> [SessionRecord] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "json" }
        // Fail visibly on corrupt archives: do not silently train on a partial history.
        return try files.map { try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: $0)) }.sorted { $0.date < $1.date }
    }
    public func deleteLearningHistory() throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix("session-") || url.lastPathComponent == "profiles.json" || url.lastPathComponent == "learning-backups" {
            try FileManager.default.removeItem(at: url)
        }
    }
}

