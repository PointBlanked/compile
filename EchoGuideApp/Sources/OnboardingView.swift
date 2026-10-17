// Owner: Maxwell. First-launch setup, built for someone who cannot see the
// screen: every page speaks itself (unless VoiceOver is already reading),
// every control is one large button, and nothing is required except the
// camera. Six short steps, under two minutes.

import AVFoundation
import Speech
import SwiftUI
import EchoGuideSpatial

struct OnboardingView: View {
    let cloudAvailable: Bool
    let onFinish: () -> Void

    enum Step: Int, CaseIterable { case welcome, camera, modes, feel, voice, privacy, ready }

    @State private var step: Step = .welcome
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var voiceGranted = false
    @State private var cloudPhotos = AppSettings.imageConsent
    @State private var narrator = Narrator()
    @State private var haptics = SpatialHapticEngine()
    @State private var demoRunning = false

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                .tint(.yellow)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(title)
                        .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                        .foregroundStyle(.yellow)
                        .accessibilityAddTraits(.isHeader)
                    Text(bodyText)
                        .font(.system(.title2, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    extra
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 12) {
                BigButton(primaryLabel, hint: primaryHint, filled: true) { Task { await primaryAction() } }
                    .disabled(demoRunning)
                if let secondary = secondaryLabel {
                    BigButton(secondary, filled: false) { advance() }
                }
            }
            .padding(24)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { narrator.say(spoken) }
        .onChange(of: step) { _, _ in narrator.say(spoken) }
    }

    // MARK: - Copy

    private var title: String {
        switch step {
        case .welcome: return "EchoGuide"
        case .camera: return "Your camera"
        case .modes: return "Three ways to use it"
        case .feel: return "Feel the guidance"
        case .voice: return "Your voice"
        case .privacy: return "Richer descriptions"
        case .ready: return "You're ready"
        }
    }

    private var bodyText: String {
        switch step {
        case .welcome:
            return "EchoGuide is your eyes through the phone camera. It tells you what is around you, reads text, and guides your hand to buttons. You do not need to look at the screen."
        case .camera:
            return cameraStatus == .denied || cameraStatus == .restricted
                ? "Camera access is off. EchoGuide cannot work without it. Open Settings, choose EchoGuide, and turn on Camera."
                : "EchoGuide watches through the back camera. Video stays on your phone."
        case .modes:
            return "Explore tells you what comes into view, and warns you about things in your path.\n\nFind guides your finger to one thing you ask for, like the start button.\n\nRead reads signs, letters and labels out loud.\n\nAnd any time, Describe tells you everything in front of you."
        case .feel:
            return "In Find, the phone pulses. Faster pulses mean your finger is closer. Two quick taps mean you are on it. Hold still there and EchoGuide confirms."
        case .voice:
            return "You can say what to find, like \"find the start button\". Speech is understood on your phone. This is optional."
        case .privacy:
            return cloudAvailable
                ? "Describe works on your phone. If you allow it, EchoGuide can also send a photo to an AI model for a fuller description. Photos are not stored by EchoGuide. You can change this later in Settings."
                : "Everything in this version runs on your phone, even in Airplane Mode. Nothing is sent anywhere."
        case .ready:
            return "Hold the phone upright at chest height with the camera facing away from you. EchoGuide starts in Explore. Use the large buttons at the bottom of the screen to switch modes. With VoiceOver, a two-finger double tap means Describe."
        }
    }

    private var spoken: String { "\(title). \(bodyText) \(primaryLabel)." }

    @ViewBuilder private var extra: some View {
        switch step {
        case .privacy where cloudAvailable:
            Toggle(isOn: $cloudPhotos) {
                Text("Send photos for richer descriptions")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .tint(.yellow)
            .padding(.vertical, 8)
            .onChange(of: cloudPhotos) { _, on in AppSettings.imageConsent = on }
        case .voice where voiceGranted:
            Label("Voice is on", systemImage: "checkmark.circle.fill")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.green)
        default:
            EmptyView()
        }
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Get started"
        case .camera:
            switch cameraStatus {
            case .authorized: return "Continue"
            case .denied, .restricted: return "Open Settings"
            default: return "Allow camera"
            }
        case .modes: return "Continue"
        case .feel: return demoRunning ? "Feel the phone…" : "Try it"
        case .voice: return voiceGranted ? "Continue" : "Turn on voice"
        case .privacy: return "Continue"
        case .ready: return "Start"
        }
    }

    private var primaryHint: String? {
        step == .feel ? "Plays the guidance pulses from far to close, then the on-target taps" : nil
    }

    private var secondaryLabel: String? {
        switch step {
        case .feel: return "Skip"
        case .voice: return voiceGranted ? nil : "Not now"
        default: return nil
        }
    }

    // MARK: - Actions

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next } else { finish() }
    }

    private func finish() {
        narrator.stop()
        onFinish()
    }

    private func primaryAction() async {
        switch step {
        case .camera:
            switch cameraStatus {
            case .authorized:
                advance()
            case .denied, .restricted:
                if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
            default:
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                if granted { advance() } else { narrator.say(bodyText) }
            }
        case .feel:
            demoRunning = true
            narrator.say("Far.")
            await haptics.guide(offset: 0.45, 0, distanceMetres: nil)
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            narrator.say("Closer.")
            await haptics.guide(offset: 0.18, 0, distanceMetres: nil)
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            narrator.say("Almost.")
            await haptics.guide(offset: 0.06, 0, distanceMetres: nil)
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await haptics.stop()
            await haptics.confirm()
            narrator.say("On it.")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            demoRunning = false
            advance()
        case .voice:
            if voiceGranted { advance(); return }
            let speech = await VoiceGoalListener.requestAuthorization()
            let mic = await AVAudioApplication.requestRecordPermission()
            voiceGranted = speech && mic
            if voiceGranted { narrator.say("Voice is on.") }
            advance()
        case .ready:
            finish()
        default:
            advance()
        }
    }
}

/// Speaks onboarding pages, unless VoiceOver is already reading the screen.
@MainActor
final class Narrator {
    private let synth = AVSpeechSynthesizer()

    func say(_ text: String) {
        guard !UIAccessibility.isVoiceOverRunning else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        u.prefersAssistiveTechnologySettings = true
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }
}

/// The one button style in the app: full width, 72 pt tall, high contrast.
struct BigButton: View {
    let label: String
    let hint: String?
    let filled: Bool
    let action: () -> Void

    init(_ label: String, hint: String? = nil, filled: Bool = true, action: @escaping () -> Void) {
        self.label = label
        self.hint = hint
        self.filled = filled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 72)
                .foregroundStyle(filled ? .black : .yellow)
                .background(filled ? Color.yellow : Color.clear, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.yellow, lineWidth: filled ? 0 : 3))
        }
        .accessibilityHint(hint ?? "")
    }
}
