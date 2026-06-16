//
//  camera.js
//  NotionScan Web
//
//  getUserMedia wrapper for a custom batch camera, mirroring the iOS
//  `CameraModel` (permissions, start/stop, capture, flash/torch, flip, zoom,
//  tap-to-focus). The browser's MediaStream API is the web analogue of
//  AVFoundation; capabilities (torch, zoom, focus) vary by device and browser,
//  so each is feature-detected and degrades gracefully — exactly as the iOS code
//  no-ops on hardware that lacks a focus point of interest.
//

export const FlashMode = { off: "off", on: "on", auto: "auto" };

export class CameraController extends EventTarget {
  constructor() {
    super();
    this.isAuthorized = false;
    this.permissionDenied = false;
    this.flashMode = FlashMode.off;
    this.position = "environment"; // "environment" (back) | "user" (front)

    // Zoom state, populated from the active track's capabilities.
    this.zoom = 1;
    this.minZoom = 1;
    this.maxZoom = 1;
    this.zoomStep = 0.1;
    this.lensOptions = []; // [{displayName, zoom}]
    this._zoomGestureBase = 1;

    this.torchAvailable = false;

    /** Called with each captured photo {id, blob}; the view decides what to do. */
    this.onCapture = null;

    this._stream = null;
    this._track = null;
    this._video = null;
  }

  _notify() {
    this.dispatchEvent(new Event("change"));
  }

  get supportsZoom() {
    return this.maxZoom > this.minZoom + 0.001;
  }

  get showsLensSelector() {
    return this.lensOptions.length > 1;
  }

  /** Display zoom relative to the base lens (e.g. "1.5×"). */
  get displayZoom() {
    return this.minZoom > 0 ? this.zoom / this.minZoom : this.zoom;
  }

  get displayZoomLabel() {
    return CameraController.zoomLabel(this.displayZoom);
  }

  /** The preset whose range currently contains `zoom` (the highlighted button). */
  get activeLens() {
    let active = this.lensOptions[0];
    for (const lens of this.lensOptions) {
      if (this.zoom + 0.001 >= lens.zoom) active = lens;
    }
    return active;
  }

  // MARK: - Lifecycle

  /** Attach the <video> element the preview renders into. */
  attach(videoEl) {
    this._video = videoEl;
  }

