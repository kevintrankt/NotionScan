//
//  gallery.js
//  NotionScan Web
//
//  Persistent, on-device gallery of every photo the app has captured, with each
//  photo's Notion upload status. Mirrors the iOS `GalleryStore`.
//
//  On iOS, photos are JPEG files on disk and metadata is a JSON sidecar. On the
//  web the equivalent durable, no-backend store is IndexedDB: each record holds
//  the JPEG `Blob` plus its metadata. (localStorage is unsuitable for image
//  bytes — it's tiny and string-only — so settings live in localStorage and
//  photos live in IndexedDB. Both are fully client-side.)
//

import { NotionError } from "./notion.js";
import { downloadBlob } from "./dom.js";

export const UploadStatus = {
  pending: "pending", // captured, not yet uploaded
  uploading: "uploading",
  uploaded: "uploaded",
  failed: "failed",
};

const DB_NAME = "notionscan";
const DB_VERSION = 1;
const STORE = "photos";

/** Shown on photos whose upload was cut short by the tab closing (see `load`). */
export const INTERRUPTED_MESSAGE =
  "This photo wasn't uploaded before the app closed. Tap retry to upload it now.";

export class GalleryStore extends EventTarget {
  constructor() {
    super();
    /** @type {Array<object>} metadata only (no blob), newest first. */
    this.items = [];
    this._db = null;
    this._objectURLs = new Map(); // id -> object URL cache
  }

  _notify() {
    this.dispatchEvent(new Event("change"));
  }

  // MARK: - Setup

