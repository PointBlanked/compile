// Owner: Maxwell (app shell). First launch shows onboarding; after that the
// app opens straight into the live camera in Explore mode.

import AVFoundation
import SwiftUI
import UIKit
import EchoGuideAutomation

@main
struct EchoGuideApp: App {
    @State private var runtime = AppRuntime()
    @State private var onboarded = AppSettings.onboarded
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarded {
                    MainView(runtime: runtime)
                        .task { await runtime.start() }
                } else {
                    OnboardingView(cloudAvailable: runtime.cloudConfigured) {
                        AppSettings.onboarded = true
                        onboarded = true
                    }
                }
            }
            .preferredColorScheme(.dark)
            .statusBarHidden()
        }
        .onChange(of: phase) { _, new in
            // Guidance needs the camera; never let the screen lock mid-task.
            UIApplication.shared.isIdleTimerDisabled = new == .active
        }
    }
}
