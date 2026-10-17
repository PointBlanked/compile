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
