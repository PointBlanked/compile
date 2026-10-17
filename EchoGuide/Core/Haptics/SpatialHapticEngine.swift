// Owner: Bryan. Turns "target minus fingertip" into transient CoreHaptics
// pulses, like a parking sensor in the hand:
//   * pulse rate and intensity rise as the finger closes on the target
//   * sharpness encodes vertical: crisp = move up, dull = move down
//   * left/right is carried by spatial audio (a phone has one actuator, so
//     haptics cannot point sideways on their own)
//   * inside tolerance: a distinct double tap, then silence

import Foundation
import EchoGuideContracts

public struct HapticPulse: Sendable, Equatable {
    public var intensity: Float
    public var sharpness: Float
    /// Seconds until the next pulse.
    public var interval: TimeInterval
}

public enum HapticMapping {
    /// Normalized distance at or below which the finger counts as on target.
    public static let alignedTolerance: Float = Alignment.tolerance
    /// Beyond this distance, pulses are at their slowest.
    public static let farDistance: Float = 0.5

    /// nil means aligned: play the confirm pattern instead.
    public static func pulse(dx: Float, dy: Float, distanceMetres: Float? = nil) -> HapticPulse? {
        let d = (dx * dx + dy * dy).squareRoot()
        guard d > alignedTolerance else { return nil }

        let closeness = 1 - min(1, (d - alignedTolerance) / (farDistance - alignedTolerance)) // 0 far ... 1 close
        // 1.6 Hz far ... 12 Hz close.
        let interval = TimeInterval(0.625 - 0.542 * closeness)
        var intensity = 0.35 + 0.65 * closeness
        // LiDAR: a hand far from the surface feels slightly weaker, so "closer
        // to the button" and "closer to the panel" both read as stronger.
        if let m = distanceMetres { intensity *= max(0.6, min(1, 1.2 - m)) }

        // Image y grows downward, so target above the finger means dy < 0.
        let vertical = d > 0 ? -dy / d : 0 // +1 = move up, -1 = move down
        let sharpness = 0.5 + 0.45 * vertical
        return HapticPulse(intensity: min(1, intensity), sharpness: max(0, min(1, sharpness)), interval: interval)
    }
}

#if canImport(CoreHaptics)
import CoreHaptics

public actor SpatialHapticEngine: HapticCueing {
    private var engine: CHHapticEngine?
    private var loop: Task<Void, Never>?
    private var current: HapticPulse?
    private var lastConfirm: Double = -.infinity
    private let clock = FrameTimer()

    public init() {}

    public var isSupported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    /// True while the guidance pulse train is running (for telemetry and tests).
    public var isGuiding: Bool { current != nil }

    private func ensureEngine() throws -> CHHapticEngine? {
        guard isSupported else { return nil }
        if let engine { return engine }
        let e = try CHHapticEngine()
        e.isAutoShutdownEnabled = false
        e.playsHapticsOnly = true
        // The system can stop the engine (audio interruptions, backgrounding);
        // restart lazily on the next pulse instead of failing silently.
        e.stoppedHandler = { [weak self] _ in Task { await self?.dropEngine() } }
        e.resetHandler = { [weak self] in Task { await self?.dropEngine() } }
        try e.start()
        engine = e
        return e
    }

    private func dropEngine() { engine = nil }

    public func guide(offset dx: Float, _ dy: Float, distanceMetres: Float?) async {
        guard let pulse = HapticMapping.pulse(dx: dx, dy: dy, distanceMetres: distanceMetres) else {
            current = nil
            await confirm()
            return
        }
        current = pulse
        if loop == nil { startLoop() }
    }

    public func confirm() async {
        // On target: the guidance train stops, whoever called us.
        current = nil
        // Debounce: hovering on target should not buzz continuously.
        let now = clock.elapsedMs
        guard now - lastConfirm > 1_000 else { return }
        lastConfirm = now
        play([(0, 1.0, 0.9), (0.09, 1.0, 0.9)])
    }

    public func warn() async {
        current = nil
        play([(0, 1.0, 0.1), (0.12, 1.0, 0.1), (0.24, 1.0, 0.1), (0.36, 1.0, 0.1)])
    }

    public func stop() async {
        current = nil
        loop?.cancel()
        loop = nil
    }

    private func startLoop() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let pulse = await self.tick() else { break }
                try? await Task.sleep(nanoseconds: UInt64(pulse.interval * 1_000_000_000))
            }
            await self?.loopEnded()
        }
    }

    private func tick() -> HapticPulse? {
        guard let p = current else { return nil }
        play([(0, p.intensity, p.sharpness)])
        return p
    }

    private func loopEnded() {
        loop = nil
        // A guide() that landed between the loop's last tick and this call
        // would otherwise wait for the next frame; pick it up now.
        if current != nil { startLoop() }
    }

    /// (relativeTime, intensity, sharpness) transients.
    private func play(_ events: [(TimeInterval, Float, Float)]) {
        do {
            guard let engine = try ensureEngine() else { return }
            let hapticEvents = events.map { t, i, s in
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: i),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: s),
                    ],
                    relativeTime: t
                )
            }
            let player = try engine.makePlayer(with: CHHapticPattern(events: hapticEvents, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            engine = nil
        }
    }
}
#endif
