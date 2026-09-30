import Foundation
@preconcurrency import CoreBluetooth
import Combine
import PerifitCore

struct PeripheralChoice: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
}
struct CharacteristicChoice: Identifiable, Hashable {
    var id: String { service + "/" + characteristic }
    let service: String
    let characteristic: String
}

@MainActor
final class BluetoothInput: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated let safetyTap = PressureSafetyTap()
    @Published var status = "Bluetooth not started"
    @Published var devices: [PeripheralChoice] = []
    @Published var choices: [CharacteristicChoice] = []
    @Published var connectedID: UUID?
    @Published var selectedCharacteristic = ""
    @Published var packetCount = 0
    @Published var malformedCount = 0
    @Published var sampleRate = 0.0
    @Published var baseRange = "—"
    @Published var tipRange = "—"
    @Published var lastHex = ""
    var onSample: ((PressureSample) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onProtocolError: ((String) -> Void)?
    private let callbackQueue = DispatchQueue(label: "PerifitEdge.bluetooth")
    private var readTimer: Timer?
    private var readbackEnabled = false
    private var readPending = false
    private var lastPressurePacket = 0.0
    private var central: CBCentralManager!
    var hasStarted: Bool { central != nil }
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var characteristics: [String: CBCharacteristic] = [:]
    private var peripheral: CBPeripheral?
    private var activeCharacteristic: CBCharacteristic?
    private var firstPacket: Double?
    private var receivedPackets = 0
    private var lastStatistics = 0.0
    private var minBase: UInt16 = .max, maxBase: UInt16 = 0
    private var minTip: UInt16 = .max, maxTip: UInt16 = 0
    var canVerify: Bool { packetCount >= 20 && malformedCount == 0 && maxBase > minBase && maxTip > minTip }
    var activeChoice: CharacteristicChoice? { choices.first { $0.id == selectedCharacteristic } }
    override init() {
        super.init()
        // Initialized on demand so launching in demo mode does not request Bluetooth access.
    }
    func scan() {
        if central == nil { central = CBCentralManager(delegate: self, queue: callbackQueue); return }
        guard central.state == .poweredOn else { status = "Enable Bluetooth and grant this app Bluetooth access."; return }
        devices = []; peripherals = [:]
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        status = "Scanning nearby Bluetooth devices…"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self else { return }
            self.central?.stopScan()
            if self.connectedID == nil { self.status = "Scan complete. Select your Perifit." }
        }
    }
    func connect(_ id: UUID) {
        guard let p = peripherals[id] else { status = "Scan again to locate this device."; return }
        disconnect()
        central.stopScan(); peripheral = p; p.delegate = self
        status = "Connecting to \(p.name ?? id.uuidString)…"
        central.connect(p)
    }
    func disconnect() {
        safetyTap.clear()
        stopReadback()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        connectedID = nil; activeCharacteristic = nil; selectedCharacteristic = ""
        choices = []; characteristics = [:]; self.peripheral = nil
    }
    func subscribe(_ id: String) {
        guard let peripheral, let characteristic = characteristics[id] else { return }
        if let activeCharacteristic { peripheral.setNotifyValue(false, for: activeCharacteristic) }
        stopReadback(); lastPressurePacket = 0
        packetCount = 0; malformedCount = 0; firstPacket = nil; sampleRate = 0
        receivedPackets = 0; lastStatistics = 0; baseRange = "—"; tipRange = "—"; lastHex = ""
        minBase = .max; maxBase = 0; minTip = .max; maxTip = 0
        selectedCharacteristic = id; activeCharacteristic = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
        status = "Subscribing; verify the two pressure channels before live control."
    }
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        deliver { [weak self] in
            guard let self else { return }
            switch central.state {
            case .poweredOn: scan()
            case .unauthorized: status = "Bluetooth permission denied. Enable it in System Settings → Privacy & Security → Bluetooth."
            case .poweredOff: status = "Bluetooth is off."
            case .unsupported: status = "Bluetooth LE is unavailable."
            default: status = "Bluetooth is initializing."
            }
            if central.state != .poweredOn { stopReadback(); onDisconnect?(status) }

        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        deliver { [weak self] in
            guard let self else { return }
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? "Unnamed peripheral"
            peripherals[p.identifier] = p
            if !devices.contains(where: { $0.id == p.identifier }) {
                devices.append(PeripheralChoice(id: p.identifier, name: name, rssi: RSSI.intValue))
                devices.sort {
                    let a = $0.name.localizedCaseInsensitiveContains("perifit"), b = $1.name.localizedCaseInsensitiveContains("perifit")
                    return a == b ? $0.rssi > $1.rssi : a
                }
            }

        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        deliver { [weak self] in
            guard let self else { return }
            guard p == peripheral else { return }
            connectedID = p.identifier; status = "Discovering services…"; p.discoverServices(nil)

        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        deliver { [weak self] in
            guard let self else { return }
            guard p == peripheral else { return }
            connectedID = nil; status = "Connection failed: \(error?.localizedDescription ?? "unknown reason")"
            onDisconnect?(status)

        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        safetyTap.disconnected(p.identifier)
        deliver { [weak self] in
            guard let self else { return }
            guard p == peripheral else { return }
            stopReadback()
            connectedID = nil; activeCharacteristic = nil; status = "Perifit disconnected. Reconnect to restore its saved calibration."
            onDisconnect?(status)

        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        deliver { [weak self] in
            guard let self else { return }
            guard p == peripheral else { return }
            if let error { status = error.localizedDescription; onProtocolError?(status); return }
            for service in p.services ?? [] { p.discoverCharacteristics(nil, for: service) }

        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        deliver { [weak self] in
            guard let self else { return }
            guard p == peripheral else { return }
            if let error { status = error.localizedDescription; onProtocolError?(status); return }
            for c in service.characteristics ?? [] where c.properties.contains(.notify) || c.properties.contains(.indicate) {
                let choice = CharacteristicChoice(service: service.uuid.uuidString, characteristic: c.uuid.uuidString)
                characteristics[choice.id] = c
                if !choices.contains(choice) { choices.append(choice) }
            }
            status = "Select a notifying pressure characteristic. Pressure input is read-only."

        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        deliver { [weak self] in
            guard let self else { return }
            guard characteristic == activeCharacteristic else { return }
            if let error { status = error.localizedDescription; onProtocolError?(status) }
            else if characteristic.isNotifying {
                startReadback()
                status = readbackEnabled ? "Pressure notifications + readback when quiet" : "Receiving pressure notifications"
            } else { stopReadback(); status = "Pressure notifications stopped"; onDisconnect?(status) }

        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let data = characteristic.value, receivedAt = ProcessInfo.processInfo.systemUptime
        if error == nil, let data, let service = characteristic.service?.uuid.uuidString {
            safetyTap.receive(data, peripheral: p.identifier, service: service, characteristic: characteristic.uuid.uuidString, time: receivedAt)
        }
        deliver {
            [weak self] in
            guard let self, p == peripheral, characteristic == activeCharacteristic else { return }
            if let error {
                if readbackEnabled {
                    stopReadback(); status = "Readback unavailable; using pressure notifications"
                } else { onProtocolError?(error.localizedDescription) }
                return
            }
            readPending = false
            guard let data else { return }
            receivePacket(data, at: receivedAt)
        }
    }
    // Common-mode delivery also runs during slider/menu tracking, like the control timer.
    nonisolated func deliver(_ action: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { action() } }
    }
    private func stopReadback() {
        readTimer?.invalidate(); readTimer = nil; readbackEnabled = false; readPending = false
    }
    private func startReadback() {
        stopReadback()
        guard activeCharacteristic?.properties.contains(.read) == true else { return }
        readbackEnabled = true
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.readbackEnabled, !self.readPending,
                      ProcessInfo.processInfo.systemUptime - self.lastPressurePacket >= 0.2,
                      let peripheral = self.peripheral, peripheral.state == .connected,
                      let characteristic = self.activeCharacteristic else { return }
                self.readPending = true
                peripheral.readValue(for: characteristic)
            }
        }
        readTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func receivePacket(_ data: Data, at now: Double = ProcessInfo.processInfo.systemUptime) {
        do {
            let sample = try PressureSample(data: data, time: now)
            lastPressurePacket = now
            receivedPackets += 1; firstPacket = firstPacket ?? now
            minBase = min(minBase, sample.base); maxBase = max(maxBase, sample.base)
            minTip = min(minTip, sample.tip); maxTip = max(maxTip, sample.tip)
            onSample?(sample)
            // Deliver every pressure packet; redraw Bluetooth statistics at most 10 Hz.
            if now - lastStatistics >= 0.1 {
                lastStatistics = now; packetCount = receivedPackets
                sampleRate = Double(max(0, receivedPackets - 1)) / max(0.001, now - firstPacket!)
                baseRange = "\(minBase)…\(maxBase)"; tipRange = "\(minTip)…\(maxTip)"
                lastHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            }
        } catch {
            lastHex = data.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
            malformedCount += 1; status = error.localizedDescription; onProtocolError?(status)
        }
    }
}
