//
//  autoUpload.js
//  NotionScan Web
//
//  Handles "auto mode": each captured photo is uploaded immediately as its own
//  one-photo Notion page, with no review step. Uploads run sequentially so rapid
//  captures don't race. The actual upload + status tracking lives in GalleryStore.
//  Mirrors the iOS `AutoUploadManager`.
//

import { NotionError } from "./notion.js";

export class AutoUploadManager extends EventTarget {
  constructor() {
    super();
    /** Number of photos still uploading or queued. */
    this.inFlight = 0;
    /** Timestamp set briefly after a successful upload, to flash a confirmation. */
    this.lastSucceededAt = null;
    /** Most recent error message, if any. */
    this.lastError = null;

    this._queue = [];
    this._isProcessing = false;
  }

  _notify() {
    this.dispatchEvent(new Event("change"));
  }

  enqueue({ itemID, gallery, client, databaseID, saveToPhotos }) {
    this._queue.push({ itemID, gallery, client, databaseID, saveToPhotos });
    this.inFlight = this._queue.length + (this._isProcessing ? 1 : 0);
    this._notify();
    this._process();
  }

  async _process() {
    if (this._isProcessing) return;
    this._isProcessing = true;

    while (this._queue.length) {
      const job = this._queue.shift();
      this.inFlight = this._queue.length + 1;
      this._notify();
      try {
        await job.gallery.upload({
          itemID: job.itemID,
          client: job.client,
          databaseID: job.databaseID,
          saveToPhotos: job.saveToPhotos,
        });
        this.lastSucceededAt = Date.now();
        this.lastError = null;
      } catch (error) {
        this.lastError = error instanceof NotionError ? error.message : error?.message || String(error);
      }
      this.inFlight = this._queue.length;
      this._notify();
    }

    this._isProcessing = false;
  }
}
