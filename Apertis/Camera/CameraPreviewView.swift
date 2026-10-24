@preconcurrency import AVFoundation
import SwiftUI

/// Viseur : couche d'aperçu AVFoundation, toucher pour faire la mise au point.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let onTap: (CGPoint) -> Void

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTap: ((CGPoint) -> Void)?

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            let point = recognizer.location(in: self)
            onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.onTap = onTap
        view.addGestureRecognizer(UITapGestureRecognizer(target: view, action: #selector(PreviewView.handleTap(_:))))
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.onTap = onTap
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
