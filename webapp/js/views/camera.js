//
//  views/camera.js
//  NotionScan Web
//
//  Home screen: live camera, shutter, flash/flip, zoom, batch thumbnail strip,
//  a "Done" button that opens Review, an Auto-mode toggle, a destination-database
//  picker, and a last-photo preview that opens the Gallery. Mirrors the iOS
//  `CameraView`.
//

import { el, clear } from "../dom.js";
import { CameraController, FlashMode } from "../camera.js";
import { AutoUploadManager } from "../autoUpload.js";

export class CameraScreen {
  constructor(app) {
    this.app = app;
    this.camera = new CameraController();
    this.autoUploader = new AutoUploadManager();

    /** In-memory batch (manual mode): array of {id, blob, objectURL}. */
    this.batch = [];
    this.databases = [];
    this.isLoadingDatabases = false;
    this._uploadedFlashTimer = null;
    this.showUploadedFlash = false;
    this._lastSuccess = null;

    this.element = el("div.screen.camera");
    this._buildLayout();

    this._onCameraChange = () => this.renderControls();
    this._onSettingsChange = () => this.renderControls();
    this._onAutoChange = () => this._handleAutoChange();

    this.camera.addEventListener("change", this._onCameraChange);
    this.app.settings.addEventListener("change", this._onSettingsChange);
    this.autoUploader.addEventListener("change", this._onAutoChange);
    this.app.gallery.addEventListener("change", this._onCameraChange);

    this.camera.onCapture = (photo) => this._handleCapture(photo);
  }

  get settings() {
    return this.app.settings;
  }

  get gallery() {
    return this.app.gallery;
  }

  // MARK: - Layout

  _buildLayout() {
    this.video = el("video.camera-video", { autoplay: true, playsinline: true, muted: true });
    this.reticleLayer = el("div.reticle-layer");
    this.previewWrap = el("div.preview-wrap", {}, [this.video, this.reticleLayer]);
    this.controls = el("div.controls-layer");
    this.permissionView = el("div.permission-view.hidden", {}, this._permissionContent());

    this.element.append(this.previewWrap, this.controls, this.permissionView);
    this.camera.attach(this.video);
    this._attachGestures();
    this.renderControls();
  }

  async start() {
    await this.camera.start();
    this.renderControls();
    this.loadDatabases();
  }

  stop() {
    this.camera.stop();
  }

  destroy() {
    this.camera.removeEventListener("change", this._onCameraChange);
    this.settings.removeEventListener("change", this._onSettingsChange);
    this.autoUploader.removeEventListener("change", this._onAutoChange);
    this.gallery.removeEventListener("change", this._onCameraChange);
    this.stop();
  }

  // MARK: - Controls (re-rendered on state change)

  renderControls() {
    clear(this.controls);
    this.permissionView.classList.toggle("hidden", !this.camera.permissionDenied);
    this.previewWrap.classList.toggle("hidden", this.camera.permissionDenied);
    if (this.camera.permissionDenied) return;

    this.controls.append(
      this._topBar(),
      this._databaseSelector(),
      this._autoModeToggle(),
      el("div.spacer"),
      this._bottomControls()
    );
  }

  _topBar() {
    return el("div.top-bar", {}, [
      iconButton(this._flashIcon(), "Toggle flash", () => this.camera.cycleFlash()),
      el("div.spacer"),
      iconButton("⚙", "Settings", () => this.app.openSettings()),
    ]);
  }

  _databaseSelector() {
    const name = this.settings.defaultDatabaseName || "Choose database";
    return el(
      "button.db-pill",
      {
        onclick: () => this._openDatabaseMenu(),
        "aria-label": "Destination database",
      },
      [
        el("span.db-pill-label", { text: "Saving to" }),
        el("span.db-pill-name", { text: name }),
        el("span.chevron", { text: "▾" }),
      ]
    );
  }

  _openDatabaseMenu() {
    const items = this.databases.map((db) => ({
      label: db.title,
      checked: db.id === this.settings.defaultDatabaseID,
      onClick: () => this.settings.setDefaultDatabase(db.id, db.title),
    }));
    if (items.length === 0) {
      items.push({ label: this.isLoadingDatabases ? "Loading…" : "No databases available", disabled: true });
    }
    items.push({
      label: "↻ Refresh databases",
      onClick: () => this.loadDatabases(),
    });
    this.app.openActionSheet({ title: "Save photos to", items });
  }

