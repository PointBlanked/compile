#!/usr/bin/env bash
# Recreates the AutoVision Audio Engine repo from scratch, commits, and pushes.
# Usage: ./setup_repo.sh [target-dir]   (REMOTE_URL overrides the GitHub remote)
set -euo pipefail

TARGET="${1:-auto-vision-audio-engine}"
REMOTE_URL="${REMOTE_URL:-https://github.com/PointBlanked/compile.git}"

mkdir -p .github .github/workflows EchoGuide/Core/Audio EchoGuide/Core/Automation EchoGuide/Core/Camera EchoGuide/Core/Cognitive EchoGuide/Core/Contracts EchoGuide/Core/Depth EchoGuide/Core/Fence EchoGuide/Core/Haptics EchoGuide/Core/Plugins EchoGuide/Core/Router EchoGuide/Core/Vision EchoGuide/UI EchoGuideApp EchoGuideApp/Assets.xcassets EchoGuideApp/Assets.xcassets/AppIcon.appiconset EchoGuideApp/EchoGuideApp.xcodeproj EchoGuideApp/EchoGuideApp.xcodeproj/xcshareddata/xcschemes EchoGuideApp/Resources EchoGuideApp/Resources/Models EchoGuideApp/Sources EchoGuideTests plugins proxy

cat > '.github/CODEOWNERS' <<'EOF_AVAE'
# Two owners. PRs touching a path need that owner's review.
# @bryan is a placeholder: replace it with Bryan's GitHub username.

# Maxwell: perception + infrastructure
/EchoGuide/Core/Camera/      @mkhavari-spec
/EchoGuide/Core/Vision/      @mkhavari-spec
/EchoGuide/Core/Depth/       @mkhavari-spec
/EchoGuide/Core/Plugins/     @mkhavari-spec
/EchoGuide/Core/Router/      @mkhavari-spec
/EchoGuideTests/             @mkhavari-spec
/.github/                    @mkhavari-spec
/Package.swift               @mkhavari-spec
/plugins/                    @mkhavari-spec
/proxy/                      @mkhavari-spec
/EchoGuideApp/               @mkhavari-spec

# Bryan: everything the user feels, hears and sees
/EchoGuide/Core/Fence/       @bryan
/EchoGuide/Core/Haptics/     @bryan
/EchoGuide/Core/Audio/       @bryan
/EchoGuide/Core/Automation/  @bryan
/EchoGuide/Core/Cognitive/   @bryan
/EchoGuide/UI/               @bryan

# Shared contracts: both sign off.
/EchoGuide/Core/Contracts/   @mkhavari-spec @bryan
EOF_AVAE

cat > '.github/workflows/export-model.yml' <<'EOF_AVAE'
# Owner: Maxwell. Manual: exports YOLO to Core ML INT8 with NMS and attaches it
# as a build artifact. Download it, put it in EchoGuideApp/Resources/Models/.
# Ultralytics YOLO is AGPL-3.0: a closed-source app needs an Ultralytics
# Enterprise license, or swap in a permissively licensed detector.

name: export-model

on:
  workflow_dispatch:
    inputs:
      model:
        description: "Ultralytics weights"
        default: "yolo11n.pt"
        required: true
      imgsz:
        description: "Input size"
        default: "640"
        required: true

jobs:
  export:
    runs-on: macos-15
    timeout-minutes: 30
    steps:
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - name: Export
        run: |
          python -m pip install --quiet "ultralytics>=8.3" "coremltools>=8"
          yolo export model="${{ inputs.model }}" format=coreml int8=True nms=True imgsz=${{ inputs.imgsz }}
          ls -la
      - uses: actions/upload-artifact@v4
        with:
          name: coreml-model
          path: "*.mlpackage"
EOF_AVAE

cat > '.github/workflows/ios-release.yml' <<'EOF_AVAE'
# Owner: Maxwell. Manual TestFlight upload. Uses Xcode cloud signing with an
# App Store Connect API key, so no certificates or profiles live in the repo.
#
# Repo secrets needed (Settings > Secrets and variables > Actions):
#   APPLE_TEAM_ID        10-character team id
#   ASC_KEY_ID           App Store Connect API key id (Admin or App Manager role)
#   ASC_ISSUER_ID        issuer id
#   ASC_KEY_P8_BASE64    base64 of the AuthKey_XXXX.p8 file
#   EG_PROXY_BASE_URL    deployed proxy URL baked into the build (optional)
# The bundle id app.echoguide.EchoGuide must exist in App Store Connect.

name: ios-release

on:
  workflow_dispatch:
    inputs:
      build_number:
        description: "Build number (must increase every upload)"
        required: true

jobs:
  testflight:
    runs-on: macos-15
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4

      - name: Check secrets
        env:
          TEAM: ${{ secrets.APPLE_TEAM_ID }}
          KEY: ${{ secrets.ASC_KEY_ID }}
          ISSUER: ${{ secrets.ASC_ISSUER_ID }}
          P8: ${{ secrets.ASC_KEY_P8_BASE64 }}
        run: |
          missing=""
          [ -z "$TEAM" ] && missing="$missing APPLE_TEAM_ID"
          [ -z "$KEY" ] && missing="$missing ASC_KEY_ID"
          [ -z "$ISSUER" ] && missing="$missing ASC_ISSUER_ID"
          [ -z "$P8" ] && missing="$missing ASC_KEY_P8_BASE64"
          if [ -n "$missing" ]; then echo "::error::Missing secrets:$missing"; exit 1; fi

      - name: Write API key
        env:
          P8: ${{ secrets.ASC_KEY_P8_BASE64 }}
        run: |
          mkdir -p "$RUNNER_TEMP/asc"
          echo "$P8" | base64 --decode > "$RUNNER_TEMP/asc/key.p8"

      - name: Archive
        run: |
          xcodebuild archive \
            -project EchoGuideApp/EchoGuideApp.xcodeproj \
            -scheme EchoGuideApp \
            -configuration Release \
            -destination 'generic/platform=iOS' \
            -archivePath "$RUNNER_TEMP/EchoGuide.xcarchive" \
            -allowProvisioningUpdates \
            -authenticationKeyPath "$RUNNER_TEMP/asc/key.p8" \
            -authenticationKeyID "${{ secrets.ASC_KEY_ID }}" \
            -authenticationKeyIssuerID "${{ secrets.ASC_ISSUER_ID }}" \
            DEVELOPMENT_TEAM="${{ secrets.APPLE_TEAM_ID }}" \
            CURRENT_PROJECT_VERSION="${{ inputs.build_number }}" \
            EG_PROXY_BASE_URL="${{ secrets.EG_PROXY_BASE_URL }}" | tail -n 60
          exit ${PIPESTATUS[0]}

      - name: Upload to TestFlight
        run: |
          cat > "$RUNNER_TEMP/ExportOptions.plist" <<PLIST
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0"><dict>
            <key>method</key><string>app-store-connect</string>
            <key>destination</key><string>upload</string>
            <key>teamID</key><string>${{ secrets.APPLE_TEAM_ID }}</string>
            <key>signingStyle</key><string>automatic</string>
          </dict></plist>
          PLIST
          xcodebuild -exportArchive \
            -archivePath "$RUNNER_TEMP/EchoGuide.xcarchive" \
            -exportOptionsPlist "$RUNNER_TEMP/ExportOptions.plist" \
            -exportPath "$RUNNER_TEMP/export" \
            -allowProvisioningUpdates \
            -authenticationKeyPath "$RUNNER_TEMP/asc/key.p8" \
            -authenticationKeyID "${{ secrets.ASC_KEY_ID }}" \
            -authenticationKeyIssuerID "${{ secrets.ASC_ISSUER_ID }}" | tail -n 40
          exit ${PIPESTATUS[0]}

      - name: Remove key
        if: always()
        run: rm -rf "$RUNNER_TEMP/asc"
EOF_AVAE

cat > '.github/workflows/swift-ci.yml' <<'EOF_AVAE'
name: swift-ci

on:
  push:
    branches: [main, "feature/**"]
  pull_request:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  macos-test:
    name: Build + unit tests (macOS host)
    runs-on: macos-15
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
      - name: Toolchain
        run: swift --version
      - name: Build
        run: swift build -c debug
      - name: Test (includes frame-delta benchmark)
        run: swift test --parallel
      - name: Release build (optimizer catches different issues)
        run: swift build -c release

  ios-build:
    name: Compile iOS paths (ARKit, CoreHaptics, camera)
    runs-on: macos-15
    timeout-minutes: 25
    steps:
      - uses: actions/checkout@v4
      - name: Build for iOS Simulator
        run: |
          # SwiftPM schemes are named after the checkout folder; pick the package scheme.
          SCHEME=$(xcodebuild -list -json | python3 -c 'import json,sys; s=json.load(sys.stdin)["workspace"]["schemes"]; print(next((x for x in s if x.endswith("-Package")), s[0]))')
          echo "Using scheme: $SCHEME"
          xcodebuild build \
            -scheme "$SCHEME" \
            -destination 'generic/platform=iOS Simulator' \
            -skipPackagePluginValidation \
            CODE_SIGNING_ALLOWED=NO | tail -n 40
          exit ${PIPESTATUS[0]}

  app-build:
    name: Build the iOS app (EchoGuideApp)
    runs-on: macos-15
    timeout-minutes: 25
    steps:
      - uses: actions/checkout@v4
      - name: Build app for iOS Simulator
        run: |
          xcodebuild build \
            -project EchoGuideApp/EchoGuideApp.xcodeproj \
            -scheme EchoGuideApp \
            -destination 'generic/platform=iOS Simulator' \
            -skipPackagePluginValidation \
            CODE_SIGNING_ALLOWED=NO | tail -n 40
          exit ${PIPESTATUS[0]}

  proxy-test:
    name: Proxy tests (Node)
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - name: Test
        working-directory: proxy
        run: node --test
EOF_AVAE

cat > '.gitignore' <<'EOF_AVAE'
.DS_Store
.build/
.swiftpm/
*.xcodeproj/xcuserdata/
DerivedData/
*.mlmodelc/
*.mlpackage/
__pycache__/
.venv/
EOF_AVAE

cat > 'EchoGuide/Core/Audio/SpatialAudioEngine.swift' <<'EOF_AVAE'
// Owner: Bryan. Directional earcons through AVAudioEngine's environment node
// (HRTF on headphones, equal-power pan on the speaker) plus on-device speech.
// Everything here works in Airplane Mode; cloud TTS is an optional upgrade
// layered on top, never a dependency.

import Foundation
import EchoGuideContracts

public enum SpatialAudioMath {
    /// Azimuth in radians (-π/2 hard left ... +π/2 hard right) from a
    /// horizontal image offset in -1...1.
    public static func azimuth(forOffsetX dx: Float) -> Float {
        max(-1, min(1, dx * 2)) * .pi / 2
    }

    /// Listener-relative position 1 m away for the environment node
    /// (x right, y up, z forward is negative).
    public static func position(azimuth: Float, elevation: Float) -> (x: Float, y: Float, z: Float) {
        (sin(azimuth) * cos(elevation), sin(elevation), -cos(azimuth) * cos(elevation))
    }
}

#if canImport(AVFoundation)
import AVFoundation

public actor SpatialAudioEngine: SpatialAudioCueing {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private let synth = AVSpeechSynthesizer()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var pingBuffer: AVAudioPCMBuffer?
    private var wired = false
    private var started = false
    private var observers: [NSObjectProtocol] = []

    public init() {}

    /// Builds the graph once; (re)starts the engine whenever it is down.
    /// A phone call, a route change (headphones out) or backgrounding stops
    /// AVAudioEngine; the next cue brings it back instead of going silent.
    private func startIfNeeded() {
        if !wired {
            engine.attach(environment)
            engine.attach(player)
            // Mono source into the environment node is what makes it positional.
            engine.connect(player, to: environment, format: format)
            engine.connect(environment, to: engine.mainMixerNode, format: nil)
            player.renderingAlgorithm = .auto
            environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
            pingBuffer = Self.makePing(format: format)
            observeInterruptions()
            wired = true
        }
        guard !started || !engine.isRunning else { return }
        do {
            #if os(iOS)
            let s = AVAudioSession.sharedInstance()
            // Mix with other audio and duck it, so navigation never silences a call app.
            try s.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
            try s.setActive(true)
            #endif
            try engine.start()
            player.play()
            started = true
        } catch {
            started = false
        }
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        var names: [Notification.Name] = [.AVAudioEngineConfigurationChange]
        #if os(iOS)
        names += [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification]
        #endif
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { await self?.markStopped() }
            })
        }
    }

    private func markStopped() { started = false }

    public func ping(azimuth: Float, elevation: Float) async {
        startIfNeeded()
        guard started, let pingBuffer else { return }
        let p = SpatialAudioMath.position(azimuth: azimuth, elevation: elevation)
        player.position = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
        schedule(pingBuffer)
    }

    /// Synchronous on purpose: the async `scheduleBuffer` variant would hold
    /// the actor until the buffer has played.
    private func schedule(_ buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    public func speak(_ text: String, azimuth: Float) async {
        // Spoken words carry the instruction; a ping first gives the direction.
        await ping(azimuth: azimuth, elevation: 0)
        if synth.isSpeaking { synth.stopSpeaking(at: .word) }
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        u.prefersAssistiveTechnologySettings = true
        synth.speak(u)
    }

    /// 60 ms 1.2 kHz sine with a short fade, cheap to schedule repeatedly.
    private static func makePing(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * 0.06)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let ch = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = frames
        let n = Int(frames)
        for i in 0..<n {
            let t = Float(i) / Float(format.sampleRate)
            let env = min(1, Float(i) / 200) * min(1, Float(n - i) / 400)
            ch[i] = sin(2 * .pi * 1200 * t) * 0.5 * env
        }
        return buf
    }
}
#endif
EOF_AVAE

cat > 'EchoGuide/Core/Automation/AutomationEngine.swift' <<'EOF_AVAE'
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
    /// User has walked out of a safe location region (dementia wandering).
    case outsideSafeArea(String)
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
        // Wandering outside the safe area is cleared only by coming back.
        if case .outsideSafeArea = state { return }

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
        case .leftSafeArea(let region):
            var told = false
            if let tools {
                let alert = ToolMatch(toolName: "notify_caregiver", sideEffect: .none, arguments: ["region": region])
                told = (try? await tools.invoke(alert)) != nil
            }
            await audio.speak(told ? "You have left \(region). Your carer has been told." : "You have left \(region).", azimuth: 0)
            transition(.outsideSafeArea(region))
            return true
        case .returnedToSafeArea(let region):
            await audio.speak("You are back at \(region).", azimuth: 0)
            // Only the wandering alert is cleared; a paused engine stays paused.
            if case .outsideSafeArea = state { transition(.scanning) }
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
EOF_AVAE

cat > 'EchoGuide/Core/Camera/CameraFeed.swift' <<'EOF_AVAE'
// Owner: Maxwell. Continuous back-camera feed for devices or modes without
// LiDAR. When LiDARDepthEngine is running, ARKit owns the camera and its
// ARFrame.capturedImage is fed into the same handler instead; iOS will not
// run AVCaptureSession and ARSession on the back camera at the same time.


#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import EchoGuideContracts

public final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "echoguide.camera", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var index: UInt64 = 0
    private var handler: ((CameraFrame) -> Void)?

    public override init() { super.init() }

    /// `handler` runs on the camera queue for every frame. Keep it cheap:
    /// run FrameDeltaEngine there and hand only triggered frames onward.
    public func start(fps: Int32 = 30, handler: @escaping (CameraFrame) -> Void) throws {
        self.handler = handler
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            session.commitConfiguration()
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }

        try device.lockForConfiguration()
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
        device.unlockForConfiguration()

        session.commitConfiguration()
        queue.async { [session] in session.startRunning() }
    }

    public func stop() {
        queue.async { [session] in session.stopRunning() }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        index += 1
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        handler?(CameraFrame(pixelBuffer: pb, timestamp: t, index: index))
    }

    public enum CameraError: Error { case noCamera }
}
#endif
EOF_AVAE

cat > 'EchoGuide/Core/Camera/FrameDeltaEngine.swift' <<'EOF_AVAE'
// Owner: Maxwell. Decides, per camera frame, whether full inference is worth
// running. Samples the luma plane on a coarse grid (768 points by default),
// compares to the previous grid and only fires on real change. Sub-millisecond
// per frame; that is what lets the expensive models sleep most of the time.

import Foundation
import EchoGuideContracts
#if canImport(CoreVideo)
import CoreVideo
#endif

public struct FrameDeltaConfig: Sendable {
    /// Sampling grid. 32x24 keeps the cost flat regardless of camera resolution.
    public var gridWidth = 32
    public var gridHeight = 24
    /// A cell counts as changed when its luma moves by more than this (0...255).
    public var cellThreshold: UInt8 = 18
    /// Fire when this fraction of cells changed (object entry, hand movement).
    public var changedFractionTrigger: Float = 0.04
    /// Ignore global brightness shifts (auto-exposure) below this mean delta.
    public var exposureCompensation = true
    /// Minimum seconds between two triggers, so a waving hand does not run
    /// inference on every frame.
    public var cooldown: TimeInterval = 0.10
    /// Re-check a static scene at most this often, so something that entered
    /// slowly is still seen eventually. nil disables.
    public var idleRefresh: TimeInterval? = 3.0

    public init() {}
}

public enum FrameDeltaDecision: Sendable, Equatable {
    case skip
    case infer(Reason)

    public enum Reason: Sendable, Equatable {
        case firstFrame
        case motion(changedFraction: Float)
        case idleRefresh
        case forced
    }

    public var shouldInfer: Bool {
        if case .infer = self { return true }
        return false
    }
}

public struct FrameDeltaStats: Sendable, Equatable {
    public var framesSeen: UInt64 = 0
    public var framesInferred: UInt64 = 0
    public var skipRatio: Double { framesSeen == 0 ? 0 : 1 - Double(framesInferred) / Double(framesSeen) }
}

/// Not thread-safe by design: call it from the single camera queue.
public final class FrameDeltaEngine {
    public private(set) var config: FrameDeltaConfig
    public private(set) var stats = FrameDeltaStats()
    public private(set) var lastAnalysisMs: Double = 0

    private var previous: [UInt8]
    private var current: [UInt8]
    private var hasPrevious = false
    private var lastTrigger: TimeInterval = -.infinity
    private var forceNext = false

    public init(config: FrameDeltaConfig = FrameDeltaConfig()) {
        self.config = config
        let n = config.gridWidth * config.gridHeight
        previous = Array(repeating: 0, count: n)
        current = Array(repeating: 0, count: n)
    }

    /// Next frame runs inference no matter what (e.g. the user tapped, or the
    /// automation engine needs a fresh look after a step completes).
    public func forceNextFrame() { forceNext = true }

    public func reset() {
        hasPrevious = false
        lastTrigger = -.infinity
        stats = FrameDeltaStats()
    }

    /// Core analysis on a raw 8-bit luma plane. `bytesPerRow` may exceed width.
    public func analyze(luma: UnsafeBufferPointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, timestamp: TimeInterval) -> FrameDeltaDecision {
        let timer = FrameTimer()
        defer { lastAnalysisMs = timer.elapsedMs }
        stats.framesSeen += 1

        let gw = config.gridWidth, gh = config.gridHeight
        guard width >= gw, height >= gh, luma.count >= (height - 1) * bytesPerRow + width else { return .skip }

        // Sample the centre of each grid cell.
        let stepX = width / gw, stepY = height / gh
        var sum = 0
        for gy in 0..<gh {
            let row = (gy * stepY + stepY / 2) * bytesPerRow
            for gx in 0..<gw {
                let v = luma[row + gx * stepX + stepX / 2]
                current[gy * gw + gx] = v
                sum += Int(v)
            }
        }

        defer {
            swap(&previous, &current)
            hasPrevious = true
        }

        if forceNext {
            forceNext = false
            return fire(.forced, at: timestamp)
        }
        guard hasPrevious else { return fire(.firstFrame, at: timestamp) }

        // Remove a uniform brightness shift so auto-exposure is not "motion".
        var bias = 0
        if config.exposureCompensation {
            let prevSum = previous.reduce(0) { $0 + Int($1) }
            bias = (sum - prevSum) / current.count
        }

        var changed = 0
        let threshold = Int(config.cellThreshold)
        for i in 0..<current.count where abs(Int(current[i]) - Int(previous[i]) - bias) > threshold {
            changed += 1
        }
        let fraction = Float(changed) / Float(current.count)

        if timestamp - lastTrigger < config.cooldown { return .skip }
        if fraction >= config.changedFractionTrigger {
            return fire(.motion(changedFraction: fraction), at: timestamp)
        }
        if let refresh = config.idleRefresh, timestamp - lastTrigger >= refresh {
            return fire(.idleRefresh, at: timestamp)
        }
        return .skip
    }

    private func fire(_ reason: FrameDeltaDecision.Reason, at t: TimeInterval) -> FrameDeltaDecision {
        lastTrigger = t
        stats.framesInferred += 1
        return .infer(reason)
    }

    #if canImport(CoreVideo)
    /// Convenience for camera buffers. Expects bi-planar 420v/420f (what both
    /// CameraFeed and ARFrame.capturedImage deliver); plane 0 is luma.
    public func analyze(_ buffer: CVPixelBuffer, timestamp: TimeInterval) -> FrameDeltaDecision {
        guard CVPixelBufferIsPlanar(buffer) else { return .skip }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return .skip }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let ptr = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: bpr * height)
        return analyze(luma: ptr, width: width, height: height, bytesPerRow: bpr, timestamp: timestamp)
    }
    #endif
}
EOF_AVAE

cat > 'EchoGuide/Core/Camera/PerceptionPipeline.swift' <<'EOF_AVAE'
// Owner: Maxwell. The one path from camera to detections:
//
//   frame (camera queue) -> FrameDeltaEngine -> [skip]
//                                     \-> LocalVisionEngine -> onResult
//
// Back-pressure: at most one inference in flight. A frame that arrives while
// the model is busy is dropped, never queued, so latency cannot pile up
// behind a slow frame. Every stage is timed; `stats` is what the benchmark
// HUD and the "< 15 ms local" claim are measured against.

#if canImport(CoreVideo)
import CoreVideo
import Foundation
import EchoGuideContracts

public struct PipelineTiming: Sendable, Equatable {
    /// FrameDeltaEngine analysis of this frame.
    public var deltaMs: Double
    /// Submit to the start of inference (task hop).
    public var queueMs: Double
    public var inferenceMs: Double
    /// Submit to detections ready, handed to `onResult`. `stats` additionally
    /// includes the time `onResult` took (the cue the consumer fired).
    public var totalMs: Double
}

public struct PipelineStats: Sendable, Equatable {
    public var framesSeen: UInt64 = 0
    public var framesSkipped: UInt64 = 0
    public var framesDroppedBusy: UInt64 = 0
    public var framesInferred: UInt64 = 0
    public var totalP50Ms: Double = 0
    public var totalP95Ms: Double = 0

    /// Share of frames that never reached the model.
    public var computeSaved: Double {
        framesSeen == 0 ? 0 : Double(framesSkipped + framesDroppedBusy) / Double(framesSeen)
    }
}

/// `submit` is called from the camera / ARKit delegate queue only.
public final class PerceptionPipeline: @unchecked Sendable {
    public typealias ResultHandler = @Sendable (VisionFrameResult, PipelineTiming) async -> Void

    private let delta: FrameDeltaEngine
    private let vision: FrameInferring
    private let onResult: ResultHandler
    private let lock = NSLock()
    private var busy = false
    private var counters = PipelineStats()
    private var totals = LatencyWindow()

    public init(vision: FrameInferring, delta: FrameDeltaEngine = FrameDeltaEngine(), onResult: @escaping ResultHandler) {
        self.vision = vision
        self.delta = delta
        self.onResult = onResult
    }

    public var stats: PipelineStats {
        lock.withLock {
            var s = counters
            s.totalP50Ms = totals.percentile(0.5)
            s.totalP95Ms = totals.percentile(0.95)
            return s
        }
    }

    /// Ask for a fresh look on the next frame (step completed, user tapped).
    public func forceNextFrame() {
        lock.withLock { delta.forceNextFrame() }
    }

    /// Returns the decision so callers (and tests) can see what happened.
    @discardableResult
    public func submit(_ frame: CameraFrame) -> FrameDeltaDecision {
        let submitted = FrameTimer()
        let (decision, deltaMs, accepted): (FrameDeltaDecision, Double, Bool) = lock.withLock {
            counters.framesSeen += 1
            let d = delta.analyze(frame.pixelBuffer, timestamp: frame.timestamp)
            guard d.shouldInfer else {
                counters.framesSkipped += 1
                return (d, delta.lastAnalysisMs, false)
            }
            guard !busy else {
                counters.framesDroppedBusy += 1
                // The motion is still there next frame; make sure it is not lost.
                delta.forceNextFrame()
                return (d, delta.lastAnalysisMs, false)
            }
            busy = true
            counters.framesInferred += 1
            return (d, delta.lastAnalysisMs, true)
        }
        guard accepted else { return decision }

        Task(priority: .userInitiated) { [vision, onResult] in
            let queueMs = submitted.elapsedMs
            let result = await vision.infer(frame)
            let timing = PipelineTiming(deltaMs: deltaMs, queueMs: queueMs, inferenceMs: result.inferenceMs, totalMs: submitted.elapsedMs)
            await onResult(result, timing)
            self.finish(endToEndMs: submitted.elapsedMs)
        }
        return decision
    }

    private func finish(endToEndMs: Double) {
        lock.withLock {
            totals.record(endToEndMs)
            busy = false
        }
    }
}
#endif
EOF_AVAE

cat > 'EchoGuide/Core/Cognitive/CognitiveTaskIsolation.swift' <<'EOF_AVAE'
// Owner: Bryan. Step-anchoring for dementia and cognitive accessibility.
// A frame can hold a dozen detections; the user gets exactly one. Rules:
//   1. One target at a time, chosen by goal, closeness to the finger, size
//      and confidence.
//   2. Sticky: the current target holds until a rival is clearly better, so
//      the instruction does not flicker between two buttons.
//   3. Settled: a new target must be seen for several frames in a row before
//      it is announced at all.
//   4. Short: instructions are capped at a few plain words.

import Foundation
import EchoGuideContracts

public struct CognitiveConfig: Sendable {
    /// Consecutive frames a new target must persist before it becomes the step.
    public var settleFrames = 3
    /// A rival must outscore the current target by this factor to replace it.
    public var switchMargin: Float = 1.35
    public var sameTargetIoU: Float = 0.3
    public var maxInstructionWords = 8
    /// Labels never offered as a step on their own (background clutter).
    public var ignoredLabels: Set<String> = ["person", "dining table", "chair"]

    public init() {}
}

