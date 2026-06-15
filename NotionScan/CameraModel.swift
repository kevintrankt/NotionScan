//
//  CameraModel.swift
//  NotionScan
//
//  AVFoundation wrapper for a custom batch camera. The capture session runs
//  on its own queue; published state is updated on the main actor.
//

import AVFoundation
import UIKit
import Photos
import Combine

@MainActor
final class CameraModel: NSObject, ObservableObject {

    @Published var capturedPhotos: [CapturedPhoto] = []
    @Published var isAuthorized = false
    @Published var permissionDenied = false
    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published private(set) var position: AVCaptureDevice.Position = .back

    /// Called on the main actor for each captured photo. When set, the model does
    /// not append to `capturedPhotos` itself — the handler decides what to do.
    var onCapture: ((CapturedPhoto) -> Void)?

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "notionscan.camera.session")
    private var isConfigured = false

    /// Call from the camera screen's `.task`. Requests permission, configures, starts.
    func start() async {
        await requestAuthorizationIfNeeded()
        guard isAuthorized else { return }
        configureIfNeeded()
        let session = self.session
        sessionQueue.async {
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    func capturePhoto() {
        guard isAuthorized else { return }
        let flash = flashMode
        let output = self.output
        sessionQueue.async {
            let settings = AVCapturePhotoSettings()
            if output.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    /// Focus and meter exposure on a point the user tapped. `devicePoint` is in the
    /// camera's normalized coordinate space (0,0 top-left … 1,1 bottom-right), which
    /// the preview layer produces from a tap location. No-ops gracefully on hardware
    /// that doesn't support a focus/exposure point of interest (e.g. some front cameras).
    func focus(at devicePoint: CGPoint) {
        guard isAuthorized else { return }
        let session = self.session
        sessionQueue.async {
            guard let device = session.inputs
                .compactMap({ ($0 as? AVCaptureDeviceInput)?.device })
                .first else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }
                if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                // Configuration can fail if the device is briefly unavailable; ignore.
            }
        }
    }

    func flipCamera() {
        position = (position == .back) ? .front : .back
        let session = self.session
        let newPosition = position
        sessionQueue.async {
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            if let device = Self.device(for: newPosition),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
        }
    }

    func cycleFlash() {
        switch flashMode {
        case .off: flashMode = .on
        case .on: flashMode = .auto
        default: flashMode = .off
        }
    }

    func removePhoto(_ photo: CapturedPhoto) {
        capturedPhotos.removeAll { $0.id == photo.id }
    }

    func clearBatch() {
        capturedPhotos.removeAll()
    }

    // MARK: - Private

    private func requestAuthorizationIfNeeded() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isAuthorized = granted
            permissionDenied = !granted
        default:
            isAuthorized = false
            permissionDenied = true
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        let session = self.session
        let output = self.output
        let position = self.position
        sessionQueue.async {
            session.beginConfiguration()
            session.sessionPreset = .photo
            if let device = Self.device(for: position),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()
        }
    }

    nonisolated static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraModel: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        // Re-encode to a controlled JPEG quality for smaller, faster uploads.
        let jpeg = image.jpegData(compressionQuality: 0.8) ?? data
        Task { @MainActor in
            let photo = CapturedPhoto(image: image, jpegData: jpeg)
            if let onCapture = self.onCapture {
                onCapture(photo)
            } else {
                self.capturedPhotos.append(photo)
            }
        }
    }
}

// MARK: - Photo library saving (opt-in)

enum PhotoLibrarySaver {
    /// Requests add-only Photos permission and saves the images. Best-effort.
    static func save(_ images: [UIImage]) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        for image in images {
            try? await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        }
    }
}
