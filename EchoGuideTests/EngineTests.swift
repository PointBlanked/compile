// Owner: Maxwell. Unit tests for the pure logic under every engine. Hardware
// paths (camera, ANE, LiDAR, actuator) are covered by on-device runs, not CI.

import Foundation
import Testing
@testable import EchoGuideAutomation
import EchoGuideContracts
@testable import EchoGuideInfra
import EchoGuideSpatial
import EchoGuideVision

// MARK: - Helpers

func lumaFrame(width: Int = 640, height: Int = 480, fill: UInt8 = 100, square: (x: Int, y: Int, size: Int, value: UInt8)? = nil) -> [UInt8] {
    var px = [UInt8](repeating: fill, count: width * height)
    if let s = square {
        for y in s.y..<min(height, s.y + s.size) {
            for x in s.x..<min(width, s.x + s.size) { px[y * width + x] = s.value }
        }
    }
    return px
}

func analyze(_ e: FrameDeltaEngine, _ px: [UInt8], t: TimeInterval, width: Int = 640, height: Int = 480) -> FrameDeltaDecision {
    px.withUnsafeBufferPointer { e.analyze(luma: $0, width: width, height: height, bytesPerRow: width, timestamp: t) }
}

func det(_ label: String, x: Float, y: Float, size: Float = 0.1, conf: Float = 0.9, kind: DetectionKind = .object, text: String? = nil) -> Detection {
    Detection(label: label, confidence: conf, box: ImageRect(x: x - size / 2, y: y - size / 2, width: size, height: size), kind: kind, text: text)
}

func tip(x: Float, y: Float) -> Detection { det("fingertip", x: x, y: y, size: 0.02, kind: .fingertip) }

func frame(_ d: [Detection], t: TimeInterval, index: UInt64 = 0) -> VisionFrameResult {
    VisionFrameResult(frameIndex: index, timestamp: t, detections: d, inferenceMs: 5)
}

actor RecordingHaptics: HapticCueing {
    var guides = 0, confirms = 0, warns = 0, stops = 0
    func guide(offset dx: Float, _ dy: Float, distanceMetres: Float?) async { guides += 1 }
    func confirm() async { confirms += 1 }
    func warn() async { warns += 1 }
    func stop() async { stops += 1 }
}

actor RecordingAudio: SpatialAudioCueing {
    var spoken: [String] = []
    var pings = 0
    func speak(_ text: String, azimuth: Float) async { spoken.append(text) }
    func ping(azimuth: Float, elevation: Float) async { pings += 1 }
}

struct FixedConnectivity: Connectivity {
    let online: Bool
    func isOnline() async -> Bool { online }
}

struct StubProvider: ReasoningProvider {
    var reply: String = "Microwave start button."
    var delay: TimeInterval = 0
    var fail = false
    func answer(_ q: ReasoningQuery, includeImage: Bool) async throws -> String {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if fail { throw URLError(.notConnectedToInternet) }
        return reply
    }
}

// MARK: - Maxwell: frame delta