public struct CognitiveTaskIsolation: Sendable {
    public var config: CognitiveConfig
    /// When set, only matching labels or text are eligible ("start", "microwave").
    public var goal: String?
    /// Labels temporarily off the menu, e.g. a target the user just finished.
    /// AutomationEngine sets this so "done" moves on to the next step instead
    /// of guiding the finger straight back to the same button.
    public var excludedLabels: Set<String> = [] {
        didSet {
            if let cur = current, excludedLabels.contains(cur.label) { current = nil }
            if let c = candidate, excludedLabels.contains(c.label) { candidate = nil; candidateFrames = 0 }
        }
    }

    private var current: Detection?
    private var candidate: Detection?
    private var candidateFrames = 0
    /// True when the step returned by the last `isolate` came from a detection
    /// in that frame; false when it is the remembered target of an earlier
    /// frame. The caller uses this to time out a target that has gone away.
    public private(set) var isCurrentVisible = false

    public init(config: CognitiveConfig = CognitiveConfig(), goal: String? = nil) {
        self.config = config
        self.goal = goal
    }

    public mutating func reset() {
        current = nil
        candidate = nil
        candidateFrames = 0
        isCurrentVisible = false
    }

    /// The one step for this frame, or nil when nothing is settled yet.
    public mutating func isolate(_ frame: VisionFrameResult) -> ActionStep? {
        let anchor = frame.fingertip?.box.mid ?? .center
        let eligible = frame.targets.filter(isEligible)
        isCurrentVisible = false
        guard let best = eligible.max(by: { score($0, anchor: anchor) < score($1, anchor: anchor) }) else {
            candidate = nil
            candidateFrames = 0
            // Keep the current target through a single dropped frame; the
            // caller decides when "nothing seen" has lasted long enough.
            return current.map { step(for: $0, anchor: anchor) }
        }

        // Current target still visible: refresh its box, and keep it unless the
        // best rival is clearly better.
        if let cur = current, let refreshed = eligible.first(where: { isSame($0, cur) }) {
            current = refreshed
            isCurrentVisible = true
            let rivalWins = !isSame(best, refreshed)
                && score(best, anchor: anchor) > score(refreshed, anchor: anchor) * config.switchMargin
            if !rivalWins {
                candidate = nil
                candidateFrames = 0
                return step(for: refreshed, anchor: anchor)
            }
        }

        // Settle the challenger.
        if let c = candidate, isSame(c, best) {
            candidateFrames += 1
        } else {
            candidateFrames = 1
        }
        candidate = best

        if candidateFrames >= config.settleFrames {
            current = best
            isCurrentVisible = true
            candidate = nil
            candidateFrames = 0
        }
        return current.map { step(for: $0, anchor: anchor) }
    }

    // MARK: - Scoring

    func score(_ d: Detection, anchor: ImagePoint) -> Float {
        let proximity = 1 - min(1, d.box.mid.distance(to: anchor) / 0.75)
        let size = min(1, d.box.area * 8)
        var s = 0.45 * proximity + 0.35 * d.confidence + 0.20 * size
        if let goal, matches(d, goal) { s += 1 }
        return s
    }

    private func isEligible(_ d: Detection) -> Bool {
        if config.ignoredLabels.contains(d.label) || excludedLabels.contains(d.label) { return false }
        if let goal { return matches(d, goal) }
        return true
    }

    private func matches(_ d: Detection, _ goal: String) -> Bool {
        let g = goal.lowercased()
        return d.label.lowercased().contains(g) || (d.text?.lowercased().contains(g) ?? false)
    }

    private func isSame(_ a: Detection, _ b: Detection) -> Bool {
        a.label == b.label && a.kind == b.kind && a.box.iou(b.box) >= config.sameTargetIoU
    }

    // MARK: - Wording

    private func step(for d: Detection, anchor: ImagePoint) -> ActionStep {
        let dx = d.box.midX - anchor.x
        let dy = d.box.midY - anchor.y
        let name = Self.spokenName(d)
        let instruction: String
        if (dx * dx + dy * dy).squareRoot() <= Alignment.tolerance {
            instruction = "\(name). You are on it."
        } else {
            instruction = "\(name). \(Self.direction(dx: dx, dy: dy))."
        }
        return ActionStep(
            targetLabel: d.label,
            instruction: Self.clip(instruction, words: config.maxInstructionWords),
            guidance: .align(dx: dx, dy: dy),
            target: d
        )
    }

    static func spokenName(_ d: Detection) -> String {
        switch d.kind {
        case .text: return (d.text ?? "Text").capitalizedFirst
        case .barcode: return "Barcode"
        case .object, .fingertip: return d.label.capitalizedFirst
        }
    }

    /// One direction at a time: the larger axis first. Two-axis directions
    /// ("left and up") are harder to follow for many users.
    static func direction(dx: Float, dy: Float) -> String {
        let far = max(abs(dx), abs(dy)) > 0.2
        let amount = far ? "" : " a little"
        if abs(dx) >= abs(dy) {
            return (dx > 0 ? "Move right" : "Move left") + amount
        }
        return (dy > 0 ? "Move down" : "Move up") + amount
    }

    static func clip(_ s: String, words: Int) -> String {
        let parts = s.split(separator: " ")
        guard parts.count > words else { return s }
        return parts.prefix(words).joined(separator: " ")
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
EOF_AVAE

cat > 'EchoGuide/Core/Contracts/Contracts.swift' <<'EOF_AVAE'
// Shared vocabulary for every engine. Owned jointly: a change here needs a
// review from both owners (see .github/CODEOWNERS).
//
// Coordinate convention, used everywhere in the pipeline: normalized space of
// the *upright portrait* image the user is holding up, origin top-left, x to
// the user's right, y down, both in 0...1. The camera sensor is landscape, so
// LocalVisionEngine runs Vision with orientation .right and converts Vision's
// bottom-left boxes once; LiDARDepthEngine maps back to sensor space itself.

import Foundation

// MARK: - Geometry

public struct ImagePoint: Sendable, Equatable, Hashable, Codable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public static let center = ImagePoint(x: 0.5, y: 0.5)

    public func distance(to other: ImagePoint) -> Float {
        let dx = other.x - x, dy = other.y - y
        return (dx * dx + dy * dy).squareRoot()
    }
}

public struct ImageRect: Sendable, Equatable, Hashable, Codable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Float { x + width / 2 }
    public var midY: Float { y + height / 2 }
    public var mid: ImagePoint { ImagePoint(x: midX, y: midY) }
    public var area: Float { max(0, width) * max(0, height) }

    public func contains(_ p: ImagePoint) -> Bool {
        p.x >= x && p.x <= x + width && p.y >= y && p.y <= y + height
    }

    /// Intersection over union, used for frame-to-frame identity.
    public func iou(_ other: ImageRect) -> Float {
        let ix = max(0, min(x + width, other.x + other.width) - max(x, other.x))
        let iy = max(0, min(y + height, other.y + other.height) - max(y, other.y))
        let inter = ix * iy
        let union = area + other.area - inter
        return union > 0 ? inter / union : 0
    }
}

/// Shared by haptics (when to stop pulsing) and automation (when the finger is
/// on target), so the two can never disagree.
public enum Alignment {
    public static let tolerance: Float = 0.03
}

// MARK: - Vision output

public enum DetectionKind: String, Sendable, Codable {
    case object
    case text
    case barcode
    case fingertip
}

public struct Detection: Sendable, Equatable, Codable {
    public var label: String
    public var confidence: Float
    public var box: ImageRect
    public var kind: DetectionKind
    /// Recognised string for `.text`, payload for `.barcode`.
    public var text: String?

    public init(label: String, confidence: Float, box: ImageRect, kind: DetectionKind = .object, text: String? = nil) {
        self.label = label
        self.confidence = confidence
        self.box = box
        self.kind = kind
        self.text = text
    }
}

public struct VisionFrameResult: Sendable, Equatable {
    public var frameIndex: UInt64
    public var timestamp: TimeInterval
    public var detections: [Detection]
    /// Wall time spent inside LocalVisionEngine for this frame.
    public var inferenceMs: Double

    public init(frameIndex: UInt64, timestamp: TimeInterval, detections: [Detection], inferenceMs: Double) {
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.detections = detections
        self.inferenceMs = inferenceMs
    }

    public var fingertip: Detection? { detections.first { $0.kind == .fingertip } }
    public var targets: [Detection] { detections.filter { $0.kind != .fingertip } }
}

// MARK: - Steps

/// The one thing the user should do right now. Cognitive isolation produces at
/// most one of these per moment; nothing else is spoken or felt.
public struct ActionStep: Sendable, Equatable {
    public enum Guidance: Sendable, Equatable {
        /// Move the fingertip (or the camera aim) by this offset to reach the target.
        case align(dx: Float, dy: Float)
        /// Nothing to move; just say it.
        case announce
    }

    public var targetLabel: String
    public var instruction: String
    public var guidance: Guidance
    public var target: Detection?

    public init(targetLabel: String, instruction: String, guidance: Guidance, target: Detection?) {
        self.targetLabel = targetLabel
        self.instruction = instruction
        self.guidance = guidance
        self.target = target
    }
}

// MARK: - Engine seams
// Each engine is built against these, never against another owner's types.
// The app target composes concrete engines into AutomationEngine.

public protocol HapticCueing: Sendable {
    /// Continuous guidance toward a target. `offset` is target minus fingertip.
    func guide(offset dx: Float, _ dy: Float, distanceMetres: Float?) async
    /// Distinct "you are on it" pattern.
    func confirm() async
    /// Strong, unmistakable warning (digital fence breach).
    func warn() async
    func stop() async
}

public protocol SpatialAudioCueing: Sendable {
    /// Speak a short phrase, panned to `azimuth` radians (-π/2 left ... +π/2 right).
    func speak(_ text: String, azimuth: Float) async
    /// Short directional earcon.
    func ping(azimuth: Float, elevation: Float) async
}

public protocol DepthProviding: Sendable {
    /// Metres to the surface at a normalized image point, nil if unknown.
    func depth(at point: ImagePoint) async -> Float?
}

public struct ReasoningQuery: Sendable {
    public var question: String
    public var detections: [Detection]
    public var localConfidence: Float
    /// JPEG of the triggering frame. Only sent to the cloud with consent.
    public var jpeg: Data?

    public init(question: String, detections: [Detection], localConfidence: Float, jpeg: Data? = nil) {
        self.question = question
        self.detections = detections
        self.localConfidence = localConfidence
        self.jpeg = jpeg
    }
}

public enum ReasoningSource: String, Sendable, Codable {
    case local
    case cloud
    /// Cloud was wanted but unavailable (offline, no consent, budget, breaker open).
    case localFallback
}

public struct ReasoningOutcome: Sendable, Equatable {
    public var answer: String
    public var source: ReasoningSource
    public var latencyMs: Double

    public init(answer: String, source: ReasoningSource, latencyMs: Double) {
        self.answer = answer
        self.source = source
        self.latencyMs = latencyMs
    }
}

public protocol ReasoningRouting: Sendable {
    func resolve(_ query: ReasoningQuery) async -> ReasoningOutcome
}

public enum ToolSideEffect: String, Sendable, Codable {
    /// Read-only lookups (barcode product info).
    case none
    /// Undoable state changes (lights).
    case reversible
    /// Changes the physical world (start a microwave, unlock a door). Requires a
    /// deliberate dwell confirmation before AutomationEngine will call it.
    case physical
}

public struct ToolMatch: Sendable, Equatable {
    public var toolName: String
    public var sideEffect: ToolSideEffect
    public var arguments: [String: String]

    public init(toolName: String, sideEffect: ToolSideEffect, arguments: [String: String]) {
        self.toolName = toolName
        self.sideEffect = sideEffect
        self.arguments = arguments
    }
}

public protocol ToolInvoking: Sendable {
    func match(_ detection: Detection) async -> ToolMatch?
    /// Returns a short sentence suitable to speak.
    func invoke(_ match: ToolMatch) async throws -> String
}

// MARK: - Digital fence

public enum FenceEvent: Sendable, Equatable {
    /// Hand or camera is approaching a spatial hazard zone.
    case approaching(zone: String, metres: Float?)
    /// Hand is inside a spatial hazard zone.
    case breached(zone: String)
    /// User walked out of a safe location region.
    case leftSafeArea(region: String)
    case returnedToSafeArea(region: String)
}

// MARK: - Timing

/// Monotonic millisecond timer. CFAbsoluteTimeGetCurrent() is wall-clock and
/// jumps when the system clock is corrected, so per-frame budgets use the
/// monotonic uptime clock instead.
public struct FrameTimer: Sendable {
    private let start: UInt64

    public init() { start = DispatchTime.now().uptimeNanoseconds }

    public var elapsedMs: Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
    }
}

/// Fixed-size rolling latency window, reports p50/p95 for on-device telemetry.
public struct LatencyWindow: Sendable {
    private var samples: [Double]
    private var next = 0
    private var filled = false

    public init(capacity: Int = 240) {
        samples = Array(repeating: 0, count: max(1, capacity))
    }

    public mutating func record(_ ms: Double) {
        samples[next] = ms
        next = (next + 1) % samples.count
        if next == 0 { filled = true }
    }

    public var count: Int { filled ? samples.count : next }

    public func percentile(_ p: Double) -> Double {
        let n = count
        guard n > 0 else { return 0 }
        let sorted = samples.prefix(n).sorted()
        let idx = min(n - 1, max(0, Int((p * Double(n - 1)).rounded())))
        return sorted[idx]
    }
}

// MARK: - Frames

#if canImport(CoreVideo)
import CoreVideo

/// Pixel buffers are not Sendable; this wrapper is the one sanctioned hop
/// from the capture queue into the vision actor.
public struct CameraFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let timestamp: TimeInterval
    public let index: UInt64

    public init(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, index: UInt64) {
        self.pixelBuffer = pixelBuffer
        self.timestamp = timestamp
        self.index = index
    }
}
#endif
EOF_AVAE

cat > 'EchoGuide/Core/Depth/LiDARDepthEngine.swift' <<'EOF_AVAE'
// Owner: Maxwell. 60 FPS ARKit smoothedSceneDepth. Keeps only the latest depth
// map (256x192 Float32 metres + confidence) and answers point queries with a
// confidence-filtered 3x3 median, so one noisy pixel never moves a cue.
// While running, ARKit owns the back camera: the captured image of every
// ARFrame is forwarded to `onFrame` so the frame-delta path still runs.

import Foundation
import EchoGuideContracts

/// Pure sampling over a row-major Float32 depth map. Testable without ARKit.
public enum DepthSampler {
    /// Upright portrait point -> landscape-right sensor point (the depth map's
    /// native layout). Inverse of Vision's `.right` orientation.
    public static func sensorPoint(fromUpright p: ImagePoint) -> ImagePoint {
        ImagePoint(x: p.y, y: 1 - p.x)
    }

    /// `confidence` uses ARConfidenceLevel raw values (0 low, 1 medium, 2 high).
    public static func sample(
        depth: UnsafeBufferPointer<Float32>, confidence: UnsafeBufferPointer<UInt8>?,
        width: Int, height: Int, rowStride: Int, confidenceRowStride: Int,
        at p: ImagePoint, minimumConfidence: UInt8 = 1, radius: Int = 1
    ) -> Float? {
        guard width > 0, height > 0 else { return nil }
        let cx = min(width - 1, max(0, Int(p.x * Float(width))))
        let cy = min(height - 1, max(0, Int(p.y * Float(height))))

        var values: [Float] = []
        values.reserveCapacity((2 * radius + 1) * (2 * radius + 1))
        for y in max(0, cy - radius)...min(height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(width - 1, cx + radius) {
                if let confidence, confidence[y * confidenceRowStride + x] < minimumConfidence { continue }
                let v = depth[y * rowStride + x]
                if v.isFinite, v > 0 { values.append(v) }
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }
}

#if canImport(ARKit) && os(iOS)
import ARKit

public final class LiDARDepthEngine: NSObject, ARSessionDelegate, DepthProviding, @unchecked Sendable {
    public let session = ARSession()
    private let lock = NSLock()
    private var latestDepth: CVPixelBuffer?
    private var latestConfidence: CVPixelBuffer?
    private var frameIndex: UInt64 = 0

    /// Called on ARKit's delegate queue with every captured frame (420f).
    public var onFrame: ((CameraFrame) -> Void)?

    public static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    public override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = DispatchQueue(label: "echoguide.depth", qos: .userInteractive)
    }

    public func start() {
        let config = ARWorldTrackingConfiguration()
        if Self.isSupported { config.frameSemantics.insert(.smoothedSceneDepth) }
        // 60 FPS format where the device offers one.
        if let fmt = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: { $0.framesPerSecond == 60 }) {
            config.videoFormat = fmt
        }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    public func stop() { session.pause() }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if let d = frame.smoothedSceneDepth {
            lock.withLock {
                latestDepth = d.depthMap
                latestConfidence = d.confidenceMap
            }
        }
        frameIndex += 1
        onFrame?(CameraFrame(pixelBuffer: frame.capturedImage, timestamp: frame.timestamp, index: frameIndex))
    }

    public func depth(at point: ImagePoint) async -> Float? {
        let (depth, conf) = lock.withLock { (latestDepth, latestConfidence) }
        guard let depth else { return nil }

        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        if let conf { CVPixelBufferLockBaseAddress(conf, .readOnly) }
        defer { if let conf { CVPixelBufferUnlockBaseAddress(conf, .readOnly) } }

        let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
        let stride = CVPixelBufferGetBytesPerRow(depth) / MemoryLayout<Float32>.size
        guard let dBase = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let dPtr = UnsafeBufferPointer(start: dBase.assumingMemoryBound(to: Float32.self), count: stride * h)

        var cPtr: UnsafeBufferPointer<UInt8>?
        var cStride = 0
        if let conf, let cBase = CVPixelBufferGetBaseAddress(conf) {
            cStride = CVPixelBufferGetBytesPerRow(conf)
            cPtr = UnsafeBufferPointer(start: cBase.assumingMemoryBound(to: UInt8.self), count: cStride * CVPixelBufferGetHeight(conf))
        }
        return DepthSampler.sample(depth: dPtr, confidence: cPtr, width: w, height: h,
                                   rowStride: stride, confidenceRowStride: cStride, at: DepthSampler.sensorPoint(fromUpright: point))
    }
}
#endif
EOF_AVAE

cat > 'EchoGuide/Core/Fence/DigitalFenceEngine.swift' <<'EOF_AVAE'
// Owner: Bryan. The digital fence, in two layers:
//
//  1. Spatial fence: hazard zones the camera can see (hob, oven door, stair
//     edge, knife block). Zones come from a detected label ("oven") or a fixed
//     region of the frame. The fingertip approaching a zone triggers a warning
//     before contact; LiDAR depth tightens it when available.
//  2. Location fence: safe areas (home, day centre) for dementia wandering.
//     Leaving one is reported once after a dwell, never on GPS jitter.
//
// Both layers only *report* FenceEvents. AutomationEngine decides what the
// user feels and hears; caregiver alerts go through a plugin tool.

import Foundation
import EchoGuideContracts

// MARK: - Spatial fence

public struct SpatialFenceZone: Sendable, Equatable {
    public enum Anchor: Sendable, Equatable {
        /// Follows any detection with this label, e.g. "oven".
        case label(String)
        /// Fixed region of the frame, for a fixed camera mount.
        case region(ImageRect)
    }

    public var name: String
    public var anchor: Anchor
    /// Expand the zone by this much (normalized) to warn before contact.
    public var warningMargin: Float
    /// When depth is known, only warn within this many metres of the zone surface.
    public var warningDepthMetres: Float

    public init(name: String, anchor: Anchor, warningMargin: Float = 0.08, warningDepthMetres: Float = 0.35) {
        self.name = name
        self.anchor = anchor
        self.warningMargin = warningMargin
        self.warningDepthMetres = warningDepthMetres
    }
}

public struct SpatialFence: Sendable {
    public var zones: [SpatialFenceZone]

    public init(zones: [SpatialFenceZone]) { self.zones = zones }

    public static let kitchenDefaults = SpatialFence(zones: [
        SpatialFenceZone(name: "hob", anchor: .label("oven")),
        SpatialFenceZone(name: "knife", anchor: .label("knife"), warningMargin: 0.05),
    ])

    /// Evaluate one frame. `handDepth` and `zoneDepth` are metres from LiDAR,
    /// nil when unknown (then the 2-D test alone decides). One `zoneDepth`
    /// applies to every zone; use `evaluate(_:depth:)` to sample each zone.
    /// Returns the most severe event: a breach beats an approach.
    public func evaluate(_ frame: VisionFrameResult, handDepth: Float? = nil, zoneDepth: Float? = nil) -> FenceEvent? {
        guard let tip = frame.fingertip?.box.mid else { return nil }
        let gap: Float? = {
            guard let h = handDepth, let z = zoneDepth else { return nil }
            return abs(z - h)
        }()
        return resolve(tip: tip, candidates: candidates(in: frame).map { ($0.zone, $0.rect, gap) })
    }

    /// Evaluate one frame against a live depth source (LiDAR). The hand and
    /// the centre of every zone rect are sampled, so a hob at 1.2 m and a
    /// knife at 0.4 m each get their own distance to the hand. A zone whose
    /// depth is unknown falls back to the 2-D test.
    public func evaluate(_ frame: VisionFrameResult, depth: DepthProviding?) async -> FenceEvent? {
        guard let tip = frame.fingertip?.box.mid else { return nil }
        let pairs = candidates(in: frame)
        guard let depth, !pairs.isEmpty, let hand = await depth.depth(at: tip) else {
            return resolve(tip: tip, candidates: pairs.map { ($0.zone, $0.rect, nil) })
        }
        var withGap: [(SpatialFenceZone, ImageRect, Float?)] = []
        withGap.reserveCapacity(pairs.count)
        for (zone, rect) in pairs {
            let z = await depth.depth(at: rect.mid)
            withGap.append((zone, rect, z.map { abs($0 - hand) }))
        }
        return resolve(tip: tip, candidates: withGap)
    }

    private func candidates(in frame: VisionFrameResult) -> [(zone: SpatialFenceZone, rect: ImageRect)] {
        zones.flatMap { zone in rects(for: zone, in: frame).map { (zone, $0) } }
    }

    /// `candidates` carries each zone rect with the hand-to-zone depth gap in
    /// metres (nil when unknown).
    private func resolve(tip: ImagePoint, candidates: [(SpatialFenceZone, ImageRect, Float?)]) -> FenceEvent? {
        var approaching: FenceEvent?

        for (zone, rect, depthGap) in candidates {
            if rect.contains(tip) {
                // Overlapping in 2-D but clearly far apart in depth is not contact.
                if let gap = depthGap, gap > zone.warningDepthMetres {
                    approaching = approaching ?? .approaching(zone: zone.name, metres: gap)
                    continue
                }
                return .breached(zone: zone.name)
            }

            let m = zone.warningMargin
            let warn = ImageRect(x: rect.x - m, y: rect.y - m, width: rect.width + 2 * m, height: rect.height + 2 * m)
            if warn.contains(tip), approaching == nil {
                if let gap = depthGap, gap > zone.warningDepthMetres { continue }
                approaching = .approaching(zone: zone.name, metres: depthGap)
            }
        }
        return approaching
    }

    private func rects(for zone: SpatialFenceZone, in frame: VisionFrameResult) -> [ImageRect] {
        switch zone.anchor {
        case .region(let r):
            return [r]
        case .label(let label):
            return frame.targets.filter { $0.label == label }.map(\.box)
        }
    }
}

// MARK: - Location fence

public struct GeoCoordinate: Sendable, Equatable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Haversine distance in metres.
    public func distance(to o: GeoCoordinate) -> Double {
        let r = 6_371_000.0
        let dLat = (o.latitude - latitude) * .pi / 180
        let dLon = (o.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(o.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}

public struct SafeArea: Sendable, Equatable, Codable {
    public var name: String
    public var center: GeoCoordinate
    public var radiusMetres: Double

    public init(name: String, center: GeoCoordinate, radiusMetres: Double) {
        self.name = name
        self.center = center
        self.radiusMetres = radiusMetres
    }
}

/// Pure state machine over location fixes. Feed it CLLocation updates; it emits
/// at most one event per real crossing.
public struct LocationFence: Sendable {
    public var areas: [SafeArea]
    /// Must be outside every area for this long before `leftSafeArea` fires.
    public var exitDwell: TimeInterval
    /// Fixes worse than this are ignored (indoor GPS can be 100 m+ off).
    public var maxAccuracyMetres: Double

    /// Name of the area the last good fix was inside, nil when outside all.
    public private(set) var insideArea: String?
    private var outsideSince: TimeInterval?
    private var reportedExit = false
    private var lastArea: String?

    /// True once an exit has been reported and not yet cancelled by a return.
    public var isOutside: Bool { reportedExit }

    public init(areas: [SafeArea], exitDwell: TimeInterval = 45, maxAccuracyMetres: Double = 65) {
        self.areas = areas
        self.exitDwell = exitDwell
        self.maxAccuracyMetres = maxAccuracyMetres
    }

    public mutating func update(_ c: GeoCoordinate, accuracyMetres: Double, at t: TimeInterval) -> FenceEvent? {
        guard accuracyMetres <= maxAccuracyMetres else { return nil }

        // Inside if the fix is within radius, giving the benefit of the doubt for accuracy.
        let area = areas.first { c.distance(to: $0.center) <= $0.radiusMetres + accuracyMetres / 2 }

        if let area {
            insideArea = area.name
            lastArea = area.name
            outsideSince = nil
            if reportedExit {
                reportedExit = false
                return .returnedToSafeArea(region: area.name)
            }
            return nil
        }

        insideArea = nil
        if outsideSince == nil { outsideSince = t }
        if !reportedExit, let since = outsideSince, t - since >= exitDwell {
            reportedExit = true
            return .leftSafeArea(region: lastArea ?? "safe area")
        }
        return nil
    }
}

#if canImport(CoreLocation) && os(iOS)
import CoreLocation

/// Bridges CoreLocation to LocationFence. Needs "Always" authorization and the
/// location background mode for wandering alerts to work with the screen off.
public final class LocationFenceMonitor: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var fence: LocationFence
    private let onEvent: @Sendable (FenceEvent) -> Void

    public init(areas: [SafeArea], onEvent: @escaping @Sendable (FenceEvent) -> Void) {
        fence = LocationFence(areas: areas)
        self.onEvent = onEvent
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
    }

    public func start() {
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
    }

    public func stop() { manager.stopUpdatingLocation() }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for l in locations {
            let c = GeoCoordinate(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude)
            if let e = fence.update(c, accuracyMetres: l.horizontalAccuracy, at: l.timestamp.timeIntervalSince1970) {
                onEvent(e)
            }
        }
    }
}
#endif
EOF_AVAE

