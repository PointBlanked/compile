// Owner: Maxwell. Proactive narration for Explore mode: the agent speaks up
// on its own when something new and worth knowing comes into view, and stays
// quiet otherwise. The rules that keep it useful instead of noisy:
//
//   * settled:   a thing must be seen on several frames before it is named
//   * novel:     each thing is named once, then not again for a cooldown
//   * ranked:    an obstacle in the path beats a car beats a person beats a cup
//   * paced:     at most one sentence every couple of seconds
//   * placed:    every sentence says where ("on your left, 2 meters")
//
// Pure logic, no audio; AgentCore speaks what this returns.

import Foundation
import EchoGuideContracts

public struct NarratorConfig: Sendable {
    public var settleFrames = 2
    /// The same label is not announced again for this long.
    public var labelCooldown: TimeInterval = 20
    /// The same piece of text is not read again for this long.
    public var textCooldown: TimeInterval = 45
    /// Minimum gap between two announcements.
    public var minGap: TimeInterval = 2.5
    /// Something closer than this, straight ahead, is an obstacle warning.
    public var obstacleMetres: Float = 1.2
    public var obstacleCooldown: TimeInterval = 4
    /// Ignore detections less confident than this (avoids naming noise).
    public var minimumConfidence: Float = 0.5
    /// Tracks unseen for this long are forgotten.
    public var trackExpiry: TimeInterval = 1.5
    /// A tracked thing whose centre moves faster than this (frame widths per
    /// second), or whose box grows by this factor inside half a second, is
    /// "moving fast" and may interrupt.
    public var fastSpeed: Float = 0.6
    public var approachGrowth: Float = 1.6
    public var motionCooldown: TimeInterval = 4

    public init() {}
}

public struct Announcement: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case obstacle, motion, object, text }

    public var text: String
    public var kind: Kind
    /// -π/2 left ... +π/2 right, for the spatial ping before the words.
    public var azimuth: Float
    /// Obstacles also buzz.
    public var urgent: Bool
}

public enum SceneVocabulary {
    /// Higher = more worth interrupting for. Unlisted labels score 2.
    public static let salience: [String: Int] = [
        "car": 9, "bus": 9, "truck": 9, "motorcycle": 9, "bicycle": 8, "train": 9,
        "traffic light": 8, "stop sign": 8, "person": 7, "dog": 6, "cat": 5,
        "bench": 5, "chair": 5, "couch": 4, "bed": 4, "dining table": 5, "toilet": 6, "sink": 5,
        "refrigerator": 5, "oven": 6, "microwave": 5, "tv": 3, "laptop": 3, "cell phone": 3,
        "backpack": 3, "handbag": 3, "suitcase": 4, "bottle": 2, "cup": 2, "potted plant": 3,
        // Open-vocabulary classes (YOLO-World export): hazards for someone walking first.
        "stairs": 9, "step": 8, "hole": 9, "puddle": 8, "wet floor sign": 9, "curb": 8, "escalator": 8, "cable": 7,
        "bollard": 8, "pole": 8, "traffic cone": 8, "crosswalk": 8, "scooter": 8, "child": 8, "shopping cart": 6,
        "door": 6, "open door": 7, "elevator": 6, "elevator button": 6, "exit sign": 7, "handrail": 5, "ramp": 6,
        "wheelchair": 6, "stroller": 6, "knife": 7, "scissors": 6, "stove": 7, "kettle": 5, "medicine bottle": 5,
        "cane": 4, "light switch": 4, "control panel": 5, "button": 4,
    ]

    /// Words on a sign that matter enough to be read before anything else.
    public static let importantSignWords: [String] = [
        "exit", "emergency", "caution", "danger", "warning", "wet floor", "stop", "do not enter", "keep out",
        "toilet", "restroom", "wc", "entrance", "push", "pull", "elevator", "lift", "stairs", "platform", "gate", "open", "closed",
    ]

    public static func isImportantSign(_ text: String) -> Bool {
        let t = text.lowercased()
        return importantSignWords.contains { t.contains($0) }
    }

    /// Never volunteered: the user's own hand, and background clutter.
    public static let silent: Set<String> = ["fingertip", "text", "hand"]

    public static func salience(of label: String) -> Int { salience[label] ?? 2 }

    public static func place(_ x: Float) -> String {
        if x < 0.33 { return "on your left" }
        if x > 0.67 { return "on your right" }
        return "ahead"
    }