@Suite struct FrameDeltaTests {
    @Test func staticSceneIsSkipped() {
        var config = FrameDeltaConfig()
        config.idleRefresh = nil
        let e = FrameDeltaEngine(config: config)
        let still = lumaFrame()
        #expect(analyze(e, still, t: 0) == .infer(.firstFrame))
        for i in 1...300 { #expect(analyze(e, still, t: Double(i) / 30) == .skip) }
        #expect(e.stats.skipRatio > 0.99)
    }

    @Test func objectEntryTriggers() {
        let e = FrameDeltaEngine()
        _ = analyze(e, lumaFrame(), t: 0)
        let entered = lumaFrame(square: (200, 150, 160, 230))
        guard case .infer(.motion(let f)) = analyze(e, entered, t: 0.5) else {
            Issue.record("expected motion")
            return
        }
        #expect(f > 0.04)
    }

    @Test func exposureShiftIsNotMotion() {
        var config = FrameDeltaConfig()
        config.idleRefresh = nil
        let e = FrameDeltaEngine(config: config)
        _ = analyze(e, lumaFrame(fill: 100), t: 0)
        #expect(analyze(e, lumaFrame(fill: 140), t: 0.5) == .skip)
    }

    @Test func cooldownLimitsTriggers() {
        let e = FrameDeltaEngine()
        _ = analyze(e, lumaFrame(), t: 0)
        _ = analyze(e, lumaFrame(square: (0, 0, 200, 250)), t: 1.0)
        #expect(analyze(e, lumaFrame(), t: 1.03) == .skip)
    }

    @Test func idleRefreshFires() {
        let e = FrameDeltaEngine()
        let still = lumaFrame()
        _ = analyze(e, still, t: 0)
        #expect(analyze(e, still, t: 1) == .skip)
        #expect(analyze(e, still, t: 3.1) == .infer(.idleRefresh))
    }

    @Test func benchmarkUnderBudget() {
        let e = FrameDeltaEngine()
        let a = lumaFrame(width: 1920, height: 1440), b = lumaFrame(width: 1920, height: 1440, square: (300, 300, 400, 200))
        var window = LatencyWindow(capacity: 500)
        for i in 0..<500 {
            _ = analyze(e, i % 2 == 0 ? a : b, t: Double(i) / 60, width: 1920, height: 1440)
            window.record(e.lastAnalysisMs)
        }
        // Debug build on a shared, parallel CI runner: p50 holds the 1 ms target,
        // p95 gets headroom for scheduler noise. Release on device is far lower.
        #expect(window.percentile(0.50) < 1.0)
        #expect(window.percentile(0.95) < 3.0)
    }
}

// MARK: - Maxwell + Bryan: vision geometry + digital fence

@Suite struct VisionAndFenceTests {
    @Test func visionBoxFlipsToTopLeft() {
        let r = VisionGeometry.topLeft(x: 0.1, y: 0.7, width: 0.2, height: 0.2)
        #expect(abs(r.y - 0.1) < 1e-6)
        #expect(abs(r.x - 0.1) < 1e-6)
    }

    @Test func fingerInsideHazardIsBreach() {
        let fence = SpatialFence.kitchenDefaults
        let f = frame([det("oven", x: 0.5, y: 0.5, size: 0.3), tip(x: 0.5, y: 0.5)], t: 0)
        #expect(fence.evaluate(f) == .breached(zone: "hob"))
    }

    @Test func fingerNearHazardIsApproach() {
        let fence = SpatialFence.kitchenDefaults
        let f = frame([det("oven", x: 0.5, y: 0.5, size: 0.3), tip(x: 0.69, y: 0.5)], t: 0)
        #expect(fence.evaluate(f) == .approaching(zone: "hob", metres: nil))
    }

    @Test func depthSeparatesOverlapFromContact() {
        let fence = SpatialFence.kitchenDefaults
        let f = frame([det("oven", x: 0.5, y: 0.5, size: 0.3), tip(x: 0.5, y: 0.5)], t: 0)
        // Hand 30 cm from the lens, oven 1.2 m away: overlapping on screen, not touching.
        guard case .approaching = fence.evaluate(f, handDepth: 0.3, zoneDepth: 1.2) else {
            Issue.record("expected approach, not breach")
            return
        }
    }

    @Test func noFingerNoEvent() {
        #expect(SpatialFence.kitchenDefaults.evaluate(frame([det("oven", x: 0.5, y: 0.5)], t: 0)) == nil)
    }

