import AppKit
import PerifitCore

// Uses the production serial transport, without touching app preferences or BLE.
@main
struct MacProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            let usb = ArduinoUSB()
            do {
                guard CommandLine.arguments.count == 3,
                      ["--locked", "--unpowered-bench", "--full-range-check", "--test-only-check", "--live-test"].contains(CommandLine.arguments[2]) else {
                    throw AppError.invalid("Usage: MacProbe PORT --locked|--unpowered-bench|--full-range-check|--test-only-check|--live-test")
                }
                let mode = CommandLine.arguments[2]
                let locked = mode == "--locked"
                do { try await usb.connect(path: CommandLine.arguments[1]) }
                catch {
                    guard locked && usb.status.contains("NOT_CONFIGURED") else { throw error }
                    print("PASS Perifit Edge production client rejects the uncommissioned board: \(usb.status)")
                    exit(0)
                }
                if mode == "--test-only-check" || mode == "--live-test" {
                    guard usb.ready, usb.supportsDiscovery, usb.reported == .zero,
                          mode == "--test-only-check" || usb.limits.values.prefix(usb.limits.channelCount).allSatisfy({ (1...16).contains($0) }) else {
                        throw AppError.invalid("Live console requires caps no higher than 16 PWM; use the dashboard for manual levels")
                    }
                    if mode == "--test-only-check" {
                        do { try await usb.arm() }
                        catch {
                            guard usb.status.contains("TEST_ONLY") else { throw error }
                            print("PASS real Uno test-only build refuses normal arming; no motor pulse requested")
                            exit(0)
                        }
                        throw AppError.invalid("Test-only firmware incorrectly allowed ARM")
                    }
                    var lastOff = 0.0
                    print("READY: USB connected, all channels OFF. Motor power must remain disconnected until the operator is ready.")
                    print("Type a motor number 1–\(usb.limits.channelCount) for one 250 ms pulse at its advertised cap. q closes USB. Observe each pulse before requesting another.")
                    fflush(stdout)
                    while let input = await Task.detached(operation: { readLine() }).value {
                        if input == "q" { break }
                        guard let motor = Int(input), (1...usb.limits.channelCount).contains(motor) else { continue }
                        guard ProcessInfo.processInfo.systemUptime - lastOff >= 2 else {
                            print("Wait at least two seconds OFF between pulses."); fflush(stdout); continue
                        }
                        let pwm = usb.limits[motor - 1]
                        var levels = VibrationLevels.zero; levels[motor - 1] = pwm
                        try await usb.testPulse(levels)
                        guard usb.reported == .zero, !usb.boardArmed else { throw AppError.invalid("Pulse OFF not acknowledged") }
                        lastOff = ProcessInfo.processInfo.systemUptime
                        print("M\(input): one 250 ms pulse at \(pwm)/255 completed; board acknowledges all outputs OFF. Waiting for observation.")
                        fflush(stdout)
                    }
                    try await usb.stop()
                    usb.disconnect()
                    print("STOP acknowledged; USB closed.")
                    exit(0)
                }
                let fullRange = mode == "--full-range-check"
                guard !locked, usb.ready, usb.supportsDiscovery,
                      usb.limits == (fullRange ? VibrationLevels(255, 255, 255) : VibrationLevels(200, 180, 160)), usb.reported == .zero else {
                    throw AppError.invalid("Unexpected board readiness or limits")
                }
                try await usb.arm()
                let pairs: [VibrationLevels] = fullRange ? [VibrationLevels(255, 0, 0), VibrationLevels(0, 255, 0), VibrationLevels(0, 0, 255), .zero] : [VibrationLevels(8, 16, 24), VibrationLevels(0, 16, 24), VibrationLevels(0, 0, 24), .zero]
                for pair in pairs {
                    for _ in 0..<(fullRange ? 24 : 4) {
                        try usb.drive(pair)
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    guard usb.reported == pair else { throw AppError.invalid("Independent pair was not acknowledged") }
                }
                try await usb.stop()
                guard usb.reported == .zero, !usb.boardArmed else { throw AppError.invalid("STOP failed") }
                for pair in [VibrationLevels(8, 0, 0), VibrationLevels(0, 8, 0), VibrationLevels(0, 0, 8)] {
                    try await usb.testPulse(pair)
                    guard usb.reported == .zero, !usb.boardArmed else { throw AppError.invalid("TEST250 failed") }
                }
                usb.disconnect()
                print("PASS Perifit Edge production client: real Uno handshake, ARM, independent channels, zero, STOP and all three TEST250 pulses")
                if fullRange { print("PASS full 0–255 on each channel held beyond 1 second with heartbeats; motor power disconnected") }
                exit(0)
            } catch {
                usb.disconnect()
                fputs("FAIL Mac/Uno: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }
}
