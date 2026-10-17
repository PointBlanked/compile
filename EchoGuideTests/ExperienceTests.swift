// Owner: Bryan. Tests for the experience + safety layer: automation state
// machine, cognitive isolation, haptic mapping, and the digital fence. Shares
// the helpers (det, tip, frame, RecordingHaptics, RecordingAudio) defined in
// EngineTests.swift.

import Foundation
import Testing
@testable import EchoGuideAutomation
import EchoGuideContracts
@testable import EchoGuideInfra
import EchoGuideSpatial
import EchoGuideVision

/// Depth stub keyed by label: the hand and each zone get their own distance.
struct TableDepth: DepthProviding {
    var byPoint: [(ImagePoint, Float)]
    func depth(at point: ImagePoint) async -> Float? {
        byPoint.first { $0.0.distance(to: point) < 0.02 }?.1
    }
}

@Suite struct FenceDepthTests {
    @Test func eachZoneGetsItsOwnDepth() async {
        // Hob and knife overlap the finger on screen. Hob is 1.2 m away, the
        // knife is 0.4 m away, the hand 0.3 m: only the knife is a breach.
        let fence = SpatialFence.kitchenDefaults
        let hob = det("oven", x: 0.5, y: 0.5, size: 0.3)
        let knife = det("knife", x: 0.3, y: 0.3, size: 0.1)
        let f = frame([hob, knife, tip(x: 0.3, y: 0.3)], t: 0)
        let depth = TableDepth(byPoint: [(hob.box.mid, 1.2), (knife.box.mid, 0.4), (ImagePoint(x: 0.3, y: 0.3), 0.3)])
        #expect(await fence.evaluate(f, depth: depth) == .breached(zone: "knife"))
    }

    @Test func farZoneOverlapIsOnlyAnApproach() async {
        let fence = SpatialFence.kitchenDefaults
        let hob = det("oven", x: 0.5, y: 0.5, size: 0.3)
        let f = frame([hob, tip(x: 0.42, y: 0.5)], t: 0) // inside the hob box
        let depth = TableDepth(byPoint: [(hob.box.mid, 1.2), (ImagePoint(x: 0.42, y: 0.5), 0.3)])
        guard case .approaching(let zone, let metres) = await fence.evaluate(f, depth: depth) else {
            Issue.record("expected approach"); return
        }
        #expect(zone == "hob")
        #expect(metres.map { abs($0 - 0.9) < 1e-5 } == true)
    }

    @Test func unknownDepthFallsBackToTwoD() async {
        let fence = SpatialFence.kitchenDefaults
        let f = frame([det("oven", x: 0.5, y: 0.5, size: 0.3), tip(x: 0.5, y: 0.5)], t: 0)
        #expect(await fence.evaluate(f, depth: nil) == .breached(zone: "hob"))
        #expect(await fence.evaluate(f, depth: TableDepth(byPoint: [])) == .breached(zone: "hob"))
    }

    @Test func fixedRegionZone() {
        let fence = SpatialFence(zones: [SpatialFenceZone(name: "stairs", anchor: .region(ImageRect(x: 0, y: 0.8, width: 1, height: 0.2)))])
        #expect(fence.evaluate(frame([tip(x: 0.5, y: 0.9)], t: 0)) == .breached(zone: "stairs"))
        #expect(fence.evaluate(frame([tip(x: 0.5, y: 0.75)], t: 0)) == .approaching(zone: "stairs", metres: nil))
        #expect(fence.evaluate(frame([tip(x: 0.5, y: 0.5)], t: 0)) == nil)
    }

}

@Suite struct CognitiveIsolationTests {
    @Test func reportsWhenTheTargetVanishes() {
        var c = CognitiveConfig()
        c.settleFrames = 1
        var iso = CognitiveTaskIsolation(config: c)
        #expect(iso.isolate(frame([det("button", x: 0.6, y: 0.5)], t: 0)) != nil)
        #expect(iso.isCurrentVisible)
        // Dropped frame: the remembered step is still returned, but flagged.
        #expect(iso.isolate(frame([], t: 0.1))?.targetLabel == "button")
        #expect(!iso.isCurrentVisible)
    }

    @Test func excludedLabelDropsCurrentTarget() {
        var c = CognitiveConfig()
        c.settleFrames = 1
        var iso = CognitiveTaskIsolation(config: c)
        let dets = [det("start", x: 0.5, y: 0.5), det("stop", x: 0.2, y: 0.2)]
        #expect(iso.isolate(frame(dets, t: 0))?.targetLabel == "start")
        iso.excludedLabels = ["start"]
        #expect(iso.isolate(frame(dets, t: 0.1))?.targetLabel == "stop")
        iso.excludedLabels = []
        // "start" sits under the finger and is clearly better, so it wins back.
        #expect(iso.isolate(frame(dets, t: 0.2))?.targetLabel == "start")
    }
}

@Suite struct HapticEngineTests {
    @Test func confirmSilencesGuidance() async {
        // No actuator on the CI host: the engine still tracks its state.
        let h = SpatialHapticEngine()
        await h.guide(offset: 0.3, 0.1, distanceMetres: nil)
        #expect(await h.isGuiding)
        await h.confirm()
        #expect(await !h.isGuiding)
        await h.guide(offset: 0.3, 0.1, distanceMetres: nil)
        #expect(await h.isGuiding)
        await h.warn()
        #expect(await !h.isGuiding)
        await h.stop()
    }

    @Test func alignedGuideIsConfirmNotPulse() async {
        let h = SpatialHapticEngine()
        await h.guide(offset: 0.01, 0.01, distanceMetres: nil)
        #expect(await !h.isGuiding)
    }

    @Test func lidarWeakensDistantHand() throws {
        let near = try #require(HapticMapping.pulse(dx: 0.2, dy: 0, distanceMetres: 0.2))
        let far = try #require(HapticMapping.pulse(dx: 0.2, dy: 0, distanceMetres: 0.8))
        #expect(far.intensity < near.intensity)
        #expect(far.intensity >= 0.6 * 0.35) // floor keeps it feelable
    }
}

@Suite struct AutomationSafetyTests {
    func engine(tools: ToolInvoking? = nil, config: AutomationConfig = AutomationConfig()) -> (AutomationEngine, RecordingHaptics, RecordingAudio) {
        var c = CognitiveConfig()
        c.settleFrames = 1
        let h = RecordingHaptics(), a = RecordingAudio()
        return (AutomationEngine(haptics: h, audio: a, tools: tools, cognitive: CognitiveTaskIsolation(config: c), config: config), h, a)
    }

    func physicalTool(_ fired: Counter) async -> PluginRegistry {
        let registry = PluginRegistry()
        await registry.register(ToolDescriptor(name: "go", description: "", sideEffect: .physical, claim: ToolClaim(labels: ["button"])) { _ in
            await fired.inc()
            return "ok"
        })
        return registry
    }

    @Test func breachResetsTheDwell() async {
        let fired = Counter()
        let (e, h, _) = engine(tools: await physicalTool(fired))
        await e.start()
        let onIt = [det("button", x: 0.5, y: 0.5), tip(x: 0.5, y: 0.5)]
        await e.ingest(frame(onIt, t: 0))
        guard case .onTarget = await e.state else { Issue.record("expected onTarget"); return }
        // 0.5 s in, the hand strays into the hob zone.
        await e.ingest(frame(onIt, t: 0.5), fence: .breached(zone: "hob"))
        #expect(await e.state == .warning("hob"))
        #expect(await h.warns == 1)
        // 0.9 s after the first touch: without the reset this would fire.
        await e.ingest(frame(onIt, t: 0.9))
        #expect(await fired.value == 0)
        guard case .onTarget = await e.state else { Issue.record("expected onTarget again"); return }
        await e.ingest(frame(onIt, t: 1.8))
        #expect(await fired.value == 1)
    }

