# Explainer: route the web app through your local server by default

A walkthrough of the change that stops the web app from defaulting its Notion API base URL
to `https://api.notion.com` — a call browsers refuse — and instead points it at a
self-hosted local server, with one clearly-marked constant that anyone cloning the project
edits to match their own machine.

> 🔗 The behaviour change is tiny (which URL we call by default) but it removes the single
> most confusing failure in first-time web setup. Most of the diff is documentation.

## Background

### Deep background (skip if you know the project)

NotionScan turns a batch of photos into **one new page (row)** in a Notion database, one
image block per photo. Its defining constraint is that it has **no backend of its own**:
the client talks straight to the Notion API with your personal *internal integration
token*.

The project ships two implementations of the same product: an iOS app (SwiftUI, in
`NotionScan/`) and a web app (vanilla HTML/CSS/ES-module JavaScript, no build step, in
`webapp/`). All Notion access in the web app funnels through one file, `webapp/js/notion.js`
(the `NotionClient` class), which is the JavaScript counterpart of the iOS
`NotionClient.swift`.

> 💡 **Key concept — CORS.** *Cross-Origin Resource Sharing* is the browser rule that a web
> page may only read a response from another origin if that origin opts in with
> `Access-Control-Allow-*` headers. The Notion API sends **no** such headers, so a browser
> blocks a page on (say) `localhost:8000` from reading a response from `api.notion.com`. A
> **native** app like the iOS build doesn't enforce CORS at all, which is why only the web
> version has this problem.

The standard fix is a **proxy**: a tiny server *you* run that forwards your request to
Notion and copies the response back with the missing CORS headers added. The repo ships two
such proxies — a one-file [Cloudflare Worker](../webapp/cloudflare-worker/) and a
zero-dependency [local Node server](../webapp/local-server/). The local server can *also*
serve the app itself over HTTPS from the same origin, which is what lets the phone camera
(`getUserMedia`, secure-context only) work over a LAN IP.

### Narrow background (the base URL)

`NotionClient` is built around a configurable `baseURL`. Every request path is appended to
it, and the upload URL Notion hands back mid-flow is *rewritten* onto it so that multipart
uploads also pass through the proxy. Before this change, a single constant did double duty:

```js
// webapp/js/settings.js  (before)
export const DEFAULT_API_BASE_URL = "https://api.notion.com";
```

That one value was used as **(a)** the default base URL the app calls, and **(b)** the
literal Notion origin that `notion.js` compares against to decide whether to rewrite upload
URLs and whether a failed `fetch` should be reported as a CORS error.

Because the default was Notion's own origin, a brand-new user — open the app, paste a token,
hit *Connect* — immediately ran into the CORS wall and a scary error, *before* they'd done
anything wrong. They had to already know to go to **Settings → API proxy** and paste a proxy
URL. The whole point of this change is to make the working configuration the default.

## Intuition

The fix is one sentence: **default to the proxy, not to Notion.** If the app calls a
CORS-friendly server out of the box, the first-run experience just works.

But notice the constant was overloaded. The moment you change the *default* to a proxy
address, the *rewrite* and *CORS-detection* logic — which genuinely need Notion's real
origin — would break if they kept reading the same constant. So the change **splits the one
constant into two**, each with a single job:

- `NOTION_API_BASE_URL` = `https://api.notion.com` — Notion's fixed address. Used only
  internally to rewrite upload URLs and to recognise a direct (CORS-prone) call. Never
  changes.
- `DEFAULT_API_BASE_URL` = the proxy address the app calls by default. Now the local
  server, and **the one place a cloner edits**.

A concrete trace makes the rewrite half clear. During an image upload Notion replies with an
absolute URL like `https://api.notion.com/v1/file_uploads/abc/send`. With the base URL set to
the local server, `_rewrite` strips the `NOTION_API_BASE_URL` prefix and prepends the base:

```
https://api.notion.com/v1/file_uploads/abc/send
        └────────── NOTION_API_BASE_URL ─────────┘
→ https://192.168.86.239:8787/v1/file_uploads/abc/send
```

So the second leg of the upload travels through the proxy too. If instead you've explicitly
set the base URL *to* `api.notion.com` (e.g. inside a native shell), `_rewrite` sees
`baseURL === NOTION_API_BASE_URL` and returns the URL untouched.

The error half mirrors this. A `fetch` that throws with no response means different things
depending on where you're pointed: against Notion directly it's almost certainly the CORS
block (show the "deploy a proxy" guidance); against your own proxy it means the server is
down or its self-signed certificate isn't trusted yet (so the message now names the address
it tried).

## Code

### `webapp/js/settings.js` — split the overloaded constant

