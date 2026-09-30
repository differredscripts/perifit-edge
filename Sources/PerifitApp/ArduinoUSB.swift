import Foundation
import Combine
import PerifitCore

@MainActor
final class ArduinoUSB: ObservableObject {
    let debugLog = USBDebugLog()
    @Published private(set) var status = "Not connected"
    @Published private(set) var connected = false
    @Published private(set) var ready = false
    @Published private(set) var supportsDiscovery = false
    @Published private(set) var boardArmed = false
    private(set) var reported: VibrationLevels?
    private(set) var requested = VibrationLevels.zero
    @Published private(set) var limits = VibrationLevels(255, 255)
    @Published private(set) var ports: [String] = []
    private(set) var port = ""
    private(set) var isPseudoTerminalTest = false
    var onFault: ((String) -> Void)?
    var onReported: ((VibrationLevels) -> Void)?
    var onPressureSafety: ((PressureSafetyEvent) -> Void)?
    var pressureSafetyPause: PressureSafetyEvent? { worker.pressurePause(epoch: epoch) }
    func updatePressureSafety(_ context: PressureSafetyContext) { worker.submitSafetyContext(context, epoch: epoch) }
    func receivePressure(_ sample: PressureSample) { worker.submitPressure(sample, epoch: epoch) }
    func pressureSafetySink() -> @Sendable (PressureSample?, PressureSafetyEvent.Kind?) -> Void {
        let transport = worker!, generation = epoch
        return { sample, failure in transport.submitPressure(sample, failure: failure, epoch: generation) }
    }
    private let allowPseudoTerminal: Bool
    private var worker: USBSerialWorker!
    private var epoch = UUID(), lastFault: UUID?
    private var revision: UInt64 = 0
    private var intendedArmed = false, stopping = false, testing = false
    private var lastTelemetryUI = 0.0

    private func publishTelemetry(force: Bool = false) {
        let time = ProcessInfo.processInfo.systemUptime
        guard force || time - lastTelemetryUI >= 0.1 else { return }
        lastTelemetryUI = time; objectWillChange.send()
    }

