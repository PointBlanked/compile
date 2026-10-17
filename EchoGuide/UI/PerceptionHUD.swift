// Owner: Bryan. The audience's window into the AI. The blind user never needs
// this; a sighted helper, a judge or a tester does: it shows exactly what the
// phone perceives and decides, live, on top of the camera. Everything drawn
// here is also spoken or felt.
//
//   * every detection as a thin box with its label (objects yellow, text cyan,
//     barcodes magenta)
//   * the fingertip as a white dot with a ring
//   * the one isolated target as a thick green box, with a line from the
//     fingertip to it: the "last 10 cm" made visible
//   * hazard zones in red when approached or breached
//   * a dwell ring that fills while the finger holds still on the target

import Foundation
import EchoGuideContracts

/// One frame's worth of perception, as the screen needs it.
public struct HUDFrame: Sendable, Equatable {
    public var detections: [Detection]
    public var fence: FenceEvent?
    public var timestamp: TimeInterval
    /// Milliseconds spent in the vision engine, for the latency readout.
    public var inferenceMs: Double

    public init(detections: [Detection] = [], fence: FenceEvent? = nil, timestamp: TimeInterval = 0, inferenceMs: Double = 0) {
        self.detections = detections
        self.fence = fence
        self.timestamp = timestamp
        self.inferenceMs = inferenceMs
    }

    public var fingertip: Detection? { detections.first { $0.kind == .fingertip } }
    public var objects: Int { detections.filter { $0.kind == .object }.count }
}

/// Maps normalized upright-image coordinates onto a view that shows the image
/// aspect-fill (scaled by the larger ratio, centred, edges cropped), which is
/// how both the AVCapture preview layer and ARSCNView draw the camera.
public enum HUDGeometry {
    public struct Transform: Equatable {
        public var scale: CGFloat
        public var offsetX: CGFloat
        public var offsetY: CGFloat
    }

    /// `imageAspect` is width / height of the upright image (9/16 for a
    /// 720x1280 feed held in portrait, 3/4 for ARKit's 1440x1920).
    public static func transform(viewSize: CGSize, imageAspect: CGFloat) -> Transform {
        guard viewSize.width > 0, viewSize.height > 0, imageAspect > 0 else { return Transform(scale: 1, offsetX: 0, offsetY: 0) }
        // Image drawn at unit height has width = aspect; pick the scale that covers the view.
        let imageW = imageAspect, imageH: CGFloat = 1
        let scale = max(viewSize.width / imageW, viewSize.height / imageH)
        return Transform(scale: scale,
                         offsetX: (viewSize.width - imageW * scale) / 2,
                         offsetY: (viewSize.height - imageH * scale) / 2)
    }

    public static func point(_ p: ImagePoint, viewSize: CGSize, imageAspect: CGFloat) -> CGPoint {
        let t = transform(viewSize: viewSize, imageAspect: imageAspect)
        return CGPoint(x: t.offsetX + CGFloat(p.x) * imageAspect * t.scale,
                       y: t.offsetY + CGFloat(p.y) * t.scale)
    }

    public static func rect(_ r: ImageRect, viewSize: CGSize, imageAspect: CGFloat) -> CGRect {
        let o = point(ImagePoint(x: r.x, y: r.y), viewSize: viewSize, imageAspect: imageAspect)
        let t = transform(viewSize: viewSize, imageAspect: imageAspect)
        return CGRect(x: o.x, y: o.y, width: CGFloat(r.width) * imageAspect * t.scale, height: CGFloat(r.height) * t.scale)
    }
}

#if canImport(SwiftUI)
import SwiftUI

public struct PerceptionOverlay: View {
    public var frame: HUDFrame
    /// The one target the automation engine has isolated, if any.
    public var target: Detection?
    public var imageAspect: CGFloat
    public var showsLabels: Bool

    public init(frame: HUDFrame, target: Detection? = nil, imageAspect: CGFloat = 9.0 / 16.0, showsLabels: Bool = true) {
        self.frame = frame
        self.target = target
        self.imageAspect = imageAspect
        self.showsLabels = showsLabels
    }

    private static func color(for d: Detection) -> Color {
        switch d.kind {
        case .object: return .yellow
        case .text: return .cyan
        case .barcode: return Color(red: 1, green: 0.3, blue: 0.9)
        case .fingertip: return .white
        }
    }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    // Hazard: a red wash and a thick border on the whole frame when breached.
                    if case .breached? = frame.fence {
                        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.red.opacity(0.18)))
                        ctx.stroke(Path(CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)), with: .color(.red), lineWidth: 8)
                    } else if case .approaching? = frame.fence {
                        ctx.stroke(Path(CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)), with: .color(.orange), lineWidth: 6)
                    }

                    for d in frame.detections where d.kind != .fingertip {
                        let r = HUDGeometry.rect(d.box, viewSize: size, imageAspect: imageAspect)
                        let isTarget = target.map { $0.label == d.label && $0.box.iou(d.box) > 0.5 } ?? false
                        let path = Path(roundedRect: r, cornerRadius: 6)
                        ctx.stroke(path, with: .color(isTarget ? .green : Self.color(for: d).opacity(0.85)), lineWidth: isTarget ? 4 : 1.5)
                        if isTarget {
                            ctx.fill(path, with: .color(.green.opacity(0.12)))
                        }
                    }

                    if let tip = frame.fingertip {
                        let p = HUDGeometry.point(tip.box.mid, viewSize: size, imageAspect: imageAspect)
                        if let target {
                            let q = HUDGeometry.point(target.box.mid, viewSize: size, imageAspect: imageAspect)
                            var line = Path()
                            line.move(to: p)
                            line.addLine(to: q)
                            ctx.stroke(line, with: .color(.green.opacity(0.9)), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 6]))
                        }
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(.white))
                        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)), with: .color(.white.opacity(0.8)), lineWidth: 3)
                    }
                }

                if showsLabels {
                    ForEach(Array(frame.detections.enumerated()), id: \.offset) { _, d in
                        if d.kind != .fingertip {
                            let r = HUDGeometry.rect(d.box, viewSize: size, imageAspect: imageAspect)
                            let isTarget = target.map { $0.label == d.label && $0.box.iou(d.box) > 0.5 } ?? false
                            Text(labelText(d))
                                .font(.system(isTarget ? .subheadline : .caption2, design: .rounded, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(isTarget ? Color.green : Self.color(for: d), in: RoundedRectangle(cornerRadius: 4))
                                .position(x: r.minX + 40, y: max(10, r.minY - 10))
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func labelText(_ d: Detection) -> String {
        switch d.kind {
        case .text: return "“\(d.text ?? "")”"
        case .barcode: return "barcode"
        default: return "\(d.label) \(Int(d.confidence * 100))%"
        }
    }
}

/// Fills clockwise over `duration` while `active`; empty otherwise. Shows the
/// 0.8 s hold that is the confirmation gesture, so a watcher understands why
/// nothing has fired yet.
public struct DwellRing: View {
    public var active: Bool
    public var duration: TimeInterval
    @State private var progress: CGFloat = 0

    public init(active: Bool, duration: TimeInterval = 0.8) {
        self.active = active
        self.duration = duration
    }

    public var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 10)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: progress >= 1 ? "checkmark" : "hand.point.up.left.fill")
                .font(.system(size: 28, weight: .black))
                .foregroundStyle(.white)
        }
        .onChange(of: active, initial: true) { _, on in
            if on {
                progress = 0
                withAnimation(.linear(duration: duration)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