  async open() {
    this._db = await new Promise((resolve, reject) => {
      const request = indexedDB.open(DB_NAME, DB_VERSION);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains(STORE)) {
          db.createObjectStore(STORE, { keyPath: "id" });
        }
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    await this.load();
  }

  async load() {
    const records = await this._all();
    // Newest first, matching the iOS `items.insert(at: 0)` ordering.
    records.sort((a, b) => b.createdAt - a.createdAt);

    // An upload only makes progress while the tab is open — the async task that
    // does the work dies with the page. So any item still marked `uploading`
    // (interrupted mid-upload) or `pending` (captured but never sent) when we
    // load was stranded by the app closing. Surface these as `failed` so they're
    // flagged in the gallery and can be retried, instead of sitting silently.
    let didReconcile = false;
    for (const record of records) {
      if (record.status === UploadStatus.uploading || record.status === UploadStatus.pending) {
        record.status = UploadStatus.failed;
        record.errorMessage = INTERRUPTED_MESSAGE;
        await this._put(record);
        didReconcile = true;
      }
    }

    this.items = records.map(stripBlob);
    this._notify();
    if (didReconcile) this._notify();
  }

  // MARK: - Reading images

  /** Returns (and caches) an object URL for the item's blob, or null. */
  async objectURL(id) {
    if (this._objectURLs.has(id)) return this._objectURLs.get(id);
    const blob = await this.getBlob(id);
    if (!blob) return null;
    const url = URL.createObjectURL(blob);
    this._objectURLs.set(id, url);
    return url;
  }

  async getBlob(id) {
    const record = await this._get(id);
    return record?.blob ?? null;
  }

  // MARK: - Mutations

  /**
   * Persists a freshly captured photo and returns its new gallery item.
   * @param {{id: string, blob: Blob}} photo
   */
  async add(photo) {
    const record = {
      id: photo.id,
      createdAt: Date.now(),
      blob: photo.blob,
      status: UploadStatus.pending,
      databaseID: null,
      pageURL: null,
      errorMessage: null,
    };
    await this._put(record);
    this.items.unshift(stripBlob(record));
    this._notify();
    return stripBlob(record);
  }

  async delete(idOrIds) {
    const ids = idOrIds instanceof Set ? [...idOrIds] : [idOrIds];
    if (!ids.length) return;
    for (const id of ids) {
      await this._delete(id);
      const url = this._objectURLs.get(id);
      if (url) {
        URL.revokeObjectURL(url);
        this._objectURLs.delete(id);
      }
    }
    const idSet = new Set(ids);
    this.items = this.items.filter((item) => !idSet.has(item.id));
    this._notify();
  }

  async markUploading(id) {
    await this._update(id, (record) => {
      record.status = UploadStatus.uploading;
      record.errorMessage = null;
    });
  }

  async markUploaded(id, pageURL, databaseID) {
    await this._update(id, (record) => {
      record.status = UploadStatus.uploaded;
      record.pageURL = pageURL ?? null;
      record.databaseID = databaseID ?? null;
      record.errorMessage = null;
    });
  }

  async markFailed(id, error) {
    await this._update(id, (record) => {
      record.status = UploadStatus.failed;
      record.errorMessage = error;
    });
  }

  // MARK: - Upload (single photo -> single page)

  /**
   * Uploads one gallery item as its own Notion page and updates its status.
   * Used by auto mode and by manual retries from the gallery.
   */
  async upload({ itemID, client, databaseID, saveToPhotos }) {
    const blob = await this.getBlob(itemID);
    const item = this.items.find((i) => i.id === itemID);
    if (!blob || !item) {
      throw NotionError.network("This photo's data is missing.");
    }
    await this.markUploading(itemID);
    try {
      const fileID = await client.uploadImage(blob);
      const title = `NotionScan ${formatTitle(new Date(item.createdAt), true)}`;
      const response = await client.createBatchPage(databaseID, title, [fileID]);
      if (saveToPhotos) downloadBlob(blob, `notionscan-${itemID}.jpg`);
      await this.markUploaded(itemID, response.url, databaseID);
      return response;
    } catch (error) {
      await this.markFailed(itemID, friendlyMessage(error));
      throw error;
    }
  }

  /**
   * Retries every *failed* item in `ids`, one at a time so the uploads don't
   * race each other. Items in `ids` that aren't failed are skipped. Returns the
   * number that failed again, so the caller can surface a summary if it wants.
   */
  async retryFailed({ ids, client, databaseID, saveToPhotos }) {
    const idSet = ids instanceof Set ? ids : new Set(ids);
    const targets = this.items.filter(
      (item) => idSet.has(item.id) && item.status === UploadStatus.failed
    );
    let failures = 0;
    for (const target of targets) {
      try {
        await this.upload({ itemID: target.id, client, databaseID, saveToPhotos });
      } catch {
        failures += 1;
      }
    }
    return failures;
  }

  // MARK: - Private (memory + IndexedDB)

  async _update(id, transform) {
    const record = await this._get(id);
    if (!record) return;
    transform(record);
    await this._put(record);
    const index = this.items.findIndex((i) => i.id === id);
    if (index >= 0) this.items[index] = stripBlob(record);
    this._notify();
  }

  _tx(mode) {
    return this._db.transaction(STORE, mode).objectStore(STORE);
  }

  _all() {
    return new Promise((resolve, reject) => {
      const request = this._tx("readonly").getAll();
      request.onsuccess = () => resolve(request.result || []);
      request.onerror = () => reject(request.error);
    });
  }

  _get(id) {
    return new Promise((resolve, reject) => {
      const request = this._tx("readonly").get(id);
      request.onsuccess = () => resolve(request.result || null);
      request.onerror = () => reject(request.error);
    });
  }

  _put(record) {
    return new Promise((resolve, reject) => {
      const request = this._tx("readwrite").put(record);
      request.onsuccess = () => resolve();
      request.onerror = () => reject(request.error);
    });
  }

  _delete(id) {
    return new Promise((resolve, reject) => {
      const request = this._tx("readwrite").delete(id);
      request.onsuccess = () => resolve();
      request.onerror = () => reject(request.error);
    });
  }
}

// MARK: - Helpers

/** Strip the (large) blob from a record for the in-memory metadata list. */
function stripBlob(record) {
  const { blob, ...meta } = record;
  return meta;
}

function friendlyMessage(error) {
  if (error instanceof NotionError) return error.message;
  return error?.message || String(error);
}

/** Formats a timestamp for a page title: "yyyy-MM-dd HH:mm[:ss]". */
export function formatTitle(date, withSeconds = false) {
  const p = (n) => String(n).padStart(2, "0");
  const base = `${date.getFullYear()}-${p(date.getMonth() + 1)}-${p(date.getDate())} ${p(
    date.getHours()
  )}:${p(date.getMinutes())}`;
  return withSeconds ? `${base}:${p(date.getSeconds())}` : base;
}
