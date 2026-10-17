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
