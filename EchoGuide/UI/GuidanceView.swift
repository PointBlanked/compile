// Owner: Bryan. The screen is secondary: audio and haptics carry the product.
// What is shown is for low-vision users and helpers: one step, huge, yellow on
// black, Dynamic Type, and VoiceOver reads the same sentence the audio speaks.
// A helper gets one big Pause/Resume control and the current goal; nothing
// else competes with the step.

#if canImport(SwiftUI)
import SwiftUI
import Observation
import EchoGuideContracts

/// Anything that can listen for a spoken goal and return the goal words.
/// `VoiceGoalListener` (Audio) satisfies this with a one-line extension in
/// the app target: `extension VoiceGoalListener: GoalListening {}`.
public protocol GoalListening: Sendable {
    /// What was said, or nil when nothing was heard.
    func listen() async throws -> String?
}

/// What a heard phrase turned out to be.
public enum HeardIntent: Sendable, Equatable {
    /// Words to find (already stripped of filler).
    case goal(String)
    /// A question the app answered and spoke; the text is shown as feedback.
    case answered(String)
    case nothing
}

public typealias HeardInterpreter = @Sendable (String) async -> HeardIntent

@MainActor
@Observable
public final class GuidanceModel {
    public private(set) var state: AutomationState = .idle
    public private(set) var goal: String?
    /// Hazard zone the hand is approaching, for the amber banner.
    public private(set) var caution: String?
    public private(set) var isListening = false
    /// Step n of m of a running multi-step task, nil for single targets.
    public private(set) var taskProgress: AutomationEngine.TaskProgress?
    private var progressTask: Task<Void, Never>?
    /// Short feedback after a listening attempt ("Heard: start", "Did not catch that").
    public private(set) var listenResult: String?
    private var engine: AutomationEngine?
    private var listener: GoalListening?
    /// Turns a transcript into a goal or an answered question. Default: the
    /// phrase is the goal as spoken.
    public var interpret: HeardInterpreter = { .goal($0) }
    private var task: Task<Void, Never>?
    private var cautionTask: Task<Void, Never>?

    public init(listener: GoalListening? = nil) {
        self.listener = listener
    }

    /// A model pinned to one state, for SwiftUI previews and tests.
    public init(previewState: AutomationState, goal: String? = nil) {
        state = previewState
        self.goal = goal
    }

