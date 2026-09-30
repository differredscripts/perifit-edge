import AppKit
import Combine
import Darwin
import PerifitCore

private final class TestClock {
    private let lock = NSLock()
    private var stored = 0.0
    var value: Double {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class TestWrites {
    private let lock = NSLock()
    private var armed = false, partial = false, blocked = false, releaseAt = 0.0
    func block() { lock.lock(); blocked = true; lock.unlock() }
    func unblock() { lock.lock(); blocked = false; lock.unlock() }
    func armPartial() { lock.lock(); armed = true; partial = false; lock.unlock() }
    var didSplit: Bool { lock.lock(); defer { lock.unlock() }; return partial }
    func write(_ fd: Int32, _ data: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        let now = USBSerialWorker.continuousSeconds()
        if blocked || now < releaseAt { errno = EAGAIN; return -1 }
        var bytes = data
        if armed && data.starts(with: Data("PE1 SET ".utf8)) {
            armed = false; partial = true; releaseAt = now + 0.060
            bytes = Data(data.prefix(12))
        } else { bytes = Data(data.prefix(11)) } // Exercise ordinary partial writes too.
        return bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    }
}

@main
struct WatchdogProbe {
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw AppError.invalid(message) }
    }
    @MainActor static func wait(_ message: String, usb: ArduinoUSB? = nil, seconds: Double = 4,
                               _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            usb?.tickForTesting()
            if condition() { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AppError.invalid(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func state() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) as! [String: Any]
    }
    static func zero() -> Bool { (try? state()["levels"] as? [Int]) == [0, 0] }
    static func control(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
    }
    @MainActor static func connect(_ usb: ArduinoUSB) async throws {
        let task = Task { try await usb.connect(path: CommandLine.arguments[1]) }
        try await wait("Connect failed", usb: usb) { usb.ready }
        try await task.value
    }
    @MainActor static func arm(_ usb: ArduinoUSB) async throws {
        let task = Task { try await usb.arm() }
        try await wait("ARM failed", usb: usb) { usb.boardArmed }
        try await task.value
    }
    @MainActor static func close(_ usb: ArduinoUSB) async throws {
        usb.disconnect()
        try await wait("Disconnect did not finish", usb: usb) { !usb.snapshotForTesting().connected }
    }

    @MainActor static func perform(_ operation: USBSerialWorker.Operation, worker: USBSerialWorker, epoch: UUID) async throws {
        let pump = Task { @MainActor in
            while !Task.isCancelled {
                worker.tickForTesting()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { pump.cancel() }
        let _: USBSerialWorker.Snapshot = try await withCheckedThrowingContinuation { continuation in
            worker.perform(operation, epoch: epoch) { continuation.resume(with: $0) }
        }
    }
    @MainActor static func mailboxChecks() async throws {
        let clock = TestClock(), writes = TestWrites(), epoch = UUID()
        var io = USBSerialWorker.IO()
        io.now = { clock.value }; io.write = { writes.write($0, $1) }; io.automaticTimer = false
        let worker = USBSerialWorker(io: io) {}
        worker.invalidate(epoch)
        try await perform(.connect(CommandLine.arguments[1], true), worker: worker, epoch: epoch)
        try await perform(.arm, worker: worker, epoch: epoch)
        clock.value = 0.1
        worker.submit(VibrationLevels(20, 30), at: clock.value, epoch: epoch, zeros: 0)
        try await wait("Mailbox fixture did not establish output") {
            worker.tickForTesting()
            return (try? state()["levels"] as? [Int]) == [20, 30]
        }
        let before = try (state()["commands"] as! [String]).count
        writes.block()
        clock.value = 0.2
        worker.submit(VibrationLevels(0, 30), at: clock.value, epoch: epoch, zeros: 1)
        worker.tickForTesting()
        clock.value = 0.3
        worker.submit(VibrationLevels(20, 0), at: clock.value, epoch: epoch, zeros: 2)
        worker.tickForTesting()
        clock.value = 0.5
        worker.submit(VibrationLevels(20, 30), at: clock.value, epoch: epoch, zeros: 0)
        worker.tickForTesting(); writes.unblock()
        try await wait("Queued zero transitions were lost", seconds: 0.3) {
            worker.tickForTesting()
            let commands = (try? state()["commands"] as? [String]) ?? []
            let pairs = commands.dropFirst(before).filter { $0.hasPrefix("PE1 SET ") }
                .map { $0.split(separator: " ").suffix(2).joined(separator: " ") }
            return pairs == ["0 30", "20 0", "20 30"]
        }
        // An update produced before expiry but consumed afterward must not
        // revive the lease, even if the worker serviced it just before expiry.
        clock.value = 1.199; worker.tickForTesting()
        clock.value = 1.2
        worker.submit(VibrationLevels(99, 99), at: 1.199, epoch: epoch, zeros: 0)
        worker.tickForTesting()
        try require(!worker.snapshotForTesting().active, "Queued update revived an expired controller lease")
        try await wait("Mailbox expiry did not close") {
            worker.tickForTesting(); return !worker.snapshotForTesting().connected
        }
        try await wait("Mailbox expiry did not zero the peer", seconds: 0.2) { zero() }
        print("PASS queued urgent zeros stay ordered; delayed production timestamp cannot revive an expired lease")
        clock.value = 2
        try await perform(.connect(CommandLine.arguments[1], true), worker: worker, epoch: epoch)
        try await perform(.arm, worker: worker, epoch: epoch)
        clock.value = 2.701
        worker.submit(VibrationLevels(99, 99), at: clock.value, epoch: epoch, zeros: 0)
        worker.tickForTesting()
        try require(!worker.snapshotForTesting().active, "Fresh update rescued a prolonged worker stall")
        try await wait("Worker stall did not close") {
            worker.tickForTesting(); return !worker.snapshotForTesting().connected
        }
        print("PASS prolonged worker stall rejects even a newly produced controller update")
    }
    @MainActor static func pressureSafetyChecks() async throws {
        try control([:]); try await Task.sleep(for: .milliseconds(50))
        let usb = ArduinoUSB(allowPseudoTerminal: true)
        try await connect(usb); try await arm(usb)
        func context(_ permitted: Bool, ack: UUID? = nil) throws -> PressureSafetyContext {
            try PressureSafetyContext(baseline: 1000, gain: 1, score: 680, peakTrough: 0, cutoff: 760,
                permitted: permitted, peakGuardEnabled: true, time: ProcessInfo.processInfo.systemUptime, acknowledgedPause: ack)
        }
        usb.updatePressureSafety(try context(true))
        let tap = PressureSafetyTap(), peripheral = UUID()
        tap.bind(peripheral: peripheral, service: "service", characteristic: "pressure", sink: usb.pressureSafetySink())
        tap.receive(Data([3, 232, 2, 188]), peripheral: peripheral, service: "service", characteristic: "pressure", time: ProcessInfo.processInfo.systemUptime)
        try usb.drive(VibrationLevels(20, 30))
        try await wait("Safe pressure did not permit output", usb: usb) { usb.reported == VibrationLevels(20, 30) }
        tap.receive(Data([0, 0, 0, 0]), peripheral: UUID(), service: "service", characteristic: "pressure", time: ProcessInfo.processInfo.systemUptime)
        let before = try state()["updatedAt"] as! Double
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            tap.receive(Data([4, 176, 2, 188]), peripheral: peripheral, service: "service", characteristic: "pressure", time: ProcessInfo.processInfo.systemUptime)
        }
        try usb.drive(VibrationLevels(20, 30))
        usleep(450_000)
        let paused = try state()
        try require(zero() && (paused["lastOff"] as! Double) - before < 0.4, "Pressure safety waited for the blocked UI")
        guard let pause = usb.pressureSafetyPause else { throw AppError.invalid("Missing pressure safety pause") }
        try require(pause.kind == .pendingPeak, "Unexpected pressure safety cause")
        try usb.drive(VibrationLevels(20, 30))
        usb.updatePressureSafety(try context(false, ack: pause.id))
        tap.receive(Data([3, 232, 2, 188]), peripheral: peripheral, service: "service", characteristic: "pressure", time: ProcessInfo.processInfo.systemUptime)
        try await Task.sleep(for: .milliseconds(50))
        try require(zero(), "A fresh ON command bypassed the pressure safety hold")
        usb.updatePressureSafety(try context(true, ack: pause.id))
        try usb.drive(VibrationLevels(20, 30))
        try await wait("Acknowledged quiet cooldown did not release hold", usb: usb) { usb.reported == VibrationLevels(20, 30) }
        let sink = usb.pressureSafetySink()
        DispatchQueue.global().async {
            for _ in 0..<12 {
                sink(PressureSample(base: 1000, tip: 700, time: ProcessInfo.processInfo.systemUptime), nil)
                usleep(80_000)
            }
        }
        try usb.drive(VibrationLevels(20, 30))
        usleep(850_000)
        try require(zero(), "Pressure packets improperly renewed the controller lease")
        try await wait("Expired controller did not disarm", usb: usb) { !usb.connected }
        tap.clear()
        print("PASS independent pending-peak STOP during blocked UI, source identity, held ON rejection, release, pressure cannot renew controller lease")
    }
    @MainActor static func checks() async throws {
        try await pressureSafetyChecks()
        try control([:]); try await Task.sleep(for: .milliseconds(50))
        let telemetry = ArduinoUSB(allowPseudoTerminal: true)
        try await connect(telemetry); try await arm(telemetry)
        var redraws = 0, reports = 0
        let subscription = telemetry.objectWillChange.sink { redraws += 1 }
        telemetry.onReported = { _ in reports += 1 }
        for index in 0..<100 {
            let levels = VibrationLevels(20 + index % 30, 60)
            try telemetry.drive(levels)
            try require(telemetry.requested == levels, "UI throttling delayed the requested motor values")
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(redraws < 35 && reports >= 10 && telemetry.connected && telemetry.boardArmed,
                    "Telemetry redraws were not bounded, or control/report delivery was slowed")
        telemetry.zeroNow()
        try require(telemetry.requested == .zero, "UI throttling delayed immediate OFF")
        try await telemetry.stop(); try await close(telemetry)
        subscription.cancel()
        print("PASS telemetry redraw throttling with immediate commands, exact values and unchanged OFF")
        try await mailboxChecks()
        // Exact freshness boundary with the same worker and a controllable clock.
        let clock = TestClock()
        var io = USBSerialWorker.IO(); io.now = { clock.value }; io.automaticTimer = false
        let timed = ArduinoUSB(allowPseudoTerminal: true, io: io)
        try await connect(timed); try await arm(timed)
        clock.value = 0.3; try timed.drive(VibrationLevels(8, 16))
        try await wait("Timed SET failed", usb: timed) { timed.reported == VibrationLevels(8, 16) }
        clock.value = 0.999; timed.tickForTesting()
        try require(timed.snapshotForTesting().active, "Freshness expired before 700 ms")
        clock.value = 1.0; timed.tickForTesting()
        try require(!timed.snapshotForTesting().active, "Freshness survived the 700 ms boundary")
        try await wait("Freshness shutdown did not close", usb: timed) { !timed.connected }
        try await wait("Freshness fault did not zero the peer", seconds: 0.2) { zero() }
        print("PASS exact 700 ms freshness boundary; stale control cannot rescue a consumed lease")

        // ACK boundary while fresh source timestamps continue arriving.
        let ackClock = TestClock()
        io.now = { ackClock.value }
        let ack = ArduinoUSB(allowPseudoTerminal: true, io: io)
        try await connect(ack); try await arm(ack)
        try await Task.sleep(for: .milliseconds(50)); ack.tickForTesting()
        try control(["drop_ack": true]); try await Task.sleep(for: .milliseconds(50))
        for value in [0.1, 0.4, 0.7, 0.999] {
            ackClock.value = value; try ack.drive(VibrationLevels(8, 16)); ack.tickForTesting()
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(ack.snapshotForTesting().active, "ACK deadline expired before 900 ms")
        ackClock.value = 1.0; ack.tickForTesting()
        try require(ack.snapshotForTesting().stopping, "ACK survived the 900 ms boundary")
        ackClock.value = 1.901; ack.tickForTesting()
        try require(!ack.snapshotForTesting().connected && ack.reported == nil, "Unacknowledged STOP claimed OFF")
        print("PASS exact 900 ms ACK deadline and bounded STOP acknowledgement failure")

        try control(["ack_delay": 0.85]); try await Task.sleep(for: .milliseconds(50))
        let delayed = ArduinoUSB(allowPseudoTerminal: true)
        try await connect(delayed); try await arm(delayed) // ARM itself may take 850 ms.
        for index in 0..<50 {
            try delayed.drive(index % 2 == 0 ? VibrationLevels(0, 30) : VibrationLevels(20, 0))
            try await Task.sleep(for: .milliseconds(50))
            try require(delayed.connected && delayed.boardArmed, "850 ms ACKs overflowed or faulted a fresh controller")
        }
        try await delayed.stop(); try await close(delayed)
        print("PASS 850 ms ACKs with >8 in-flight commands; ARM lease starts on acknowledged zero")

        try control([:]); try await Task.sleep(for: .milliseconds(50))
        let stalledUI = ArduinoUSB(allowPseudoTerminal: true)
        try await connect(stalledUI); try await arm(stalledUI)
        try stalledUI.drive(VibrationLevels(20, 30))
        try await wait("SET failed before UI stall") { stalledUI.reported == VibrationLevels(20, 30) }
        try stalledUI.drive(VibrationLevels(20, 30)) // Fresh source timestamp at the start of the deliberate stall.
        usleep(600_000)
        try require(!zero(), "600 ms UI stall stopped a fresh lease early")
        try stalledUI.drive(VibrationLevels(20, 30))
        try await Task.sleep(for: .milliseconds(80))
        try require(stalledUI.connected, "Brief UI stall faulted")
        let before = try state()["updatedAt"] as! Double
        usleep(800_000)
        let during = try state()
        try require(zero(), "Worker did not stop before MainActor resumed")
        try require((during["lastOff"] as! Double) - before <= 0.800, "Worker exceeded controlled 800 ms stop bound")
        usleep(400_000)
        try await wait("UI stall fault did not finish") { !stalledUI.connected }
        print("PASS 600 ms UI stall tolerated; >700 ms stall stops during a 1.2 s blocked MainActor")

        let writes = TestWrites()
        var partialIO = USBSerialWorker.IO(); partialIO.write = { writes.write($0, $1) }
        let partial = ArduinoUSB(allowPseudoTerminal: true, io: partialIO)
        try await connect(partial); try await arm(partial)
        writes.armPartial(); try partial.drive(VibrationLevels(44, 55))
        try await wait("Partial SET was not injected") { writes.didSplit }
        try partial.drive(VibrationLevels(66, 77)) // Superseded before its first byte.
        partial.prepareStop(); try await partial.stop()
        try require(partial.reported == .zero && !partial.boardArmed, "Partial-write STOP did not confirm OFF")
        var rejected = false
        do { try partial.drive(VibrationLevels(99, 99)) } catch { rejected = true }
        try require(rejected, "Stopped generation accepted stale output")
        try await close(partial)
        print("PASS partial writes/EAGAIN, immediate Stop, coalesced Stop waiters and stale-generation rejection")

        let blockedWrites = TestWrites()
        partialIO.write = { blockedWrites.write($0, $1) }
        let blocked = ArduinoUSB(allowPseudoTerminal: true, io: partialIO)
        try await connect(blocked); try await arm(blocked)
        try blocked.drive(VibrationLevels(20, 30))
        try await wait("Blocked-write precondition failed") { blocked.reported == VibrationLevels(20, 30) }
        blockedWrites.block()
        let started = ProcessInfo.processInfo.systemUptime
        rejected = false
        do { try await blocked.stop() } catch { rejected = true }
        try require(rejected && !blocked.connected && blocked.reported == nil, "Blocked STOP did not close as unknown")
        try require(ProcessInfo.processInfo.systemUptime - started < 0.250, "STOP write retries exceeded their 100 ms budget")
        try await wait("Peer deadman did not back up failed STOP", seconds: 2) { zero() }
        print("PASS 100 ms STOP write budget and independent device deadman fallback")

        let cancelled = ArduinoUSB(allowPseudoTerminal: true)
        try await connect(cancelled)
        let pulse = Task { try await cancelled.testPulse(VibrationLevels(8, 0)) }
        try await wait("Cancellation pulse did not start") { !zero() }
        cancelled.prepareStop(); try await cancelled.stop()
        rejected = false
        do { try await pulse.value } catch { rejected = true }
        try require(rejected && cancelled.reported == .zero, "TEST waiter was not cancelled exactly once")
        try control(["ack_delay": 0.2, "delay_verbs": ["ARM"]])
        try await Task.sleep(for: .milliseconds(50))
        let armsBefore = (try state()["commands"] as! [String]).filter { $0.hasPrefix("PE1 ARM ") }.count
        let oldArm = Task { try await cancelled.arm() }
        try await wait("ARM was not in flight before cancellation") {
            ((try? state()["commands"] as? [String]) ?? []).filter { $0.hasPrefix("PE1 ARM ") }.count > armsBefore
        }
        cancelled.prepareStop(); try await cancelled.stop()
        rejected = false
        do { try await oldArm.value } catch { rejected = true }
        try await Task.sleep(for: .milliseconds(300))
        try require(rejected && !cancelled.boardArmed && zero(), "Late ARM ACK revived a stopped generation")
        try await close(cancelled)
        print("PASS TEST/ARM cancellation and late-reply handling")

        for fault in ["bad_frame", "flood"] {
            try control([:]); try await Task.sleep(for: .milliseconds(50))
            let malformed = ArduinoUSB(allowPseudoTerminal: true)
            try await connect(malformed); try await arm(malformed)
            try malformed.drive(VibrationLevels(20, 30))
            try await wait("Malformed-input precondition failed") { malformed.reported == VibrationLevels(20, 30) }
            try control([fault: true])
            try await wait("Malformed/flooded input did not close") { !malformed.connected }
            try await wait("Malformed/flooded input did not fail off", seconds: 2) { zero() }
        }
        try control([:]); try await Task.sleep(for: .milliseconds(50))
        print("PASS malformed frames and bounded RX flood fail-off")

        let suspended = ArduinoUSB(allowPseudoTerminal: true)
        try await connect(suspended); try await arm(suspended)
        try suspended.drive(VibrationLevels(20, 30))
        try await wait("Host suspend precondition failed") { suspended.reported == VibrationLevels(20, 30) }
        try control(["pause_host": true, "ignore_stop": true])
        try await Task.sleep(for: .milliseconds(50))
        raise(SIGSTOP) // Python observes an actual stopped process, checks peer, then resumes us.
        try await wait("Resumed process replayed a stale lease") { !suspended.connected }
        try require(zero(), "Full process suspension did not leave the peer OFF")
        print("PASS full host process suspension, board-local deadman and no stale output after resume")
    }

    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await checks(); exit(0) }
            catch { fputs("Watchdog check failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        app.run()
    }
}
