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
    public enum Source: String, Sendable, Codable { case narrator, reader, describe, fence, system }
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
}

public actor AgentCore {
    public private(set) var mode: AgentMode = .explore
    private let audio: SpatialAudioCueing
    private let haptics: HapticCueing
    private let depth: DepthProviding?
    private let router: ReasoningRouting?
    private var narrator: SceneNarrator
    private var reader = TextReader()
    private var lastFrame: VisionFrameResult?
    private var lastFenceWarning: [String: TimeInterval] = [:]
    private var busyUntil: TimeInterval = 0
    private var telemetry = AgentTelemetry()
    private var describeLatency = LatencyWindow(capacity: 64)
    private var continuations: [UUID: AsyncStream<AgentLine>.Continuation] = [:]
    private let clock: @Sendable () -> TimeInterval

    public init(audio: SpatialAudioCueing, haptics: HapticCueing, depth: DepthProviding? = nil, router: ReasoningRouting? = nil,
                narrator: NarratorConfig = NarratorConfig(),
                clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.audio = audio
        self.haptics = haptics
        self.depth = depth
        self.router = router
        self.narrator = SceneNarrator(config: narrator)
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
            guard let a = narrator.observe(frame, depths: depths, aheadMetres: ahead) else { return false }
            if !a.urgent, clock() < busyUntil { return false }
            telemetry.announcements += 1
            if a.urgent { await haptics.warn() }
            await say(a.text, source: .narrator, azimuth: a.azimuth, urgent: a.urgent)
        case .read:
            guard clock() >= busyUntil else { return false }
            let fresh = reader.newLines(in: frame)
            guard !fresh.isEmpty else { return false }
            await say(fresh.prefix(3).joined(separator: ". "), source: .reader)
        case .find:
            break
        }
        return false
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
                question: "Describe what is in front of the camera for someone who cannot see it.",
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

    /// The Read button: everything readable right now, ignoring what was read before.
    @discardableResult
    public func readNow() async -> String {
        guard let frame = lastFrame else { return "" }
        let lines = TextReader.lines(in: frame)
        let text = lines.isEmpty ? "I cannot see any text. Hold the phone about a foot away and keep still." : lines.joined(separator: ". ")
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
            var phrase = SceneVocabulary.article(d.label)
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
