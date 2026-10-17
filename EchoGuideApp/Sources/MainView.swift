// Owner: Maxwell. The live screen. Top: what the camera sees, with the last
// spoken sentence in huge text. Bottom: the three modes and the one action
// for the current mode. Find mode hands the screen to Bryan's GuidanceView.
// Everything here is also spoken; the screen is for low vision and helpers.

import ARKit
import AVFoundation
import SwiftUI
import EchoGuideAutomation
import EchoGuideInfra
import EchoGuideSpatial
import EchoGuideVision
import EchoGuideContracts

struct MainView: View {
    @Bindable var runtime: AppRuntime
    @State private var showSettings = false

    /// The one thing the automation engine is guiding to, for the overlay.
    private var target: Detection? {
        switch runtime.guidance.state {
        case .guiding(let step), .onTarget(let step): return step.target
        default: return nil
        }
    }

    var body: some View {
        ZStack {
            // The camera is always up: a helper or a judge sees what the
            // phone sees, with the AI's perception drawn on top.
            CameraPreview(arSession: runtime.lidar?.session, captureSession: runtime.camera?.session)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            PerceptionOverlay(frame: runtime.hud, target: target, imageAspect: runtime.imageAspect)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                if let error = runtime.cameraError {
                    Text(error)
                        .font(.title2.bold()).foregroundStyle(.white)
                        .padding(12).background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                }
                Spacer(minLength: 0)
                if runtime.mode == .find {
                    GuidancePanel(model: runtime.guidance).padding(.horizontal, 12)
                } else {
                    captionCard.padding(.horizontal, 12)
                }
                controls
            }
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showSettings) { SettingsView(runtime: runtime) }
        // VoiceOver's two-finger double tap: describe, from anywhere.
        .accessibilityAction(.magicTap) { Task { await runtime.describe() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(runtime.statusLine)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.6), in: Capsule())
                .accessibilityLabel("Status: \(runtime.statusLine)")
            Spacer()
            // Live perception readout: what the eye is seeing, and how fast.
            HStack(spacing: 6) {
                Circle().fill(runtime.hud.detections.isEmpty ? Color.gray : Color.green).frame(width: 8, height: 8)
                Text("\(runtime.hud.objects) things · \(Int(runtime.hud.inferenceMs)) ms")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
            .accessibilityHidden(true)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(.yellow)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.6), in: Circle())
            }
            .accessibilityLabel("Settings and benchmarks")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// What the agent just said, huge, with the two lines before it fading out.
    private var captionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(runtime.captions.dropLast().suffix(2).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Text(runtime.caption.isEmpty ? runtime.mode.spokenHelp : runtime.caption)
                .font(.system(.title, design: .rounded, weight: .heavy))
                .foregroundStyle(.yellow)
                .minimumScaleFactor(0.5)
                .lineLimit(3)
                .accessibilityLabel(runtime.caption.isEmpty ? runtime.mode.spokenHelp : runtime.caption)
                .accessibilityAddTraits(.updatesFrequently)
            if let summary = runtime.benchmarkSummary {
                Text(summary)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.yellow.opacity(0.5), lineWidth: 2))
        .animation(.easeOut(duration: 0.2), value: runtime.caption)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            TrialBanner(runtime: runtime)

            HStack(spacing: 8) {
                ForEach(AgentMode.allCases, id: \.self) { m in
                    Button { Task { await runtime.setMode(m) } } label: {
                        VStack(spacing: 3) {
                            Image(systemName: icon(m)).font(.title3)
                            Text(m.title).font(.system(.subheadline, design: .rounded, weight: .bold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .foregroundStyle(runtime.mode == m ? .black : .yellow)
                        .background(runtime.mode == m ? Color.yellow : Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .accessibilityLabel(m.title)
                    .accessibilityHint(m.spokenHelp)
                    .accessibilityAddTraits(runtime.mode == m ? .isSelected : [])
                }
                if runtime.mode == .read {
                    actionButton("Read all", icon: "text.viewfinder", hint: "Reads all the text the camera can see right now") { Task { await runtime.readNow() } }
                } else if runtime.mode == .explore {
                    actionButton(runtime.describing ? "Looking…" : "Describe", icon: "sparkles", hint: "Tells you everything in front of the camera") {
                        Task { await runtime.describe() }
                    }
                    .disabled(runtime.describing)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func actionButton(_ title: String, icon: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.system(.subheadline, design: .rounded, weight: .bold))
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .foregroundStyle(.black)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }

    private func icon(_ m: AgentMode) -> String {
        switch m {
        case .explore: return "eye.fill"
        case .find: return "hand.point.up.left.fill"
        case .read: return "text.viewfinder"
        }
    }
}

/// Shown while a benchmark trial runs: the tester taps the outcome.
struct TrialBanner: View {
    let runtime: AppRuntime
    @State private var task: String?
    @State private var started = Date()

    var body: some View {
        Group {
            if let task {
                VStack(spacing: 8) {
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        Text("Trial: \(task) · \(Int(ctx.date.timeIntervalSince(started))) s")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    HStack(spacing: 10) {
                        BigButton("Success") { finish(true) }
                        BigButton("Failed", filled: false) { finish(false) }
                    }
                }
                .padding(12)
                .background(Color.blue.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task {
            while !Task.isCancelled {
                let current = await runtime.trials.currentTask
                if current != task {
                    task = current
                    started = Date()
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private func finish(_ success: Bool) {
        Task {
            await runtime.trials.finish(success: success)
            task = nil
        }
    }
}
