@preconcurrency import AVFoundation
import SwiftUI

/// Viseur : couche d'aperçu AVFoundation. Toucher : mise au point et mesure ; pincer : zoom.
/// L'orientation de l'image suit l'appareil (`AVCaptureDevice.RotationCoordinator`).
struct CameraPreviewView: UIViewRepresentable {
    let camera: CameraController

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var camera: CameraController?
        private var pinchStart: Double = 1

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            let point = recognizer.location(in: self)
            camera?.focus(at: previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let camera else { return }
            if recognizer.state == .began { pinchStart = camera.zoomFactor }
            camera.setZoom(pinchStart * Double(recognizer.scale))
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspect
        view.camera = camera
        view.addGestureRecognizer(UITapGestureRecognizer(target: view, action: #selector(PreviewView.handleTap(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: view, action: #selector(PreviewView.handlePinch(_:))))
        camera.attachPreviewLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.camera = camera
    }
}

/// Grille des tiers.
struct GridOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                for i in 1...2 {
                    let x = proxy.size.width * CGFloat(i) / 3
                    let y = proxy.size.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}
