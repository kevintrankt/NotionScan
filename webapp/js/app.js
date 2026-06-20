//
//  app.js
//  NotionScan Web
//
//  Root controller + router. Mirrors the iOS `NotionScanApp` + `ContentView`:
//  it owns the shared `AppSettings` and `GalleryStore`, routes between the
//  Onboarding and Camera screens, and presents the Review / Gallery / Settings
//  surfaces as overlays (the web analogue of iOS sheets and full-screen covers).
//

import { AppSettings } from "./settings.js";
import { GalleryStore } from "./gallery.js";
import { el, clear } from "./dom.js";
import { OnboardingScreen } from "./views/onboarding.js";
import { CameraScreen } from "./views/camera.js";
import { ReviewOverlay } from "./views/review.js";
import { GalleryOverlay, GalleryDetailOverlay } from "./views/gallery.js";
import { SettingsOverlay } from "./views/settings.js";

class App {
  constructor(root) {
    this.root = root;
    this.settings = new AppSettings();
    this.gallery = new GalleryStore();

    this.screenContainer = el("div.screen-container");
    this.overlayRoot = el("div.overlay-root");
    this.dialogRoot = el("div.dialog-root");
    this.toastRoot = el("div.toast-root");
    this.root.append(this.screenContainer, this.overlayRoot, this.dialogRoot, this.toastRoot);

    this.currentScreen = null;
    this.currentScreenKind = null;
    this.overlays = []; // stack of overlay objects with .element and optional .destroy()
  }

  async init() {
    await this.gallery.open();
    this.render();
  }

  // MARK: - Routing

  render() {
    const kind = this.settings.isFullyConfigured ? "camera" : "onboarding";
    if (kind === this.currentScreenKind && this.currentScreen) return;

    // Tear down the previous screen.
    if (this.currentScreen?.destroy) this.currentScreen.destroy();
    clear(this.screenContainer);

    if (kind === "camera") {
      this.currentScreen = new CameraScreen(this);
      this.screenContainer.append(this.currentScreen.element);
      this.currentScreen.start();
    } else {
      this.currentScreen = new OnboardingScreen(this);
      this.screenContainer.append(this.currentScreen.element);
    }
    this.currentScreenKind = kind;
  }

  // MARK: - Overlays

  _pushOverlay(overlay) {
    // Pause the live camera while a full surface is shown (mirrors iOS sheets
    // stopping the session), then resume when the last overlay closes.
    if (this.overlays.length === 0 && this.currentScreenKind === "camera") {
      this.currentScreen.stop();
    }
    this.overlays.push(overlay);
    overlay.element.classList.add("overlay-enter");
    this.overlayRoot.append(overlay.element);
    requestAnimationFrame(() => overlay.element.classList.remove("overlay-enter"));
  }

  _popOverlay(overlay) {
    const index = this.overlays.indexOf(overlay);
    if (index < 0) return;
    this.overlays.splice(index, 1);
    overlay.destroy?.();
    overlay.element.remove();
    if (this.overlays.length === 0 && this.currentScreenKind === "camera") {
      this.currentScreen.start();
    }
  }

  openReview(cameraScreen) {
    const overlay = new ReviewOverlay(this, cameraScreen, { onClose: () => this._popOverlay(overlay) });
    this._pushOverlay(overlay);
  }

  openGallery() {
    const overlay = new GalleryOverlay(this, { onClose: () => this._popOverlay(overlay) });
    this._pushOverlay(overlay);
  }

  openGalleryDetail(itemID) {
    const overlay = new GalleryDetailOverlay(this, itemID, { onClose: () => this._popOverlay(overlay) });
    this._pushOverlay(overlay);
  }

  openSettings() {
    const overlay = new SettingsOverlay(this, { onClose: () => this._popOverlay(overlay) });
    this._pushOverlay(overlay);
  }

  // MARK: - Action sheet

  openActionSheet({ title, items }) {
    const sheet = el("div.action-sheet");
    const close = () => backdrop.remove();
    const list = el("div.action-sheet-list");
    if (title) list.append(el("div.action-sheet-title", { text: title }));
    for (const item of items) {
      list.append(
        el(
          "button.action-sheet-item",
          {
            disabled: item.disabled,
            onclick: () => {
              close();
              item.onClick?.();
            },
          },
          [item.checked ? el("span.check", { text: "✓ " }) : el("span.check-spacer"), el("span", { text: item.label })]
        )
      );
    }
    sheet.append(list, el("button.action-sheet-item.cancel", { onclick: close }, "Cancel"));
    const backdrop = el("div.sheet-backdrop", { onclick: (e) => e.target === backdrop && close() }, [sheet]);
    this.dialogRoot.append(backdrop);
  }

  // MARK: - Dialogs

  confirm({ title, message, confirmLabel = "OK", destructive = false, onConfirm }) {
    const close = () => backdrop.remove();
    const dialog = el("div.dialog", {}, [
      el("h3", { text: title }),
      message ? el("p", { text: message }) : null,
      el("div.dialog-actions", {}, [
        el("button.btn.btn-bordered", { onclick: close }, "Cancel"),
        el(
          "button.btn",
          {
            class: destructive ? "btn-danger" : "btn-primary",
            onclick: () => {
              close();
              onConfirm?.();
            },
          },
          confirmLabel
        ),
      ]),
    ]);
    const backdrop = el("div.dialog-backdrop", {}, [dialog]);
    this.dialogRoot.append(backdrop);
  }

  prompt({ title, message, placeholder = "", password = false }) {
    return new Promise((resolve) => {
      const input = el("input.field", {
        type: password ? "password" : "text",
        placeholder,
        autocapitalize: "off",
        spellcheck: false,
      });
      const finish = (value) => {
        backdrop.remove();
        resolve(value);
      };
      const dialog = el("div.dialog", {}, [
        el("h3", { text: title }),
        message ? el("p", { text: message }) : null,
        input,
        el("div.dialog-actions", {}, [
          el("button.btn.btn-bordered", { onclick: () => finish(null) }, "Cancel"),
          el("button.btn.btn-primary", { onclick: () => finish(input.value) }, "Save"),
        ]),
      ]);
      const backdrop = el("div.dialog-backdrop", {}, [dialog]);
      this.dialogRoot.append(backdrop);
      input.focus();
    });
  }

  // MARK: - Toast

  toast(message) {
    const toast = el("div.toast", { text: message });
    this.toastRoot.append(toast);
    requestAnimationFrame(() => toast.classList.add("show"));
    setTimeout(() => {
      toast.classList.remove("show");
      setTimeout(() => toast.remove(), 300);
    }, 4000);
  }
}

// Boot.
const root = document.getElementById("app");
const app = new App(root);
app.init();