  _autoModeToggle() {
    const on = this.settings.autoUploadEnabled;
    let content;
    if (on) {
      if (this.autoUploader.inFlight > 0) {
        content = [el("span.spinner"), `Uploading ${this.autoUploader.inFlight}…`];
      } else if (this.showUploadedFlash) {
        content = [el("span.dot.green"), "Uploaded to Notion"];
      } else {
        content = [el("span.bolt", { text: "⚡" }), "Auto mode"];
      }
    } else {
      content = [el("span.bolt.dim", { text: "⚡" }), "Auto mode off"];
    }
    return el(
      "button.auto-pill",
      {
        class: on ? "auto-on" : "",
        onclick: () => {
          this.settings.autoUploadEnabled = !this.settings.autoUploadEnabled;
          if (navigator.vibrate) navigator.vibrate(15);
        },
        "aria-label": "Auto mode",
      },
      content
    );
  }

  _bottomControls() {
    const wrap = el("div.bottom-controls");

    if (this.batch.length > 0) {
      wrap.append(
        el("div.batch-row", {}, [
          iconButton("🗑", "Discard batch", () => this._confirmDiscard()),
          this._thumbnailStrip(),
          el(
            "button.btn.done-btn",
            { onclick: () => this.app.openReview(this) },
            `Done (${this.batch.length})`
          ),
        ])
      );
    }

    wrap.append(this._zoomControls());

    wrap.append(
      el("div.shutter-row", {}, [
        iconButton("⟲", "Flip camera", () => this.camera.flipCamera(), "flip-btn"),
        el("button.shutter", {
          disabled: !this.camera.isAuthorized,
          "aria-label": "Take photo",
          onclick: () => this.camera.capturePhoto(),
        }),
        this._lastPhotoPreview(),
      ])
    );

    return wrap;
  }

  _zoomControls() {
    if (this.camera.showsLensSelector) {
      return el(
        "div.lens-selector",
        {},
        this.camera.lensOptions.map((lens) => {
          const isActive = this.camera.activeLens && this.camera.activeLens.zoom === lens.zoom;
          return el(
            "button.lens-btn",
            {
              class: isActive ? "active" : "",
              onclick: () => this.camera.selectLens(lens),
              "aria-label": `${lens.displayName}× lens`,
            },
            isActive ? `${this.camera.displayZoomLabel}×` : lens.displayName
          );
        })
      );
    }
    if (this.camera.displayZoom > 1.05) {
      return el("div.zoom-pill", { text: `${this.camera.displayZoomLabel}×` });
    }
    return el("div.zoom-spacer");
  }

  _thumbnailStrip() {
    return el(
      "div.thumb-strip",
      {},
      this.batch.map((photo) => el("img.thumb", { src: photo.objectURL, alt: "" }))
    );
  }

  _lastPhotoPreview() {
    const first = this.gallery.items[0];
    if (!first) return el("div.last-photo-placeholder");
    const img = el("img.last-photo", { alt: "Open gallery" });
    this.gallery.objectURL(first.id).then((url) => {
      if (url) img.src = url;
    });
    return el("button.last-photo-btn", { onclick: () => this.app.openGallery(), "aria-label": "Open gallery" }, [img]);
  }

  _permissionContent() {
    return [
      el("div.permission-icon", { text: "📷" }),
      el("h2", { text: "Camera access is off" }),
      el("p", { text: "Allow camera access in your browser to take photos, then reload." }),
      el("button.btn.btn-primary", { onclick: () => this.start() }, "Try again"),
    ];
  }

  // MARK: - Capture handling

  async _handleCapture(photo) {
    // Every captured photo is persisted to the gallery as `pending`.
    await this.gallery.add(photo);
    if (this.settings.autoUploadEnabled && this.settings.defaultDatabaseID) {
      const client = this.settings.makeClient();
      if (client) {
        this.autoUploader.enqueue({
          itemID: photo.id,
          gallery: this.gallery,
          client,
          databaseID: this.settings.defaultDatabaseID,
          saveToPhotos: this.settings.saveToLibraryByDefault,
        });
      }
    } else {
      this.batch.push({ id: photo.id, blob: photo.blob, objectURL: URL.createObjectURL(photo.blob) });
    }
    this.renderControls();
  }

