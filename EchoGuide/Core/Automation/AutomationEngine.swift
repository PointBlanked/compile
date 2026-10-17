// Owner: Bryan. The hands-free state machine. Every inferred frame goes in;
// at most one spoken instruction, one haptic stream and (rarely) one tool call
// come out. No prompt from the user is ever required:
//
//   scanning -> guiding(step) -> onTarget(dwell) -> completed -> scanning
//                    |
//                 warning (digital fence) preempts everything
//
// Resolution order per step: local (confidence >= threshold) -> plugin tool
// (if one claims the target) -> cloud router (low confidence, consent, online).

import Foundation
import EchoGuideContracts

public enum AutomationState: Sendable, Equatable {
    case idle
    case scanning
    case guiding(ActionStep)
    case onTarget(ActionStep)
    case completed(String)
    /// Hand inside a spatial hazard zone.
    case warning(String)
}

public struct AutomationConfig: Sendable {
    /// Below this, the step is checked with the cloud router (if one is wired).
    public var cloudConfidenceThreshold: Float = 0.85
    /// Holding the finger on target this long is the confirmation gesture.
    public var dwellToConfirm: TimeInterval = 0.8
    /// No target for this long returns to scanning and silences haptics.
    public var lostTargetTimeout: TimeInterval = 1.2
    /// Re-announce the same step at most this often.
    public var repeatInstructionAfter: TimeInterval = 6
    /// Directional ping cadence while the target is off to one side.
    public var pingInterval: TimeInterval = 0.9
    public var fenceWarningInterval: TimeInterval = 3
    /// A finished target is off the menu for this long, so "done" moves on to
    /// the next step instead of guiding the finger back to the same button.
    public var completedCooldown: TimeInterval = 8

    public init() {}
}

