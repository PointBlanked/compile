// Owner: Maxwell. Real on-device numbers for the README targets, captured
// from the live camera. CI can only measure the frame-delta step on a Mac.

import Foundation
import UIKit
import EchoGuideVision

struct BenchmarkReport: Codable {
    var device: String
    var system: String
    var lidar: Bool
    var framesSeen: UInt64
    var framesInferred: UInt64
    var computeSaved: Double
    var endToEndP50Ms: Double
    var endToEndP95Ms: Double
    var visionP95Ms: Double
    var visionOverBudgetFrames: Int
    var capturedAt: Date

    /// The README target: local end-to-end (frame to cue) under 15 ms.
    var meetsLocalTarget: Bool { endToEndP95Ms < 15 }

    var summary: String {
        String(format: "e2e p50 %.1f ms, p95 %.1f ms %@ | vision p95 %.1f ms | skipped %.0f%% of %llu frames",
               endToEndP50Ms, endToEndP95Ms, meetsLocalTarget ? "(meets 15 ms)" : "(MISSES 15 ms)",
               visionP95Ms, computeSaved * 100, framesSeen)
    }

    @MainActor
    static func capture(pipeline: PerceptionPipeline, vision: LocalVisionEngine, lidar: Bool) async -> BenchmarkReport {
        let s = pipeline.stats
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return BenchmarkReport(
            device: machine,
            system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            lidar: lidar,
            framesSeen: s.framesSeen,
            framesInferred: s.framesInferred,
            computeSaved: s.computeSaved,
            endToEndP50Ms: s.totalP50Ms,
            endToEndP95Ms: s.totalP95Ms,
            visionP95Ms: await vision.p95Ms,
            visionOverBudgetFrames: await vision.overBudgetFrames,
            capturedAt: Date()
        )
    }

    func write() -> URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = dir.appendingPathComponent("benchmark-\(Int(capturedAt.timeIntervalSince1970)).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(self), (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}
