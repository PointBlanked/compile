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

    @Test func locationFenceExposesWhereTheUserIs() {
        let home = GeoCoordinate(latitude: 51.5145, longitude: -0.1165)
        var fence = LocationFence(areas: [SafeArea(name: "home", center: home, radiusMetres: 80)], exitDwell: 10)
        _ = fence.update(home, accuracyMetres: 5, at: 0)
        #expect(fence.insideArea == "home")
        #expect(!fence.isOutside)
        let away = GeoCoordinate(latitude: 51.5175, longitude: -0.1165)
        _ = fence.update(away, accuracyMetres: 5, at: 1)
        #expect(fence.insideArea == nil)
        #expect(fence.update(away, accuracyMetres: 5, at: 12) == .leftSafeArea(region: "home"))
        #expect(fence.isOutside)
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

    @Test func wanderingIsStickyUntilReturn() async {
        let (e, _, a) = engine()
        await e.start()
        await e.ingest(fence: .leftSafeArea(region: "home"), at: 0)
        #expect(await e.state == .outsideSafeArea("home"))
        #expect(await a.spoken == ["You have left home."])
        // Frames do not clear a wandering alert.
        await e.ingest(frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 1))
        #expect(await e.state == .outsideSafeArea("home"))
        await e.ingest(fence: .returnedToSafeArea(region: "home"), at: 60)
        #expect(await e.state == .scanning)
    }

    @Test func caregiverToldWhenToolExists() async {
        let registry = PluginRegistry()
        let told = Counter()
        await registry.register(ToolDescriptor(name: "notify_caregiver", description: "", sideEffect: .none, parameters: ["region"]) { args in
            await told.inc()
            return "Carer told: left \(args["region"] ?? "")."
        })
        let (e, _, a) = engine(tools: registry)
        await e.start()
        await e.ingest(fence: .leftSafeArea(region: "home"), at: 0)
        #expect(await told.value == 1)
        #expect(await a.spoken == ["You have left home. Your carer has been told."])
    }

    @Test func returnDoesNotUnpause() async {
        let (e, _, _) = engine()
        await e.ingest(fence: .returnedToSafeArea(region: "home"), at: 0)
        #expect(await e.state == .idle)
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
