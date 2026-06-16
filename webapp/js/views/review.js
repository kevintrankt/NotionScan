//
//  views/review.js
//  NotionScan Web
//
//  Review a captured batch: delete bad shots, choose the destination database,
//  optionally save to the device, then upload as a single Notion page. Mirrors
//  the iOS `ReviewView`.
//

import { el, clear, downloadBlob } from "../dom.js";
import { formatTitle } from "../gallery.js";

export class ReviewOverlay {
  constructor(app, cameraScreen, { onClose }) {
    this.app = app;
    this.cameraScreen = cameraScreen;
    this.onClose = onClose;

    this.databases = [];
    this.selectedDatabaseID = this.settings.defaultDatabaseID;
    this.saveToPhotos = this.settings.saveToLibraryByDefault;
    this.isLoadingDatabases = false;
    this.uploadState = { kind: "idle" };
    this.errorMessage = null;

    this.element = el("div.overlay.review-overlay");
    this.render();
    this.loadDatabases();
  }

  get settings() {
    return this.app.settings;
  }

  get gallery() {
    return this.app.gallery;
  }

  get batch() {
    return this.cameraScreen.batch;
  }

  get isUploading() {
    return this.uploadState.kind === "uploading" || this.uploadState.kind === "creatingPage";
  }

  get canUpload() {
    return this.batch.length > 0 && this.selectedDatabaseID != null && !this.isUploading;
  }

  render() {
    clear(this.element);
    const count = this.batch.length;

    const header = el("div.overlay-header", {}, [
      el("button.btn-text", { disabled: this.isUploading, onclick: () => this.close() }, "Back"),
      el("h2.overlay-title", { text: `Review ${count} photo${count === 1 ? "" : "s"}` }),
      el(
        "button.btn-text.strong",
        { disabled: !this.canUpload, onclick: () => this.upload() },
        "Upload"
      ),
    ]);

    this.element.append(header, this._body());
    if (this.isUploading) this.element.append(this._uploadOverlay());
  }

  _body() {
    return el("div.overlay-body", {}, [
      this._photoGrid(),
      this._destinationSection(),
      el("label.toggle-row", {}, [
        el("span", { text: "Save to device" }),
        el("input", {
          type: "checkbox",
          checked: this.saveToPhotos,
          onchange: (e) => (this.saveToPhotos = e.target.checked),
        }),
      ]),
    ]);
  }

  _photoGrid() {
    return el(
      "div.review-grid",
      {},
      this.batch.map((photo) =>
        el("div.review-cell", {}, [
          el("img", { src: photo.objectURL, alt: "" }),
          el(
            "button.delete-badge",
            {
              disabled: this.isUploading,
              "aria-label": "Remove photo",
              onclick: () => {
                this.cameraScreen.removeFromBatch(photo.id);
                if (this.batch.length === 0) this.close();
                else this.render();
              },
            },
            "✕"
          ),
        ])
      )
    );
  }

  _destinationSection() {
    let body;
    if (this.isLoadingDatabases) {
      body = el("div.row.gap", {}, [el("span.spinner"), el("span.hint", { text: "Loading databases…" })]);
    } else if (this.databases.length === 0) {
      body = el("p.hint", {
        text:
          "No databases found. Make sure your integration is shared with the database in Notion " +
          "(••• → Connections).",
      });
    } else {
      body = el(
        "select.field",
        {
          onchange: (e) => (this.selectedDatabaseID = e.target.value),
        },
        this.databases.map((db) =>
          el("option", { value: db.id, selected: db.id === this.selectedDatabaseID, text: db.title })
        )
      );
    }
    return el("section.card", {}, [el("h3.subtitle", { text: "Destination database" }), body]);
  }

  _uploadOverlay() {
    return el("div.upload-overlay", {}, [
      el("div.upload-box", {}, [el("span.spinner.large"), el("p", { text: this._uploadStatusText() })]),
    ]);
  }

  _uploadStatusText() {
    switch (this.uploadState.kind) {
      case "uploading":
        return `Uploading ${this.uploadState.done} of ${this.uploadState.total}…`;
      case "creatingPage":
        return "Creating Notion page…";
      default:
        return "";
    }
  }

  // MARK: - Actions

  async loadDatabases() {
    const client = this.settings.makeClient();
    if (!client) return;
    this.isLoadingDatabases = true;
    this.render();
    try {
      const result = await client.listDatabases();
      this.databases = result;
      if (this.selectedDatabaseID == null || !result.some((d) => d.id === this.selectedDatabaseID)) {
        this.selectedDatabaseID =
          result.find((d) => d.id === this.settings.defaultDatabaseID)?.id ?? result[0]?.id ?? null;
      }
    } catch (error) {
      this.errorMessage = error?.message || String(error);
      this.app.toast(this.errorMessage);
    }
    this.isLoadingDatabases = false;
    this.render();
  }

  async upload() {
    const client = this.settings.makeClient();
    const databaseID = this.selectedDatabaseID;
    if (!client || !databaseID) return;

    const photos = [...this.batch];
    const total = photos.length;

    try {
      const fileUploadIDs = [];
      this.uploadState = { kind: "uploading", done: 0, total };
      this.render();
      for (let i = 0; i < photos.length; i++) {
        const id = await client.uploadImage(photos[i].blob);
        fileUploadIDs.push(id);
        this.uploadState = { kind: "uploading", done: i + 1, total };
        this.render();
      }

      this.uploadState = { kind: "creatingPage" };
      this.render();
      const title = `NotionScan ${formatTitle(new Date(), false)}`;
      const response = await client.createBatchPage(databaseID, title, fileUploadIDs);

      for (const photo of photos) {
        await this.gallery.markUploaded(photo.id, response.url, databaseID);
      }
      if (this.saveToPhotos) {
        for (const photo of photos) downloadBlob(photo.blob, `notionscan-${photo.id}.jpg`);
      }

      this.uploadState = { kind: "success" };
      this.cameraScreen.clearBatch();
      this.app.toast("Uploaded to Notion ✓");
      this.close();
    } catch (error) {
      this.uploadState = { kind: "idle" };
      this.errorMessage = error?.message || String(error);
      this.app.toast(this.errorMessage);
      this.render();
    }
  }

  close() {
    if (this.isUploading) return;
    this.onClose?.();
  }
}
