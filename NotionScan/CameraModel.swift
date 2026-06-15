//
//  CameraModel.swift
//  NotionScan
//
//  AVFoundation wrapper for a custom batch camera. The capture session runs
//  on its own queue; published state is updated on the main actor.
//

@preconcurrency import AVFoundation
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

    // MARK: Zoom

    /// The active device's raw `videoZoomFactor`. We keep an optimistic copy here so
    /// the UI updates immediately; the device itself is set asynchronously on the
    /// session queue.
    @Published private(set) var zoomFactor: CGFloat = 1.0

    /// The lenses the current device can switch between (e.g. 0.5× / 1× / 2×). Empty
    /// or single-element on hardware with one camera (most front cameras), in which
    /// case the lens picker is hidden.
    @Published private(set) var lensOptions: [LensOption] = []

    /// Bounds for `zoomFactor` on the current device, cached from the device so we can
    /// clamp on the main actor without touching `AVCaptureDevice` off the session queue.
    @Published private(set) var minZoomFactor: CGFloat = 1.0
    @Published private(set) var maxZoomFactor: CGFloat = 1.0

    /// The raw zoom factor that corresponds to the marketed "1×" (the wide-angle lens).
    /// Display zoom is `zoomFactor / referenceZoomFactor`, so an ultra-wide lens reads
    /// as 0.5× and a 3× telephoto reads as 3×.
    private var referenceZoomFactor: CGFloat = 1.0
    /// Where zoom resets to (the wide-angle "1×" lens).
    private var defaultZoomFactor: CGFloat = 1.0
    /// The zoom factor captured when a pinch begins, so the gesture scales relative to it.
    private var zoomGestureBaseFactor: CGFloat = 1.0

    /// One selectable lens on the lens picker, e.g. the ultra-wide ("0.5") or telephoto ("3").
    struct LensOption: Identifiable, Equatable, Sendable {
        /// User-facing zoom number for this lens, e.g. "0.5", "1", "3".
        let displayName: String
        /// The raw `videoZoomFactor` at which this lens becomes active.
        let deviceZoomFactor: CGFloat
        var id: CGFloat { deviceZoomFactor }
    }

    /// Display zoom (what the user thinks of as "1.5×"), relative to the wide lens.
    var displayZoomFactor: CGFloat {
        referenceZoomFactor > 0 ? zoomFactor / referenceZoomFactor : zoomFactor
    }

    /// Formatted display zoom for the indicator, e.g. "1", "1.5", "0.5".
    var displayZoomLabel: String { Self.zoomLabel(displayZoomFactor) }

    /// Whether to show the lens picker (only meaningful when there's a choice of lens).
    var showsLensSelector: Bool { lensOptions.count > 1 }

    /// The lens whose range currently contains `zoomFactor` (the highlighted button).
    var activeLens: LensOption? {
        lensOptions.last { zoomFactor + 0.001 >= $0.deviceZoomFactor } ?? lensOptions.first
    }

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

    // MARK: - Zoom controls

    /// Call when a pinch gesture begins, to anchor the gesture to the current zoom.
    func beginZoomGesture() {
        zoomGestureBaseFactor = zoomFactor
    }

    /// Call as a pinch gesture updates. `scale` is the gesture's cumulative scale
    /// since it began (1.0 at the start), so the new zoom is the anchor times scale.
    func updateZoomGesture(scale: CGFloat) {
        setZoom(to: zoomGestureBaseFactor * scale)
    }

    /// Jumps to a specific lens (smoothly ramped), e.g. when a lens button is tapped.
    func selectLens(_ lens: LensOption) {
        setZoom(to: lens.deviceZoomFactor, ramp: true)
    }

    /// Resets zoom back to the wide-angle "1×" lens (smoothly ramped).
    func resetZoom() {
        setZoom(to: defaultZoomFactor, ramp: true)
    }

    /// Sets the zoom to a raw device factor, clamped to the current device's range.
    /// `ramp` animates the transition (used for lens jumps); pinch uses a direct set.
    func setZoom(to factor: CGFloat, ramp: Bool = false) {
        let clamped = Self.clamp(factor, min: minZoomFactor, max: maxZoomFactor)
        zoomFactor = clamped
        applyZoom(to: clamped, ramp: ramp)
    }

    private func applyZoom(to factor: CGFloat, ramp: Bool) {
        let session = self.session
        sessionQueue.async {
            guard let device = session.inputs
                .compactMap({ ($0 as? AVCaptureDeviceInput)?.device })
                .first else { return }
            do {
                try device.lockForConfiguration()
                let clamped = Self.clamp(factor,
                                         min: device.minAvailableVideoZoomFactor,
                                         max: device.maxAvailableVideoZoomFactor)
                if ramp {
                    device.ramp(toVideoZoomFactor: clamped, withRate: 8.0)
                } else {
                    // Cancel any in-flight ramp so a pinch takes over immediately.
                    device.cancelVideoZoomRamp()
                    device.videoZoomFactor = clamped
                }
                device.unlockForConfiguration()
            } catch {
                // Device briefly unavailable; ignore and keep the last applied zoom.
            }
        }
    }

    /// Publishes the zoom capabilities of a freshly configured device and resets the
    /// live zoom state to its default (wide) lens. Runs on the main actor.
    private func applyZoomInfo(_ info: ZoomInfo) {
        minZoomFactor = info.minFactor
        maxZoomFactor = info.maxFactor
        referenceZoomFactor = info.referenceFactor
        defaultZoomFactor = info.defaultFactor
        lensOptions = info.lenses
        zoomFactor = info.defaultFactor
        zoomGestureBaseFactor = info.defaultFactor
    }

    func flipCamera() {
        position = (position == .back) ? .front : .back
        let session = self.session
        let newPosition = position
        sessionQueue.async {
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            let info = Self.addVideoInput(for: newPosition, to: session)
            session.commitConfiguration()
            if let info {
                Task { @MainActor in self.applyZoomInfo(info) }
            }
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
            let info = Self.addVideoInput(for: position, to: session)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()
            if let info {
                Task { @MainActor in self.applyZoomInfo(info) }
            }
        }
    }

    /// Adds the best zoomable camera for `position` to the session and returns the
    /// resulting zoom capabilities, or `nil` if no camera could be added. Runs on the
    /// session queue. Also seeds the device to the "1×" (wide) lens so the preview opens
    /// at the familiar field of view rather than the ultra-wide that a virtual device
    /// reports as its raw minimum.
    nonisolated private static func addVideoInput(for position: AVCaptureDevice.Position,
                                                  to session: AVCaptureSession) -> ZoomInfo? {
        guard let device = zoomableDevice(for: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return nil }
        session.addInput(input)
        let info = zoomInfo(for: device)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamp(info.defaultFactor,
                                           min: device.minAvailableVideoZoomFactor,
                                           max: device.maxAvailableVideoZoomFactor)
            device.unlockForConfiguration()
        } catch {
            // Device briefly unavailable; the preview still opens at its own default.
        }
        return info
    }

    /// Picks the richest multi-lens camera available for a position so that zooming
    /// transitions optically between the ultra-wide, wide, and telephoto lenses. Falls
    /// back through progressively simpler virtual devices to a plain wide-angle camera.
    nonisolated static func zoomableDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let preferredTypes: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        for type in preferredTypes {
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [type],
                                                             mediaType: .video,
                                                             position: position)
            if let device = discovery.devices.first { return device }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// The zoom capabilities of a device, computed off the device once at configuration
    /// time so the main actor never has to read `AVCaptureDevice` properties directly.
    struct ZoomInfo: Sendable {
        let minFactor: CGFloat
        let maxFactor: CGFloat
        let referenceFactor: CGFloat
        let defaultFactor: CGFloat
        let lenses: [LensOption]
    }

    /// Derives the lens picker and zoom range from a (possibly virtual) capture device.
    ///
    /// A virtual device such as the triple camera exposes its constituent lenses in
    /// order from widest to longest, plus the zoom factors at which it switches between
    /// them (`virtualDeviceSwitchOverVideoZoomFactors`). The widest lens starts at the
    /// device minimum (1.0); each switch-over factor is where the next lens takes over.
    /// We treat the wide-angle lens as the marketed "1×", so the ultra-wide reads as
    /// 0.5× and a telephoto as 2×/3×/5× — matching the stock Camera app.
    nonisolated static func zoomInfo(for device: AVCaptureDevice) -> ZoomInfo {
        let minFactor = device.minAvailableVideoZoomFactor
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        let constituents = device.constituentDevices

        // The raw zoom factor at which each lens (widest → longest) becomes active.
        let startFactors: [CGFloat] = [minFactor] + switchOvers

        // "1×" is the wide-angle lens if this device has one; otherwise the base zoom.
        var referenceFactor = minFactor
        if let wideIndex = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }),
           wideIndex < startFactors.count {
            referenceFactor = startFactors[wideIndex]
        }

        // Build a lens button per physical lens. Only meaningful on multi-lens devices.
        var lenses: [LensOption] = []
        if constituents.count > 1 {
            for (index, factor) in startFactors.enumerated() where index < constituents.count {
                let display = referenceFactor > 0 ? factor / referenceFactor : factor
                lenses.append(LensOption(displayName: zoomLabel(display), deviceZoomFactor: factor))
            }
        }

        // Allow digital zoom past the longest lens, but cap it to a sane 10× of "1×".
        let maxFactor = Swift.min(device.maxAvailableVideoZoomFactor, referenceFactor * 10)

        return ZoomInfo(minFactor: minFactor,
                        maxFactor: Swift.max(maxFactor, referenceFactor),
                        referenceFactor: referenceFactor,
                        defaultFactor: referenceFactor,
                        lenses: lenses)
    }

    /// Formats a display-zoom number compactly: whole numbers drop the decimal
    /// ("1", "2", "3"), fractional values keep one place ("0.5", "1.5").
    nonisolated static func zoomLabel(_ value: CGFloat) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return String(format: "%.0f", Double(value))
        }
        return String(format: "%.1f", Double(value))
    }

    nonisolated static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), upper)
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
