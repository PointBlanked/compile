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

    /// How often a still scene is looked at again; nil only on motion.
    public func setIdleRefresh(_ seconds: TimeInterval?) { config.idleRefresh = seconds }

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
