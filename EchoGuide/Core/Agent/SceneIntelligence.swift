// Owner: Maxwell's agent, extended for the demo (Bryan). Decides *when* the
// agent should ask a vision-language model what is going on, on top of the
// per-object narration:
//
//   * the first time something settles after entering Explore
//   * when the scene changes materially (the set of things in view turns over)
//   * never more often than `minInterval`, never while another ask is in flight
//
// Pure logic, no network. AgentCore runs the actual request and speaks it.

import Foundation
import EchoGuideContracts

public struct SceneIntelligenceConfig: Sendable {
    /// Seconds between two scene descriptions, however much changes.
    public var minInterval: TimeInterval = 8
    /// Refresh the reference this often even when the scene has not turned over.
    public var refreshInterval: TimeInterval = 15
    /// Share of the label set that must turn over to count as a new scene (Jaccard distance).
    public var changeThreshold: Float = 0.5
    /// Wait this long after entering the mode before the first description.
    public var warmup: TimeInterval = 2
    /// Objects below this confidence do not define the scene.
    public var minimumConfidence: Float = 0.5

    public init() {}
}

public struct SceneIntelligence: Sendable {
    public var config: SceneIntelligenceConfig
    private var startedAt: TimeInterval?
    private var lastAskedAt: TimeInterval = -.infinity
    private var lastLabels: Set<String> = []
    private var described = false

    public init(config: SceneIntelligenceConfig = SceneIntelligenceConfig()) { self.config = config }

    public mutating func reset(at now: TimeInterval? = nil) {
        startedAt = now
        lastAskedAt = -.infinity
        lastLabels = []
        described = false
    }

    /// Labels that define the scene for this frame.
    public func labels(in frame: VisionFrameResult) -> Set<String> {
        Set(frame.detections.filter { $0.kind == .object && $0.confidence >= config.minimumConfidence && !SceneVocabulary.silent.contains($0.label) }.map(\.label))
    }

    /// True when the agent should ask now. Caller marks the ask with `asked(at:labels:)`.
    public mutating func wantsScene(_ frame: VisionFrameResult) -> Bool {
        let now = frame.timestamp
        if startedAt == nil { startedAt = now }
        guard now - (startedAt ?? now) >= config.warmup, now - lastAskedAt >= config.minInterval else { return false }
        let current = labels(in: frame)
        if !described { return !current.isEmpty }
        if !current.isEmpty, now - lastAskedAt >= config.refreshInterval { return true }
        let union = current.union(lastLabels)
        guard !union.isEmpty else { return false }
        let distance = 1 - Float(current.intersection(lastLabels).count) / Float(union.count)
        return distance >= config.changeThreshold && current.count >= 1
    }

    public mutating func asked(at now: TimeInterval, labels: Set<String>) {
        lastAskedAt = now
        lastLabels = labels
        described = true
    }

    /// The question for the model. Detections are added by the router prompt.
    public static let question = """
    Describe the scene for a blind person in one or two short sentences: what kind of place this is, \
    what is happening, and the colour and shape of the most important thing. Say where things are. \
    Do not list every object.
    """
}
