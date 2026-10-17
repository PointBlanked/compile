// Owner: Maxwell. What the camera sees, for a sighted helper or a demo. The
// user does not need it; everything it shows is also spoken.

import ARKit
import AVFoundation
import SceneKit
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let arSession: ARSession?
    let captureSession: AVCaptureSession?

    /// Decided at creation: ARKit on LiDAR phones, AVCapture otherwise.
    let usesARKit: Bool

    init(arSession: ARSession?, captureSession: AVCaptureSession?, usesARKit: Bool? = nil) {
        self.arSession = arSession
        self.captureSession = captureSession
        self.usesARKit = usesARKit ?? (arSession != nil)
    }

    func makeUIView(context: Context) -> UIView {
        if usesARKit {
            let view = ARSCNView(frame: .zero)
            if let arSession { view.session = arSession }
            view.automaticallyUpdatesLighting = false
            view.rendersCameraGrain = false
            view.isAccessibilityElement = false
            return view
        }
        let view = PreviewView()
        view.previewLayer.session = captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        view.isAccessibilityElement = false
        return view
    }

    /// The sessions are created after the first render (the runtime starts in
    /// a task), so attach them here, not only in makeUIView, or the preview
    /// stays black on phones that take the AVCapture path.
    func updateUIView(_ uiView: UIView, context: Context) {
        if let view = uiView as? ARSCNView {
            if let arSession, view.session !== arSession { view.session = arSession }
        } else if let view = uiView as? PreviewView {
            if view.previewLayer.session !== captureSession { view.previewLayer.session = captureSession }
            // The sensor is landscape; the app is portrait-only.
            if let c = view.previewLayer.connection {
                if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            }
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
