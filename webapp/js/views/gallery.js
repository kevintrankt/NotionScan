//
//  views/gallery.js
//  NotionScan Web
//
//  In-app gallery of every captured photo with its Notion upload status.
//  Doubles as the upload history: failed uploads can be retried, uploaded photos
//  link to their Notion page. Mirrors the iOS `GalleryView` (grid, multiselect,
//  mass delete, retry) and `GalleryDetailView`.
//

import { el, clear } from "../dom.js";
import { UploadStatus } from "../gallery.js";

export class GalleryOverlay {
  constructor(app, { onClose }) {
    this.app = app;
    this.onClose = onClose;

    this.isSelecting = false;
    this.selection = new Set();
    this.isRetrying = false;

    this.element = el("div.overlay.gallery-overlay");
    this._onChange = () => this.render();
    this.gallery.addEventListener("change", this._onChange);
    this.render();
  }

  get settings() {
    return this.app.settings;
  }

  get gallery() {
    return this.app.gallery;
  }

  get items() {
    return this.gallery.items;
  }

  destroy() {
    this.gallery.removeEventListener("change", this._onChange);
  }

  render() {
    clear(this.element);
    this.element.append(this._header());
    this.element.append(this.items.length === 0 ? this._emptyState() : this._grid());
    if (this.isSelecting) this.element.append(this._selectionBar());
  }

  _header() {
    if (this.isSelecting) {
      const allSelected = this.items.length > 0 && this.selection.size === this.items.length;
      return el("div.overlay-header", {}, [
        el("button.btn-text", { disabled: this.isRetrying, onclick: () => this._endSelecting() }, "Cancel"),
        el("h2.overlay-title", { text: this._title() }),
        el(
          "button.btn-text",
          {
            disabled: this.isRetrying,
            onclick: () => {
              if (allSelected) this.selection.clear();
              else this.selection = new Set(this.items.map((i) => i.id));
              this.render();
            },
          },
          allSelected ? "Deselect All" : "Select All"
        ),
      ]);
    }
    return el("div.overlay-header", {}, [
      this.items.length > 0
        ? el("button.btn-text", { onclick: () => this._beginSelecting() }, "Select")
        : el("span"),
      el("h2.overlay-title", { text: "Gallery" }),
      el("button.btn-text.strong", { onclick: () => this.close() }, "Done"),
    ]);
  }

  _title() {
    if (!this.isSelecting) return "Gallery";
    return this.selection.size === 0 ? "Select Photos" : `${this.selection.size} Selected`;
  }

  _grid() {
    return el(
      "div.gallery-grid",
      {},
      this.items.map((item) => this._cell(item))
    );
  }

  _cell(item) {
    const isSelected = this.selection.has(item.id);
    const isFailed = item.status === UploadStatus.failed;
    const img = el("img.gallery-img", { alt: "" });
    this.gallery.objectURL(item.id).then((url) => {
      if (url) img.src = url;
    });

    const cell = el(
      "div.gallery-cell",
      {
        class: [isFailed ? "failed" : "", isSelected ? "selected" : ""].filter(Boolean).join(" "),
      },
      [img, this._statusBadge(item.status)]
    );

    if (this.isSelecting) {
      cell.append(el("div.select-indicator", { class: isSelected ? "on" : "" }, isSelected ? "✓" : ""));
    }

    // Tap = open detail (or toggle in select mode); long-press = enter select mode.
    let pressTimer = null;
    let longPressed = false;
    cell.addEventListener("pointerdown", () => {
      longPressed = false;
      pressTimer = setTimeout(() => {
        longPressed = true;
        this._beginSelecting(item.id);
      }, 400);
    });
    const cancelTimer = () => clearTimeout(pressTimer);
    cell.addEventListener("pointerup", () => {
      cancelTimer();
      if (longPressed) return;
      if (this.isSelecting) this._toggle(item.id);
      else this.app.openGalleryDetail(item.id);
    });
    cell.addEventListener("pointercancel", cancelTimer);
    cell.addEventListener("pointerleave", cancelTimer);

    return cell;
  }

  _statusBadge(status) {
    switch (status) {
      case UploadStatus.pending:
        return el("span.status-badge.pending", { title: "Not uploaded", text: "🕒" });
      case UploadStatus.uploading:
        return el("span.status-badge.uploading", { title: "Uploading" }, el("span.spinner"));
      case UploadStatus.uploaded:
        return el("span.status-badge.uploaded", { title: "Uploaded", text: "✓" });
      case UploadStatus.failed:
        return el("span.status-badge.failed", { title: "Failed", text: "!" });
      default:
        return el("span");
    }
  }

  _selectionBar() {
    const failedCount = this.items.reduce(
      (n, item) => n + (this.selection.has(item.id) && item.status === UploadStatus.failed ? 1 : 0),
      0
    );
    return el("div.selection-bar", {}, [
      el(
        "button.btn-text.danger",
        {
          disabled: this.selection.size === 0 || this.isRetrying,
          onclick: () => this._confirmDelete(),
        },
        this.selection.size === 0 ? "Delete" : `Delete (${this.selection.size})`
      ),
      el("div.spacer"),
      el(
        "button.btn-text",
        {
          disabled: failedCount === 0 || this.isRetrying || this.settings.defaultDatabaseID == null,
          onclick: () => this._retrySelected(),
        },
        this.isRetrying
          ? [el("span.spinner"), "Retrying…"]
          : failedCount === 0
          ? "Retry"
          : `Retry (${failedCount})`
      ),
    ]);
  }

