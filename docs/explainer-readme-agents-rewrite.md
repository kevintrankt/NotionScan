# Explainer: README rewrite + new `AGENTS.md`

A walkthrough of the documentation change that rewrites the root `README.md` and adds a
new `AGENTS.md`, so that both people and AI coding agents can quickly understand what
NotionScan is and how to work in it.

> 🔗 This change is **documentation-only** — no application code was touched.

## Background

### Deep background (skip if you know the project)

NotionScan is a tiny, single-user tool for getting real-world photos into Notion. You snap
a batch of photos and they become **one new page (row)** in a Notion database, with each
photo attached as an image block. The defining constraint is that there is **no backend of
its own**: the client talks straight to the Notion API using your personal *internal
integration token*.

Notion's API has two relevant quirks the docs must explain. First, uploading a file is a
**two-step dance**: you `POST /v1/file_uploads` to get an `{ id, upload_url }`, then `POST`
the raw bytes to that URL as `multipart/form-data`; only then can you reference the
`file_upload` `id` inside an image block when you `POST /v1/pages`. Second, the API **does
not send CORS headers**, which a native iOS app can ignore but a browser cannot — so the
web version needs a proxy.

The project ships **two implementations of the same product**: an iOS app (SwiftUI +
AVFoundation, in `NotionScan/`) and a web app (vanilla HTML/CSS/ES-module JS, no build
step, in `webapp/`). The web app is a near line-for-line port of the iOS architecture.

### Narrow background (the docs themselves)

Before this change the repo had four docs: a `README.md` that opened with iOS-specific
signing steps, a `PRD.md` (product requirements), a `PLAN.md` (build plan + iOS setup), and
a `webapp/README.md`. There was **no `AGENTS.md`** — nothing that orients an AI coding
agent (or a new contributor) to the codebase as a whole: the iOS↔web parity, the Notion
API contract, how to build, and the project's guardrails.

> 💡 **Key concept — `AGENTS.md`:** a now-common convention for a single file at the repo
> root that tells coding agents how the project is laid out, how to build/test it, and what
> conventions to follow. It is the agent-facing complement to a human-facing README.

## Intuition

The old README answered *"how do I install the iOS app?"* before it answered *"what is
this and why does it exist?"* A reader (human or agent) landing on the repo had to infer
the big picture from setup steps.

The change splits the job in two, matching the two audiences:

- **`README.md`** leads with the *what and why*: a one-line definition, the shared
  *open → shoot → upload* flow, a side-by-side table of the two versions, the shared
  Notion data model, then quick start and a documentation index.
- **`AGENTS.md`** is the *operating manual* for someone editing code: the file-by-file
  iOS↔web parity table, the exact Notion API contract, build/run/validate commands,
  platform-degradation rules, and security/convention guardrails.

A concrete example of why this matters: an agent asked to "add a flash toggle to the web
app" can now open `AGENTS.md`, see that `CameraModel.swift` ↔ `js/camera.js`, read that
flash maps to the MediaStream `torch` constraint and should still cycle off/on/auto for
parity, and learn that it must not add dependencies — all without reverse-engineering the
tree first.

## Code

Two files changed: a rewritten `README.md` and a new `AGENTS.md`.

### `README.md` — reordered around comprehension

The new structure puts purpose first and setup later:

1. **What it is** — a one-paragraph definition plus a "why it exists" callout (the
   6-steps-across-two-apps friction).
2. **What it does** — the five-step flow including Auto mode and the Gallery.
3. **Two versions, one product** — a comparison table (build tooling, where it runs,
   token/photo storage, dependencies) with a callout explaining the web app's CORS catch.
4. **How it works (the shared core)** — the one-batch-one-page rule and the exact upload
   sequence.
5. **Quick start** — condensed iOS and web steps that defer to `PLAN.md` /
   `webapp/README.md` for depth.
6. **Repository layout**, **Documentation index**, and **Status & scope**.

```
| | iOS app | Web app |
| --- | --- | --- |
| Source | NotionScan/ | webapp/ |
| Built with | SwiftUI + AVFoundation | Vanilla HTML/CSS/ES-module JS |
| Token storage | iOS Keychain | localStorage |
| Dependencies | None (URLSession only) | None (fetch only) |
```

### `AGENTS.md` — the new agent guide

It opens with *what the project is* and a set of **golden rules** (no third-party
dependencies, no backend of our own, the token is a secret, keep the two ports in sync,
match the house comment style). Then it provides the repository map and the full parity
table:

```
| Responsibility | iOS (NotionScan/) | Web (webapp/) |
| --- | --- | --- |
| App entry / root router | NotionScanApp.swift + ContentView.swift | js/app.js |
| All Notion API calls | NotionClient.swift | js/notion.js |
| Persistent gallery + status | GalleryStore.swift | js/gallery.js (IndexedDB) |
| Sequential auto-upload queue | AutoUploadManager.swift | js/autoUpload.js |
```

It then documents the Notion data-model contract (the five endpoints and the
one-batch-one-page rule), the build/run/validate steps for each platform, the
browser-degradation rules, and security notes.

> ⚠️ **Edge case the guide calls out:** Xcode uses *file-system-synchronized groups*, so
> any `.swift` file added under `NotionScan/` compiles automatically — an agent must
> **not** hand-edit `project.pbxproj` to register new files. It also notes the
> camera/photo-library permission strings already live as build settings (so `PLAN.md`'s
> old "add this by hand" step is no longer needed).

## Verification

This is a documentation-only change, so verification focused on **accuracy** and **link
integrity** rather than program behaviour.

