//
//  views/onboarding.js
//  NotionScan Web
//
//  First-launch flow: paste + validate a Notion integration token, then pick the
//  default destination database. Mirrors the iOS `OnboardingView`.
//

import { el, clear } from "../dom.js";
import { NotionClient } from "../notion.js";

export class OnboardingScreen {
  constructor(app) {
    this.app = app;
    this.step = "token";
    this.databases = [];
    this.selectedDatabaseID = null;
    this.tokenInput = "";
    this.isWorking = false;
    this.errorMessage = null;

    this.element = el("div.screen.onboarding");
    this.render();
  }

  get settings() {
    return this.app.settings;
  }

  render() {
    clear(this.element);
    this.element.append(this.step === "token" ? this.tokenStep() : this.databaseStep());
  }

  // MARK: - Step 1: token

  tokenStep() {
    const input = el("input.field", {
      type: "password",
      placeholder: "ntn_… or secret_…",
      autocomplete: "off",
      autocapitalize: "off",
      spellcheck: false,
      value: this.tokenInput,
      oninput: (e) => {
        this.tokenInput = e.target.value;
        connectBtn.disabled = !this.tokenInput.trim() || this.isWorking;
      },
    });

    const connectBtn = el(
      "button.btn.btn-primary.btn-block",
      {
        disabled: !this.tokenInput.trim() || this.isWorking,
        onclick: () => this.connect(),
      },
      this.isWorking ? [spinner(), "Connecting…"] : "Connect"
    );

    return el("div.form", {}, [
      el("h1.title", { text: "Connect Notion" }),
      el("section.card", {}, [
        el("label.label", { text: "Integration token" }),
        input,
        el("p.hint", {
          text: "Paste your Notion internal integration secret. It's stored only in this browser.",
        }),
      ]),
      el("section.card", {}, [
        el("h2.subtitle", { text: "How to get a token" }),
        instructionRow(1, 'Open notion.so/my-integrations and click "New integration".'),
        instructionRow(2, 'Choose "Internal", create it, then copy the Internal Integration Secret.'),
        instructionRow(
          3,
          "In Notion, open each database you want to use → ••• → Connections → add your integration."
        ),
      ]),
      this.errorMessage ? el("p.error", { text: this.errorMessage }) : null,
      connectBtn,
      el("p.hint.center", {
        html:
          'Web version &middot; <a href="#" id="cors-help-link">Why might I need an API proxy?</a>',
      }),
      this._corsHelpHandler(),
    ]);
  }

  _corsHelpHandler() {
    // Attach after creation via microtask since the link is inside innerHTML.
    queueMicrotask(() => {
      const link = this.element.querySelector("#cors-help-link");
      if (link) {
        link.onclick = (e) => {
          e.preventDefault();
          this.app.toast(
            "Notion's API can't be called directly from a web page (CORS). NotionScan routes " +
              "calls through a server you run — set its address under Settings → API proxy " +
              "(see the local-server README), or deploy the included Cloudflare Worker."
          );
        };
      }
    });
    return null;
  }

  // MARK: - Step 2: database

  databaseStep() {
    const refreshBtn = el(
      "button.btn.btn-secondary",
      { disabled: this.isWorking, onclick: () => this.loadDatabases() },
      this.isWorking ? [spinner(), "Refreshing…"] : "Refresh databases"
    );

    let list;
    if (this.databases.length === 0) {
      list = el("p.hint", {
        text:
          "No databases were shared with this integration yet. In Notion, open a database → " +
          "••• → Connections → add your integration, then tap Refresh.",
      });
    } else {
      list = el(
        "div.radio-list",
        {},
        this.databases.map((db) =>
          el("label.radio-row", {}, [
            el("input", {
              type: "radio",
              name: "default-db",
              checked: db.id === this.selectedDatabaseID,
              onchange: () => {
                this.selectedDatabaseID = db.id;
                continueBtn.disabled = false;
              },
            }),
            el("span", { text: db.title }),
          ])
        )
      );
    }

    const continueBtn = el(
      "button.btn.btn-primary.btn-block",
      {
        disabled: this.selectedDatabaseID == null || this.isWorking,
        onclick: () => this.finish(),
      },
      "Continue"
    );

    return el("div.form", {}, [
      el("h1.title", { text: "Default destination" }),
      el("section.card", {}, [
        list,
        el("p.hint", { text: "Photos will go here by default. You can change it per batch later." }),
      ]),
      this.errorMessage ? el("p.error", { text: this.errorMessage }) : null,
      el("div.row.gap", {}, [refreshBtn, continueBtn]),
    ]);
  }

  // MARK: - Actions

  async connect() {
    const token = this.tokenInput.trim();
    this.isWorking = true;
    this.errorMessage = null;
    this.render();
    try {
      const client = new NotionClient(token, this.settings.apiBaseUrl);
      const workspaceName = await client.validateToken();
      this.settings.setToken(token, workspaceName);
      this.step = "database";
      this.isWorking = false;
      this.render();
      this.loadDatabases();
    } catch (error) {
      this.isWorking = false;
      this.errorMessage = error?.message || String(error);
      this.render();
    }
  }

  async loadDatabases() {
    const client = this.settings.makeClient();
    if (!client) return;
    this.isWorking = true;
    this.errorMessage = null;
    this.render();
    try {
      this.databases = await client.listDatabases();
      if (this.selectedDatabaseID == null) {
        this.selectedDatabaseID = this.databases[0]?.id ?? null;
      }
    } catch (error) {
      this.errorMessage = error?.message || String(error);
    }
    this.isWorking = false;
    this.render();
  }

  finish() {
    const db = this.databases.find((d) => d.id === this.selectedDatabaseID);
    if (!db) return;
    this.settings.setDefaultDatabase(db.id, db.title);
    this.app.render(); // settings now fully configured → router shows Camera
  }
}

function instructionRow(number, text) {
  return el("div.instruction", {}, [el("span.step-number", { text: String(number) }), el("span", { text })]);
}

function spinner() {
  return el("span.spinner");
}