  _emptyState() {
    return el("div.empty-state", {}, [
      el("div.empty-icon", { text: "🖼" }),
      el("h3", { text: "No photos yet" }),
      el("p", { text: "Photos you capture will appear here with their upload status." }),
    ]);
  }

  // MARK: - Actions

  _beginSelecting(id) {
    if (this.isSelecting) {
      if (id) this.selection.add(id);
      this.render();
      return;
    }
    this.isSelecting = true;
    if (id) this.selection.add(id);
    if (navigator.vibrate) navigator.vibrate(10);
    this.render();
  }

  _endSelecting() {
    this.isSelecting = false;
    this.selection.clear();
    this.render();
  }

  _toggle(id) {
    if (this.selection.has(id)) this.selection.delete(id);
    else this.selection.add(id);
    this.render();
  }

  _confirmDelete() {
    const count = this.selection.size;
    this.app.confirm({
      title: `Delete ${count} photo${count === 1 ? "" : "s"}?`,
      confirmLabel: "Delete",
      destructive: true,
      onConfirm: async () => {
        await this.gallery.delete(new Set(this.selection));
        this._endSelecting();
      },
    });
  }

  async _retrySelected() {
    const client = this.settings.makeClient();
    const databaseID = this.settings.defaultDatabaseID;
    if (!client || !databaseID) return;
    this.isRetrying = true;
    this.render();
    await this.gallery.retryFailed({
      ids: new Set(this.selection),
      client,
      databaseID,
      saveToPhotos: this.settings.saveToLibraryByDefault,
    });
    this.isRetrying = false;
    this.render();
  }

  close() {
    this.onClose?.();
  }
}

// MARK: - Detail

export class GalleryDetailOverlay {
  constructor(app, itemID, { onClose }) {
    this.app = app;
    this.itemID = itemID;
    this.onClose = onClose;
    this.isRetrying = false;

    this.element = el("div.overlay.detail-overlay");
    this._onChange = () => this.render();
    this.gallery.addEventListener("change", this._onChange);
    this.render();
  }

  get settings() {
    return this.app.settings;
  }
  get gallery() {
    return this.app.gallery;
  }
  get item() {
    return this.gallery.items.find((i) => i.id === this.itemID);
  }

  destroy() {
    this.gallery.removeEventListener("change", this._onChange);
  }

  render() {
    clear(this.element);
    const item = this.item;
    this.element.append(
      el("div.overlay-header", {}, [
        el("span"),
        el("h2.overlay-title", { text: "Photo" }),
        el("button.btn-text.strong", { onclick: () => this.close() }, "Done"),
      ])
    );
    if (!item) {
      this.element.append(el("div.empty-state", {}, [el("p", { text: "Photo unavailable." })]));
      return;
    }

    const img = el("img.detail-img", { alt: "" });
    this.gallery.objectURL(item.id).then((url) => {
      if (url) img.src = url;
    });

    const body = el("div.overlay-body", {}, [
      img,
      el("div.detail-status-row", {}, [
        el("span", { text: this._statusText(item.status) }),
        el("span.hint", { text: new Date(item.createdAt).toLocaleString() }),
      ]),
    ]);

    if (item.errorMessage && item.status === UploadStatus.failed) {
      body.append(el("p.error", { text: item.errorMessage }));
    }

    body.append(this._actions(item));
    this.element.append(body);
  }

  _actions(item) {
    const actions = el("div.detail-actions");

    if (item.pageURL) {
      actions.append(
        el("a.btn.btn-primary.btn-block", { href: item.pageURL, target: "_blank", rel: "noopener" }, "Open in Notion ↗")
      );
    }

    if (item.status === UploadStatus.failed || item.status === UploadStatus.pending) {
      actions.append(
        el(
          "button.btn.btn-primary.btn-block",
          {
            disabled: this.isRetrying || this.settings.defaultDatabaseID == null,
            onclick: () => this._retry(),
          },
          this.isRetrying
            ? [el("span.spinner"), "Uploading…"]
            : item.status === UploadStatus.failed
            ? "Retry upload"
            : "Upload now"
        )
      );
    }

    actions.append(
      el(
        "button.btn.btn-bordered.btn-block.danger",
        {
          onclick: async () => {
            await this.gallery.delete(item.id);
            this.close();
          },
        },
        "Delete"
      )
    );
    return actions;
  }

  async _retry() {
    const client = this.settings.makeClient();
    const databaseID = this.settings.defaultDatabaseID;
    if (!client || !databaseID) return;
    this.isRetrying = true;
    this.render();
    try {
      await this.gallery.upload({
        itemID: this.itemID,
        client,
        databaseID,
        saveToPhotos: this.settings.saveToLibraryByDefault,
      });
    } catch {
      /* status + error already recorded on the item */
    }
    this.isRetrying = false;
    this.render();
  }

  _statusText(status) {
    switch (status) {
      case UploadStatus.pending:
        return "Not uploaded";
      case UploadStatus.uploading:
        return "Uploading…";
      case UploadStatus.uploaded:
        return "Uploaded to Notion";
      case UploadStatus.failed:
        return "Upload failed";
      default:
        return "";
    }
  }

  close() {
    this.onClose?.();
  }
}
