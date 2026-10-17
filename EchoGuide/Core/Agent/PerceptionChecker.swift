// Owner: Maxwell's agent, extended for the demo (Bryan). The check pipeline
// for image recognition, the counterpart of TextVerifier for text. Before an
// uncertain detection is spoken, the vision model is asked a yes/no question
// about a crop of it. Confident detections skip the check; rejected labels
// are held back; verdicts are cached by label and place so a still scene
// costs one request, not one per frame.

import Foundation
import EchoGuideContracts

public actor PerceptionChecker {
    public enum Verdict: Sendable, Equatable { case confirmed, rejected, unknown }

    /// Detections at or above this confidence are trusted without a check.
    public var trustAbove: Float
    public var timeout: TimeInterval
    private var cache: [String: (Verdict, TimeInterval)] = [:]
    private let cacheFor: TimeInterval = 30

    public init(trustAbove: Float = 0.75, timeout: TimeInterval = 4) {
        self.trustAbove = trustAbove
        self.timeout = timeout
    }

    public func needsCheck(_ d: Detection) -> Bool {
        d.kind == .object && d.confidence < trustAbove && cache[Self.key(d)] == nil
    }

    public static func question(_ d: Detection) -> String {
        "Is there \(SceneVocabulary.article(d.label)) in this picture? Answer yes or no."
    }

    public func check(_ d: Detection, jpeg: Data?, router: ReasoningRouting) async -> Verdict {
        let key = Self.key(d)
        if let (v, at) = cache[key], Date().timeIntervalSince1970 - at < cacheFor { return v }
        guard jpeg != nil else { return .unknown }
        let out = await router.resolve(ReasoningQuery(question: Self.question(d), detections: [], localConfidence: 0,
                                                      jpeg: jpeg, maxWords: 3, timeout: timeout, raw: true))
        let verdict: Verdict
        if out.source == .cloud {
            let a = out.answer.lowercased()
            verdict = a.hasPrefix("yes") ? .confirmed : a.hasPrefix("no") ? .rejected : .unknown
        } else {
            verdict = .unknown
        }
        if verdict != .unknown { cache[key] = (verdict, Date().timeIntervalSince1970) }
        return verdict
    }

    /// Label plus a coarse place (thirds of the frame).
    static func key(_ d: Detection) -> String {
        "\(d.label)|\(Int(d.box.midX * 3))|\(Int(d.box.midY * 3))"
    }
}
