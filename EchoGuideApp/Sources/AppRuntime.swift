// Owner: Maxwell. Composition root: the only place every engine is built and
// wired together. Engines never see each other; they meet here through the
// protocols in EchoGuideContracts.
//
//   LiDAR (ARKit) or CameraFeed -> PerceptionPipeline -> SpatialFence
//        -> AgentCore (Explore / Read / Describe)
//        -> AutomationEngine (Find: finger guidance, tool press)
//   Speech, haptics and cloud calls pass through observers that drive the
//   on-screen captions and the benchmark recorder.

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Observation
import os
import EchoGuideAutomation
import EchoGuideContracts
import EchoGuideInfra
import EchoGuideSpatial
import EchoGuideVision

private let log = Logger(subsystem: "app.echoguide", category: "runtime")

extension VoiceGoalListener: GoalListening {}

@MainActor
@Observable
final class AppRuntime {
    let guidance = GuidanceModel(listener: VoiceGoalListener())
    let trials = TrialRecorder(storeURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("trials.json"))

    private(set) var mode: AgentMode = .explore
    private(set) var caption = ""
    /// The last few sentences spoken, newest last, for the on-screen ticker.
    private(set) var captions: [String] = []
    /// What the phone perceives right now, for the overlay (about 15 Hz).
    private(set) var hud = HUDFrame()
    private var lastHUDAt: TimeInterval = -.infinity
    /// Width / height of the upright camera image the overlay maps onto.
    var imageAspect: CGFloat { hasLiDAR ? 3.0 / 4.0 : 9.0 / 16.0 }
    private(set) var started = false
    private(set) var hasLiDAR = false
    private(set) var hasModel = false
    let cloudConfigured = AppSettings.proxyBase != nil
    /// A vision-language model is reachable (key proxy or self-hosted server).
    private(set) var visionConfigured = false
    private(set) var online = false
    private(set) var cameraError: String?
    private(set) var benchmarkSummary: String?
    private(set) var describing = false

    private(set) var lidar: LiDARDepthEngine?
    private(set) var camera: CameraFeed?
    private var agent: AgentCore?
    private var automation: AutomationEngine?
    private var pipeline: PerceptionPipeline?
    private var vision: LocalVisionEngine?
    private let latest = LatestFrame()
    private let motionGate = DeviceMotionGate()
    private var background: [Task<Void, Never>] = []

    var statusLine: String {
        var parts: [String] = []
        parts.append(hasLiDAR ? "LiDAR" : "Camera")
        parts.append(hasModel ? "objects on" : "no object model")
        if visionConfigured && online {
            parts.append(cloudConfigured ? (AppSettings.imageConsent ? "cloud photos on" : "cloud text only") : "scene AI on")
        } else {
            parts.append("on-device only")
        }
        return parts.joined(separator: " · ")
    }