    @Test func vanishedTargetTimesOutToScanning() async {
        let (e, h, _) = engine()
        await e.start()
        await e.ingest(frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 0))
        guard case .guiding = await e.state else { Issue.record("expected guiding"); return }
        // Target gone, within the timeout: cue carries on, state unchanged.
        await e.ingest(frame([tip(x: 0.4, y: 0.5)], t: 0.5))
        guard case .guiding = await e.state else { Issue.record("expected still guiding"); return }
        #expect(await h.stops == 0)
        // Past the timeout: haptics silenced, back to scanning.
        await e.ingest(frame([tip(x: 0.4, y: 0.5)], t: 1.5))
        #expect(await e.state == .scanning)
        #expect(await h.stops == 1)
        // The target returning is announced afresh, not treated as "already said".
        await e.ingest(frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 2))
        guard case .guiding = await e.state else { Issue.record("expected guiding again"); return }
    }

    @Test func completedTargetMovesOnToTheNextStep() async {
        var config = AutomationConfig()
        config.completedCooldown = 5
        let (e, h, a) = engine(config: config)
        await e.start()
        let both = { (tipX: Float) in [det("start", x: 0.5, y: 0.5), det("stop", x: 0.2, y: 0.2, size: 0.08), tip(x: tipX, y: 0.5)] }
        await e.ingest(frame(both(0.5), t: 0))
        await e.ingest(frame(both(0.5), t: 1))
        #expect(await e.state == .completed("start"))
        #expect(await h.stops >= 1)
        // Finger still on the finished button: it is not offered again...
        await e.ingest(frame(both(0.5), t: 1.1))
        guard case .guiding(let step) = await e.state else { Issue.record("expected guiding to next"); return }
        #expect(step.targetLabel == "stop")
        #expect(await a.spoken.last?.hasPrefix("Stop.") == true)
        // ...until the cooldown has passed and nothing else is around.
        await e.ingest(frame([det("start", x: 0.5, y: 0.5), tip(x: 0.3, y: 0.5)], t: 7))
        guard case .guiding(let again) = await e.state else { Issue.record("expected guiding to start"); return }
        #expect(again.targetLabel == "start")
    }

    @Test func stopSilencesAndForgets() async {
        let (e, h, a) = engine()
        await e.start()
        await e.ingest(frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 0))
        await e.stop()
        #expect(await e.state == .idle)
        #expect(await h.stops == 1)
        await e.ingest(frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 1))
        #expect(await e.state == .idle)
        await e.start()
        await e.ingest(frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 2))
        // Spoken again after a restart.
        #expect(await a.spoken.count == 2)
    }
}

// MARK: - Tool failure, cadence

@Suite struct AutomationCadenceTests {
    func engine(tools: ToolInvoking? = nil) -> (AutomationEngine, RecordingHaptics, RecordingAudio) {
        var c = CognitiveConfig()
        c.settleFrames = 1
        let h = RecordingHaptics(), a = RecordingAudio()
        return (AutomationEngine(haptics: h, audio: a, tools: tools, cognitive: CognitiveTaskIsolation(config: c)), h, a)
    }




    @Test func failedToolCanBeRetriedAtOnce() async {
        struct Boom: Error {}
        let registry = PluginRegistry()
        let calls = Counter()
        await registry.register(ToolDescriptor(name: "go", description: "", sideEffect: .physical, claim: ToolClaim(labels: ["button"])) { _ in
            await calls.inc()
            if await calls.value == 1 { throw Boom() }
            return "Done."
        })
        let (e, _, a) = engine(tools: registry)
        await e.start()
        let onIt = [det("button", x: 0.5, y: 0.5), tip(x: 0.5, y: 0.5)]
        await e.ingest(frame(onIt, t: 0))
        await e.ingest(frame(onIt, t: 1))
        #expect(await e.state == .completed("button"))
        #expect(await a.spoken.last == "That did not work.")
        // Same button is offered again straight away; a fresh dwell fires it.
        await e.ingest(frame(onIt, t: 1.1))
        guard case .onTarget(let step) = await e.state else { Issue.record("expected onTarget for retry"); return }
        #expect(step.targetLabel == "button")
        await e.ingest(frame(onIt, t: 2))
        #expect(await e.state == .completed("Done."))
        #expect(await calls.value == 2)
    }

    @Test func approachWarningIsThrottled() async {
        let (e, h, a) = engine()
        await e.start()
        let f = { (t: TimeInterval) in frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: t) }
        await e.ingest(f(0), fence: .approaching(zone: "hob", metres: nil))
        await e.ingest(f(1), fence: .approaching(zone: "hob", metres: nil))
        #expect(await h.warns == 1)
        #expect(await a.spoken.filter { $0.hasPrefix("Careful") }.count == 1)
        // Guidance carries on underneath the caution.
        guard case .guiding = await e.state else { Issue.record("expected guiding"); return }
        await e.ingest(f(3.5), fence: .approaching(zone: "hob", metres: nil))
        #expect(await h.warns == 2)
    }

    @Test func instructionRepeatsOnlyAfterInterval() async {
        let (e, _, a) = engine()
        await e.start()
        let f = { (t: TimeInterval) in frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: t) }
        await e.ingest(f(0))
        await e.ingest(f(3))
        #expect(await a.spoken.count == 1)
        await e.ingest(f(6.5))
        #expect(await a.spoken.count == 2)
    }

    @Test func directionalPingKeepsItsCadence() async {
        let (e, _, a) = engine()
        await e.start()
        let f = { (t: TimeInterval) in frame([det("button", x: 0.8, y: 0.5), tip(x: 0.3, y: 0.5)], t: t) }
        await e.ingest(f(0))
        await e.ingest(f(0.3))
        await e.ingest(f(0.6))
        #expect(await a.pings == 1)
        await e.ingest(f(1.0))
        #expect(await a.pings == 2)
        // Target straight ahead: no sideways ping.
        await e.ingest(frame([det("button", x: 0.3, y: 0.2), tip(x: 0.3, y: 0.5)], t: 5))
        #expect(await a.pings == 2)
    }
}

// MARK: - Per-home fence configuration

@Suite struct FenceConfigTests {
    @Test func decodesHandWrittenJSON() throws {
        let json = """
        { "zones": [
            { "name": "hob", "anchor": { "label": "oven" }, "warningMargin": 0.1 },
            { "name": "stairs", "anchor": { "region": { "x": 0, "y": 0.8, "width": 1, "height": 0.2 } } }
          ] }
        """
        let c = try FenceConfig.load(from: Data(json.utf8))
        #expect(c.zones.count == 2)
        #expect(c.zones[0].anchor == .label("oven"))
        #expect(c.zones[0].warningMargin == 0.1)
        #expect(c.zones[1].anchor == .region(ImageRect(x: 0, y: 0.8, width: 1, height: 0.2)))
        #expect(c.zones[1].warningDepthMetres == 0.35) // default kept
        // The decoded zones behave like code-defined ones.
        let f = frame([tip(x: 0.5, y: 0.9)], t: 0)
        #expect(c.spatialFence.evaluate(f) == .breached(zone: "stairs"))
    }