    @Test func locationFenceNeedsDwellAndIgnoresJitter() {
        let home = GeoCoordinate(latitude: 51.5145, longitude: -0.1165)
        var fence = LocationFence(areas: [SafeArea(name: "home", center: home, radiusMetres: 80)])
        #expect(fence.update(home, accuracyMetres: 10, at: 0) == nil)

        let away = GeoCoordinate(latitude: 51.5175, longitude: -0.1165) // ~330 m north
        #expect(fence.update(away, accuracyMetres: 300, at: 10) == nil) // bad fix ignored
        #expect(fence.update(away, accuracyMetres: 10, at: 20) == nil)
        #expect(fence.update(away, accuracyMetres: 10, at: 70) == .leftSafeArea(region: "home"))
        #expect(fence.update(away, accuracyMetres: 10, at: 90) == nil) // reported once
        #expect(fence.update(home, accuracyMetres: 10, at: 200) == .returnedToSafeArea(region: "home"))
    }
}

// MARK: - Bryan + Maxwell: haptics, depth, audio math

@Suite struct SpatialTests {
    @Test func alignedMeansConfirm() {
        #expect(HapticMapping.pulse(dx: 0.01, dy: 0.01) == nil)
    }

    @Test func closerIsFasterAndStronger() throws {
        let far = try #require(HapticMapping.pulse(dx: 0.4, dy: 0))
        let near = try #require(HapticMapping.pulse(dx: 0.06, dy: 0))
        #expect(near.interval < far.interval)
        #expect(near.intensity > far.intensity)
    }

    @Test func sharpnessEncodesVertical() throws {
        let up = try #require(HapticMapping.pulse(dx: 0, dy: -0.2))
        let down = try #require(HapticMapping.pulse(dx: 0, dy: 0.2))
        #expect(up.sharpness > down.sharpness)
    }

    @Test func depthMedianRejectsLowConfidenceAndOutliers() {
        let w = 4, h = 4
        var depth = [Float32](repeating: 1.0, count: w * h)
        depth[5] = 9.0 // spike
        var conf = [UInt8](repeating: 2, count: w * h)
        conf[6] = 0
        depth[6] = 0.1 // low-confidence garbage
        let v = depth.withUnsafeBufferPointer { d in
            conf.withUnsafeBufferPointer { c in
                DepthSampler.sample(depth: d, confidence: c, width: w, height: h, rowStride: w, confidenceRowStride: w,
                                    at: ImagePoint(x: 0.3, y: 0.3))
            }
        }
        #expect(v == 1.0)
    }

    @Test func uprightToSensorMapping() {
        // Upright top-right is the sensor's top-left for a portrait back camera.
        #expect(DepthSampler.sensorPoint(fromUpright: ImagePoint(x: 1, y: 0)) == ImagePoint(x: 0, y: 0))
    }

    @Test func azimuthClamps() {
        #expect(SpatialAudioMath.azimuth(forOffsetX: 5) == .pi / 2)
        #expect(SpatialAudioMath.azimuth(forOffsetX: 0) == 0)
    }
}

// MARK: - Bryan: cognitive isolation + automation

@Suite struct CognitiveTests {
    @Test func picksOneAndSettles() {
        var iso = CognitiveTaskIsolation()
        let dets = [det("cup", x: 0.2, y: 0.2), det("button", x: 0.55, y: 0.5), det("chair", x: 0.5, y: 0.5, size: 0.5)]
        #expect(iso.isolate(frame(dets, t: 0)) == nil)
        #expect(iso.isolate(frame(dets, t: 0.1)) == nil)
        let step = iso.isolate(frame(dets, t: 0.2))
        #expect(step?.targetLabel == "button")
    }

    @Test func stickyAgainstSmallRivals() {
        var config = CognitiveConfig()
        config.settleFrames = 1
        var iso = CognitiveTaskIsolation(config: config)
        _ = iso.isolate(frame([det("button", x: 0.6, y: 0.5)], t: 0))
        let step = iso.isolate(frame([det("button", x: 0.6, y: 0.5), det("dial", x: 0.55, y: 0.5)], t: 0.1))
        #expect(step?.targetLabel == "button")
    }

