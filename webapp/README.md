# NotionScan — Web app

A fully client-side web version of NotionScan. Snap photos in the browser and upload them straight into a Notion database — a batch becomes one new page (row), with every photo attached. No backend, no build step: it's plain HTML/CSS/ES-module JavaScript that you can host on **GitHub Pages** (or any static host).

It mirrors the iOS app's functionality: onboarding with a Notion token, a camera home screen with live preview / flash / flip / zoom / pinch-to-zoom / tap-to-focus, a per-batch review-and-upload flow, an **Auto mode** that uploads each shot instantly, and a persistent **Gallery** with per-photo upload status, retry, and multiselect delete.

---

## How state is stored (no backend)

| Data | iOS | Web |
| --- | --- | --- |
| Integration token | Keychain | `localStorage` |
| Default database, preferences | `UserDefaults` | `localStorage` |
| Captured photos + upload status | JPEG files + JSON sidecar | **IndexedDB** (JPEG `Blob` + metadata) |

Settings live in `localStorage` exactly as requested; photo bytes live in IndexedDB because `localStorage` is too small and string-only for images. Both are on-device and require no server.

> ⚠️ **Security:** `localStorage` is not an encrypted keychain. Your Notion token is stored in plain text and readable by any script on this origin. That's an acceptable trade-off for a personal, single-user, statically-hosted tool — but don't deploy this to a shared/public domain with your token in it.

---

## The one catch: Notion + CORS

The Notion API does **not** send CORS headers, so browsers block a web page from calling `https://api.notion.com` directly. (The native iOS app is unaffected — native apps don't enforce CORS.)

You have three options:

1. **Deploy the included Cloudflare Worker proxy** (recommended, free). See [`cloudflare-worker/`](./cloudflare-worker/). Paste its URL into **Settings → API proxy**. This keeps everything else client-side.
2. **Run a browser with web security disabled** (development only), e.g. `open -na "Google Chrome" --args --disable-web-security --user-data-dir=/tmp/ns`.
3. **Wrap the web app in a native shell** (Capacitor/Tauri), where CORS doesn't apply.

If a request is blocked, the app shows a clear CORS error pointing you here.

---

## Run it locally

Because the app uses ES modules and the camera API, open it over `http://localhost` (a `file://` path won't work, and `getUserMedia` needs a secure context — `localhost` counts as secure):

```bash
cd webapp
python3 -m http.server 8000
# open http://localhost:8000
```

---

## Deploy to GitHub Pages

1. Push this repo to GitHub.
2. Repo **Settings → Pages → Build and deployment → Source: Deploy from a branch**.
3. Pick your branch and set the folder to **`/webapp`** (or move `webapp/`'s contents to `/docs` and select that). Save.
4. Your app is live at `https://YOUR_USERNAME.github.io/NotionScan/`.
5. Deploy the Cloudflare Worker (above) and set the proxy URL in Settings so Notion calls succeed.

> Tip: if you set `ALLOWED_ORIGIN` on the Worker, use your exact Pages origin (`https://YOUR_USERNAME.github.io`).

---

## Connect Notion (first launch)

1. Go to [notion.so/my-integrations](https://www.notion.so/my-integrations) → **New integration** → **Internal** → create it.
2. Copy the **Internal Integration Secret** (starts with `ntn_` or `secret_`).
3. In Notion, open each **database** you want to upload to → top-right **•••** → **Connections** → add your integration.
4. In the app: paste the token, **Connect**, then pick your **default database**.

## Daily use

Open the app → tap the shutter to capture one or more photos → **Done** → review (delete bad shots, pick the database, optionally "Save to device") → **Upload**. A new page appears in Notion with all the photos attached.

Turn on **Auto mode** (the pill, or Settings) to skip review entirely: every shot uploads immediately as its own page. The gear opens **Settings**; the last-photo thumbnail opens the **Gallery**, where you can retry failed uploads, open uploaded photos in Notion, and multiselect-delete.

---

## How it works (for the curious)

The web app is a faithful port of the iOS architecture. Each iOS type has a JavaScript counterpart:

| iOS (Swift) | Web (JS) | Responsibility |
| --- | --- | --- |
| `AppSettings` | `js/settings.js` | Connection state + preferences (localStorage) |
| `NotionClient` | `js/notion.js` | All Notion API calls (`fetch`) |
| `CameraModel` + `CameraPreviewView` | `js/camera.js` | `getUserMedia` capture, flash/zoom/focus |
| `GalleryStore` | `js/gallery.js` | Persistent gallery + upload status (IndexedDB) |
| `AutoUploadManager` | `js/autoUpload.js` | Sequential auto-upload queue |
| `OnboardingView` | `js/views/onboarding.js` | Token + default database |
| `CameraView` | `js/views/camera.js` | Camera home screen |
| `ReviewView` | `js/views/review.js` | Batch review + upload |
| `GalleryView` / `GalleryDetailView` | `js/views/gallery.js` | Gallery grid + detail |
| `SettingsView` | `js/views/settings.js` | Settings + API proxy |
| `NotionScanApp` / `ContentView` | `js/app.js` | Root router + overlays |

## Feature parity notes

Most features map directly. A few depend on browser/hardware support and degrade gracefully (exactly as the iOS code no-ops when a capability is missing):

- **Flash** uses the MediaStream `torch` constraint, supported on some mobile browsers (notably not iOS Safari). The toggle still cycles off/on/auto for parity.
- **Zoom / lens picker** uses the `zoom` track capability. The web can't enumerate physical lenses, so the picker shows zoom **presets** (1×, 2×, 5×, max) within the device's range; pinch-to-zoom and double-tap-to-reset work wherever zoom is supported.
- **Tap-to-focus** attempts the `pointsOfInterest`/`focusMode` constraints and shows the focus reticle; on most browsers the focus itself is a no-op.
- **"Save to Photos"** becomes **"Save to device"** — a file download — since the web has no Photos library.
