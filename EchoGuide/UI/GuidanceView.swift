// Owner: Bryan. The screen is secondary: audio and haptics carry the product.
// What is shown is for low-vision users and helpers: one step, huge, yellow on
// black, Dynamic Type, and VoiceOver reads the same sentence the audio speaks.
// A helper gets one big Pause/Resume control and the current goal; nothing
// else competes with the step.

#if canImport(SwiftUI)
import SwiftUI
import Observation
import EchoGuideContracts

@MainActor
@Observable
public final class GuidanceModel {
    public private(set) var state: AutomationState = .idle
    public private(set) var goal: String?
    private var engine: AutomationEngine?
    private var task: Task<Void, Never>?

    public init() {}

    public func bind(to engine: AutomationEngine) {
        self.engine = engine
        task?.cancel()
        task = Task { [weak self] in
            for await s in await engine.states() {
                self?.state = s
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
        return .black
    }

    private var foreground: Color { model.isWarning ? .white : .yellow }

    public var body: some View {
        ZStack {
            background.ignoresSafeArea()
                .animation(.easeInOut(duration: 0.2), value: model.isWarning)

            VStack(spacing: 16) {
                Spacer(minLength: 0)

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
            TextField("Goal, e.g. start", text: $goalDraft)
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
