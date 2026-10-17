// Owner: Maxwell. Perception pipeline back-pressure and the built-in plugins,
// all against stubs: no camera, no network.

import CoreVideo
import Foundation
import Testing
import EchoGuideContracts
@testable import EchoGuideInfra
import EchoGuideVision

// MARK: - Stubs

final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Responder = @Sendable (URLRequest) throws -> (Int, Data)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var responder: Responder

    init(_ responder: @escaping Responder = { _ in (200, Data("{}".utf8)) }) { self.responder = responder }

    var requests: [URLRequest] { lock.withLock { _requests } }
    func respond(_ r: @escaping Responder) { lock.withLock { responder = r } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let r = lock.withLock { _requests.append(request); return responder }
        let (status, data) = try r(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

func pixelBuffer(width: Int = 640, height: Int = 480, fill: UInt8 = 100, square: Bool = false) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            base[y * bpr + x] = square && x > 160 && x < 480 && y > 120 && y < 360 ? 230 : fill
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

actor SlowVision: FrameInferring {
    let delay: TimeInterval
    var calls = 0
    init(delay: TimeInterval) { self.delay = delay }
    func infer(_ frame: CameraFrame) async -> VisionFrameResult {
        calls += 1
        try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        return VisionFrameResult(frameIndex: frame.index, timestamp: frame.timestamp, detections: [], inferenceMs: delay * 1000)
    }
}

actor ResultBox {
    var timings: [PipelineTiming] = []
    func add(_ t: PipelineTiming) { timings.append(t) }
}

func waitUntil(_ timeout: TimeInterval = 2, _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

// MARK: - Pipeline

@Suite struct PerceptionPipelineTests {
    @Test func skipsStaticAndInfersOnMotion() async {
        var config = FrameDeltaConfig()
        config.idleRefresh = nil
        config.cooldown = 0
        let vision = SlowVision(delay: 0)
        let box = ResultBox()
        let p = PerceptionPipeline(vision: vision, delta: FrameDeltaEngine(config: config)) { _, t in await box.add(t) }

        let still = pixelBuffer(), moved = pixelBuffer(square: true)
        p.submit(CameraFrame(pixelBuffer: still, timestamp: 0, index: 1))
        await waitUntil { await box.timings.count == 1 }
        for i in 2...20 { p.submit(CameraFrame(pixelBuffer: still, timestamp: Double(i) / 30, index: UInt64(i))) }
        #expect(p.submit(CameraFrame(pixelBuffer: moved, timestamp: 1, index: 21)).shouldInfer)
        await waitUntil { await box.timings.count == 2 }

        let s = p.stats
        #expect(s.framesSeen == 21)
        #expect(s.framesSkipped == 19)
        #expect(s.framesInferred == 2)
        #expect(await vision.calls == 2)
    }

    @Test func dropsFramesWhileBusyAndRecoversMotion() async {
        var config = FrameDeltaConfig()
        config.cooldown = 0
        config.idleRefresh = nil
        let vision = SlowVision(delay: 0.2)
        let box = ResultBox()
        let p = PerceptionPipeline(vision: vision, delta: FrameDeltaEngine(config: config)) { _, t in await box.add(t) }

        p.submit(CameraFrame(pixelBuffer: pixelBuffer(), timestamp: 0, index: 1)) // first frame -> infer (slow)
        p.submit(CameraFrame(pixelBuffer: pixelBuffer(square: true), timestamp: 0.03, index: 2)) // motion, busy -> dropped
        #expect(p.stats.framesDroppedBusy == 1)

        await waitUntil { await box.timings.count == 1 }
        // The dropped motion is not lost: the next frame is forced through.
        #expect(p.submit(CameraFrame(pixelBuffer: pixelBuffer(square: true), timestamp: 0.5, index: 3)) == .infer(.forced))
        await waitUntil { await box.timings.count == 2 }
        #expect(p.stats.computeSaved > 0)
    }

    @Test func timingIsConsistent() async throws {
        let box = ResultBox()
        let p = PerceptionPipeline(vision: SlowVision(delay: 0.01)) { _, t in await box.add(t) }
        p.submit(CameraFrame(pixelBuffer: pixelBuffer(), timestamp: 0, index: 1))
        await waitUntil { await box.timings.count == 1 }
        let t = try #require(await box.timings.first)
        #expect(t.totalMs >= t.inferenceMs)
        #expect(t.deltaMs < 5)
        await waitUntil { p.stats.totalP50Ms > 0 }
        #expect(p.stats.totalP50Ms >= t.totalMs)
    }
}

// MARK: - Plugins

@Suite struct BuiltInPluginTests {
    @Test func homeAssistantCallsService() async throws {
        let transport = StubTransport()
        let tools = HomeAssistantPlugin.tools(
            baseURL: URL(string: "http://ha.local:8123")!,
            entities: [HomeAssistantEntity(name: "microwave_start", doneSentence: "Microwave started.",
                                           entityId: "switch.microwave", service: "switch.turn_on", textContains: ["start"])],
            transport: transport, token: { "tok" })
        let registry = PluginRegistry()
        for t in tools { await registry.register(t) }

        let m = try #require(await registry.match(Detection(label: "text", confidence: 0.9, box: ImageRect(x: 0, y: 0, width: 0.1, height: 0.1),
                                                            kind: .text, text: "START")))
        #expect(m.sideEffect == .physical)
        #expect(try await registry.invoke(m) == "Microwave started.")

        let req = try #require(transport.requests.first)
        #expect(req.url?.absoluteString == "http://ha.local:8123/api/services/switch/turn_on")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: String]
        #expect(body == ["entity_id": "switch.microwave"])
    }

    @Test func homeAssistantErrorSurfaces() async {
        let transport = StubTransport { _ in (401, Data()) }
        let tool = HomeAssistantPlugin.tools(baseURL: URL(string: "http://ha.local")!,
                                             entities: [HomeAssistantEntity(name: "x", doneSentence: "ok", entityId: "light.a", service: "light.turn_on")],
                                             transport: transport, token: { nil })[0]
        await #expect(throws: HTTPStatusError(status: 401)) { try await tool.handler([:]) }
    }

    @Test func caregiverAlertQueuesOfflineAndDeliversLater() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outbox = dir.appendingPathComponent("outbox.json")
        let transport = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        let alerts = CaregiverAlerts(webhook: URL(string: "https://care.example/alerts")!, transport: transport,
                                     outboxURL: outbox, signingSecret: "s3cret")

        // Offline: the tool must not claim the carer was told.
        let tool = await alerts.tool
        await #expect(throws: CaregiverAlertQueued()) { try await tool.handler(["region": "home"]) }
        #expect(await alerts.pending == 1)

        // Survives a relaunch.
        let relaunched = CaregiverAlerts(webhook: URL(string: "https://care.example/alerts")!, transport: transport,
                                         outboxURL: outbox, signingSecret: "s3cret")
        #expect(await relaunched.pending == 1)

        // Back online: delivered once, signed, with an idempotency key.
        transport.respond { _ in (200, Data()) }
        await relaunched.flush()
        #expect(await relaunched.pending == 0)
        let sent = try #require(transport.requests.last)
        #expect(sent.value(forHTTPHeaderField: "Idempotency-Key") != nil)
        #expect(sent.value(forHTTPHeaderField: "X-EchoGuide-Signature")?.hasPrefix("sha256=") == true)
    }

    @Test func signatureIsStableHMAC() {
        // RFC 4231-style sanity: same input, same output, 64 hex chars.
        let a = CaregiverAlerts.signature(Data("x".utf8), secret: "k")
        #expect(a == CaregiverAlerts.signature(Data("x".utf8), secret: "k"))
        #expect(a.count == "sha256=".count + 64)
        #expect(a != CaregiverAlerts.signature(Data("y".utf8), secret: "k"))
    }

    @Test func productLookupParsesAndCaches() async {
        let json = #"{"status":1,"product":{"product_name":"Baked Beans","brands":"Heinz, Kraft","allergens_tags":["en:gluten","en:milk"]}}"#
        let transport = StubTransport { _ in (200, Data(json.utf8)) }
        let plugin = ProductLookupPlugin(transport: transport)
        #expect(await plugin.describe("5000157024671") == "Heinz Baked Beans. Contains gluten, milk.")
        _ = await plugin.describe("5000157024671")
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].value(forHTTPHeaderField: "User-Agent")?.hasPrefix("EchoGuide") == true)
    }

    @Test func qrCodesNeverLeaveTheDevice() async {
        let transport = StubTransport()
        let plugin = ProductLookupPlugin(transport: transport)
        #expect(await plugin.describe("https://example.com/menu") == "QR code for example.com.")
        #expect(await plugin.describe("hello") == "This code is not a product barcode.")
        #expect(transport.requests.isEmpty)
    }

    @Test func anyBarcodeClaim() {
        let d = Detection(label: "barcode", confidence: 0.9, box: ImageRect(x: 0, y: 0, width: 0.1, height: 0.1), kind: .barcode, text: "123")
        #expect(ToolClaim(anyBarcode: true).claims(d))
        #expect(!ToolClaim().claims(d))
    }
}