cat > 'EchoGuide/Core/Haptics/SpatialHapticEngine.swift' <<'EOF_AVAE'
// Owner: Bryan. Turns "target minus fingertip" into transient CoreHaptics
// pulses, like a parking sensor in the hand:
//   * pulse rate and intensity rise as the finger closes on the target
//   * sharpness encodes vertical: crisp = move up, dull = move down
//   * left/right is carried by spatial audio (a phone has one actuator, so
//     haptics cannot point sideways on their own)
//   * inside tolerance: a distinct double tap, then silence

import Foundation
import EchoGuideContracts

public struct HapticPulse: Sendable, Equatable {
    public var intensity: Float
    public var sharpness: Float
    /// Seconds until the next pulse.
    public var interval: TimeInterval
}

public enum HapticMapping {
    /// Normalized distance at or below which the finger counts as on target.
    public static let alignedTolerance: Float = Alignment.tolerance
    /// Beyond this distance, pulses are at their slowest.
    public static let farDistance: Float = 0.5

    /// nil means aligned: play the confirm pattern instead.
    public static func pulse(dx: Float, dy: Float, distanceMetres: Float? = nil) -> HapticPulse? {
        let d = (dx * dx + dy * dy).squareRoot()
        guard d > alignedTolerance else { return nil }

        let closeness = 1 - min(1, (d - alignedTolerance) / (farDistance - alignedTolerance)) // 0 far ... 1 close
        // 1.6 Hz far ... 12 Hz close.
        let interval = TimeInterval(0.625 - 0.542 * closeness)
        var intensity = 0.35 + 0.65 * closeness
        // LiDAR: a hand far from the surface feels slightly weaker, so "closer
        // to the button" and "closer to the panel" both read as stronger.
        if let m = distanceMetres { intensity *= max(0.6, min(1, 1.2 - m)) }

        // Image y grows downward, so target above the finger means dy < 0.
        let vertical = d > 0 ? -dy / d : 0 // +1 = move up, -1 = move down
        let sharpness = 0.5 + 0.45 * vertical
        return HapticPulse(intensity: min(1, intensity), sharpness: max(0, min(1, sharpness)), interval: interval)
    }
}

#if canImport(CoreHaptics)
import CoreHaptics

public actor SpatialHapticEngine: HapticCueing {
    private var engine: CHHapticEngine?
    private var loop: Task<Void, Never>?
    private var current: HapticPulse?
    private var lastConfirm: Double = -.infinity
    private let clock = FrameTimer()

    public init() {}

    public var isSupported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    /// True while the guidance pulse train is running (for telemetry and tests).
    public var isGuiding: Bool { current != nil }

    private func ensureEngine() throws -> CHHapticEngine? {
        guard isSupported else { return nil }
        if let engine { return engine }
        let e = try CHHapticEngine()
        e.isAutoShutdownEnabled = false
        e.playsHapticsOnly = true
        // The system can stop the engine (audio interruptions, backgrounding);
        // restart lazily on the next pulse instead of failing silently.
        e.stoppedHandler = { [weak self] _ in Task { await self?.dropEngine() } }
        e.resetHandler = { [weak self] in Task { await self?.dropEngine() } }
        try e.start()
        engine = e
        return e
    }

    private func dropEngine() { engine = nil }

    public func guide(offset dx: Float, _ dy: Float, distanceMetres: Float?) async {
        guard let pulse = HapticMapping.pulse(dx: dx, dy: dy, distanceMetres: distanceMetres) else {
            current = nil
            await confirm()
            return
        }
        current = pulse
        if loop == nil { startLoop() }
    }

    public func confirm() async {
        // On target: the guidance train stops, whoever called us.
        current = nil
        // Debounce: hovering on target should not buzz continuously.
        let now = clock.elapsedMs
        guard now - lastConfirm > 1_000 else { return }
        lastConfirm = now
        play([(0, 1.0, 0.9), (0.09, 1.0, 0.9)])
    }

    public func warn() async {
        current = nil
        play([(0, 1.0, 0.1), (0.12, 1.0, 0.1), (0.24, 1.0, 0.1), (0.36, 1.0, 0.1)])
    }

    public func stop() async {
        current = nil
        loop?.cancel()
        loop = nil
    }

    private func startLoop() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let pulse = await self.tick() else { break }
                try? await Task.sleep(nanoseconds: UInt64(pulse.interval * 1_000_000_000))
            }
            await self?.loopEnded()
        }
    }

    private func tick() -> HapticPulse? {
        guard let p = current else { return nil }
        play([(0, p.intensity, p.sharpness)])
        return p
    }

    private func loopEnded() {
        loop = nil
        // A guide() that landed between the loop's last tick and this call
        // would otherwise wait for the next frame; pick it up now.
        if current != nil { startLoop() }
    }

    /// (relativeTime, intensity, sharpness) transients.
    private func play(_ events: [(TimeInterval, Float, Float)]) {
        do {
            guard let engine = try ensureEngine() else { return }
            let hapticEvents = events.map { t, i, s in
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: i),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: s),
                    ],
                    relativeTime: t
                )
            }
            let player = try engine.makePlayer(with: CHHapticPattern(events: hapticEvents, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            engine = nil
        }
    }
}
#endif
EOF_AVAE

cat > 'EchoGuide/Core/Plugins/BuiltInPlugins.swift' <<'EOF_AVAE'
// Owner: Maxwell. The first real tools, chosen for the differentiation plan:
//
//  * HomeAssistantPlugin   press the button for the user (microwave, kettle,
//                          lights, thermostat) through one Home Assistant hub,
//                          which already integrates thousands of appliances.
//  * CaregiverAlerts       tell the carer when the location fence trips. Alerts
//                          are written to a disk outbox first, so one sent
//                          offline is delivered when the phone reconnects.
//  * ProductLookupPlugin   barcode -> product name and allergens (Open Food Facts).

import Foundation
import EchoGuideContracts
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Looks up a secret (token, signing key) by name. Keychain in the app; a
/// dictionary in tests. Secrets never live in the manifest.
public typealias SecretProvider = @Sendable (String) async -> String?

// MARK: - Home Assistant

public struct HomeAssistantEntity: Sendable, Equatable, Codable {
    /// Tool name, e.g. "microwave_start".
    public var name: String
    /// What the user hears after it worked: "Microwave started."
    public var doneSentence: String
    public var entityId: String
    /// Home Assistant service, "domain.service", e.g. "switch.turn_on".
    public var service: String
    public var labels: [String]?
    public var textContains: [String]?
    public var sideEffect: ToolSideEffect

    public init(name: String, doneSentence: String, entityId: String, service: String,
                labels: [String]? = nil, textContains: [String]? = nil, sideEffect: ToolSideEffect = .physical) {
        self.name = name
        self.doneSentence = doneSentence
        self.entityId = entityId
        self.service = service
        self.labels = labels
        self.textContains = textContains
        self.sideEffect = sideEffect
    }
}

public enum HomeAssistantPlugin {
    /// One tool per entity. Calls `POST {base}/api/services/{domain}/{service}`
    /// with a long-lived access token.
    public static func tools(baseURL: URL, entities: [HomeAssistantEntity], transport: HTTPTransport,
                             token: @escaping @Sendable () async -> String?) -> [ToolDescriptor] {
        entities.compactMap { e in
            let parts = e.service.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let url = baseURL.appendingPathComponent("api/services/\(parts[0])/\(parts[1])")
            return ToolDescriptor(
                name: e.name,
                description: "Home Assistant \(e.service) on \(e.entityId)",
                sideEffect: e.sideEffect,
                claim: ToolClaim(labels: Set(e.labels ?? []), textContains: e.textContains ?? [])
            ) { _ in
                _ = try await transport.postJSON(url, body: ["entity_id": e.entityId], bearer: await token())
                return e.doneSentence
            }
        }
    }
}

// MARK: - Caregiver alerts

public struct CaregiverAlert: Sendable, Equatable, Codable {
    public var id: UUID
    public var event: String
    public var region: String
    public var at: Date
}

/// Thrown when the alert is safely queued but not yet delivered, so the caller
/// does not tell the user "your carer has been told" when that is not true yet.
public struct CaregiverAlertQueued: Error, Equatable {}

public actor CaregiverAlerts {
    private let webhook: URL
    private let transport: HTTPTransport
    private let outboxURL: URL?
    private let signingSecret: String?
    private var outbox: [CaregiverAlert]

    /// `outboxURL` persists undelivered alerts across app launches; nil keeps
    /// them in memory only (tests).
    public init(webhook: URL, transport: HTTPTransport, outboxURL: URL?, signingSecret: String? = nil) {
        self.webhook = webhook
        self.transport = transport
        self.outboxURL = outboxURL
        self.signingSecret = signingSecret
        if let outboxURL, let data = try? Data(contentsOf: outboxURL),
           let saved = try? Self.decoder.decode([CaregiverAlert].self, from: data) {
            outbox = saved
        } else {
            outbox = []
        }
    }

    public var pending: Int { outbox.count }

    /// Queue, then try to deliver everything queued. True when this alert went out.
    @discardableResult
    public func send(event: String, region: String, at date: Date = Date()) async -> Bool {
        let alert = CaregiverAlert(id: UUID(), event: event, region: region, at: date)
        outbox.append(alert)
        save()
        await flush()
        return !outbox.contains(alert)
    }

    /// Call on reconnect (NWPathMonitor) and on app launch.
    public func flush() async {
        var remaining: [CaregiverAlert] = []
        for alert in outbox {
            do {
                try await deliver(alert)
            } catch {
                remaining.append(alert)
            }
        }
        outbox = remaining
        save()
    }

    public var tool: ToolDescriptor {
        ToolDescriptor(name: "notify_caregiver", description: "Tell the carer the user left a safe area",
                       sideEffect: .none, parameters: ["region"]) { [self] args in
            let delivered = await self.send(event: "left_safe_area", region: args["region"] ?? "safe area")
            if !delivered { throw CaregiverAlertQueued() }
            return "Your carer has been told."
        }
    }

    private func deliver(_ alert: CaregiverAlert) async throws {
        var req = URLRequest(url: webhook)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The receiver dedupes on this, so a retry after a lost response is safe.
        req.setValue(alert.id.uuidString, forHTTPHeaderField: "Idempotency-Key")
        let body = try Self.encoder.encode(alert)
        req.httpBody = body
        if let signingSecret { req.setValue(Self.signature(body, secret: signingSecret), forHTTPHeaderField: "X-EchoGuide-Signature") }
        let (_, http) = try await transport.send(req)
        guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError(status: http.statusCode) }
    }

    private func save() {
        guard let outboxURL, let data = try? Self.encoder.encode(outbox) else { return }
        try? data.write(to: outboxURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Hex HMAC-SHA256 of the body, so the receiver can reject forged alerts.
    static func signature(_ body: Data, secret: String) -> String {
        #if canImport(CryptoKit)
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        return "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Product lookup

public actor ProductLookupPlugin {
    private let transport: HTTPTransport
    private let base: URL
    private var cache: [String: String] = [:]

    public init(transport: HTTPTransport, base: URL = URL(string: "https://world.openfoodfacts.org")!) {
        self.transport = transport
        self.base = base
    }

    public var tool: ToolDescriptor {
        ToolDescriptor(name: "lookup_product", description: "Say the product name and allergens for a barcode",
                       sideEffect: .none, claim: ToolClaim(anyBarcode: true), parameters: ["text"]) { [self] args in
            await self.describe(args["text"] ?? "")
        }
    }

    public func describe(_ code: String) async -> String {
        // QR codes and other payloads are not product codes; never send them off-device.
        guard (8...14).contains(code.count), code.allSatisfy(\.isNumber) else {
            if let host = URL(string: code)?.host { return "QR code for \(host)." }
            return "This code is not a product barcode."
        }
        if let hit = cache[code] { return hit }

        let url = base.appendingPathComponent("api/v2/product/\(code)")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "fields", value: "product_name,brands,allergens_tags")]
        do {
            let json = try await transport.getJSON(comps.url!, headers: ["User-Agent": "EchoGuide/0.1 (accessibility app)"])
            guard let product = json["product"] as? [String: Any], let name = product["product_name"] as? String, !name.isEmpty else {
                return "I could not find this product."
            }
            let brand = (product["brands"] as? String)?.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
            var sentence = [brand, name].compactMap { $0 }.joined(separator: " ") + "."
            let allergens = (product["allergens_tags"] as? [String] ?? []).map { $0.split(separator: ":").last.map(String.init) ?? $0 }
            if !allergens.isEmpty { sentence += " Contains \(allergens.prefix(4).joined(separator: ", "))." }
            cache[code] = sentence
            return sentence
        } catch {
            return "I cannot look this up right now."
        }
    }
}
EOF_AVAE

cat > 'EchoGuide/Core/Plugins/HTTPTransport.swift' <<'EOF_AVAE'
// Owner: Maxwell. One HTTP seam for every network call in Infra (cloud
// providers, plugins), so tests run against a stub and the app can add
// certificate pinning or a proxy in one place.

import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public var session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public struct HTTPStatusError: Error, Equatable {
    public var status: Int
}

extension HTTPTransport {
    /// POST a JSON object, expect 2xx, return the decoded object (empty for no body).
    func postJSON(_ url: URL, body: [String: Any], bearer: String?, timeout: TimeInterval = 4) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError(status: http.statusCode) }
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func getJSON(_ url: URL, timeout: TimeInterval = 4, headers: [String: String] = [:]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError(status: http.statusCode) }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
EOF_AVAE

cat > 'EchoGuide/Core/Plugins/PluginManifest.swift' <<'EOF_AVAE'
// Owner: Maxwell. One JSON file per home sets up its tools, so a care
// provider can configure a new home without a code change. Secrets are named
// here, never stored here: the app resolves them from the Keychain.
//
// {
//   "homeAssistant": { "baseURL": "http://homeassistant.local:8123", "tokenSecret": "ha_token",
//     "entities": [ { "name": "microwave_start", "doneSentence": "Microwave started.",
//                     "entityId": "switch.microwave", "service": "switch.turn_on",
//                     "textContains": ["start"], "sideEffect": "physical" } ] },
//   "caregiver": { "webhookURL": "https://care.example.com/alerts", "signingSecret": "care_hmac" },
//   "productLookup": true,
//   "remoteServers": [ { "endpoint": "https://plugins.example.com/mcp",
//                        "claims": { "thermostat_set": { "labels": ["thermostat"] } },
//                        "sideEffects": { "thermostat_set": "reversible" } } ]
// }

import Foundation
import EchoGuideContracts

public struct PluginManifest: Sendable, Codable, Equatable {
    public struct HomeAssistant: Sendable, Codable, Equatable {
        public var baseURL: URL
        public var tokenSecret: String
        public var entities: [HomeAssistantEntity]
    }

    public struct Caregiver: Sendable, Codable, Equatable {
        public var webhookURL: URL
        public var signingSecret: String?
    }

    public struct Claim: Sendable, Codable, Equatable {
        public var labels: [String]?
        public var textContains: [String]?
        public var barcodePrefixes: [String]?

        var toolClaim: ToolClaim {
            ToolClaim(labels: Set(labels ?? []), textContains: textContains ?? [], barcodePrefixes: barcodePrefixes ?? [])
        }
    }

    public struct RemoteServer: Sendable, Codable, Equatable {
        public var endpoint: URL
        public var claims: [String: Claim]?
        public var sideEffects: [String: ToolSideEffect]?
        /// Name of a secret sent as `Authorization: Bearer`.
        public var tokenSecret: String?
    }

    public var homeAssistant: HomeAssistant?
    public var caregiver: Caregiver?
    public var productLookup: Bool?
    public var remoteServers: [RemoteServer]?

    public static func load(_ data: Data) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: data)
    }
}

public struct InstalledPlugins: Sendable {
    /// Keep a handle so the app can `flush()` on reconnect and launch.
    public var caregiver: CaregiverAlerts?
    /// Remote servers that could not be reached; their tools are missing until retried.
    public var failedRemotes: [URL]
}

extension PluginRegistry {
    /// Registers every tool the manifest describes. Local tools first, so a
    /// remote server cannot shadow a built-in by registering the same name.
    @discardableResult
    public func install(_ manifest: PluginManifest, secrets: @escaping SecretProvider,
                        transport: HTTPTransport = URLSessionTransport(), outboxURL: URL? = nil) async -> InstalledPlugins {
        var installed = InstalledPlugins(caregiver: nil, failedRemotes: [])

        if let ha = manifest.homeAssistant {
            let secret = ha.tokenSecret
            for tool in HomeAssistantPlugin.tools(baseURL: ha.baseURL, entities: ha.entities, transport: transport,
                                                  token: { await secrets(secret) }) {
                register(tool)
            }
        }

        if let c = manifest.caregiver {
            let signing: String? = if let name = c.signingSecret { await secrets(name) } else { nil }
            let alerts = CaregiverAlerts(webhook: c.webhookURL, transport: transport, outboxURL: outboxURL, signingSecret: signing)
            register(await alerts.tool)
            installed.caregiver = alerts
        }

        if manifest.productLookup == true {
            register(await ProductLookupPlugin(transport: transport).tool)
        }

        let local = Set(toolNames)
        for server in manifest.remoteServers ?? [] {
            var headers: [String: String] = [:]
            if let name = server.tokenSecret, let token = await secrets(name) { headers["Authorization"] = "Bearer \(token)" }
            let client = MCPHTTPClient(endpoint: server.endpoint, headers: headers)
            do {
                try await registerRemote(client, claims: (server.claims ?? [:]).mapValues(\.toolClaim),
                                         sideEffects: server.sideEffects ?? [:], skipping: local)
            } catch {
                installed.failedRemotes.append(server.endpoint)
            }
        }
        return installed
    }
}
EOF_AVAE

cat > 'EchoGuide/Core/Plugins/PluginRegistry.swift' <<'EOF_AVAE'
// Owner: Maxwell. Tool layer speaking the Model Context Protocol.
//
//  * Local tools: Swift handlers registered in-process, exposed through MCP
//    `tools/list` and `tools/call` JSON-RPC so any MCP client can drive them.
//  * Remote tools: plugin servers written with FastMCP (Python) or any MCP
//    server, reached over the Streamable HTTP transport by MCPHTTPClient.
//
// Each tool declares which detections it claims (labels, text, barcode
// prefixes) and its side effect; AutomationEngine never calls a physical tool
// without the dwell confirmation.

import Foundation
import EchoGuideContracts

// MARK: - JSON

public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

// MARK: - Tools

public struct ToolClaim: Sendable, Equatable {
    public var labels: Set<String> = []
    /// Case-insensitive substrings of recognised text ("start", "defrost").
    public var textContains: [String] = []
    public var barcodePrefixes: [String] = []
    /// Claim every barcode (product lookup).
    public var anyBarcode = false

    public init(labels: Set<String> = [], textContains: [String] = [], barcodePrefixes: [String] = [], anyBarcode: Bool = false) {
        self.labels = labels
        self.textContains = textContains
        self.barcodePrefixes = barcodePrefixes
        self.anyBarcode = anyBarcode
    }

    func claims(_ d: Detection) -> Bool {
        if labels.contains(d.label) { return true }
        guard let text = d.text?.lowercased() else { return false }
        if d.kind == .barcode { return anyBarcode || barcodePrefixes.contains { text.hasPrefix($0.lowercased()) } }
        return textContains.contains { text.contains($0.lowercased()) }
    }
}

public struct ToolDescriptor: Sendable {
    public typealias Handler = @Sendable ([String: String]) async throws -> String

    public var name: String
    public var description: String
    public var sideEffect: ToolSideEffect
    public var claim: ToolClaim
    /// Argument names, all strings; published as the MCP inputSchema.
    public var parameters: [String]
    public var handler: Handler

    public init(name: String, description: String, sideEffect: ToolSideEffect, claim: ToolClaim = ToolClaim(),
                parameters: [String] = [], handler: @escaping Handler) {
        self.name = name
        self.description = description
        self.sideEffect = sideEffect
        self.claim = claim
        self.parameters = parameters
        self.handler = handler
    }

    var inputSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(Dictionary(uniqueKeysWithValues: parameters.map { ($0, .object(["type": .string("string")])) })),
            "required": .array(parameters.map(JSONValue.string)),
        ])
    }
}

public enum PluginError: Error, Equatable {
    case unknownTool(String)
    case remote(String)
}

public actor PluginRegistry: ToolInvoking {
    private var tools: [String: ToolDescriptor] = [:]
    private var order: [String] = []

    public init() {}

    public func register(_ tool: ToolDescriptor) {
        if tools[tool.name] == nil { order.append(tool.name) }
        tools[tool.name] = tool
    }

    /// Pull every tool from a remote MCP server and proxy calls to it.
    /// Remote tools claim detections through `claims`, keyed by tool name,
    /// because MCP has no notion of "what this tool can see".
    /// Names in `skipping` are never replaced (built-ins win over remote tools).
    public func registerRemote(_ client: MCPHTTPClient, claims: [String: ToolClaim], sideEffects: [String: ToolSideEffect] = [:],
                               skipping: Set<String> = []) async throws {
        for remote in try await client.listTools() where !skipping.contains(remote.name) {
            register(ToolDescriptor(
                name: remote.name,
                description: remote.description,
                sideEffect: sideEffects[remote.name] ?? .physical, // unknown = treat as most dangerous
                claim: claims[remote.name] ?? ToolClaim(),
                parameters: remote.parameters
            ) { args in try await client.callTool(remote.name, arguments: args) })
        }
    }

    public var toolNames: [String] { order }

    // MARK: ToolInvoking

    public func match(_ detection: Detection) -> ToolMatch? {
        for name in order {
            guard let t = tools[name], t.claim.claims(detection) else { continue }
            var args: [String: String] = [:]
            if t.parameters.contains("label") { args["label"] = detection.label }
            if t.parameters.contains("text"), let text = detection.text { args["text"] = text }
            return ToolMatch(toolName: t.name, sideEffect: t.sideEffect, arguments: args)
        }
        return nil
    }

    public func invoke(_ match: ToolMatch) async throws -> String {
        guard let t = tools[match.toolName] else { throw PluginError.unknownTool(match.toolName) }
        return try await t.handler(match.arguments)
    }

    // MARK: MCP server surface (JSON-RPC 2.0)

    /// Handles one MCP JSON-RPC request. Returns nil for notifications.
    public func handle(_ request: Data) async -> Data? {
        guard let req = try? JSONDecoder().decode(JSONValue.self, from: request),
              let method = req["method"]?.stringValue else {
            return encode(rpcError(id: .null, code: -32700, message: "Parse error"))
        }
        let id = req["id"] ?? .null
        if case .null = id, method.hasPrefix("notifications/") { return nil }

        switch method {
        case "initialize":
            return encode(rpcResult(id: id, .object([
                "protocolVersion": .string(MCP.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("echoguide"), "version": .string("0.1.0")]),
            ])))
        case "tools/list":
            let list: [JSONValue] = order.compactMap { tools[$0] }.map {
                .object(["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema])
            }
            return encode(rpcResult(id: id, .object(["tools": .array(list)])))
        case "tools/call":
            guard let name = req["params"]?["name"]?.stringValue else {
                return encode(rpcError(id: id, code: -32602, message: "Missing tool name"))
            }
            var args: [String: String] = [:]
            if case .object(let o)? = req["params"]?["arguments"] {
                for (k, v) in o { if let s = v.stringValue { args[k] = s } }
            }
            guard let t = tools[name] else {
                return encode(rpcError(id: id, code: -32602, message: "Unknown tool: \(name)"))
            }
            do {
                let text = try await t.handler(args)
                return encode(rpcResult(id: id, MCP.textContent(text, isError: false)))
            } catch {
                // MCP reports tool failures as results with isError, not protocol errors.
                return encode(rpcResult(id: id, MCP.textContent(String(describing: error), isError: true)))
            }
        default:
            return encode(rpcError(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func rpcResult(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func rpcError(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    private func encode(_ v: JSONValue) -> Data? { try? JSONEncoder().encode(v) }
}

enum MCP {
    static let protocolVersion = "2025-06-18"

    static func textContent(_ text: String, isError: Bool) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(isError)])
    }
}

// MARK: - Remote MCP client (Streamable HTTP)

public actor MCPHTTPClient {
    public struct RemoteTool: Sendable { public var name, description: String; public var parameters: [String] }

    private let endpoint: URL
    private let session: URLSession
    private let headers: [String: String]
    private var sessionID: String?
    private var initialized = false
    private var nextID = 1

    /// `endpoint` is the server's MCP path, e.g. `https://plugins.example.com/mcp`
    /// for `fastmcp run server.py --transport http`.
    public init(endpoint: URL, headers: [String: String] = [:], session: URLSession = .shared) {
        self.endpoint = endpoint
        self.headers = headers
        self.session = session
    }

    public func listTools() async throws -> [RemoteTool] {
        try await ensureInitialized()
        let result = try await call("tools/list", params: .object([:]))
        guard case .array(let tools)? = result["tools"] else { return [] }
        return tools.compactMap { t in
            guard let name = t["name"]?.stringValue else { return nil }
            var params: [String] = []
            if case .object(let props)? = t["inputSchema"]?["properties"] { params = props.keys.sorted() }
            return RemoteTool(name: name, description: t["description"]?.stringValue ?? "", parameters: params)
        }
    }

    public func callTool(_ name: String, arguments: [String: String]) async throws -> String {
        try await ensureInitialized()
        let result = try await call("tools/call", params: .object([
            "name": .string(name),
            "arguments": .object(arguments.mapValues(JSONValue.string)),
        ]))
        var text = ""
        if case .array(let content)? = result["content"] {
            text = content.compactMap { $0["text"]?.stringValue }.joined(separator: " ")
        }
        if case .bool(true)? = result["isError"] { throw PluginError.remote(text) }
        return text
    }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        _ = try await call("initialize", params: .object([
            "protocolVersion": .string(MCP.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("echoguide"), "version": .string("0.1.0")]),
        ]))
        try await post(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
        initialized = true
    }

    private func call(_ method: String, params: JSONValue) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let data = try await post(.object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params,
        ]))
        guard let data else { throw PluginError.remote("Empty response to \(method)") }
        let msg = try JSONDecoder().decode(JSONValue.self, from: data)
        if let err = msg["error"] { throw PluginError.remote(err["message"]?.stringValue ?? "MCP error") }
        return msg["result"] ?? .null
    }

    @discardableResult
    private func post(_ body: JSONValue) async throws -> Data? {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 4
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(MCP.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw PluginError.remote("No HTTP response") }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
        if http.statusCode == 202 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw PluginError.remote("HTTP \(http.statusCode)") }

        // Streamable HTTP may answer as SSE; the JSON-RPC response is the last `data:` event.
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            let payload = lines.last { $0.hasPrefix("data:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            return payload.map { Data($0.utf8) }
        }
        return data
    }
}
EOF_AVAE

