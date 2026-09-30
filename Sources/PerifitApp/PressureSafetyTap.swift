import Foundation
import PerifitCore

/// A verified BLE subscription can deliver safety samples without waiting for MainActor.
final class PressureSafetyTap: @unchecked Sendable {
    typealias Sink = @Sendable (PressureSample?, PressureSafetyEvent.Kind?) -> Void
    private let lock = NSLock()
    private var binding: (UUID, String, String, Sink)?
    func bind(peripheral: UUID, service: String, characteristic: String, sink: @escaping Sink) {
        lock.lock(); binding = (peripheral, service, characteristic, sink); lock.unlock()
    }
    func clear() { lock.lock(); binding = nil; lock.unlock() }
    func receive(_ data: Data, peripheral: UUID, service: String, characteristic: String, time: Double) {
        lock.lock(); let value = binding; lock.unlock()
        guard let value, value.0 == peripheral, value.1 == service, value.2 == characteristic else { return }
        do { value.3(try PressureSample(data: data, time: time), nil) }
        catch { value.3(nil, .invalidPressure) }
    }
    func disconnected(_ peripheral: UUID) {
        lock.lock()
        let sink = binding?.0 == peripheral ? binding?.3 : nil
        if sink != nil { binding = nil }
        lock.unlock(); sink?(nil, .disconnected)
    }
}
