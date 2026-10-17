// Owner: Maxwell. The visual agent: one actor that owns what the user hears
// in each mode, on top of the same live perception stream.
//
//   Explore  continuous perception, proactive: names what comes into view and
//            warns about obstacles in the path, unprompted.
//   Find     goal-directed: frames go to AutomationEngine (Bryan), which guides
//            the finger onto one target and presses it.
//   Read     reads text in view in reading order, once per line.
//   Describe one-shot contextual reasoning about the whole scene (multimodal
//            cloud model with the photo when allowed, on-device summary otherwise).
//
// Hazard-fence warnings speak in every mode.

import Foundation
import EchoGuideContracts

public enum AgentMode: String, Sendable, CaseIterable, Codable {
    case explore, find, read

    public var title: String {
        switch self {
        case .explore: return "Explore"
        case .find: return "Find"
        case .read: return "Read"
        }
    }

    /// One sentence the user hears when switching, so the mode explains itself.
    public var spokenHelp: String {
        switch self {
        case .explore: return "Explore. I will tell you what is around you."
        case .find: return "Find. Say or type what you want, then follow the pulses."
        case .read: return "Read. Point the camera at text and hold still."
        }
    }
}

public struct AgentLine: Sendable, Equatable {
    public enum Source: String, Sendable, Codable { case narrator, reader, describe, scene, fence, system }
    public var text: String
    public var source: Source
    public var at: Date
}

public struct AgentTelemetry: Sendable, Equatable {
    public var framesSeen = 0
    public var announcements = 0
    public var describeCloud = 0
    public var describeLocal = 0
    public var describeP50Ms: Double = 0
    public var describeP95Ms: Double = 0
    /// Unprompted scene descriptions spoken in Explore.
    public var sceneDescriptions = 0
    /// Uncertain detections the check pipeline refused to announce.
    public var rejectedRecognitions = 0
}