- **Facts cross-checked against source**, not assumed: the Notion endpoints, headers
  (`Notion-Version: 2022-06-28`), and the two-step upload come from `NotionClient.swift` /
  `webapp/js/notion.js`; the build settings (deployment target iOS 26.2, Swift 5.0, bundle
  id `rip.kevin.NotionScan`, the two `INFOPLIST_KEY_*` permission strings) come from
  `NotionScan.xcodeproj/project.pbxproj`; the storage model (Keychain / UserDefaults /
  `localStorage` / IndexedDB) comes from `AppSettings.swift`, `KeychainStore.swift`,
  `GalleryStore.swift`, and `webapp/js/settings.js`.
- **Every internal link was confirmed to resolve** to a real path in the repo (the
  referenced files/folders all exist).
- **No build was run** because compiling the iOS app requires macOS + Xcode, and the repo
  has **no automated test suite or linter** to run.

> ✅ **How to QA manually:** open the PR's *Files changed* tab and read the rendered
> `README.md` and `AGENTS.md`. Click every internal link to confirm none 404. Spot-check
> the API/build facts against `NotionClient.swift` and `project.pbxproj`.

## Alternatives

### Alternative 1 — Put everything in one big README (no separate `AGENTS.md`)

| Pros | Cons |
| --- | --- |
| One file to maintain; nothing can drift between two docs | Mixes two audiences; the "what is this" story gets buried under build/agent minutiae |
| Readers never wonder which file to open | No conventional entry point that agent tooling looks for (`AGENTS.md`) |

### Alternative 2 — Nested per-folder `AGENTS.md` files (one in `NotionScan/`, one in `webapp/`)

| Pros | Cons |
| --- | --- |
| Guidance sits next to the code it describes | Splits the iOS↔web parity story across files, which is exactly what should be seen together |
| Scales if the subprojects diverge | More files to keep in sync for a small, single-developer repo |

The chosen approach (one root `AGENTS.md` + a comprehension-first `README.md`) keeps the
two-ports-one-product narrative in one place while giving agent tooling its conventional
entry point.

## Suggested people to talk to

- **Kevin Tran** (`kevin.tran.kt@gmail.com` / `ktran@makenotion.com`) — the repo owner and
  original author (the `vibe code init` commit, the earlier README rebrand, and the iOS
  `auto mode` work). He's the authority on the project's intent, the Notion data-model
  choices, and the iOS structure these docs describe.

> 📌 Note: most of the codebase — the entire `webapp/`, the gallery, multiselect/delete,
> and camera zoom/lens — was authored by AI agents rather than a human contributor, so for
> those areas there isn't a separate human expert to consult beyond Kevin.

## Quiz

<details>
<summary>Q1. Why does the web app need an optional proxy while the iOS app does not?</summary>

- A. The web app uses a different Notion API version
- B. The Notion API doesn't send CORS headers, and browsers enforce CORS while native apps don't ✅
- C. iOS can't make HTTPS requests without a proxy
- D. The proxy stores the integration token

**Correct: B.** Notion's API omits CORS headers, so a browser blocks a page from calling
`api.notion.com` directly; native iOS ignores CORS entirely. A is wrong (both use
`2022-06-28`), C is backwards, and D is explicitly something the stateless proxy must
*not* do.
</details>

<details>
<summary>Q2. In normal (non-Auto) mode, what does "one batch = one page" mean?</summary>

- A. Each photo becomes its own Notion page
- B. All photos in a batch become a single Notion page, one image block per photo ✅
- C. Each batch creates a new database
- D. A batch is uploaded as a single combined image

**Correct: B.** A batch maps to one page whose body holds one image block per photo. A
describes **Auto mode** (one photo per page), not normal mode. C and D aren't how the data
model works.
</details>

<details>
<summary>Q3. An agent adds a new Swift file under NotionScan/. What must it do to get it compiled?</summary>

- A. Manually add the file to the target in `project.pbxproj`
- B. Nothing — file-system-synchronized groups compile it automatically ✅
- C. Add it to an `Info.plist` manifest
- D. Register it in `Package.swift`

**Correct: B.** The Xcode project uses file-system-synchronized groups, so any `.swift`
under `NotionScan/` is compiled automatically. A is the thing the guide says **not** to do;
there is no `Info.plist` file (C) and no `Package.swift` (D).
</details>

<details>
<summary>Q4. What are the three steps to attach one photo to a Notion page via the API?</summary>

- A. `POST /v1/pages`, then upload bytes, then patch the page
- B. `POST /v1/file_uploads` → `POST` bytes to the returned `upload_url` (multipart) → reference the `file_upload` id in an image block on `POST /v1/pages` ✅
- C. Upload bytes directly inside the `POST /v1/pages` body
- D. `PATCH /v1/pages/{id}` with the image data

**Correct: B.** It's create-upload → send bytes → reference the id when creating the page.
C isn't supported (you can't inline bytes), D is how a page is *deleted*
(`{"archived": true}`), and A has the order wrong.
</details>

<details>
<summary>Q5. Why is the web app's localStorage token storage acceptable here but flagged in the docs?</summary>

- A. It's encrypted like the iOS Keychain
- B. It's plain text readable by any script on the origin — fine only for a personal, single-user, static deployment ✅
- C. The token is never stored on the web at all
- D. localStorage automatically expires the token after 7 days

**Correct: B.** `localStorage` is not an encrypted keychain; the token sits in plain text,
so the docs say it's acceptable only for a personal, single-user, static deployment and
warn against widening it. A is false, C is false (it is stored), and D confuses this with
the iOS free-signing 7-day build expiry.
</details>
