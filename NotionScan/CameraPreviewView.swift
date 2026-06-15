//
//  CameraPreviewView.swift
//  NotionScan
//
//  A SwiftUI wrapper around AVCaptureVideoPreviewLayer for the live camera feed.
//  Taps are converted from screen coordinates to the camera's normalized
//  coordinate space and reported back via `onTapToFocus`, while a short focus
//  reticle animation is drawn at the tap location.
//

import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Called with a normalized device point (0…1) when the user taps the preview.
    var onTapToFocus: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.onTapToFocus = onTapToFocus
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onTapToFocus = onTapToFocus
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // Safe: layerClass guarantees this type.
            layer as! AVCaptureVideoPreviewLayer
        }

        /// Reports the tapped point in the camera's normalized coordinate space.
        var onTapToFocus: ((CGPoint) -> Void)?

        /// The reticle currently on screen, if any, so a new tap replaces it.
        private weak var reticleView: UIView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            addGestureRecognizer(tap)
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            addGestureRecognizer(tap)
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            let location = gesture.location(in: self)
            // The preview layer knows how the feed is cropped/scaled into the view
            // (.resizeAspectFill), so let it do the screen → device conversion.
            let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: location)
            onTapToFocus?(devicePoint)
            showReticle(at: location)
        }

        /// A brief yellow square that fades out, mirroring the system Camera app.
        private func showReticle(at point: CGPoint) {
            reticleView?.removeFromSuperview()

            let size: CGFloat = 78
            let reticle = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
            reticle.center = point
            reticle.layer.borderColor = UIColor.systemYellow.cgColor
            reticle.layer.borderWidth = 1.5
            reticle.layer.cornerRadius = 6
            reticle.backgroundColor = .clear
            reticle.isUserInteractionEnabled = false
            addSubview(reticle)
            reticleView = reticle

            reticle.alpha = 0
            reticle.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
            UIView.animate(withDuration: 0.2, animations: {
                reticle.alpha = 1
                reticle.transform = .identity
            }, completion: { _ in
                UIView.animate(withDuration: 0.4, delay: 0.6, options: [], animations: {
                    reticle.alpha = 0
                }, completion: { [weak reticle] _ in
                    reticle?.removeFromSuperview()
                })
            })
        }
    }
}