    public func bind(to engine: AutomationEngine) {
        self.engine = engine
        task?.cancel()
        task = Task { [weak self] in
            for await s in await engine.states() {
                self?.state = s
            }
        }
        cautionTask?.cancel()
        cautionTask = Task { [weak self] in
            for await c in await engine.cautions() {
                self?.caution = c
            }
        }
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            for await p in await engine.progress() {
                self?.taskProgress = p
            }
        }
        Task { [weak self] in
            let g = await engine.goal
            self?.goal = g
        }
    }

    public var isPaused: Bool { state == .idle }

    /// Helper control. Pausing silences haptics; resuming returns to scanning.
    public func togglePaused() {
        guard let engine else { return }
        let resume = isPaused
        Task {
            if resume { await engine.start() } else { await engine.stop() }
        }
    }

    public func setGoal(_ goal: String?) {
        let trimmed = goal?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.goal = value
        guard let engine else { return }
        Task { await engine.setGoal(value) }
    }

    public var canListen: Bool { listener != nil }

    /// Mic button: one short listening window, then the goal is set from what
    /// was said. Pauses nothing; guidance carries on underneath.
    public func listenForGoal() {
        guard let listener, !isListening else { return }
        isListening = true
        listenResult = nil
        let interpret = self.interpret
        Task { [weak self] in
            let heard = try? await listener.listen()
            guard let self else { return }
            guard let heard, !heard.isEmpty else {
                self.isListening = false
                self.listenResult = "Did not catch that"
                return
            }
            let intent = await interpret(heard)
            self.isListening = false
            switch intent {
            case .goal(let goal) where !goal.isEmpty:
                self.setGoal(goal)
                self.listenResult = "Heard: \(goal)"
            case .answered(let answer):
                self.listenResult = answer
            default:
                self.listenResult = "Did not catch that"
            }
        }
    }

    /// Banner text for an approaching hazard, in the words the audio speaks.
    var cautionLine: String? {
        caution.map { "Careful. \($0.capitalizedFirst) is close." }
    }

    /// The one line that matters, in the words the audio speaks.
    var headline: String {
        switch state {
        case .idle: return "Paused"
        case .scanning: return "Looking"
        case .guiding(let step), .onTarget(let step): return step.instruction
        case .completed(let what): return "Done. \(what)"
        case .warning(let what): return "Stop. \(what.capitalizedFirst)"
        }
    }

    /// Secondary line: what happens next, for a sighted helper reading over a shoulder.
    var detail: String? {
        switch state {
        case .idle: return "Tap Resume to start guiding"
        case .scanning: return goal.map { "Looking for \"\($0)\"" } ?? "Point the camera at the task"
        case .guiding: return "Follow the pulses"
        case .onTarget: return "Hold still"
        case .completed: return "Next step coming"
        case .warning: return "Move your hand away"
        }
    }

    var isWarning: Bool {
        if case .warning = state { return true }
        return false
    }

    var isOnTarget: Bool {
        if case .onTarget = state { return true }
        return false
    }

    var isCompleted: Bool {
        if case .completed = state { return true }
        return false
    }

    /// SF Symbol for the one direction the audio speaks, or nil when there is
    /// nothing to point at. Mirrors `CognitiveTaskIsolation.direction`: the
    /// larger axis wins, so the arrow and the words never disagree.
    var arrowSymbol: String? {
        guard case .guiding(let step) = state, case .align(let dx, let dy) = step.guidance else { return nil }
        return Self.arrowSymbol(dx: dx, dy: dy)
    }

    static func arrowSymbol(dx: Float, dy: Float) -> String? {
        guard (dx * dx + dy * dy).squareRoot() > Alignment.tolerance else { return nil }
        if abs(dx) >= abs(dy) { return dx > 0 ? "arrow.right" : "arrow.left" }
        return dy > 0 ? "arrow.down" : "arrow.up"
    }
}

/// Compact Find-mode panel for the bottom of a camera screen: the step in
/// huge type, the arrow, the dwell ring while holding, the caution banner,
/// and a one-row goal entry with the mic. Same model as GuidanceView.
public struct GuidancePanel: View {
    @State private var model: GuidanceModel
    @State private var goalDraft = ""
    public var dwellSeconds: TimeInterval

    public init(model: GuidanceModel, dwellSeconds: TimeInterval = 0.8) {
        _model = State(initialValue: model)
        self.dwellSeconds = dwellSeconds
    }

    private var accent: Color {
        if model.isWarning { return .red }
        if model.isOnTarget || model.isCompleted { return .green }
        return .yellow
    }

    public var body: some View {
        VStack(spacing: 10) {
            if let p = model.taskProgress {
                HStack(spacing: 8) {
                    Text(p.name.capitalizedFirst)
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                    Text("step \(p.step) of \(p.of)")
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .opacity(0.8)
                }
                .foregroundStyle(.black)
                .padding(.vertical, 6).padding(.horizontal, 12)
                .background(Color.yellow, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(p.name), step \(p.step) of \(p.of)")
            }
            if let caution = model.cautionLine, !model.isWarning {
                Label(caution, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.vertical, 8).padding(.horizontal, 14)
                    .background(Color.orange, in: Capsule())
            }

            HStack(spacing: 14) {
                if model.isOnTarget {
                    DwellRing(active: true, duration: dwellSeconds).frame(width: 64, height: 64)
                } else if let arrow = model.arrowSymbol {
                    Image(systemName: arrow)
                        .font(.system(size: 52, weight: .black))
                        .foregroundStyle(accent)
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                } else if model.isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 52, weight: .black))
                        .foregroundStyle(.green)
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.headline)
                        .font(.system(.title, design: .rounded, weight: .heavy))
                        .foregroundStyle(accent)
                        .minimumScaleFactor(0.6)
                        .lineLimit(2)
                    if let detail = model.detail {
                        Text(detail)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.headline)
            .accessibilityValue(model.detail ?? "")

            HStack(spacing: 10) {
                if model.canListen {
                    Button(action: model.listenForGoal) {
                        Image(systemName: model.isListening ? "waveform" : "mic.fill")
                            .font(.system(.title2, weight: .bold))
                            .frame(width: 52, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isListening ? .red : .blue)
                    .disabled(model.isListening)
                    .accessibilityLabel(model.isListening ? "Listening" : "Say the goal")
                }
                TextField(model.listenResult ?? "What to find, e.g. start", text: $goalDraft)
                    .font(.system(.body, design: .rounded))
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit { model.setGoal(goalDraft) }
                    .accessibilityLabel("Goal")
                if model.goal != nil {
                    Button("Clear") { goalDraft = ""; model.setGoal(nil) }
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(.yellow)
                }
            }
        }
        .padding(14)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(accent.opacity(0.6), lineWidth: 2))
        .animation(.easeInOut(duration: 0.2), value: model.isWarning)
        .onAppear { goalDraft = model.goal ?? "" }
    }
}

