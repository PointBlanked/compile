// Owner: Maxwell (app shell). The screen is Bryan's GuidanceView; this file
// only starts the runtime and keeps the phone awake while guiding.

import AVFoundation
import SwiftUI
import UIKit
import EchoGuideAutomation

@main
struct EchoGuideApp: App {
    @State private var runtime = AppRuntime()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottom) {
                GuidanceView(model: runtime.guidance)
                if let summary = runtime.benchmarkSummary {
                    Text(summary)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.8))
                        .accessibilityLabel("Benchmark result. \(summary)")
                }
            }
            .statusBarHidden()
            .task { await runtime.start() }
        }
        .onChange(of: phase) { _, new in
            // Guidance needs the camera; never let the screen lock mid-task.
            UIApplication.shared.isIdleTimerDisabled = new == .active
        }
    }
}

enum AudioSessionSetup {
    /// Voice mode needs the mic. Keep mixing and ducking so a phone call or
    /// music is never silenced, and route to the speaker, not the earpiece.
    static func enableRecording() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .voiceChat,
                          options: [.defaultToSpeaker, .mixWithOthers, .duckOthers, .allowBluetoothA2DP])
        try s.setActive(true)
    }
}
