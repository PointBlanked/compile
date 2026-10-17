// Owner: Maxwell. Reproducible benchmarks of the real engine code, not mocks
// of it. Runs anywhere Swift and Apple's Vision framework run:
//
//   swift run -c release EchoGuideBench            # prints a table, writes benchmarks/results/<host>.md
//
// Every number here is measured by this file on the machine it runs on. The
// phone numbers come from the in-app speed test (Settings > Measure speed).

import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import Foundation
import EchoGuideContracts
import EchoGuideInfra
import EchoGuideVision

// MARK: - Harness

struct Row {
    var name: String
    var value: String
    var detail: String
}

var rows: [Row] = []

func stats(_ samples: [Double]) -> (p50: Double, p95: Double, max: Double) {
    let s = samples.sorted()
    func at(_ p: Double) -> Double { s[min(s.count - 1, Int((p * Double(s.count - 1)).rounded()))] }
    return (at(0.5), at(0.95), s.last ?? 0)
}

func ms(_ v: Double) -> String { v < 1 ? String(format: "%.3f ms", v) : String(format: "%.1f ms", v) }

func record(_ name: String, _ samples: [Double], unit: String = "ms", detail: String) {
    let s = stats(samples)
    let value = unit == "µs"
        ? String(format: "p50 %.1f µs · p95 %.1f µs", s.p50 * 1000, s.p95 * 1000)
        : "p50 \(ms(s.p50)) · p95 \(ms(s.p95))"
    rows.append(Row(name: name, value: value, detail: detail + " (n=\(samples.count))"))
    print("• \(name): \(value)")
}

func luma(_ w: Int, _ h: Int, fill: UInt8 = 100, square: (Int, Int, Int)? = nil) -> [UInt8] {
    var px = [UInt8](repeating: fill, count: w * h)
    if let (sx, sy, size) = square {
        for y in sy..<min(h, sy + size) { for x in sx..<min(w, sx + size) { px[y * w + x] = 230 } }
    }
    return px
}

func pixelBuffer420(_ w: Int, _ h: Int, fill: UInt8 = 100, square: Bool = false) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    let base = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h { for x in 0..<w { base[y * bpr + x] = square && x > w / 4 && x < w / 2 && y > h / 4 && y < h / 2 ? 230 : fill } }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

/// A photographed-panel stand-in: white card, black words at real sizes, plus a barcode.
func panelImage(words: [String], barcode: String?, width: Int = 1280, height: Int = 960) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(b), width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(b), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (i, word) in words.enumerated() {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
        let str = NSAttributedString(string: word, attributes: [.init(kCTFontAttributeName as String): font,
                                                                 .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.05, alpha: 1)])
        let line = CTLineCreateWithAttributedString(str)
        ctx.textPosition = CGPoint(x: 80 + (i % 2) * 560, y: height - 160 - (i / 2) * 140)
        CTLineDraw(line, ctx)
    }
    if let barcode, let filter = CIFilter(name: "CICode128BarcodeGenerator") {
        filter.setValue(Data(barcode.utf8), forKey: "inputMessage")
        if let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 3, y: 3)),
           let cg = CIContext().createCGImage(out, from: out.extent) {
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 80, y: 60, width: out.extent.width, height: out.extent.height * 0.5))
        }
    }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

struct NullAudio: SpatialAudioCueing {
    func speak(_ text: String, azimuth: Float) async {}
    func ping(azimuth: Float, elevation: Float) async {}
}

struct NullHaptics: HapticCueing {
    func guide(offset dx: Float, _ dy: Float, distanceMetres: Float?) async {}
    func confirm() async {}
    func warn() async {}
    func stop() async {}
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func set(_ n: T) { lock.withLock { v = n } }
}

// MARK: - 1. Motion gate

setvbuf(stdout, nil, _IOLBF, 0)
print("EchoGuide benchmarks\n")
do {
    let e = FrameDeltaEngine()
    let a = luma(1920, 1440), b = luma(1920, 1440, square: (400, 300, 500))
    var samples: [Double] = []
    for i in 0..<3000 {
        let px = i % 2 == 0 ? a : b
        _ = px.withUnsafeBufferPointer { e.analyze(luma: $0, width: 1920, height: 1440, bytesPerRow: 1920, timestamp: Double(i) / 60) }
        samples.append(e.lastAnalysisMs)
    }
    record("Motion gate, per frame (1920×1440)", samples, unit: "µs", detail: "FrameDeltaEngine decides whether a frame is worth running the models on")
}

