// Owner: Bryan. Multi-step physical tasks: reach for a thing, grasp it, hold
// it the right way, aim it at something. Find mode guides one fingertip onto
// one flat control; this guides the whole hand through a sequence:
//
//   reach   "Phone to your right."  "Move right and down."   (hand -> object)
//   grasp   hand box covers the object box for a moment      "Got it."
//   orient  "Flip it so the lens faces away from you."       (vision model verifies)
//   aim     "Person ahead. Point up and right."              (hand -> target)
//   finish  "Lined up. Press the shutter."
//
// Pure logic over frames; AutomationEngine speaks, buzzes and asks the model.

import Foundation
import EchoGuideContracts

public struct TaskPlan: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Guide the hand onto a detected object and confirm the grasp.
        case reach(label: String, spoken: String)
        /// Say how to hold it; `check` is a yes/no question for the vision model, nil to trust the user.
        case orient(instruction: String, check: String?)
        /// Line the hand (holding the object) up with another detected thing.
        case aim(label: String, spoken: String)
        case finish(say: String)
    }

    public var name: String
    public var steps: [Step]

    public init(name: String, steps: [Step]) {
        self.name = name
        self.steps = steps
    }

    /// Pick up the phone or camera and aim it at a person: "take a photo".
    public static let photo = TaskPlan(name: "take a photo", steps: [
        .reach(label: "cell phone", spoken: "phone"),
        .orient(instruction: "Flip it so the lens faces away from you.",
                check: "Is the phone held with its screen toward the viewer and its camera lens facing away? Answer yes or no."),
        .aim(label: "person", spoken: "person"),
        .finish(say: "Lined up. Hold still and press the shutter."),
    ])

    /// Spoken goals that are tasks rather than single targets.
    public static func parse(_ goal: String) -> TaskPlan? {
        let g = goal.lowercased()
        if g.contains("photo") || g.contains("picture") || g.contains("take a pic") { return .photo }
        for (label, spoken) in [("remote", "remote"), ("cell phone", "phone"), ("cup", "cup"), ("bottle", "bottle")]
        where (g.hasPrefix("grab") || g.hasPrefix("pick up") || g.hasPrefix("get") || g.hasPrefix("hold")) && g.contains(spoken) {
            return TaskPlan(name: "pick up the \(spoken)", steps: [
                .reach(label: label, spoken: spoken),
                .finish(say: "You have the \(spoken)."),
            ])
        }
        return nil
    }
}

public struct TaskGuideConfig: Sendable {
    /// Share of the hand box that must lie over the object to count as a grasp.
    public var graspOverlap: Float = 0.5
    public var graspHold: TimeInterval = 0.4
    /// Aim is "lined up" within this normalized offset, held for `aimHold`.
    public var aimTolerance: Float = 0.08
    public var aimHold: TimeInterval = 0.5
    /// Repeat the same instruction at most this often.
    public var repeatAfter: TimeInterval = 2.5
    /// After an orient instruction, wait this long before checking.
    public var orientWait: TimeInterval = 3
    /// Below this offset on an axis the axis is not mentioned.
    public var deadZone: Float = 0.05

    public init() {}
}

public struct TaskGuide: Sendable {
    public enum Cue: Sendable, Equatable {
        case speak(String)
        /// Continuous haptic guidance, target minus hand.
        case guide(dx: Float, dy: Float)
        /// Haptic confirmation (grasped, lined up).
        case confirm
        /// Ask the vision model this yes/no question about the current frame.
        case check(String)
        case done(String)
    }

    public var config: TaskGuideConfig
    public private(set) var plan: TaskPlan
    public private(set) var index = 0
    public var isFinished: Bool { index >= plan.steps.count }
    public var progress: (step: Int, of: Int) { (min(index + 1, plan.steps.count), plan.steps.count) }

    private var lastSpoken: String?
    private var lastSpokenAt: TimeInterval = -.infinity
    private var holdSince: TimeInterval?
    /// The "where it is relative to your hand" line has been said for this step.
    private var introduced = false
    private var orientSpokenAt: TimeInterval?
    private var orientChecked = 0
    private var checkPending = false

    public init(plan: TaskPlan, config: TaskGuideConfig = TaskGuideConfig()) {
        self.plan = plan
        self.config = config
    }

    /// The spoken instruction for the current step, for the screen.
    public var currentInstruction: String? { lastSpoken }

    public mutating func step(_ frame: VisionFrameResult, now: TimeInterval) -> [Cue] {
        guard index < plan.steps.count else { return [] }
        switch plan.steps[index] {
        case .reach(let label, let spoken):
            return reach(label: label, spoken: spoken, frame, now)
        case .orient(let instruction, let check):
            return orient(instruction: instruction, check: check, now)
        case .aim(let label, let spoken):
            return aim(label: label, spoken: spoken, frame, now)
        case .finish(let say):
            index += 1
            return [.done(say)]
        }
    }

    /// Answer to the last `.check`. `nil` means no model was available.
    public mutating func checkResult(_ yes: Bool?, now: TimeInterval) -> [Cue] {
        guard checkPending, case .orient(let instruction, _) = plan.steps[safe: index] else { return [] }
        checkPending = false
        if yes == false, orientChecked < 2 {
            orientSpokenAt = now
            return [.speak("Not yet. " + instruction)]
        }
        advance(now)
        return [.speak(yes == true ? "Good." : "Okay.")]
    }

    // MARK: - Steps

