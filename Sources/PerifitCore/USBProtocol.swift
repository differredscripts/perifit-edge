import Foundation

/// PE1 is newline-framed ASCII, bounded for an ATmega328P's 2 KB RAM.
public enum USBReply: Equatable, Sendable {
    case boot
    case ready(session: String, limits: VibrationLevels, discovery: Bool = false)
    case ack(session: String, sequence: UInt32, armed: Bool, levels: VibrationLevels)
    case error(session: String, sequence: UInt32, code: String)
    case fault(session: String, code: String)
}
public enum USBWire {
    public static let watchdogMilliseconds = 1000
    public static let controllerFreshnessSeconds = 0.700
    public static let acknowledgementSeconds = 0.900
    public static let maximumLineBytes = 128
    public static func validSession(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func newSession() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    public static func command(_ verb: String, session: String, sequence: UInt32? = nil,
                               levels: VibrationLevels? = nil, channels: Int = 2) throws -> Data {
        guard validSession(session), [2, 3].contains(channels), ["HELLO", "ARM", "SET", "STOP", "TEST"].contains(verb) else { throw AppError.invalid("Invalid USB command.") }
        var fields = ["PE1", verb, session]
        if verb != "HELLO" {
            guard let sequence, sequence > 0, sequence <= 2_147_483_647 else { throw AppError.invalid("Invalid USB sequence.") }
            fields.append(String(sequence))
        }
        if verb == "SET" || verb == "TEST" {
            guard let levels else { throw AppError.invalid("Missing motor levels.") }
            _ = try levels.validated(limits: VibrationLevels(255, 255, channels == 3 ? 255 : 0))
            if verb == "TEST", levels.values.filter({ $0 > 0 }).count != 1 { throw AppError.invalid("Test exactly one motor at a time.") }
            fields += levels.values.prefix(channels).map(String.init)
        }
        return Data((fields.joined(separator: " ") + "\n").utf8)
    }
    public static func parse(_ line: String, expectedChannels: Int? = nil) throws -> USBReply {
        guard !line.isEmpty, line.utf8.count < maximumLineBytes,
              line.utf8.allSatisfy({ (32...126).contains($0) }) else { throw AppError.invalid("Malformed USB response.") }
        let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 3, f[0] == "PE1" else { throw AppError.invalid("Unsupported Arduino protocol; PE1 firmware is required.") }
        if f == ["PE1", "BOOT", "1"] { return .boot }
        guard validSession(f[2]) else { throw AppError.invalid("Invalid USB session identifier.") }
        func number(_ value: String, max: UInt32) throws -> UInt32 {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = UInt32(value), number <= max else { throw AppError.invalid("Invalid USB numeric field.") }
            return number
        }
        switch f[1] {
        case "READY":
            guard f.count >= 7, ["2", "3"].contains(f[3]), let channels = Int(f[3]),
                  (f.count == channels + 5 || (f.count == channels + 6 && f.last == "TEST250")),
                  f[channels + 4] == "1000" else { throw AppError.invalid("Board must provide two or three channels and a 1000 ms watchdog.") }
            let limits = VibrationLevels(Int(try number(f[4], max: 255)), Int(try number(f[5], max: 255)),
                                        channels == 3 ? Int(try number(f[6], max: 255)) : 0)
            _ = try VibrationLevels.zero.validated(limits: limits)
            guard channels == limits.channelCount else { throw AppError.invalid("Invalid channel limits.") }
            return .ready(session: f[2], limits: limits, discovery: f.last == "TEST250")
        case "ACK":
            guard [7, 8].contains(f.count), expectedChannels == nil || f.count == expectedChannels! + 5,
                  ["ARMED", "DISARMED"].contains(f[4]) else { throw AppError.invalid("Malformed USB acknowledgement.") }
            let sequence = try number(f[3], max: 2_147_483_647)
            guard sequence > 0 else { throw AppError.invalid("Invalid USB acknowledgement sequence.") }
            let levels = VibrationLevels(Int(try number(f[5], max: 255)), Int(try number(f[6], max: 255)),
                                        f.count == 8 ? Int(try number(f[7], max: 255)) : 0)
            guard f[4] == "ARMED" || levels == .zero else { throw AppError.invalid("Disarmed board reported nonzero output.") }
            return .ack(session: f[2], sequence: sequence, armed: f[4] == "ARMED", levels: levels)
        case "ERR":
            guard f.count == 5 else { throw AppError.invalid("Malformed USB error.") }
            return .error(session: f[2], sequence: try number(f[3], max: 2_147_483_647), code: f[4])
        case "FAULT":
            guard f.count == 4 else { throw AppError.invalid("Malformed USB fault.") }
            return .fault(session: f[2], code: f[3])
        default: throw AppError.invalid("Unknown USB response.")
        }
    }
}

public struct USBLineBuffer: Sendable {
    private var bytes = Data()
    public init() {}
    public mutating func append(_ input: Data) throws -> [String] {
        var lines: [String] = []
        for byte in input {
            if byte == 10 {
                if bytes.last == 13 { bytes.removeLast() }
                guard let line = String(data: bytes, encoding: .ascii), !line.isEmpty else { throw AppError.invalid("Invalid USB line encoding.") }
                lines.append(line); bytes.removeAll(keepingCapacity: true)
            } else {
                guard bytes.count < USBWire.maximumLineBytes-1 else { bytes.removeAll(); throw AppError.invalid("USB response exceeds 128 bytes.") }
                bytes.append(byte)
            }
        }
        return lines
    }
}