    public static func distance(_ metres: Float?) -> String? {
        guard let m = metres, m.isFinite, m > 0 else { return nil }
        if m < 0.75 { return "very close" }
        if m < 1.5 { return "about 1 meter" }
        return "about \(Int(m.rounded())) meters"
    }

    public static func azimuth(_ x: Float) -> Float { max(-1, min(1, (x - 0.5) * 2)) * .pi / 2 }

    /// "a chair" / "a person" / "an oven"; plural not needed for one-at-a-time speech.
    public static func article(_ label: String) -> String {
        guard let first = label.lowercased().first else { return label }
        return ("aeiou".contains(first) ? "an " : "a ") + label
    }
}

public struct SceneNarrator: Sendable {
    public var config: NarratorConfig

    struct Track {
        var label: String
        var box: ImageRect
        var frames: Int
        var lastSeen: TimeInterval
        /// Where and how big it was about half a second ago, for motion.
        var pastBox: ImageRect
        var pastAt: TimeInterval
    }

    private var tracks: [Track] = []
    private var lastAnnounced: [String: TimeInterval] = [:]
    private var lastAny: TimeInterval = -.infinity

    public init(config: NarratorConfig = NarratorConfig()) { self.config = config }

    public mutating func reset() {
        tracks = []
        lastAnnounced = [:]
        lastAny = -.infinity
    }

    /// `depths` holds metres per detection index when LiDAR is available.
    /// `aheadMetres` is the depth at the frame centre (the walking path).
    public mutating func observe(_ frame: VisionFrameResult, depths: [Int: Float] = [:], aheadMetres: Float? = nil) -> Announcement? {
        let now = frame.timestamp
        updateTracks(frame, now: now)

        // 1. Obstacle in the path: only rule allowed to break the pacing gap.
        if let ahead = aheadMetres, ahead > 0, ahead < config.obstacleMetres, cooled("__obstacle", now, config.obstacleCooldown) {
            let what = frame.targets
                .filter { $0.box.contains(.center) && !SceneVocabulary.silent.contains($0.label) }
                .max { $0.confidence < $1.confidence }?.label
            let distance = SceneVocabulary.distance(ahead) ?? "close"
            let text = what.map { "\($0.capitalizedFirstLetter) ahead, \(distance)." } ?? "Obstacle ahead, \(distance)."
            return mark(Announcement(text: text, kind: .obstacle, azimuth: 0, urgent: true), keys: ["__obstacle"] + (what.map { [$0] } ?? []), at: now)
        }

        // 1b. Something moving fast, or growing fast (coming at the user): interrupts too.
        if let moving = fastestMover(now), cooled("motion:" + moving.label, now, config.motionCooldown) {
            let name = frame.detections.first { $0.label == moving.label && $0.box.iou(moving.box) > 0.3 }?.describedLabel ?? moving.label
            let text = "\(SceneVocabulary.article(name).capitalizedFirstLetter), \(moving.approaching ? "coming toward you" : "moving fast"), \(SceneVocabulary.place(moving.box.midX))."
            return mark(Announcement(text: text, kind: .motion, azimuth: SceneVocabulary.azimuth(moving.box.midX), urgent: true),
                        keys: ["motion:" + moving.label, moving.label], at: now)
        }

        guard now - lastAny >= config.minGap else { return nil }

        // 1c. An important sign (EXIT, CAUTION, WET FLOOR) outranks objects.
        if let sign = signs(in: frame).first(where: { SceneVocabulary.isImportantSign($0.1) }),
           cooled("text:" + sign.1.lowercased(), now, config.textCooldown) {
            return mark(Announcement(text: "Sign: \(sign.1).", kind: .text, azimuth: SceneVocabulary.azimuth(sign.0.box.midX), urgent: false),
                        keys: ["text:" + sign.1.lowercased()], at: now)
        }

        // 2. The most salient settled thing not announced recently.
        var best: (score: Float, d: Detection, metres: Float?)?
        for (i, d) in frame.detections.enumerated() {
            guard d.kind == .object, d.confidence >= config.minimumConfidence,
                  !SceneVocabulary.silent.contains(d.label), isSettled(d),
                  cooled(d.label, now, config.labelCooldown) else { continue }
            let metres = depths[i]
            // Salience first; nearer and more central break ties.
            var score = Float(SceneVocabulary.salience(of: d.label))
            if let m = metres { score += max(0, 3 - m) * 0.5 }
            score += (1 - abs(d.box.midX - 0.5) * 2) * 0.5
            if best == nil || score > best!.score { best = (score, d, metres) }
        }
        if let b = best {
            var parts = [SceneVocabulary.article(b.d.describedLabel).capitalizedFirstLetter, SceneVocabulary.place(b.d.box.midX)]
            if let dist = SceneVocabulary.distance(b.metres) { parts.append(dist) }
            let text = parts.joined(separator: ", ") + "."
            return mark(Announcement(text: text, kind: .object, azimuth: SceneVocabulary.azimuth(b.d.box.midX), urgent: false), keys: [b.d.label], at: now)
        }

        // 3. Readable text nobody has read out yet (signs, labels).
        if let sign = signs(in: frame).max(by: { $0.0.box.area < $1.0.box.area }),
           cooled("text:" + sign.1.lowercased(), now, config.textCooldown) {
            return mark(Announcement(text: "Sign: \(sign.1).", kind: .text, azimuth: SceneVocabulary.azimuth(sign.0.box.midX), urgent: false),
                        keys: ["text:" + sign.1.lowercased()], at: now)
        }
        return nil
    }