@Suite struct ManifestTests {
    let json = #"""
    {
      "homeAssistant": { "baseURL": "http://homeassistant.local:8123", "tokenSecret": "ha_token",
        "entities": [ { "name": "microwave_start", "doneSentence": "Microwave started.",
                        "entityId": "switch.microwave", "service": "switch.turn_on",
                        "textContains": ["start"], "sideEffect": "physical" } ] },
      "caregiver": { "webhookURL": "https://care.example.com/alerts", "signingSecret": "care_hmac" },
      "productLookup": true,
      "remoteServers": [ { "endpoint": "http://127.0.0.1:9/mcp" } ]
    }
    """#

    @Test func installsEveryToolAndReportsDeadRemotes() async throws {
        let manifest = try PluginManifest.load(Data(json.utf8))
        let registry = PluginRegistry()
        let secrets: SecretProvider = { ["ha_token": "t", "care_hmac": "h"][$0] }
        let installed = await registry.install(manifest, secrets: secrets, transport: StubTransport())
        #expect(await registry.toolNames == ["microwave_start", "notify_caregiver", "lookup_product"])
        #expect(installed.caregiver != nil)
        #expect(installed.failedRemotes == [URL(string: "http://127.0.0.1:9/mcp")!])
    }

    @Test func rejectsUnknownSideEffect() {
        let bad = json.replacingOccurrences(of: "\"physical\"", with: "\"explosive\"")
        #expect(throws: (any Error).self) { try PluginManifest.load(Data(bad.utf8)) }
    }
}
