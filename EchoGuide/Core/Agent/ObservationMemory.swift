// Owner: Maxwell's agent, extended for the demo (Bryan). Short-term visual
// memory: a rolling list of timestamped observations (what was in view, where,
// and the last scene sentence), so the user can ask about things that are no
// longer in frame: "where did you see my backpack?" -> "I saw a backpack
// about 40 seconds ago, on your left." Pure logic, no model.

import Foundation
import EchoGuideContracts

public struct SceneObservation: Sendable, Equatable {
    public var time: TimeInterval
    /// Most confident box per label this frame.
    public var objects: [String: ImageRect]
    /// Colour per label when it was clear.
    public var colors: [String: String] = [:]
    public var text: [String]
    /// The vision model's scene sentence, when one was spoken around this time.
    public var scene: String?

    public init(time: TimeInterval, objects: [String: ImageRect], text: [String] = [], scene: String? = nil) {
        self.time = time
        self.objects = objects
        self.text = text
        self.scene = scene
    }
}

public struct ObservationMemory: Sendable {
    public var capacity: Int
    /// Record a frame at most this often while the label set is unchanged.
    public var minSpacing: TimeInterval
    public var minimumConfidence: Float
    public private(set) var observations: [SceneObservation] = []

    public init(capacity: Int = 60, minSpacing: TimeInterval = 2, minimumConfidence: Float = 0.5) {
        self.capacity = capacity
        self.minSpacing = minSpacing
        self.minimumConfidence = minimumConfidence
    }

    public mutating func reset() { observations = [] }

    /// Adds an observation when the set of things changed or enough time passed.
    @discardableResult
    public mutating func record(_ frame: VisionFrameResult) -> Bool {
        var objects: [String: ImageRect] = [:]
        var colors: [String: String] = [:]
        var best: [String: Float] = [:]
        for d in frame.detections where d.kind == .object && d.confidence >= minimumConfidence && !SceneVocabulary.silent.contains(d.label) {
            if d.confidence > (best[d.label] ?? 0) { best[d.label] = d.confidence; objects[d.label] = d.box; colors[d.label] = d.color }
        }
        let text = frame.detections.filter { $0.kind == .text && $0.confidence >= minimumConfidence }
            .compactMap { $0.text.map(TextReader.clean) }.filter { $0.count >= 3 }
        guard !objects.isEmpty || !text.isEmpty else { return false }
        if let last = observations.last, Set(last.objects.keys) == Set(objects.keys), frame.timestamp - last.time < minSpacing {
            return false
        }
        var o = SceneObservation(time: frame.timestamp, objects: objects, text: text)
        o.colors = colors
        observations.append(o)
        if observations.count > capacity { observations.removeFirst(observations.count - capacity) }
        return true
    }

    /// Attach the scene sentence to the latest observation.
    public mutating func noteScene(_ sentence: String, at time: TimeInterval) {
        if observations.isEmpty { observations.append(SceneObservation(time: time, objects: [:], scene: sentence)) } else { observations[observations.count - 1].scene = sentence }
    }

    // MARK: - Questions

    /// "where did you see my backpack", "have you seen a cup", "what did you see".
    public static func isRecallQuestion(_ raw: String) -> Bool {
        let s = raw.lowercased()
        return s.contains("did you see") || s.contains("have you seen") || s.contains("where was") || s.contains("where were")
            || s.contains("where did") || s.hasPrefix("where's my") || s.hasPrefix("where is my") || s.contains("what did you see")
            || s.contains("what have you seen") || s.contains("last see") || s.contains("seen my")
    }

    static let filler: Set<String> = ["where", "did", "do", "you", "see", "seen", "have", "has", "was", "were", "is", "my", "the", "a", "an",
                                      "last", "earlier", "before", "what", "when", "it", "that", "there", "any", "please", "wheres", "where's"]

    /// The thing asked about, in COCO vocabulary where possible; nil for "what did you see".
    public static func subject(of raw: String) -> String? {
        let words = raw.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !filler.contains($0) }
        guard !words.isEmpty else { return nil }
        let phrase = words.joined(separator: " ")
        for (spoken, label) in synonyms where phrase.contains(spoken) { return label }
        return phrase
    }

    static let synonyms: [(String, String)] = [
        ("phone", "cell phone"), ("mobile", "cell phone"), ("bag", "backpack"), ("purse", "handbag"), ("sofa", "couch"),
        ("television", "tv"), ("glass", "wine glass"), ("mug", "cup"), ("computer", "laptop"), ("bike", "bicycle"), ("plant", "potted plant"),
    ]

    /// Spoken answer, always grounded in what was recorded.
    public func answer(_ raw: String, now: TimeInterval) -> String {
        guard let subject = Self.subject(of: raw) else { return summary(now: now) }
        let matches = observations.reversed().first { o in o.objects.keys.contains { $0.contains(subject) || subject.contains($0) } }
        guard let o = matches, let (label, box) = o.objects.first(where: { $0.key.contains(subject) || subject.contains($0.key) }) else {
            if let t = observations.reversed().first(where: { $0.text.contains { $0.lowercased().contains(subject) } }) {
                return "I read \"\(subject)\" \(Self.ago(now - t.time))."
            }
            return "I have not seen \(SceneVocabulary.article(subject)) recently."
        }
        let named = o.colors[label].map { "\($0) \(label)" } ?? label
        return "I saw \(SceneVocabulary.article(named)) \(Self.ago(now - o.time)), \(SceneVocabulary.place(box.midX))."
    }

    /// "In the last minute I saw a chair, a laptop and a person."
    public func summary(now: TimeInterval, window: TimeInterval = 60) -> String {
        var seen: [String] = []
        for o in observations.reversed() where now - o.time <= window {
            for label in o.objects.keys.sorted() where !seen.contains(label) { seen.append(label) }
        }
        guard !seen.isEmpty else { return "I have not seen anything I recognise in the last minute." }
        let names = seen.prefix(6).map(SceneVocabulary.article)
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "In the last minute I saw \(list)."
    }

    public static func ago(_ seconds: TimeInterval) -> String {
        if seconds < 5 { return "just now" }
        if seconds < 90 { return "about \(Int((seconds / 5).rounded()) * 5) seconds ago" }
        return "about \(Int((seconds / 60).rounded())) minutes ago"
    }
}
