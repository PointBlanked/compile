// Owner: Maxwell. Continuous back-camera feed for devices or modes without
// LiDAR. When LiDARDepthEngine is running, ARKit owns the camera and its
// ARFrame.capturedImage is fed into the same handler instead; iOS will not
// run AVCaptureSession and ARSession on the back camera at the same time.


#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import EchoGuideContracts

public final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "echoguide.camera", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var index: UInt64 = 0
    private var handler: ((CameraFrame) -> Void)?

    public override init() { super.init() }

    /// `handler` runs on the camera queue for every frame. Keep it cheap:
    /// run FrameDeltaEngine there and hand only triggered frames onward.
    public func start(fps: Int32 = 30, handler: @escaping (CameraFrame) -> Void) throws {
        self.handler = handler
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            session.commitConfiguration()
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }

        try device.lockForConfiguration()
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
        device.unlockForConfiguration()

        session.commitConfiguration()
        queue.async { [session] in session.startRunning() }
    }

    public func stop() {
        queue.async { [session] in session.stopRunning() }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        index += 1
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        handler?(CameraFrame(pixelBuffer: pb, timestamp: t, index: index))
    }

    public enum CameraError: Error { case noCamera }
}
#endif
