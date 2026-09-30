import Foundation
import Combine
import PerifitCore

/// Explicitly enabled, bounded capture. No pressure samples, marks, or HA credentials.
@MainActor final class USBDebugLog: ObservableObject {
    struct Context: Codable, Equatable, Sendable {
        var selectedPort: String
        var connectedPort: String
        var ready: Bool
        var boardLimits: VibrationLevels
        var savedCalibration: MotorCalibration?
        var appliedCalibration: MotorCalibration?
        var vibration: VibrationSettings
        var output: String

        var warnings: [String] {
            guard let saved = savedCalibration else { return [] }
            return Array(zip(saved.minimums.values, saved.maximums.values).prefix(saved.boardLimits.channelCount))
                .enumerated().compactMap { index, range in
                    range.0 == range.1 ? "M\(index + 1) saved minimum and maximum are both \(range.0) PWM. When this calibration applies, every nonzero command is clamped to that value by the Mac. Retest lower discovery levels if this starting floor was recorded incorrectly; do not infer a firmware fault from this alone." : nil
                }
        }
    }
    struct Entry: Codable, Sendable {
        var seconds: Double
        var kind: String
        var detail: String
        var bytesBase64: String?
    }
    @Published private(set) var enabled = false
    @Published private(set) var status = "Debug logging is off."
    private(set) var entries: [Entry] = []
    private var startedAt: Date?
    private var startedUptime = 0.0
    private var byteCount = 0
    private var lastContext: Context?
    var hasCapture: Bool { startedAt != nil }
    // ponytail: finite capture stops at either bound; export and start again for longer investigations.
    static let maximumEntries = 20_000
    static let maximumBytes = 8 * 1024 * 1024

    func setEnabled(_ value: Bool, context: Context) {
        guard value != enabled else { return }
        if value {
            entries = []; byteCount = 0; lastContext = nil
            startedAt = Date(); startedUptime = ProcessInfo.processInfo.systemUptime
            enabled = true
            status = "Recording USB debug log in memory. Export before quitting."
            record("capture", "Started a new capture.")
            recordContext(context)
        } else {
            record("capture", "Capture stopped by user.")
            enabled = false; status = "Capture stopped; ready to export."
        }
    }

    func record(_ kind: String, _ detail: String, bytes: Data? = nil) {
        guard enabled else { return }
        let entry = Entry(seconds: ProcessInfo.processInfo.systemUptime - startedUptime,
                          kind: kind, detail: String(detail.prefix(8192)), bytesBase64: bytes?.base64EncodedString())
        let size = entry.detail.utf8.count + (entry.bytesBase64?.utf8.count ?? 0) + 128
        guard entries.count < Self.maximumEntries - 1, byteCount + size < Self.maximumBytes else {
            entries.append(Entry(seconds: entry.seconds, kind: "capture", detail: "Capture limit reached; later events are not recorded.", bytesBase64: nil))
            enabled = false; status = "Capture limit reached. Export this capture before starting another."
            return
        }
        entries.append(entry); byteCount += size
    }

    func wire(_ direction: String, _ bytes: Data) {
        guard enabled else { return }
        record(direction, String(decoding: bytes, as: UTF8.self), bytes: bytes)
    }

    func recordContext(_ context: Context) {
        guard enabled, context != lastContext else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(context) {
            record("context", String(decoding: data, as: UTF8.self)); lastContext = context
        }
    }