```js
/** Notion's real API origin — used only to rewrite upload URLs and detect
 *  direct CORS-blocked calls. Don't change it. */
export const NOTION_API_BASE_URL = "https://api.notion.com";

/**
 * Where the web app sends Notion API calls out of the box.
 * 👉 CLONING THIS PROJECT? This is the one place to change the local server's
 *    location. Set it to YOUR server's scheme://host:port (no trailing slash).
 */
export const DEFAULT_API_BASE_URL = "https://192.168.86.239:8787";
```

Everything downstream already reads `DEFAULT_API_BASE_URL` (the `AppSettings` initial value,
the `apiBaseUrl` setter's empty-string fallback, the Settings placeholder, the "Reset to
default" button), so flipping its value re-points the whole app — no other wiring needed.

### `webapp/js/notion.js` — read the right constant for the right job

The import now pulls both constants, and the two internal checks switch from
`DEFAULT_API_BASE_URL` to `NOTION_API_BASE_URL`:

```js
import { DEFAULT_API_BASE_URL, NOTION_API_BASE_URL } from "./settings.js";

_rewrite(url) {
  if (this.baseURL === NOTION_API_BASE_URL) return url;          // talking straight to Notion
  if (url.startsWith(NOTION_API_BASE_URL)) {
    return this.baseURL + url.slice(NOTION_API_BASE_URL.length); // onto the proxy
  }
  return url;
}
```

The `fetch` failure path now distinguishes the two worlds, and names the address when a
proxy is unreachable:

```js
if (this.baseURL === NOTION_API_BASE_URL) throw NotionError.cors();
throw NotionError.network(
  `couldn't reach ${this.baseURL}. Is your proxy/local server running, and ` +
    `have you accepted its certificate? (${error?.message || "request failed"})`
);
```

> ⚠️ **Why the default param still imports `DEFAULT_API_BASE_URL`.** The constructor keeps
> `baseURL = DEFAULT_API_BASE_URL` so a `NotionClient` built with no explicit base still
> lands on the proxy. Both constants are therefore imported and both are used.

### In-app copy — `views/settings.js` and `views/onboarding.js`

The Settings hint no longer says "leave it as the default to call Notion directly" (no
longer true) and instead explains that the default routes through a local server you run,
and that `https://api.notion.com` is only for native wrappers / web-security-disabled
browsers. The onboarding CORS help toast is reworded to match.

### Documentation — the "where do I change it?" answer in five places

The heart of the task is making the server location easy to relocate after a clone. Every
doc that touches CORS now points at the single constant `DEFAULT_API_BASE_URL` in
`webapp/js/settings.js`:

- **`webapp/README.md`** — the "one catch: CORS" section now leads with "the app does not
  call Notion directly by default," shows the constant, and has a 👉 callout with the two
  ways to repoint it (edit the constant, or override per-browser in Settings).
- **`webapp/local-server/README.md`** — a new "This server *is* the web app's default"
  callout tells cloners to make the constant match their server's address.
- **Root `README.md`** — the versions table, the CORS callout, and the web quick start all
  reflect the proxy-by-default model and name the constant.
- **`AGENTS.md`** — the "no backend of our own" golden rule and the Web build/run note are
  corrected (the old text claimed `baseURL` defaults to `api.notion.com`).
- **`webapp/cloudflare-worker/README.md`** — reframed as the alternative to the default
  local server.

## Verification

There is no automated test suite or linter in this repo, so verification was done with
`node` directly:

- **Syntax check.** `node --check` passed on `js/settings.js`, `js/notion.js`,
  `js/views/settings.js`, and `js/views/onboarding.js`.
- **Logic harness.** A small script mocked `localStorage`/`fetch`, imported the real
  modules, and asserted: `DEFAULT_API_BASE_URL` is the local server and `NOTION_API_BASE_URL`
  is `api.notion.com`; a default `NotionClient` targets the local server; an upload URL from
  `api.notion.com` is rewritten onto the proxy base; a client explicitly pointed at Notion
  leaves that URL untouched; the `apiBaseUrl` setter trims a trailing slash and falls back to
  the default on empty input; and a failed `fetch` yields a **network** error through the
  proxy default versus a **cors** error when pointed directly at Notion. **All 10 assertions
  passed.**
- **Integration smoke test.** Started `webapp/local-server/server.js`, then issued a
  `GET /v1/users/me` through it. Notion returned `401 unauthorized` (token was fake) **with
  `Access-Control-Allow-Origin: *` added**, proving the default target proxies and adds CORS
  headers; `GET /` served `index.html`, confirming the same-origin static host.

> ✅ **How to QA manually.** Stand up the local server
> (`cd webapp/local-server && ./make-cert.sh <your-ip> && npm start`), open
> `https://<your-ip>:8787`, accept the self-signed cert once, paste a real token, and watch
> *Connect* succeed with **no proxy configuration** — that's the whole point. Then capture a
> couple of photos and upload; a new page should appear in your database. To see the new
> error path, point **Settings → API proxy** at a dead address and confirm the message names
> that address.

