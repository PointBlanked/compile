// Owner: Bryan. The screen is secondary: audio and haptics carry the product.
// What is shown is for low-vision users and carers: one step, huge, yellow on
// black, Dynamic Type, and VoiceOver reads the same sentence the audio speaks.

#if canImport(SwiftUI)
import SwiftUI
import Observation
import EchoGuideContracts

@MainActor
@Observable
public final class GuidanceModel {
    public private(set) var state: AutomationState = .idle
    private var task: Task<Void, Never>?

    public init() {}

    public func bind(to engine: AutomationEngine) {
        task?.cancel()
        task = Task { [weak self] in
            for await s in await engine.states() {
                self?.state = s
            }
        }
    }

    var headline: String {
        switch state {
        case .idle: return "Paused"
        case .scanning: return "Looking"
        case .guiding(let step), .onTarget(let step): return step.instruction
        case .completed(let what): return "Done. \(what)"
        case .warning(let what): return "Stop. \(what.capitalizedFirst)"
        }
    }

    var isWarning: Bool {
        if case .warning = state { return true }
        return false
    }
}

public struct GuidanceView: View {
    @State private var model: GuidanceModel

    public init(model: GuidanceModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        ZStack {
            (model.isWarning ? Color.red : Color.black).ignoresSafeArea()
            Text(model.headline)
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .foregroundStyle(model.isWarning ? Color.white : Color.yellow)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .padding(24)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.headline)
    }
}
#endif
