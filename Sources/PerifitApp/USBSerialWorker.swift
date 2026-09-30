import Foundation
import Darwin
import PerifitCore

// Only this queue owns the descriptor and PE1 state. The two small locked
// mailboxes bound controller/UI work even when either executor is stalled.
final class USBSerialWorker: @unchecked Sendable {
    private static let clockOrigin = ContinuousClock.now
    static func continuousSeconds() -> Double {
        let elapsed = clockOrigin.duration(to: ContinuousClock.now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
    struct IO {
        var pressureNow: () -> Double = { ProcessInfo.processInfo.systemUptime }
        var now: () -> Double = { USBSerialWorker.continuousSeconds() }
        var write: (Int32, Data) -> Int = { fd, data in
            data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        }
        var automaticTimer = true // Private test seam; production always uses the timer.
    }
    struct Snapshot {
        var pressurePause: PressureSafetyEvent?
        var epoch = UUID(), revision: UInt64 = 0
        var connected = false, ready = false, discovery = false, armed = false
        var active = false, testing = false, stopping = false, pseudo = false
        var reported: VibrationLevels?, requested = VibrationLevels.zero
        var limits = VibrationLevels(255, 255)
        var port = "", status = "Not connected"
        var faultID: UUID?, fault: String?
    }
    struct Event { var kind: String; var text: String; var bytes: Data? = nil; var pressurePause: PressureSafetyEvent? = nil; var epoch: UUID? = nil }
    struct Failure: Error { let underlying: Error; let snapshot: Snapshot }
    enum Operation { case connect(String, Bool), arm, test(VibrationLevels), stop, disconnect }
    typealias Completion = (Result<Snapshot, Error>) -> Void
    private struct Control { var epoch: UUID; var at: Double; var levels: VibrationLevels }
    private struct Packet { var bytes: Data; var offset = 0; var sequence: UInt32?; var urgent = false }
    private struct Pending {
        var verb: String; var levels: VibrationLevels; var at: Double
        var completion: ((Result<Void, Error>) -> Void)?
    }

    private let queue = DispatchQueue(label: "PerifitEdge.USB", qos: .userInitiated)
    private let io: IO
    private let inputLock = NSLock(), deliveryLock = NSLock()
    private var acceptedEpoch = UUID(), control: Control?, zeroMask: UInt8 = 0, wakeScheduled = false
    private var incomingSafetyContext: (UUID, PressureSafetyContext)?
    private var incomingPressure: [(UUID, PressureSample)] = []
    private var incomingPressureFailure: (UUID, PressureSafetyEvent.Kind)?
    private var pressureSafety = PressureSafety()
    private var pressureEpoch: UUID?
    private var publishedPressurePause: (UUID, PressureSafetyEvent?)?
    private var delivery: Snapshot?, events: [Event] = [], deliveryScheduled = false
    private let notify: () -> Void
    private var state = Snapshot(), timer: DispatchSourceTimer?
    private var fd: Int32 = -1, linkID = UUID()
    private var buffer = USBLineBuffer(), session = ""
    private var sequence: UInt32 = 0, acknowledged: UInt32 = 0
    private var output: [Packet] = [], pending: [UInt32: Pending] = [:], cancelled: Set<UInt32> = []
    private var helloDeadline: Double?, helloAt = 0.0
    private var helloCompletion: ((Result<Void, Error>) -> Void)?
    private var controlAt: Double?, lastSet = 0.0
    private var servicedAt: Double?
    private var stopSequence: UInt32?, stopAt = 0.0, closeAfterStop = false, silentClose = false
    private var stopWaiters: [Completion] = [], faultReason: String?
    private var lastStopEpoch: UUID?
    private var now: Double { io.now() }

    init(io: IO = IO(), notify: @escaping () -> Void) { self.io = io; self.notify = notify }
    deinit { timer?.cancel(); if fd >= 0 { Darwin.close(fd) } }
    func time() -> Double { io.now() }

    func invalidate(_ epoch: UUID) {
        inputLock.lock(); acceptedEpoch = epoch; control = nil; zeroMask = 0
        incomingSafetyContext = nil; incomingPressure = []; incomingPressureFailure = nil
        inputLock.unlock()
    }
    func submitSafetyContext(_ context: PressureSafetyContext, epoch: UUID) {
        inputLock.lock()
        if epoch == acceptedEpoch { incomingSafetyContext = (epoch, context) }
        inputLock.unlock(); wakeForPressure()
    }
    func submitPressure(_ sample: PressureSample?, failure: PressureSafetyEvent.Kind? = nil, epoch: UUID) {
        inputLock.lock()
        if epoch == acceptedEpoch {
            if let failure { incomingPressureFailure = (epoch, failure) }
            else if let sample {
                if incomingPressure.count < 64 { incomingPressure.append((epoch, sample)) }
                else { incomingPressureFailure = (epoch, .invalidPressure) }
            }
        }
        inputLock.unlock(); wakeForPressure()
    }
    private func wakeForPressure() {
        inputLock.lock(); let wake = !wakeScheduled; wakeScheduled = true; inputLock.unlock()
        if wake { queue.async { [self] in
            inputLock.lock(); wakeScheduled = false; inputLock.unlock(); pump()
        } }
    }
    func pressurePause(epoch: UUID) -> PressureSafetyEvent? {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        guard publishedPressurePause?.0 == epoch else { return nil }
        return publishedPressurePause?.1
    }
    private func current(_ epoch: UUID) -> Bool {
        inputLock.lock(); defer { inputLock.unlock() }; return epoch == acceptedEpoch
    }
    func submit(_ levels: VibrationLevels, at: Double, epoch: UUID, zeros: UInt8) {
        inputLock.lock()
        guard epoch == acceptedEpoch else { inputLock.unlock(); return }
        control = Control(epoch: epoch, at: at, levels: levels); zeroMask |= zeros
        let wake = !wakeScheduled; wakeScheduled = true; inputLock.unlock()
        if wake {
            queue.async { [weak self] in
                guard let self else { return }
                inputLock.lock(); wakeScheduled = false; inputLock.unlock(); pump()
            }
        }
    }
    func takeDelivery() -> (Snapshot?, [Event]) {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        let result = (delivery, events)
        delivery = nil; events = []; deliveryScheduled = false
        return result
    }
    private func post(_ event: Event? = nil, snapshot: Bool = false) {
        if snapshot { state.revision &+= 1 }
        deliveryLock.lock()
        if snapshot { delivery = state }
        if let event {
            // ponytail: a 256-entry mailbox is enough between UI drains; drop
            // old wire detail rather than growing memory during a blocked UI.
            if events.count == 256 { events.removeFirst() }
            events.append(event)
        }
        let wake = !deliveryScheduled; deliveryScheduled = true; deliveryLock.unlock()
        if wake { notify() }
    }
    private func publish() { post(snapshot: true) }
    private func complete(_ callback: Completion, _ result: Result<Void, Error>) {
        publish(); callback(result.map { state })
    }

    func perform(_ operation: Operation, epoch: UUID, completion callback: @escaping Completion) {
        queue.async { [self] in
            let completion: Completion = { [self] result in
                callback(result.mapError { Failure(underlying: $0, snapshot: state) })
            }
            guard current(epoch) else { completion(.failure(CancellationError())); return }
            state.epoch = epoch
            switch operation {
            case .connect(let path, let allowPseudo):
                let open: Completion = { [self] _ in
                    guard current(epoch) else { completion(.failure(CancellationError())); return }
                    do { try openPort(path, allowPseudo: allowPseudo); hello { [self] result in complete(completion, result) } }
                    catch { closePort(error); complete(completion, .failure(error)) }
                }
                if fd >= 0 { beginStop(close: true, completion: open) } else { open(.success(state)) }
            case .arm, .test:
                guard state.ready, state.reported == .zero, !state.armed, !state.stopping,
                      !state.testing, !state.active, helloDeadline == nil, pending.isEmpty else {
                    completion(.failure(AppError.invalid("Connect the Arduino with all channels OFF before arming or testing."))); return
                }
                let levels: VibrationLevels?
                if case .test(let pair) = operation {
                    guard state.discovery else { completion(.failure(AppError.invalid("TEST250 firmware required."))); return }
                    do { _ = try pair.validated(limits: state.limits); _ = try USBWire.command("TEST", session: session, sequence: 1, levels: pair, channels: state.limits.channelCount) }
                    catch { completion(.failure(error)); return }
                    levels = pair; state.testing = true
                } else { levels = nil }
                hello { [self] result in
                    guard current(epoch) else { completion(.failure(CancellationError())); return }
                    if case .failure(let error) = result { completion(.failure(error)); return }
                    do {
                        if let levels { _ = try levels.validated(limits: state.limits) }
                        state.requested = levels ?? .zero
                        if levels != nil { state.reported = nil }
                        state.status = levels == nil ? "Arming at zero…" : "Testing one motor · Arduino cutoff 250 ms"
                        try enqueue(levels == nil ? "ARM" : "TEST", levels: levels ?? .zero) { [self] result in
                            guard current(epoch) else { completion(.failure(CancellationError())); return }
                            if case .success = result {
                                if levels == nil {
                                    state.active = true; controlAt = now; lastSet = now - 0.1
                                    state.status = "Armed · awaiting channel targets"
                                } else {
                                    state.testing = false; state.requested = .zero
                                    state.status = "Test complete · all channels OFF"
                                }
                            }
                            complete(completion, result)
                        }
                        publish(); pump()
                    } catch { completion(.failure(error)); fail(error.localizedDescription) }
                }
            case .stop:
                if !state.stopping && lastStopEpoch == epoch && state.reported == .zero && !state.armed {
                    complete(completion, .success(()))
                } else { beginStop(close: false, completion: completion) }
            case .disconnect: beginStop(close: true, completion: completion)
            }
        }
    }

    private func openPort(_ path: String, allowPseudo: Bool) throws {
        let physical = path.range(of: #"^/dev/cu\.[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
        let pseudo = allowPseudo && path.range(of: #"^/dev/ttys[0-9]+$"#, options: .regularExpression) != nil
        guard physical || pseudo else { throw AppError.invalid("Select a /dev/cu.* USB serial port.") }
        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard handle >= 0 else { throw AppError.invalid("Cannot open Arduino USB port.") }
        var options = termios()
        guard isatty(handle) == 1, tcgetattr(handle, &options) == 0 else { Darwin.close(handle); throw AppError.invalid("Selected path is not a serial terminal.") }
        guard ioctl(handle, UInt(TIOCEXCL), 0) == 0 else { Darwin.close(handle); throw AppError.invalid("Serial port is busy. Close other serial apps.") }
        cfmakeraw(&options); options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CSIZE | CRTSCTS); options.c_cflag |= tcflag_t(CS8)
        cfsetispeed(&options, speed_t(B115200)); cfsetospeed(&options, speed_t(B115200))
        guard tcsetattr(handle, TCSANOW, &options) == 0 else {
            _ = ioctl(handle, UInt(TIOCNXCL), 0); Darwin.close(handle); throw AppError.invalid("Cannot configure 115200-baud 8N1 serial.")
        }
        tcflush(handle, TCIOFLUSH)
        fd = handle; linkID = UUID(); state.port = path; state.pseudo = pseudo
        servicedAt = now
        state.connected = true; state.faultID = nil; state.fault = nil; faultReason = nil
        state.status = "Waiting for PE1 firmware (Uno may reset on USB open)…"
        post(Event(kind: "connect", text: "Opening \(path) at 115200 baud"))
        if io.automaticTimer {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
            source.setEventHandler { [weak self] in self?.pump() }; timer = source; source.resume()
        }
    }
    private func hello(_ completion: @escaping (Result<Void, Error>) -> Void) {
        state.ready = false; state.reported = nil; state.requested = .zero; state.armed = false
        session = USBWire.newSession(); sequence = 0; acknowledged = 0; cancelled = []
        buffer = USBLineBuffer(); output = []; pending = [:]
        helloDeadline = now + 5; helloAt = now - 0.5; helloCompletion = completion
        publish(); sendHello(); flush()
    }
    private func sendHello() {
        guard output.isEmpty, !state.stopping, current(state.epoch) else { return }
        output.append(Packet(bytes: try! USBWire.command("HELLO", session: session)))
        helloAt = now
    }
    private func enqueue(_ verb: String, levels: VibrationLevels = .zero, urgent: Bool = false,
                         completion: ((Result<Void, Error>) -> Void)? = nil) throws {
        if verb == "SET", !urgent,
           let index = output.firstIndex(where: { $0.offset == 0 && !$0.urgent && $0.sequence.flatMap { pending[$0]?.verb } == "SET" }),
           let seq = output[index].sequence {
            // Replace only wholly unsent data. Keep its original ACK deadline.
            output[index].bytes = try USBWire.command("SET", session: session, sequence: seq, levels: levels, channels: state.limits.channelCount)
            pending[seq]?.levels = levels; return
        }
        guard fd >= 0, pending.count < (verb == "STOP" ? 64 : 63), sequence < 2_147_483_647 else {
            throw AppError.invalid("USB command backlog or sequence limit reached.")
        }
        sequence += 1
        let bytes = try USBWire.command(verb, session: session, sequence: sequence, levels: verb == "SET" || verb == "TEST" ? levels : nil, channels: state.limits.channelCount)
        pending[sequence] = Pending(verb: verb, levels: verb == "TEST" ? .zero : levels, at: now, completion: completion)
        output.append(Packet(bytes: bytes, sequence: sequence, urgent: urgent))
    }
    private func consumeControl() {
        inputLock.lock(); let update = control, zeros = zeroMask; control = nil; zeroMask = 0; inputLock.unlock()
        guard let update, update.epoch == state.epoch, current(update.epoch), state.active, !state.stopping else { return }
        guard update.at <= now, now - update.at < USBWire.controllerFreshnessSeconds else {
            fail("Controller updates stopped; USB output disarmed."); return
        }
        guard controlAt == nil || update.at >= controlAt! else { return }
        if let controlAt, now - controlAt >= USBWire.controllerFreshnessSeconds {
            fail("Controller updates stopped; USB output disarmed."); return
        }
        do {
            _ = try update.levels.validated(limits: state.limits)
            controlAt = update.at
            let levels = pressureSafety.context != nil && !pressureSafety.allowsOutput(at: io.pressureNow()) ? VibrationLevels.zero : update.levels
            if state.requested != levels {
                state.requested = levels; publish()
                post(Event(kind: "request", text: "M1=\(levels.one) M2=\(levels.two) M3=\(levels.three)"))
            }
            if zeros != 0 {
                cancelUnsentSets()
                let pair = VibrationLevels(zeros & 1 != 0 ? 0 : levels.one, zeros & 2 != 0 ? 0 : levels.two,
                                           zeros & 4 != 0 ? 0 : levels.three)
                try enqueue("SET", levels: pair, urgent: true); lastSet = now
            } else if output.contains(where: { $0.offset == 0 && !$0.urgent && $0.sequence.flatMap { pending[$0]?.verb } == "SET" }) {
                try enqueue("SET", levels: levels)
            }
        } catch { fail(error.localizedDescription) }
    }
    private func cancelUnsentSets() {
        output.removeAll { packet in
            guard packet.offset == 0, !packet.urgent, let seq = packet.sequence, pending[seq]?.verb == "SET" else { return false }
            pending.removeValue(forKey: seq)?.completion?(.failure(CancellationError())); return true
        }
    }
    private func consumePressureSafety() {
        inputLock.lock()
        let context = incomingSafetyContext, samples = incomingPressure, failure = incomingPressureFailure
        incomingSafetyContext = nil; incomingPressure = []; incomingPressureFailure = nil
        inputLock.unlock()
        guard state.active, !state.stopping, current(state.epoch) else { return }
        if pressureEpoch != state.epoch {
            pressureSafety.reset(); pressureEpoch = state.epoch; state.pressurePause = nil
        }
        if let (epoch, value) = context, epoch == state.epoch { pressureSafety.configure(value) }
        let time = io.pressureNow()
        if let (epoch, kind) = failure, epoch == state.epoch { pressureSafety.fail(kind, at: time) }
        for (epoch, sample) in samples where epoch == state.epoch { pressureSafety.observe(sample, at: time) }
        pressureSafety.evaluate(at: time)
        if state.pressurePause != pressureSafety.pause {
            state.pressurePause = pressureSafety.pause
            deliveryLock.lock(); publishedPressurePause = (state.epoch, state.pressurePause); deliveryLock.unlock()
            if let pause = state.pressurePause {
                post(Event(kind: "pressureSafety", text: pause.reason, pressurePause: pause, epoch: state.epoch))
                if pause.requiresDisarm { beginStop(close: false); return }
            }
            publish()
        }
        guard pressureSafety.context != nil, !pressureSafety.allowsOutput(at: time) else { return }
        // Cancel every unsent SET, including urgent mixed-channel transitions.
        output.removeAll { packet in
            guard packet.offset == 0, let sequence = packet.sequence, pending[sequence]?.verb == "SET",
                  pending[sequence]?.levels != .zero else { return false }
            pending.removeValue(forKey: sequence)?.completion?(.failure(CancellationError())); return true
        }
        if state.requested.anyOn || state.reported?.anyOn == true {
            state.requested = .zero
            do { try enqueue("SET", levels: .zero, urgent: true); lastSet = now }
            catch { fail(error.localizedDescription); return }
            publish()
        }
    }
    private func pump() {
        guard fd >= 0 else { return }
        let previousService = servicedAt; servicedAt = now
        do { try readAvailable() } catch {
            if state.stopping { finishStop(.failure(error)) } else { fail(error.localizedDescription) }
        }
        guard fd >= 0 else { return }
        if state.active, !state.stopping, let previousService,
           now - previousService >= USBWire.controllerFreshnessSeconds {
            fail("USB worker timing stalled; output disarmed."); return
        }
        consumePressureSafety()
        consumeControl()
        if state.stopping {
            if !output.isEmpty && now - stopAt >= 0.100 {
                finishStop(.failure(AppError.invalid("USB STOP write timed out; output is unconfirmed."))); return
            }
            if now - stopAt >= USBWire.acknowledgementSeconds {
                finishStop(.failure(AppError.invalid("USB STOP acknowledgement timed out; output is unconfirmed."))); return
            }
            flush(); return
        }
        guard current(state.epoch) else { return }
        if state.active, let controlAt, now - controlAt >= USBWire.controllerFreshnessSeconds {
            fail("Controller updates stopped; USB output disarmed."); return
        }
        if pending.values.contains(where: { now - $0.at >= USBWire.acknowledgementSeconds }) {
            fail("Arduino acknowledgement timed out. Output is unconfirmed."); return
        }
        if let deadline = helloDeadline {
            if now >= deadline { fail("No compatible PE1 response. Install the supplied Arduino firmware."); return }
            if now - helloAt >= 0.5 { sendHello() }
        }
        if state.active && now - lastSet >= 0.1 {
            do { try enqueue("SET", levels: state.requested); lastSet = now }
            catch { fail(error.localizedDescription); return }
        }
        flush()
    }
    private func flush() {
        for _ in 0..<16 {
            guard fd >= 0, let packet = output.first else { return }
            guard state.stopping || current(state.epoch) else { return }
            if !state.stopping, state.active, let controlAt, now - controlAt >= USBWire.controllerFreshnessSeconds {
                fail("Controller updates stopped; USB output disarmed."); return
            }
            if state.stopping && now - stopAt >= 0.100 {
                finishStop(.failure(AppError.invalid("USB STOP write timed out; output is unconfirmed."))); return
            }
            let bytes = Data(packet.bytes.dropFirst(packet.offset))
            let written = io.write(fd, bytes)
            if written > 0 {
                guard written <= bytes.count else { fail("Invalid serial write result."); return }
                post(Event(kind: "wire", text: "tx", bytes: Data(bytes.prefix(written))))
                output[0].offset += written
                if output[0].offset == output[0].bytes.count { output.removeFirst() }
            } else if written < 0 && errno == EINTR { continue }
            else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else {
                let error = AppError.invalid("USB write failed or cable disconnected.")
                if state.stopping { finishStop(.failure(error)) } else { fail(error.localizedDescription) }
                return
            }
        }
    }
    private func readAvailable() throws {
        let link = linkID
        var bytes = [UInt8](repeating: 0, count: 1024)
        for _ in 0..<8 {
            guard fd >= 0, link == linkID else { return }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                let data = Data(bytes.prefix(count)); post(Event(kind: "wire", text: "rx", bytes: data))
                for line in try buffer.append(data) {
                    // Stop clears readiness, but ACKs must still include every negotiated channel.
                    try receive(USBWire.parse(line, expectedChannels: helloDeadline == nil ? state.limits.channelCount : nil))
                    if fd < 0 || link != linkID { return }
                }
            } else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else { throw AppError.invalid("USB device disconnected.") }
        }
        throw AppError.invalid("Unexpected serial data flood.")
    }
    private func receive(_ reply: USBReply) throws {
        switch reply {
        case .boot:
            if helloDeadline == nil { throw AppError.invalid("Arduino reset; reconnect and rearm.") }
        case .ready(let nonce, let limits, let discovery):
            guard nonce == session, !state.stopping else { return }
            if helloDeadline == nil && state.ready && !state.armed && !state.active && state.limits == limits && state.discovery == discovery { return }
            guard let deadline = helloDeadline, now < deadline else { throw AppError.invalid("Unexpected or late Arduino handshake.") }
            state.ready = true; state.limits = limits; state.discovery = discovery
            state.reported = .zero; state.armed = false; helloDeadline = nil
            state.status = "PE1 connected · all motors OFF · watchdog 1s"
            let callback = helloCompletion; helloCompletion = nil; publish(); callback?(.success(()))
        case .ack(let nonce, let seq, let armed, let levels):
            guard nonce == session else { return }
            if cancelled.remove(seq) != nil || seq <= acknowledged { return }
            guard let expected = pending[seq] else { throw AppError.invalid("Unexpected USB acknowledgement sequence.") }
            guard now - expected.at < USBWire.acknowledgementSeconds else { throw AppError.invalid("Arduino acknowledgement timed out.") }
            let expectedArmed = expected.verb == "ARM" || expected.verb == "SET"
            guard armed == expectedArmed, levels == expected.levels else { throw AppError.invalid("Arduino reported an unexpected motor output.") }
            _ = try levels.validated(limits: state.limits)
            acknowledged = seq; pending.removeValue(forKey: seq)
            state.armed = armed; state.reported = levels; publish()
            if seq == stopSequence { finishStop(.success(())) }
            else { expected.completion?(.success(())) }
        case .error(let nonce, _, let code), .fault(let nonce, let code):
            if nonce == session { throw AppError.invalid("Arduino fault: \(code). Reconnect and rearm.") }
        }
    }
    private func beginStop(close: Bool, reason: String? = nil, completion: Completion? = nil) {
        if let reason, faultReason == nil { faultReason = reason }
        if let completion { stopWaiters.append(completion) }
        if fd < 0 {
            let callbacks = stopWaiters; stopWaiters = []; callbacks.forEach { $0(.success(state)) }; return
        }
        if state.stopping { closeAfterStop = closeAfterStop || close; return }
        state.stopping = true; state.active = false; state.testing = false; state.ready = false
        state.requested = .zero; state.reported = nil; controlAt = nil
        closeAfterStop = close; silentClose = close && reason == nil
        stopAt = now; state.status = reason ?? "Stopping · waiting for OFF acknowledgement"
        let callbacks = pending.values.compactMap(\.completion)
        cancelled.formUnion(pending.keys); pending = [:]
        output.removeAll { $0.offset == 0 }
        let hello = helloCompletion; helloCompletion = nil; helloDeadline = nil
        publish()
        if let faultReason {
            // Finish failed operations after bounded STOP/close, so awaiting
            // callers observe the terminal transport state, not a stale UI copy.
            stopWaiters.append { _ in
                let error = AppError.invalid(faultReason)
                hello?(.failure(error)); callbacks.forEach { $0(.failure(error)) }
            }
        } else {
            hello?(.failure(CancellationError())); callbacks.forEach { $0(.failure(CancellationError())) }
        }
        do {
            try enqueue("STOP"); stopSequence = sequence
            post(Event(kind: "emergencyStop", text: "STOP queued; write budget 100 ms, total ACK budget 900 ms."))
            flush()
        } catch { finishStop(.failure(error)) }
    }
    private func finishStop(_ result: Result<Void, Error>) {
        guard state.stopping else { return }
        let callbacks = stopWaiters; stopWaiters = []
        let error: Error?
        if case .failure(let failure) = result { error = failure } else { error = nil }
        let fault = faultReason ?? (!silentClose ? error?.localizedDescription : nil)
        state.stopping = false; stopSequence = nil; pending = [:]; output = []; cancelled = []
        if closeAfterStop || error != nil {
            closePort(error ?? AppError.invalid("USB disconnected."))
            if let fault { state.faultID = UUID(); state.fault = fault; state.status = fault }
        } else {
            state.ready = true; state.armed = false; state.reported = .zero
            lastStopEpoch = state.epoch
            state.status = "Connected · all channels OFF"
        }
        publish(); callbacks.forEach { $0(result.map { state }) }
    }
    private func fail(_ reason: String) {
        guard fd >= 0, !state.stopping else { return }
        let age = controlAt.map { now - $0 } ?? 0
        let ackAge = pending.values.map { now - $0.at }.max() ?? 0
        post(Event(kind: "fault", text: "\(reason) controlAge=\(age) ackAge=\(ackAge) sequence=\(sequence) pending=\(pending.count) queued=\(output.count)"))
        beginStop(close: true, reason: reason)
    }
    private func closePort(_ error: Error) {
        timer?.cancel(); timer = nil
        if fd >= 0 { _ = ioctl(fd, UInt(TIOCNXCL), 0); Darwin.close(fd); fd = -1 }
        linkID = UUID()
        let hello = helloCompletion; helloCompletion = nil; helloDeadline = nil
        let callbacks = pending.values.compactMap(\.completion); pending = [:]; output = []; cancelled = []
        state.connected = false; state.ready = false; state.active = false; state.testing = false; state.stopping = false
        state.armed = false; state.reported = nil; state.requested = .zero; state.status = "Not connected"
        controlAt = nil; buffer = USBLineBuffer()
        post(Event(kind: "close", text: error.localizedDescription)); publish()
        hello?(.failure(error)); callbacks.forEach { $0(.failure(error)) }
    }

    // Deterministic checks use a frozen clock with the automatic timer disabled.
    func tickForTesting() { queue.sync { pump() } }
    func snapshotForTesting() -> Snapshot { queue.sync { state } }
}
