import Foundation
import Combine
import Network
import PerifitCore

@MainActor
final class XToysBridge: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var connected = false
    @Published private(set) var status = "XToys control is off."
    @Published private(set) var endpoint = ""
    @Published private(set) var demand = XToysDemand()
    var onFault: ((String) -> Void)?
    private let mappedChannel: Int?
    init(mappedChannel: Int? = nil) { self.mappedChannel = mappedChannel }
    private let queue = DispatchQueue(label: "PerifitEdge.XToys", qos: .userInitiated)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var timer: Timer?
    private var accepting = false
    private var lastPong = 0.0, lastPing = 0.0, rateWindow = 0.0
    private var messages = 0
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    nonisolated private static func deliver(_ action: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { action() } }
    }
    func start(port: UInt16 = 48971) throws {
        guard listener == nil else { return }
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true; websocket.maximumMessageSize = 512
        websocket.setClientRequestHandler(queue) { _, headers in
            let origins = headers.filter { $0.name.lowercased() == "origin" }.map(\.value)
            return .init(status: origins == ["https://xtoys.app"] ? .accept : .reject, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        let server = try NWListener(using: parameters)
        listener = server; enabled = true; status = "Starting local XToys connection…"
        server.stateUpdateHandler = { [weak self, weak server] state in
            Self.deliver { [weak self, weak server] in
                guard let self, let server, self.listener === server else { return }
                switch state {
                case .ready:
                    self.endpoint = "ws://127.0.0.1:\(server.port!.rawValue)"
                    self.status = self.mappedChannel == 3 ? "Waiting for XToys · M3 OFF" : "Waiting for XToys · M1/M2 OFF"
                case .failed(let error):
                    self.stop(); self.status = "XToys listener failed: \(error.localizedDescription)"; self.onFault?(self.status)
                default: break
                }
            }
        }
        server.newConnectionHandler = { [weak self, weak server] client in
            Self.deliver { [weak self, weak server] in
                guard let self, self.listener === server, self.connection == nil else { client.cancel(); return }
                self.accept(client)
            }
        }
        server.start(queue: queue)
        let clock = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkConnection() }
        }
        timer = clock; RunLoop.main.add(clock, forMode: .common)
    }
    func stop() {
        timer?.invalidate(); timer = nil
        let client = connection; connection = nil; client?.cancel()
        let server = listener; listener = nil; server?.cancel()
        endSession(); connected = false; enabled = false; endpoint = ""; status = "XToys control is off."
    }
    func beginSession() throws {
        guard connected else { throw AppError.invalid("Connect the XToys custom vibrator before arming.") }
        demand = XToysDemand(); accepting = true
    }
    func endSession() { accepting = false; demand = XToysDemand() }
    private func accept(_ client: NWConnection) {
        connection = client; connected = false; endSession()
        lastPong = now; lastPing = 0; rateWindow = now; messages = 0
        client.stateUpdateHandler = { [weak self, weak client] state in
            Self.deliver { [weak self, weak client] in
                guard let self, let client, self.connection === client else { return }
                switch state {
                case .ready:
                    self.connected = true; self.lastPong = self.now
                    self.status = "XToys connected · Start in Perifit Edge, then play a pattern in XToys"
                    self.receive(client)
                case .failed, .cancelled: self.disconnect("XToys disconnected. All motor outputs stopped.")
                default: break
                }
            }
        }
        client.start(queue: queue)
    }
    private func receive(_ client: NWConnection) {
        // Request the next message only after handling this one, bounding queued UI work.
        client.receiveMessage { [weak self, weak client] data, context, _, error in
            Self.deliver { [weak self, weak client] in
                guard let self, let client, self.connection === client else { return }
                guard error == nil, let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                    self.disconnect("XToys connection lost. All motor outputs stopped."); return
                }
                switch metadata.opcode {
                case .text:
                    if self.now - self.rateWindow >= 1 { self.rateWindow = self.now; self.messages = 0 }
                    self.messages += 1
                    guard self.messages <= 200, let data else { self.disconnect("XToys sent too many messages. All motor outputs stopped."); return }
                    do {
                        let command = try XToysCommand.parse(data, mappedChannel: self.mappedChannel)
                        if self.accepting {
                            var next = self.demand; next.apply(command)
                            if next != self.demand { self.demand = next }
                        }
                    } catch { self.disconnect("Invalid XToys command. All motor outputs stopped. \(error.localizedDescription)"); return }
                case .ping, .pong: break
                case .close: self.disconnect("XToys disconnected. All motor outputs stopped."); return
                default: self.disconnect("XToys must send JSON text. All motor outputs stopped."); return
                }
                self.receive(client)
            }
        }
    }
    private func checkConnection() {
        guard let client = connection else { return }
        guard now - lastPong < 3 else { disconnect("XToys connection stopped responding. All motor outputs stopped."); return }
        guard connected, now - lastPing >= 1 else { return }
        lastPing = now
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { [weak self, weak client] error in
            Self.deliver { [weak self, weak client] in
                guard let self, let client, self.connection === client else { return }
                if error != nil { self.disconnect("XToys keepalive failed. All motor outputs stopped.") }
                else { self.lastPong = self.now }
            }
        }
        client.send(content: Data(), contentContext: .init(identifier: "XToys keepalive", metadata: [metadata]),
                    isComplete: true, completion: .idempotent)
    }
    private func disconnect(_ reason: String) {
        let wasConnected = connected
        let client = connection; connection = nil
        endSession(); connected = false; client?.cancel(); status = reason
        if wasConnected { onFault?(reason) }
    }
}