    @Test func emptyConfigFallsBackToKitchenDefaults() throws {
        let c = try FenceConfig.load(from: Data("{}".utf8))
        #expect(c.spatialFence == SpatialFence.kitchenDefaults)
    }

    @Test func roundTrips() throws {
        let original = FenceConfig(
            zones: [SpatialFenceZone(name: "knife", anchor: .label("knife"), warningMargin: 0.05, warningDepthMetres: 0.2)])
        let data = try JSONEncoder().encode(original)
        #expect(try FenceConfig.load(from: data) == original)
    }

    @Test func anchorNeedsLabelOrRegion() {
        #expect(throws: DecodingError.self) {
            try FenceConfig.load(from: Data(#"{ "zones": [ { "name": "x", "anchor": {} } ] }"#.utf8))
        }
    }
}

// MARK: - Screen

@Suite struct GuidanceModelTests {
    @Test @MainActor func headlineMirrorsTheAudio() {
        let step = ActionStep(targetLabel: "start", instruction: "Start. Move right.", guidance: .align(dx: 0.3, dy: 0), target: nil)
        #expect(GuidanceModel(previewState: .guiding(step)).headline == "Start. Move right.")
        #expect(GuidanceModel(previewState: .guiding(step)).detail == "Follow the pulses")
        #expect(GuidanceModel(previewState: .onTarget(step)).detail == "Hold still")
        #expect(GuidanceModel(previewState: .completed("Microwave started.")).headline == "Done. Microwave started.")
        #expect(GuidanceModel(previewState: .warning("hob")).headline == "Stop. Hob")
        #expect(GuidanceModel(previewState: .warning("hob")).isWarning)
        #expect(GuidanceModel(previewState: .scanning, goal: "start").detail == "Looking for \"start\"")
        #expect(GuidanceModel(previewState: .idle).isPaused)
    }

    @Test @MainActor func arrowAgreesWithTheSpokenDirection() {
        let step = ActionStep(targetLabel: "start", instruction: "", guidance: .align(dx: 0.02, dy: -0.2), target: nil)
        #expect(GuidanceModel(previewState: .guiding(step)).arrowSymbol == "arrow.up")
        #expect(CognitiveTaskIsolation.direction(dx: 0.02, dy: -0.2).hasPrefix("Move up"))
        #expect(GuidanceModel.arrowSymbol(dx: 0.3, dy: 0.1) == "arrow.right")
        #expect(GuidanceModel.arrowSymbol(dx: -0.3, dy: 0.1) == "arrow.left")
        #expect(GuidanceModel.arrowSymbol(dx: 0, dy: 0.3) == "arrow.down")
        #expect(GuidanceModel.arrowSymbol(dx: 0.01, dy: 0.01) == nil)
        // Not guiding: no arrow.
        #expect(GuidanceModel(previewState: .onTarget(step)).arrowSymbol == nil)
    }
}

// MARK: - Voice: Kokoro provider, cache, priority, goal parsing

struct StubSpeech: SpeechSynthesizing {
    var fail = false
    var delay: TimeInterval = 0
    var calls: Counter? = nil
    func synthesize(_ text: String) async throws -> Data {
        await calls?.inc()
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if fail { throw SpeechProviderError.badStatus(500) }
        return WAVEncoder.pcm16Mono([Float](repeating: 0, count: 2400), sampleRate: 24_000)
    }
}

struct StubListener: GoalListening {
    var heard: String?
    func listen() async throws -> String? { heard }
}

@Suite struct SpeechProviderTests {
    @Test func kokoroRequestIsOpenAIShaped() throws {
        let p = KokoroSpeechProvider(baseURL: URL(string: "http://pi.local:8880")!, voice: "bf_emma", speed: 1.1)
        let r = p.request(for: "Start. Move right.")
        #expect(r.url?.absoluteString == "http://pi.local:8880/v1/audio/speech")
        #expect(r.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any]
        #expect(body?["model"] as? String == "kokoro")
        #expect(body?["input"] as? String == "Start. Move right.")
        #expect(body?["voice"] as? String == "bf_emma")
        #expect(body?["response_format"] as? String == "wav")
        #expect(body?["speed"] as? Double == 1.1)
    }

