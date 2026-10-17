// Owner: Maxwell. Read mode: turns OCR fragments into the order a sighted
// person would read them (top to bottom, left to right), drops repeats and
// junk, and remembers what was already read so a held-still page is not
// read twice.

import Foundation
import EchoGuideContracts

public struct TextReader: Sendable {
    /// A line already read is not read again for this long.
    public var repeatAfter: TimeInterval = 60
    private var readAt: [String: TimeInterval] = [:]

    public init() {}

    public mutating func reset() { readAt = [:] }

    /// Everything readable in this frame, in reading order, ignoring history.
    public static func lines(in frame: VisionFrameResult, minimumConfidence: Float = 0.5) -> [String] {
        let items = frame.detections
            .filter { $0.kind == .text && $0.confidence >= minimumConfidence }
            .compactMap { d -> (ImageRect, String)? in
                guard let t = d.text.map(clean), t.count >= 2 else { return nil }
                return (d.box, t)
            }
        // Group into rows by vertical overlap, then left to right inside a row.
        let sorted = items.sorted { $0.0.midY < $1.0.midY }
        var rows: [[(ImageRect, String)]] = []
        for item in sorted {
            if let last = rows.last?.last, abs(last.0.midY - item.0.midY) < max(last.0.height, item.0.height) * 0.6 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        var seen = Set<String>()
        return rows.map { $0.sorted { $0.0.midX < $1.0.midX }.map(\.1).joined(separator: " ") }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Lines not read recently, marked as read now.
    public mutating func newLines(in frame: VisionFrameResult) -> [String] {
        let now = frame.timestamp
        let fresh = Self.lines(in: frame).filter { line in
            guard let at = readAt[line.lowercased()] else { return true }
            return now - at >= repeatAfter
        }
        for l in fresh { readAt[l.lowercased()] = now }
        return fresh
    }

    /// Strips OCR noise: stray symbols, repeated spaces, lone characters.
    public static func clean(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: ".,:;!?'%$£€&-/()")).contains($0) }
        let s = String(String.UnicodeScalarView(kept))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,-"))
        // A line with no letters or digits at all is noise.
        return s.rangeOfCharacter(from: .alphanumerics) == nil ? "" : s
    }
}
