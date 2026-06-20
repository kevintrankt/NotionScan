//
//  notion.js
//  NotionScan Web
//
//  All Notion API access. No third-party dependencies — just `fetch`.
//  Each instance is bound to one integration token. This mirrors the iOS
//  `NotionClient` one-to-one (validate, list databases, upload file, create page).
//
//  Browser caveat: the Notion API does not send CORS headers, so a browser
//  blocks direct calls to https://api.notion.com. `baseURL` is therefore
//  configurable, and it defaults to a self-hosted local server (see
//  webapp/local-server) rather than Notion itself, so the app works without
//  hitting the CORS wall. Every call is rewritten onto whatever base is set.
//

import { DEFAULT_API_BASE_URL, NOTION_API_BASE_URL } from "./settings.js";

const NOTION_VERSION = "2022-06-28";

/** Errors surfaced to the UI in plain language, mirroring iOS `NotionError`. */
export class NotionError extends Error {
  constructor(kind, message) {
    super(message);
    this.name = "NotionError";
    this.kind = kind; // "invalidToken" | "network" | "cors" | "decoding" | "api"
  }

  static invalidToken() {
    return new NotionError(
      "invalidToken",
      "That token didn't work. Double-check you copied the full integration secret."
    );
  }

  static network(message) {
    return new NotionError("network", `Network problem: ${message}`);
  }

  static cors() {
    return new NotionError(
      "cors",
      "The browser blocked the request to Notion (CORS). Notion's API can't be " +
        "called directly from a web page. Set an API proxy URL in Settings — see the " +
        "README for a one-file Cloudflare Worker you can deploy for free."
    );
  }

  static decoding(message) {
    return new NotionError("decoding", `Couldn't read Notion's response: ${message}`);
  }

  static api(status, message) {
    return new NotionError("api", `Notion API error (${status}): ${message}`);
  }
}

export class NotionClient {
  constructor(token, baseURL = DEFAULT_API_BASE_URL) {
    this.token = token;
    this.baseURL = (baseURL || DEFAULT_API_BASE_URL).replace(/\/+$/, "");
  }

  // MARK: - Public API

  /** Validates the token via GET /v1/users/me. Returns the workspace/bot name. */
  async validateToken() {
    const user = await this._send(this._url("/v1/users/me"), { method: "GET" });
    return user?.bot?.workspace_name ?? user?.name ?? null;
  }

  /** Lists databases the integration can access via POST /v1/search. */
  async listDatabases() {
    const body = { filter: { value: "database", property: "object" }, page_size: 100 };
    const response = await this._send(this._url("/v1/search"), {
      method: "POST",
      body: JSON.stringify(body),
    });

    return (response.results || []).map((db) => {
      const title = (db.title || [])
        .map((rt) => rt.plain_text || "")
        .join("")
        .trim();
      const properties = db.properties || {};
      const titleProp =
        Object.keys(properties).find((key) => properties[key]?.type === "title") || "Name";
      return {
        id: db.id,
        title: title || "Untitled database",
        titlePropertyName: titleProp,
      };
    });
  }

  /**
   * Two-step upload of one image. Returns the file_upload id to reference in a block.
   * @param {Blob} jpegBlob
   */
  async uploadImage(jpegBlob) {
    // Step 1: create the file upload object.
    const created = await this._send(this._url("/v1/file_uploads"), {
      method: "POST",
      body: JSON.stringify({}),
    });

    if (!created.upload_url) {
      throw NotionError.api(0, "Notion did not return an upload URL.");
    }

    // Step 2: send the bytes as multipart/form-data with field name "file".
    // The browser sets the multipart boundary + Content-Type automatically.
    const form = new FormData();
    form.append("file", jpegBlob, "photo.jpg");

    const sent = await this._send(this._rewrite(created.upload_url), {
      method: "POST",
      body: form,
      multipart: true,
    });
    return sent.id;
  }

  /**
   * Creates one page in `databaseId` containing all uploaded images as blocks.
   * The title is set via the stable `"title"` property id, which works for any
   * database regardless of what its title column is named.
   */
  async createBatchPage(databaseId, title, fileUploadIDs) {
    const children = fileUploadIDs.map((id) => ({
      object: "block",
      type: "image",
      image: { type: "file_upload", file_upload: { id } },
    }));
    const body = {
      parent: { database_id: databaseId },
      properties: { title: { title: [{ text: { content: title } }] } },
      children,
    };

    return this._send(this._url("/v1/pages"), {
      method: "POST",
      body: JSON.stringify(body),
    });
  }

  // MARK: - Helpers

  _url(path) {
    return `${this.baseURL}${path}`;
  }

  /** Rewrites an absolute api.notion.com URL onto the configured base (for proxies). */
  _rewrite(url) {
    // When we're talking straight to Notion, its URLs are already correct.
    if (this.baseURL === NOTION_API_BASE_URL) return url;
    if (url.startsWith(NOTION_API_BASE_URL)) {
      return this.baseURL + url.slice(NOTION_API_BASE_URL.length);
    }
    return url;
  }

  /** Performs the request and decodes JSON, mapping failures to NotionError. */
  async _send(url, { method, body, multipart = false } = {}) {
    const headers = {
      Authorization: `Bearer ${this.token}`,
      "Notion-Version": NOTION_VERSION,
    };
    // For multipart, let the browser set Content-Type (with boundary).
    if (!multipart) headers["Content-Type"] = "application/json";

    let response;
    try {
      response = await fetch(url, { method, headers, body });
    } catch (error) {
      // A failed fetch with no response talking *directly* to Notion is almost
      // always a CORS/preflight block, so surface that targeted guidance.
      // Through a proxy/local server (the default) it instead means the server
      // is unreachable or its self-signed certificate hasn't been trusted yet.
      if (this.baseURL === NOTION_API_BASE_URL) throw NotionError.cors();
      throw NotionError.network(
        `couldn't reach ${this.baseURL}. Is your proxy/local server running, and ` +
          `have you accepted its certificate? (${error?.message || "request failed"})`
      );
    }

    if (!response.ok) {
      if (response.status === 401) throw NotionError.invalidToken();
      let message;
      try {
        const errBody = await response.json();
        message = errBody?.message;
      } catch {
        /* fall through */
      }
      throw NotionError.api(response.status, message || response.statusText || "Unknown error");
    }

    try {
      return await response.json();
    } catch (error) {
      throw NotionError.decoding(error?.message || "invalid JSON");
    }
  }
}