    @Test func goalFiltersByText() {
        var config = CognitiveConfig()
        config.settleFrames = 1
        var iso = CognitiveTaskIsolation(config: config, goal: "start")
        let dets = [det("text", x: 0.3, y: 0.3, kind: .text, text: "STOP"), det("text", x: 0.7, y: 0.7, kind: .text, text: "START")]
        #expect(iso.isolate(frame(dets, t: 0))?.instruction.hasPrefix("START") == true)
    }

    @Test func oneDirectionAtATime() {
        #expect(CognitiveTaskIsolation.direction(dx: 0.3, dy: -0.1) == "Move right")
        #expect(CognitiveTaskIsolation.direction(dx: 0.02, dy: -0.1) == "Move up a little")
    }

    @Test func instructionsAreShort() {
        #expect(CognitiveTaskIsolation.clip("one two three four five six seven eight nine ten", words: 8).split(separator: " ").count == 8)
    }
}

@Suite struct AutomationTests {
    func engine(tools: ToolInvoking? = nil, router: ReasoningRouting? = nil) -> (AutomationEngine, RecordingHaptics, RecordingAudio) {
        var c = CognitiveConfig()
        c.settleFrames = 1
        let h = RecordingHaptics(), a = RecordingAudio()
        return (AutomationEngine(haptics: h, audio: a, router: router, tools: tools, cognitive: CognitiveTaskIsolation(config: c)), h, a)
    }