cat > 'EchoGuide/Core/Router/CloudReasoningRouter.swift' <<'EOF_AVAE'
// Owner: Maxwell. Decides local vs cloud for one reasoning query and never
// lets the cloud make the app worse than local:
//   * local confidence >= threshold        -> answered locally, no network
//   * offline / no consent / breaker open  -> local fallback, flagged
//   * otherwise                            -> provider, under a hard timeout
// Keys never ship in the app: providers point at a proxy you run, which holds
// the real Gemini / OpenAI keys and rate-limits per device.

import Foundation
import EchoGuideContracts

public struct CloudRouterConfig: Sendable {
    public var confidenceThreshold: Float = 0.85
    /// Hard ceiling; past this the local answer is spoken instead.
    public var timeout: TimeInterval = 2.5
    /// Consecutive failures that open the breaker, and how long it stays open.
    public var breakerFailures = 3
    public var breakerCooldown: TimeInterval = 60
    /// Per-session ceiling on cloud calls (cost guard).
    public var maxCallsPerSession = 200
    /// Camera images leave the device only when the user has agreed.
    public var imageConsent = false

    public init() {}
}

/// One cloud model behind the router. Swap Gemini / OpenAI / anything.
public protocol ReasoningProvider: Sendable {
    func answer(_ query: ReasoningQuery, includeImage: Bool) async throws -> String
}

public protocol Connectivity: Sendable {
    func isOnline() async -> Bool
}

public actor CloudReasoningRouter: ReasoningRouting {
    private let config: CloudRouterConfig
    private let provider: ReasoningProvider?
    private let connectivity: Connectivity
    private var failures = 0
    private var breakerOpenedAt: Date?
    private var calls = 0
    public private(set) var latency = LatencyWindow()

    public init(config: CloudRouterConfig = CloudRouterConfig(), provider: ReasoningProvider?, connectivity: Connectivity) {
        self.config = config
        self.provider = provider
        self.connectivity = connectivity
    }

    public func resolve(_ query: ReasoningQuery) async -> ReasoningOutcome {
        let timer = FrameTimer()
        let local = Self.localAnswer(query)

        if query.localConfidence >= config.confidenceThreshold {
            return ReasoningOutcome(answer: local, source: .local, latencyMs: timer.elapsedMs)
        }
        guard let provider, calls < config.maxCallsPerSession, !breakerOpen, await connectivity.isOnline() else {
            return ReasoningOutcome(answer: local, source: .localFallback, latencyMs: timer.elapsedMs)
        }

        calls += 1
        let includeImage = config.imageConsent && query.jpeg != nil
        let timeout = config.timeout
        do {
            let text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await provider.answer(query, includeImage: includeImage) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw RouterError.timeout
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw RouterError.timeout }
                return first
            }
            failures = 0
            let ms = timer.elapsedMs
            latency.record(ms)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ReasoningOutcome(answer: trimmed.isEmpty ? local : trimmed, source: trimmed.isEmpty ? .localFallback : .cloud, latencyMs: ms)
        } catch {
            failures += 1
            if failures >= config.breakerFailures { breakerOpenedAt = Date() }
            return ReasoningOutcome(answer: local, source: .localFallback, latencyMs: timer.elapsedMs)
        }
    }

    private var breakerOpen: Bool {
        guard let opened = breakerOpenedAt else { return false }
        if Date().timeIntervalSince(opened) >= config.breakerCooldown {
            breakerOpenedAt = nil
            failures = 0
            return false
        }
        return true
    }

    /// Best on-device sentence from detections alone. Always available.
    static func localAnswer(_ q: ReasoningQuery) -> String {
        guard let top = q.detections.max(by: { $0.confidence < $1.confidence }) else { return "I am not sure what this is." }
        let name = top.kind == .text ? (top.text ?? "Some text") : top.label
        return q.localConfidence >= 0.6 ? "This looks like \(name)." : "This might be \(name)."
    }

    enum RouterError: Error { case timeout }
}

// MARK: - Providers

/// Gemini `generateContent` through your proxy. The proxy forwards to
/// `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`.
public struct GeminiProvider: ReasoningProvider {
    public var proxyBase: URL
    public var model: String
    public var deviceToken: @Sendable () async -> String?
    public var transport: HTTPTransport

    public init(proxyBase: URL, model: String = "gemini-2.5-flash", transport: HTTPTransport = URLSessionTransport(),
                deviceToken: @escaping @Sendable () async -> String?) {
        self.proxyBase = proxyBase
        self.model = model
        self.transport = transport
        self.deviceToken = deviceToken
    }

    public func answer(_ q: ReasoningQuery, includeImage: Bool) async throws -> String {
        var parts: [[String: Any]] = [["text": Prompt.text(q)]]
        if includeImage, let jpeg = q.jpeg {
            parts.append(["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]])
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["maxOutputTokens": 40, "temperature": 0.2],
        ]
        let url = proxyBase.appendingPathComponent("v1beta/models/\(model):generateContent")
        let json = try await transport.postJSON(url, body: body, bearer: await deviceToken())
        let candidates = json["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let textParts = content?["parts"] as? [[String: Any]]
        return textParts?.compactMap { $0["text"] as? String }.joined() ?? ""
    }
}

/// OpenAI Chat Completions (gpt-4o) through your proxy. For multi-turn voice,
/// the Realtime API is a separate WebSocket session and not routed here.
public struct OpenAIProvider: ReasoningProvider {
    public var proxyBase: URL
    public var model: String
    public var deviceToken: @Sendable () async -> String?
    public var transport: HTTPTransport

    public init(proxyBase: URL, model: String = "gpt-4o", transport: HTTPTransport = URLSessionTransport(),
                deviceToken: @escaping @Sendable () async -> String?) {
        self.proxyBase = proxyBase
        self.model = model
        self.transport = transport
        self.deviceToken = deviceToken
    }

    public func answer(_ q: ReasoningQuery, includeImage: Bool) async throws -> String {
        var content: [[String: Any]] = [["type": "text", "text": Prompt.text(q)]]
        if includeImage, let jpeg = q.jpeg {
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())", "detail": "low"]])
        }
        let body: [String: Any] = ["model": model, "max_tokens": 40, "temperature": 0.2, "messages": [["role": "user", "content": content]]]
        let json = try await transport.postJSON(proxyBase.appendingPathComponent("v1/chat/completions"), body: body, bearer: await deviceToken())
        let choices = json["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String ?? ""
    }
}

enum Prompt {
    static func text(_ q: ReasoningQuery) -> String {
        let seen = q.detections.map { d in
            "\(d.kind == .text ? "text \"\(d.text ?? "")\"" : d.label) (\(Int(d.confidence * 100))%)"
        }.joined(separator: ", ")
        return """
        You guide a blind or cognitively impaired person, one step at a time. \
        On-device vision saw: \(seen). \(q.question) \
        Answer in one short plain sentence, no lists, under eight words.
        """
    }
}

#if canImport(Network)
import Network

/// NWPathMonitor-backed connectivity. Airplane Mode reads as offline instantly.
public final class PathConnectivity: Connectivity, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = false

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.online = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "echoguide.network"))
    }

    deinit { monitor.cancel() }

    public func isOnline() async -> Bool {
        lock.withLock { online }
    }
}
#endif
EOF_AVAE

cat > 'EchoGuide/Core/Router/VoiceLoop.swift' <<'EOF_AVAE'
// Owner: Maxwell. Optional voice layer on top of the hands-free core.
//
//   mic (16 kHz PCM16) --WebSocket--> Deepgram live STT --> transcripts
//   text --HTTP stream--> ElevenLabs TTS (through the proxy) --> PCM chunks
//
// Keys never ship: the proxy mints a 30-second Deepgram token per session and
// forwards TTS. Offline, none of this runs and on-device speech carries on;
// voice is a convenience ("find the start button"), never a requirement.

import Foundation
import EchoGuideContracts

public struct Transcript: Sendable, Equatable {
    public var text: String
    /// Deepgram `is_final`: this segment will not be revised.
    public var isFinal: Bool
    /// Deepgram `speech_final`: the speaker paused; act on it now.
    public var endOfUtterance: Bool
}

/// What a spoken sentence asks for. Deliberately tiny: two intents cover the
/// hands-free product; anything else becomes a question for the router.
public enum VoiceIntent: Sendable, Equatable {
    case find(String)
    case stop
    case question(String)