    @Test func kokoroReturnsAudioAndRejectsErrors() async throws {
        let wav = WAVEncoder.pcm16Mono([0, 0.5, -0.5], sampleRate: 24_000)
        func provider(status: Int, body: Data) -> KokoroSpeechProvider {
            KokoroSpeechProvider(baseURL: URL(string: "http://localhost:8880")!) { req in
                (body, HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        #expect(try await provider(status: 200, body: wav) .synthesize("hi") == wav)
        await #expect(throws: SpeechProviderError.badStatus(503)) { try await provider(status: 503, body: wav).synthesize("hi") }
        await #expect(throws: SpeechProviderError.emptyAudio) { try await provider(status: 200, body: Data()).synthesize("hi") }
    }

    @Test func kokoroGivesUpAfterTimeout() async {
        let p = KokoroSpeechProvider(baseURL: URL(string: "http://localhost:8880")!, timeout: 0.05) { req in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let t = FrameTimer()
        await #expect(throws: SpeechProviderError.timeout) { try await p.synthesize("hi") }
        #expect(t.elapsedMs < 1_000)
    }

    @Test func wavHeaderIsValid() {
        let d = WAVEncoder.pcm16Mono([0, 1, -1], sampleRate: 24_000)
        #expect(d.count == 44 + 6)
        #expect(String(decoding: d.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: d[8..<12], as: UTF8.self) == "WAVE")
        let rate = d[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: rate) == 24_000)
    }

    @Test func cacheEvictsLeastRecentlyUsed() async {
        let c = SpeechCache(capacity: 2)
        await c.put("a", Data([1])); await c.put("b", Data([2]))
        _ = await c.get("a") // a is now the most recent
        await c.put("c", Data([3]))
        #expect(await c.get("b") == nil)
        #expect(await c.get("a") == Data([1]))
        #expect(await c.get("c") == Data([3]))
        #expect(await c.count == 2)
    }

    @Test func urgencyPolicy() {
        #expect(SpeechPolicy.isUrgent("Stop. Hob."))
        #expect(SpeechPolicy.isUrgent("Careful. Knife is close."))
        #expect(SpeechPolicy.isUrgent("You have left home. Your carer has been told."))
        #expect(!SpeechPolicy.isUrgent("Start. Move right."))
        #expect(!SpeechPolicy.isUrgent("Microwave started."))
    }

    @Test func engineFallsBackToOnDeviceVoice() async {
        // Provider down: the phrase is still spoken, by the on-device voice.
        let down = SpatialAudioEngine(speech: StubSpeech(fail: true))
        await down.speak("Start. Move right.", azimuth: 0)
        #expect(await down.lastSpeechSource == .onDevice)
        #expect(await down.lastSpoken == "Start. Move right.")
        #expect(await down.cachedPhrases == 0)
        // No provider at all: same.
        let plain = SpatialAudioEngine()
        await plain.speak("Hold still", azimuth: 0)
        #expect(await plain.lastSpeechSource == .onDevice)
    }

    @Test func engineCachesSynthesizedPhrases() async {
        let calls = Counter()
        let e = SpatialAudioEngine(speech: StubSpeech(calls: calls))
        await e.prewarm(["Hold still", "Stop. Hob."])
        #expect(await calls.value == 2)
        #expect(await e.cachedPhrases == 2)
        await e.prewarm(["Hold still"]) // already cached
        #expect(await calls.value == 2)
        await e.speak("Hold still", azimuth: 0)
        #expect(await calls.value == 2) // served from cache
        await e.speak("Start. Move right.", azimuth: 0.3)
        #expect(await calls.value == 3)
        #expect(await e.cachedPhrases == 3)
    }

    @Test func goalParsingStripsFiller() {
        #expect(GoalPhraseParser.goal(from: "Find the start button") == "start button")
        #expect(GoalPhraseParser.goal(from: "Where's the microwave?") == "microwave")
        #expect(GoalPhraseParser.goal(from: "Hey EchoGuide, please press START") == "start")
        #expect(GoalPhraseParser.goal(from: "um, please") == nil)
        #expect(GoalPhraseParser.goal(from: "") == nil)
    }

    @Test func multiWordGoalMatchesAnyWord() {
        var c = CognitiveConfig()
        c.settleFrames = 1
        var iso = CognitiveTaskIsolation(config: c, goal: "start microwave")
        let dets = [det("cup", x: 0.5, y: 0.5), det("text", x: 0.7, y: 0.7, kind: .text, text: "START"), det("microwave", x: 0.2, y: 0.2, size: 0.4)]
        let step = iso.isolate(frame(dets, t: 0))
        #expect(step != nil)
        #expect(step?.targetLabel != "cup")
        // The parser's output drops into the goal unchanged.
        iso.goal = GoalPhraseParser.goal(from: "find the stop button")
        iso.reset()
        #expect(iso.isolate(frame([det("start", x: 0.5, y: 0.5), det("stop", x: 0.3, y: 0.3)], t: 1))?.targetLabel == "stop")
    }
}

// MARK: - Caution banner and mic button

@Suite struct CautionTests {
    @Test func engineReportsApproachAsCautionNotState() async {
        var c = CognitiveConfig()
        c.settleFrames = 1
        let e = AutomationEngine(haptics: RecordingHaptics(), audio: RecordingAudio(), cognitive: CognitiveTaskIsolation(config: c))
        await e.start()
        let f = { (t: TimeInterval) in frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: t) }
        await e.ingest(f(0), fence: .approaching(zone: "hob", metres: 0.2))
        #expect(await e.caution == "hob")
        guard case .guiding = await e.state else { Issue.record("expected guiding under the caution"); return }
        await e.ingest(f(0.1))
        #expect(await e.caution == nil)
        await e.ingest(f(0.2), fence: .approaching(zone: "knife", metres: nil))
        #expect(await e.caution == "knife")
        await e.stop()
        #expect(await e.caution == nil)
    }

    @Test func cautionStreamDeliversChanges() async {
        var c = CognitiveConfig()
        c.settleFrames = 1
        let e = AutomationEngine(haptics: RecordingHaptics(), audio: RecordingAudio(), cognitive: CognitiveTaskIsolation(config: c))
        await e.start()
        let stream = await e.cautions()
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == .some(nil)) // current value first
        await e.ingest(frame([tip(x: 0.4, y: 0.5)], t: 0), fence: .approaching(zone: "hob", metres: nil))
        #expect(await it.next() == .some("hob"))
    }

    @Test @MainActor func modelShowsCautionLineAndHearsGoal() async {
        let m = GuidanceModel(listener: StubListener(heard: "start button"))
        #expect(m.canListen)
        #expect(m.cautionLine == nil)
        #expect(GuidanceModel(previewState: .idle).canListen == false)
        m.listenForGoal()
        // The listening task hops through the main actor; yield until it lands.
        for _ in 0..<50 where m.isListening || m.goal == nil { await Task.yield() }
        #expect(m.goal == "start button")
        #expect(m.listenResult == "Heard: start button")
        #expect(!m.isListening)

        let silent = GuidanceModel(listener: StubListener(heard: nil))
        silent.listenForGoal()
        for _ in 0..<50 where silent.isListening { await Task.yield() }
        #expect(silent.goal == nil)
        #expect(silent.listenResult == "Did not catch that")
    }
}

// MARK: - Text identity, read-only tools, scanning heartbeat

@Suite struct PipelineBehaviourTests {
    func engine(tools: ToolInvoking? = nil, goal: String? = nil, config: AutomationConfig = AutomationConfig()) -> (AutomationEngine, RecordingHaptics, RecordingAudio) {
        var c = CognitiveConfig()
        c.settleFrames = 1
        let h = RecordingHaptics(), a = RecordingAudio()
        return (AutomationEngine(haptics: h, audio: a, tools: tools, cognitive: CognitiveTaskIsolation(config: c, goal: goal), config: config), h, a)
    }

    @Test func finishingOneTextButtonKeepsTheOthers() async {
        // Vision labels every OCR hit "text": START and STOP share a label.
        let (e, _, a) = engine()
        await e.start()
        let start = det("text", x: 0.5, y: 0.5, kind: .text, text: "START")
        let stop = det("text", x: 0.2, y: 0.2, size: 0.08, kind: .text, text: "STOP")
        await e.ingest(frame([start, stop, tip(x: 0.5, y: 0.5)], t: 0))
        #expect(await a.spoken.first == "START. You are on it.")
        await e.ingest(frame([start, stop, tip(x: 0.5, y: 0.5)], t: 1))
        #expect(await e.state == .completed("text"))
        // STOP is a different thing: still offered, and announced as new.
        await e.ingest(frame([start, stop, tip(x: 0.5, y: 0.5)], t: 1.1))
        guard case .guiding(let step) = await e.state else { Issue.record("expected guiding to STOP"); return }
        #expect(step.target?.text == "STOP")
        #expect(await a.spoken.last?.hasPrefix("STOP.") == true)
    }

    @Test func misreadTextAtTheSamePlaceIsNotReannounced() async {
        // Fast OCR reads the same button as START, STAR T, 5TART across frames.
        let (e, _, a) = engine()
        await e.start()
        let f = { (reading: String, t: TimeInterval) in
            frame([det("text", x: 0.7, y: 0.5, kind: .text, text: reading), tip(x: 0.4, y: 0.5)], t: t)
        }
        await e.ingest(f("START", 0))
        #expect(await a.spoken.count == 1)
        await e.ingest(f("STAR T", 0.1))
        await e.ingest(f("5TART", 0.2))
        await e.ingest(f("START", 0.3))
        #expect(await a.spoken.count == 1)
        // A different word somewhere else is new.
        await e.ingest(frame([det("text", x: 0.7, y: 0.5, kind: .text, text: "START"), det("text", x: 0.2, y: 0.2, size: 0.3, kind: .text, text: "STOP"), tip(x: 0.2, y: 0.2)], t: 0.4))
        #expect(await a.spoken.count == 2)
    }

    @Test func misreadVariantOfFinishedButtonStaysExcluded() async {
        let (e, _, _) = engine()
        await e.start()
        let start = { (reading: String) in det("text", x: 0.5, y: 0.5, kind: .text, text: reading) }
        let stop = det("text", x: 0.2, y: 0.2, size: 0.08, kind: .text, text: "STOP")
        await e.ingest(frame([start("START"), stop, tip(x: 0.5, y: 0.5)], t: 0))
        await e.ingest(frame([start("START"), stop, tip(x: 0.5, y: 0.5)], t: 1))
        #expect(await e.state == .completed("text"))
        // Next frame OCR misreads the finished button: still excluded, by place.
        await e.ingest(frame([start("5TART"), stop, tip(x: 0.5, y: 0.5)], t: 1.1))
        guard case .guiding(let step) = await e.state else { Issue.record("expected guiding to STOP"); return }
        #expect(step.target?.text == "STOP")
    }