    init(allowPseudoTerminal: Bool = false, io: USBSerialWorker.IO = .init()) {
        self.allowPseudoTerminal = allowPseudoTerminal
        worker = USBSerialWorker(io: io) { [weak self] in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { self?.receiveDelivery() }
            }
        }
        worker.invalidate(epoch)
    }
    func refreshPorts() {
        ports = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.") && ($0.contains("usb") || $0.contains("USB") || $0.contains("SLAB")) }
            .sorted().map { "/dev/" + $0 }
    }
    private func nextEpoch() -> UUID {
        epoch = UUID(); worker.invalidate(epoch); return epoch
    }
    private func receiveDelivery() {
        let (snapshot, events) = worker.takeDelivery()
        for event in events {
            if event.epoch == epoch, let pressure = event.pressurePause { onPressureSafety?(pressure) }
            if let bytes = event.bytes { debugLog.wire(event.text, bytes) }
            else { debugLog.record(event.kind, event.text) }
        }
        if let snapshot { apply(snapshot) }
    }
    private func apply(_ snapshot: USBSerialWorker.Snapshot) {
        guard snapshot.epoch == epoch, snapshot.revision >= revision else { return }
        revision = snapshot.revision
        let reportChanged = reported != snapshot.reported || boardArmed != snapshot.armed || ready != snapshot.ready
        if connected != snapshot.connected { connected = snapshot.connected }
        if ready != snapshot.ready { ready = snapshot.ready }
        if supportsDiscovery != snapshot.discovery { supportsDiscovery = snapshot.discovery }
        if boardArmed != snapshot.armed { boardArmed = snapshot.armed }
        if reported != snapshot.reported { reported = snapshot.reported }
        if limits != snapshot.limits { limits = snapshot.limits }
        port = snapshot.port; isPseudoTerminalTest = snapshot.pseudo
        if status != snapshot.status { status = snapshot.status }
        intendedArmed = snapshot.active; testing = snapshot.testing; stopping = snapshot.stopping
        if !intendedArmed { requested = snapshot.requested }
        if reportChanged { publishTelemetry(force: !intendedArmed || reported == nil || reported == .zero) }
        if reportChanged, let reported { onReported?(reported) }
        if let faultID = snapshot.faultID, faultID != lastFault, let reason = snapshot.fault {
            lastFault = faultID; onFault?(reason)
        }
    }
    private func run(_ operation: USBSerialWorker.Operation, epoch: UUID) async throws -> USBSerialWorker.Snapshot {
        do {
            let snapshot: USBSerialWorker.Snapshot = try await withCheckedThrowingContinuation { continuation in
                worker.perform(operation, epoch: epoch) { continuation.resume(with: $0) }
            }
            guard self.epoch == epoch else { throw CancellationError() }
            apply(snapshot); return snapshot
        } catch let failure as USBSerialWorker.Failure {
            guard self.epoch == epoch else { throw CancellationError() }
            apply(failure.snapshot); throw failure.underlying
        }
    }
    func connect(path: String) async throws {
        let id = nextEpoch()
        ready = false; intendedArmed = false; stopping = false; testing = false
        requested = .zero; reported = nil; port = path
        do { _ = try await run(.connect(path, allowPseudoTerminal), epoch: id) }
        catch { if epoch == id { status = error.localizedDescription }; throw error }
    }
    func arm() async throws {
        guard ready, reported == .zero, !boardArmed, !stopping, !testing else {
            throw AppError.invalid("The Arduino must report all channels OFF before arming.")
        }
        let snapshot = try await run(.arm, epoch: nextEpoch())
        guard snapshot.active, snapshot.armed, snapshot.reported == .zero else {
            throw AppError.invalid("Arduino arming was not confirmed.")
        }
    }
    func testPulse(_ levels: VibrationLevels) async throws {
        guard ready, supportsDiscovery, reported == .zero, !boardArmed, !intendedArmed, !stopping, !testing else {
            throw AppError.invalid("Connect TEST250 firmware with all motors OFF before discovery.")
        }
        _ = try levels.validated(limits: limits)
        guard levels.values.filter({ $0 > 0 }).count == 1 else { throw AppError.invalid("Test exactly one motor at a time.") }
        let id = nextEpoch(); testing = true; requested = levels; reported = nil; publishTelemetry(force: true)
        defer { if epoch == id { testing = false; requested = .zero } }
        let snapshot = try await run(.test(levels), epoch: id)
        guard snapshot.reported == .zero, !snapshot.armed else { throw AppError.invalid("Motor test OFF was not confirmed.") }
    }
    func drive(_ levels: VibrationLevels) throws {
        _ = try levels.validated(limits: limits)
        guard ready, intendedArmed, !stopping else { throw AppError.invalid("Arduino is not armed.") }
        var zeros: UInt8 = 0
        if requested.one > 0 && levels.one == 0 { zeros |= 1 }
        if requested.two > 0 && levels.two == 0 { zeros |= 2 }
        if requested.three > 0 && levels.three == 0 { zeros |= 4 }
        let changed = requested != levels
        requested = levels
        // Timestamp on the producer, never when a delayed worker dequeues it.
        worker.submit(levels, at: worker.time(), epoch: epoch, zeros: zeros)
        if changed { publishTelemetry(force: levels == .zero) }
    }
    func zeroNow() {
        guard connected, intendedArmed, !stopping else { return }
        requested = .zero; worker.submit(.zero, at: worker.time(), epoch: epoch, zeros: 7)
        publishTelemetry(force: true)
    }
    func prepareStop() {
        guard !stopping else { return }
        let id = nextEpoch()
        intendedArmed = false; requested = .zero; stopping = true; testing = false
        // Dispatch immediately: Stop must not wait for a MainActor Task to run.
        worker.perform(.stop, epoch: id) { _ in }
        publishTelemetry(force: true)
    }
    func stop() async throws {
        prepareStop()
        let snapshot = try await run(.stop, epoch: epoch)
        if snapshot.connected && (snapshot.reported != .zero || snapshot.armed) {
            throw AppError.invalid("Arduino did not confirm all motor outputs OFF.")
        }
    }
    func disconnect() {
        let id = nextEpoch()
        intendedArmed = false; requested = .zero; stopping = false; testing = false
        connected = false; ready = false; reported = nil; boardArmed = false; supportsDiscovery = false
        status = "Not connected"
        worker.perform(.disconnect, epoch: id) { _ in }
    }

    func tickForTesting() { worker.tickForTesting(); receiveDelivery() }
    func snapshotForTesting() -> USBSerialWorker.Snapshot { worker.snapshotForTesting() }
}