public struct GuidanceView: View {
    @State private var model: GuidanceModel
    /// Set to show the goal field; a helper types "start" or "microwave".
    public var showsGoalField: Bool
    @State private var goalDraft = ""

    public init(model: GuidanceModel, showsGoalField: Bool = true) {
        _model = State(initialValue: model)
        self.showsGoalField = showsGoalField
    }

    private var background: Color {
        if model.isWarning { return .red }
        if model.isOnTarget { return Color(red: 0, green: 0.35, blue: 0) }
        if model.isCompleted { return Color(red: 0, green: 0.55, blue: 0.1) }
        return .black
    }

    private var foreground: Color { model.isWarning ? .white : .yellow }

    public var body: some View {
        ZStack {
            background.ignoresSafeArea()
                .animation(.easeInOut(duration: 0.2), value: model.isWarning)
                .animation(.easeInOut(duration: 0.2), value: model.isCompleted)

            VStack(spacing: 16) {
                Spacer(minLength: 0)

                if let arrow = model.arrowSymbol {
                    Image(systemName: arrow)
                        .font(.system(size: 96, weight: .black))
                        .foregroundStyle(foreground)
                        .accessibilityHidden(true) // the headline already says the direction
                }

                Text(model.headline)
                    .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 24)
                    .accessibilityAddTraits(.updatesFrequently)

                if let detail = model.detail {
                    Text(detail)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .foregroundStyle(foreground.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                if let caution = model.cautionLine, !model.isWarning {
                    Label(caution, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 24)
                        .accessibilityAddTraits(.updatesFrequently)
                }

                Spacer(minLength: 0)

                if showsGoalField {
                    goalField
                }

                Button(action: model.togglePaused) {
                    Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 72)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isPaused ? .green : .gray)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .accessibilityHint(model.isPaused ? "Starts guiding again" : "Stops haptics and speech")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.headline)
        .accessibilityValue(model.detail ?? "")
    }

    private var goalField: some View {
        HStack(spacing: 12) {
            if model.canListen {
                Button(action: model.listenForGoal) {
                    Image(systemName: model.isListening ? "waveform" : "mic.fill")
                        .font(.system(.title, weight: .bold))
                        .frame(width: 60, height: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isListening ? .red : .blue)
                .disabled(model.isListening)
                .accessibilityLabel(model.isListening ? "Listening" : "Say the goal")
                .accessibilityHint("Say what to find, for example start button")
            }
            TextField(model.listenResult ?? "Goal, e.g. start", text: $goalDraft)
                .font(.system(.title3, design: .rounded))
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit { model.setGoal(goalDraft) }
                .accessibilityLabel("Goal")
                .accessibilityHint("Only matching buttons or words are offered")
            if model.goal != nil {
                Button("Clear") {
                    goalDraft = ""
                    model.setGoal(nil)
                }
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(foreground)
            }
        }
        .padding(.horizontal, 24)
        .onAppear { goalDraft = model.goal ?? "" }
    }
}
#endif