    private mutating func reach(label: String, spoken: String, _ frame: VisionFrameResult, _ now: TimeInterval) -> [Cue] {
        let hand = frame.detections.first { $0.label == "hand" && $0.kind == .object }?.box
        guard let object = frame.detections.filter({ $0.label == label && $0.kind == .object }).max(by: { $0.confidence < $1.confidence })?.box else {
            holdSince = nil
            return say("I cannot see the \(spoken). Move the camera slowly.", now)
        }
        guard let hand else {
            holdSince = nil
            return say("Show me your hand.", now)
        }
        // Grasp: most of the hand lies over the object.
        let overlap = TaskGeometry.overlap(of: hand, over: object)
        if overlap >= config.graspOverlap {
            if holdSince == nil { holdSince = now }
            if now - (holdSince ?? now) >= config.graspHold {
                holdSince = nil
                advance(now)
                return [.confirm, .speak("Got it.")]
            }
            return [.guide(dx: 0, dy: 0)]
        }
        holdSince = nil
        let dx = object.midX - hand.midX, dy = object.midY - hand.midY
        var cues: [Cue] = [.guide(dx: dx, dy: dy)]
        let line: String
        if introduced {
            line = "Move \(TaskWording.direction(dx: dx, dy: dy, deadZone: config.deadZone))."
        } else {
            introduced = true
            line = "\(spoken.capitalizedFirst) \(TaskWording.relative(dx: dx, dy: dy, deadZone: config.deadZone))."
        }
        cues += say(line, now)
        return cues
    }

    private mutating func orient(instruction: String, check: String?, _ now: TimeInterval) -> [Cue] {
        if orientSpokenAt == nil {
            orientSpokenAt = now
            return say(instruction, now, force: true)
        }
        guard !checkPending, now - (orientSpokenAt ?? now) >= config.orientWait else { return [] }
        guard let check else {
            advance(now)
            return [.speak("Okay.")]
        }
        checkPending = true
        orientChecked += 1
        return [.check(check)]
    }

    private mutating func aim(label: String, spoken: String, _ frame: VisionFrameResult, _ now: TimeInterval) -> [Cue] {
        let hand = frame.detections.first { $0.label == "hand" && $0.kind == .object }?.box
        guard let target = frame.detections.filter({ $0.label == label && $0.kind == .object }).max(by: { $0.confidence < $1.confidence })?.box else {
            holdSince = nil
            return say("I cannot see a \(spoken). Turn slowly.", now)
        }
        guard let hand else {
            holdSince = nil
            return say("Show me your hand.", now)
        }
        let dx = target.midX - hand.midX, dy = target.midY - hand.midY
        let dist = (dx * dx + dy * dy).squareRoot()
        if dist <= config.aimTolerance {
            if holdSince == nil { holdSince = now }
            if now - (holdSince ?? now) >= config.aimHold {
                holdSince = nil
                advance(now)
                return [.confirm, .speak("Lined up.")]
            }
            return [.guide(dx: 0, dy: 0)]
        }
        holdSince = nil
        let line = "\(spoken.capitalizedFirst) \(TaskWording.place(target.midX)). Point \(TaskWording.direction(dx: dx, dy: dy, deadZone: config.deadZone))."
        return [.guide(dx: dx, dy: dy)] + say(line, now)
    }

    // MARK: - Helpers

    private mutating func advance(_ now: TimeInterval) {
        index += 1
        lastSpoken = nil
        lastSpokenAt = -.infinity
        holdSince = nil
        introduced = false
        orientSpokenAt = nil
        orientChecked = 0
        checkPending = false
    }

    private mutating func say(_ line: String, _ now: TimeInterval, force: Bool = false) -> [Cue] {
        guard force || line != lastSpoken || now - lastSpokenAt >= config.repeatAfter else { return [] }
        lastSpoken = line
        lastSpokenAt = now
        return [.speak(line)]
    }
}

public enum TaskGeometry {
    /// Share of `a`'s area that lies inside `b`.
    public static func overlap(of a: ImageRect, over b: ImageRect) -> Float {
        let ix = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
        let iy = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        return a.area > 0 ? (ix * iy) / a.area : 0
    }
}

public enum TaskWording {
    /// Two-axis direction, larger axis first: "right and down", "a little up".
    public static func direction(dx: Float, dy: Float, deadZone: Float = 0.05) -> String {
        var parts: [String] = []
        let h = abs(dx) >= deadZone ? (dx > 0 ? "right" : "left") : nil
        let v = abs(dy) >= deadZone ? (dy > 0 ? "down" : "up") : nil
        if abs(dx) >= abs(dy) { parts = [h, v].compactMap { $0 } } else { parts = [v, h].compactMap { $0 } }
        guard !parts.isEmpty else { return "a little closer" }
        let small = max(abs(dx), abs(dy)) < 0.15
        return (small ? "a little " : "") + parts.joined(separator: " and ")
    }

    /// Where the object is relative to the hand: "to your right and below".
    public static func relative(dx: Float, dy: Float, deadZone: Float = 0.05) -> String {
        let h = abs(dx) >= deadZone ? (dx > 0 ? "to your right" : "to your left") : nil
        let v = abs(dy) >= deadZone ? (dy > 0 ? "below your hand" : "above your hand") : nil
        let parts = [h, v].compactMap { $0 }
        return parts.isEmpty ? "right by your hand" : parts.joined(separator: " and ")
    }

    public static func place(_ x: Float) -> String {
        if x < 0.33 { return "on your left" }
        if x > 0.67 { return "on your right" }
        return "ahead"
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
