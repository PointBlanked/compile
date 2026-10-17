// Owner: Bryan. Step-anchoring for dementia and cognitive accessibility.
// A frame can hold a dozen detections; the user gets exactly one. Rules:
//   1. One target at a time, chosen by goal, closeness to the finger, size
//      and confidence.
//   2. Sticky: the current target holds until a rival is clearly better, so
//      the instruction does not flicker between two buttons.
//   3. Settled: a new target must be seen for several frames in a row before
//      it is announced at all.
//   4. Short: instructions are capped at a few plain words.

import Foundation
import EchoGuideContracts

public struct CognitiveConfig: Sendable {
    /// Consecutive frames a new target must persist before it becomes the step.
    public var settleFrames = 3
    /// A rival must outscore the current target by this factor to replace it.
    public var switchMargin: Float = 1.35
    public var sameTargetIoU: Float = 0.3
    public var maxInstructionWords = 8
    /// Labels never offered as a step on their own (background clutter).
    public var ignoredLabels: Set<String> = ["person", "dining table", "chair"]

    public init() {}
}

public struct CognitiveTaskIsolation: Sendable {
    public var config: CognitiveConfig
    /// When set, only matching labels or text are eligible ("start", "microwave").
    public var goal: String?
    /// Labels temporarily off the menu, e.g. a target the user just finished.
    /// AutomationEngine sets this so "done" moves on to the next step instead
    /// of guiding the finger straight back to the same button.
    public var excludedLabels: Set<String> = [] {
        didSet {
            if let cur = current, excludedLabels.contains(cur.label) { current = nil }
            if let c = candidate, excludedLabels.contains(c.label) { candidate = nil; candidateFrames = 0 }
        }
    }

    private var current: Detection?
    private var candidate: Detection?
    private var candidateFrames = 0
    /// True when the step returned by the last `isolate` came from a detection
    /// in that frame; false when it is the remembered target of an earlier
    /// frame. The caller uses this to time out a target that has gone away.
    public private(set) var isCurrentVisible = false

    public init(config: CognitiveConfig = CognitiveConfig(), goal: String? = nil) {
        self.config = config
        self.goal = goal
    }

    public mutating func reset() {
        current = nil
        candidate = nil
        candidateFrames = 0
        isCurrentVisible = false
    }

    /// The one step for this frame, or nil when nothing is settled yet.
    public mutating func isolate(_ frame: VisionFrameResult) -> ActionStep? {
        let anchor = frame.fingertip?.box.mid ?? .center
        let eligible = frame.targets.filter(isEligible)
        isCurrentVisible = false
        guard let best = eligible.max(by: { score($0, anchor: anchor) < score($1, anchor: anchor) }) else {
            candidate = nil
            candidateFrames = 0
            // Keep the current target through a single dropped frame; the
            // caller decides when "nothing seen" has lasted long enough.
            return current.map { step(for: $0, anchor: anchor) }
        }

        // Current target still visible: refresh its box, and keep it unless the
        // best rival is clearly better.
        if let cur = current, let refreshed = eligible.first(where: { isSame($0, cur) }) {
            current = refreshed
            isCurrentVisible = true
            let rivalWins = !isSame(best, refreshed)
                && score(best, anchor: anchor) > score(refreshed, anchor: anchor) * config.switchMargin
            if !rivalWins {
                candidate = nil
                candidateFrames = 0
                return step(for: refreshed, anchor: anchor)
            }
        }

        // Settle the challenger.
        if let c = candidate, isSame(c, best) {
            candidateFrames += 1
        } else {
            candidateFrames = 1
        }
        candidate = best

        if candidateFrames >= config.settleFrames {
            current = best
            isCurrentVisible = true
            candidate = nil
            candidateFrames = 0
        }
        return current.map { step(for: $0, anchor: anchor) }
    }

    // MARK: - Scoring

    func score(_ d: Detection, anchor: ImagePoint) -> Float {
        let proximity = 1 - min(1, d.box.mid.distance(to: anchor) / 0.75)
        let size = min(1, d.box.area * 8)
        var s = 0.45 * proximity + 0.35 * d.confidence + 0.20 * size
        if let goal, matches(d, goal) { s += 1 }
        return s
    }

    private func isEligible(_ d: Detection) -> Bool {
        if config.ignoredLabels.contains(d.label) || excludedLabels.contains(d.label) { return false }
        if let goal { return matches(d, goal) }
        return true
    }

    private func matches(_ d: Detection, _ goal: String) -> Bool {
        let g = goal.lowercased()
        return d.label.lowercased().contains(g) || (d.text?.lowercased().contains(g) ?? false)
    }

    private func isSame(_ a: Detection, _ b: Detection) -> Bool {
        a.label == b.label && a.kind == b.kind && a.box.iou(b.box) >= config.sameTargetIoU
    }

    // MARK: - Wording

    private func step(for d: Detection, anchor: ImagePoint) -> ActionStep {
        let dx = d.box.midX - anchor.x
        let dy = d.box.midY - anchor.y
        let name = Self.spokenName(d)
        let instruction: String
        if (dx * dx + dy * dy).squareRoot() <= Alignment.tolerance {
            instruction = "\(name). You are on it."
        } else {
            instruction = "\(name). \(Self.direction(dx: dx, dy: dy))."
        }
        return ActionStep(
            targetLabel: d.label,
            instruction: Self.clip(instruction, words: config.maxInstructionWords),
            guidance: .align(dx: dx, dy: dy),
            target: d
        )
    }

    static func spokenName(_ d: Detection) -> String {
        switch d.kind {
        case .text: return (d.text ?? "Text").capitalizedFirst
        case .barcode: return "Barcode"
        case .object, .fingertip: return d.label.capitalizedFirst
        }
    }

    /// One direction at a time: the larger axis first. Two-axis directions
    /// ("left and up") are harder to follow for many users.
    static func direction(dx: Float, dy: Float) -> String {
        let far = max(abs(dx), abs(dy)) > 0.2
        let amount = far ? "" : " a little"
        if abs(dx) >= abs(dy) {
            return (dx > 0 ? "Move right" : "Move left") + amount
        }
        return (dy > 0 ? "Move down" : "Move up") + amount
    }

    static func clip(_ s: String, words: Int) -> String {
        let parts = s.split(separator: " ")
        guard parts.count > words else { return s }
        return parts.prefix(words).joined(separator: " ")
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
