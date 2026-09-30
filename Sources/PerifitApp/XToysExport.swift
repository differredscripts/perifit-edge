import Foundation
import SwiftUI
import PerifitCore

/// Opt-in outbound telemetry; failures never alter the motor controller.
@MainActor final class XToysExport: NSObject, ObservableObject, URLSessionTaskDelegate {
    @Published private(set) var enabled = false
    @Published private(set) var status = "Export off"
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var endpoint: URL?
    private var inFlight: Task<Void, Never>?
    private var generation = UUID()
    private var lastSend = -Double.infinity

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
    }
    static func destination(_ webhookID: String) throws -> URL {
        let id = webhookID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(id.utf8.count),
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw AppError.invalid("Enter only your XToys Private Webhook ID, not a URL or token.")
        }
        return URL(string: "https://webhook.xtoys.app/" + id)!
    }
    func start(webhookID: String) throws {
        let url = try Self.destination(webhookID)
        stop()
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 1.5; configuration.timeoutIntervalForResource = 1.5
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        endpoint = url; lastSend = -.infinity; enabled = true
        status = "Sharing live readings with XToys · up to 2 updates/s"
    }
    func publish(_ value: XToysTelemetry, at time: Double) {
        guard enabled, time.isFinite, time - lastSend >= 0.5, inFlight == nil, let endpoint, let session else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { request.httpBody = try JSONEncoder().encode(value) }
        catch { stop(); status = "Export stopped: invalid telemetry"; return }
        lastSend = time
        let epoch = generation
        inFlight = Task { [weak self] in
            do {
                let (_, response) = try await session.data(for: request)
                guard let self, self.generation == epoch else { return }
                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                    self.stop(); self.status = "Export stopped: XToys rejected the request"; return
                }
                self.inFlight = nil
            } catch {
                guard let self, self.generation == epoch else { return }
                self.stop(); self.status = "Export stopped: network request failed"
            }
        }
    }
    func stop() {
        generation = UUID(); enabled = false; endpoint = nil
        inFlight?.cancel(); inFlight = nil
        session?.invalidateAndCancel(); session = nil; status = "Export off"
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward pressure data or the private ID to a redirect destination.
    }
}

struct XToysExportControls: View {
    @ObservedObject var exporter: XToysExport
    @State private var webhookID = ""
    @State private var error = ""
    var body: some View {
        DisclosureGroup("Export pressure / arousal to XToys") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Optional: sends live pressure, heuristic score and control state to XToys’ servers. The Private Webhook ID stays in memory and export starts off after every launch.")
                    .font(.caption)
                SecureField("XToys Private Webhook ID", text: $webhookID).disabled(exporter.enabled)
                HStack {
                    Button("Start sharing readings") {
                        do { try exporter.start(webhookID: webhookID); webhookID = ""; error = "" }
                        catch { self.error = error.localizedDescription }
                    }.disabled(exporter.enabled || webhookID.isEmpty)
                    Button("Stop sharing") { exporter.stop() }.disabled(!exporter.enabled)
                }
                Text(exporter.status).font(.caption)
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
                Text("This exports data, not motor commands. An XToys script driving other toys must honor fresh / armed / permitted and stop when updates are missing for 2 seconds.")
                    .font(.caption)
                Link("XToys webhook setup", destination: URL(string: "https://guide.xtoys.app/tools/webhook.html")!)
            }.padding(.top, 6)
        }
    }
}
