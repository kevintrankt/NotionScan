# NotionScan

**Snap a batch of photos and push them straight into a Notion database.** A batch of
photos becomes one new row (page) in your chosen database, with every photo attached as
an image block. The whole loop is *open app → shoot → upload*.

There is **no backend of our own**: the app talks directly to the Notion API using your
personal [internal integration token](https://www.notion.so/my-integrations). Your token
never leaves the device except to call `api.notion.com`.

> **Why it exists.** Getting a real-world thing (a receipt, a whiteboard, a label, a page
> of handwritten notes) into Notion normally means: open camera → shoot → switch to
> Notion → find the database → make a row → attach the image. That's 6+ steps across two
> apps, so it usually doesn't happen. NotionScan collapses it to three taps. See
> [`PRD.md`](./PRD.md) for the full product rationale.

---

## What it does

1. **Onboard once.** Paste your Notion integration token; the app validates it and lets
   you pick a default destination database.
2. **Shoot.** The app opens straight to a full-screen camera. Capture as many photos as
   you like; each one joins the current batch.
3. **Review & upload.** Tap **Done**, drop any bad shots, confirm the database, and
   **Upload**. One Notion page is created with all the photos as image blocks.
4. **Auto mode.** Flip it on to skip review entirely — every shot uploads instantly as
   its own one-photo page.
5. **Gallery.** A persistent, on-device gallery records every photo with its upload
   status, lets you retry failed uploads, opens uploaded photos in Notion, and
   multiselect-deletes (optionally deleting the Notion page too).

---

## Two versions, one product

NotionScan ships in two flavours that share the same product and the **same Notion data
model**. Pick whichever fits how you want to run it.

| | **iOS app** | **Web app** |
| --- | --- | --- |
| Source | [`NotionScan/`](./NotionScan/) | [`webapp/`](./webapp/) |
| Built with | SwiftUI + AVFoundation | Vanilla HTML/CSS/ES-module JS (no build step) |
| Runs on | iPhone (build & install via Xcode) | Any modern browser; deployable to **GitHub Pages** |
| Token storage | iOS Keychain | `localStorage` |
| Photo storage | JPEG files + JSON sidecar | IndexedDB (JPEG blobs + metadata) |
| Talks to Notion | Directly (native apps ignore CORS) | Directly, **or** via an optional CORS proxy |
| Dependencies | None (URLSession only) | None (`fetch` only) |

The web app is a faithful, line-for-line port of the iOS architecture — every Swift type
has a JavaScript counterpart with the same responsibility (see the
[parity table in the web README](./webapp/README.md#how-it-works-for-the-curious)).

> **The web app's one catch: CORS.** The Notion API does not send CORS headers, so a
> browser blocks a web page from calling `api.notion.com` directly. (Native iOS is
> unaffected.) The web app therefore makes the API base URL configurable and ships two
> ready-made proxies you can run yourself: a one-file
> [Cloudflare Worker](./webapp/cloudflare-worker/) and a zero-dependency
> [local Node server](./webapp/local-server/). Full details in the
> [web README](./webapp/README.md).

---

## How it works (the shared core)

Both versions follow the same flow and the same Notion data model.

**One batch = one Notion page.** The page title is a human-readable timestamp (e.g.
`NotionScan 2026-06-13 14:35`) written to the database's title property, and the page
body is one **image block per photo** in capture order.

**Upload sequence** (the Notion File Upload API, `Notion-Version: 2022-06-28`):

1. For each photo: `POST /v1/file_uploads` → returns `{ id, upload_url }`.
2. `POST {upload_url}` with `multipart/form-data` (field `file`, the JPEG bytes) → the
   file's status becomes `uploaded`.
3. After all uploads: `POST /v1/pages` with `parent.database_id`, the title property, and
   `children` = one image block per file, each referencing
   `{ type: "file_upload", file_upload: { id } }`.

**Other endpoints:** `GET /v1/users/me` validates the token, `POST /v1/search`
(filtered to `object: "database"`) lists the databases the integration can write to, and
`PATCH /v1/pages/{id}` with `{ "archived": true }` deletes (trashes) a page.

> **Sharing matters.** Only databases you've explicitly connected to your integration
> (database → **•••** → **Connections** → add your integration) appear in the picker.
> This is the most common "where are my databases?" gotcha.

---

## Quick start

### iOS

1. Open [`NotionScan.xcodeproj`](./NotionScan.xcodeproj) in Xcode.
2. Confirm **Signing & Capabilities** uses your team (automatic signing). A free Apple ID
   works, but the build expires ~7 days after install — just re-run from Xcode to refresh.
3. Pick your iPhone as the run destination and press **Run** (⌘R).
4. On first launch, paste your token and choose a default database.

The full from-zero walkthrough (device setup, Developer Mode, troubleshooting) is in
[`PLAN.md`](./PLAN.md).

### Web

```bash
cd webapp
python3 -m http.server 8000
# open http://localhost:8000  (localhost is a secure context, which the camera requires)
```

To run it from a phone or deploy to GitHub Pages you'll also need a CORS proxy — see the
[web README](./webapp/README.md) and [`webapp/local-server/`](./webapp/local-server/).

### Connect Notion (either version)

1. [notion.so/my-integrations](https://www.notion.so/my-integrations) → **New
   integration** → **Internal** → create it.
2. Copy the **Internal Integration Secret** (starts with `ntn_` or `secret_`).
3. Open each database you want to use → **•••** → **Connections** → add your integration.
4. In the app: paste the token, **Connect**, then pick your **default database**.

---

## Repository layout

```
NotionScan/
├── NotionScan/              # iOS app (SwiftUI). Any .swift here auto-compiles.
├── NotionScan.xcodeproj/    # Xcode project (signing, build settings, permissions)
├── webapp/                  # Browser version (no build step)
│   ├── index.html           #   entry; loads js/app.js as an ES module
│   ├── js/                  #   app logic; one module per iOS type/screen
│   ├── cloudflare-worker/   #   optional one-file CORS proxy
│   └── local-server/        #   optional self-hosted Node proxy + HTTPS static host
├── README.md                # this file
├── AGENTS.md                # orientation guide for AI coding agents
├── PRD.md                   # product requirements & rationale
└── PLAN.md                  # build plan + click-by-click iOS setup guide
```

## Documentation index

- **[`AGENTS.md`](./AGENTS.md)** — a concise map of the codebase, conventions, and
  build/run commands for both humans and AI agents working in the repo.
- **[`PRD.md`](./PRD.md)** — what the product is, who it's for, and the requirements.
- **[`PLAN.md`](./PLAN.md)** — architecture overview and the full iOS setup walkthrough.
- **[`webapp/README.md`](./webapp/README.md)** — web feature parity, deployment, and CORS.
- **[`webapp/cloudflare-worker/README.md`](./webapp/cloudflare-worker/README.md)** and
  **[`webapp/local-server/README.md`](./webapp/local-server/README.md)** — the two proxy
  options.

## Status & scope

This is a **single-user, personal-use** app (v1). No OAuth, no team accounts, no App
Store distribution, no cloud backend. The iOS project targets iPhone (the template also
lists iPad/Vision Pro). See [`PRD.md`](./PRD.md) §5 for non-goals and §12 for future ideas.
