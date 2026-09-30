import Foundation
import PerifitCore

private final class WebhookMock: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var code = 204
    static var hold = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let code = Self.code, hold = Self.hold; Self.lock.unlock()
        guard !hold else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func count() -> Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    static func firstRequest() -> URLRequest { lock.lock(); defer { lock.unlock() }; return requests[0] }
    static func configure(code: Int = 204, hold: Bool = false) { lock.lock(); self.code = code; self.hold = hold; lock.unlock() }
}

@main struct XToysExportProbe {
    @MainActor static func main() async throws {
        let settings = EngineSettings()
        var snapshot = Snapshot(); snapshot.score = settings.sensitivity / 2; snapshot.wantsPower = true
        func frame(_ sample: PressureSample?, now: Double = 10, calibrated: Bool = true, armed: Bool = true) -> XToysTelemetry {
            XToysTelemetry(sample: sample, snapshot: snapshot, settings: settings, baseline: 1000, gain: 2,
                now: now, calibrated: calibrated, armed: armed, permitted: true, automaticCutoffs: true, simulated: false,
                timestamp: Date(timeIntervalSince1970: 1700000000))
        }
        let sample = PressureSample(base: 1200, tip: 700, time: 10)
        let value = frame(sample)
        assert(value.pressure == 400 && value.arousalPercent == 50 && value.fresh && value.permitted)
        let stale = frame(sample, now: 10.51)
        assert(!stale.fresh && !stale.permitted && stale.arousal == 0 && stale.pressureBase == 0)
        assert(!frame(nil).permitted && !frame(sample, now: 9).fresh && !frame(sample, calibrated: false).permitted)
        assert(!frame(PressureSample(base: 0, tip: 700, time: 10)).fresh)
        assert(!frame(sample, armed: false).permitted)
        snapshot.score = 65535
        assert(frame(sample).arousalPercent == 100)
        for invalid in ["", "https://example.com/id", "id?x=1", "../path", "a/b", "user:password", "é", String(repeating: "a", count: 129)] {
            do { _ = try XToysExport.destination(invalid); fatalError("Invalid webhook destination accepted") } catch {}
        }
        let destination = try XToysExport.destination("synthetic_test-id")
        assert(destination.scheme == "https" && destination.host == "webhook.xtoys.app")
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [WebhookMock.self]
        let exporter = XToysExport(configuration: configuration)
        assert(!exporter.enabled)
        try exporter.start(webhookID: "synthetic_test-id")
        for n in 0..<100 { exporter.publish(value, at: Double(n) / 1000) }
        try await Task.sleep(for: .milliseconds(100))
        assert(WebhookMock.count() == 1 && exporter.enabled)
        exporter.publish(value, at: 0.49)
        try await Task.sleep(for: .milliseconds(50)); assert(WebhookMock.count() == 1)
        exporter.publish(value, at: 0.5)
        try await Task.sleep(for: .milliseconds(100)); assert(WebhookMock.count() == 2)
        let request = WebhookMock.firstRequest()
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 2048); let count = stream.read(&bytes, maxLength: bytes.count)
            if count > 0 { data = Data(bytes.prefix(count)) }
        }
        let payload = try JSONSerialization.jsonObject(with: data!) as! [String: Any]
        assert(request.httpMethod == "POST" && payload["action"] as? String == "perifit" && payload["pressure"] as? Int == 400)
        assert(Set(payload.keys) == Set(["action", "schema", "timestampMs", "pressureBase", "pressureTip", "pressure", "arousal", "arousalPercent", "edge", "cutoff", "fresh", "calibrated", "armed", "permitted", "automaticCutoffs", "simulated"]))
        WebhookMock.configure(hold: true)
        exporter.publish(value, at: 1)
        try await Task.sleep(for: .milliseconds(100))
        for n in 2...100 { exporter.publish(value, at: Double(n)) }
        assert(WebhookMock.count() == 3) // No queue or overlapping requests, even with a slow receiver.
        exporter.stop(); assert(!exporter.enabled)
        exporter.publish(value, at: 101); assert(WebhookMock.count() == 3)
        WebhookMock.configure(code: 503)
        try exporter.start(webhookID: "synthetic_test-id"); exporter.publish(value, at: 0)
        try await Task.sleep(for: .milliseconds(100)); assert(!exporter.enabled)
        assert(!exporter.status.contains("synthetic_test-id"))
        print("PASS XToys telemetry: schema, conditioning, stale/zero/unarmed data, destination validation, HTTP POST, 2 Hz bound, one in-flight request, Stop and error isolation")
    }
}