    @Test func readOnlyToolFiresOnSightWithoutDwell() async {
        let registry = PluginRegistry()
        let looked = Counter()
        await registry.register(ToolDescriptor(name: "product_lookup", description: "", sideEffect: .none,
                                               claim: ToolClaim(anyBarcode: true), parameters: ["text"]) { args in
            await looked.inc()
            return "Oat milk. Contains oats."
        })
        let (e, h, a) = engine(tools: registry)
        await e.start()
        // No fingertip at all: the camera simply sees the barcode.
        let code = det("barcode", x: 0.6, y: 0.4, kind: .barcode, text: "5000112637922")
        await e.ingest(frame([code], t: 0))
        #expect(await looked.value == 1)
        #expect(await e.state == .completed("Oat milk. Contains oats."))
        #expect(await a.spoken == ["Oat milk. Contains oats."])
        #expect(await h.guides == 0)
        // Same barcode next frame: not looked up again during the cooldown.
        await e.ingest(frame([code], t: 0.5))
        #expect(await looked.value == 1)
        // A different barcode is a new product.
        await e.ingest(frame([det("barcode", x: 0.6, y: 0.4, kind: .barcode, text: "9999")], t: 1))
        #expect(await looked.value == 2)
    }

    @Test func physicalToolStillNeedsTheDwell() async {
        let registry = PluginRegistry()
        let fired = Counter()
        await registry.register(ToolDescriptor(name: "go", description: "", sideEffect: .physical, claim: ToolClaim(labels: ["button"])) { _ in
            await fired.inc(); return "ok"
        })
        let (e, _, _) = engine(tools: registry)
        await e.start()
        await e.ingest(frame([det("button", x: 0.6, y: 0.4)], t: 0)) // seen, no finger
        #expect(await fired.value == 0)
        guard case .guiding = await e.state else { Issue.record("expected guiding"); return }
    }

