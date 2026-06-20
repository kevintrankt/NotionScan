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

To keep that CORS error from being the first thing you hit, **the web app does not call Notion directly by default.** Instead it routes every API call through a [self-hosted local server](./local-server/) — a one-file, zero-dependency Node proxy you run on your own machine — which forwards to Notion and adds the missing CORS headers. That default address lives in one place:

```js
// webapp/js/settings.js
export const DEFAULT_API_BASE_URL = "https://192.168.86.239:8787";
```

> ### 👉 Cloned this project? Point it at *your* server
> The address above is the original author's home server and won't exist on your network. Change it to your own in **one** of two ways:
> 1. **Edit the default in code** — set `DEFAULT_API_BASE_URL` in [`js/settings.js`](./js/settings.js) to your server's `scheme://host:port` (no trailing slash), e.g. `https://192.168.1.50:8787`. This is the single source of truth; everything else reads from it.
> 2. **Override at runtime** — in the app, go to **Settings → API proxy**, paste your server's URL, and **Save**. This is stored per-browser in `localStorage` and overrides the code default without a redeploy.
>
> See [`local-server/`](./local-server/) for how to stand that server up (and serve the app from it over HTTPS so the camera works on your phone).

Prefer not to run your own box? You still have the usual escape hatches:

- **Deploy the included Cloudflare Worker proxy** (free, zero-maintenance). See [`cloudflare-worker/`](./cloudflare-worker/), then set its URL as the `DEFAULT_API_BASE_URL` (or under **Settings → API proxy**).
- **Call Notion directly** by setting the base URL to `https://api.notion.com` — only works inside a **native shell** (Capacitor/Tauri) or a **browser with web security disabled** (development only), e.g. `open -na "Google Chrome" --args --disable-web-security --user-data-dir=/tmp/ns`.

If a call to `https://api.notion.com` is blocked, the app shows a clear CORS error pointing you here; if your proxy/local server can't be reached, it names the address it tried so you can fix it.

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

The app lives in the `webapp/` subfolder. GitHub Pages' "Deploy from a branch"
option can only serve the repo **root** or **`/docs`** — it can't point at an
arbitrary subfolder like `/webapp`. So the repo ships a GitHub Actions workflow
([`.github/workflows/deploy-pages.yml`](../.github/workflows/deploy-pages.yml))
that uploads just `webapp/` as the Pages artifact. That's the recommended path:

1. Push this repo to GitHub.
2. Repo **Settings → Pages → Build and deployment → Source: GitHub Actions**.
3. Push to `main` (or run the **Deploy web app to GitHub Pages** workflow from the
   **Actions** tab via **Run workflow**). The workflow deploys `webapp/`.
4. Your app is live at `https://YOUR_USERNAME.github.io/NotionScan/`.
5. Make sure the API base URL points at a proxy you control — your
   [`local-server`](./local-server/) or the [Cloudflare Worker](./cloudflare-worker/) —
   either by editing `DEFAULT_API_BASE_URL` in [`js/settings.js`](./js/settings.js)
   before you deploy, or per-browser under **Settings → API proxy**. (A Pages site is
   HTTPS, so the proxy must be HTTPS too.)

> **Prefer "Deploy from a branch"?** Move `webapp/`'s contents into a top-level
> `docs/` folder, then choose **Source: Deploy from a branch** and set the folder
> to **`/docs`**. (You can delete the Actions workflow if you go this route.)

> **Custom name?** This is a *project* page served from `https://USER.github.io/NotionScan/`,
> so every asset path in the app is relative — don't change them to start with `/`
> or the page will 404 under the `/NotionScan/` prefix.

> Tip: if you set `ALLOWED_ORIGIN` on the Worker, use your exact Pages origin (`https://YOUR_USERNAME.github.io`).

---

## Connect Notion (first launch)

1. Go to [notion.com/my-integrations](https://www.notion.com/my-integrations) → **New integration** → **Internal** → create it.
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
