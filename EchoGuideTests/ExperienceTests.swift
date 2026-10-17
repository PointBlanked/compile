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

    @Test func hudFrameHelpers() {
        let f = HUDFrame(detections: [det("cup", x: 0.5, y: 0.5), det("text", x: 0.2, y: 0.2, kind: .text, text: "A"), tip(x: 0.1, y: 0.1)], timestamp: 1, inferenceMs: 9)
        #expect(f.objects == 1)
        #expect(f.fingertip?.kind == .fingertip)
        #expect(HUDGeometry.transform(viewSize: .zero, imageAspect: 1).scale == 1)
    }
}
