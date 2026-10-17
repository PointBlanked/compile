#!/usr/bin/env bash
# Recreates the AutoVision Audio Engine repo from scratch, commits, and pushes.
# Usage: ./setup_repo.sh [target-dir]   (REMOTE_URL overrides the GitHub remote)
set -euo pipefail

TARGET="${1:-auto-vision-audio-engine}"
REMOTE_URL="${REMOTE_URL:-https://github.com/bbyycc1/compile.git}"

mkdir -p "$TARGET"
cd "$TARGET"

mkdir -p .github .github/workflows EchoGuide/Core/Audio EchoGuide/Core/Automation EchoGuide/Core/Camera EchoGuide/Core/Cognitive EchoGuide/Core/Contracts EchoGuide/Core/Depth EchoGuide/Core/Fence EchoGuide/Core/Haptics EchoGuide/Core/Plugins EchoGuide/Core/Router EchoGuide/Core/Vision EchoGuide/UI EchoGuideTests plugins

cat > '.github/CODEOWNERS' <<'EOF_AVAE'
# Each path has one owner. PRs touching a path need that owner's review.
/EchoGuide/Core/Camera/      @james
/EchoGuide/Core/Vision/      @james
/EchoGuide/Core/Fence/       @james
/EchoGuide/Core/Haptics/     @lily
/EchoGuide/Core/Depth/       @lily
/EchoGuide/Core/Audio/       @lily
/EchoGuide/Core/Automation/  @bryan
/EchoGuide/Core/Cognitive/   @bryan
/EchoGuide/UI/               @bryan
/EchoGuide/Core/Plugins/     @maxwell
/EchoGuide/Core/Router/      @maxwell
/EchoGuideTests/             @maxwell
/.github/                    @maxwell
/Package.swift               @maxwell
/plugins/                    @maxwell
# Shared contracts: everyone signs off.
/EchoGuide/Core/Contracts/   @james @lily @bryan @maxwell
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
          xcodebuild build \
            -scheme EchoGuide \
            -destination 'generic/platform=iOS Simulator' \
            -skipPackagePluginValidation \
            CODE_SIGNING_ALLOWED=NO | tail -n 40
          exit ${PIPESTATUS[0]}
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
// Owner: Lily. Directional earcons through AVAudioEngine's environment node
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
    private var started = false

    public init() {}

    private func startIfNeeded() {
        guard !started else { return }
        engine.attach(environment)
        engine.attach(player)
        // Mono source into the environment node is what makes it positional.
        engine.connect(player, to: environment, format: format)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        player.renderingAlgorithm = .auto
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        pingBuffer = Self.makePing(format: format)
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

    public func ping(azimuth: Float, elevation: Float) async {
        startIfNeeded()
        guard started, let pingBuffer else { return }
        let p = SpatialAudioMath.position(azimuth: azimuth, elevation: elevation)
        player.position = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
        player.scheduleBuffer(pingBuffer, at: nil, options: .interrupts, completionHandler: nil)
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
    private var completedLabel: String?
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
        completedLabel = nil
    }

    public func start() { transition(.scanning) }

    public func stop() async {
        transition(.idle)
        await haptics.stop()
    }

    // MARK: - Input

    public func ingest(_ frame: VisionFrameResult, fence: FenceEvent? = nil) async {
        guard state != .idle else { return }
        let now = frame.timestamp

        if let fence, await handle(fence, at: now) { return }

        guard let step = isolation.isolate(frame) else {
            if now - lastSeenAt > config.lostTargetTimeout, state != .scanning {
                onTargetSince = nil
                await haptics.stop()
                transition(.scanning)
            }
            return
        }
        lastSeenAt = now

        // Finished target stays finished until the finger moves off it.
        if step.targetLabel == completedLabel {
            if case .align(let dx, let dy) = step.guidance, (dx * dx + dy * dy).squareRoot() > Alignment.tolerance * 3 {
                completedLabel = nil
            } else {
                return
            }
        }

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
            await complete(step)
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

    private func complete(_ step: ActionStep) async {
        onTargetSince = nil
        completedLabel = step.targetLabel

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
        await haptics.stop()
    }

    // MARK: - Fence

    /// Returns true when the fence event takes over this frame.
    private func handle(_ event: FenceEvent, at now: TimeInterval) async -> Bool {
        switch event {
        case .breached(let zone):
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
            transition(.warning(region))
            return true
        case .returnedToSafeArea(let region):
            await audio.speak("You are back at \(region).", azimuth: 0)
            transition(.scanning)
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
// Owner: James. Continuous back-camera feed for devices or modes without
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
// Owner: James. Decides, per camera frame, whether full inference is worth
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

    private var current: Detection?
    private var candidate: Detection?
    private var candidateFrames = 0

    public init(config: CognitiveConfig = CognitiveConfig(), goal: String? = nil) {
        self.config = config
        self.goal = goal
    }

    public mutating func reset() {
        current = nil
        candidate = nil
        candidateFrames = 0
    }

    /// The one step for this frame, or nil when nothing is settled yet.
    public mutating func isolate(_ frame: VisionFrameResult) -> ActionStep? {
        let anchor = frame.fingertip?.box.mid ?? .center
        let eligible = frame.targets.filter(isEligible)
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
            candidate = best
            candidateFrames = 1
        }
        candidate = best

        if candidateFrames >= config.settleFrames || current == nil && config.settleFrames <= 1 {
            current = best
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
        if config.ignoredLabels.contains(d.label) { return false }
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
// review from all four owners (see .github/CODEOWNERS).
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
// Owner: Lily. 60 FPS ARKit smoothedSceneDepth. Keeps only the latest depth
// map (256x192 Float32 metres + confidence) and answers point queries with a
// confidence-filtered 3x3 median, so one noisy pixel never moves a cue.
// While running, ARKit owns the back camera: the captured image of every
// ARFrame is forwarded to `onFrame` so James's frame-delta path still runs.

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
// Owner: James. The digital fence, in two layers:
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
    /// nil when unknown (then the 2-D test alone decides). Returns the most
    /// severe event: a breach beats an approach.
    public func evaluate(_ frame: VisionFrameResult, handDepth: Float? = nil, zoneDepth: Float? = nil) -> FenceEvent? {
        guard let tip = frame.fingertip?.box.mid else { return nil }
        var approaching: FenceEvent?

        for zone in zones {
            for rect in rects(for: zone, in: frame) {
                let depthGap: Float? = {
                    guard let h = handDepth, let z = zoneDepth else { return nil }
                    return abs(z - h)
                }()

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
    public var exitDwell: TimeInterval = 45
    /// Fixes worse than this are ignored (indoor GPS can be 100 m+ off).
    public var maxAccuracyMetres: Double = 65

    private(set) var insideArea: String?
    private var outsideSince: TimeInterval?
    private var reportedExit = false
    private var lastArea: String?

    public init(areas: [SafeArea]) { self.areas = areas }

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
// Owner: Lily. Turns "target minus fingertip" into transient CoreHaptics
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
    private var lastConfirm: TimeInterval = 0

    public init() {}

    public var isSupported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

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
        // Debounce: hovering on target should not buzz continuously.
        let now = Date().timeIntervalSince1970
        guard now - lastConfirm > 1.0 else { return }
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

    private func loopEnded() { loop = nil }

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

    public init(labels: Set<String> = [], textContains: [String] = [], barcodePrefixes: [String] = []) {
        self.labels = labels
        self.textContains = textContains
        self.barcodePrefixes = barcodePrefixes
    }

    func claims(_ d: Detection) -> Bool {
        if labels.contains(d.label) { return true }
        guard let text = d.text?.lowercased() else { return false }
        if d.kind == .barcode { return barcodePrefixes.contains { text.hasPrefix($0.lowercased()) } }
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
    public func registerRemote(_ client: MCPHTTPClient, claims: [String: ToolClaim], sideEffects: [String: ToolSideEffect] = [:]) async throws {
        for remote in try await client.listTools() {
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

    public init(proxyBase: URL, model: String = "gemini-2.5-flash", deviceToken: @escaping @Sendable () async -> String?) {
        self.proxyBase = proxyBase
        self.model = model
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
        let json = try await HTTP.postJSON(url, body: body, token: await deviceToken())
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

    public init(proxyBase: URL, model: String = "gpt-4o", deviceToken: @escaping @Sendable () async -> String?) {
        self.proxyBase = proxyBase
        self.model = model
        self.deviceToken = deviceToken
    }

    public func answer(_ q: ReasoningQuery, includeImage: Bool) async throws -> String {
        var content: [[String: Any]] = [["type": "text", "text": Prompt.text(q)]]
        if includeImage, let jpeg = q.jpeg {
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())", "detail": "low"]])
        }
        let body: [String: Any] = ["model": model, "max_tokens": 40, "temperature": 0.2, "messages": [["role": "user", "content": content]]]
        let json = try await HTTP.postJSON(proxyBase.appendingPathComponent("v1/chat/completions"), body: body, token: await deviceToken())
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

enum HTTP {
    static func postJSON(_ url: URL, body: [String: Any], token: String?) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
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

cat > 'EchoGuide/Core/Vision/LocalVisionEngine.swift' <<'EOF_AVAE'
// Owner: James. On-device inference for frames FrameDeltaEngine let through:
//   * YOLOv8n / YOLO11n INT8 Core ML (exported with nms=True) on the Neural Engine
//   * VNDetectHumanHandPoseRequest for the index fingertip (target alignment)
//   * VNRecognizeTextRequest, .fast level, offline (only on OCR frames)
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
    /// Keep at most this many detections; cognitive isolation picks one anyway.
    public var maxDetections = 12
    public var budgetMs: Double = 12

    public init() {}
}

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
#endif
EOF_AVAE

cat > 'EchoGuide/UI/GuidanceView.swift' <<'EOF_AVAE'
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

// MARK: - James: frame delta

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

    @Test func benchmarkUnderOneMillisecond() {
        let e = FrameDeltaEngine()
        let a = lumaFrame(width: 1920, height: 1440), b = lumaFrame(width: 1920, height: 1440, square: (300, 300, 400, 200))
        var window = LatencyWindow(capacity: 500)
        for i in 0..<500 {
            _ = analyze(e, i % 2 == 0 ? a : b, t: Double(i) / 60, width: 1920, height: 1440)
            window.record(e.lastAnalysisMs)
        }
        // Debug builds on shared CI runners; the budget on device is far lower.
        #expect(window.percentile(0.95) < 1.0)
    }
}

// MARK: - James: vision geometry + digital fence

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

// MARK: - Lily: haptics, depth, audio math

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

cat > 'Package.swift' <<'EOF_AVAE'
// swift-tools-version: 5.10
// Owner: Maxwell (infrastructure). One target per co-founder so nobody edits
// another person's target, plus a small shared Contracts target that every
// engine depends on and nobody else imports across.
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
        // Shared types and protocols. Changes here need review from all four owners.
        .target(
            name: "EchoGuideContracts",
            path: "EchoGuide/Core/Contracts"
        ),
        // James: camera feed, frame delta, local vision, digital fence.
        .target(
            name: "EchoGuideVision",
            dependencies: ["EchoGuideContracts"],
            path: "EchoGuide/Core",
            exclude: ["Contracts", "Haptics", "Depth", "Audio", "Automation", "Cognitive", "Plugins", "Router"],
            sources: ["Camera", "Vision", "Fence"]
        ),
        // Lily: haptics, LiDAR depth, spatial audio.
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

Each person owns one SwiftPM target. Code crosses targets only through `EchoGuideContracts`, so two people never edit the same file. Ownership is enforced in `.github/CODEOWNERS`.

| Owner | Role | Target | Paths | Files |
|---|---|---|---|---|
| James | ML & edge vision | `EchoGuideVision` | `EchoGuide/Core/Camera/`, `Vision/`, `Fence/` | `FrameDeltaEngine`, `CameraFeed`, `LocalVisionEngine`, `DigitalFenceEngine` |
| Lily | Haptics, LiDAR, audio | `EchoGuideSpatial` | `EchoGuide/Core/Haptics/`, `Depth/`, `Audio/` | `SpatialHapticEngine`, `LiDARDepthEngine`, `SpatialAudioEngine` |
| Bryan | Accessibility & cognitive UX | `EchoGuideAutomation` | `EchoGuide/Core/Automation/`, `Cognitive/`, `EchoGuide/UI/` | `AutomationEngine`, `CognitiveTaskIsolation`, `GuidanceView` |
| Maxwell | Infra, router, plugins | `EchoGuideInfra` | `EchoGuide/Core/Plugins/`, `Router/`, `.github/`, `EchoGuideTests/`, `Package.swift`, `plugins/` | `PluginRegistry`, `CloudReasoningRouter`, CI, tests |
| All four | Shared contracts | `EchoGuideContracts` | `EchoGuide/Core/Contracts/` | `Contracts.swift` (needs four approvals) |

### Branches

`feature/james-vision`, `feature/james-fence`, `feature/lily-haptics`, `feature/bryan-automation`, `feature/maxwell-plugins`. Each branch opens a PR into `main`. CI must pass and the owner of every path the PR touches must approve.

## Digital fence (James)

There are two layers. Each one only reports a `FenceEvent`, and `AutomationEngine` decides how the user hears or feels it.

- **Spatial fence:** hazard zones the camera can see, such as the hob or a knife. A zone follows a detected label or covers a fixed part of the frame. When the fingertip comes near a zone, the user gets "Careful" and a warning pulse. When it enters the zone, they get "Stop" and the warning preempts all other guidance. If LiDAR is available, its depth reading rules out cases where the hand only overlaps the zone on screen but is not near it.
- **Location fence:** safe areas for dementia wandering. A position must stay outside the area for 45 s before it counts as leaving, and fixes with poor accuracy are ignored. The event is reported once, and a `notify_caregiver` MCP tool is called if one is registered.

## Targets

| Metric | Target | Where it is measured |
|---|---|---|
| Frame-delta analysis | < 1 ms p95 (CI debug build) | `FrameDeltaTests.benchmarkUnderOneMillisecond` |
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
swift build && swift test        # macOS host: pure logic, 36 tests
```

The iOS-only paths (ARKit, the camera, the haptic actuator) are behind `#if canImport(...) && os(iOS)`. The `ios-build` CI job compiles them with `xcodebuild` for the iOS Simulator. Real latency numbers need a device.

### What the app target has to supply

This package is the engine. An Xcode iOS app target links the `EchoGuide` library and does the following:

1. Bundles a YOLO Core ML model and passes it to `LocalVisionEngine(modelURL:)`. Export it with `yolo export model=yolo11n.pt format=coreml int8=True nms=True`. Models are git-ignored.
2. Sets up the camera feed. With LiDAR, it runs `LiDARDepthEngine` and feeds its `onFrame` into `FrameDeltaEngine`. ARKit owns the camera, so `CameraFeed` cannot run at the same time. Without LiDAR, it uses `CameraFeed`.
3. Runs each triggered frame through `LocalVisionEngine.process`, then `SpatialFence.evaluate`, then `AutomationEngine.ingest(_:fence:)`.
4. Adds `Info.plist` keys: `NSCameraUsageDescription` and `NSLocationAlwaysAndWhenInUseUsageDescription`, plus the `location` background mode for the location fence.
5. Points `GeminiProvider` / `OpenAIProvider` at a proxy you run. No API keys ship in the app.

## Plugins (MCP)

`PluginRegistry` serves MCP `initialize`, `tools/list` and `tools/call` over JSON-RPC 2.0. `MCPHTTPClient` connects to remote MCP servers over Streamable HTTP. An example FastMCP server is in `plugins/smart_home_server.py`.

Remote tools are registered as `physical` unless told otherwise. A physical tool runs only after the user holds their finger on the target (0.8 s dwell).

## Not built yet

- The WebSocket voice loop (Deepgram STT / ElevenLabs TTS). On-device `AVSpeechSynthesizer` is used for now, so the app works offline.
- The OpenAI Realtime API (multi-turn). The router uses one-shot Chat Completions.
- Barcode detection (`VNDetectBarcodesRequest`). The contract and plugin matching already support it.
- The Xcode app target and the bundled model.
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

git init -q -b main
git add -A
git commit -q -m "Initial AutoVision Audio Engine scaffold"

if git remote | grep -q "^origin$"; then git remote set-url origin "$REMOTE_URL"; else git remote add origin "$REMOTE_URL"; fi
git push -u origin main
echo "Pushed to $REMOTE_URL"