  /** Requests permission, configures, and starts the live preview. */
  async start() {
    if (!navigator.mediaDevices?.getUserMedia) {
      this.permissionDenied = true;
      this._notify();
      return;
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: { ideal: this.position } },
        audio: false,
      });
      this._attachStream(stream);
      this.isAuthorized = true;
      this.permissionDenied = false;
    } catch (error) {
      // NotAllowedError = denied; others (no camera, in use) also block capture.
      this.isAuthorized = false;
      this.permissionDenied = true;
    }
    this._notify();
  }

  stop() {
    if (this._stream) {
      for (const track of this._stream.getTracks()) track.stop();
    }
    this._stream = null;
    this._track = null;
    if (this._video) this._video.srcObject = null;
  }

  _attachStream(stream) {
    this._stream = stream;
    this._track = stream.getVideoTracks()[0] || null;
    if (this._video) {
      this._video.srcObject = stream;
      this._video.play?.().catch(() => {});
    }
    this._readCapabilities();
  }

  _readCapabilities() {
    this.torchAvailable = false;
    this.lensOptions = [];
    this.minZoom = 1;
    this.maxZoom = 1;
    this.zoom = 1;

    const caps = this._track?.getCapabilities?.();
    if (!caps) return;

    if ("torch" in caps) this.torchAvailable = !!caps.torch;

    if (caps.zoom && typeof caps.zoom.max === "number") {
      this.minZoom = caps.zoom.min ?? 1;
      this.maxZoom = caps.zoom.max;
      this.zoomStep = caps.zoom.step || 0.1;
      const settings = this._track.getSettings?.();
      this.zoom = settings?.zoom ?? this.minZoom;
      this._zoomGestureBase = this.zoom;
      this.lensOptions = this._buildLensPresets();
    }
  }

  /**
   * The web can't enumerate physical lenses the way AVFoundation can, so we
   * approximate the iOS lens picker with a few zoom presets (1×, 2×, 5×, max)
   * that fall inside the device's supported zoom range.
   */
  _buildLensPresets() {
    const base = this.minZoom;
    const candidates = [base, base * 2, base * 5];
    const presets = candidates.filter((z) => z <= this.maxZoom + 0.001);
    // Include the device maximum as a final stop if it's meaningfully past the last preset.
    if (this.maxZoom > presets[presets.length - 1] * 1.2) presets.push(this.maxZoom);
    if (presets.length < 2) return [];
    return presets.map((z) => ({
      displayName: CameraController.zoomLabel(z / base),
      zoom: z,
    }));
  }

  // MARK: - Capture

  capturePhoto() {
    if (!this.isAuthorized || !this._video) return;
    const video = this._video;
    const width = video.videoWidth;
    const height = video.videoHeight;
    if (!width || !height) return;

    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext("2d");
    // Front camera preview is mirrored for the user; un-mirror the saved frame
    // so the photo matches what a normal camera would record.
    if (this.position === "user") {
      ctx.translate(width, 0);
      ctx.scale(-1, 1);
    }
    ctx.drawImage(video, 0, 0, width, height);

    canvas.toBlob(
      (blob) => {
        if (!blob) return;
        const photo = { id: crypto.randomUUID(), blob };
        this.onCapture?.(photo);
      },
      "image/jpeg",
      0.8
    );
  }

  // MARK: - Controls

  async flipCamera() {
    this.position = this.position === "environment" ? "user" : "environment";
    this.flashMode = FlashMode.off;
    this.stop();
    await this.start();
  }

  cycleFlash() {
    this.flashMode =
      this.flashMode === FlashMode.off
        ? FlashMode.on
        : this.flashMode === FlashMode.on
        ? FlashMode.auto
        : FlashMode.off;
    this._applyTorch();
    this._notify();
  }

  _applyTorch() {
    if (!this._track || !this.torchAvailable) return;
    const torch = this.flashMode === FlashMode.on;
    this._track.applyConstraints({ advanced: [{ torch }] }).catch(() => {});
  }

  // MARK: - Zoom

  beginZoomGesture() {
    this._zoomGestureBase = this.zoom;
  }

  updateZoomGesture(scale) {
    this.setZoom(this._zoomGestureBase * scale);
  }

  selectLens(lens) {
    this.setZoom(lens.zoom);
  }

  resetZoom() {
    this.setZoom(this.minZoom);
  }

  setZoom(value) {
    if (!this.supportsZoom || !this._track) return;
    const clamped = CameraController.clamp(value, this.minZoom, this.maxZoom);
    this.zoom = clamped;
    this._track.applyConstraints({ advanced: [{ zoom: clamped }] }).catch(() => {});
    this._notify();
  }

  // MARK: - Focus

  /**
   * Best-effort tap-to-focus. `point` is normalized (0..1). Most browsers don't
   * support a focus point of interest, so this commonly no-ops — matching the
   * iOS behaviour on hardware without `isFocusPointOfInterestSupported`.
   */
  focus(point) {
    if (!this._track) return;
    const caps = this._track.getCapabilities?.() || {};
    const advanced = [];
    if (Array.isArray(caps.focusMode) && caps.focusMode.includes("single-shot")) {
      advanced.push({ focusMode: "single-shot" });
    }
    if (caps.pointsOfInterest) {
      advanced.push({ pointsOfInterest: [{ x: point.x, y: point.y }] });
    }
    if (advanced.length) this._track.applyConstraints({ advanced }).catch(() => {});
  }

  // MARK: - Static helpers

  static zoomLabel(value) {
    if (Math.abs(Math.round(value) - value) < 0.05) return String(Math.round(value));
    return value.toFixed(1);
  }

  static clamp(value, lower, upper) {
    return Math.min(Math.max(value, lower), upper);
  }
}
