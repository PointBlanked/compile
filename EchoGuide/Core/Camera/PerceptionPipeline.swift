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
