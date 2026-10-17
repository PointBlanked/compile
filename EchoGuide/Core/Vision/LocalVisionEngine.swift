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
    public private(set) var config: LocalVisionConfig
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

    /// Read mode wants text on every frame; Explore and Find keep the cheaper cadence.
    public func setTextEveryNthFrame(_ n: Int) { config.ocrEveryNthFrame = max(0, n) }

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