    func start() async {
        guard !started else { return }
        started = true
        let config = AppConfig.load()

        // Perception (local, always).
        let modelURL = ModelStore.locate()
        hasModel = modelURL != nil
        if modelURL == nil { log.warning("No YOLO model bundled; running hands, text and barcodes only") }
        let vision: LocalVisionEngine
        do {
            vision = try LocalVisionEngine(modelURL: modelURL)
        } catch {
            log.error("Model failed to load: \(error.localizedDescription, privacy: .public)")
            hasModel = false
            vision = try! LocalVisionEngine(modelURL: nil)
        }
        self.vision = vision
        let lidar = LiDARDepthEngine.isSupported ? LiDARDepthEngine() : nil
        self.lidar = lidar
        hasLiDAR = lidar != nil

        // Output, observed for captions and benchmarks.
        let speech: SpeechSynthesizing? = config.kokoroURL.map { KokoroSpeechProvider(baseURL: $0) }
        let trials = self.trials
        let audio = ObservedAudio(SpatialAudioEngine(speech: speech)) { [weak self] text in
            Task { @MainActor in self?.noteCaption(text) }
            Task { await trials.noteSpoken() }
        }
        let haptics = ObservedHaptics(SpatialHapticEngine()) { Task { await trials.noteHaptic() } }

        // Cloud (optional) and tools.
        let connectivity = PathConnectivity()
        let deviceToken: @Sendable () async -> String? = { Keychain.read("device_token") }
        var routerConfig = CloudRouterConfig()
        // Photos to a server you run yourself need no separate consent; a
        // third-party proxy keeps the opt-in toggle.
        routerConfig.imageConsent = AppSettings.imageConsent || (AppSettings.proxyBase == nil && config.visionURL != nil)
        routerConfig.timeout = 8
        let provider: ReasoningProvider?
        if let proxy = AppSettings.proxyBase {
            provider = GeminiProvider(proxyBase: proxy, deviceToken: deviceToken)
        } else if let vision = config.visionURL {
            provider = OpenAIProvider(proxyBase: vision, model: "vlm", deviceToken: { nil })
        } else {
            provider = nil
        }
        visionConfigured = provider != nil
        let router = ObservedRouter(CloudReasoningRouter(config: routerConfig, provider: provider, connectivity: connectivity)) {
            Task { await trials.noteCloudCall() }
        }

        let registry = PluginRegistry()
        let manifest = config.plugins ?? (try? PluginManifest.load(Data(#"{"productLookup":true}"#.utf8)))
        if let manifest { await registry.install(manifest, secrets: { Keychain.read($0) }) }

        // Decisions.
        let latestForTask = self.latest
        var automationConfig = AutomationConfig()
        automationConfig.requiresGoal = true // Find guides only to what the user asked for
        let automation = AutomationEngine(haptics: haptics, audio: audio, depth: lidar, router: router, tools: registry,
                                          config: automationConfig, jpegProvider: { box in latestForTask.jpeg(maxSide: 512, crop: box) })
        self.automation = automation
        guidance.bind(to: automation)
        await automation.setGoal(config.goal)
        // OCR correction gets a text-only model when configured: it is faster
        // and better at it than the vision model, and it never needs the photo.
        var textRouter: ReasoningRouting? = nil
        if let text = config.textURL {
            var textConfig = CloudRouterConfig()
            textConfig.timeout = 3
            textRouter = CloudReasoningRouter(config: textConfig, provider: OpenAIProvider(proxyBase: text, model: "text", deviceToken: { nil }), connectivity: connectivity)
        }
        let latestForScene = self.latest
        let motionGate = self.motionGate
        motionGate.start()
        let agent = AgentCore(audio: audio, haptics: haptics, depth: lidar, router: router, textRouter: textRouter,
                              jpegProvider: { box in latestForScene.jpeg(maxSide: box == nil ? 512 : 320, crop: box) },
                              cameraMoving: { motionGate.isMoving })
        self.agent = agent
        // What the mic heard: a question about the recent past is answered
        // from the agent's memory; anything else becomes the Find goal.
        guidance.interpret = { heard in
            if ObservationMemory.isRecallQuestion(heard) {
                return .answered(await agent.recall(heard))
            }
            if let goal = GoalPhraseParser.goal(from: heard) { return .goal(goal) }
            return .nothing
        }

        // Pipeline: frame -> detections -> fence -> agent (and automation in Find).
        let fence = (config.fence ?? FenceConfig()).spatialFence
        let pipeline = PerceptionPipeline(vision: vision) { [weak self] result, _ in
            // Depth is sampled per zone, so two hazards at different distances are judged separately.
            let event = await fence.evaluate(result, depth: lidar)
            Task { @MainActor in self?.publishHUD(result, fence: event) }
            if await agent.ingest(result, fence: event) {
                await automation.ingest(result, fence: event)
            }
        }
        self.pipeline = pipeline

        // Camera: ARKit owns it when LiDAR is present, otherwise AVCapture.
        let latest = self.latest
        if let lidar {
            lidar.onFrame = { frame in
                latest.set(frame)
                pipeline.submit(frame)
            }
            lidar.start()
        } else {
            let camera = CameraFeed()
            do {
                try camera.start { frame in
                    latest.set(frame)
                    pipeline.submit(frame)
                }
                self.camera = camera
            } catch {
                cameraError = "The camera is not available."
            }
        }

        background.append(Task { [weak self] in
            while !Task.isCancelled {
                let isOnline = await connectivity.isOnline()
                self?.online = isOnline
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        })

        await setMode(.explore, countsAsPrompt: false)
        if AppSettings.isBenchmark { runLatencyBenchmark() }
    }

    func stop() async {
        background.forEach { $0.cancel() }
        lidar?.stop()
        camera?.stop()
        await automation?.stop()
    }

    // MARK: - Screen

    private func noteCaption(_ text: String) {
        caption = text
        captions.append(text)
        if captions.count > 4 { captions.removeFirst(captions.count - 4) }
    }

    /// Throttled to ~15 Hz: the screen does not need every inferred frame.
    private func publishHUD(_ result: VisionFrameResult, fence: FenceEvent?) {
        guard result.timestamp - lastHUDAt >= 0.066 || fence != nil else { return }
        lastHUDAt = result.timestamp
        hud = HUDFrame(detections: result.detections, fence: fence, timestamp: result.timestamp, inferenceMs: result.inferenceMs)
    }

    // MARK: - User actions

    func setMode(_ m: AgentMode, countsAsPrompt: Bool = true) async {
        mode = m
        if countsAsPrompt { await trials.notePrompt() }
        if m == .find { await automation?.start() } else { await automation?.stop() }
        // Cadence per mode: Read looks at a still page often and reads text on
        // every frame; Explore re-checks a still scene each second so nothing
        // that walked in slowly is missed; Find relies on motion (the hand moves).
        switch m {
        case .read:
            pipeline?.setIdleRefresh(0.5)
            await vision?.setTextEveryNthFrame(1)
            await vision?.setTextQuality(accurate: true)
            await vision?.setObjectDetection(enabled: false)
        case .explore:
            pipeline?.setIdleRefresh(1.0)
            await vision?.setTextEveryNthFrame(3)
            await vision?.setTextQuality(accurate: false) // accurate recogniser, sign-sized text only
            await vision?.setObjectDetection(enabled: true)
        case .find:
            pipeline?.setIdleRefresh(3.0)
            await vision?.setTextEveryNthFrame(2)
            await vision?.setTextQuality(accurate: false)
            await vision?.setObjectDetection(enabled: true)
        }
        await agent?.setMode(m)
        pipeline?.forceNextFrame()
    }

    func describe() async {
        guard let agent, !describing else { return }
        describing = true
        defer { describing = false }
        await trials.notePrompt()
        let jpeg = AppSettings.imageConsent ? latest.jpeg() : nil
        await agent.describe(jpeg: jpeg)
    }

    func readNow() async {
        await trials.notePrompt()
        await agent?.readNow()
    }

    // MARK: - Benchmarks

    func startTrial(task: String, mode taskMode: String) async {
        let m: AgentMode = taskMode == "read" ? .read : taskMode == "find" ? .find : .explore
        // Switch first, so the mode announcement does not count as the product's first cue.
        await setMode(m, countsAsPrompt: false)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        await trials.start(task: task, mode: taskMode, offline: !(cloudConfigured && online))
        if taskMode == "describe" { await describe() }
    }

    /// 20 s on the live camera; real on-device latency numbers.
    func runLatencyBenchmark() {
        benchmarkSummary = "Measuring for 20 seconds. Point the camera at a scene with some movement."
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

// MARK: - Observers

/// Forwards speech and reports every sentence (captions, trial counts).
struct ObservedAudio: SpatialAudioCueing {
    let inner: SpatialAudioCueing
    let onSpeak: @Sendable (String) -> Void
    init(_ inner: SpatialAudioCueing, onSpeak: @escaping @Sendable (String) -> Void) {
        self.inner = inner
        self.onSpeak = onSpeak
    }
    func speak(_ text: String, azimuth: Float) async {
        onSpeak(text)
        await inner.speak(text, azimuth: azimuth)
    }
    func ping(azimuth: Float, elevation: Float) async { await inner.ping(azimuth: azimuth, elevation: elevation) }
}

struct ObservedHaptics: HapticCueing {
    let inner: HapticCueing
    let onCue: @Sendable () -> Void
    init(_ inner: HapticCueing, onCue: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.onCue = onCue
    }
    func guide(offset dx: Float, _ dy: Float, distanceMetres: Float?) async {
        onCue()
        await inner.guide(offset: dx, dy, distanceMetres: distanceMetres)
    }
    func confirm() async {
        onCue()
        await inner.confirm()
    }
    func warn() async {
        onCue()
        await inner.warn()
    }
    func stop() async { await inner.stop() }
}

struct ObservedRouter: ReasoningRouting {
    let inner: ReasoningRouting
    let onCloud: @Sendable () -> Void
    init(_ inner: ReasoningRouting, onCloud: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.onCloud = onCloud
    }
    func resolve(_ query: ReasoningQuery) async -> ReasoningOutcome {
        let out = await inner.resolve(query)
        if out.source == .cloud { onCloud() }
        return out
    }
}

/// The newest camera frame, for Describe's photo. One buffer is held at a
/// time, so ARKit is never starved of frames.
final class LatestFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CameraFrame?
    private static let context = CIContext()

    func set(_ f: CameraFrame) { lock.withLock { frame = f } }

    /// Upright, at most `maxSide` px on the long side, ~60% quality: enough for a
    /// multimodal model, small enough to send quickly. `crop` is a normalized
    /// upright rect (the check pipeline sends just the detection).
    func jpeg(maxSide: CGFloat = 768, crop: ImageRect? = nil) -> Data? {
        guard let pb = lock.withLock({ frame?.pixelBuffer }) else { return nil }
        var image = CIImage(cvPixelBuffer: pb).oriented(.right)
        if let c = crop {
            let e = image.extent
            // CIImage is bottom-left origin; ImageRect is top-left.
            let rect = CGRect(x: e.minX + CGFloat(c.x) * e.width, y: e.minY + (1 - CGFloat(c.y + c.height)) * e.height,
                              width: CGFloat(c.width) * e.width, height: CGFloat(c.height) * e.height).intersection(e)
            if !rect.isEmpty { image = image.cropped(to: rect) }
        }
        let scale = maxSide / max(image.extent.width, image.extent.height)
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return Self.context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [quality: 0.6])
    }
}