    func export(to parent: URL, context: Context) async throws -> URL {
        guard let startedAt else { throw AppError.invalid("Enable debug logging and reproduce the issue first.") }
        recordContext(context)
        let captured = entries, wasRecording = enabled
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let documents = ["USB_PROTOCOL", "ARDUINO_HANDOFF"].compactMap { Bundle.main.url(forResource: $0, withExtension: "md") }
        return try await Task.detached(priority: .utility) {
            let directory = parent.appendingPathComponent("Arduino-debug-" + UUID().uuidString, isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            func write(_ data: Data, _ name: String) throws {
                let file = directory.appendingPathComponent(name)
                try data.write(to: file, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                var trace = Data()
                for entry in captured { trace.append(try encoder.encode(entry)); trace.append(10) }
                try write(trace, "trace.jsonl")
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try write(try encoder.encode(context), "context.json")
                for document in documents { try write(Data(contentsOf: document), document.lastPathComponent) }
                let timestamp = ISO8601DateFormatter().string(from: startedAt)
                let handoff = """
                # Arduino firmware debugging handoff

                Investigate the attached Perifit Edge USB capture and fix the demonstrated cause in the Mac app or Arduino firmware. First compare Mac requests, actual transmitted SET channel levels, and the Arduino ACK channel levels. Do not assume the firmware caused a constant output.

                App: \(version) (\(build)); \(system).
                Capture began: \(timestamp). Exported events: \(captured.count). Recording at export: \(wasRecording).
                Hardware supplied by user: Arduino Uno REV3, HiLetgo L293D v1 motor shield, JETT motors originally on M1/M2; M3 motor identity is user-supplied, originally powered by four AA cells (user ceiling 6.2 V). Actual wiring and firmware revision are not automatically identified; verify them.

                ## Evidence
                - `trace.jsonl`: ordered events; seconds are monotonic offsets from capture start. TX means bytes accepted by the Mac serial write, not proof of motor movement. RX contains raw bytes before parsing. `bytesBase64` preserves exact bytes; chunks may split or combine protocol lines. Reassemble TX and RX independently within each connection. Emergency writes use the same TX format.
                - `request` is the Mac's desired raw PWM pair; `context` events record changes to targets, modes, timing, caps and calibration. `context.json` is the current context at export and can differ from the final trace event when logging is stopped.
                - `fault`, `connect`, `close`, and `reconnect` describe transport failures and retries. A limit event means the trace is truncated. An initial ARM/HELLO may be absent if logging began after connection.
                - No pressure readings, feedback marks, credentials, or learning history are included. Serial port identifiers, timing, and motor settings are included. Review before sharing.

                ## Calibration observations
                \(context.warnings.isEmpty ? "No saved channel has an equal minimum and maximum." : context.warnings.joined(separator: "\n"))
                A positive output is floored to the applicable discovered minimum. Target percent is relative to the saved maximum (or advertised board cap without matching calibration). Pattern levels are percentages of that target. Zero remains OFF. Check the context events at the failure, not only the export snapshot.

                ## Work to do
                1. Ask the user to describe the physical symptom and roughly when it happened if the capture does not make that clear. Identify the first divergence between target/settings, TX, ACK, and observed hardware.
                2. Inspect `Sources/PerifitApp/ArduinoUSB.swift`, `Sources/PerifitCore/Vibration.swift`, and `Firmware/PerifitEdgeUno/` in the app repository. Follow `USB_PROTOCOL.md` and `ARDUINO_HANDOFF.md` (bundled here in release exports).
                3. Preserve independent M1/M2/M3 targets and timing, shared cutoff, STOP, sequence/nonce checks, and zero/disarmed reconnect. PE1 is 115200 8N1 ASCII; Mac streams raw SET channel levels at 10 Hz; firmware watchdog is 1000 ms and TEST is one 250 ms pulse. Do not add debug prints to the PE1 serial stream. ACK must report applied PWM, not measured motor speed or current.
                4. Make the smallest correction and add a regression to `Tools/check_usb.py` / `Tools/USBProbe.swift` or `Firmware/Checks.cpp`. Use emulated hardware first. Document changes and validation; confirm electrical/pin details before any firmware flash or powered test.
                """
                try write(Data(handoff.utf8), "HANDOFF.md")
                return directory
            } catch {
                try? fm.removeItem(at: directory) // Only this newly created, incomplete export.
                throw error
            }
        }.value
    }
}
