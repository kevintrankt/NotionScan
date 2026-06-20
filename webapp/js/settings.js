//
//  settings.js
//  NotionScan Web
//
//  Single source of truth for connection state and user preferences, mirroring
//  the iOS `AppSettings`. The iOS app keeps the token in the Keychain and
//  everything else in UserDefaults; on the web everything lives in
//  `localStorage`, which is the closest no-backend equivalent.
//
//  NOTE on security: a browser's localStorage is not an encrypted keychain.
//  The integration token is stored in plain text and is readable by any script
//  running on this origin. That's an acceptable trade-off for a personal,
//  single-user, statically-hosted tool — but it is called out in the docs.
//

import { NotionClient } from "./notion.js";

const KEYS = {
  token: "notionscan.token",
  defaultDatabaseID: "notionscan.defaultDatabaseID",
  defaultDatabaseName: "notionscan.defaultDatabaseName",
  workspaceName: "notionscan.workspaceName",
  saveToLibrary: "notionscan.saveToLibraryByDefault",
  autoUpload: "notionscan.autoUploadEnabled",
  apiBaseUrl: "notionscan.apiBaseUrl",
};

/** The Notion API origin. Overridable so a user can route through their own proxy. */
export const DEFAULT_API_BASE_URL = "https://api.notion.com";

export class AppSettings extends EventTarget {
  constructor() {
    super();
    this._token = localStorage.getItem(KEYS.token) || null;
    this._defaultDatabaseID = localStorage.getItem(KEYS.defaultDatabaseID) || null;
    this._defaultDatabaseName = localStorage.getItem(KEYS.defaultDatabaseName) || null;
    this._connectedWorkspaceName = localStorage.getItem(KEYS.workspaceName) || null;
    this._saveToLibraryByDefault = localStorage.getItem(KEYS.saveToLibrary) === "true";
    this._autoUploadEnabled = localStorage.getItem(KEYS.autoUpload) === "true";
    this._apiBaseUrl = localStorage.getItem(KEYS.apiBaseUrl) || DEFAULT_API_BASE_URL;
  }

  // MARK: - Notifications

  /** Fire a "change" event so subscribed views re-render. */
  _notify() {
    this.dispatchEvent(new Event("change"));
  }

  // MARK: - Derived state

  /** True once a token exists. Drives Onboarding-vs-Camera routing. */
  get isConnected() {
    return this._token != null;
  }

  /** True once both a token and a default database are configured. */
  get isFullyConfigured() {
    return this._token != null && this._defaultDatabaseID != null;
  }

  // MARK: - Accessors

  get token() {
    return this._token;
  }

  get defaultDatabaseID() {
    return this._defaultDatabaseID;
  }

  get defaultDatabaseName() {
    return this._defaultDatabaseName;
  }

  get connectedWorkspaceName() {
    return this._connectedWorkspaceName;
  }

  get saveToLibraryByDefault() {
    return this._saveToLibraryByDefault;
  }

  set saveToLibraryByDefault(value) {
    this._saveToLibraryByDefault = value;
    localStorage.setItem(KEYS.saveToLibrary, String(value));
    this._notify();
  }

  get autoUploadEnabled() {
    return this._autoUploadEnabled;
  }

  set autoUploadEnabled(value) {
    this._autoUploadEnabled = value;
    localStorage.setItem(KEYS.autoUpload, String(value));
    this._notify();
  }

  get apiBaseUrl() {
    return this._apiBaseUrl;
  }

  set apiBaseUrl(value) {
    const trimmed = (value || "").trim().replace(/\/+$/, "");
    this._apiBaseUrl = trimmed || DEFAULT_API_BASE_URL;
    localStorage.setItem(KEYS.apiBaseUrl, this._apiBaseUrl);
    this._notify();
  }

  // MARK: - Mutations

  /** Persists a validated token. */
  setToken(token, workspaceName) {
    this._token = token;
    this._connectedWorkspaceName = workspaceName ?? null;
    localStorage.setItem(KEYS.token, token);
    if (workspaceName) localStorage.setItem(KEYS.workspaceName, workspaceName);
    else localStorage.removeItem(KEYS.workspaceName);
    this._notify();
  }

  /** Sets the default destination database. */
  setDefaultDatabase(id, name) {
    this._defaultDatabaseID = id;
    this._defaultDatabaseName = name;
    localStorage.setItem(KEYS.defaultDatabaseID, id);
    localStorage.setItem(KEYS.defaultDatabaseName, name);
    this._notify();
  }

  /** Clears everything and returns to a disconnected state. */
  disconnect() {
    this._token = null;
    this._defaultDatabaseID = null;
    this._defaultDatabaseName = null;
    this._connectedWorkspaceName = null;
    localStorage.removeItem(KEYS.token);
    localStorage.removeItem(KEYS.defaultDatabaseID);
    localStorage.removeItem(KEYS.defaultDatabaseName);
    localStorage.removeItem(KEYS.workspaceName);
    this._notify();
  }

  /** Builds a NotionClient for the current token (null if disconnected). */
  makeClient() {
    if (!this._token) return null;
    return new NotionClient(this._token, this._apiBaseUrl);
  }
}