public actor AgentCore {
    public private(set) var mode: AgentMode = .explore
    private let audio: SpatialAudioCueing
    private let haptics: HapticCueing
    private let depth: DepthProviding?
    private let router: ReasoningRouting?
    /// Text-only model for OCR verification; `router` when nil.
    private let textRouter: ReasoningRouting?
    private var narrator: SceneNarrator
    private var reader = TextReader()
    private var scene = SceneIntelligence()
    private var sceneInFlight = false
    private var memory = ObservationMemory()
    private let verifier = TextVerifier()
    private var readInFlight = false
    private var pendingLines: [String] = []
    /// Supplies the current camera frame as JPEG when the scene is worth describing.
    /// Full frame when the box is nil, otherwise that region, for checks.
    private let jpegProvider: (@Sendable (ImageRect?) -> Data?)?
    private let checker = PerceptionChecker()
    private var checkInFlight = false
    private var lastFrame: VisionFrameResult?
    private var lastFenceWarning: [String: TimeInterval] = [:]
    private var busyUntil: TimeInterval = 0
    private var telemetry = AgentTelemetry()
    private var describeLatency = LatencyWindow(capacity: 64)
    private var continuations: [UUID: AsyncStream<AgentLine>.Continuation] = [:]
    private let clock: @Sendable () -> TimeInterval

    public init(audio: SpatialAudioCueing, haptics: HapticCueing, depth: DepthProviding? = nil, router: ReasoningRouting? = nil,
                textRouter: ReasoningRouting? = nil,
                narrator: NarratorConfig = NarratorConfig(), scene: SceneIntelligenceConfig = SceneIntelligenceConfig(),
                jpegProvider: (@Sendable (ImageRect?) -> Data?)? = nil,
                clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.audio = audio
        self.haptics = haptics
        self.depth = depth
        self.router = router
        self.textRouter = textRouter
        self.narrator = SceneNarrator(config: narrator)
        self.scene = SceneIntelligence(config: scene)
        self.jpegProvider = jpegProvider
        self.clock = clock
    }

    /// Captions for the screen: every sentence the agent says, as it says it.
    public func lines() -> AsyncStream<AgentLine> {
        AsyncStream { c in
            let id = UUID()
            continuations[id] = c
            c.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        }
    }

    private func drop(_ id: UUID) { continuations[id] = nil }

    public var stats: AgentTelemetry {
        var t = telemetry
        t.describeP50Ms = describeLatency.percentile(0.5)
        t.describeP95Ms = describeLatency.percentile(0.95)
        return t
    }

    public func setMode(_ m: AgentMode, announce: Bool = true) async {
        mode = m
        narrator.reset()
        reader.reset()
        scene.reset()
        busyUntil = 0
        await haptics.stop()
        if announce { await say(m.spokenHelp, source: .system, urgent: true) }
    }

    /// Feed every inferred frame. Returns true when the frame belongs to
    /// AutomationEngine (Find mode), which then also handles the fence.
    @discardableResult
    public func ingest(_ frame: VisionFrameResult, fence: FenceEvent?) async -> Bool {
        lastFrame = frame
        telemetry.framesSeen += 1
        memory.record(frame)
        if mode == .find { return true }

        if let fence, await handle(fence, at: frame.timestamp) { return false }

        switch mode {
        case .explore:
            var depths: [Int: Float] = [:]
            var ahead: Float?
            if let depth {
                // Sample only what could be announced: the few most salient objects and the path ahead.
                let ranked = frame.detections.enumerated()
                    .filter { $0.element.kind == .object && !SceneVocabulary.silent.contains($0.element.label) }
                    .sorted { SceneVocabulary.salience(of: $0.element.label) > SceneVocabulary.salience(of: $1.element.label) }
                    .prefix(4)
                for (i, d) in ranked { depths[i] = await depth.depth(at: d.box.mid) }
                ahead = await depth.depth(at: .center)
            }
            // Scene intelligence: when the scene turns over, ask the vision
            // model what is going on. Runs off the frame path so perception
            // and hazards never wait on the network.
            if router != nil, let jpegProvider, !sceneInFlight, scene.wantsScene(frame) {
                let labels = scene.labels(in: frame)
                scene.asked(at: frame.timestamp, labels: labels)
                sceneInFlight = true
                let snapshot = frame
                Task { await self.describeScene(snapshot, jpeg: jpegProvider(nil)) }
            }
            guard let a = narrator.observe(frame, depths: depths, aheadMetres: ahead) else { return false }
            if !a.urgent, clock() < busyUntil { return false }
            // Check pipeline: an uncertain object is confirmed against the
            // vision model on its crop before it is spoken. Off the frame path;
            // confident detections and urgent alerts are spoken at once.
            if a.kind == .object, let d = a.detection, await checker.needsCheck(d), let router, let jpegProvider, !checkInFlight {
                checkInFlight = true
                let crop = jpegProvider(Self.padded(d.box))
                Task { await self.confirmAndSay(a, detection: d, jpeg: crop, router: router) }
                return false
            }
            telemetry.announcements += 1
            if a.urgent { if a.kind == .motion { await haptics.alert() } else { await haptics.warn() } }
            await say(a.text, source: .narrator, azimuth: a.azimuth, urgent: a.urgent)
        case .read:
            guard clock() >= busyUntil else { return false }
            // OCR -> local gate -> model correction, off the frame path.
            let fresh = TextVerifier.gate(reader.newLines(in: frame))
            guard !fresh.isEmpty else { return false }
            if textRouter == nil, router == nil {
                // No model to hand off to: the gate is the whole check, instant.
                await say(fresh.prefix(3).joined(separator: ". "), source: .reader)
                return false
            }
            pendingLines += fresh
            if !readInFlight {
                readInFlight = true
                Task { await self.flushReading() }
            }
        case .find:
            break
        }
        return false
    }

    /// Vision-model yes/no on the crop; speaks only if confirmed, otherwise the
    /// label is doubted for a while so the narrator does not keep offering it.
    private func confirmAndSay(_ a: Announcement, detection d: Detection, jpeg: Data?, router: ReasoningRouting) async {
        defer { checkInFlight = false }
        let verdict = await checker.check(d, jpeg: jpeg, router: router)
        guard mode == .explore else { return }
        switch verdict {
        case .confirmed, .unknown:
            telemetry.announcements += 1
            await say(a.text, source: .narrator, azimuth: a.azimuth, urgent: a.urgent)
        case .rejected:
            telemetry.rejectedRecognitions += 1
            narrator.doubt(d.label, at: lastFrame?.timestamp ?? clock())
        }
    }

    /// A little context around the box helps the model.
    static func padded(_ b: ImageRect) -> ImageRect {
        let px = b.width * 0.25, py = b.height * 0.25
        return ImageRect(x: max(0, b.x - px), y: max(0, b.y - py), width: min(1 - max(0, b.x - px), b.width + 2 * px), height: min(1 - max(0, b.y - py), b.height + 2 * py))
    }

    /// Unprompted: one or two sentences about the place and what is happening,
    /// from the vision model. Spoken only if it came from the model; the
    /// on-device fallback would just repeat what the narrator already said.
    private func describeScene(_ frame: VisionFrameResult, jpeg: Data?) async {
        defer { sceneInFlight = false }
        guard let router, mode == .explore else { return }
        let outcome = await router.resolve(ReasoningQuery(
            question: SceneIntelligence.question,
            detections: frame.detections.filter { $0.kind != .fingertip },
            localConfidence: 0,
            jpeg: jpeg,
            maxWords: 32,
            timeout: 10
        ))
        guard outcome.source == .cloud, !outcome.answer.isEmpty, mode == .explore else { return }
        telemetry.sceneDescriptions += 1
        memory.noteScene(outcome.answer, at: frame.timestamp)
        // Wait for whatever is being said, then speak.
        let wait = busyUntil - clock()
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(min(wait, 4) * 1_000_000_000)) }
        await say(outcome.answer, source: .scene)
    }

    /// The Describe button: what is in front of me, all of it, in a few sentences.
    @discardableResult
    public func describe(jpeg: Data?) async -> String {
        let timer = FrameTimer()
        guard let frame = lastFrame else {
            let text = "The camera is still starting. Try again in a moment."
            await say(text, source: .describe, urgent: true)
            return text
        }
        await say("Looking.", source: .system, urgent: true)

        var depths: [Int: Float] = [:]
        if let depth {
            for (i, d) in frame.detections.enumerated().prefix(6) where d.kind == .object { depths[i] = await depth.depth(at: d.box.mid) }
        }
        let local = SceneSummary.local(frame, depths: depths)

        var text = local
        if let router {
            let outcome = await router.resolve(ReasoningQuery(
                question: "Describe what is in front of the camera for someone who cannot see it: the kind of place, what is happening, the main things with their colours and where they are, and anything hazardous.",
                detections: frame.detections.filter { $0.kind != .fingertip },
                localConfidence: 0,
                jpeg: jpeg,
                maxWords: 40,
                timeout: 6
            ))
            if outcome.source == .cloud, !outcome.answer.isEmpty {
                text = outcome.answer
                telemetry.describeCloud += 1
            } else {
                telemetry.describeLocal += 1
            }
        } else {
            telemetry.describeLocal += 1
        }
        describeLatency.record(timer.elapsedMs)
        await say(text, source: .describe, urgent: true)
        return text
    }

    /// Verifies the pending OCR lines with the model, then speaks them.
    private func flushReading() async {
        defer { readInFlight = false }
        while !pendingLines.isEmpty, mode == .read {
            let batch = Array(pendingLines.prefix(3))
            pendingLines.removeFirst(batch.count)
            let cleaned = await verifier.verify(batch, router: textRouter ?? router)
            guard !cleaned.isEmpty, mode == .read else { continue }
            await say(cleaned.joined(separator: ". "), source: .reader)
        }
        pendingLines = []
    }

    /// A question about the recent past, answered from memory and spoken:
    /// "where did you see my backpack" -> "I saw a backpack about 40 seconds ago, on your left."
    @discardableResult
    public func recall(_ question: String) async -> String {
        let now = lastFrame?.timestamp ?? clock()
        let text = memory.answer(question, now: now)
        await say(text, source: .describe, urgent: true)
        return text
    }

    public var recentObservations: [SceneObservation] { memory.observations }

    /// The Read button: everything readable right now, ignoring what was read before.
    @discardableResult
    public func readNow() async -> String {
        guard let frame = lastFrame else { return "" }
        let lines = await verifier.verify(TextReader.lines(in: frame), router: textRouter ?? router)
        let text = lines.isEmpty ? "I cannot see any text. Hold the phone about a foot away and keep still." : lines.prefix(6).joined(separator: ". ")
        await say(text, source: .reader, urgent: true)
        return text
    }

    // MARK: - Speech

    private func say(_ text: String, source: AgentLine.Source, azimuth: Float = 0, urgent: Bool = false) async {
        // Roughly 2.5 words a second; the next routine line waits for this one.
        let words = Double(text.split(separator: " ").count)
        busyUntil = clock() + max(1.2, words / 2.5)
        let line = AgentLine(text: text, source: source, at: Date())
        for c in continuations.values { c.yield(line) }
        await audio.speak(text, azimuth: azimuth)
    }

    // MARK: - Fence (Explore and Read; Find delegates to AutomationEngine)

    private func handle(_ event: FenceEvent, at now: TimeInterval) async -> Bool {
        switch event {
        case .breached(let zone):
            await haptics.warn()
            if throttle(zone, now) { await say("Stop. \(zone.capitalizedFirstLetter).", source: .fence, urgent: true) }
            return true
        case .approaching(let zone, _):
            if throttle(zone, now) {
                await haptics.warn()
                await say("Careful. \(zone.capitalizedFirstLetter) is close.", source: .fence, urgent: true)
            }
            return false
        }
    }

    private func throttle(_ key: String, _ now: TimeInterval) -> Bool {
        if let last = lastFenceWarning[key], now - last < 3 { return false }
        lastFenceWarning[key] = now
        return true
    }
}

