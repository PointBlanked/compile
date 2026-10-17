// Owner: Bryan. The digital fence, in two layers:
//
//  1. Spatial fence: hazard zones the camera can see (hob, oven door, stair
//     edge, knife block). Zones come from a detected label ("oven") or a fixed
//     region of the frame. The fingertip approaching a zone triggers a warning
//     before contact; LiDAR depth tightens it when available.
//  2. Location fence: safe areas (home, day centre) for dementia wandering.
//     Leaving one is reported once after a dwell, never on GPS jitter.
//
// Both layers only *report* FenceEvents. AutomationEngine decides what the
// user feels and hears; caregiver alerts go through a plugin tool.

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
    /// nil when unknown (then the 2-D test alone decides). Returns the most
    /// severe event: a breach beats an approach.
    public func evaluate(_ frame: VisionFrameResult, handDepth: Float? = nil, zoneDepth: Float? = nil) -> FenceEvent? {
        guard let tip = frame.fingertip?.box.mid else { return nil }
        var approaching: FenceEvent?

        for zone in zones {
            for rect in rects(for: zone, in: frame) {
                let depthGap: Float? = {
                    guard let h = handDepth, let z = zoneDepth else { return nil }
                    return abs(z - h)
                }()

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

// MARK: - Location fence

public struct GeoCoordinate: Sendable, Equatable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Haversine distance in metres.
    public func distance(to o: GeoCoordinate) -> Double {
        let r = 6_371_000.0
        let dLat = (o.latitude - latitude) * .pi / 180
        let dLon = (o.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(o.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}

public struct SafeArea: Sendable, Equatable, Codable {
    public var name: String
    public var center: GeoCoordinate
    public var radiusMetres: Double

    public init(name: String, center: GeoCoordinate, radiusMetres: Double) {
        self.name = name
        self.center = center
        self.radiusMetres = radiusMetres
    }
}

/// Pure state machine over location fixes. Feed it CLLocation updates; it emits
/// at most one event per real crossing.
public struct LocationFence: Sendable {
    public var areas: [SafeArea]
    /// Must be outside every area for this long before `leftSafeArea` fires.
    public var exitDwell: TimeInterval = 45
    /// Fixes worse than this are ignored (indoor GPS can be 100 m+ off).
    public var maxAccuracyMetres: Double = 65

    private(set) var insideArea: String?
    private var outsideSince: TimeInterval?
    private var reportedExit = false
    private var lastArea: String?

    public init(areas: [SafeArea]) { self.areas = areas }

    public mutating func update(_ c: GeoCoordinate, accuracyMetres: Double, at t: TimeInterval) -> FenceEvent? {
        guard accuracyMetres <= maxAccuracyMetres else { return nil }

        // Inside if the fix is within radius, giving the benefit of the doubt for accuracy.
        let area = areas.first { c.distance(to: $0.center) <= $0.radiusMetres + accuracyMetres / 2 }

        if let area {
            insideArea = area.name
            lastArea = area.name
            outsideSince = nil
            if reportedExit {
                reportedExit = false
                return .returnedToSafeArea(region: area.name)
            }
            return nil
        }

        insideArea = nil
        if outsideSince == nil { outsideSince = t }
        if !reportedExit, let since = outsideSince, t - since >= exitDwell {
            reportedExit = true
            return .leftSafeArea(region: lastArea ?? "safe area")
        }
        return nil
    }
}

#if canImport(CoreLocation) && os(iOS)
import CoreLocation

/// Bridges CoreLocation to LocationFence. Needs "Always" authorization and the
/// location background mode for wandering alerts to work with the screen off.
public final class LocationFenceMonitor: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var fence: LocationFence
    private let onEvent: @Sendable (FenceEvent) -> Void

    public init(areas: [SafeArea], onEvent: @escaping @Sendable (FenceEvent) -> Void) {
        fence = LocationFence(areas: areas)
        self.onEvent = onEvent
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
    }

    public func start() {
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
    }

    public func stop() { manager.stopUpdatingLocation() }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for l in locations {
            let c = GeoCoordinate(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude)
            if let e = fence.update(c, accuracyMetres: l.horizontalAccuracy, at: l.timestamp.timeIntervalSince1970) {
                onEvent(e)
            }
        }
    }
}
#endif