    @Test func guidesThenCompletesOnDwellAndCallsTool() async throws {
        let registry = PluginRegistry()
        await registry.register(ToolDescriptor(name: "microwave_start", description: "Start the microwave", sideEffect: .physical,
                                               claim: ToolClaim(labels: ["start button"])) { _ in "Microwave started." })
        let (e, h, a) = engine(tools: registry)
        await e.start()

        await e.ingest(frame([det("start button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 0))
        guard case .guiding = await e.state else { Issue.record("expected guiding"); return }
        #expect(await h.guides == 1)
        #expect(await a.spoken.first == "Start button. Move right.")

        await e.ingest(frame([det("start button", x: 0.7, y: 0.5), tip(x: 0.7, y: 0.5)], t: 0.5))
        guard case .onTarget = await e.state else { Issue.record("expected onTarget"); return }

        await e.ingest(frame([det("start button", x: 0.7, y: 0.5), tip(x: 0.7, y: 0.5)], t: 1.4))
        #expect(await e.state == .completed("Microwave started."))
        #expect(await a.spoken.contains("Microwave started."))
    }

    @Test func noToolCallWithoutDwell() async {
        let registry = PluginRegistry()
        let fired = Counter()
        await registry.register(ToolDescriptor(name: "go", description: "", sideEffect: .physical, claim: ToolClaim(labels: ["button"])) { _ in
            await fired.inc()
            return "ok"
        })
        let (e, _, _) = engine(tools: registry)
        await e.start()
        await e.ingest(frame([det("button", x: 0.5, y: 0.5), tip(x: 0.5, y: 0.5)], t: 0))
        await e.ingest(frame([det("button", x: 0.5, y: 0.5), tip(x: 0.5, y: 0.5)], t: 0.3))
        #expect(await fired.value == 0)
    }

    @Test func fenceBreachPreemptsGuidance() async {
        let (e, h, a) = engine()
        await e.start()
        await e.ingest(frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 0), fence: .breached(zone: "hob"))
        #expect(await e.state == .warning("hob"))
        #expect(await h.warns == 1)
        #expect(await h.guides == 0)
        #expect(await a.spoken == ["Stop. Hob."])
    }

    @Test func lowConfidenceAsksTheRouter() async {
        let router = CloudReasoningRouter(provider: StubProvider(reply: "Defrost dial."), connectivity: FixedConnectivity(online: true))
        let (e, _, a) = engine(router: router)
        await e.start()
        await e.ingest(frame([det("dial", x: 0.7, y: 0.5, conf: 0.5), tip(x: 0.4, y: 0.5)], t: 0))
        #expect(await a.spoken == ["Defrost dial."])
    }
}

actor Counter {
    var value = 0
    func inc() { value += 1 }
}

// MARK: - Maxwell: router + plugins

@Suite struct RouterTests {
    let query = ReasoningQuery(question: "What is it?", detections: [det("dial", x: 0.5, y: 0.5, conf: 0.6)], localConfidence: 0.6)

    @Test func highConfidenceStaysLocal() async {
        let r = CloudReasoningRouter(provider: StubProvider(), connectivity: FixedConnectivity(online: true))
        var q = query
        q.localConfidence = 0.9
        #expect(await r.resolve(q).source == .local)
    }

    @Test func airplaneModeFallsBackLocally() async {
        let r = CloudReasoningRouter(provider: StubProvider(), connectivity: FixedConnectivity(online: false))
        let out = await r.resolve(query)
        #expect(out.source == .localFallback)
        #expect(out.answer == "This looks like dial.")
    }

    @Test func lowConfidenceGoesToCloud() async {
        let r = CloudReasoningRouter(provider: StubProvider(), connectivity: FixedConnectivity(online: true))
        let out = await r.resolve(query)
        #expect(out.source == .cloud)
        #expect(out.answer == "Microwave start button.")
    }

    @Test func timeoutFallsBack() async {
        var c = CloudRouterConfig()
        c.timeout = 0.05
        let r = CloudReasoningRouter(config: c, provider: StubProvider(delay: 1), connectivity: FixedConnectivity(online: true))
        let out = await r.resolve(query)
        #expect(out.source == .localFallback)
        #expect(out.latencyMs < 500)
    }

    @Test func breakerOpensAfterFailures() async {
        var c = CloudRouterConfig()
        c.breakerFailures = 2
        let r = CloudReasoningRouter(config: c, provider: StubProvider(fail: true), connectivity: FixedConnectivity(online: true))
        for _ in 0..<3 { _ = await r.resolve(query) }
        #expect(await r.latency.count == 0)
    }
}

@Suite struct PluginTests {
    func registry() async -> PluginRegistry {
        let r = PluginRegistry()
        await r.register(ToolDescriptor(name: "lookup_barcode", description: "Product lookup", sideEffect: .none,
                                        claim: ToolClaim(barcodePrefixes: ["50"]), parameters: ["text"]) { args in
            "Product \(args["text"] ?? "")"
        })
        return r
    }

    @Test func matchesBarcodeAndInvokes() async throws {
        let r = await registry()
        let m = try #require(await r.match(det("barcode", x: 0.5, y: 0.5, kind: .barcode, text: "5012345678900")))
        #expect(m.arguments["text"] == "5012345678900")
        #expect(try await r.invoke(m) == "Product 5012345678900")
    }

    @Test func mcpToolsList() async throws {
        let r = await registry()
        let req = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let data = try #require(await r.handle(Data(req.utf8)))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let tools)? = json["result"]?["tools"] else { Issue.record("no tools"); return }
        #expect(tools.first?["name"]?.stringValue == "lookup_barcode")
        #expect(tools.first?["inputSchema"]?["type"]?.stringValue == "object")
    }

    @Test func mcpToolsCall() async throws {
        let r = await registry()
        let req = #"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"lookup_barcode","arguments":{"text":"50"}}}"#
        let json = try JSONDecoder().decode(JSONValue.self, from: try #require(await r.handle(Data(req.utf8))))
        guard case .array(let content)? = json["result"]?["content"] else { Issue.record("no content"); return }
        #expect(content.first?["text"]?.stringValue == "Product 50")
        #expect(json["result"]?["isError"] == .bool(false))
    }

    @Test func mcpUnknownMethod() async throws {
        let r = await registry()
        let json = try JSONDecoder().decode(JSONValue.self, from: try #require(await r.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"nope"}"#.utf8))))
        #expect(json["error"]?["code"] == .number(-32601))
    }
}