    /// Plausible sign text in this frame.
    private func signs(in frame: VisionFrameResult) -> [(Detection, String)] {
        frame.detections
            .filter { $0.kind == .text && $0.confidence >= config.minimumConfidence }
            .compactMap { d -> (Detection, String)? in
                guard let t = d.text.map(TextReader.clean), t.count >= 3, TextVerifier.plausible(t) else { return nil }
                return (d, t)
            }
    }

    // MARK: - Tracking

    private mutating func updateTracks(_ frame: VisionFrameResult, now: TimeInterval) {
        tracks.removeAll { now - $0.lastSeen > config.trackExpiry }
        for d in frame.detections where d.kind == .object && !SceneVocabulary.silent.contains(d.label) {
            if let i = tracks.indices.filter({ tracks[$0].label == d.label && (tracks[$0].box.iou(d.box) > 0.15 || tracks[$0].box.mid.distance(to: d.box.mid) < 0.5) })
                .min(by: { tracks[$0].box.mid.distance(to: d.box.mid) < tracks[$1].box.mid.distance(to: d.box.mid) }) {
                if now - tracks[i].pastAt >= 0.5 {
                    tracks[i].pastBox = tracks[i].box
                    tracks[i].pastAt = tracks[i].lastSeen
                }
                tracks[i].box = d.box
                tracks[i].frames += 1
                tracks[i].lastSeen = now
            } else {
                tracks.append(Track(label: d.label, box: d.box, frames: 1, lastSeen: now, pastBox: d.box, pastAt: now))
            }
        }
    }

    /// The settled track moving or growing fastest beyond the thresholds, if any.
    private func fastestMover(_ now: TimeInterval) -> (label: String, box: ImageRect, approaching: Bool)? {
        var best: (speed: Float, label: String, box: ImageRect, approaching: Bool)?
        for t in tracks where t.frames >= config.settleFrames && t.lastSeen == now {
            let dt = Float(max(0.2, t.lastSeen - t.pastAt))
            guard t.lastSeen > t.pastAt else { continue }
            let speed = t.box.mid.distance(to: t.pastBox.mid) / dt
            let growth = t.pastBox.area > 0 ? t.box.area / t.pastBox.area : 1
            let approaching = growth >= config.approachGrowth && t.box.area > 0.04
            guard speed >= config.fastSpeed || approaching else { continue }
            let score = speed + (approaching ? 1 : 0)
            if best == nil || score > best!.speed { best = (score, t.label, t.box, approaching) }
        }
        return best.map { ($0.label, $0.box, $0.approaching) }
    }

    private func isSettled(_ d: Detection) -> Bool {
        tracks.contains { $0.label == d.label && $0.frames >= config.settleFrames && ($0.box.iou(d.box) > 0.15 || $0.box.mid.distance(to: d.box.mid) < 0.15) }
    }

    private func cooled(_ key: String, _ now: TimeInterval, _ cooldown: TimeInterval) -> Bool {
        guard let last = lastAnnounced[key] else { return true }
        return now - last >= cooldown
    }

    private mutating func mark(_ a: Announcement, keys: [String], at now: TimeInterval) -> Announcement {
        for k in keys { lastAnnounced[k] = now }
        lastAny = now
        return a
    }
}

extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
