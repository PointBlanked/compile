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
    /// While scanning with nothing to offer, say so this often. Silence is
    /// ambiguous for a blind user: is it working, or has it crashed?
    public var scanningReminderInterval: TimeInterval = 8
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
    /// Current camera frame as JPEG, for the task guide's orientation checks.
    private let jpegProvider: (@Sendable () -> Data?)?
    private var task: TaskGuide?
    private var checkInFlight = false
    private var progressContinuations: [UUID: AsyncStream<TaskProgress?>.Continuation] = [:]

    private var lastSpokenLabel: String?
    /// Where the last announced target was, so a different OCR reading of the
    /// same button at the same place is not announced again.
    private var lastSpokenBox: ImageRect?
    private var lastSpokenPlainLabel: String?
    private var lastSpokenAt: TimeInterval = -.infinity
    private var lastReminderAt: TimeInterval = -.infinity
    private var lastPingAt: TimeInterval = -.infinity
    private var lastSeenAt: TimeInterval = -.infinity
    private var onTargetSince: TimeInterval?
    private var completedUntil: [String: TimeInterval] = [:]
    private var completedBoxes: [String: CognitiveTaskIsolation.ExcludedRegion] = [:]
    private var lastFenceWarning: [String: TimeInterval] = [:]
    private var routedLabels: Set<String> = []
    private var continuations: [UUID: AsyncStream<AutomationState>.Continuation] = [:]
    private var cautionContinuations: [UUID: AsyncStream<String?>.Continuation] = [:]
    /// Hazard zone the hand is approaching right now, nil when clear. Spoken
    /// as "Careful", shown on screen as a banner; it never changes `state`.
    public private(set) var caution: String?

    public init(
        haptics: HapticCueing,
        audio: SpatialAudioCueing,
        depth: DepthProviding? = nil,
        router: ReasoningRouting? = nil,
        tools: ToolInvoking? = nil,
        cognitive: CognitiveTaskIsolation = CognitiveTaskIsolation(),
        config: AutomationConfig = AutomationConfig(),
        jpegProvider: (@Sendable () -> Data?)? = nil
    ) {
        self.haptics = haptics
        self.audio = audio
        self.depth = depth
        self.router = router
        self.tools = tools
        self.jpegProvider = jpegProvider
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

    /// For the UI: the zone being approached, nil when the hand is clear.
    public func cautions() -> AsyncStream<String?> {
        AsyncStream { c in
            let id = UUID()
            c.yield(caution)
            cautionContinuations[id] = c
            c.onTermination = { [weak self] _ in Task { await self?.removeCautionContinuation(id) } }
        }
    }

    private func removeCautionContinuation(_ id: UUID) { cautionContinuations[id] = nil }

    private func setCaution(_ zone: String?) {
        guard zone != caution else { return }
        caution = zone
        for c in cautionContinuations.values { c.yield(zone) }
    }

    /// Narrow the engine to one task ("start", "microwave"); nil for open scanning.
    /// A goal that names a multi-step task ("take a photo") starts a TaskPlan instead.
    public func setGoal(_ goal: String?) {
        if let goal, let plan = TaskPlan.parse(goal) {
            setPlan(plan)
            return
        }
        setPlan(nil)
        isolation.goal = goal
        isolation.reset()
        completedUntil = [:]
        completedBoxes = [:]
        routedLabels = []
        lastSpokenLabel = nil; lastSpokenBox = nil; lastSpokenPlainLabel = nil
        onTargetSince = nil
    }

    public var goal: String? { task?.plan.name ?? isolation.goal }

    /// Step n of m for the screen; nil when no task is running.
    public struct TaskProgress: Sendable, Equatable {
        public var name: String
        public var step: Int
        public var of: Int
    }

    public var taskProgress: TaskProgress? {
        guard let task, !task.isFinished else { return nil }
        return TaskProgress(name: task.plan.name, step: task.progress.step, of: task.progress.of)
    }

    public func progress() -> AsyncStream<TaskProgress?> {
        AsyncStream { c in
            let id = UUID()
            c.yield(taskProgress)
            progressContinuations[id] = c
            c.onTermination = { [weak self] _ in Task { await self?.removeProgressContinuation(id) } }
        }
    }

    private func removeProgressContinuation(_ id: UUID) { progressContinuations[id] = nil }

    private func publishProgress() {
        let p = taskProgress
        for c in progressContinuations.values { c.yield(p) }
    }

    /// Run a multi-step physical task; nil stops it and returns to single targets.
    public func setPlan(_ plan: TaskPlan?) {
        task = plan.map { TaskGuide(plan: $0) }
        isolation.goal = nil
        isolation.reset()
        checkInFlight = false
        publishProgress()
    }

    public func start() {
        forgetTarget()
        lastReminderAt = -.infinity
        transition(.scanning)
    }

    public func stop() async {
        forgetTarget()
        setCaution(nil)
        task = nil
        publishProgress()
        transition(.idle)
        await haptics.stop()
    }

    private func forgetTarget() {
        isolation.reset()
        onTargetSince = nil
        lastSpokenLabel = nil; lastSpokenBox = nil; lastSpokenPlainLabel = nil
        lastSeenAt = -.infinity
    }

    // MARK: - Input

    public func ingest(_ frame: VisionFrameResult, fence: FenceEvent? = nil) async {
        guard state != .idle else { return }
        let now = frame.timestamp

        if case .approaching(let zone, _)? = fence { setCaution(zone) } else { setCaution(nil) }
        if let fence, await handle(fence, at: now) { return }

        if task != nil {
            await runTask(frame, at: now)
            return
        }

        // Recently finished targets are off the menu; prune expired ones.
        completedUntil = completedUntil.filter { $0.value > now }
        completedBoxes = completedBoxes.filter { completedUntil[$0.key] != nil }
        let excluded = Set(completedUntil.keys)
        if excluded != isolation.excludedLabels { isolation.excludedLabels = excluded }
        let regions = Array(completedBoxes.values)
        if regions != isolation.excludedRegions { isolation.excludedRegions = regions }

        let step = isolation.isolate(frame)
        if step != nil, isolation.isCurrentVisible { lastSeenAt = now }

        // Nothing settled, or the settled target has not been seen for a while.
        guard let step, isolation.isCurrentVisible || now - lastSeenAt <= config.lostTargetTimeout else {
            if step == nil, state == .scanning { await remindScanning(at: now) }
            if now - lastSeenAt > config.lostTargetTimeout, state != .scanning {
                // Drop only a remembered target; a challenger still settling
                // keeps its frame count (frames are sparse in a still scene).
                if step != nil { isolation.reset() }
                onTargetSince = nil
                lastSpokenLabel = nil; lastSpokenBox = nil; lastSpokenPlainLabel = nil
                await haptics.stop()
                transition(.scanning)
            }
            return
        }
        // The target dropped out of this frame: keep the last cue going, but
        // do not announce, confirm or complete against a remembered box.
        guard isolation.isCurrentVisible else { return }

        // A read-only tool (product lookup on a barcode) needs no finger and
        // no dwell: seeing the thing is the request.
        if await fireReadOnlyTool(for: step, at: now) { return }

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

    // MARK: - Tasks

    private func runTask(_ frame: VisionFrameResult, at now: TimeInterval) async {
        guard var guide = task else { return }
        let cues = guide.step(frame, now: now)
        task = guide
        await apply(cues, frame: frame, at: now)
    }

    private func apply(_ cues: [TaskGuide.Cue], frame: VisionFrameResult, at now: TimeInterval) async {
        for cue in cues {
            switch cue {
            case .speak(let line):
                let step = ActionStep(targetLabel: task?.plan.name ?? "task", instruction: line, guidance: .announce, target: nil)
                transition(.guiding(step))
                await audio.speak(line, azimuth: 0)
                publishProgress()
            case .guide(let dx, let dy):
                if dx == 0, dy == 0 { await haptics.stop() } else { await haptics.guide(offset: dx, dy, distanceMetres: nil) }
            case .confirm:
                await haptics.confirm()
            case .check(let question):
                guard !checkInFlight else { continue }
                checkInFlight = true
                let jpeg = jpegProvider?()
                Task { await self.runCheck(question, jpeg: jpeg, detections: frame.detections) }
            case .done(let say):
                await haptics.stop()
                await audio.speak(say, azimuth: 0)
                transition(.completed(say))
                task = nil
                publishProgress()
            }
        }
    }

    /// Yes/no question to the vision model about the current frame; nil when no model.
    private func runCheck(_ question: String, jpeg: Data?, detections: [Detection]) async {
        var answer: Bool?
        if let router, jpeg != nil {
            let out = await router.resolve(ReasoningQuery(question: question + " Reply with only yes or no.", detections: detections.filter { $0.kind == .object }, localConfidence: 0, jpeg: jpeg, maxWords: 3, timeout: 10))
            if out.source == .cloud { answer = out.answer.lowercased().hasPrefix("yes") }
        }
        checkInFlight = false
        guard var guide = task else { return }
        let cues = guide.checkResult(answer, now: Date().timeIntervalSince1970)
        task = guide
        await apply(cues, frame: VisionFrameResult(frameIndex: 0, timestamp: 0, detections: detections, inferenceMs: 0), at: 0)
    }

    // MARK: - Steps

    /// Identity of a step for exclusion and announcement: label, or
    /// label|content for text and barcodes (see `Detection.stepKey`).
    private func key(_ step: ActionStep) -> String { step.target?.stepKey ?? step.targetLabel }

    private func remindScanning(at now: TimeInterval) async {
        let since = max(lastReminderAt, lastSpokenAt)
        guard now - since >= config.scanningReminderInterval else { return }
        lastReminderAt = now
        await audio.speak(isolation.goal.map { "Looking for \($0)." } ?? "Looking.", azimuth: 0)
    }

    /// True when a `.none` side-effect tool claimed the target and was run.
    private func fireReadOnlyTool(for step: ActionStep, at now: TimeInterval) async -> Bool {
        guard let target = step.target, let tools, let match = await tools.match(target), match.sideEffect == .none else { return false }
        markCompleted(step, at: now)
        onTargetSince = nil
        await haptics.stop()
        do {
            let said = try await tools.invoke(match)
            lastSpokenLabel = key(step)
            lastSpokenPlainLabel = step.targetLabel
            lastSpokenBox = target.box
            lastSpokenAt = now
            await audio.speak(said, azimuth: 0)
            transition(.completed(said))
        } catch {
            unmarkCompleted(step)
            await audio.speak("I could not read that.", azimuth: 0)
            transition(.completed(step.targetLabel))
        }
        return true
    }

    /// Same thing as last announced: same key, or same label at the same place
    /// (OCR read the characters differently this frame).
    private func isSameAsLastSpoken(_ step: ActionStep) -> Bool {
        if key(step) == lastSpokenLabel { return true }
        guard step.target?.kind == .text, step.targetLabel == lastSpokenPlainLabel,
              let box = step.target?.box, let last = lastSpokenBox else { return false }
        return box.iou(last) >= 0.3
    }

    /// Remember a finished target by key and by place for the cooldown.
    private func markCompleted(_ step: ActionStep, at now: TimeInterval) {
        completedUntil[key(step)] = now + config.completedCooldown
        if let t = step.target, t.kind == .text { completedBoxes[key(step)] = .init(label: t.label, box: t.box) }
    }

    private func unmarkCompleted(_ step: ActionStep) {
        completedUntil[key(step)] = nil
        completedBoxes[key(step)] = nil
    }

    private func announceIfNeeded(_ step: ActionStep, at now: TimeInterval) async {
        let isNew = !isSameAsLastSpoken(step)
        guard isNew || now - lastSpokenAt >= config.repeatInstructionAfter else { return }
        lastSpokenLabel = key(step)
        lastSpokenPlainLabel = step.targetLabel
        lastSpokenBox = step.target?.box
        lastSpokenAt = now

        var sentence = step.instruction
        if isNew, let target = step.target, let router,
           target.confidence < config.cloudConfidenceThreshold, !routedLabels.contains(key(step)) {
            routedLabels.insert(key(step))
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
        markCompleted(step, at: now)

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
            // Not excluded: the user should be able to settle on it and try again.
            unmarkCompleted(step)
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
