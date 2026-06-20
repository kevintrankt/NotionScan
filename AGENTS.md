# AGENTS.md

Orientation guide for AI coding agents (Claude, Cursor, Copilot, etc.) working in this
repository. Humans are welcome to read it too. For the product story, read
[`README.md`](./README.md); for product requirements, [`PRD.md`](./PRD.md).

## What this project is

**NotionScan** captures a batch of photos and uploads them into a Notion database as a
single new page (one image block per photo). It exists in two parallel implementations
that share one product and one Notion data model:

- **iOS app** — SwiftUI + AVFoundation, in [`NotionScan/`](./NotionScan/).
- **Web app** — vanilla HTML/CSS/ES-module JavaScript with no build step, in
  [`webapp/`](./webapp/).

The web app is a deliberate, near line-for-line port of the iOS app. **When you change
behaviour in one, consider whether the other needs the same change** so they don't drift.

## Golden rules

- **No third-party dependencies.** The iOS app uses only `URLSession`; the web app uses
  only `fetch`; the local server uses only Node's standard library. Do not add packages,
  package managers, or a build step without explicit instruction.
- **No backend of our own.** The iOS client talks directly to `api.notion.com`. The web
  app can't (browsers enforce CORS), so it routes through a **self-hosted** proxy that the
  *user* runs — `webapp/local-server/` (the shipped default) or `webapp/cloudflare-worker/`.
  These are stateless relays we don't host; the web app's default address is the single
  constant `DEFAULT_API_BASE_URL` in `webapp/js/settings.js`.
- **The token is a secret.** It lives in the iOS Keychain / browser `localStorage` and is
  only ever sent to `api.notion.com`. Never log it, persist it elsewhere, or transmit it
  to any other host.
- **Keep the two ports in sync.** Mirror the existing file/responsibility mapping (below)
  rather than inventing new structure.
- **Match the house style.** Every source file opens with a short header comment
  explaining its responsibility; comments explain *why*, not *what*. Follow suit.

## Repository map

```
NotionScan/              iOS app (SwiftUI)
NotionScan.xcodeproj/    Xcode project: signing, build settings, Info.plist keys
webapp/                  Web app (no build step)
  index.html             entry point; loads js/app.js as an ES module
  styles.css             all styling
  js/                    app logic (see parity table)
  js/views/              one module per screen
  cloudflare-worker/     optional one-file CORS proxy (wrangler deploy)
  local-server/          optional self-hosted Node proxy + HTTPS static host
README.md                product overview + quick start
AGENTS.md                this file
PRD.md                   product requirements
PLAN.md                  architecture + full iOS setup walkthrough
```

## Architecture & file-by-file parity

Both apps follow the same flow: **Onboarding → Camera → Review → Upload**, plus a
persistent **Gallery** and an **Auto mode**. Each iOS type has a web counterpart with the
same responsibility — keep them aligned.

| Responsibility | iOS (`NotionScan/`) | Web (`webapp/`) |
| --- | --- | --- |
| App entry / root router | `NotionScanApp.swift` + `ContentView.swift` | `js/app.js` |
| Connection state + prefs | `AppSettings.swift` (UserDefaults) | `js/settings.js` (localStorage) |
| Secure token storage | `KeychainStore.swift` (Keychain) | (in `js/settings.js`, localStorage) |
| All Notion API calls | `NotionClient.swift` | `js/notion.js` |
| Value types / API shapes | `Models.swift` | (inlined per module) |
| Camera capture + preview | `CameraModel.swift`, `CameraPreviewView.swift` | `js/camera.js` |
| Persistent gallery + status | `GalleryStore.swift` | `js/gallery.js` (IndexedDB) |
| Sequential auto-upload queue | `AutoUploadManager.swift` | `js/autoUpload.js` |
| Onboarding screen | `OnboardingView.swift` | `js/views/onboarding.js` |
| Camera home screen | `CameraView.swift` | `js/views/camera.js` |
| Batch review + upload | `ReviewView.swift` | `js/views/review.js` |
| Gallery grid + detail | `GalleryView.swift` | `js/views/gallery.js` |
| Settings (+ API proxy on web) | `SettingsView.swift` | `js/views/settings.js` |
| Shared DOM helpers | — | `js/dom.js` |

## The Notion data model (don't break this contract)

All Notion access goes through `NotionClient.swift` / `js/notion.js`. Every request sends
`Authorization: Bearer <token>` and `Notion-Version: 2022-06-28`.

