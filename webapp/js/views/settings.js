//
//  views/settings.js
//  NotionScan Web
//
//  Connection status, change default database, replace token, toggle the
//  "save to device" and "auto mode" defaults, configure the API proxy URL, and
//  disconnect. Mirrors the iOS `SettingsView`, plus the web-only API-proxy
//  setting that works around Notion's lack of CORS support.
//

import { el, clear } from "../dom.js";
import { NotionClient, NotionError } from "../notion.js";
import { DEFAULT_API_BASE_URL } from "../settings.js";

export class SettingsOverlay {
  constructor(app, { onClose }) {
    this.app = app;
    this.onClose = onClose;

    this.databases = [];
    this.isLoading = false;
    this.errorMessage = null;

    this.element = el("div.overlay.settings-overlay");
    this._onChange = () => this.render();
    this.settings.addEventListener("change", this._onChange);
    this.render();
    this.loadDatabases();
  }

  get settings() {
    return this.app.settings;
  }

  destroy() {
    this.settings.removeEventListener("change", this._onChange);
  }

  render() {
    clear(this.element);
    this.element.append(
      el("div.overlay-header", {}, [
        el("span"),
        el("h2.overlay-title", { text: "Settings" }),
        el("button.btn-text.strong", { onclick: () => this.close() }, "Done"),
      ]),
      el("div.overlay-body", {}, [
        this._notionSection(),
        this._defaultDatabaseSection(),
        this._captureSection(),
        this._saveSection(),
        this._proxySection(),
        this.errorMessage ? el("p.error", { text: this.errorMessage }) : null,
        this._accountSection(),
      ])
    );
  }

  _notionSection() {
    return el("section.card", {}, [
      el("h3.subtitle", { text: "Notion" }),
      labeled("Workspace", this.settings.connectedWorkspaceName || "Connected"),
      labeled("Default database", this.settings.defaultDatabaseName || "Not set"),
    ]);
  }

  _defaultDatabaseSection() {
    let body;
    if (this.isLoading) {
      body = el("div.row.gap", {}, [el("span.spinner"), el("span.hint", { text: "Loading…" })]);
    } else if (this.databases.length > 0) {
      body = el(
        "div.radio-list",
        {},
        this.databases.map((db) =>
          el("label.radio-row", {}, [
            el("input", {
              type: "radio",
              name: "settings-db",
              checked: db.id === this.settings.defaultDatabaseID,
              onchange: () => this.settings.setDefaultDatabase(db.id, db.title),
            }),
            el("span", { text: db.title }),
          ])
        )
      );
    } else {
      body = el("p.hint", { text: "No databases found yet." });
    }
    return el("section.card", {}, [
      el("h3.subtitle", { text: "Default database" }),
      body,
      el("button.btn.btn-secondary", { disabled: this.isLoading, onclick: () => this.loadDatabases() }, "Refresh databases"),
    ]);
  }

  _captureSection() {
    return el("section.card", {}, [
      el("h3.subtitle", { text: "Capture" }),
      el("label.toggle-row", {}, [
        el("span", { text: "Auto mode" }),
        el("input", {
          type: "checkbox",
          checked: this.settings.autoUploadEnabled,
          onchange: (e) => (this.settings.autoUploadEnabled = e.target.checked),
        }),
      ]),
      el("p.hint", {
        text:
          "When on, every photo you take is uploaded to your default database immediately — no " +
          "review or confirmation. Each photo becomes its own page.",
      }),
    ]);
  }

  _saveSection() {
    return el("section.card", {}, [
      el("label.toggle-row", {}, [
        el("span", { text: "Save photos to device by default" }),
        el("input", {
          type: "checkbox",
          checked: this.settings.saveToLibraryByDefault,
          onchange: (e) => (this.settings.saveToLibraryByDefault = e.target.checked),
        }),
      ]),
      el("p.hint", { text: "When on, new batches are also downloaded to this device after upload." }),
    ]);
  }

  _proxySection() {
    const input = el("input.field", {
      type: "url",
      placeholder: DEFAULT_API_BASE_URL,
      value: this.settings.apiBaseUrl,
      autocapitalize: "off",
      spellcheck: false,
    });
    return el("section.card", {}, [
      el("h3.subtitle", { text: "API proxy" }),
      input,
      el("p.hint", {
        text:
          "Notion's API can't be called directly from a web page because it doesn't send CORS " +
          "headers. By default NotionScan routes calls through a local server you run yourself " +
          "(see the local-server README) — point this at your own server's address, or at a " +
          "deployed Cloudflare Worker, and press Save. Set it to https://api.notion.com only " +
          "inside a native wrapper or a browser with web security disabled.",
      }),
      el("div.row.gap", {}, [
        el(
          "button.btn.btn-secondary",
          {
            onclick: () => {
              this.settings.apiBaseUrl = input.value;
              this.app.toast("API proxy saved");
            },
          },
          "Save proxy URL"
        ),
        el(
          "button.btn.btn-bordered",
          {
            onclick: () => {
              this.settings.apiBaseUrl = DEFAULT_API_BASE_URL;
            },
          },
          "Reset to default"
        ),
      ]),
    ]);
  }

  _accountSection() {
    return el("section.card", {}, [
      el("button.btn.btn-bordered.btn-block", { onclick: () => this._replaceToken() }, "Replace token"),
      el(
        "button.btn.btn-bordered.btn-block.danger",
        {
          onclick: () =>
            this.app.confirm({
              title: "Disconnect Notion?",
              message: "This clears your token and default database from this browser.",
              confirmLabel: "Disconnect",
              destructive: true,
              onConfirm: () => {
                this.settings.disconnect();
                this.close();
                this.app.render();
              },
            }),
        },
        "Disconnect"
      ),
    ]);
  }

  // MARK: - Actions

  async loadDatabases() {
    const client = this.settings.makeClient();
    if (!client) return;
    this.isLoading = true;
    this.errorMessage = null;
    this.render();
    try {
      this.databases = await client.listDatabases();
    } catch (error) {
      this.errorMessage = error?.message || String(error);
    }
    this.isLoading = false;
    this.render();
  }

  async _replaceToken() {
    const token = await this.app.prompt({
      title: "Replace token",
      message: "Paste a new integration token to reconnect.",
      placeholder: "ntn_… or secret_…",
      password: true,
    });
    if (!token || !token.trim()) return;
    this.isLoading = true;
    this.errorMessage = null;
    this.render();
    try {
      const client = new NotionClient(token.trim(), this.settings.apiBaseUrl);
      const workspace = await client.validateToken();
      this.settings.setToken(token.trim(), workspace);
      await this.loadDatabases();
    } catch (error) {
      this.errorMessage = error instanceof NotionError ? error.message : error?.message || String(error);
      this.isLoading = false;
      this.render();
    }
  }

  close() {
    this.onClose?.();
  }
}

function labeled(label, value) {
  return el("div.labeled-row", {}, [el("span.labeled-key", { text: label }), el("span.labeled-value", { text: value })]);
}
