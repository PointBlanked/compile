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

struct MainView: View {
    @Bindable var runtime: AppRuntime
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if runtime.mode == .find {
                GuidanceView(model: runtime.guidance)
            } else {
                live
            }
            controls
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showSettings) { SettingsView(runtime: runtime) }
        // VoiceOver's two-finger double tap: describe, from anywhere.
        .accessibilityAction(.magicTap) { Task { await runtime.describe() } }
    }

    private var header: some View {
        HStack {
            Text(runtime.statusLine)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel("Status: \(runtime.statusLine)")
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Settings and benchmarks")
        }
        .padding(.horizontal, 16)
    }

    private var live: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(arSession: runtime.lidar?.session, captureSession: runtime.camera?.session)
                .overlay(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                if let error = runtime.cameraError {
                    Text(error).font(.title2.bold()).foregroundStyle(.red)
                }
                Text(runtime.caption.isEmpty ? runtime.mode.spokenHelp : runtime.caption)
                    .font(.system(.title, design: .rounded, weight: .heavy))
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel(runtime.caption.isEmpty ? runtime.mode.spokenHelp : runtime.caption)
                    .accessibilityAddTraits(.updatesFrequently)
                if let summary = runtime.benchmarkSummary {
                    Text(summary)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(12)
        }
        .padding(.horizontal, 12)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            TrialBanner(runtime: runtime)

            HStack(spacing: 10) {
                ForEach(AgentMode.allCases, id: \.self) { m in
                    Button { Task { await runtime.setMode(m) } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: icon(m)).font(.title2)
                            Text(m.title).font(.system(.headline, design: .rounded, weight: .bold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .foregroundStyle(runtime.mode == m ? .black : .yellow)
                        .background(runtime.mode == m ? Color.yellow : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .accessibilityLabel(m.title)
                    .accessibilityHint(m.spokenHelp)
                    .accessibilityAddTraits(runtime.mode == m ? .isSelected : [])
                }
            }

            if runtime.mode == .read {
                BigButton("Read everything", hint: "Reads all the text the camera can see right now") { Task { await runtime.readNow() } }
            } else if runtime.mode == .explore {
                BigButton(runtime.describing ? "Looking…" : "Describe", hint: "Tells you everything in front of the camera") {
                    Task { await runtime.describe() }
                }
                .disabled(runtime.describing)
            }
        }
        .padding(16)
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