    @Test func scanningHeartbeat() async {
        var config = AutomationConfig()
        config.scanningReminderInterval = 5
        let (e, _, a) = engine(goal: "start", config: config)
        await e.start()
        await e.ingest(frame([tip(x: 0.5, y: 0.5)], t: 0))
        #expect(await a.spoken == ["Looking for start."])
        await e.ingest(frame([tip(x: 0.5, y: 0.5)], t: 3))
        #expect(await a.spoken.count == 1)
        await e.ingest(frame([tip(x: 0.5, y: 0.5)], t: 5.5))
        #expect(await a.spoken.count == 2)
        // A target silences the heartbeat.
        await e.ingest(frame([det("start", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 6))
        #expect(await a.spoken.last == "Start. Move right.")
        await e.ingest(frame([det("start", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 9))
        #expect(await a.spoken.count == 3)
    }

    @Test func stepKeyDistinguishesContentOnly() {
        #expect(det("button", x: 0, y: 0).stepKey == "button")
        #expect(det("text", x: 0, y: 0, kind: .text, text: "START").stepKey == "text|START")
        #expect(det("text", x: 0, y: 0, kind: .text, text: "STOP").stepKey != det("text", x: 0, y: 0, kind: .text, text: "START").stepKey)
    }

    @Test func streamingWAVHeaderIsCorrected() {
        // Kokoro-FastAPI writes 0xFFFFFFFF sizes because it streams; the
        // provider must hand AVAudioPlayer the real lengths.
        var wav = WAVEncoder.pcm16Mono([0, 0.5, -0.5, 1], sampleRate: 24_000)
        let good = wav
        for i in [4, 5, 6, 7, 40, 41, 42, 43] { wav[i] = 0xFF }
        #expect(wav != good)
        #expect(WAVEncoder.withCorrectSizes(wav) == good)
        #expect(WAVEncoder.withCorrectSizes(good) == good)
        #expect(WAVEncoder.withCorrectSizes(Data([1, 2, 3])) == Data([1, 2, 3]))
        // Sliced input (non-zero startIndex) works too.
        let sliced = (Data([9, 9]) + wav)[2...]
        #expect(WAVEncoder.withCorrectSizes(sliced) == good)
    }

    @Test func wavFromRawPCMMatchesFloatPath() {
        let floats: [Float] = [0, 0.5, -0.5, 1]
        var pcm = Data()
        for s in floats { withUnsafeBytes(of: Int16(s * 32767).littleEndian) { pcm.append(contentsOf: $0) } }
        #expect(WAVEncoder.pcm16Mono(pcm: pcm, sampleRate: 16_000) == WAVEncoder.pcm16Mono(floats, sampleRate: 16_000))
    }
}

// MARK: - Screen overlay geometry

@Suite struct HUDGeometryTests {
    @Test func portraitFeedFillsPhoneHeightAndCropsSides() {
        // 9:16 image on a 390x844 view: height-limited? 844/1 = 844 vs 390/0.5625 = 693 -> scale 844, width 474, cropped 42 px each side.
        let t = HUDGeometry.transform(viewSize: CGSize(width: 390, height: 844), imageAspect: 9.0 / 16.0)
        #expect(abs(t.scale - 844) < 0.01)
        #expect(abs(t.offsetY) < 0.01)
        #expect(t.offsetX < 0) // image wider than view: sides cropped
        #expect(abs(t.offsetX - (390 - 0.5625 * 844) / 2) < 0.01)
        // Image centre lands on view centre.
        let c = HUDGeometry.point(.center, viewSize: CGSize(width: 390, height: 844), imageAspect: 9.0 / 16.0)
        #expect(abs(c.x - 195) < 0.01)
        #expect(abs(c.y - 422) < 0.01)
    }

    @Test func squareViewCropsTopAndBottomOfPortraitImage() {
        let size = CGSize(width: 400, height: 400)
        let t = HUDGeometry.transform(viewSize: size, imageAspect: 3.0 / 4.0)
        // Width-limited: scale so image width (0.75) covers 400 -> 533.3; image height 533 > 400, cropped top and bottom.
        #expect(abs(t.scale - 400 / 0.75) < 0.01)
        #expect(abs(t.offsetX) < 0.01)
        #expect(t.offsetY < 0)
        let r = HUDGeometry.rect(ImageRect(x: 0, y: 0, width: 1, height: 1), viewSize: size, imageAspect: 3.0 / 4.0)
        #expect(abs(r.width - 400) < 0.01)
        #expect(abs(r.height - 533.33) < 0.1)
    }

    @Test func overlayFilterPerMode() {
        let cup = det("cup", x: 0.5, y: 0.5), start = det("text", x: 0.7, y: 0.5, kind: .text, text: "START")
        let code = det("barcode", x: 0.2, y: 0.2, kind: .barcode, text: "1"), tipD = tip(x: 0.1, y: 0.1), hand = det("hand", x: 0.1, y: 0.1)
        let all = [cup, start, code, tipD, hand]
        #expect(HUDFilter.all.visible(all, target: nil) == all)
        #expect(HUDFilter.text.visible(all, target: nil) == [start])
        #expect(HUDFilter.objects.visible(all, target: nil) == [cup, code, tipD, hand])
        // Find guiding to a text button: that one text box is shown, other text is not.
        let stop = det("text", x: 0.3, y: 0.8, kind: .text, text: "STOP")
        #expect(HUDFilter.objects.visible(all + [stop], target: start) == [cup, start, code, tipD, hand])
    }

    @Test func hudFrameHelpers() {
        let f = HUDFrame(detections: [det("cup", x: 0.5, y: 0.5), det("text", x: 0.2, y: 0.2, kind: .text, text: "A"), tip(x: 0.1, y: 0.1)], timestamp: 1, inferenceMs: 9)
        #expect(f.objects == 1)
        #expect(f.fingertip?.kind == .fingertip)
        #expect(HUDGeometry.transform(viewSize: .zero, imageAspect: 1).scale == 1)
    }
}

// MARK: - Scene intelligence policy

@Suite struct SceneIntelligenceTests {
    func objects(_ labels: [String], t: TimeInterval) -> VisionFrameResult {
        frame(labels.enumerated().map { i, l in det(l, x: 0.2 + Float(i) * 0.2, y: 0.5, conf: 0.9) }, t: t)
    }

    @Test func firstDescriptionWaitsForWarmupThenFiresOnce() {
        var s = SceneIntelligence()
        s.reset(at: 0)
        let warming = s.wantsScene(objects(["chair"], t: 1))
        let empty = s.wantsScene(objects([], t: 2.5))
        let first = s.wantsScene(objects(["chair"], t: 3))
        #expect(!warming)
        #expect(!empty)
        #expect(first)
        s.asked(at: 3, labels: ["chair"])
        let soon = s.wantsScene(objects(["chair"], t: 4))
        let sameLater = s.wantsScene(objects(["chair"], t: 30))
        #expect(!soon)
        #expect(!sameLater)
    }

    @Test func materialChangeAfterIntervalAsksAgain() {
        var s = SceneIntelligence()
        s.reset(at: 0)
        _ = s.wantsScene(objects(["chair", "laptop"], t: 3))
        s.asked(at: 3, labels: ["chair", "laptop"])
        let inside = s.wantsScene(objects(["chair", "microwave"], t: 10))     // inside the interval
        let halfTurnedOver = s.wantsScene(objects(["chair", "microwave"], t: 20)) // distance 2/3
        #expect(!inside)
        #expect(halfTurnedOver)
        s.asked(at: 20, labels: ["chair", "microwave"])
        let sameScene = s.wantsScene(objects(["microwave", "chair"], t: 40))
        let newRoom = s.wantsScene(objects(["bed", "tv"], t: 41))
        #expect(!sameScene)
        #expect(newRoom)
    }

    @Test func lowConfidenceAndSilentLabelsDoNotDefineTheScene() {
        let s = SceneIntelligence()
        let f = frame([det("chair", x: 0.5, y: 0.5, conf: 0.3), det("text", x: 0.2, y: 0.2, kind: .text, text: "EXIT"), tip(x: 0.1, y: 0.1), det("cup", x: 0.7, y: 0.5, conf: 0.8)], t: 0)
        #expect(s.labels(in: f) == ["cup"])
    }

    @Test func agentAsksTheRouterWithThePhotoAndSpeaksTheScene() async {
        struct SceneRouter: ReasoningRouting {
            let seen: Counter
            func resolve(_ q: ReasoningQuery) async -> ReasoningOutcome {
                if q.jpeg != nil { await seen.inc() }
                return ReasoningOutcome(answer: "A small kitchen. A red kettle sits on the white counter ahead.", source: .cloud, latencyMs: 900)
            }
        }
        let seen = Counter(), a = RecordingAudio()
        var cfg = SceneIntelligenceConfig()
        cfg.warmup = 0
        let agent = AgentCore(audio: a, haptics: RecordingHaptics(), router: SceneRouter(seen: seen), scene: cfg,
                              jpegProvider: { Data([0xFF, 0xD8]) }, clock: { 100 })
        await agent.setMode(.explore, announce: false)
        await agent.ingest(frame([det("kettle", x: 0.5, y: 0.5, conf: 0.9)], t: 0.1), fence: nil)
        await agent.ingest(frame([det("kettle", x: 0.5, y: 0.5, conf: 0.9)], t: 0.2), fence: nil)
        var spokenScene = false
        for _ in 0..<200 where !spokenScene {
            spokenScene = await a.spoken.contains { $0.hasPrefix("A small kitchen") }
            if !spokenScene { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        #expect(spokenScene)
        #expect(await seen.value == 1)
        #expect(await agent.stats.sceneDescriptions == 1)
    }
}

// MARK: - Multi-step physical tasks

@Suite struct TaskGuideTests {
    func hand(x: Float, y: Float, size: Float = 0.12) -> Detection { det("hand", x: x, y: y, size: size, conf: 0.8) }

    @Test func goalsThatAreTasks() {
        #expect(TaskPlan.parse("take a photo of the person") == .photo)
        #expect(TaskPlan.parse("Take a picture")?.steps.count == 4)
        #expect(TaskPlan.parse("grab the remote")?.name == "pick up the remote")
        #expect(TaskPlan.parse("start button") == nil)
        #expect(TaskPlan.parse("microwave") == nil)
    }

    @Test func wordingUsesTwoAxesLargerFirst() {
        #expect(TaskWording.direction(dx: 0.3, dy: 0.2) == "right and down")
        #expect(TaskWording.direction(dx: -0.1, dy: 0.3) == "down and left")
        #expect(TaskWording.direction(dx: 0.08, dy: 0.01) == "a little right")
        #expect(TaskWording.direction(dx: 0.01, dy: 0.01) == "a little closer")
        #expect(TaskWording.relative(dx: 0.3, dy: 0.2) == "to your right and below your hand")
        #expect(TaskGeometry.overlap(of: ImageRect(x: 0, y: 0, width: 1, height: 1), over: ImageRect(x: 0.5, y: 0, width: 1, height: 1)) == 0.5)
    }

    @Test func reachGraspOrientAimFinish() {
        var g = TaskGuide(plan: .photo)
        let phone = det("cell phone", x: 0.7, y: 0.6, size: 0.15, conf: 0.9)
        // Nothing seen: ask for the object, not the hand.
        #expect(g.step(frame([hand(x: 0.3, y: 0.3)], t: 0), now: 0) == [.speak("I cannot see the phone. Move the camera slowly.")])
        // Object but no hand.
        #expect(g.step(frame([phone], t: 0.1), now: 0.1) == [.speak("Show me your hand.")])
        // Both: first line says where it is relative to the hand, with haptics.
        let first = g.step(frame([phone, hand(x: 0.3, y: 0.3)], t: 0.2), now: 0.2)
        #expect(first.count == 2)
        #expect(first.contains(.speak("Phone to your right and below your hand.")))
        // Then movement words, not repeated every frame.
        let second = g.step(frame([phone, hand(x: 0.4, y: 0.4)], t: 0.3), now: 0.3)
        #expect(second.contains(.speak("Move right and down.")))
        let third = g.step(frame([phone, hand(x: 0.45, y: 0.45)], t: 0.4), now: 0.4)
        #expect(third == [.guide(dx: 0.25, dy: 0.15)] || third.count == 1)
        // Hand over the phone: hold, then grasp confirmed.
        #expect(g.step(frame([phone, hand(x: 0.7, y: 0.6)], t: 1), now: 1) == [.guide(dx: 0, dy: 0)])
        let grasped = g.step(frame([phone, hand(x: 0.7, y: 0.6)], t: 1.5), now: 1.5)
        #expect(grasped == [.confirm, .speak("Got it.")])
        #expect(g.progress.step == 2)
        // Orient: instruction, then after the wait a check for the model.
        #expect(g.step(frame([], t: 1.6), now: 1.6) == [.speak("Flip it so the lens faces away from you.")])
        #expect(g.step(frame([], t: 2), now: 2) == [])
        guard case .check? = g.step(frame([], t: 5), now: 5).first else { Issue.record("expected a check"); return }
        // Model says no once: re-prompt; then yes: advance.
        #expect(g.checkResult(false, now: 6) == [.speak("Not yet. Flip it so the lens faces away from you.")])
        guard case .check? = g.step(frame([], t: 10), now: 10).first else { Issue.record("expected a second check"); return }
        #expect(g.checkResult(true, now: 11) == [.speak("Good.")])
        #expect(g.progress.step == 3)
        // Aim at the person.
        let person = det("person", x: 0.6, y: 0.3, size: 0.4, conf: 0.9)
        let aim = g.step(frame([person, hand(x: 0.4, y: 0.6)], t: 12), now: 12)
        #expect(aim.contains(.speak("Person ahead. Point up and right.")))
        #expect(g.step(frame([person, hand(x: 0.6, y: 0.3)], t: 13), now: 13) == [.guide(dx: 0, dy: 0)])
        #expect(g.step(frame([person, hand(x: 0.6, y: 0.3)], t: 13.6), now: 13.6) == [.confirm, .speak("Lined up.")])
        // Finish.
        #expect(g.step(frame([], t: 14), now: 14) == [.done("Lined up. Hold still and press the shutter.")])
        #expect(g.isFinished)
    }

    @Test func noModelMeansOrientIsTrusted() {
        var g = TaskGuide(plan: TaskPlan(name: "t", steps: [.orient(instruction: "Turn it over.", check: nil), .finish(say: "Done.")]))
        #expect(g.step(frame([], t: 0), now: 0) == [.speak("Turn it over.")])
        #expect(g.step(frame([], t: 3.5), now: 3.5) == [.speak("Okay.")])
        #expect(g.step(frame([], t: 4), now: 4) == [.done("Done.")])
    }

    @Test func engineRunsAPlanFromTheGoal() async {
        let h = RecordingHaptics(), a = RecordingAudio()
        let e = AutomationEngine(haptics: h, audio: a)
        await e.start()
        await e.setGoal("grab the remote")
        #expect(await e.goal == "pick up the remote")
        #expect(await e.taskProgress?.of == 2)
        let remote = det("remote", x: 0.7, y: 0.5, size: 0.12, conf: 0.9)
        await e.ingest(frame([remote, det("hand", x: 0.3, y: 0.5, size: 0.12, conf: 0.8)], t: 0))
        #expect(await a.spoken.last == "Remote to your right.")
        #expect(await h.guides == 1)
        guard case .guiding(let step) = await e.state else { Issue.record("expected guiding"); return }
        #expect(step.instruction == "Remote to your right.")
        await e.ingest(frame([remote, det("hand", x: 0.7, y: 0.5, size: 0.12, conf: 0.8)], t: 1))
        await e.ingest(frame([remote, det("hand", x: 0.7, y: 0.5, size: 0.12, conf: 0.8)], t: 1.5))
        #expect(await a.spoken.last == "Got it.")
        #expect(await h.confirms == 1)
        await e.ingest(frame([remote], t: 1.6))
        #expect(await e.state == .completed("You have the remote."))
        #expect(await e.taskProgress == nil)
        // A plain goal afterwards returns to single-target Find.
        await e.setGoal("start")
        #expect(await e.goal == "start")
    }
}

// MARK: - Visual memory and text verification

@Suite struct MemoryAndVerifierTests {
    @Test func memoryRecallsWhereAndWhen() {
        var m = ObservationMemory()
        let first = m.record(frame([det("backpack", x: 0.2, y: 0.5, conf: 0.9), det("chair", x: 0.8, y: 0.5, conf: 0.8)], t: 10))
        let repeat_ = m.record(frame([det("backpack", x: 0.2, y: 0.5, conf: 0.9), det("chair", x: 0.8, y: 0.5, conf: 0.8)], t: 11)) // unchanged, too soon
        let changed = m.record(frame([det("chair", x: 0.8, y: 0.5, conf: 0.8)], t: 20))                                             // set changed
        #expect(first)
        #expect(!repeat_)
        #expect(changed)
        #expect(m.answer("where did you see my bag", now: 52) == "I saw a backpack about 40 seconds ago, on your left.")
        #expect(m.answer("have you seen a chair", now: 22) == "I saw a chair just now, on your right.")
        #expect(m.answer("where's my phone", now: 30) == "I have not seen a cell phone recently.")
        #expect(m.answer("what did you see", now: 30) == "In the last minute I saw a chair and a backpack.")
        #expect(ObservationMemory.isRecallQuestion("Where did you see my keys?"))
        #expect(ObservationMemory.isRecallQuestion("have you seen a cup"))
        #expect(!ObservationMemory.isRecallQuestion("find the start button"))
        #expect(ObservationMemory.ago(130) == "about 2 minutes ago")
    }

    @Test func memoryIgnoresNoiseAndKeepsText() {
        var m = ObservationMemory()
        let noise = m.record(frame([det("chair", x: 0.5, y: 0.5, conf: 0.3), tip(x: 0.1, y: 0.1), det("hand", x: 0.5, y: 0.5, conf: 0.9)], t: 0))
        let text = m.record(frame([det("text", x: 0.5, y: 0.5, conf: 0.9, kind: .text, text: "EXIT")], t: 1))
        #expect(!noise)
        #expect(text)
        #expect(m.answer("where did you see exit", now: 3) == "I read \"exit\" just now.")
    }

    @Test func localGateDropsNonsense() {
        #expect(TextVerifier.plausible("START"))
        #expect(TextVerifier.plausible("EXIT"))
        #expect(TextVerifier.plausible("TV"))
        #expect(TextVerifier.plausible("230"))
        #expect(TextVerifier.plausible("Push to open"))
        #expect(!TextVerifier.plausible("l|l1 ;;"))
        #expect(!TextVerifier.plausible("qzxvwkjp"))
        #expect(!TextVerifier.plausible("~"))
        #expect(!TextVerifier.plausible("##@@!!"))
        #expect(TextVerifier.gate(["START", "l|l1", "STOP"]) == ["START", "STOP"])
    }

    @Test func modelHandoffCorrectsAndCaches() async {
        struct FixingRouter: ReasoningRouting {
            let calls: Counter
            func resolve(_ q: ReasoningQuery) async -> ReasoningOutcome {
                await calls.inc()
                #expect(q.jpeg == nil)
                return ReasoningOutcome(answer: "START\nSTOP", source: .cloud, latencyMs: 400)
            }
        }
        let calls = Counter()
        let v = TextVerifier()
        let out = await v.verify(["STAR T", "5TOP", "l|l1"], router: FixingRouter(calls: calls))
        #expect(out == ["START", "STOP"])
        #expect(await calls.value == 1)
        _ = await v.verify(["STAR T", "5TOP", "l|l1"], router: FixingRouter(calls: calls))
        #expect(await calls.value == 1) // cached
        #expect(await v.verify(["@@@"], router: FixingRouter(calls: calls)).isEmpty)
        #expect(await calls.value == 1) // nothing worth asking
    }

    @Test func modelNoneAndOfflineFallBackCorrectly() async {
        struct NoneRouter: ReasoningRouting {
            func resolve(_ q: ReasoningQuery) async -> ReasoningOutcome { ReasoningOutcome(answer: "NONE", source: .cloud, latencyMs: 1) }
        }
        struct OfflineRouter: ReasoningRouting {
            func resolve(_ q: ReasoningQuery) async -> ReasoningOutcome { ReasoningOutcome(answer: "I am not sure what this is.", source: .localFallback, latencyMs: 1) }
        }
        #expect(await TextVerifier().verify(["STARTT"], router: NoneRouter()).isEmpty)
        #expect(await TextVerifier().verify(["START"], router: OfflineRouter()) == ["START"])
        #expect(await TextVerifier().verify(["START"], router: nil) == ["START"])
        // A rambling model is ignored in favour of the gated input.
        #expect(TextVerifier.parse("Sure! Here are the corrected lines:\nSTART\nSTOP\nDEFROST\nPOWER", fallback: ["START"]) == ["START"])
    }
}

// MARK: - Colour, motion and sign priority

@Suite struct AdvancedPerceptionTests {
    @Test func colourNames() {
        #expect(ColorNamer.name(r: 220, g: 30, b: 30) == "red")
        #expect(ColorNamer.name(r: 30, g: 60, b: 220) == "blue")
        #expect(ColorNamer.name(r: 40, g: 180, b: 60) == "green")
        #expect(ColorNamer.name(r: 240, g: 200, b: 30) == "yellow")
        #expect(ColorNamer.name(r: 245, g: 140, b: 20) == "orange")
        #expect(ColorNamer.name(r: 120, g: 70, b: 30) == "brown")
        #expect(ColorNamer.name(r: 250, g: 250, b: 250) == "white")
        #expect(ColorNamer.name(r: 128, g: 128, b: 128) == "grey")
        #expect(ColorNamer.name(r: 10, g: 10, b: 10) == "black")
        #expect(ColorNamer.dominant(["red", "red", "red", "grey"]) == "red")
        #expect(ColorNamer.dominant(["red", "blue", "green", "grey"]) == nil)
        let (r, g, b) = ColorNamer.rgb(y: 128, cb: 128, cr: 128)
        #expect(r == 128 && g == 128 && b == 128)
        #expect(ColorNamer.sensorPoint(fromUpright: ImagePoint(x: 1, y: 0)) == ImagePoint(x: 0, y: 0))
        #expect(Detection(label: "cup", confidence: 0.9, box: ImageRect(x: 0, y: 0, width: 0.1, height: 0.1), color: "red").describedLabel == "red cup")
    }

    @Test func fastMoverInterruptsAndNamesColour() {
        var n = SceneNarrator()
        // A bicycle crossing the frame quickly: settled on frame 2, fast by frame 3.
        var bike = Detection(label: "bicycle", confidence: 0.9, box: ImageRect(x: 0.05, y: 0.4, width: 0.15, height: 0.15), color: "red")
        _ = n.observe(frame([bike], t: 0))
        bike.box.x = 0.15
        _ = n.observe(frame([bike], t: 0.3))
        bike.box.x = 0.55
        let a = n.observe(frame([bike], t: 0.9))
        #expect(a?.kind == .motion)
        #expect(a?.urgent == true)
        #expect(a?.text == "A red bicycle, moving fast, ahead.")
        // Not repeated right away.
        bike.box.x = 0.8
        #expect(n.observe(frame([bike], t: 1.2)) == nil)
    }

    @Test func approachingThingIsCalledOut() {
        var n = SceneNarrator()
        var car = det("car", x: 0.5, y: 0.5, size: 0.2, conf: 0.9)
        _ = n.observe(frame([car], t: 0))
        _ = n.observe(frame([car], t: 0.3))
        car = det("car", x: 0.5, y: 0.5, size: 0.4, conf: 0.9) // box area x4 in 0.6 s
        let a = n.observe(frame([car], t: 0.9))
        #expect(a?.kind == .motion)
        #expect(a?.text == "A car, coming toward you, ahead.")
    }

    @Test func cameraMotionIsNotObjectMotion() {
        var n = SceneNarrator()
        // Panning: chair, table and a person all shift together. Nothing is announced as moving.
        func scene(_ shift: Float) -> [Detection] {
            [det("chair", x: 0.2 + shift, y: 0.5, conf: 0.9), det("dining table", x: 0.5 + shift, y: 0.6, size: 0.3, conf: 0.9), det("person", x: 0.8 + shift, y: 0.4, size: 0.3, conf: 0.9)]
        }
        _ = n.observe(frame(scene(0), t: 0))
        _ = n.observe(frame(scene(0.1), t: 0.3))
        let a = n.observe(frame(scene(0.4), t: 0.9))
        #expect(a?.kind != .motion)
        // A chair alone can never be "moving fast".
        var m = SceneNarrator()
        var chair = det("chair", x: 0.1, y: 0.5, conf: 0.9)
        _ = m.observe(frame([chair], t: 0)); chair = det("chair", x: 0.2, y: 0.5, conf: 0.9)
        _ = m.observe(frame([chair], t: 0.3)); chair = det("chair", x: 0.7, y: 0.5, conf: 0.9)
        #expect(m.observe(frame([chair], t: 0.9))?.kind != .motion)
        // Walking toward a table makes it grow: not "coming toward you".
        var w = SceneNarrator()
        _ = w.observe(frame([det("dining table", x: 0.5, y: 0.6, size: 0.2, conf: 0.9)], t: 0))
        _ = w.observe(frame([det("dining table", x: 0.5, y: 0.6, size: 0.25, conf: 0.9)], t: 0.3))
        #expect(w.observe(frame([det("dining table", x: 0.5, y: 0.6, size: 0.45, conf: 0.9)], t: 0.9))?.kind != .motion)
    }

    @Test func importantSignBeatsObjects() {
        var n = SceneNarrator()
        let dets = [det("chair", x: 0.3, y: 0.5, conf: 0.9), det("text", x: 0.8, y: 0.3, conf: 0.9, kind: .text, text: "EXIT")]
        // Signs need no settling: the very first frame reads the important one.
        let a = n.observe(frame(dets, t: 0))
        #expect(a?.kind == .text)
        #expect(a?.text == "Sign: EXIT.")
        #expect(a.map { $0.azimuth > 0 } == true) // pinged from the right
        #expect(SceneVocabulary.isImportantSign("Wet Floor"))
        #expect(!SceneVocabulary.isImportantSign("Oat milk"))
        // Then the chair, once settled and after the pacing gap (tracks expire after 1.5 s of absence).
        _ = n.observe(frame(dets, t: 1))
        _ = n.observe(frame(dets, t: 2))
        let b = n.observe(frame(dets, t: 3))
        #expect(b?.text == "A chair, on your left.")
    }

    @Test func staticSceneStaysQuiet() {
        var n = SceneNarrator()
        let dets = [det("chair", x: 0.3, y: 0.5, conf: 0.9)]
        _ = n.observe(frame(dets, t: 0))
        #expect(n.observe(frame(dets, t: 0.2))?.text == "A chair, on your left.")
        for t in stride(from: 1.0, to: 15.0, by: 0.5) { #expect(n.observe(frame(dets, t: t)) == nil) }
    }
}