do {
    // 60 s at 30 fps: a still room with four short events (someone walks in, a hand reaches out).
    let e = FrameDeltaEngine()
    let still = luma(640, 480)
    let events: [ClosedRange<Int>] = [300...330, 700...760, 1200...1215, 1500...1560]
    for i in 0..<1800 {
        let moving = events.contains { $0.contains(i) }
        let px = moving ? luma(640, 480, square: (100 + (i % 30) * 10, 120, 160)) : still
        _ = px.withUnsafeBufferPointer { e.analyze(luma: $0, width: 640, height: 480, bytesPerRow: 640, timestamp: Double(i) / 30) }
    }
    let s = e.stats
    let pct = s.skipRatio * 100
    rows.append(Row(name: "Frames that never reach the models", value: String(format: "%.1f%%", pct),
                    detail: "60 s at 30 fps of a mostly still scene with 4 motion events: \(s.framesInferred) of \(s.framesSeen) frames inferred"))
    print("• Frames skipped: \(String(format: "%.1f%%", pct)) (\(s.framesInferred)/\(s.framesSeen) inferred)")
}

// MARK: - 2. Apple Vision through LocalVisionEngine (the shipping engine, no object model)

let expectedWords = ["START", "STOP", "DEFROST", "POWER", "TIMER", "CLEAR"]
let barcodeValue = "5000157024671"
let panel = panelImage(words: expectedWords, barcode: barcodeValue)
/// The same panel in the camera's own format (bi-planar 420), which is what the motion gate reads.
let panel420: CVPixelBuffer = {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(panel), CVPixelBufferGetHeight(panel),
                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
    CIContext().render(CIImage(cvPixelBuffer: panel), to: pb!)
    return pb!
}()
var visionMs: [Double] = []
var textHits = 0, barcodeHits = 0, textRuns = 0
do {
    var config = LocalVisionConfig()
    config.ocrEveryNthFrame = 1
    let engine = try LocalVisionEngine(modelURL: nil, config: config)
    for i in 0..<40 {
        let r = await engine.process(CameraFrame(pixelBuffer: panel, timestamp: Double(i), index: UInt64(i)), orientation: .up)
        if i >= 3 { visionMs.append(r.inferenceMs) } // first frames include model warm-up
        let found = Set(r.detections.filter { $0.kind == .text }.compactMap { $0.text?.uppercased() })
        textHits += expectedWords.filter { w in found.contains { $0.contains(w) } }.count
        textRuns += 1
        if r.detections.contains(where: { $0.kind == .barcode && $0.text == barcodeValue }) { barcodeHits += 1 }
    }
    record("Hand + text + barcode in one pass", visionMs, detail: "LocalVisionEngine with Apple Vision (hand pose, fast OCR, barcodes) on a 1280×960 panel")
    let textAcc = Double(textHits) / Double(textRuns * expectedWords.count) * 100
    rows.append(Row(name: "Button labels read correctly", value: String(format: "%.0f%%", textAcc),
                    detail: "\(expectedWords.joined(separator: ", ")) on a synthetic panel, \(textRuns) frames"))
    rows.append(Row(name: "Barcode decoded correctly", value: String(format: "%.0f%%", Double(barcodeHits) / Double(textRuns) * 100),
                    detail: "Code 128 \(barcodeValue), \(textRuns) frames"))
    print("• Labels read: \(String(format: "%.0f%%", textAcc)), barcode: \(barcodeHits)/\(textRuns)")
} catch {
    print("Vision engine unavailable: \(error)")
}

// MARK: - 3. Decision layer

do {
    var n = SceneNarrator()
    let scene = (0..<12).map { i in
        Detection(label: ["person", "chair", "car", "cup", "dog", "bench"][i % 6], confidence: 0.8,
                  box: ImageRect(x: Float(i % 4) * 0.22, y: Float(i / 4) * 0.3, width: 0.18, height: 0.25))
    }
    var samples: [Double] = []
    for i in 0..<5000 {
        let t = FrameTimer()
        _ = n.observe(VisionFrameResult(frameIndex: UInt64(i), timestamp: Double(i) / 30, detections: scene, inferenceMs: 0),
                      aheadMetres: 2.0)
        samples.append(t.elapsedMs)
    }
    record("Proactive narrator decision (12 objects)", samples, unit: "µs", detail: "Track, rank by salience, check novelty and pacing, phrase with place and distance")
}

