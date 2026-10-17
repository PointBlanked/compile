// Owner: Maxwell's agent, extended for the demo (Bryan). OCR flickers: a
// string that appears in one frame and is gone in the next is noise, a
// reflection or a misread. A text detection counts only once the same words
// have been read at the same place in two of the last three OCR frames.

import Foundation
import EchoGuideContracts

public struct TextStabilizer: Sendable {
    public var window = 3
    public var required = 2
    private var history: [[(key: String, box: ImageRect)]] = []

    public init() {}

    public mutating func reset() { history = [] }

    static func key(_ d: Detection) -> String? {
        guard d.kind == .text, let t = d.text else { return nil }
        let cleaned = TextReader.clean(t).lowercased()
        return cleaned.count >= 2 ? cleaned : nil
    }

    /// Text detections of this frame that have persisted. Frames without any
    /// OCR output do not advance the window (OCR runs on a cadence).
    public mutating func stable(in frame: VisionFrameResult) -> [Detection] {
        let texts = frame.detections.filter { $0.kind == .text }
        guard !texts.isEmpty else { return [] }
        let current = texts.compactMap { d in Self.key(d).map { (key: $0, box: d.box) } }
        history.append(current)
        if history.count > window { history.removeFirst(history.count - window) }
        return texts.filter { d in
            guard let k = Self.key(d) else { return false }
            let seen = history.filter { frame in frame.contains { $0.key == k && $0.box.iou(d.box) > 0.2 } }.count
            return seen >= required
        }
    }
}