## Alternatives

### Alternative 1 — Default to a *relative* / same-origin base URL (`""`)

| Pros | Cons |
| --- | --- |
| Works for any cloner with zero edits **when** the app is served from the same box as the proxy | Breaks the moment the app is hosted apart from the proxy (e.g. GitHub Pages + home proxy), which is a supported setup |
| Nothing hardcoded to relocate | The upload-URL rewrite logic assumes an absolute base, so it would need extra handling |

### Alternative 2 — Keep `api.notion.com` as the default but show a setup wizard on first CORS failure

| Pros | Cons |
| --- | --- |
| No hardcoded personal address ships in the repo | Still *fails first, explains later* — exactly the confusion the task set out to remove |
| Nudges every user to configure their own proxy | More UI code for a single-user tool; the unconfigured default still never works |

The chosen approach (a hardcoded proxy default in one well-marked constant) makes the
working path the default for the project owner, keeps the absolute-URL rewrite logic intact,
and gives cloners exactly one obvious line to change.

## Suggested people to talk to

- **Kevin Tran** (`kevin.tran.kt@gmail.com`) — repo owner and the only human with context
  here. He owns the product intent and the Notion data-model decisions, and he chose the
  proxy-by-default direction in this task. He's the person to confirm the default address
  and how the local server is deployed on his network.

> 📌 Note: `webapp/js/notion.js`, `webapp/js/settings.js`, and `webapp/local-server/` were
> authored entirely by AI agents (commit history shows only `Claude` / `NotionScanner`), so
> there's no separate human maintainer for these files to consult beyond Kevin.

## Quiz

<details>
<summary>Q1. Why was the old single constant split into two?</summary>

- A. To support more than one proxy at a time
- B. Because the value is needed for two different jobs — the *default* call target and the *fixed Notion origin* used for URL rewriting / CORS detection — and those must now differ ✅
- C. To let the iOS app import it too
- D. Because `localStorage` can't hold a URL

**Correct: B.** Once the default points at a proxy, the rewrite and CORS-detection logic
still need Notion's real origin. `NOTION_API_BASE_URL` keeps that fixed address while
`DEFAULT_API_BASE_URL` becomes the (editable) proxy default. A, C, and D aren't what the
change is about.
</details>

<details>
<summary>Q2. After this change, what does a fresh <code>NotionClient("token")</code> (no base URL passed) call?</summary>

- A. `https://api.notion.com`
- B. Nothing until the user sets a proxy in Settings
- C. The self-hosted local server at `DEFAULT_API_BASE_URL` ✅
- D. The Cloudflare Worker

**Correct: C.** The constructor defaults `baseURL` to `DEFAULT_API_BASE_URL`, which now
points at the local server. A was the old behaviour; B is false (there's always a default);
D is only true if you set the constant to a Worker URL.
</details>

<details>
<summary>Q3. During an image upload, what does <code>_rewrite</code> do with the <code>upload_url</code> Notion returns?</summary>

- A. Leaves it as `api.notion.com` so the bytes go straight to Notion
- B. Strips the `NOTION_API_BASE_URL` prefix and prepends the configured base, so the upload also flows through the proxy ✅
- C. Discards it and re-derives the URL from the page ID
- D. Sends the bytes as base64 inside the page-create request

**Correct: B.** The rewrite moves the absolute Notion URL onto whatever base is configured,
keeping the second upload leg on the proxy. A would re-trigger CORS; C and D aren't how the
two-step upload works.
</details>

<details>
<summary>Q4. You point Settings → API proxy at an address where nothing is listening. What error do you get now?</summary>

- A. A CORS error telling you to deploy a Cloudflare Worker
- B. A network error that names the unreachable address and asks whether the server is running / its cert is trusted ✅
- C. A 401 "invalid token"
- D. Silent failure with no message

**Correct: B.** The CORS message is now reserved for the case where the base URL *is*
`api.notion.com`. For any other (proxy) base, a failed fetch reports a network error that
includes the address it tried. A is the old catch-all; C is a real HTTP response (not a
fetch failure); D isn't the behaviour.
</details>

<details>
<summary>Q5. A teammate clones the repo onto their own network. What's the recommended single edit to make Notion calls work?</summary>

- A. Rewrite `notion.js` to call `api.notion.com`
- B. Edit `DEFAULT_API_BASE_URL` in `webapp/js/settings.js` to their own server's address (or override per-browser in Settings → API proxy) ✅
- C. Change `NOTION_API_BASE_URL`
- D. Set an environment variable before serving the app

**Correct: B.** `DEFAULT_API_BASE_URL` is documented as the one place to relocate the
server. A reintroduces the CORS problem; C would break upload-URL rewriting and CORS
detection; D doesn't apply — the web app has no build/env step.
</details>