do {
    let agent = AgentCore(audio: NullAudio(), haptics: NullHaptics())
    let scene = [Detection(label: "person", confidence: 0.9, box: ImageRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4))]
    var samples: [Double] = []
    for i in 0..<5000 {
        let t = FrameTimer()
        await agent.ingest(VisionFrameResult(frameIndex: UInt64(i), timestamp: Double(i) / 30, detections: scene, inferenceMs: 0), fence: nil)
        samples.append(t.elapsedMs)
    }
    record("Agent step (detections in → what to say)", samples, unit: "µs", detail: "AgentCore.ingest in Explore, including actor hop")
}

// MARK: - 4. End to end on real Vision: frame submitted → sentence chosen

do {
    var config = LocalVisionConfig()
    config.ocrEveryNthFrame = 1
    let engine = try LocalVisionEngine(modelURL: nil, config: config)
    let spoken = Box<Double?>(nil)
    struct TimingAudio: SpatialAudioCueing {
        let onSpeak: @Sendable () -> Void
        func speak(_ text: String, azimuth: Float) async { onSpeak() }
        func ping(azimuth: Float, elevation: Float) async {}
    }
    let start = Box<FrameTimer>(FrameTimer())
    let agent = AgentCore(audio: TimingAudio { if spoken.value == nil { spoken.set(start.value.elapsedMs) } }, haptics: NullHaptics())
    await agent.setMode(.read, announce: false)
    let done = Box(false)
    let pipeline = PerceptionPipeline(vision: OrientedUp(engine)) { result, _ in
        await agent.ingest(result, fence: nil)
        done.set(true)
    }
    var e2e: [Double] = []
    for i in 0..<15 {
        await agent.setMode(.read, announce: false) // forget what was read, so every trial speaks
        spoken.set(nil)
        done.set(false)
        start.set(FrameTimer())
        pipeline.forceNextFrame()
        let decision = pipeline.submit(CameraFrame(pixelBuffer: panel420, timestamp: 1000 + Double(i) * 10, index: UInt64(i)))
        guard decision.shouldInfer else { continue }
        let deadline = Date().addingTimeInterval(5)
        while !done.value && Date() < deadline { try? await Task.sleep(nanoseconds: 200_000) }
        if let s = spoken.value, i >= 2 { e2e.append(s) }
    }
    if !e2e.isEmpty {
        record("Camera frame → spoken sentence (Read mode)", e2e,
               detail: "Full path on real Vision: motion gate, hand + OCR + barcode, reading order, speech handed off")
    }
} catch {
    print("Vision engine unavailable: \(error)")
}

/// Runs the shipping engine with an upright synthetic image (camera frames use .right).
struct OrientedUp: FrameInferring {
    let engine: LocalVisionEngine
    init(_ e: LocalVisionEngine) { engine = e }
    func infer(_ frame: CameraFrame) async -> VisionFrameResult { await engine.process(frame, orientation: .up) }
}

// MARK: - Report

func sysctl(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}

let chip = sysctl("machdep.cpu.brand_string")
let model = sysctl("hw.model")
let os = ProcessInfo.processInfo.operatingSystemVersionString
let date = ISO8601DateFormatter().string(from: Date())

var md = """
# Benchmark results: \(chip) (\(model))

Measured by `swift run -c release EchoGuideBench` on \(date), macOS \(os). Every number below is produced by the shipping engine code in this repo; nothing is simulated except the input images. Phone numbers come from the in-app speed test.

| Measure | Result | What it is |
|---|---|---|

"""
for r in rows { md += "| \(r.name) | \(r.value) | \(r.detail) |\n" }
md += "\nInput images are synthetic (rendered panel text and a Code 128 barcode), so recognition rates here are an upper bound for clean, well-lit labels, not a field accuracy figure.\n"

let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("benchmarks/results/\(model.isEmpty ? "host" : model).md")
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try? md.write(to: out, atomically: true, encoding: .utf8)
print("\nWrote \(out.path)")