public actor AutomationEngine {
    public private(set) var state: AutomationState = .idle
    public let config: AutomationConfig

    private var isolation: CognitiveTaskIsolation
    private let haptics: HapticCueing
    private let audio: SpatialAudioCueing
    private let depth: DepthProviding?
    private let router: ReasoningRouting?
    private let tools: ToolInvoking?

    private var lastSpokenLabel: String?
    private var lastSpokenAt: TimeInterval = -.infinity
    private var lastPingAt: TimeInterval = -.infinity
    private var lastSeenAt: TimeInterval = -.infinity
    private var onTargetSince: TimeInterval?
    private var completedUntil: [String: TimeInterval] = [:]
    private var lastFenceWarning: [String: TimeInterval] = [:]
    private var routedLabels: Set<String> = []
    private var continuations: [UUID: AsyncStream<AutomationState>.Continuation] = [:]

    public init(
        haptics: HapticCueing,
        audio: SpatialAudioCueing,
        depth: DepthProviding? = nil,
        router: ReasoningRouting? = nil,
        tools: ToolInvoking? = nil,
        cognitive: CognitiveTaskIsolation = CognitiveTaskIsolation(),
        config: AutomationConfig = AutomationConfig()
    ) {
        self.haptics = haptics
        self.audio = audio
        self.depth = depth
        self.router = router
        self.tools = tools
        self.isolation = cognitive
        self.config = config
    }

    /// For the UI. Each subscriber gets the current state first.
    public func states() -> AsyncStream<AutomationState> {
        AsyncStream { c in
            let id = UUID()
            c.yield(state)
            continuations[id] = c
            c.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
        }
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    /// Narrow the engine to one task ("start", "microwave"); nil for open scanning.
    public func setGoal(_ goal: String?) {
        isolation.goal = goal
        isolation.reset()
        completedUntil = [:]
        lastSpokenLabel = nil
        onTargetSince = nil
    }

    public var goal: String? { isolation.goal }

    public func start() {
        forgetTarget()
        transition(.scanning)
    }

    public func stop() async {
        forgetTarget()
        transition(.idle)
        await haptics.stop()
    }

    private func forgetTarget() {
        isolation.reset()
        onTargetSince = nil
        lastSpokenLabel = nil
        lastSeenAt = -.infinity
    }

    // MARK: - Input

    public func ingest(_ frame: VisionFrameResult, fence: FenceEvent? = nil) async {
        guard state != .idle else { return }
        let now = frame.timestamp

        if let fence, await handle(fence, at: now) { return }

        // Recently finished targets are off the menu; prune expired ones.
        completedUntil = completedUntil.filter { $0.value > now }
        let excluded = Set(completedUntil.keys)
        if excluded != isolation.excludedLabels { isolation.excludedLabels = excluded }

        let step = isolation.isolate(frame)
        if step != nil, isolation.isCurrentVisible { lastSeenAt = now }

        // Nothing settled, or the settled target has not been seen for a while.
        guard let step, isolation.isCurrentVisible || now - lastSeenAt <= config.lostTargetTimeout else {
            if now - lastSeenAt > config.lostTargetTimeout, state != .scanning {
                // Drop only a remembered target; a challenger still settling
                // keeps its frame count (frames are sparse in a still scene).
                if step != nil { isolation.reset() }
                onTargetSince = nil
                lastSpokenLabel = nil
                await haptics.stop()
                transition(.scanning)
            }
            return
        }
        // The target dropped out of this frame: keep the last cue going, but
        // do not announce, confirm or complete against a remembered box.
        guard isolation.isCurrentVisible else { return }

        await announceIfNeeded(step, at: now)

        guard case .align(let dx, let dy) = step.guidance else {
            transition(.guiding(step))
            return
        }

        let aligned = (dx * dx + dy * dy).squareRoot() <= Alignment.tolerance
        if !aligned {
            onTargetSince = nil
            let metres: Float? = if let tip = frame.fingertip { await depth?.depth(at: tip.box.mid) } else { nil }
            await haptics.guide(offset: dx, dy, distanceMetres: metres)
            if abs(dx) > 0.1, now - lastPingAt >= config.pingInterval {
                lastPingAt = now
                await audio.ping(azimuth: max(-1, min(1, dx * 2)) * .pi / 2, elevation: 0)
            }
            transition(.guiding(step))
            return
        }

        if onTargetSince == nil {
            onTargetSince = now
            await haptics.confirm()
        }
        transition(.onTarget(step))

        if let since = onTargetSince, now - since >= config.dwellToConfirm {
            await complete(step, at: now)
        }
    }

    /// Location-fence events arrive without a frame (screen may be off).
    public func ingest(fence: FenceEvent, at time: TimeInterval) async {
        _ = await handle(fence, at: time)
    }

    // MARK: - Steps

    private func announceIfNeeded(_ step: ActionStep, at now: TimeInterval) async {
        let isNew = step.targetLabel != lastSpokenLabel
        guard isNew || now - lastSpokenAt >= config.repeatInstructionAfter else { return }
        lastSpokenLabel = step.targetLabel
        lastSpokenAt = now

        var sentence = step.instruction
        if isNew, let target = step.target, let router,
           target.confidence < config.cloudConfidenceThreshold, !routedLabels.contains(step.targetLabel) {
            routedLabels.insert(step.targetLabel)
            let outcome = await router.resolve(ReasoningQuery(
                question: "In under eight words, what is this and what should the user do with it?",
                detections: [target],
                localConfidence: target.confidence
            ))
            if outcome.source == .cloud, !outcome.answer.isEmpty { sentence = outcome.answer }
        }

        let azimuth: Float
        if case .align(let dx, _) = step.guidance { azimuth = max(-1, min(1, dx * 2)) * .pi / 2 } else { azimuth = 0 }
        await audio.speak(sentence, azimuth: azimuth)
    }

    private func complete(_ step: ActionStep, at now: TimeInterval) async {
        onTargetSince = nil
        completedUntil[step.targetLabel] = now + config.completedCooldown

        await haptics.stop()

        guard let target = step.target, let tools, let match = await tools.match(target) else {
            transition(.completed(step.targetLabel))
            return
        }
        // The dwell just held is the deliberate confirmation physical tools require.
        do {
            let said = try await tools.invoke(match)
            await audio.speak(said, azimuth: 0)
            transition(.completed(said))
        } catch {
            await audio.speak("That did not work.", azimuth: 0)
            transition(.completed(step.targetLabel))
        }
    }

    // MARK: - Fence

    /// Returns true when the fence event takes over this frame.
    private func handle(_ event: FenceEvent, at now: TimeInterval) async -> Bool {
        switch event {
        case .breached(let zone):
            // A hazard cancels any dwell in progress: the finger must settle on
            // the target again, from scratch, before a physical tool can fire.
            onTargetSince = nil
            await haptics.warn()
            if throttle(zone, at: now) { await audio.speak("Stop. \(zone.capitalizedFirst).", azimuth: 0) }
            transition(.warning(zone))
            return true
        case .approaching(let zone, _):
            if throttle(zone, at: now) {
                await haptics.warn()
                await audio.speak("Careful. \(zone.capitalizedFirst) is close.", azimuth: 0)
            }
            return false
        }
    }

    private func throttle(_ key: String, at now: TimeInterval) -> Bool {
        if let last = lastFenceWarning[key], now - last < config.fenceWarningInterval { return false }
        lastFenceWarning[key] = now
        return true
    }

    private func transition(_ s: AutomationState) {
        guard s != state else { return }
        state = s
        for c in continuations.values { c.yield(s) }
    }
}
