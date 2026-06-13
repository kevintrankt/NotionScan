# NotionScan — Product Requirements Document (PRD)

## 1. One-line summary
A dead-simple iOS camera app that lets you snap a batch of photos and push them
straight into a Notion database, removing the friction of getting raw visual data
into Notion.

## 2. Problem
Capturing something in the real world (a receipt, a whiteboard, a label, a page of
notes) and getting it into Notion today means: open camera → take photo → open
Notion → find the right database → create a row → attach the image. That is 6+ steps
and several app switches. People give up and the data never makes it in.

## 3. Goal
Reduce "thing in the real world → row in Notion" to **open app → shoot → upload**.
The app opens directly to a camera. The default destination database is remembered.
A batch of photos becomes a single Notion row (page) with the images attached.

## 4. Target user
A single Notion user (personal use). The author of this app, on an iPhone 17 Pro.
No multi-user accounts, no team sharing, no App Store distribution required for v1.

## 5. Non-goals (v1)
- No OAuth / public Notion integration (we use a personal "internal integration token").
- No editing of existing Notion rows.
- No video, no PDF, no document scanning / edge-detection / cropping.
- No offline queue / retry-later. (If upload fails, user retries manually.)
- No cloud backend of our own. The phone talks directly to the Notion API.
- No automatic saving of every shot to the Photos library — saving is an explicit,
  opt-in toggle (see 7.3 / 7.4), off by default.
- No iPad / Mac / Vision Pro optimization (the project template supports them, but
  v1 targets iPhone only).

## 6. Key user stories
1. **First launch / onboarding.** As a new user, I am asked to connect my Notion by
   pasting my integration token. The app verifies it works, then shows me a list of
   my databases so I can pick a default destination.
2. **Capture.** As a returning user, the app opens straight to a live camera. I can
   take multiple photos in a row; each capture adds a thumbnail to a strip so I can
   see my batch growing.
3. **Review.** When I tap "Done", I see my batch in a grid. I can delete any bad
   shots. The default database is pre-selected, but I can change the destination for
   this batch.
4. **Upload.** I tap "Upload". The app shows progress while it uploads each image and
   creates one Notion page containing all of them. On success I'm returned to the
   camera, ready for the next capture.
5. **Reconnect / change default.** As a user, I can open Settings to paste a new token
   or change my default database.

## 7. Functional requirements

### 7.1 Onboarding & auth
- On launch, check the iOS Keychain for a stored Notion token.
  - If absent → show Onboarding.
  - If present → go straight to Camera.
- Onboarding screen:
  - Text field to paste a Notion **internal integration token** (starts with `ntn_`
    or `secret_`), with inline step-by-step help on where to get it.
  - "Connect" button validates the token via `GET https://api.notion.com/v1/users/me`.
  - On success, store token in Keychain and fetch the user's databases.
  - Show a picker of databases; selecting one stores its ID as the default
    (in `UserDefaults`). Then proceed to Camera.
- Errors (invalid token, no network, no shared databases) are shown clearly with a
  retry path.

### 7.2 Camera (home screen)
- Full-screen live camera preview (`AVFoundation`).
- Shutter button to capture a still photo (saved to an in-memory batch, not the photo
  library).
- Controls: flash toggle (off/on/auto), front/back camera flip.
- A horizontal thumbnail strip of photos captured so far in the current batch.
- A "Done (N)" button (N = count) that opens Review. Disabled when N = 0.
- A way to reach Settings (e.g. a gear icon).
- Requesting camera permission on first use; if denied, show guidance to enable it in
  iOS Settings.

### 7.3 Review & upload
- Grid of captured photos with a delete control on each.
- Database picker, defaulting to the saved default database; user can override for
  this batch only.
- "Upload" button. While uploading, show determinate-ish progress (e.g. "Uploading
  3 of 5…") and block double-submits.
- A "Save to Photos" toggle (defaults to the global preference set in Settings; can be
  overridden for this batch). When on, the batch's photos are written to the iOS
  Photos library as part of the upload action.
- Upload result:
  - Success → toast/confirmation, clear the batch, return to Camera.
  - Partial/total failure → show which step failed and allow retry.

### 7.4 Settings
- Show connection status (connected as <workspace/user>).
- Re-paste / replace token.
- Change default database (re-fetch list).
- "Save photos to library by default" toggle (global default for new batches; off by
  default). When first enabled, iOS will prompt for Photos add permission.
- "Disconnect" (clears Keychain token + default DB) → returns to Onboarding.

## 8. Notion data model & API behavior
- **One batch = one Notion page** created in the chosen database.
- Page title property: a human-readable timestamp (e.g. `NotionScan 2026-06-13 14:35`).
  - The title property is whatever the database's title column is named; we detect it.
- Page body (`children`): one **image block per photo**, in capture order.
- Upload sequence (per the Notion File Upload API):
  1. For each photo: `POST /v1/file_uploads` → returns `{ id, upload_url }`.
  2. `POST {upload_url}` with `multipart/form-data`, field name `file`, the JPEG bytes
     → file status becomes `uploaded`.
  3. After all uploads: `POST /v1/pages` with `parent.database_id`, the title property,
     and `children` = one image block per file, each referencing
     `{ type: "file_upload", file_upload: { id } }`.
- Required headers on every call:
  - `Authorization: Bearer <token>`
  - `Notion-Version: 2022-06-28`
  - `Content-Type: application/json` (except the raw multipart upload POST).
- Database discovery: `POST /v1/search` with filter `{ value: "database", property: "object" }`.
  - Note: only databases that the integration has been **shared with** (via the
    database's "Connections" menu) will appear. The onboarding help must call this out.

## 9. Constraints & assumptions
- Personal-use app signed with a **free Apple ID / Personal Team**, so the build
  expires ~7 days after install and must be re-run from Xcode to refresh. Acceptable.
- Token is a personal secret stored only in the device Keychain; it is never sent
  anywhere except `api.notion.com`.
- JPEG compression applied to keep uploads small/fast (e.g. quality ~0.8).
- Photos live only in memory during a batch and are discarded after a successful
  upload, **unless** the user enables "Save to Photos" (opt-in, off by default), in
  which case they are also written to the iOS Photos library. Saving requires the
  `NSPhotoLibraryAddUsageDescription` permission string and the user granting access.

## 10. Success metrics (informal, personal)
- Time from app launch to a photo landing in Notion: target < 15 seconds.
- Number of taps from launch to upload of a single photo: target ≤ 4
  (launch → shutter → Done → Upload).

## 11. Risks
- **Notion API shape changes / file-upload nuances.** Mitigation: keep `NotionClient`
  isolated and easy to tweak; log raw responses on failure.
- **Integration not shared with the target database** → it won't appear in the list.
  Mitigation: explicit onboarding instructions + an empty-state hint.
- **Free-signing 7-day expiry** surprises the user. Mitigation: documented in setup.
- **Camera permissions denied.** Mitigation: graceful in-app guidance.

## 12. Future / v2 ideas (out of scope now)
- OAuth so non-technical users can connect without a manual token.
- Offline queue with automatic retry.
- Document scanner (edge detection, perspective correction) via VisionKit.
- Map extra Notion properties (e.g. a Date, a Category select) at upload time.
