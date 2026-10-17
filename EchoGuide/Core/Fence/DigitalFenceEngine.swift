// Owner: Bryan. The digital fence: hazard zones the camera can see (hob, oven
// door, stair edge, knife block). Zones come from a detected label ("oven") or
// a fixed region of the frame. The fingertip approaching a zone triggers a
// warning before contact; LiDAR depth tightens it when available.
//
// The fence only *reports* FenceEvents. AutomationEngine decides what the
// user feels and hears.

import Foundation
import EchoGuideContracts

// MARK: - Spatial fence

public struct SpatialFenceZone: Sendable, Equatable {
    public enum Anchor: Sendable, Equatable {
        /// Follows any detection with this label, e.g. "oven".
        case label(String)
        /// Fixed region of the frame, for a fixed camera mount.
        case region(ImageRect)
    }

    public var name: String
    public var anchor: Anchor
    /// Expand the zone by this much (normalized) to warn before contact.
    public var warningMargin: Float
    /// When depth is known, only warn within this many metres of the zone surface.
    public var warningDepthMetres: Float

    public init(name: String, anchor: Anchor, warningMargin: Float = 0.08, warningDepthMetres: Float = 0.35) {
        self.name = name
        self.anchor = anchor
        self.warningMargin = warningMargin
        self.warningDepthMetres = warningDepthMetres
    }
}

public struct SpatialFence: Sendable {
    public var zones: [SpatialFenceZone]

    public init(zones: [SpatialFenceZone]) { self.zones = zones }

    public static let kitchenDefaults = SpatialFence(zones: [
        SpatialFenceZone(name: "hob", anchor: .label("oven")),
        SpatialFenceZone(name: "knife", anchor: .label("knife"), warningMargin: 0.05),
    ])

    /// Evaluate one frame. `handDepth` and `zoneDepth` are metres from LiDAR,
    /// nil when unknown (then the 2-D test alone decides). One `zoneDepth`
    /// applies to every zone; use `evaluate(_:depth:)` to sample each zone.
    /// Returns the most severe event: a breach beats an approach.
    public func evaluate(_ frame: VisionFrameResult, handDepth: Float? = nil, zoneDepth: Float? = nil) -> FenceEvent? {
        guard let tip = frame.fingertip?.box.mid else { return nil }
        let gap: Float? = {
            guard let h = handDepth, let z = zoneDepth else { return nil }
            return abs(z - h)
        }()
        return resolve(tip: tip, candidates: candidates(in: frame).map { ($0.zone, $0.rect, gap) })
    }

    /// Evaluate one frame against a live depth source (LiDAR). The hand and
    /// the centre of every zone rect are sampled, so a hob at 1.2 m and a
    /// knife at 0.4 m each get their own distance to the hand. A zone whose
    /// depth is unknown falls back to the 2-D test.
    public func evaluate(_ frame: VisionFrameResult, depth: DepthProviding?) async -> FenceEvent? {
        guard let tip = frame.fingertip?.box.mid else { return nil }
        let pairs = candidates(in: frame)
        guard let depth, !pairs.isEmpty, let hand = await depth.depth(at: tip) else {
            return resolve(tip: tip, candidates: pairs.map { ($0.zone, $0.rect, nil) })
        }
        var withGap: [(SpatialFenceZone, ImageRect, Float?)] = []
        withGap.reserveCapacity(pairs.count)
        for (zone, rect) in pairs {
            let z = await depth.depth(at: rect.mid)
            withGap.append((zone, rect, z.map { abs($0 - hand) }))
        }
        return resolve(tip: tip, candidates: withGap)
    }

    private func candidates(in frame: VisionFrameResult) -> [(zone: SpatialFenceZone, rect: ImageRect)] {
        zones.flatMap { zone in rects(for: zone, in: frame).map { (zone, $0) } }
    }

    /// `candidates` carries each zone rect with the hand-to-zone depth gap in
    /// metres (nil when unknown).
    private func resolve(tip: ImagePoint, candidates: [(SpatialFenceZone, ImageRect, Float?)]) -> FenceEvent? {
        var approaching: FenceEvent?

        for (zone, rect, depthGap) in candidates {
            if rect.contains(tip) {
                // Overlapping in 2-D but clearly far apart in depth is not contact.
                if let gap = depthGap, gap > zone.warningDepthMetres {
                    approaching = approaching ?? .approaching(zone: zone.name, metres: gap)
                    continue
                }
                return .breached(zone: zone.name)
            }

            let m = zone.warningMargin
            let warn = ImageRect(x: rect.x - m, y: rect.y - m, width: rect.width + 2 * m, height: rect.height + 2 * m)
            if warn.contains(tip), approaching == nil {
                if let gap = depthGap, gap > zone.warningDepthMetres { continue }
                approaching = .approaching(zone: zone.name, metres: depthGap)
            }
        }
        return approaching
    }

    private func rects(for zone: SpatialFenceZone, in frame: VisionFrameResult) -> [ImageRect] {
        switch zone.anchor {
        case .region(let r):
            return [r]
        case .label(let label):
            return frame.targets.filter { $0.label == label }.map(\.box)
        }
    }
}
