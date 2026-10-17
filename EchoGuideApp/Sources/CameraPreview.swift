// Owner: Maxwell. What the camera sees, for a sighted helper or a demo. The
// user does not need it; everything it shows is also spoken.

import ARKit
import AVFoundation
import SceneKit
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let arSession: ARSession?
    let captureSession: AVCaptureSession?

    func makeUIView(context: Context) -> UIView {
        if let arSession {
            let view = ARSCNView(frame: .zero)
            view.session = arSession
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

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
