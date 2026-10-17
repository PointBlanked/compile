// Owner: Maxwell's app, added for the demo (Bryan). Is the phone itself
// moving? The gyroscope catches turning, user acceleration catches steps.
// While either is above threshold (and for a short hold after), nothing in
// the camera may be called "moving fast": it is the user who moved.

import CoreMotion
import Foundation

final class DeviceMotionGate: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let lock = NSLock()
    private var lastMotionAt: TimeInterval = -.infinity
    /// rad/s of rotation, and g of acceleration beyond gravity, that count as moving.
    var rotationThreshold = 0.35
    var accelerationThreshold = 0.12
    var hold: TimeInterval = 0.6

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: OperationQueue()) { [weak self] m, _ in
            guard let self, let m else { return }
            let r = m.rotationRate, a = m.userAcceleration
            let rot = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
            let acc = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            if rot > self.rotationThreshold || acc > self.accelerationThreshold {
                self.lock.withLock { self.lastMotionAt = Date().timeIntervalSince1970 }
            }
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    var isMoving: Bool {
        lock.withLock { Date().timeIntervalSince1970 - lastMotionAt < hold }
    }
}