- **Validate token:** `GET /v1/users/me` → returns the workspace/bot name.
- **List databases:** `POST /v1/search` filtered to `{ value: "database", property:
  "object" }`. Only databases connected to the integration are returned. The title
  property's *name* varies per database, so it's detected (the property whose `type` is
  `"title"`).
- **Upload one image (two steps):** `POST /v1/file_uploads` → `{ id, upload_url }`, then
  `POST {upload_url}` as `multipart/form-data` (field name `file`, JPEG bytes).
- **Create the page:** `POST /v1/pages` with `parent.database_id`, the title property, and
  `children` = one image block per file referencing `{ type: "file_upload", file_upload:
  { id } }`. **One batch = one page** (Auto mode = one photo per page).
- **Delete a page:** `PATCH /v1/pages/{id}` with `{ "archived": true }` (trashes it).

JPEG compression (~0.8 quality) keeps uploads small.

## Build, run, and validate

There is **no automated test suite** and **no linter config** in this repo. Validate
changes by building and by manual QA of the capture→upload loop.

### iOS

- File layout uses Xcode **file-system-synchronized groups**: any `.swift` file added
  under `NotionScan/` is compiled automatically — you do **not** edit `project.pbxproj` to
  register new files.
- There is **no `Info.plist`**; it's auto-generated. Permission strings are build settings
  already present in `project.pbxproj`
  (`INFOPLIST_KEY_NSCameraUsageDescription`, `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription`).
- Key settings: deployment target **iOS 26.2**, Swift **5.0**, bundle id
  `rip.kevin.NotionScan`, automatic signing.
- Build from the command line (a Mac with Xcode is required):

  ```bash
  xcodebuild -project NotionScan.xcodeproj -scheme NotionScan \
    -destination 'generic/platform=iOS' build
  ```

  In a sandbox without Xcode/macOS you cannot compile Swift; review changes carefully and
  state that the build was not run.

### Web

- No build, no install. Serve over a secure context (`getUserMedia` requires it;
  `localhost` counts):

  ```bash
  cd webapp && python3 -m http.server 8000   # open http://localhost:8000
  ```

- To exercise live Notion calls from a browser you need a CORS proxy
  (`webapp/local-server/` or `webapp/cloudflare-worker/`). `NotionClient`'s `baseURL`
  defaults to `DEFAULT_API_BASE_URL` (in `js/settings.js`), which points at the
  self-hosted local server — **not** `api.notion.com` — so a fresh clone must repoint that
  constant (or override it per-browser under **Settings → API proxy**) at its own server.
  `js/settings.js` also keeps `NOTION_API_BASE_URL` (`https://api.notion.com`) purely for
  rewriting upload URLs and detecting direct CORS-blocked calls.

### Manual QA checklist

Onboard with a real token → confirm databases load → capture 2–3 photos → **Done** →
delete one → **Upload** → confirm a new page with the images appears in Notion. Then test
**Auto mode** (one page per shot) and the **Gallery** (retry a failed upload, open a page,
delete).

## Platform-specific behaviour to respect

The web app degrades gracefully where browsers lack a capability — mirror the iOS intent
rather than removing the control:

- **Flash** → MediaStream `torch` constraint (not on iOS Safari); the toggle still cycles
  off/on/auto.
- **Zoom/lens** → the `zoom` track capability with pinch-to-zoom + double-tap reset; the
  picker shows zoom *presets* because the web can't enumerate physical lenses.
- **Tap-to-focus** → attempts `pointsOfInterest`/`focusMode`; commonly a no-op, but the
  reticle still animates.
- **"Save to Photos"** → becomes **"Save to device"** (a file download) on the web.

## Security notes for changes

- `localStorage` is **not** an encrypted keychain: on the web the token is plain text and
  readable by any script on the origin. Acceptable for a personal, single-user, static
  deployment only — never widen this (e.g. don't add analytics, third-party scripts, or a
  shared host).
- The proxies (`cloudflare-worker`, `local-server`) must remain **stateless relays**: no
  logging of requests/bodies/tokens, no storage. `local-server/certs/` and `*.pem` are
  git-ignored — never commit keys.

## Conventions

- Keep file header comments and the "explain *why*" comment style.
- Prefer small, focused changes; don't introduce abstractions for one-off code.
- Use Markdown links (not bare URLs) in docs.
- When you change one platform's behaviour, note in your summary whether the other
  platform needs a matching change.