  _handleAutoChange() {
    if (this.autoUploader.lastSucceededAt && this.autoUploader.lastSucceededAt !== this._lastSuccess) {
      this._lastSuccess = this.autoUploader.lastSucceededAt;
      this.showUploadedFlash = true;
      clearTimeout(this._uploadedFlashTimer);
      this._uploadedFlashTimer = setTimeout(() => {
        this.showUploadedFlash = false;
        this.renderControls();
      }, 1500);
    }
    if (this.autoUploader.lastError) {
      this.app.toast(this.autoUploader.lastError);
      this.autoUploader.lastError = null;
    }
    this.renderControls();
  }

  // MARK: - Batch operations (used by Review too)

  removeFromBatch(id) {
    const index = this.batch.findIndex((p) => p.id === id);
    if (index >= 0) {
      URL.revokeObjectURL(this.batch[index].objectURL);
      this.batch.splice(index, 1);
    }
    this.gallery.delete(id);
    this.renderControls();
  }

  clearBatch() {
    for (const photo of this.batch) URL.revokeObjectURL(photo.objectURL);
    this.batch = [];
    this.renderControls();
  }

  _confirmDiscard() {
    const count = this.batch.length;
    this.app.confirm({
      title: `Discard ${count} photo${count === 1 ? "" : "s"}?`,
      message: "These photos haven't been uploaded and will be removed.",
      confirmLabel: "Discard",
      destructive: true,
      onConfirm: () => {
        // Each captured photo was also persisted to the gallery as pending; delete
        // those too so discarding doesn't leave orphaned, never-uploaded photos.
        for (const photo of this.batch) this.gallery.delete(photo.id);
        this.clearBatch();
      },
    });
  }

  // MARK: - Databases

  async loadDatabases() {
    const client = this.settings.makeClient();
    if (!client) return;
    this.isLoadingDatabases = true;
    try {
      const fetched = await client.listDatabases();
      this.databases = fetched;
    } catch {
      // Leave the existing list untouched; the pill still shows the current default.
    }
    this.isLoadingDatabases = false;
    this.renderControls();
  }

  // MARK: - Gestures

  _attachGestures() {
    const wrap = this.previewWrap;
    const pointers = new Map();
    let startDist = 0;
    let lastTap = 0;

    const distance = () => {
      const pts = [...pointers.values()];
      return Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
    };

    wrap.addEventListener("pointerdown", (e) => {
      pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
      if (pointers.size === 2) {
        startDist = distance();
        this.camera.beginZoomGesture();
      }
    });

    wrap.addEventListener("pointermove", (e) => {
      if (!pointers.has(e.pointerId)) return;
      pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
      if (pointers.size === 2 && startDist > 0) {
        const scale = distance() / startDist;
        this.camera.updateZoomGesture(scale);
      }
    });

    const release = (e) => {
      pointers.delete(e.pointerId);
      if (pointers.size < 2) startDist = 0;
    };
    wrap.addEventListener("pointerup", release);
    wrap.addEventListener("pointercancel", release);

    wrap.addEventListener("click", (e) => {
      // Ignore clicks that are part of a multi-touch pinch.
      if (pointers.size > 0) return;
      const now = Date.now();
      if (now - lastTap < 300) {
        this.camera.resetZoom();
        lastTap = 0;
        return;
      }
      lastTap = now;
      this._focusAt(e);
    });
  }

  _focusAt(e) {
    const rect = this.previewWrap.getBoundingClientRect();
    const x = (e.clientX - rect.left) / rect.width;
    const y = (e.clientY - rect.top) / rect.height;
    this.camera.focus({ x, y });
    this._showReticle(e.clientX - rect.left, e.clientY - rect.top);
  }

  _showReticle(x, y) {
    const reticle = el("div.reticle", { style: { left: `${x}px`, top: `${y}px` } });
    clear(this.reticleLayer);
    this.reticleLayer.append(reticle);
    // Force reflow then animate in/out via CSS classes.
    requestAnimationFrame(() => reticle.classList.add("show"));
    setTimeout(() => reticle.classList.add("fade"), 700);
    setTimeout(() => reticle.remove(), 1200);
  }

  _flashIcon() {
    switch (this.camera.flashMode) {
      case FlashMode.on:
        return "⚡";
      case FlashMode.auto:
        return "A⚡";
      default:
        return "⚡̸";
    }
  }
}

function iconButton(label, ariaLabel, onClick, extraClass = "") {
  return el(
    "button.icon-btn",
    { class: extraClass, onclick: onClick, "aria-label": ariaLabel },
    el("span.icon-glyph", { text: label })
  );
}
