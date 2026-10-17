// Owner: Maxwell's vision, extended for the demo (Bryan). Names the dominant
// colour inside a detection box from a handful of pixels, so "a cup" becomes
// "a red cup". Pure maths; the sampling of the pixel buffer is in
// LocalVisionEngine.

import Foundation
import EchoGuideContracts

public enum ColorNamer {
    /// Basic colour name for an sRGB triple in 0...255.
    public static func name(r: Int, g: Int, b: Int) -> String {
        let rf = Float(r) / 255, gf = Float(g) / 255, bf = Float(b) / 255
        let maxC = max(rf, gf, bf), minC = min(rf, gf, bf)
        let v = maxC, d = maxC - minC
        let s: Float = maxC > 0 ? d / maxC : 0
        if v < 0.16 { return "black" }
        if s < 0.18 { return v > 0.78 ? "white" : "grey" }
        var h: Float
        if d == 0 { h = 0 }
        else if maxC == rf { h = 60 * ((gf - bf) / d).truncatingRemainder(dividingBy: 6) }
        else if maxC == gf { h = 60 * ((bf - rf) / d + 2) }
        else { h = 60 * ((rf - gf) / d + 4) }
        if h < 0 { h += 360 }
        switch h {
        case ..<14, 340...: return v < 0.5 && s < 0.7 ? "brown" : "red"
        case 14..<42: return v < 0.55 ? "brown" : "orange"
        case 42..<70: return "yellow"
        case 70..<165: return "green"
        case 165..<200: return "teal"
        case 200..<255: return "blue"
        case 255..<290: return "purple"
        default: return "pink"
        }
    }

    /// The name most samples agree on, when at least `agreement` of them do.
    public static func dominant(_ names: [String], agreement: Float = 0.5) -> String? {
        guard !names.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for n in names { counts[n, default: 0] += 1 }
        guard let (name, count) = counts.max(by: { $0.value < $1.value }),
              Float(count) / Float(names.count) >= agreement else { return nil }
        return name
    }

    /// Full-range BT.601 YCbCr to sRGB.
    public static func rgb(y: UInt8, cb: UInt8, cr: UInt8) -> (Int, Int, Int) {
        let yf = Float(y), cbf = Float(cb) - 128, crf = Float(cr) - 128
        let r = yf + 1.402 * crf
        let g = yf - 0.344136 * cbf - 0.714136 * crf
        let b = yf + 1.772 * cbf
        return (Int(max(0, min(255, r))), Int(max(0, min(255, g))), Int(max(0, min(255, b))))
    }

    /// Upright normalized point to the landscape sensor's normalized point for
    /// a back camera held in portrait (Vision orientation .right).
    public static func sensorPoint(fromUpright p: ImagePoint) -> ImagePoint {
        ImagePoint(x: p.y, y: 1 - p.x)
    }
}
