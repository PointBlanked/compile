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