    public static func parse(_ raw: String) -> VoiceIntent? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !s.isEmpty else { return nil }
        if ["stop", "cancel", "never mind", "nevermind"].contains(s) { return .stop }
        for prefix in ["find the ", "find my ", "find ", "where is the ", "where is my ", "where's the ", "where is ", "show me the "] where s.hasPrefix(prefix) {
            let target = String(s.dropFirst(prefix.count))
            if !target.isEmpty { return .find(target) }
        }
        return .question(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum DeepgramMessage {
    /// Parses one Deepgram live `Results` message; nil for metadata/keepalive.
    static func transcript(from data: Data) -> Transcript? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["type"] as? String == "Results",
              let channel = json["channel"] as? [String: Any],
              let alts = channel["alternatives"] as? [[String: Any]],
              let text = alts.first?["transcript"] as? String, !text.isEmpty else { return nil }
        return Transcript(text: text, isFinal: json["is_final"] as? Bool ?? false, endOfUtterance: json["speech_final"] as? Bool ?? false)
    }
}

public actor DeepgramSTTClient {
    private let proxyBase: URL
    private let transport: HTTPTransport
    private let deviceToken: @Sendable () async -> String?
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var keepAlive: Task<Void, Never>?

    public init(proxyBase: URL, transport: HTTPTransport = URLSessionTransport(), session: URLSession = .shared,
                deviceToken: @escaping @Sendable () async -> String?) {
        self.proxyBase = proxyBase
        self.transport = transport
        self.session = session
        self.deviceToken = deviceToken
    }

    /// Opens a live session. Feed audio with `send(_:)`; read from the stream.
    public func start(model: String = "nova-3", language: String = "en") async throws -> AsyncThrowingStream<Transcript, Error> {
        let grant = try await transport.postJSON(proxyBase.appendingPathComponent("v1/voice/stt-token"), body: [:], bearer: await deviceToken())
        guard let token = grant["access_token"] as? String else { throw URLError(.userAuthenticationRequired) }

        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        comps.queryItems = [
            .init(name: "model", value: model), .init(name: "language", value: language),
            .init(name: "encoding", value: "linear16"), .init(name: "sample_rate", value: "16000"), .init(name: "channels", value: "1"),
            .init(name: "interim_results", value: "true"), .init(name: "endpointing", value: "300"), .init(name: "smart_format", value: "true"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let ws = session.webSocketTask(with: req)
        socket = ws
        ws.resume()

        // Deepgram closes idle sockets after ~10 s without audio.
        keepAlive = Task { [weak ws] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                try? await ws?.send(.string(#"{"type":"KeepAlive"}"#))
            }
        }

        return AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    while true {
                        let message = try await ws.receive()
                        let data: Data
                        switch message {
                        case .string(let s): data = Data(s.utf8)
                        case .data(let d): data = d
                        @unknown default: continue
                        }
                        if let t = DeepgramMessage.transcript(from: data) { continuation.yield(t) }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    /// 16 kHz mono little-endian PCM16.
    public func send(_ pcm: Data) async throws {
        try await socket?.send(.data(pcm))
    }

    public func stop() async {
        keepAlive?.cancel()
        try? await socket?.send(.string(#"{"type":"CloseStream"}"#))
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }
}

public struct ElevenLabsTTSClient: Sendable {
    public var proxyBase: URL
    public var voiceID: String
    public var session: URLSession
    public var deviceToken: @Sendable () async -> String?

    public init(proxyBase: URL, voiceID: String, session: URLSession = .shared, deviceToken: @escaping @Sendable () async -> String?) {
        self.proxyBase = proxyBase
        self.voiceID = voiceID
        self.session = session
        self.deviceToken = deviceToken
    }

    /// Streams 16 kHz mono PCM16 in chunks as they arrive, so playback starts
    /// on the first chunk rather than after the whole sentence.
    public func speak(_ text: String, chunkBytes: Int = 3200, onChunk: @Sendable (Data) async -> Void) async throws {
        var req = URLRequest(url: proxyBase.appendingPathComponent("v1/voice/tts"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = await deviceToken() { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "voice_id": voiceID])

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var buffer = Data()
        buffer.reserveCapacity(chunkBytes)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= chunkBytes {
                await onChunk(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { await onChunk(buffer) }
    }
}

#if canImport(AVFoundation) && os(iOS)
import AVFoundation

/// Microphone -> 16 kHz mono PCM16 for Deepgram, plus a streaming PCM player
/// for ElevenLabs. Shares the app's AVAudioSession; does not change category.
public final class VoiceAudioIO: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pcm16k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    public init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
    }

    public func startCapture(onAudio: @escaping @Sendable (Data) -> Void) throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: pcm16k)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let ratio = 16_000 / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: self.pcm16k, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
            onAudio(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
        }
        if !engine.isRunning { try engine.start() }
        player.play()
    }

    public func stopCapture() {
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Queue one PCM16 chunk from ElevenLabs for gapless playback.
    public func play(pcm16 chunk: Data) {
        let frames = chunk.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        chunk.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        if !engine.isRunning { try? engine.start(); player.play() }
        player.scheduleBuffer(buf, completionHandler: nil)
    }
}
#endif
EOF_AVAE

cat > 'EchoGuide/Core/Vision/LocalVisionEngine.swift' <<'EOF_AVAE'
// Owner: Maxwell. On-device inference for frames FrameDeltaEngine let through:
//   * YOLOv8n / YOLO11n INT8 Core ML (exported with nms=True) on the Neural Engine
//   * VNDetectHumanHandPoseRequest for the index fingertip (target alignment)
//   * VNRecognizeTextRequest, .fast level, offline (only on OCR frames)
//   * VNDetectBarcodesRequest for product codes and QR (same cadence as OCR)
//
// Budget: object + hand under ~12 ms on A17-class hardware. OCR is the
// expensive one (roughly 10-35 ms), so it runs on a cadence, not every frame.
// Every call is timed and the rolling p95 is exposed for the benchmark HUD.

import Foundation
import EchoGuideContracts

public struct LocalVisionConfig: Sendable {
    /// Below this, a YOLO detection is dropped entirely.
    public var minimumConfidence: Float = 0.35
    /// Run OCR on every Nth inferred frame (1 = always, 0 = never).
    public var ocrEveryNthFrame = 3
    public var detectFingertip = true
    /// Barcodes ride the OCR cadence: both are "read the label" work.
    public var detectBarcodes = true
    /// Keep at most this many detections; cognitive isolation picks one anyway.
    public var maxDetections = 12
    public var budgetMs: Double = 12

    public init() {}
}

#if canImport(CoreVideo)
/// Anything that turns a camera frame into detections. LocalVisionEngine in
/// the app, a fake in tests; PerceptionPipeline only knows this.
public protocol FrameInferring: Sendable {
    func infer(_ frame: CameraFrame) async -> VisionFrameResult
}
#endif

public enum VisionGeometry {
    /// Vision boxes are bottom-left origin; the pipeline is top-left (see Contracts).
    public static func topLeft(x: Double, y: Double, width: Double, height: Double) -> ImageRect {
        ImageRect(x: Float(x), y: Float(1 - y - height), width: Float(width), height: Float(height))
    }

    public static func topLeft(pointX: Double, pointY: Double) -> ImagePoint {
        ImagePoint(x: Float(pointX), y: Float(1 - pointY))
    }
}

#if canImport(Vision) && canImport(CoreML)
import CoreML
import CoreVideo
import Vision

public actor LocalVisionEngine {
    public let config: LocalVisionConfig
    private let objectRequest: VNCoreMLRequest?
    private var frameCount: UInt64 = 0
    public private(set) var latency = LatencyWindow()
    public private(set) var overBudgetFrames = 0

    /// `modelURL` points at a compiled `.mlmodelc` (YOLO exported with
    /// `format=coreml, int8=True, nms=True`). nil runs hands + OCR only, which
    /// is useful in development before the model is bundled.
    public init(modelURL: URL?, config: LocalVisionConfig = LocalVisionConfig()) throws {
        self.config = config
        if let modelURL {
            let mlConfig = MLModelConfiguration()
            mlConfig.computeUnits = .cpuAndNeuralEngine
            let model = try VNCoreMLModel(for: MLModel(contentsOf: modelURL, configuration: mlConfig))
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFill
            objectRequest = request
        } else {
            objectRequest = nil
        }
    }

    public var p95Ms: Double { latency.percentile(0.95) }

    public func process(_ frame: CameraFrame, orientation: CGImagePropertyOrientation = .right) -> VisionFrameResult {
        let timer = FrameTimer()
        frameCount += 1

        var requests: [VNRequest] = []
        if let objectRequest { requests.append(objectRequest) }

        let hand = VNDetectHumanHandPoseRequest()
        hand.maximumHandCount = 1
        if config.detectFingertip { requests.append(hand) }

        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        let runOCR = config.ocrEveryNthFrame > 0 && frameCount % UInt64(config.ocrEveryNthFrame) == 0
        if runOCR { requests.append(text) }

        let barcode = VNDetectBarcodesRequest()
        barcode.symbologies = [.ean13, .ean8, .upce, .code128, .qr]
        if runOCR && config.detectBarcodes { requests.append(barcode) }

        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: orientation)
        do {
            try handler.perform(requests)
        } catch {
            return VisionFrameResult(frameIndex: frame.index, timestamp: frame.timestamp, detections: [], inferenceMs: timer.elapsedMs)
        }

        var detections: [Detection] = []

        for case let obs as VNRecognizedObjectObservation in objectRequest?.results ?? [] {
            guard let top = obs.labels.first, top.confidence >= config.minimumConfidence else { continue }
            let b = obs.boundingBox
            detections.append(Detection(
                label: top.identifier,
                confidence: top.confidence,
                box: VisionGeometry.topLeft(x: b.minX, y: b.minY, width: b.width, height: b.height)
            ))
        }

        if runOCR {
            for obs in text.results ?? [] {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let b = obs.boundingBox
                detections.append(Detection(
                    label: "text",
                    confidence: candidate.confidence,
                    box: VisionGeometry.topLeft(x: b.minX, y: b.minY, width: b.width, height: b.height),
                    kind: .text,
                    text: candidate.string
                ))
            }
        }

        if runOCR && config.detectBarcodes {
            for obs in barcode.results ?? [] {
                guard let payload = obs.payloadStringValue else { continue }
                let b = obs.boundingBox
                detections.append(Detection(
                    label: "barcode",
                    confidence: obs.confidence,
                    box: VisionGeometry.topLeft(x: b.minX, y: b.minY, width: b.width, height: b.height),
                    kind: .barcode,
                    text: payload
                ))
            }
        }

        detections.sort { $0.confidence > $1.confidence }
        if detections.count > config.maxDetections { detections.removeLast(detections.count - config.maxDetections) }

        if config.detectFingertip, let obs = hand.results?.first,
           let tip = try? obs.recognizedPoint(.indexTip), tip.confidence > 0.3 {
            let p = VisionGeometry.topLeft(pointX: tip.location.x, pointY: tip.location.y)
            detections.append(Detection(
                label: "fingertip",
                confidence: tip.confidence,
                box: ImageRect(x: p.x - 0.01, y: p.y - 0.01, width: 0.02, height: 0.02),
                kind: .fingertip
            ))
        }

        let ms = timer.elapsedMs
        latency.record(ms)
        if ms > config.budgetMs { overBudgetFrames += 1 }
        return VisionFrameResult(frameIndex: frame.index, timestamp: frame.timestamp, detections: detections, inferenceMs: ms)
    }
}
extension LocalVisionEngine: FrameInferring {
    public func infer(_ frame: CameraFrame) async -> VisionFrameResult { process(frame) }
}
#endif
EOF_AVAE

cat > 'EchoGuide/UI/GuidanceView.swift' <<'EOF_AVAE'
// Owner: Bryan. The screen is secondary: audio and haptics carry the product.
// What is shown is for low-vision users and carers: one step, huge, yellow on
// black, Dynamic Type, and VoiceOver reads the same sentence the audio speaks.
// A carer gets one big Pause/Resume control and the current goal; nothing
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

    /// Carer control. Pausing silences haptics; resuming returns to scanning.
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
        case .outsideSafeArea(let region): return "You have left \(region)"
        }
    }

    /// Secondary line: what happens next, for a carer reading over a shoulder.
    var detail: String? {
        switch state {
        case .idle: return "Tap Resume to start guiding"
        case .scanning: return goal.map { "Looking for \"\($0)\"" } ?? "Point the camera at the task"
        case .guiding: return "Follow the pulses"
        case .onTarget: return "Hold still"
        case .completed: return "Next step coming"
        case .warning: return "Move your hand away"
        case .outsideSafeArea: return "Go back the way you came"
        }
    }

    var isWarning: Bool {
        switch state {
        case .warning, .outsideSafeArea: return true
        default: return false
        }
    }

    var isOnTarget: Bool {
        if case .onTarget = state { return true }
        return false
    }
}

public struct GuidanceView: View {
    @State private var model: GuidanceModel
    /// Set to show the goal field; carers type "start" or "microwave".
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
EOF_AVAE

cat > 'EchoGuideApp/Assets.xcassets/AppIcon.appiconset/Contents.json' <<'EOF_AVAE'
{
  "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF_AVAE

base64 --decode > 'EchoGuideApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png' <<'EOF_AVAE'
iVBORw0KGgoAAAANSUhEUgAABAAAAAQACAIAAADwf7zUAAAdGElEQVR42u3agZXlOBACwM4/QKdjZyGroeoRwY0F0t+bAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADjkffw3AACAu6/sNwcAAMi533shAACAW763AQAAuOt7FQAA4LovngQAALjuiycBAABu/OI9AACAG794DwAA4NIvHgMAALjxi/cAAIBLv4jHAACAS7+IswIA4N4vXgIAALj0i8cAAADu/eIlAACAS794DAAA4N4vXgIAALj3i5cAAIB7v4iXAACAe7+IlwAAgHu/iJcAAICrv4hnAACAe7+IlwAAgHu/iJcAAICrv4hnAACAe7+IlwAAgFudiGcAAODeLyJeAgCAq7+IeAYAAK7+Ip4BAADu/SJeAgAArv4ingEAAK7+Ip4BAACu/iKeAQAArv4ingEAgKu/iHgGAACu/iLiGQAAuPqLiGcAAODqLyKeAQCAq7+IeAYAAK7+IuIZAAC4+ouIZwAA4OovIp4BAICrv4h4BgCAq7+IiGcAALj6i4hnAADg9i8i3gAAgKu/iHgGAACu/iLiGQAAuPqLiGcAAOD2LyLeAACAq7+IeAYAAK7+IuIZAABu/yIi3gAA4OovIuIZAABu/yIi3gAA4OovIuIZAABu/yIi3gAA4OovIuIZAABu/yLiDQAAuPpL7h3LH0U8AwDA1Urcn3zDvmEAwLVJXJJ84b5wAMDdyGUIn73PHgDcgcS9x3EQxwEAXHfEFccBEQcEANxsxIXGqRGnBgDcY8T1xSEShwgAXFzEfcWZEmcKAFxTxAXFKROnDADcS1xHcOjEoQMAtxBXEJxBcQYBwM3DhQNHUhxJAHDVcMnA8RTHEwDXC3GxwFEVRxUA9wlxmcDJdXIBwB1C3B5wip1iAHBvEDcGnGgnGgBcFNwSwAF3wAHA5cDNAJx0Jx0A3AncBsCpd+oBwD3AJQAcf8cfAMy/4QdVoAoAsPdi70EtqAUAzLzYePSD6AcArLvYdXSF6AoALLo5B6UhSgMAQ27FQXuI9gDAfhtvUCNqBABsts0GlaJSAMBU22nQLboFACy0eQYlo2QAwDBbZdA22gYAeyzGGNSO2gHADIsNBv2jfwCwvqYXUESKCACja3EBjaSRALC1hhZQTaoJABNrYgEFpaAAMK6WFTSVaCoADKpBBa0lWgsAO2pEQX2pLwAwn+YTlJgSA8BwitUEbabNALCXxhJQa2oNADNpJgHlptwAMJDWEdByWg4Au2gXAV2n6wCwiOYQUHpKDwBDaAgB1af6ALCC9g9QgAoQAONn/AA1qAYBMHs2D9CH+hDA2lk7QCuKVgSwc0YOUI/qEQDzZt4AJakkATBshg1QlaoSAJNmzwCdqTMBsGSWDNCcmhMAG2bDAP2pPwGwXqYLUKSKFACjZbQAdapOAbBY5grQqBoVwFYZKgDVqloBTJSJAlCwChbAOBknADWrZgHMklkCULbKFsAgWSNA62pdAOyQHQJ0r+4FwAhZIED9ql8AzI/5AZSwEgbA8BgeQBWrYgBMjr0BdLJOBrA0lgZAM2tmABtjYwD0s34GMDDWBUBFq2gA02JaABS1ogYwKkYFQF2rawBzYk4AlLbSBrAlhgRAbwNgRUwIoMAVOADGw3gAalyNA2A2AJS5MgcwGAYDQKWrdABrYSoAtLpWB7ATdgJAt+t2AAthIQA0vIYHMA+2AUDJK3kAw2AYAFS9qgcwCSYBQOErfABjYAwA1L7aB7AEZgBA82t+ABsAgP4H0P7aH8AKWAEA1a/3AQyBIQBQ+nofwBbYAgCNr/EBLIJFAFD3uh7AKBgFAEWv6AFMg2kAUPEqHsBAGAgA/a7cAWyEjQDQ7JodwFJYCgCdDoC9sBcAFYUOgMkwGQB+zgHAalgNQI/rcQBsB4AS1+AAmA8A9a2+AYyIEQFQ3IobwJSYEgCtrbIBrIk1AdDXKhvAoBgUAGWtrAHMilkB0NRqGsCyWBYAHa2jAeyLfQFoKmgATIyJAfDzDABWxsoAelkvA2BrbA2glDUyAObG3ADqWB0DYHSMDqCLdTEARgdAEStiAEwPgBZWwQDWx/oA6F/9C2CDbBCA5lW+AGbIDAFoXrULYIksEYDOBcAe2SOAyMIFwCSZJAA/twBglawSoGr1LACGyTABSlbJAmCezBOgYTUsAObJPAHqVb0CYKSMFKBbFSsAdspOAVpVsQJgqgC0qkoFwFoB6FN9CmCzbBaAMlWmADbLZgFoUgAsl+UCSK1RAIyX8QLwIwoA9st+AfgFBQATZsIA1ak6ATBkhgzQm3oTAENmyAClqTQBMGfmDNCYGhMAc2bOAHWpLgEwakYN0JWKEgC7ZtcALakoATBtAFpSRQJg3QD8RgKAgTNwAH4gAcDG2ThAMypHAMycmQM0o1oEwNJZOkAn6kQA7J29AxSiQgTA3tk7QCFqQwBMnskDVKE2BMDqWT1AFepBAAyf4QOUoB4EwPbZPsCvIABg/gD8BAIAFhDA7x8AGEEjCOg+3QeAETSCgOJTfACYQlMIaD2tB4ApNIWAylN5ABhEgwjoO30HgEE0iIC+U3YA2ESbCGg6ZQeAWTSLgKZTcwBYRssI+J0DAIyjcQT8yAEA9hFAwQGAfQS0m3YDwEpaSUC1qTYArKSVBFSbXgPAUBpKQKnpNQBspa0ElJpGA8BcmktAnWk0ACymxQTUmToDwGJaTECdAYDRNJqAHzMAwG7aTcAvGQBgOgEtpsUAwHQCKkyFAYABBfSX/gLAgBpQQH/pLwAMqAEFlJfyAsCMmlFAc2kuAMyoGQU0l9qCYw0AWFJAZ6ktcLSdODCmgM7SWeAgO4NgTAGdpbDAyXUqcSrtKaCtFBZUH1hwQh1YQFupKqi7VTitOK3OKaCqVBVU3PsdWxxbxxNQVaoKGu/9zi/Or1MJ6Ck9BY33fmcZZ9l5BJSUksJJFF8BTrSTCCgpJYUz6BkAzrUzCGgoDYUD6BkADrgDCKgncPQ8A8Axd/QA9QQOnWcAOOwOHbC9nsBx8wwAp95xA/w4Ac6aZwA4+84aoJjAKfMMAA3glAFaCRwxPQB6wBEDlaSVwNVfG4A28NcDlaSSwO1fIYC1BVSSPgJXf80ABhfQR/oIZ0qUAxhcQBnpIxwoURGoCAcKUEaaCKdJFAWKwmkCNJEmwlESXYGucJQATQTOkagL1IVzBJTcWsAhEqWB0nCIAL9DgBMkqgPV4QQBOggcH9EeaA/HB9BB4PbvDQAKxNkBHaSAwO3fGwDUiIMD2kcBgdu/NwCYYED7aB+cGlEmYIIB7aN9cGREn4AJBrSP6sF5Ea0CVhjQO6oH50UUC4rFeQH0jt7BYRHdgm5xWAC9A06KqBfUi5MCNPQOOCaiZFAyjgmgdMAZET2DnnFGgMSbDTgmomfQM44JoHHAGRFVg6pxRoC4xgEHRBQOCscBAdQNOB2ic9A5TgegbsDtX9QOasfRAMb/cQgeAKJ2UDtOB+gaRQMuu6J8UD6OBigaRYNzIeJ8oH+cC1A0igbnQjwAwC4DikbR4FCINwDYZUDRKBqcCPEGALsMaBktg0MhigisM6BiVAxOhOgidJETAagYcBxEHaGOHAdAxYAHgKgj1JHjAKgYcPsXjYRGchaArRUDzoIoJZSSswD4gQHc/kUvoZecBUC5gAeA6CX0krMAKBdw+xfVhGpyEEC5KBccBBHVhGpyEEC5KBecAhHthHZyCkC5aBacAhEFhYJyCkCzaBYcAfEGADMNqBXNglMgHgBgqQG1olZwBMQbACw1oFbUCo6AqCnUlCMAqBW1gtu/aCo0le8f6KkV8AAQZYWy8v0DOgXc/kVfoa98/IBOAQ8A0VfoKx8/oFPA3VT0FfrKxw86RafgyxdRWagsXz4oFJ2Cj19EZaGyfPygUBQKPn4RlYXK8vGDQlEo+PJFtBZay98NFIo2wZcvHgBgsgFtok3w5YsHAJhsQJtoE3z24g0AJhvQJtoEDwDxAEB3+ewBbQIeAKK70F0+e0CbgNu/qC/Ul28e0Cb45kXUF+rLNw/aRJvgmxdRX6gv3zyoEm2Cz15EfaG+fPagSlQJvnkRDYYG882DKtEj+OZFlBhKzDcPekSP4JsXUWIYbkCP6BF88+IBAIYb0CN6BN+8eACA4Qb0iB7B7V+8AdBjPnhAj4AHgOgx9JgPHtAj4AEgegw95oMH9Ag+eBE9hh7zwYMe0SP44EX0GHrMBw96RI/ggxfRY+gxHzzoET2Cr11ElaHKfO2gR/QIvnYRVYYq87WDHtEj+NpFVBmGG9AjegRfu3gAgOEG9IgewdcuHgBguAE9okfwABAPAPC1A3oEPABElaHKfO2AHgEPAFFlqDJfO6BH8LWLqDJUma8d9IgewdcuospQZb520CN6BF+7iCpDlfnaQY/oEXztIqoMVeZrBz2iR/C1i6gyVJmvHfSIHsHXLqLKMNyAEtEj+NpFwHYDekSJ4GsXt38w3IAe0SN4AIgHABhuQI+AB4B4AKDKfO2AHgEPAFFlqDJfO6BH8LW7dIoqQ5X52gE9gq9dRJWhynztoEf0CL52EVWGKvO1gx7RI/jaRVQZqszXDnpEj+BrF1FlqDJfO+gRPYKvXUSVocr80UCP6BF87SKqDMMN6BE9gq9dPADAcAN6RI/gASAeAGC4AT0CHgDiAYAq87UDegS8AUSPocd88IAeAQ8A0WPoMR88oEfwwYvoMfSYDx70iB7BBy+ix9BjPnjQI3oEH7yIHkOP+eBBj+gRfPAiegw95oMHPaJH8M2LKDGUmG8e9IgewTcv4hRiuAE9okfwzYsHABhuQI/oEXzz4gEAhhvQI6oEDwDxAECD+eYBVQLeAKK+UF8+eyC1TcADQNyEUF++eUCbgAeAqC/Ul28e0CbgASDqC/Xlmwe0CT57Ed2F7vLZgzbRJvjsRXQXustnD9pEm+CzF9Fd6C6fPWgTbYIvX0Rxobh8+aBNtAm+fBHFheLy5YM2USj48sUDAOw1oFAUCj5+cfsHew0oFIWCj188AMBeAzpFoeABICoLleXLB3QKeAOIvkJf+fgBnQIeAKKv0Fc+fkCngAeA6Cv0lY8fdIpOwfcvoqxQVr5/0ClqBd+/iKZCU/n+Qa2oFRwBETWFmnIEQK2oFRwBETWFmnIEQK2oFZwCcfsHSw1oFrWCIyAeAGCmAc2iWXAKxO0fzDSgWZQLToFoJ7STUwAoF/AGENWEanIQAOUCHgCimlBNDgKgXMAbQPQSeslZAJQLeACIXkIvOQugX5QLzoKIUkIpOQugX1QMzoKIRkIjOQugYlQMjoO4/YM6chxAxagYHAfxAADrDKgYFYMTIW7/YJ0BFaNicChEEYF1BrSMlsGJEC2EFnIiAEWjaHAoRAWhghwKQNGAcyH6B/3jXACKBjwARP+gf5wLQNGAN4AoH5SPowGKRteAN4CoHdSO0wHqRtfgaIioHdSOowHqRt3gdIjbP+gcpwPUjbrBARG3f7DIgLrRODgjomrAHAMaR+PgmIieAXMMKB2NgzMiegY944wASkfp4JiIkkHJOCZA+80GnBRRL6gXJwXQO+CwiG5BtzgsgN4BbwBRLCgW5wVYXT3gvIhWQas4L4DfHsCREX2CPnFkAO0DTo0oE5SJUwNoH/AGENAkDg4oIO0D3gBu/6BGHBxQQDoIvAHc/kGBODugg3QQjo9oDzC+gA7SQThBojrA+AI6SA3hEInSAMsLaCI1hHMk6gJ14RwBmkgT4SiJrkBXOEqAJtJEOE2iKFAUThPQfGUBB0pUBCrCgQL8GgHOlKs/KAdnCtBH4Fi5/YNmcKyA8S+S4HC5+oNCcLhAJakkcL60AWgD5wu0kkoCzwA9AKYW0EqKCbwBNADYWUAxKSbwDHD2wc4Cukkx4biJU49T77gBukk94dCJw47D7tAB6kk94eiJY45j7ugB6kk94QC6+oMD7gACGgqcQVd/cK6dQUBJgZPoRIMT7SQCSgqcR2cZnGXnEfSUngKn0vkFqwqoKlUFjqdjC1YVUFWqCpxTpxWsKqCqtBU4sE4oTqhJBRSWtoK2kwtOpT0FFJbOguSDDBhTQGfpLIg92oAxBdSWzoL1DQBYUkBtaS4AMKOA5tJcAGBGAeWlvAAwoAYU0F/6CwADakAB/aW/ADCgBhRQYSoMANNpOgEtpsUAMJ2mE9BiigwAu2k3Ab9kAIDRNJqAHzMAwGJaTECdAYDFBDSaOgMAcwloNKUGALYS0GtKDQBDaSgBvabaALCSVhJQbaoNACtpJQHtpt0AsI/2EVBwCg4A+2gfAQWn4wAwjsYRUHM6DgDLaBkBv3MAgFk0i4CfOgDAJgL4tQMADCKg7/QdAAbRIAIqT+UBYApNIaD1tB4AptAUAopP8QFgBI0goPt0HwBG0AgCuk/9AWABLSCgAdUfAObP/AEaUAkCYPtsH6AHlSAAhg/ADyEAYPUA/BYCACYPwM8hANg7ewcoRIUIgL2zd4BO1IkAWDpLB6hFzQiAmTNzgHLUjADYOBsHKEf9CICBM3CAitSPAFg36waoSC0JgGkzbYCi1JIA2DUARakrATBqAOoSAHNmzgA0JgDmzJwBKE0ADJkhA/Sm3gTAkBkyQHWqTgBMmAkDtKcCBcB+2S9AhypQAIyX8QJ0qBoFwHJZLkCTalIAbBaAMlWmANgsAH2qTwGwVgAqVasCmCpTBaBYtSqAnbJTAH5ZAcBIGSkA9QqAeTJPgIbVsACYJ/MEKFklC4BhMkyAnlW1AFglqwRoW1ULgEkySYC2VbgA2CMAnatzAbBEAGpX8wKYITMEoHw1L4ANskEA+lf/Algf6wOggrUwgOkxPQCKGACjY3QAdDEARsfoAOpYHQNgbswNoJGVMgC2xtYAelkvA2BlALSzagbAxABoZwUNYF/sC4CO1tEAlsWyAKhpTQ1gVswKgLJW1gAGxaAAqGx9DWBNrAmAytbaAKbElAAobn9eACNiRADUNwDmw3wAGlyJA2A7bAegx/U4AFYDQJurcgCTYTIAtLlCB7AX9gJAp+t0AEthKQA0u2YHsBE2AkC563cAA2EgAFS8igcwDaYBQNEregCjYBQAdL26B7AIFgFA42t8AFtgCwCKex8AQwCAH34AsAIA2l/7A+h//Q9gA2wAgObX/ABmwBIAqH21D2AMjAGAwlf4ACbBJACoelUPYBgMA4CSV/IAtsE8AGh4DQ9gISwEgG7X7QB2wk4AaHWtDmAqrAWg0lU6AAbDYADKXJkDYDYA1LgaBzAexgNAgStwABNiRQD0tt4GMCS2BEBpK20Ac2JOANS1ugYwKkYFQFEragDTYloAVLSKBrAuBgZAP+tnABtjYwDNrJkBsDSWBtDJOhkAe2NyAFWsigEwPIYHUMJKGADzY34A9at+AahfICME6F7dC2CH7BCA1tW6ANbIIAEoW2ULYJbMEoCaVbMAxsk4AShYBQtgokwUoFpVKwCGylYBGlWjAmCuLBagTtUpAEbLaAGKVJECYLqsF6A/9ScANsyGAZpTcwJgySwZoDN1JgD2zKQBqlJVAmDMDBugJJUkgHkzbwDqUT0CGDk7B2hFrQiAtbN2gD7UhwDYPLMHqEE1CIDxM36AAlSAANg/KwioPtUHgCE0hIDSU3oAmEOLCOg6XQeAXbSLgJbTcgBYRwMJKDflBoCZNJOg1kStAWAs7SVoM20GgNUUwwlKTIkBYD7FfIL6Ul8AGFE7CmgtrQWAQTWogKbSVABYVuMKKCgFBYCJNbGAalJNABhaWwtoJI0EgMU1uqCIRBEBYHqtL+gf0T8A2GAzDGpH7QCAMbbHoG20DQBYZcMMSkbJAIB5ttCgW3QLAHZaTDWoFJUCgM0Wmw1qRI0AYLzFfoP20B4AWHEx5CgNURoAmHOLDrpCdAUAdt26g34Q/QCAjTfzoBbUAgDYe3sPqkAVAIDhN//g+Dv+AOAS4B4ATr1TDwBuA+4E4KQ76QDgZuByAA64Aw4AbgkuCjjR4kQDgBuDewNOsTjFALg9iDsETq44uQC4TIj7BI6qowoALhbieoHj6XgCgEuGuGrgSDqSAODCIW4eOIPOIAC4gohbCD5yhw4AXEfEvcQpE6cMAFxQxDXFmRJnCgDcV8Sn6hCJQwQAri/uMTg14tQAgAuNmw0OiDggAOCK47qD4+A4AADuPe5A+Ox99gDgMiTuRr5w8YUDgEuSuDb5hsU3DADeAOJq5RMVnygAeAaIiLj6A4A3gIiI2z8AeAaIiLj6A4A3gIiI2z8AeAaIiKs/AOANICJu/wCAZ4CIuPoDAN4AIuL2DwB4BoiIqz8A4BkgIq7+AIA3gIi4/QOAZ4Dri4i4+gOAZ4CIiKs/AHgGiIirPwDgDSAibv8AgGeAiLj6AwCeASLi6g8AeAaIiKs/AOAZICKu/gCAZ4CIuPoDAJ4BIuLqDwB4BoiIqz8A4Bkg4uoPAOAZIOLqDwDgGSDi6g8A4Bkg4uoPAHgGuGyJuPoDAJ4BIuLqDwB4BoiIqz8A4BkgIq7+AICXgIi49wMAngEirv4AAJ4BIq7+AABeAiLu/QAAngEirv4AAF4CIu79AACeASKu/gAAXgIi7v0AAF4CIu79AACeASKu/gAAXgLi3g8AgJeAuPcDAOAlIO79AABeAiLu/QAAXgIi7v0AAB4DIi79AABeAiLu/QAAHgMiLv0AAF4C4t4PAIDHgLj0AwDgMSAu/QAAeA+IGz8AAB4D4tIPAID3gLjxAwDgPSBu/AAAeBK47gMAgCeB6z4AAHgVuOsDAIC3gVs+AAB4IbjfAwDA9ucEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwJ8+rAdL1A9B6loAAAAASUVORK5CYII=
EOF_AVAE

cat > 'EchoGuideApp/Assets.xcassets/Contents.json' <<'EOF_AVAE'
{ "info" : { "author" : "xcode", "version" : 1 } }
EOF_AVAE

cat > 'EchoGuideApp/EchoGuideApp.xcodeproj/project.pbxproj' <<'EOF_AVAE'
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 60;
	objects = {

/* Begin PBXBuildFile section */
		0459EACAAA5564535521EB1A /* EchoGuideApp.swift in Sources */ = {isa = PBXBuildFile; fileRef = 47616655E11BEC9506AFC0AF /* EchoGuideApp.swift */; };
		353C0228E90A352BE56AD794 /* AppRuntime.swift in Sources */ = {isa = PBXBuildFile; fileRef = EF490F8AE51962283E50B561 /* AppRuntime.swift */; };
		3583E46383EC623FB6C309F3 /* AppConfig.swift in Sources */ = {isa = PBXBuildFile; fileRef = E7317046C94C5A60F7F5DD7D /* AppConfig.swift */; };
		919657EDF72BAF9CFFFCE51A /* BenchmarkReport.swift in Sources */ = {isa = PBXBuildFile; fileRef = 31876A8878587ADCBBF59F43 /* BenchmarkReport.swift */; };
		262673F27DBD85E2AEF9A09A /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = BBE03F3784F40D95E23D8465 /* Assets.xcassets */; };
		0EB3440FE35D7D55FB80BBA6 /* echoguide.sample.json in Resources */ = {isa = PBXBuildFile; fileRef = 51C0FCA7140C933DC84EB2E5 /* echoguide.sample.json */; };
		64329A7C11B75311EA1E5D86 /* Models in Resources */ = {isa = PBXBuildFile; fileRef = 4BBB164D9E56DFB73145D0D2 /* Models */; };
		897E45C50F8B0A538BECDBE0 /* EchoGuide in Frameworks */ = {isa = PBXBuildFile; productRef = 2BAFBE90D711F96380E9193E /* EchoGuide */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		7F6D01D6546BCD07518D8398 /* EchoGuideApp.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = EchoGuideApp.app; sourceTree = BUILT_PRODUCTS_DIR; };
		47616655E11BEC9506AFC0AF /* EchoGuideApp.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = EchoGuideApp.swift; sourceTree = "<group>"; };
		EF490F8AE51962283E50B561 /* AppRuntime.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppRuntime.swift; sourceTree = "<group>"; };
		E7317046C94C5A60F7F5DD7D /* AppConfig.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppConfig.swift; sourceTree = "<group>"; };
		31876A8878587ADCBBF59F43 /* BenchmarkReport.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BenchmarkReport.swift; sourceTree = "<group>"; };
		BBE03F3784F40D95E23D8465 /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; name = Assets.xcassets; path = Assets.xcassets; sourceTree = "<group>"; };
		51C0FCA7140C933DC84EB2E5 /* echoguide.sample.json */ = {isa = PBXFileReference; lastKnownFileType = text.json; name = echoguide.sample.json; path = Resources/echoguide.sample.json; sourceTree = "<group>"; };
		4BBB164D9E56DFB73145D0D2 /* Models */ = {isa = PBXFileReference; lastKnownFileType = folder; name = Models; path = Resources/Models; sourceTree = "<group>"; };
		A15033AD4B7792BAAA520C3A /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		3806DEFC96CD30D22C0E71FE /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				897E45C50F8B0A538BECDBE0 /* EchoGuide in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		2B731CEFC6751AAE0EC69B98 = {
			isa = PBXGroup;
			children = (
				D8DBA3F9900DD17689CA0C4D /* Sources */,
				307A90002D1285ED8C05A9E0 /* Resources */,
				A15033AD4B7792BAAA520C3A /* Info.plist */,
				A8CBE22D73EBCC4E5F27B59C /* Products */,
			);
			sourceTree = "<group>";
		};
		D8DBA3F9900DD17689CA0C4D /* Sources */ = {
			isa = PBXGroup;
			children = (
				47616655E11BEC9506AFC0AF /* EchoGuideApp.swift */,
				EF490F8AE51962283E50B561 /* AppRuntime.swift */,
				E7317046C94C5A60F7F5DD7D /* AppConfig.swift */,
				31876A8878587ADCBBF59F43 /* BenchmarkReport.swift */,
			);
			path = Sources;
			sourceTree = "<group>";
		};
		307A90002D1285ED8C05A9E0 /* Resources */ = {
			isa = PBXGroup;
			children = (
				BBE03F3784F40D95E23D8465 /* Assets.xcassets */,
				51C0FCA7140C933DC84EB2E5 /* echoguide.sample.json */,
				4BBB164D9E56DFB73145D0D2 /* Models */,
			);
			name = Resources;
			sourceTree = "<group>";
		};
		A8CBE22D73EBCC4E5F27B59C /* Products */ = {
			isa = PBXGroup;
			children = (
				7F6D01D6546BCD07518D8398 /* EchoGuideApp.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		42AEFBAE01D2DFD981F7DA7D /* EchoGuideApp */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 94E92F4374F7B1A84E405A21 /* Build configuration list for PBXNativeTarget "EchoGuideApp" */;
			buildPhases = (
				DBAEDAAE674BE07D23447E75 /* Sources */,
				3806DEFC96CD30D22C0E71FE /* Frameworks */,
				B098093DFB498EF325D85EDF /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = EchoGuideApp;
			packageProductDependencies = (
				2BAFBE90D711F96380E9193E /* EchoGuide */,
			);
			productName = EchoGuideApp;
			productReference = 7F6D01D6546BCD07518D8398 /* EchoGuideApp.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		46F86FAA6BBF9AC94A7E4595 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
			};
			buildConfigurationList = 82BEFE99DEE50030C2229134 /* Build configuration list for PBXProject "EchoGuideApp" */;
			compatibilityVersion = "Xcode 15.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = 2B731CEFC6751AAE0EC69B98;
			packageReferences = (
				715E1E3F015A64BA0327CAEF /* XCLocalSwiftPackageReference ".." */,
			);
			productRefGroup = A8CBE22D73EBCC4E5F27B59C /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				42AEFBAE01D2DFD981F7DA7D /* EchoGuideApp */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		B098093DFB498EF325D85EDF /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				262673F27DBD85E2AEF9A09A /* Assets.xcassets in Resources */,
				0EB3440FE35D7D55FB80BBA6 /* echoguide.sample.json in Resources */,
				64329A7C11B75311EA1E5D86 /* Models in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		DBAEDAAE674BE07D23447E75 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				0459EACAAA5564535521EB1A /* EchoGuideApp.swift in Sources */,
				353C0228E90A352BE56AD794 /* AppRuntime.swift in Sources */,
				3583E46383EC623FB6C309F3 /* AppConfig.swift in Sources */,
				919657EDF72BAF9CFFFCE51A /* BenchmarkReport.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		4257995D5FEB097455192277 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				SDKROOT = iphoneos;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug;
		};
		CE7A3CB3B7BB14CB7E72BBF7 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				SDKROOT = iphoneos;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				SWIFT_COMPILATION_MODE = wholemodule;
				VALIDATE_PRODUCT = YES;
			};
			name = Release;
		};
		A3F61B41957AEA1EFA63EB05 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				EG_PROXY_BASE_URL = "";
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = Info.plist;
				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = app.echoguide.EchoGuide;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 1;
			};
			name = Debug;
		};
		FF8312F936D3A28646D453F8 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				EG_PROXY_BASE_URL = "";
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = Info.plist;
				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = app.echoguide.EchoGuide;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 1;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		82BEFE99DEE50030C2229134 /* Build configuration list for PBXProject "EchoGuideApp" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				4257995D5FEB097455192277 /* Debug */,
				CE7A3CB3B7BB14CB7E72BBF7 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		94E92F4374F7B1A84E405A21 /* Build configuration list for PBXNativeTarget "EchoGuideApp" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A3F61B41957AEA1EFA63EB05 /* Debug */,
				FF8312F936D3A28646D453F8 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		715E1E3F015A64BA0327CAEF /* XCLocalSwiftPackageReference ".." */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = ..;
		};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		2BAFBE90D711F96380E9193E /* EchoGuide */ = {
			isa = XCSwiftPackageProductDependency;
			productName = EchoGuide;
		};
/* End XCSwiftPackageProductDependency section */
	};
	rootObject = 46F86FAA6BBF9AC94A7E4595 /* Project object */;
}
EOF_AVAE

cat > 'EchoGuideApp/EchoGuideApp.xcodeproj/xcshareddata/xcschemes/EchoGuideApp.xcscheme' <<'EOF_AVAE'
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "42AEFBAE01D2DFD981F7DA7D" BuildableName = "EchoGuideApp.app" BlueprintName = "EchoGuideApp" ReferencedContainer = "container:EchoGuideApp.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "42AEFBAE01D2DFD981F7DA7D" BuildableName = "EchoGuideApp.app" BlueprintName = "EchoGuideApp" ReferencedContainer = "container:EchoGuideApp.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
      <CommandLineArguments>
         <CommandLineArgument argument = "-benchmark" isEnabled = "NO">
         </CommandLineArgument>
      </CommandLineArguments>
   </LaunchAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
EOF_AVAE

cat > 'EchoGuideApp/Info.plist' <<'EOF_AVAE'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>EchoGuide</string>
	<key>EGProxyBaseURL</key>
	<string>$(EG_PROXY_BASE_URL)</string>
	<key>NSCameraUsageDescription</key>
	<string>EchoGuide watches through the camera to find the one thing you need and guide your hand to it.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>If you turn on voice, EchoGuide listens for requests like "find the start button".</string>
	<key>NSLocationWhenInUseUsageDescription</key>
	<string>EchoGuide uses your location to tell your carer if you leave a safe area.</string>
	<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
	<string>EchoGuide uses your location, even when the screen is off, to tell your carer if you leave a safe area.</string>
	<key>UIBackgroundModes</key>
	<array>
		<string>location</string>
	</array>
	<key>UIRequiredDeviceCapabilities</key>
	<array>
		<string>arm64</string>
		<string>still-camera</string>
	</array>
	<key>UILaunchScreen</key>
	<dict>
		<key>UIColorName</key>
		<string></string>
	</dict>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
	</array>
	<key>UIFileSharingEnabled</key>
	<true/>
	<key>LSSupportsOpeningDocumentsInPlace</key>
	<true/>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
</dict>
</plist>
EOF_AVAE

cat > 'EchoGuideApp/Resources/Models/README.txt' <<'EOF_AVAE'
Put the exported model here as yolo11n.mlpackage (or yolov8n.mlpackage).
It is copied into the app as-is and compiled on first launch.
Get it from the "export-model" GitHub Actions workflow (Actions tab > export-model > Run).
Models are git-ignored. Check the Ultralytics AGPL-3.0 license before shipping (see README).
EOF_AVAE

cat > 'EchoGuideApp/Resources/echoguide.sample.json' <<'EOF_AVAE'
{
  "goal": null,
  "plugins": { "productLookup": true },
  "safeAreas": []
}
EOF_AVAE

cat > 'EchoGuideApp/Sources/AppConfig.swift' <<'EOF_AVAE'
// Owner: Maxwell. Everything the app reads at launch: the per-home config
// file, secrets from the Keychain, and the vision model.

import CoreML
import Foundation
import Security
import EchoGuideInfra
import EchoGuideVision

/// Per-home setup. Lives at Application Support/echoguide.json (written by the
/// care provider's setup flow); the bundled sample is the fallback.
struct AppConfig: Decodable {
    var plugins: PluginManifest?
    var safeAreas: [SafeArea]?
    /// Start narrowed to one task ("start"), nil for open scanning.
    var goal: String?

    static func load() -> AppConfig {
        let candidates = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("echoguide.json"),
            Bundle.main.url(forResource: "echoguide.sample", withExtension: "json"),
        ].compactMap { $0 }
        for url in candidates {
            if let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
                return config
            }
        }
        return AppConfig()
    }
}

enum AppSettings {
    /// Proxy base URL from Info.plist (`EGProxyBaseURL`). Empty = no cloud at all.
    static var proxyBase: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "EGProxyBaseURL") as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    static var imageConsent: Bool { UserDefaults.standard.bool(forKey: "cloudImageConsent") }
    static var voiceEnabled: Bool { UserDefaults.standard.bool(forKey: "voiceEnabled") }
    static var elevenLabsVoiceID: String? { UserDefaults.standard.string(forKey: "elevenLabsVoiceID") }
    static var isBenchmark: Bool { ProcessInfo.processInfo.arguments.contains("-benchmark") }
}

/// Generic-password Keychain items, service "EchoGuide". The setup flow writes
/// `device_token` (proxy auth) and any secret a manifest names.
enum Keychain {
    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "EchoGuide",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, for account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "EchoGuide",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Finds the YOLO model. Ships as `Resources/Models/<name>.mlpackage` (copied
/// as a folder, not compiled by Xcode), compiled on first launch and cached.
enum ModelStore {
    static let names = ["yolo11n", "yolov8n"]

    static func locate() -> URL? {
        let fm = FileManager.default
        guard let cacheDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Models") else { return nil }
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        for name in names {
            let cached = cacheDir.appendingPathComponent("\(name).mlmodelc")
            if fm.fileExists(atPath: cached.path) { return cached }
            if let compiled = Bundle.main.url(forResource: name, withExtension: "mlmodelc") { return compiled }

            let models = Bundle.main.resourceURL?.appendingPathComponent("Models")
            guard let package = models?.appendingPathComponent("\(name).mlpackage"), fm.fileExists(atPath: package.path),
                  let temp = try? MLModel.compileModel(at: package) else { continue }
            try? fm.removeItem(at: cached)
            if (try? fm.moveItem(at: temp, to: cached)) != nil { return cached }
            return temp
        }
        return nil
    }
}
EOF_AVAE

cat > 'EchoGuideApp/Sources/AppRuntime.swift' <<'EOF_AVAE'
// Owner: Maxwell. Composition root: the only place every engine is built and
// wired together. Engines never see each other; they meet here through the
// protocols in EchoGuideContracts.
//
//   LiDAR (ARKit) or CameraFeed -> PerceptionPipeline -> SpatialFence -> AutomationEngine
//                                                                          |-> haptics, audio
//                                                                          |-> plugins, router
//   LocationFenceMonitor ---------------------------------------------------^
//   VoiceLoop (optional) -> goal / question

import Foundation
import Observation
import os
import EchoGuideAutomation
import EchoGuideContracts
import EchoGuideInfra
import EchoGuideSpatial
import EchoGuideVision

private let log = Logger(subsystem: "app.echoguide", category: "runtime")

@MainActor
@Observable
final class AppRuntime {
    let guidance = GuidanceModel()
    private(set) var status = "Starting"
    private(set) var benchmarkSummary: String?

    private var automation: AutomationEngine?
    private var pipeline: PerceptionPipeline?
    private var vision: LocalVisionEngine?
    private var lidar: LiDARDepthEngine?
    private var camera: CameraFeed?
    private var location: LocationFenceMonitor?
    private var voiceIO: VoiceAudioIO?
    private var stt: DeepgramSTTClient?
    private var background: [Task<Void, Never>] = []
    private let lastDetections = DetectionBox()

    func start() async {
        guard automation == nil else { return }
        let config = AppConfig.load()

        // Perception (local, always).
        let modelURL = ModelStore.locate()
        if modelURL == nil { log.warning("No YOLO model bundled; running hands, text and barcodes only") }
        let vision: LocalVisionEngine
        do {
            vision = try LocalVisionEngine(modelURL: modelURL)
        } catch {
            log.error("Model failed to load: \(error.localizedDescription, privacy: .public)")
            vision = try! LocalVisionEngine(modelURL: nil)
        }
        self.vision = vision
        let lidar = LiDARDepthEngine.isSupported ? LiDARDepthEngine() : nil
        self.lidar = lidar

        // Output.
        let haptics = SpatialHapticEngine()
        let audio = SpatialAudioEngine()

        // Cloud (optional) and tools.
        let connectivity = PathConnectivity()
        let deviceToken: @Sendable () async -> String? = { Keychain.read("device_token") }
        var routerConfig = CloudRouterConfig()
        routerConfig.imageConsent = AppSettings.imageConsent
        let provider: ReasoningProvider? = AppSettings.proxyBase.map { GeminiProvider(proxyBase: $0, deviceToken: deviceToken) }
        let router = CloudReasoningRouter(config: routerConfig, provider: provider, connectivity: connectivity)

        let registry = PluginRegistry()
        var caregiver: CaregiverAlerts?
        if let manifest = config.plugins {
            let outbox = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("caregiver-outbox.json")
            let installed = await registry.install(manifest, secrets: { Keychain.read($0) }, outboxURL: outbox)
            caregiver = installed.caregiver
            for url in installed.failedRemotes { log.warning("Plugin server unreachable: \(url.absoluteString, privacy: .public)") }
        }

        // Decisions.
        let automation = AutomationEngine(haptics: haptics, audio: audio, depth: lidar, router: router, tools: registry)
        self.automation = automation
        guidance.bind(to: automation)
        await automation.setGoal(config.goal)
        await automation.start()

        // Pipeline: frame -> detections -> fence -> automation.
        let fence = SpatialFence.kitchenDefaults
        let detections = lastDetections
        let pipeline = PerceptionPipeline(vision: vision) { result, _ in
            await detections.set(result.targets)
            // Depth is sampled per zone, so two hazards at different distances are judged separately.
            let event = await fence.evaluate(result, depth: lidar)
            await automation.ingest(result, fence: event)
        }
        self.pipeline = pipeline

        // Camera: ARKit owns it when LiDAR is present, otherwise AVCapture.
        if let lidar {
            lidar.onFrame = { pipeline.submit($0) }
            lidar.start()
            status = "Running with LiDAR"
        } else {
            let camera = CameraFeed()
            do {
                try camera.start { pipeline.submit($0) }
                self.camera = camera
                status = "Running"
            } catch {
                status = "Camera unavailable"
            }
        }

        // Location fence (dementia wandering).
        if let areas = config.safeAreas, !areas.isEmpty {
            let monitor = LocationFenceMonitor(areas: areas) { event in
                Task { await automation.ingest(fence: event, at: Date().timeIntervalSince1970) }
            }
            monitor.start()
            location = monitor
        }

        // Deliver caregiver alerts queued while offline.
        if let caregiver {
            background.append(Task {
                while !Task.isCancelled {
                    if await connectivity.isOnline() { await caregiver.flush() }
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
            })
        }

        if AppSettings.voiceEnabled, let proxy = AppSettings.proxyBase {
            await startVoice(proxy: proxy, audio: audio, automation: automation, router: router, deviceToken: deviceToken)
        }

        if AppSettings.isBenchmark { runBenchmark() }
    }

    func stop() async {
        background.forEach { $0.cancel() }
        lidar?.stop()
        camera?.stop()
        location?.stop()
        voiceIO?.stopCapture()
        await stt?.stop()
        await automation?.stop()
    }

    // MARK: - Voice

    private func startVoice(proxy: URL, audio: SpatialAudioEngine, automation: AutomationEngine,
                            router: CloudReasoningRouter, deviceToken: @escaping @Sendable () async -> String?) async {
        // SpatialAudioEngine sets a playback-only session on its first sound;
        // make it do that now, then widen the session so the microphone can record.
        await audio.ping(azimuth: 0, elevation: 0)
        do {
            try AudioSessionSetup.enableRecording()
            let stt = DeepgramSTTClient(proxyBase: proxy, deviceToken: deviceToken)
            let transcripts = try await stt.start()
            let io = VoiceAudioIO()
            try io.startCapture { pcm in Task { try? await stt.send(pcm) } }
            self.stt = stt
            voiceIO = io
            let detections = lastDetections
            background.append(Task {
                do {
                    for try await t in transcripts where t.endOfUtterance {
                        switch VoiceIntent.parse(t.text) {
                        case .find(let target):
                            await automation.setGoal(target)
                            await audio.speak("Looking for \(target).", azimuth: 0)
                        case .stop:
                            await automation.setGoal(nil)
                            await audio.speak("Okay.", azimuth: 0)
                        case .question(let q):
                            let seen = await detections.value
                            let answer = await router.resolve(ReasoningQuery(question: q, detections: seen, localConfidence: 0))
                            await audio.speak(answer.answer, azimuth: 0)
                        case nil:
                            break
                        }
                    }
                } catch {
                    log.warning("Voice loop ended: \(error.localizedDescription, privacy: .public)")
                }
            })
        } catch {
            log.warning("Voice unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Benchmark

    /// `-benchmark` launch argument: run for 20 s on the live camera, then
    /// write the real on-device numbers to Documents/benchmark-<time>.json.
    private func runBenchmark() {
        background.append(Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, let pipeline = self.pipeline, let vision = self.vision else { return }
            let report = await BenchmarkReport.capture(pipeline: pipeline, vision: vision, lidar: self.lidar != nil)
            let url = report.write()
            self.benchmarkSummary = report.summary
            log.notice("Benchmark: \(report.summary, privacy: .public) -> \(url?.path ?? "not written", privacy: .public)")
        })
    }
}

/// Last frame's detections, for spoken questions ("what is this?").
actor DetectionBox {
    private(set) var value: [Detection] = []
    func set(_ d: [Detection]) { value = d }
}
EOF_AVAE

cat > 'EchoGuideApp/Sources/BenchmarkReport.swift' <<'EOF_AVAE'
// Owner: Maxwell. Real on-device numbers for the README targets, captured
// from the live camera. CI can only measure the frame-delta step on a Mac.

import Foundation
import UIKit
import EchoGuideVision

struct BenchmarkReport: Codable {
    var device: String
    var system: String
    var lidar: Bool
    var framesSeen: UInt64
    var framesInferred: UInt64
    var computeSaved: Double
    var endToEndP50Ms: Double
    var endToEndP95Ms: Double
    var visionP95Ms: Double
    var visionOverBudgetFrames: Int
    var capturedAt: Date

    /// The README target: local end-to-end (frame to cue) under 15 ms.
    var meetsLocalTarget: Bool { endToEndP95Ms < 15 }

    var summary: String {
        String(format: "e2e p50 %.1f ms, p95 %.1f ms %@ | vision p95 %.1f ms | skipped %.0f%% of %llu frames",
               endToEndP50Ms, endToEndP95Ms, meetsLocalTarget ? "(meets 15 ms)" : "(MISSES 15 ms)",
               visionP95Ms, computeSaved * 100, framesSeen)
    }

    @MainActor
    static func capture(pipeline: PerceptionPipeline, vision: LocalVisionEngine, lidar: Bool) async -> BenchmarkReport {
        let s = pipeline.stats
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return BenchmarkReport(
            device: machine,
            system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            lidar: lidar,
            framesSeen: s.framesSeen,
            framesInferred: s.framesInferred,
            computeSaved: s.computeSaved,
            endToEndP50Ms: s.totalP50Ms,
            endToEndP95Ms: s.totalP95Ms,
            visionP95Ms: await vision.p95Ms,
            visionOverBudgetFrames: await vision.overBudgetFrames,
            capturedAt: Date()
        )
    }

    func write() -> URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = dir.appendingPathComponent("benchmark-\(Int(capturedAt.timeIntervalSince1970)).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(self), (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}
EOF_AVAE

cat > 'EchoGuideApp/Sources/EchoGuideApp.swift' <<'EOF_AVAE'
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
    /// Voice mode needs the mic. Keep mixing and ducking so a carer's call or
    /// music is never silenced, and route to the speaker, not the earpiece.
    static func enableRecording() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .voiceChat,
                          options: [.defaultToSpeaker, .mixWithOthers, .duckOthers, .allowBluetoothA2DP])
        try s.setActive(true)
    }
}
EOF_AVAE

cat > 'EchoGuideTests/EngineTests.swift' <<'EOF_AVAE'
// Owner: Maxwell. Unit tests for the pure logic under every engine. Hardware
// paths (camera, ANE, LiDAR, actuator) are covered by on-device runs, not CI.

import Foundation
import Testing
@testable import EchoGuideAutomation
import EchoGuideContracts
@testable import EchoGuideInfra
import EchoGuideSpatial
import EchoGuideVision

// MARK: - Helpers

func lumaFrame(width: Int = 640, height: Int = 480, fill: UInt8 = 100, square: (x: Int, y: Int, size: Int, value: UInt8)? = nil) -> [UInt8] {
    var px = [UInt8](repeating: fill, count: width * height)
    if let s = square {
        for y in s.y..<min(height, s.y + s.size) {
            for x in s.x..<min(width, s.x + s.size) { px[y * width + x] = s.value }
        }
    }
    return px
}

func analyze(_ e: FrameDeltaEngine, _ px: [UInt8], t: TimeInterval, width: Int = 640, height: Int = 480) -> FrameDeltaDecision {
    px.withUnsafeBufferPointer { e.analyze(luma: $0, width: width, height: height, bytesPerRow: width, timestamp: t) }
}

func det(_ label: String, x: Float, y: Float, size: Float = 0.1, conf: Float = 0.9, kind: DetectionKind = .object, text: String? = nil) -> Detection {
    Detection(label: label, confidence: conf, box: ImageRect(x: x - size / 2, y: y - size / 2, width: size, height: size), kind: kind, text: text)
}

func tip(x: Float, y: Float) -> Detection { det("fingertip", x: x, y: y, size: 0.02, kind: .fingertip) }

func frame(_ d: [Detection], t: TimeInterval, index: UInt64 = 0) -> VisionFrameResult {
    VisionFrameResult(frameIndex: index, timestamp: t, detections: d, inferenceMs: 5)
}

actor RecordingHaptics: HapticCueing {
    var guides = 0, confirms = 0, warns = 0, stops = 0
    func guide(offset dx: Float, _ dy: Float, distanceMetres: Float?) async { guides += 1 }
    func confirm() async { confirms += 1 }
    func warn() async { warns += 1 }
    func stop() async { stops += 1 }
}

actor RecordingAudio: SpatialAudioCueing {
    var spoken: [String] = []
    var pings = 0
    func speak(_ text: String, azimuth: Float) async { spoken.append(text) }
    func ping(azimuth: Float, elevation: Float) async { pings += 1 }
}

struct FixedConnectivity: Connectivity {
    let online: Bool
    func isOnline() async -> Bool { online }
}

struct StubProvider: ReasoningProvider {
    var reply: String = "Microwave start button."
    var delay: TimeInterval = 0
    var fail = false
    func answer(_ q: ReasoningQuery, includeImage: Bool) async throws -> String {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if fail { throw URLError(.notConnectedToInternet) }
        return reply
    }
}

// MARK: - Maxwell: frame delta

@Suite struct FrameDeltaTests {
    @Test func staticSceneIsSkipped() {
        var config = FrameDeltaConfig()
        config.idleRefresh = nil
        let e = FrameDeltaEngine(config: config)
        let still = lumaFrame()
        #expect(analyze(e, still, t: 0) == .infer(.firstFrame))
        for i in 1...300 { #expect(analyze(e, still, t: Double(i) / 30) == .skip) }
        #expect(e.stats.skipRatio > 0.99)
    }

    @Test func objectEntryTriggers() {
        let e = FrameDeltaEngine()
        _ = analyze(e, lumaFrame(), t: 0)
        let entered = lumaFrame(square: (200, 150, 160, 230))
        guard case .infer(.motion(let f)) = analyze(e, entered, t: 0.5) else {
            Issue.record("expected motion")
            return
        }
        #expect(f > 0.04)
    }

    @Test func exposureShiftIsNotMotion() {
        var config = FrameDeltaConfig()
        config.idleRefresh = nil
        let e = FrameDeltaEngine(config: config)
        _ = analyze(e, lumaFrame(fill: 100), t: 0)
        #expect(analyze(e, lumaFrame(fill: 140), t: 0.5) == .skip)
    }

    @Test func cooldownLimitsTriggers() {
        let e = FrameDeltaEngine()
        _ = analyze(e, lumaFrame(), t: 0)
        _ = analyze(e, lumaFrame(square: (0, 0, 200, 250)), t: 1.0)
        #expect(analyze(e, lumaFrame(), t: 1.03) == .skip)
    }

    @Test func idleRefreshFires() {
        let e = FrameDeltaEngine()
        let still = lumaFrame()
        _ = analyze(e, still, t: 0)
        #expect(analyze(e, still, t: 1) == .skip)
        #expect(analyze(e, still, t: 3.1) == .infer(.idleRefresh))
    }

    @Test func benchmarkUnderBudget() {
        let e = FrameDeltaEngine()
        let a = lumaFrame(width: 1920, height: 1440), b = lumaFrame(width: 1920, height: 1440, square: (300, 300, 400, 200))
        var window = LatencyWindow(capacity: 500)
        for i in 0..<500 {
            _ = analyze(e, i % 2 == 0 ? a : b, t: Double(i) / 60, width: 1920, height: 1440)
            window.record(e.lastAnalysisMs)
        }
        // Debug build on a shared, parallel CI runner: p50 holds the 1 ms target,
        // p95 gets headroom for scheduler noise. Release on device is far lower.
        #expect(window.percentile(0.50) < 1.0)
        #expect(window.percentile(0.95) < 3.0)
    }
}

// MARK: - Maxwell + Bryan: vision geometry + digital fence

@Suite struct VisionAndFenceTests {
    @Test func visionBoxFlipsToTopLeft() {
        let r = VisionGeometry.topLeft(x: 0.1, y: 0.7, width: 0.2, height: 0.2)
        #expect(abs(r.y - 0.1) < 1e-6)
        #expect(abs(r.x - 0.1) < 1e-6)
    }

    @Test func fingerInsideHazardIsBreach() {
        let fence = SpatialFence.kitchenDefaults
        let f = frame([det("oven", x: 0.5, y: 0.5, size: 0.3), tip(x: 0.5, y: 0.5)], t: 0)
        #expect(fence.evaluate(f) == .breached(zone: "hob"))
    }

    @Test func fingerNearHazardIsApproach() {
        let fence = SpatialFence.kitchenDefaults
        let f = frame([det("oven", x: 0.5, y: 0.5, size: 0.3), tip(x: 0.69, y: 0.5)], t: 0)
        #expect(fence.evaluate(f) == .approaching(zone: "hob", metres: nil))
    }

    @Test func depthSeparatesOverlapFromContact() {
        let fence = SpatialFence.kitchenDefaults
        let f = frame([det("oven", x: 0.5, y: 0.5, size: 0.3), tip(x: 0.5, y: 0.5)], t: 0)
        // Hand 30 cm from the lens, oven 1.2 m away: overlapping on screen, not touching.
        guard case .approaching = fence.evaluate(f, handDepth: 0.3, zoneDepth: 1.2) else {
            Issue.record("expected approach, not breach")
            return
        }
    }

    @Test func noFingerNoEvent() {
        #expect(SpatialFence.kitchenDefaults.evaluate(frame([det("oven", x: 0.5, y: 0.5)], t: 0)) == nil)
    }

    @Test func locationFenceNeedsDwellAndIgnoresJitter() {
        let home = GeoCoordinate(latitude: 51.5145, longitude: -0.1165)
        var fence = LocationFence(areas: [SafeArea(name: "home", center: home, radiusMetres: 80)])
        #expect(fence.update(home, accuracyMetres: 10, at: 0) == nil)

        let away = GeoCoordinate(latitude: 51.5175, longitude: -0.1165) // ~330 m north
        #expect(fence.update(away, accuracyMetres: 300, at: 10) == nil) // bad fix ignored
        #expect(fence.update(away, accuracyMetres: 10, at: 20) == nil)
        #expect(fence.update(away, accuracyMetres: 10, at: 70) == .leftSafeArea(region: "home"))
        #expect(fence.update(away, accuracyMetres: 10, at: 90) == nil) // reported once
        #expect(fence.update(home, accuracyMetres: 10, at: 200) == .returnedToSafeArea(region: "home"))
    }
}

// MARK: - Bryan + Maxwell: haptics, depth, audio math

@Suite struct SpatialTests {
    @Test func alignedMeansConfirm() {
        #expect(HapticMapping.pulse(dx: 0.01, dy: 0.01) == nil)
    }

    @Test func closerIsFasterAndStronger() throws {
        let far = try #require(HapticMapping.pulse(dx: 0.4, dy: 0))
        let near = try #require(HapticMapping.pulse(dx: 0.06, dy: 0))
        #expect(near.interval < far.interval)
        #expect(near.intensity > far.intensity)
    }

    @Test func sharpnessEncodesVertical() throws {
        let up = try #require(HapticMapping.pulse(dx: 0, dy: -0.2))
        let down = try #require(HapticMapping.pulse(dx: 0, dy: 0.2))
        #expect(up.sharpness > down.sharpness)
    }

    @Test func depthMedianRejectsLowConfidenceAndOutliers() {
        let w = 4, h = 4
        var depth = [Float32](repeating: 1.0, count: w * h)
        depth[5] = 9.0 // spike
        var conf = [UInt8](repeating: 2, count: w * h)
        conf[6] = 0
        depth[6] = 0.1 // low-confidence garbage
        let v = depth.withUnsafeBufferPointer { d in
            conf.withUnsafeBufferPointer { c in
                DepthSampler.sample(depth: d, confidence: c, width: w, height: h, rowStride: w, confidenceRowStride: w,
                                    at: ImagePoint(x: 0.3, y: 0.3))
            }
        }
        #expect(v == 1.0)
    }

    @Test func uprightToSensorMapping() {
        // Upright top-right is the sensor's top-left for a portrait back camera.
        #expect(DepthSampler.sensorPoint(fromUpright: ImagePoint(x: 1, y: 0)) == ImagePoint(x: 0, y: 0))
    }

    @Test func azimuthClamps() {
        #expect(SpatialAudioMath.azimuth(forOffsetX: 5) == .pi / 2)
        #expect(SpatialAudioMath.azimuth(forOffsetX: 0) == 0)
    }
}

// MARK: - Bryan: cognitive isolation + automation

@Suite struct CognitiveTests {
    @Test func picksOneAndSettles() {
        var iso = CognitiveTaskIsolation()
        let dets = [det("cup", x: 0.2, y: 0.2), det("button", x: 0.55, y: 0.5), det("chair", x: 0.5, y: 0.5, size: 0.5)]
        #expect(iso.isolate(frame(dets, t: 0)) == nil)
        #expect(iso.isolate(frame(dets, t: 0.1)) == nil)
        let step = iso.isolate(frame(dets, t: 0.2))
        #expect(step?.targetLabel == "button")
    }

    @Test func stickyAgainstSmallRivals() {
        var config = CognitiveConfig()
        config.settleFrames = 1
        var iso = CognitiveTaskIsolation(config: config)
        _ = iso.isolate(frame([det("button", x: 0.6, y: 0.5)], t: 0))
        let step = iso.isolate(frame([det("button", x: 0.6, y: 0.5), det("dial", x: 0.55, y: 0.5)], t: 0.1))
        #expect(step?.targetLabel == "button")
    }

    @Test func goalFiltersByText() {
        var config = CognitiveConfig()
        config.settleFrames = 1
        var iso = CognitiveTaskIsolation(config: config, goal: "start")
        let dets = [det("text", x: 0.3, y: 0.3, kind: .text, text: "STOP"), det("text", x: 0.7, y: 0.7, kind: .text, text: "START")]
        #expect(iso.isolate(frame(dets, t: 0))?.instruction.hasPrefix("START") == true)
    }

    @Test func oneDirectionAtATime() {
        #expect(CognitiveTaskIsolation.direction(dx: 0.3, dy: -0.1) == "Move right")
        #expect(CognitiveTaskIsolation.direction(dx: 0.02, dy: -0.1) == "Move up a little")
    }

    @Test func instructionsAreShort() {
        #expect(CognitiveTaskIsolation.clip("one two three four five six seven eight nine ten", words: 8).split(separator: " ").count == 8)
    }
}

@Suite struct AutomationTests {
    func engine(tools: ToolInvoking? = nil, router: ReasoningRouting? = nil) -> (AutomationEngine, RecordingHaptics, RecordingAudio) {
        var c = CognitiveConfig()
        c.settleFrames = 1
        let h = RecordingHaptics(), a = RecordingAudio()
        return (AutomationEngine(haptics: h, audio: a, router: router, tools: tools, cognitive: CognitiveTaskIsolation(config: c)), h, a)
    }

    @Test func guidesThenCompletesOnDwellAndCallsTool() async throws {
        let registry = PluginRegistry()
        await registry.register(ToolDescriptor(name: "microwave_start", description: "Start the microwave", sideEffect: .physical,
                                               claim: ToolClaim(labels: ["start button"])) { _ in "Microwave started." })
        let (e, h, a) = engine(tools: registry)
        await e.start()

        await e.ingest(frame([det("start button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 0))
        guard case .guiding = await e.state else { Issue.record("expected guiding"); return }
        #expect(await h.guides == 1)
        #expect(await a.spoken.first == "Start button. Move right.")

        await e.ingest(frame([det("start button", x: 0.7, y: 0.5), tip(x: 0.7, y: 0.5)], t: 0.5))
        guard case .onTarget = await e.state else { Issue.record("expected onTarget"); return }

        await e.ingest(frame([det("start button", x: 0.7, y: 0.5), tip(x: 0.7, y: 0.5)], t: 1.4))
        #expect(await e.state == .completed("Microwave started."))
        #expect(await a.spoken.contains("Microwave started."))
    }

    @Test func noToolCallWithoutDwell() async {
        let registry = PluginRegistry()
        let fired = Counter()
        await registry.register(ToolDescriptor(name: "go", description: "", sideEffect: .physical, claim: ToolClaim(labels: ["button"])) { _ in
            await fired.inc()
            return "ok"
        })
        let (e, _, _) = engine(tools: registry)
        await e.start()
        await e.ingest(frame([det("button", x: 0.5, y: 0.5), tip(x: 0.5, y: 0.5)], t: 0))
        await e.ingest(frame([det("button", x: 0.5, y: 0.5), tip(x: 0.5, y: 0.5)], t: 0.3))
        #expect(await fired.value == 0)
    }

    @Test func fenceBreachPreemptsGuidance() async {
        let (e, h, a) = engine()
        await e.start()
        await e.ingest(frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 0), fence: .breached(zone: "hob"))
        #expect(await e.state == .warning("hob"))
        #expect(await h.warns == 1)
        #expect(await h.guides == 0)
        #expect(await a.spoken == ["Stop. Hob."])
    }

    @Test func lowConfidenceAsksTheRouter() async {
        let router = CloudReasoningRouter(provider: StubProvider(reply: "Defrost dial."), connectivity: FixedConnectivity(online: true))
        let (e, _, a) = engine(router: router)
        await e.start()
        await e.ingest(frame([det("dial", x: 0.7, y: 0.5, conf: 0.5), tip(x: 0.4, y: 0.5)], t: 0))
        #expect(await a.spoken == ["Defrost dial."])
    }
}

actor Counter {
    var value = 0
    func inc() { value += 1 }
}

// MARK: - Maxwell: router + plugins

@Suite struct RouterTests {
    let query = ReasoningQuery(question: "What is it?", detections: [det("dial", x: 0.5, y: 0.5, conf: 0.6)], localConfidence: 0.6)

    @Test func highConfidenceStaysLocal() async {
        let r = CloudReasoningRouter(provider: StubProvider(), connectivity: FixedConnectivity(online: true))
        var q = query
        q.localConfidence = 0.9
        #expect(await r.resolve(q).source == .local)
    }

    @Test func airplaneModeFallsBackLocally() async {
        let r = CloudReasoningRouter(provider: StubProvider(), connectivity: FixedConnectivity(online: false))
        let out = await r.resolve(query)
        #expect(out.source == .localFallback)
        #expect(out.answer == "This looks like dial.")
    }

    @Test func lowConfidenceGoesToCloud() async {
        let r = CloudReasoningRouter(provider: StubProvider(), connectivity: FixedConnectivity(online: true))
        let out = await r.resolve(query)
        #expect(out.source == .cloud)
        #expect(out.answer == "Microwave start button.")
    }

    @Test func timeoutFallsBack() async {
        var c = CloudRouterConfig()
        c.timeout = 0.05
        let r = CloudReasoningRouter(config: c, provider: StubProvider(delay: 1), connectivity: FixedConnectivity(online: true))
        let out = await r.resolve(query)
        #expect(out.source == .localFallback)
        #expect(out.latencyMs < 500)
    }

    @Test func breakerOpensAfterFailures() async {
        var c = CloudRouterConfig()
        c.breakerFailures = 2
        let r = CloudReasoningRouter(config: c, provider: StubProvider(fail: true), connectivity: FixedConnectivity(online: true))
        for _ in 0..<3 { _ = await r.resolve(query) }
        #expect(await r.latency.count == 0)
    }
}

@Suite struct PluginTests {
    func registry() async -> PluginRegistry {
        let r = PluginRegistry()
        await r.register(ToolDescriptor(name: "lookup_barcode", description: "Product lookup", sideEffect: .none,
                                        claim: ToolClaim(barcodePrefixes: ["50"]), parameters: ["text"]) { args in
            "Product \(args["text"] ?? "")"
        })
        return r
    }

    @Test func matchesBarcodeAndInvokes() async throws {
        let r = await registry()
        let m = try #require(await r.match(det("barcode", x: 0.5, y: 0.5, kind: .barcode, text: "5012345678900")))
        #expect(m.arguments["text"] == "5012345678900")
        #expect(try await r.invoke(m) == "Product 5012345678900")
    }

    @Test func mcpToolsList() async throws {
        let r = await registry()
        let req = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let data = try #require(await r.handle(Data(req.utf8)))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let tools)? = json["result"]?["tools"] else { Issue.record("no tools"); return }
        #expect(tools.first?["name"]?.stringValue == "lookup_barcode")
        #expect(tools.first?["inputSchema"]?["type"]?.stringValue == "object")
    }

    @Test func mcpToolsCall() async throws {
        let r = await registry()
        let req = #"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"lookup_barcode","arguments":{"text":"50"}}}"#
        let json = try JSONDecoder().decode(JSONValue.self, from: try #require(await r.handle(Data(req.utf8))))
        guard case .array(let content)? = json["result"]?["content"] else { Issue.record("no content"); return }
        #expect(content.first?["text"]?.stringValue == "Product 50")
        #expect(json["result"]?["isError"] == .bool(false))
    }

    @Test func mcpUnknownMethod() async throws {
        let r = await registry()
        let json = try JSONDecoder().decode(JSONValue.self, from: try #require(await r.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"nope"}"#.utf8))))
        #expect(json["error"]?["code"] == .number(-32601))
    }
}
EOF_AVAE

cat > 'EchoGuideTests/ExperienceTests.swift' <<'EOF_AVAE'
// Owner: Bryan. Tests for the experience + safety layer: automation state
// machine, cognitive isolation, haptic mapping, and the digital fence. Shares
// the helpers (det, tip, frame, RecordingHaptics, RecordingAudio) defined in
// EngineTests.swift.

import Foundation
import Testing
@testable import EchoGuideAutomation
import EchoGuideContracts
@testable import EchoGuideInfra
import EchoGuideSpatial
import EchoGuideVision

/// Depth stub keyed by label: the hand and each zone get their own distance.
struct TableDepth: DepthProviding {
    var byPoint: [(ImagePoint, Float)]
    func depth(at point: ImagePoint) async -> Float? {
        byPoint.first { $0.0.distance(to: point) < 0.02 }?.1
    }
}

@Suite struct FenceDepthTests {
    @Test func eachZoneGetsItsOwnDepth() async {
        // Hob and knife overlap the finger on screen. Hob is 1.2 m away, the
        // knife is 0.4 m away, the hand 0.3 m: only the knife is a breach.
        let fence = SpatialFence.kitchenDefaults
        let hob = det("oven", x: 0.5, y: 0.5, size: 0.3)
        let knife = det("knife", x: 0.3, y: 0.3, size: 0.1)
        let f = frame([hob, knife, tip(x: 0.3, y: 0.3)], t: 0)
        let depth = TableDepth(byPoint: [(hob.box.mid, 1.2), (knife.box.mid, 0.4), (ImagePoint(x: 0.3, y: 0.3), 0.3)])
        #expect(await fence.evaluate(f, depth: depth) == .breached(zone: "knife"))
    }

    @Test func farZoneOverlapIsOnlyAnApproach() async {
        let fence = SpatialFence.kitchenDefaults
        let hob = det("oven", x: 0.5, y: 0.5, size: 0.3)
        let f = frame([hob, tip(x: 0.42, y: 0.5)], t: 0) // inside the hob box
        let depth = TableDepth(byPoint: [(hob.box.mid, 1.2), (ImagePoint(x: 0.42, y: 0.5), 0.3)])
        guard case .approaching(let zone, let metres) = await fence.evaluate(f, depth: depth) else {
            Issue.record("expected approach"); return
        }
        #expect(zone == "hob")
        #expect(metres.map { abs($0 - 0.9) < 1e-5 } == true)
    }

    @Test func unknownDepthFallsBackToTwoD() async {
        let fence = SpatialFence.kitchenDefaults
        let f = frame([det("oven", x: 0.5, y: 0.5, size: 0.3), tip(x: 0.5, y: 0.5)], t: 0)
        #expect(await fence.evaluate(f, depth: nil) == .breached(zone: "hob"))
        #expect(await fence.evaluate(f, depth: TableDepth(byPoint: [])) == .breached(zone: "hob"))
    }

    @Test func fixedRegionZone() {
        let fence = SpatialFence(zones: [SpatialFenceZone(name: "stairs", anchor: .region(ImageRect(x: 0, y: 0.8, width: 1, height: 0.2)))])
        #expect(fence.evaluate(frame([tip(x: 0.5, y: 0.9)], t: 0)) == .breached(zone: "stairs"))
        #expect(fence.evaluate(frame([tip(x: 0.5, y: 0.75)], t: 0)) == .approaching(zone: "stairs", metres: nil))
        #expect(fence.evaluate(frame([tip(x: 0.5, y: 0.5)], t: 0)) == nil)
    }

    @Test func locationFenceExposesWhereTheUserIs() {
        let home = GeoCoordinate(latitude: 51.5145, longitude: -0.1165)
        var fence = LocationFence(areas: [SafeArea(name: "home", center: home, radiusMetres: 80)], exitDwell: 10)
        _ = fence.update(home, accuracyMetres: 5, at: 0)
        #expect(fence.insideArea == "home")
        #expect(!fence.isOutside)
        let away = GeoCoordinate(latitude: 51.5175, longitude: -0.1165)
        _ = fence.update(away, accuracyMetres: 5, at: 1)
        #expect(fence.insideArea == nil)
        #expect(fence.update(away, accuracyMetres: 5, at: 12) == .leftSafeArea(region: "home"))
        #expect(fence.isOutside)
    }
}

@Suite struct CognitiveIsolationTests {
    @Test func reportsWhenTheTargetVanishes() {
        var c = CognitiveConfig()
        c.settleFrames = 1
        var iso = CognitiveTaskIsolation(config: c)
        #expect(iso.isolate(frame([det("button", x: 0.6, y: 0.5)], t: 0)) != nil)
        #expect(iso.isCurrentVisible)
        // Dropped frame: the remembered step is still returned, but flagged.
        #expect(iso.isolate(frame([], t: 0.1))?.targetLabel == "button")
        #expect(!iso.isCurrentVisible)
    }

    @Test func excludedLabelDropsCurrentTarget() {
        var c = CognitiveConfig()
        c.settleFrames = 1
        var iso = CognitiveTaskIsolation(config: c)
        let dets = [det("start", x: 0.5, y: 0.5), det("stop", x: 0.2, y: 0.2)]
        #expect(iso.isolate(frame(dets, t: 0))?.targetLabel == "start")
        iso.excludedLabels = ["start"]
        #expect(iso.isolate(frame(dets, t: 0.1))?.targetLabel == "stop")
        iso.excludedLabels = []
        // "start" sits under the finger and is clearly better, so it wins back.
        #expect(iso.isolate(frame(dets, t: 0.2))?.targetLabel == "start")
    }
}

@Suite struct HapticEngineTests {
    @Test func confirmSilencesGuidance() async {
        // No actuator on the CI host: the engine still tracks its state.
        let h = SpatialHapticEngine()
        await h.guide(offset: 0.3, 0.1, distanceMetres: nil)
        #expect(await h.isGuiding)
        await h.confirm()
        #expect(await !h.isGuiding)
        await h.guide(offset: 0.3, 0.1, distanceMetres: nil)
        #expect(await h.isGuiding)
        await h.warn()
        #expect(await !h.isGuiding)
        await h.stop()
    }

    @Test func alignedGuideIsConfirmNotPulse() async {
        let h = SpatialHapticEngine()
        await h.guide(offset: 0.01, 0.01, distanceMetres: nil)
        #expect(await !h.isGuiding)
    }

    @Test func lidarWeakensDistantHand() throws {
        let near = try #require(HapticMapping.pulse(dx: 0.2, dy: 0, distanceMetres: 0.2))
        let far = try #require(HapticMapping.pulse(dx: 0.2, dy: 0, distanceMetres: 0.8))
        #expect(far.intensity < near.intensity)
        #expect(far.intensity >= 0.6 * 0.35) // floor keeps it feelable
    }
}

@Suite struct AutomationSafetyTests {
    func engine(tools: ToolInvoking? = nil, config: AutomationConfig = AutomationConfig()) -> (AutomationEngine, RecordingHaptics, RecordingAudio) {
        var c = CognitiveConfig()
        c.settleFrames = 1
        let h = RecordingHaptics(), a = RecordingAudio()
        return (AutomationEngine(haptics: h, audio: a, tools: tools, cognitive: CognitiveTaskIsolation(config: c), config: config), h, a)
    }

    func physicalTool(_ fired: Counter) async -> PluginRegistry {
        let registry = PluginRegistry()
        await registry.register(ToolDescriptor(name: "go", description: "", sideEffect: .physical, claim: ToolClaim(labels: ["button"])) { _ in
            await fired.inc()
            return "ok"
        })
        return registry
    }

    @Test func breachResetsTheDwell() async {
        let fired = Counter()
        let (e, h, _) = engine(tools: await physicalTool(fired))
        await e.start()
        let onIt = [det("button", x: 0.5, y: 0.5), tip(x: 0.5, y: 0.5)]
        await e.ingest(frame(onIt, t: 0))
        guard case .onTarget = await e.state else { Issue.record("expected onTarget"); return }
        // 0.5 s in, the hand strays into the hob zone.
        await e.ingest(frame(onIt, t: 0.5), fence: .breached(zone: "hob"))
        #expect(await e.state == .warning("hob"))
        #expect(await h.warns == 1)
        // 0.9 s after the first touch: without the reset this would fire.
        await e.ingest(frame(onIt, t: 0.9))
        #expect(await fired.value == 0)
        guard case .onTarget = await e.state else { Issue.record("expected onTarget again"); return }
        await e.ingest(frame(onIt, t: 1.8))
        #expect(await fired.value == 1)
    }

    @Test func vanishedTargetTimesOutToScanning() async {
        let (e, h, _) = engine()
        await e.start()
        await e.ingest(frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 0))
        guard case .guiding = await e.state else { Issue.record("expected guiding"); return }
        // Target gone, within the timeout: cue carries on, state unchanged.
        await e.ingest(frame([tip(x: 0.4, y: 0.5)], t: 0.5))
        guard case .guiding = await e.state else { Issue.record("expected still guiding"); return }
        #expect(await h.stops == 0)
        // Past the timeout: haptics silenced, back to scanning.
        await e.ingest(frame([tip(x: 0.4, y: 0.5)], t: 1.5))
        #expect(await e.state == .scanning)
        #expect(await h.stops == 1)
        // The target returning is announced afresh, not treated as "already said".
        await e.ingest(frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 2))
        guard case .guiding = await e.state else { Issue.record("expected guiding again"); return }
    }

    @Test func completedTargetMovesOnToTheNextStep() async {
        var config = AutomationConfig()
        config.completedCooldown = 5
        let (e, h, a) = engine(config: config)
        await e.start()
        let both = { (tipX: Float) in [det("start", x: 0.5, y: 0.5), det("stop", x: 0.2, y: 0.2, size: 0.08), tip(x: tipX, y: 0.5)] }
        await e.ingest(frame(both(0.5), t: 0))
        await e.ingest(frame(both(0.5), t: 1))
        #expect(await e.state == .completed("start"))
        #expect(await h.stops >= 1)
        // Finger still on the finished button: it is not offered again...
        await e.ingest(frame(both(0.5), t: 1.1))
        guard case .guiding(let step) = await e.state else { Issue.record("expected guiding to next"); return }
        #expect(step.targetLabel == "stop")
        #expect(await a.spoken.last?.hasPrefix("Stop.") == true)
        // ...until the cooldown has passed and nothing else is around.
        await e.ingest(frame([det("start", x: 0.5, y: 0.5), tip(x: 0.3, y: 0.5)], t: 7))
        guard case .guiding(let again) = await e.state else { Issue.record("expected guiding to start"); return }
        #expect(again.targetLabel == "start")
    }

    @Test func wanderingIsStickyUntilReturn() async {
        let (e, _, a) = engine()
        await e.start()
        await e.ingest(fence: .leftSafeArea(region: "home"), at: 0)
        #expect(await e.state == .outsideSafeArea("home"))
        #expect(await a.spoken == ["You have left home."])
        // Frames do not clear a wandering alert.
        await e.ingest(frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 1))
        #expect(await e.state == .outsideSafeArea("home"))
        await e.ingest(fence: .returnedToSafeArea(region: "home"), at: 60)
        #expect(await e.state == .scanning)
    }

    @Test func caregiverToldWhenToolExists() async {
        let registry = PluginRegistry()
        let told = Counter()
        await registry.register(ToolDescriptor(name: "notify_caregiver", description: "", sideEffect: .none, parameters: ["region"]) { args in
            await told.inc()
            return "Carer told: left \(args["region"] ?? "")."
        })
        let (e, _, a) = engine(tools: registry)
        await e.start()
        await e.ingest(fence: .leftSafeArea(region: "home"), at: 0)
        #expect(await told.value == 1)
        #expect(await a.spoken == ["You have left home. Your carer has been told."])
    }

    @Test func returnDoesNotUnpause() async {
        let (e, _, _) = engine()
        await e.ingest(fence: .returnedToSafeArea(region: "home"), at: 0)
        #expect(await e.state == .idle)
    }

    @Test func stopSilencesAndForgets() async {
        let (e, h, a) = engine()
        await e.start()
        await e.ingest(frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 0))
        await e.stop()
        #expect(await e.state == .idle)
        #expect(await h.stops == 1)
        await e.ingest(frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 1))
        #expect(await e.state == .idle)
        await e.start()
        await e.ingest(frame([det("button", x: 0.7, y: 0.5), tip(x: 0.4, y: 0.5)], t: 2))
        // Spoken again after a restart.
        #expect(await a.spoken.count == 2)
    }
}
EOF_AVAE

cat > 'EchoGuideTests/PerceptionAndPluginTests.swift' <<'EOF_AVAE'
// Owner: Maxwell. Perception pipeline back-pressure and the built-in plugins,
// all against stubs: no camera, no network.

import CoreVideo
import Foundation
import Testing
import EchoGuideContracts
@testable import EchoGuideInfra
import EchoGuideVision

// MARK: - Stubs

final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Responder = @Sendable (URLRequest) throws -> (Int, Data)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var responder: Responder

    init(_ responder: @escaping Responder = { _ in (200, Data("{}".utf8)) }) { self.responder = responder }

    var requests: [URLRequest] { lock.withLock { _requests } }
    func respond(_ r: @escaping Responder) { lock.withLock { responder = r } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let r = lock.withLock { _requests.append(request); return responder }
        let (status, data) = try r(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

func pixelBuffer(width: Int = 640, height: Int = 480, fill: UInt8 = 100, square: Bool = false) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            base[y * bpr + x] = square && x > 160 && x < 480 && y > 120 && y < 360 ? 230 : fill
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

actor SlowVision: FrameInferring {
    let delay: TimeInterval
    var calls = 0
    init(delay: TimeInterval) { self.delay = delay }
    func infer(_ frame: CameraFrame) async -> VisionFrameResult {
        calls += 1
        try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        return VisionFrameResult(frameIndex: frame.index, timestamp: frame.timestamp, detections: [], inferenceMs: delay * 1000)
    }
}

actor ResultBox {
    var timings: [PipelineTiming] = []
    func add(_ t: PipelineTiming) { timings.append(t) }
}

func waitUntil(_ timeout: TimeInterval = 2, _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

// MARK: - Pipeline

@Suite struct PerceptionPipelineTests {
    @Test func skipsStaticAndInfersOnMotion() async {
        var config = FrameDeltaConfig()
        config.idleRefresh = nil
        config.cooldown = 0
        let vision = SlowVision(delay: 0)
        let box = ResultBox()
        let p = PerceptionPipeline(vision: vision, delta: FrameDeltaEngine(config: config)) { _, t in await box.add(t) }

        let still = pixelBuffer(), moved = pixelBuffer(square: true)
        p.submit(CameraFrame(pixelBuffer: still, timestamp: 0, index: 1))
        await waitUntil { await box.timings.count == 1 }
        for i in 2...20 { p.submit(CameraFrame(pixelBuffer: still, timestamp: Double(i) / 30, index: UInt64(i))) }
        #expect(p.submit(CameraFrame(pixelBuffer: moved, timestamp: 1, index: 21)).shouldInfer)
        await waitUntil { await box.timings.count == 2 }

        let s = p.stats
        #expect(s.framesSeen == 21)
        #expect(s.framesSkipped == 19)
        #expect(s.framesInferred == 2)
        #expect(await vision.calls == 2)
    }

    @Test func dropsFramesWhileBusyAndRecoversMotion() async {
        var config = FrameDeltaConfig()
        config.cooldown = 0
        config.idleRefresh = nil
        let vision = SlowVision(delay: 0.2)
        let box = ResultBox()
        let p = PerceptionPipeline(vision: vision, delta: FrameDeltaEngine(config: config)) { _, t in await box.add(t) }

        p.submit(CameraFrame(pixelBuffer: pixelBuffer(), timestamp: 0, index: 1)) // first frame -> infer (slow)
        p.submit(CameraFrame(pixelBuffer: pixelBuffer(square: true), timestamp: 0.03, index: 2)) // motion, busy -> dropped
        #expect(p.stats.framesDroppedBusy == 1)

        await waitUntil { await box.timings.count == 1 }
        // The dropped motion is not lost: the next frame is forced through.
        #expect(p.submit(CameraFrame(pixelBuffer: pixelBuffer(square: true), timestamp: 0.5, index: 3)) == .infer(.forced))
        await waitUntil { await box.timings.count == 2 }
        #expect(p.stats.computeSaved > 0)
    }

    @Test func timingIsConsistent() async throws {
        let box = ResultBox()
        let p = PerceptionPipeline(vision: SlowVision(delay: 0.01)) { _, t in await box.add(t) }
        p.submit(CameraFrame(pixelBuffer: pixelBuffer(), timestamp: 0, index: 1))
        await waitUntil { await box.timings.count == 1 }
        let t = try #require(await box.timings.first)
        #expect(t.totalMs >= t.inferenceMs)
        #expect(t.deltaMs < 5)
        await waitUntil { p.stats.totalP50Ms > 0 }
        #expect(p.stats.totalP50Ms >= t.totalMs)
    }
}

// MARK: - Plugins

@Suite struct BuiltInPluginTests {
    @Test func homeAssistantCallsService() async throws {
        let transport = StubTransport()
        let tools = HomeAssistantPlugin.tools(
            baseURL: URL(string: "http://ha.local:8123")!,
            entities: [HomeAssistantEntity(name: "microwave_start", doneSentence: "Microwave started.",
                                           entityId: "switch.microwave", service: "switch.turn_on", textContains: ["start"])],
            transport: transport, token: { "tok" })
        let registry = PluginRegistry()
        for t in tools { await registry.register(t) }

        let m = try #require(await registry.match(Detection(label: "text", confidence: 0.9, box: ImageRect(x: 0, y: 0, width: 0.1, height: 0.1),
                                                            kind: .text, text: "START")))
        #expect(m.sideEffect == .physical)
        #expect(try await registry.invoke(m) == "Microwave started.")

        let req = try #require(transport.requests.first)
        #expect(req.url?.absoluteString == "http://ha.local:8123/api/services/switch/turn_on")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: String]
        #expect(body == ["entity_id": "switch.microwave"])
    }

    @Test func homeAssistantErrorSurfaces() async {
        let transport = StubTransport { _ in (401, Data()) }
        let tool = HomeAssistantPlugin.tools(baseURL: URL(string: "http://ha.local")!,
                                             entities: [HomeAssistantEntity(name: "x", doneSentence: "ok", entityId: "light.a", service: "light.turn_on")],
                                             transport: transport, token: { nil })[0]
        await #expect(throws: HTTPStatusError(status: 401)) { try await tool.handler([:]) }
    }

    @Test func caregiverAlertQueuesOfflineAndDeliversLater() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outbox = dir.appendingPathComponent("outbox.json")
        let transport = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        let alerts = CaregiverAlerts(webhook: URL(string: "https://care.example/alerts")!, transport: transport,
                                     outboxURL: outbox, signingSecret: "s3cret")

        // Offline: the tool must not claim the carer was told.
        let tool = await alerts.tool
        await #expect(throws: CaregiverAlertQueued()) { try await tool.handler(["region": "home"]) }
        #expect(await alerts.pending == 1)

        // Survives a relaunch.
        let relaunched = CaregiverAlerts(webhook: URL(string: "https://care.example/alerts")!, transport: transport,
                                         outboxURL: outbox, signingSecret: "s3cret")
        #expect(await relaunched.pending == 1)

        // Back online: delivered once, signed, with an idempotency key.
        transport.respond { _ in (200, Data()) }
        await relaunched.flush()
        #expect(await relaunched.pending == 0)
        let sent = try #require(transport.requests.last)
        #expect(sent.value(forHTTPHeaderField: "Idempotency-Key") != nil)
        #expect(sent.value(forHTTPHeaderField: "X-EchoGuide-Signature")?.hasPrefix("sha256=") == true)
    }

    @Test func signatureIsStableHMAC() {
        // RFC 4231-style sanity: same input, same output, 64 hex chars.
        let a = CaregiverAlerts.signature(Data("x".utf8), secret: "k")
        #expect(a == CaregiverAlerts.signature(Data("x".utf8), secret: "k"))
        #expect(a.count == "sha256=".count + 64)
        #expect(a != CaregiverAlerts.signature(Data("y".utf8), secret: "k"))
    }

    @Test func productLookupParsesAndCaches() async {
        let json = #"{"status":1,"product":{"product_name":"Baked Beans","brands":"Heinz, Kraft","allergens_tags":["en:gluten","en:milk"]}}"#
        let transport = StubTransport { _ in (200, Data(json.utf8)) }
        let plugin = ProductLookupPlugin(transport: transport)
        #expect(await plugin.describe("5000157024671") == "Heinz Baked Beans. Contains gluten, milk.")
        _ = await plugin.describe("5000157024671")
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].value(forHTTPHeaderField: "User-Agent")?.hasPrefix("EchoGuide") == true)
    }

    @Test func qrCodesNeverLeaveTheDevice() async {
        let transport = StubTransport()
        let plugin = ProductLookupPlugin(transport: transport)
        #expect(await plugin.describe("https://example.com/menu") == "QR code for example.com.")
        #expect(await plugin.describe("hello") == "This code is not a product barcode.")
        #expect(transport.requests.isEmpty)
    }

    @Test func anyBarcodeClaim() {
        let d = Detection(label: "barcode", confidence: 0.9, box: ImageRect(x: 0, y: 0, width: 0.1, height: 0.1), kind: .barcode, text: "123")
        #expect(ToolClaim(anyBarcode: true).claims(d))
        #expect(!ToolClaim().claims(d))
    }
}

@Suite struct ManifestTests {
    let json = #"""
    {
      "homeAssistant": { "baseURL": "http://homeassistant.local:8123", "tokenSecret": "ha_token",
        "entities": [ { "name": "microwave_start", "doneSentence": "Microwave started.",
                        "entityId": "switch.microwave", "service": "switch.turn_on",
                        "textContains": ["start"], "sideEffect": "physical" } ] },
      "caregiver": { "webhookURL": "https://care.example.com/alerts", "signingSecret": "care_hmac" },
      "productLookup": true,
      "remoteServers": [ { "endpoint": "http://127.0.0.1:9/mcp" } ]
    }
    """#

    @Test func installsEveryToolAndReportsDeadRemotes() async throws {
        let manifest = try PluginManifest.load(Data(json.utf8))
        let registry = PluginRegistry()
        let secrets: SecretProvider = { ["ha_token": "t", "care_hmac": "h"][$0] }
        let installed = await registry.install(manifest, secrets: secrets, transport: StubTransport())
        #expect(await registry.toolNames == ["microwave_start", "notify_caregiver", "lookup_product"])
        #expect(installed.caregiver != nil)
        #expect(installed.failedRemotes == [URL(string: "http://127.0.0.1:9/mcp")!])
    }

    @Test func rejectsUnknownSideEffect() {
        let bad = json.replacingOccurrences(of: "\"physical\"", with: "\"explosive\"")
        #expect(throws: (any Error).self) { try PluginManifest.load(Data(bad.utf8)) }
    }
}
EOF_AVAE

cat > 'EchoGuideTests/VoiceTests.swift' <<'EOF_AVAE'
// Owner: Maxwell. Voice intent parsing and Deepgram message handling.

import Foundation
import Testing
@testable import EchoGuideInfra

@Suite struct VoiceTests {
    @Test func findIntents() {
        #expect(VoiceIntent.parse("Find the start button.") == .find("start button"))
        #expect(VoiceIntent.parse("where's the kettle") == .find("kettle"))
        #expect(VoiceIntent.parse("Find my keys") == .find("keys"))
    }

    @Test func stopAndQuestions() {
        #expect(VoiceIntent.parse("Stop!") == .stop)
        #expect(VoiceIntent.parse("What does this say?") == .question("What does this say?"))
        #expect(VoiceIntent.parse("   ") == nil)
    }

    @Test func deepgramResults() {
        let msg = #"{"type":"Results","is_final":true,"speech_final":true,"channel":{"alternatives":[{"transcript":"find the kettle","confidence":0.98}]}}"#
        #expect(DeepgramMessage.transcript(from: Data(msg.utf8)) == Transcript(text: "find the kettle", isFinal: true, endOfUtterance: true))
    }

    @Test func deepgramIgnoresMetadataAndSilence() {
        #expect(DeepgramMessage.transcript(from: Data(#"{"type":"Metadata"}"#.utf8)) == nil)
        let empty = #"{"type":"Results","channel":{"alternatives":[{"transcript":""}]}}"#
        #expect(DeepgramMessage.transcript(from: Data(empty.utf8)) == nil)
    }
}
EOF_AVAE

cat > 'Package.swift' <<'EOF_AVAE'
// swift-tools-version: 5.10
// Owner: Maxwell (infrastructure). Targets split by engine; ownership between the two
// co-founders is in .github/CODEOWNERS. Engines only meet through the shared
// Contracts target, so two people never edit the same file.
import PackageDescription

let package = Package(
    name: "AutoVisionAudioEngine",
    platforms: [
        .iOS(.v17),
        // macOS is a build-and-test host only: ARKit, the camera and haptics are
        // compiled out there, the pure logic underneath them still runs in CI.
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "EchoGuide",
            targets: [
                "EchoGuideContracts",
                "EchoGuideVision",
                "EchoGuideSpatial",
                "EchoGuideAutomation",
                "EchoGuideInfra",
            ]
        ),
    ],
    targets: [
        // Shared types and protocols. Changes here need review from both owners.
        .target(
            name: "EchoGuideContracts",
            path: "EchoGuide/Core/Contracts"
        ),
        // Camera, frame delta, local vision (Maxwell); digital fence (Bryan).
        .target(
            name: "EchoGuideVision",
            dependencies: ["EchoGuideContracts"],
            path: "EchoGuide/Core",
            exclude: ["Contracts", "Haptics", "Depth", "Audio", "Automation", "Cognitive", "Plugins", "Router"],
            sources: ["Camera", "Vision", "Fence"]
        ),
        // Haptics, spatial audio (Bryan); LiDAR depth (Maxwell).
        .target(
            name: "EchoGuideSpatial",
            dependencies: ["EchoGuideContracts"],
            path: "EchoGuide/Core",
            exclude: ["Contracts", "Camera", "Vision", "Fence", "Automation", "Cognitive", "Plugins", "Router"],
            sources: ["Haptics", "Depth", "Audio"]
        ),
        // Bryan: automation state machine, cognitive isolation, SwiftUI.
        .target(
            name: "EchoGuideAutomation",
            dependencies: ["EchoGuideContracts"],
            path: "EchoGuide",
            exclude: ["Core/Contracts", "Core/Camera", "Core/Vision", "Core/Fence", "Core/Haptics", "Core/Depth", "Core/Audio", "Core/Plugins", "Core/Router"],
            sources: ["Core/Automation", "Core/Cognitive", "UI"]
        ),
        // Maxwell: plugin registry (MCP), cloud reasoning router.
        .target(
            name: "EchoGuideInfra",
            dependencies: ["EchoGuideContracts"],
            path: "EchoGuide/Core",
            exclude: ["Contracts", "Camera", "Vision", "Fence", "Haptics", "Depth", "Audio", "Automation", "Cognitive"],
            sources: ["Plugins", "Router"]
        ),
        .testTarget(
            name: "EchoGuideTests",
            dependencies: [
                "EchoGuideContracts",
                "EchoGuideVision",
                "EchoGuideSpatial",
                "EchoGuideAutomation",
                "EchoGuideInfra",
            ],
            path: "EchoGuideTests"
        ),
    ]
)
EOF_AVAE

cat > 'README.md' <<'EOF_AVAE'
# AutoVision Audio Engine (EchoGuide)

Hands-free spatial vision for people with visual impairment or dementia. The camera watches. When something changes, the engine works out the **one** next step and guides the hand there with haptic pulses and directional audio. It calls a tool only when the user holds their finger on the target. The phone screen is optional.

* NOT A MEDICAL DEVICE OR FDA APPROVED CURRENTLY JUST FOR TESTING

```
camera ─► FrameDeltaEngine ─► LocalVisionEngine ─► DigitalFence ─┐
 (ARKit or AVCapture)  skip ~99% static     YOLO INT8 + hand + OCR       │
                                                                          ▼
                     CloudReasoningRouter ◄── AutomationEngine ◄── CognitiveTaskIsolation
                     (only < 85% conf)          │ state machine       one step only
                     PluginRegistry (MCP) ◄─────┤
                                                ├─► SpatialHapticEngine (CoreHaptics)
                                                └─► SpatialAudioEngine (AVAudioEngine 3D)
```

## Team and ownership

Two owners. Engines meet only through `EchoGuideContracts`, so the two never edit the same file. Ownership is enforced in `.github/CODEOWNERS`.

| Owner | Area | Paths | Files |
|---|---|---|---|
| Maxwell | Perception + infrastructure: what the phone senses, and the plumbing | `EchoGuide/Core/Camera/`, `Vision/`, `Depth/`, `Plugins/`, `Router/`, `EchoGuideApp/`, `proxy/`, `.github/`, `EchoGuideTests/`, `Package.swift`, `plugins/` | `FrameDeltaEngine`, `PerceptionPipeline`, `CameraFeed`, `LocalVisionEngine`, `LiDARDepthEngine`, `PluginRegistry`, built-in plugins, `CloudReasoningRouter`, `VoiceLoop`, the iOS app, the key proxy, CI/CD, tests |
| Bryan | Experience + safety: everything the user feels, hears and sees | `EchoGuide/Core/Fence/`, `Haptics/`, `Audio/`, `Automation/`, `Cognitive/`, `EchoGuide/UI/` | `DigitalFenceEngine`, `SpatialHapticEngine`, `SpatialAudioEngine`, `AutomationEngine`, `CognitiveTaskIsolation`, `GuidanceView` |
| Both | Shared contracts | `EchoGuide/Core/Contracts/` | `Contracts.swift` (needs both approvals) |

The split follows the pipeline: Maxwell owns everything up to "a detection with a confidence and a depth"; Bryan owns everything from "what one step does the user take, and how do they feel it".

### Branches

`feature/maxwell-vision`, `feature/maxwell-plugins`, `feature/bryan-automation`, `feature/bryan-haptics`, `feature/bryan-fence`. Each branch opens a PR into `main`. CI must pass and the owner of every path the PR touches must approve.

## Digital fence (Bryan)

There are two layers. Each one only reports a `FenceEvent`, and `AutomationEngine` decides how the user hears or feels it.

- **Spatial fence:** hazard zones the camera can see, such as the hob or a knife. A zone follows a detected label or covers a fixed part of the frame. When the fingertip comes near a zone, the user gets "Careful" and a warning pulse. When it enters the zone, they get "Stop", the warning preempts all other guidance, and any dwell in progress is cancelled so a physical tool cannot fire straight after a hazard. If LiDAR is available, `SpatialFence.evaluate(_:depth:)` samples the hand and the centre of every zone through `DepthProviding`, so a hob at 1.2 m and a knife at 0.4 m each get their own distance; a hand that only overlaps a zone on screen is an approach, not a breach.
- **Location fence:** safe areas for dementia wandering. A position must stay outside the area for 45 s before it counts as leaving, and fixes with poor accuracy are ignored. The event is reported once, and a `notify_caregiver` MCP tool is called if one is registered. The engine enters `outsideSafeArea`, which camera frames do not clear; only `returnedToSafeArea` does, and a paused engine stays paused.

## Automation (Bryan)

`AutomationEngine` runs `scanning -> guiding -> onTarget -> completed -> scanning`. Details that matter for the demo:

- A target that drops out of the frame keeps its last haptic cue for `lostTargetTimeout` (1.2 s), then haptics stop and the engine goes back to scanning. It never announces, confirms or completes against a remembered box.
- A finished target is excluded for `completedCooldown` (8 s), so "done" moves on to the next step instead of guiding the finger back to the same button.
- On target, the guidance pulse train stops and a double tap plays once; hovering does not buzz.
- `GuidanceView` shows the step huge and yellow on black, a second line for carers ("Hold still", "Follow the pulses"), a goal field, and one big Pause/Resume button.

## Targets

| Metric | Target | Where it is measured |
|---|---|---|
| Frame-delta analysis | < 1 ms p50, < 3 ms p95 (CI debug build) | `FrameDeltaTests.benchmarkUnderBudget` |
| Local inference (object + hand) | < 12 ms on A17-class | `LocalVisionEngine.p95Ms`, on device |
| Local end-to-end (frame to haptic) | < 15 ms | on device |
| Audio / haptic cue | < 300 ms | on device |
| Static frames skipped | ~99% in a still scene | `FrameDeltaStats.skipRatio` |
| Edge compute share | > 95% of resolutions local | `ReasoningOutcome.source` |
| Airplane Mode | 100% working, local fallback | `RouterTests.airplaneModeFallsBackLocally` |

Read these honestly:

- **OCR does not fit inside 12 ms.** `VNRecognizeTextRequest` at `.fast` takes roughly 10 to 35 ms, so it runs on every third inferred frame (`ocrEveryNthFrame`). Only object detection and the hand fit inside the 12 ms budget.
- **The cloud path cannot meet 15 ms.** A cloud round trip is hundreds of milliseconds. The < 15 ms target covers only the local path, and the router gives the cloud a hard 2.5 s timeout.
- **"100% Airplane Mode" and "cloud below 85%" conflict, by design.** When the device is offline, low-confidence steps get the best local answer. The response is tagged `localFallback` so telemetry shows how often the cloud was missed.

## Build

```bash
swift build && swift test        # macOS host: pure logic, 69 tests (plus `cd proxy && node --test`: 6)
```

The iOS-only paths (ARKit, the camera, the haptic actuator) are behind `#if canImport(...) && os(iOS)`. The `ios-build` CI job compiles them with `xcodebuild` for the iOS Simulator. Real latency numbers need a device.

### The iOS app (`EchoGuideApp/`)

Open `EchoGuideApp/EchoGuideApp.xcodeproj` in Xcode 16+, set your team, and run it on an iPhone. `AppRuntime.swift` is the only place every engine is built and connected:

- With LiDAR, ARKit owns the camera and `LiDARDepthEngine` feeds the pipeline. Without LiDAR, `CameraFeed` does.
- `PerceptionPipeline` → `SpatialFence` → `AutomationEngine` → haptics, audio, plugins and router.
- The location fence, the caregiver outbox flush (every 30 s when online) and the optional voice loop start here too.

Per-home setup goes in `Application Support/echoguide.json` (plugins, safe areas, starting goal); the bundled `echoguide.sample.json` is the fallback. Secrets (the proxy `device_token`, Home Assistant token, webhook signing key) are read from the Keychain, service `EchoGuide`.

**Model:** run the `export-model` workflow (Actions tab), download the `.mlpackage`, and drop it in `EchoGuideApp/Resources/Models/`. It is compiled on first launch. Without it, the app runs hands, text and barcodes only.

> **License:** Ultralytics YOLO (v8 and 11) is **AGPL-3.0**. Shipping it in a closed-source app requires an Ultralytics Enterprise license, or a switch to a permissively licensed detector. Decide this before any public release.

**On-device benchmark:** enable the `-benchmark` launch argument in the scheme, point the phone at a scene with some movement for 20 s, and read the result on screen. The full JSON is in Documents (visible in the Files app). This is how the < 15 ms local target is checked for real.

**TestFlight:** the `ios-release` workflow (manual) archives with cloud signing and uploads. It needs four repo secrets, listed at the top of `.github/workflows/ios-release.yml`.

## Cloud proxy (`proxy/`)

The only place the Gemini, OpenAI, Deepgram and ElevenLabs keys live. It is zero-dependency Node 20+ (`node server.mjs`, tests with `node --test`).

- Devices send `Authorization: Bearer <device token>`. The proxy stores only SHA-256 hashes of allowed tokens (`DEVICE_TOKEN_SHA256S`).
- Per-device rate limit (default 30 per minute), model allow-list, output capped at 120 tokens, 2 MB body cap, 10 s upstream timeout.
- `/v1/voice/stt-token` mints a 30-second Deepgram token, so the phone opens the speech WebSocket directly and the long-lived key never leaves the server. `/v1/voice/tts` streams ElevenLabs audio back as it arrives.
- Deploy it anywhere that runs Node (Fly, Render, Railway, a small VM) and set `EG_PROXY_BASE_URL` for the app build.

## Voice (optional)

Off by default; the product works without it. With voice on (the `voiceEnabled` setting plus a proxy), Deepgram live speech-to-text understands "find the start button" (narrows guidance to that target), "stop", and any other sentence as a question for the router. ElevenLabs streaming TTS is available through the proxy; on-device speech remains the default so everything works offline.

## Plugins (MCP)

Built-in tools: **Home Assistant** (presses the control for the user through one hub that already integrates thousands of appliances), **caregiver alerts** (signed webhook, idempotent, saved to a disk outbox so an alert raised offline is delivered on reconnect; the user is told "your carer has been told" only once it has actually gone out), and **product lookup** (barcode to product name and allergens via Open Food Facts; QR codes never leave the device). A per-home `PluginManifest` JSON sets all of this up without a code change, and secrets come from the Keychain, never from the manifest.

`PluginRegistry` serves MCP `initialize`, `tools/list` and `tools/call` over JSON-RPC 2.0. `MCPHTTPClient` connects to remote MCP servers over Streamable HTTP. An example FastMCP server is in `plugins/smart_home_server.py`.

Remote tools are registered as `physical` unless told otherwise. A physical tool runs only after the user holds their finger on the target (0.8 s dwell).

## Not built yet

- The OpenAI Realtime API (multi-turn). The router uses one-shot Chat Completions.
- A care-provider setup flow that writes `echoguide.json` and the Keychain secrets (today: by hand or MDM).
- Real measurements: run the on-device benchmark on an A17-class iPhone and put the numbers in the targets table.
EOF_AVAE

cat > 'plugins/smart_home_server.py' <<'EOF_AVAE'
# Example FastMCP plugin server (owner: Maxwell). Not run in CI.
#   pip install fastmcp
#   fastmcp run plugins/smart_home_server.py --transport http --port 8765
# Register in the app with MCPHTTPClient(endpoint: http://<host>:8765/mcp) and
# claims such as ["microwave_start": ToolClaim(textContains: ["start"])].
from fastmcp import FastMCP

mcp = FastMCP("echoguide-smart-home")


@mcp.tool
def microwave_start(text: str = "") -> str:
    """Start the paired smart microwave."""
    # Call the appliance vendor API here.
    return "Microwave started."


@mcp.tool
def notify_caregiver(region: str) -> str:
    """Tell the caregiver the user left a safe area."""
    # Send SMS / push via your provider here.
    return f"Carer told: left {region}."


if __name__ == "__main__":
    mcp.run(transport="http", port=8765)
EOF_AVAE

cat > 'proxy/package.json' <<'EOF_AVAE'
{
  "name": "echoguide-proxy",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "description": "Holds the cloud API keys for EchoGuide devices. Zero dependencies.",
  "engines": { "node": ">=20" },
  "scripts": {
    "start": "node server.mjs",
    "test": "node --test"
  }
}
EOF_AVAE

cat > 'proxy/server.mjs' <<'EOF_AVAE'
// Owner: Maxwell. The only place the Gemini, OpenAI, Deepgram and ElevenLabs
// keys live. Devices authenticate with a per-device bearer token; the proxy
// checks it against SHA-256 hashes (so a leaked env file does not leak device
// tokens), rate-limits per device, allow-lists models, clamps output length
// and caps body size, then forwards to the provider.
//
// Env:
//   PORT                       default 8787
//   DEVICE_TOKEN_SHA256S       comma-separated hex sha256 of allowed device tokens
//   GEMINI_API_KEY, OPENAI_API_KEY, DEEPGRAM_API_KEY, ELEVENLABS_API_KEY
//   ALLOWED_MODELS             default "gemini-2.5-flash,gpt-4o"
//   RATE_PER_MINUTE            default 30 requests per device per minute
//   *_BASE                     upstream overrides (tests)

import { createServer } from 'node:http';
import { createHash, timingSafeEqual } from 'node:crypto';

export function createProxy(env = process.env) {
  const tokenHashes = (env.DEVICE_TOKEN_SHA256S ?? '').split(',').map(s => s.trim().toLowerCase()).filter(Boolean)
    .map(h => Buffer.from(h, 'hex'));
  const allowedModels = new Set((env.ALLOWED_MODELS ?? 'gemini-2.5-flash,gpt-4o').split(',').map(s => s.trim()));
  const ratePerMinute = Number(env.RATE_PER_MINUTE ?? 30);
  const maxBody = 2 * 1024 * 1024; // one low-detail JPEG plus prompt
  const base = {
    gemini: env.GEMINI_BASE ?? 'https://generativelanguage.googleapis.com',
    openai: env.OPENAI_BASE ?? 'https://api.openai.com',
    deepgram: env.DEEPGRAM_BASE ?? 'https://api.deepgram.com',
    eleven: env.ELEVENLABS_BASE ?? 'https://api.elevenlabs.io',
  };
  const buckets = new Map(); // device hash -> { tokens, at }

  function authorize(req) {
    const m = /^Bearer (.+)$/.exec(req.headers.authorization ?? '');
    if (!m) return null;
    const digest = createHash('sha256').update(m[1]).digest();
    return tokenHashes.some(h => h.length === digest.length && timingSafeEqual(h, digest)) ? digest.toString('hex') : null;
  }

  function allow(device) {
    const now = Date.now();
    const b = buckets.get(device) ?? { tokens: ratePerMinute, at: now };
    b.tokens = Math.min(ratePerMinute, b.tokens + ((now - b.at) / 60000) * ratePerMinute);
    b.at = now;
    if (b.tokens < 1) { buckets.set(device, b); return false; }
    b.tokens -= 1;
    buckets.set(device, b);
    return true;
  }

  async function readJSON(req) {
    let size = 0;
    const chunks = [];
    for await (const c of req) {
      size += c.length;
      if (size > maxBody) throw Object.assign(new Error('body too large'), { status: 413 });
      chunks.push(c);
    }
    try { return chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}; }
    catch { throw Object.assign(new Error('invalid json'), { status: 400 }); }
  }

  function send(res, status, obj) {
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(JSON.stringify(obj));
  }

  async function forward(res, url, init) {
    const upstream = await fetch(url, { ...init, signal: AbortSignal.timeout(10000) });
    const headers = { 'content-type': upstream.headers.get('content-type') ?? 'application/octet-stream' };
    res.writeHead(upstream.status, headers);
    if (!upstream.body) return res.end();
    for await (const chunk of upstream.body) res.write(chunk); // streams TTS audio as it arrives
    res.end();
  }

  const clamp = (n, max) => Math.min(Number.isFinite(n) ? n : max, max);

  return createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://proxy');
      if (req.method === 'GET' && url.pathname === '/healthz') return send(res, 200, { ok: true });
      if (req.method !== 'POST') return send(res, 405, { error: 'method not allowed' });

      const device = authorize(req);
      if (!device) return send(res, 401, { error: 'unauthorized' });
      if (!allow(device)) return send(res, 429, { error: 'rate limited' });

      const gemini = /^\/v1beta\/models\/([\w.-]+):generateContent$/.exec(url.pathname);
      if (gemini) {
        if (!allowedModels.has(gemini[1])) return send(res, 400, { error: 'model not allowed' });
        const body = await readJSON(req);
        body.generationConfig = { ...(body.generationConfig ?? {}), maxOutputTokens: clamp(body.generationConfig?.maxOutputTokens, 120) };
        return forward(res, `${base.gemini}/v1beta/models/${gemini[1]}:generateContent`, {
          method: 'POST', headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY ?? '' },
          body: JSON.stringify({ contents: body.contents, generationConfig: body.generationConfig }),
        });
      }

      if (url.pathname === '/v1/chat/completions') {
        const body = await readJSON(req);
        if (!allowedModels.has(body.model)) return send(res, 400, { error: 'model not allowed' });
        return forward(res, `${base.openai}/v1/chat/completions`, {
          method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${env.OPENAI_API_KEY ?? ''}` },
          body: JSON.stringify({ model: body.model, messages: body.messages, max_tokens: clamp(body.max_tokens, 120), temperature: body.temperature ?? 0.2 }),
        });
      }

      if (url.pathname === '/v1/voice/stt-token') {
        // Short-lived Deepgram token: the device opens the WebSocket directly,
        // the long-lived key never leaves this server.
        return forward(res, `${base.deepgram}/v1/auth/grant`, {
          method: 'POST', headers: { 'content-type': 'application/json', authorization: `Token ${env.DEEPGRAM_API_KEY ?? ''}` },
          body: JSON.stringify({ ttl_seconds: 30 }),
        });
      }

      if (url.pathname === '/v1/voice/tts') {
        const body = await readJSON(req);
        const text = String(body.text ?? '').slice(0, 400);
        const voice = String(body.voice_id ?? '');
        if (!text || !/^[A-Za-z0-9]+$/.test(voice)) return send(res, 400, { error: 'text and voice_id required' });
        return forward(res, `${base.eleven}/v1/text-to-speech/${voice}/stream?output_format=pcm_16000`, {
          method: 'POST', headers: { 'content-type': 'application/json', 'xi-api-key': env.ELEVENLABS_API_KEY ?? '' },
          body: JSON.stringify({ text, model_id: 'eleven_flash_v2_5' }),
        });
      }

      return send(res, 404, { error: 'not found' });
    } catch (err) {
      if (!res.headersSent) send(res, err.status ?? 502, { error: err.status ? err.message : 'upstream error' });
      else res.end();
    }
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.PORT ?? 8787);
  createProxy().listen(port, () => console.log(`echoguide proxy on :${port}`));
}
EOF_AVAE

cat > 'proxy/server.test.mjs' <<'EOF_AVAE'
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { createProxy } from './server.mjs';

const TOKEN = 'device-secret';
let upstream, proxy, proxyURL, seen = [];

before(async () => {
  upstream = createServer(async (req, res) => {
    let body = '';
    for await (const c of req) body += c;
    seen.push({ url: req.url, headers: req.headers, body: body ? JSON.parse(body) : null });
    if (req.url.startsWith('/v1/text-to-speech/')) {
      res.writeHead(200, { 'content-type': 'audio/pcm' });
      res.write(Buffer.alloc(3200)); res.end(Buffer.alloc(800));
      return;
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(req.url === '/v1/auth/grant' ? { access_token: 'jwt', expires_in: 30 } : { ok: true }));
  });
  await new Promise(r => upstream.listen(0, r));
  const u = `http://127.0.0.1:${upstream.address().port}`;
  proxy = createProxy({
    DEVICE_TOKEN_SHA256S: createHash('sha256').update(TOKEN).digest('hex'),
    GEMINI_API_KEY: 'gk', OPENAI_API_KEY: 'ok', DEEPGRAM_API_KEY: 'dk', ELEVENLABS_API_KEY: 'ek',
    GEMINI_BASE: u, OPENAI_BASE: u, DEEPGRAM_BASE: u, ELEVENLABS_BASE: u, RATE_PER_MINUTE: '12',
  });
  await new Promise(r => proxy.listen(0, r));
  proxyURL = `http://127.0.0.1:${proxy.address().port}`;
});

after(() => { upstream.close(); proxy.close(); });

const post = (path, body, token = TOKEN) => fetch(proxyURL + path, {
  method: 'POST', headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
  body: JSON.stringify(body),
});

test('rejects missing or wrong device token', async () => {
  assert.equal((await post('/v1/chat/completions', {}, null)).status, 401);
  assert.equal((await post('/v1/chat/completions', {}, 'nope')).status, 401);
});

test('gemini: adds key, clamps tokens, drops extra fields', async () => {
  seen = [];
  const r = await post('/v1beta/models/gemini-2.5-flash:generateContent', { contents: [{ parts: [{ text: 'hi' }] }], generationConfig: { maxOutputTokens: 9999 }, tools: ['x'] });
  assert.equal(r.status, 200);
  assert.equal(seen[0].headers['x-goog-api-key'], 'gk');
  assert.equal(seen[0].body.generationConfig.maxOutputTokens, 120);
  assert.equal(seen[0].body.tools, undefined);
});

test('model allow-list', async () => {
  assert.equal((await post('/v1beta/models/gemini-ultra:generateContent', {})).status, 400);
  assert.equal((await post('/v1/chat/completions', { model: 'o3-pro', messages: [] })).status, 400);
});

test('deepgram grant returns a short-lived token', async () => {
  seen = [];
  const r = await post('/v1/voice/stt-token', {});
  assert.deepEqual(await r.json(), { access_token: 'jwt', expires_in: 30 });
  assert.equal(seen[0].headers.authorization, 'Token dk');
  assert.equal(seen[0].body.ttl_seconds, 30);
});

test('tts streams audio bytes through', async () => {
  const r = await post('/v1/voice/tts', { text: 'Microwave started.', voice_id: 'abc123' });
  assert.equal(r.status, 200);
  assert.equal((await r.arrayBuffer()).byteLength, 4000);
  assert.equal((await post('/v1/voice/tts', { text: 'x', voice_id: '../admin' })).status, 400);
});

test('rate limits per device', async () => {
  let last;
  for (let i = 0; i < 20; i++) last = await post('/v1/chat/completions', { model: 'gpt-4o', messages: [] });
  assert.equal(last.status, 429);
});
EOF_AVAE

git init -q -b main
git add -A
git commit -q -m "Initial AutoVision Audio Engine scaffold"

if git remote | grep -q "^origin$"; then git remote set-url origin "$REMOTE_URL"; else git remote add origin "$REMOTE_URL"; fi
git push -u origin main
echo "Pushed to $REMOTE_URL"
