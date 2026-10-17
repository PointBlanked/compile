// Owner: Maxwell. The visual agent: proactive narration, reading, describe,
// mode routing, and the benchmark recorder.

import Foundation
import Testing
import EchoGuideContracts
@testable import EchoGuideInfra

private func obj(_ label: String, x: Float, y: Float = 0.5, size: Float = 0.2, conf: Float = 0.9) -> Detection {
    Detection(label: label, confidence: conf, box: ImageRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
}

private func txt(_ s: String, x: Float, y: Float, conf: Float = 0.9) -> Detection {
    Detection(label: "text", confidence: conf, box: ImageRect(x: x - 0.1, y: y - 0.02, width: 0.2, height: 0.04), kind: .text, text: s)
}

private func f(_ d: [Detection], _ t: TimeInterval) -> VisionFrameResult {
    VisionFrameResult(frameIndex: 0, timestamp: t, detections: d, inferenceMs: 5)
}

struct FixedDepth: DepthProviding {
    var metres: Float
    func depth(at point: ImagePoint) async -> Float? { metres }
}

final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    var now: TimeInterval { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

struct StubRouter: ReasoningRouting {
    var answer: String
    var source: ReasoningSource
    func resolve(_ query: ReasoningQuery) async -> ReasoningOutcome {
        ReasoningOutcome(answer: answer, source: source, latencyMs: 1)
    }
}

@Suite struct NarratorTests {
    @Test func namesSettledThingsOnceWithPlace() {
        var n = SceneNarrator()
        #expect(n.observe(f([obj("chair", x: 0.2)], 0)) == nil) // not settled yet
        let a = n.observe(f([obj("chair", x: 0.2)], 0.1))
        #expect(a?.text == "A chair, on your left.")
        #expect(a?.azimuth ?? 0 < 0)
        // Same chair later: silent (cooldown).
        #expect(n.observe(f([obj("chair", x: 0.2)], 5)) == nil)
    }

    @Test func mostSalientWins() {
        var n = SceneNarrator()
        let scene = [obj("cup", x: 0.5), obj("car", x: 0.8), obj("person", x: 0.4)]
        _ = n.observe(f(scene, 0))
        #expect(n.observe(f(scene, 0.1))?.text == "A car, on your right.")
    }

    @Test func pacedBetweenAnnouncements() {
        var n = SceneNarrator()
        let scene = [obj("car", x: 0.8), obj("person", x: 0.2)]
        _ = n.observe(f(scene, 0))
        #expect(n.observe(f(scene, 0.1)) != nil)
        #expect(n.observe(f(scene, 1.0)) == nil) // inside min gap
        #expect(n.observe(f(scene, 2.0)) == nil)
        #expect(n.observe(f(scene, 3.0))?.text == "A person, on your left.")
    }

    @Test func obstacleBreaksPacingAndIsUrgent() {
        var n = SceneNarrator()
        let scene = [obj("car", x: 0.8)]
        _ = n.observe(f(scene, 0))
        _ = n.observe(f(scene, 0.1))
        let a = n.observe(f([obj("chair", x: 0.5, size: 0.4)], 0.5), aheadMetres: 0.6)
        #expect(a?.kind == .obstacle)
        #expect(a?.urgent == true)
        #expect(a?.text == "Chair ahead, very close.")
    }

    @Test func distanceFromDepth() {
        var n = SceneNarrator()
        _ = n.observe(f([obj("person", x: 0.5)], 0), depths: [0: 2.2])
        #expect(n.observe(f([obj("person", x: 0.5)], 0.1), depths: [0: 2.2])?.text == "A person, ahead, about 2 meters.")
    }

    @Test func readsNewSignsWhenNothingElse() {
        var n = SceneNarrator()
        #expect(n.observe(f([txt("EXIT", x: 0.5, y: 0.2)], 0))?.text == "Sign: EXIT.")
        #expect(n.observe(f([txt("EXIT", x: 0.5, y: 0.2)], 10)) == nil)
    }

    @Test func ignoresLowConfidenceNoise() {
        var n = SceneNarrator()
        _ = n.observe(f([obj("dog", x: 0.5, conf: 0.3)], 0))
        #expect(n.observe(f([obj("dog", x: 0.5, conf: 0.3)], 0.1)) == nil)
    }
}

@Suite struct ReaderTests {
    @Test func readingOrder() {
        let frame = f([txt("World", x: 0.7, y: 0.3), txt("Hello", x: 0.3, y: 0.3), txt("Second line", x: 0.4, y: 0.6)], 0)
        #expect(TextReader.lines(in: frame) == ["Hello World", "Second line"])
    }

    @Test func doesNotRepeat() {
        var r = TextReader()
        let frame = f([txt("Best before 12 Nov", x: 0.5, y: 0.5)], 0)
        #expect(r.newLines(in: frame) == ["Best before 12 Nov"])
        #expect(r.newLines(in: f(frame.detections, 5)).isEmpty)
        #expect(r.newLines(in: f(frame.detections, 61)) == ["Best before 12 Nov"])
    }

    @Test func cleansNoise() {
        #expect(TextReader.clean("  ~~EXIT~~  ") == "EXIT")
        #expect(TextReader.clean("|||") == "")
    }
}

@Suite struct AgentCoreTests {
    func core(router: ReasoningRouting? = nil, depth: DepthProviding? = nil) -> (AgentCore, RecordingAudio, RecordingHaptics, ManualClock) {
        let a = RecordingAudio(), h = RecordingHaptics(), clock = ManualClock()
        return (AgentCore(audio: a, haptics: h, depth: depth, router: router, clock: { clock.now }), a, h, clock)
    }

    @Test func exploreSpeaksUnprompted() async {
        let (c, a, _, _) = core()
        await c.ingest(f([obj("person", x: 0.5)], 0), fence: nil)
        await c.ingest(f([obj("person", x: 0.5)], 0.1), fence: nil)
        #expect(await a.spoken == ["A person, ahead."])
    }

    @Test func findHandsFramesToAutomation() async {
        let (c, a, _, _) = core()
        await c.setMode(.find, announce: false)
        #expect(await c.ingest(f([obj("person", x: 0.5)], 0), fence: .breached(zone: "hob")) == true)
        #expect(await a.spoken.isEmpty) // AutomationEngine owns speech and fence in Find
    }

    @Test func fenceWarnsInExplore() async {
        let (c, a, h, _) = core()
        await c.ingest(f([], 0), fence: .breached(zone: "hob"))
        #expect(await a.spoken == ["Stop. Hob."])
        #expect(await h.warns == 1)
    }

    @Test func obstacleWithLiDAR() async {
        let (c, a, h, _) = core(depth: FixedDepth(metres: 0.7))
        await c.ingest(f([], 0), fence: nil)
        #expect(await a.spoken == ["Obstacle ahead, very close."])
        #expect(await h.warns == 1)
    }

    @Test func readModeReadsOnce() async {
        let (c, a, _, clock) = core()
        await c.setMode(.read, announce: false)
        let page = [txt("Dear Maxwell", x: 0.4, y: 0.2)]
        await c.ingest(f(page, 0), fence: nil)
        clock.advance(10)
        await c.ingest(f(page, 1), fence: nil)
        #expect(await a.spoken == ["Dear Maxwell"])
    }

    @Test func describeUsesCloudWhenAvailable() async {
        let (c, a, _, _) = core(router: StubRouter(answer: "A kitchen counter with a kettle on the left.", source: .cloud))
        await c.ingest(f([obj("oven", x: 0.5)], 0), fence: nil)
        #expect(await c.describe(jpeg: Data([1])) == "A kitchen counter with a kettle on the left.")
        #expect(await a.spoken.last == "A kitchen counter with a kettle on the left.")
        #expect(await c.stats.describeCloud == 1)
    }

    @Test func describeFallsBackToLocalSummaryOffline() async {
        let (c, _, _, _) = core(router: StubRouter(answer: "This might be oven.", source: .localFallback))
        await c.ingest(f([obj("oven", x: 0.5), obj("person", x: 0.1), txt("BAKE", x: 0.5, y: 0.8)], 0), fence: nil)
        let said = await c.describe(jpeg: nil)
        #expect(said == "Ahead: an oven. On your left: a person. Text: BAKE.")
        #expect(await c.stats.describeLocal == 1)
    }

    @Test func describeBeforeCameraIsHonest() async {
        let (c, _, _, _) = core()
        #expect(await c.describe(jpeg: nil).hasPrefix("The camera is still starting"))
    }
}

@Suite struct TrialRecorderTests {
    @Test func recordsAndExportsCSV() async {
        let r = TrialRecorder()
        await r.start(task: "Find start", mode: "find", offline: true)
        await r.notePrompt()
        await r.noteSpoken()
        await r.noteSpoken()
        let result = await r.finish(success: true, notes: "fast, \"clean\"")
        #expect(result?.spokenLines == 2)
        #expect(result?.userPrompts == 1)
        #expect(result?.firstCueMs != nil)
        let csv = await r.csv
        #expect(csv.hasPrefix(TrialResult.csvHeader))
        #expect(csv.contains("\"fast, \"\"clean\"\"\""))
        #expect(csv.contains(",1,")) // success / offline flags
    }

    @Test func taskBatteryIsStable() {
        #expect(BenchmarkTasks.all.count == 8)
    }
}