/// On-device scene description: works offline, and is the fallback whenever
/// the cloud is off, slow or refused.
public enum SceneSummary {
    public static func local(_ frame: VisionFrameResult, depths: [Int: Float] = [:]) -> String {
        var groups: [String: [String]] = [:]
        let order = ["ahead", "on your left", "on your right"]
        var seenLabels = Set<String>()
        let objects = frame.detections.enumerated()
            .filter { $0.element.kind == .object && !SceneVocabulary.silent.contains($0.element.label) && $0.element.confidence >= 0.4 }
            .sorted { SceneVocabulary.salience(of: $0.element.label) > SceneVocabulary.salience(of: $1.element.label) }
        for (i, d) in objects where seenLabels.insert(d.label).inserted && seenLabels.count <= 5 {
            var phrase = SceneVocabulary.article(d.describedLabel)
            if let dist = SceneVocabulary.distance(depths[i]) { phrase += ", \(dist)" }
            groups[SceneVocabulary.place(d.box.midX), default: []].append(phrase)
        }
        var sentences = order.compactMap { place -> String? in
            guard let items = groups[place], !items.isEmpty else { return nil }
            return "\(place.capitalizedFirstLetter): \(items.joined(separator: "; "))."
        }
        let text = TextReader.lines(in: frame).prefix(2)
        if !text.isEmpty {
            let joined = text.joined(separator: ". ")
            sentences.append("Text: " + joined + ".")
        }
        if frame.detections.contains(where: { $0.kind == .barcode }) { sentences.append("There is a barcode. Hold still on it to hear the product.") }
        return sentences.isEmpty
            ? "I cannot make out anything clearly. Move the phone slowly from side to side."
            : sentences.joined(separator: " ")
    }
}
