# NotionScanner

Take photos and upload them straight into a Notion database. A batch of photos becomes one new row (page) in Notion, with every photo attached.

Built with SwiftUI + AVFoundation. No backend: it talks directly to the Notion API using your personal Internal Integration Token, stored in the iOS Keychain.

---

## Run it on your iPhone 17 Pro (from zero)

You write/edit code in Cursor, but you build and install the app with **Xcode** (already installed here, version 26.2).

### 1. Open the project

In Finder, double-click `NotionScan.xcodeproj` (in this folder). It opens in Xcode with all files already included.

### 2. Set up signing (free Apple ID is fine)

1. Xcode menu -> **Settings** -> **Accounts** -> **+** -> add your Apple ID.
2. In the left sidebar, click the blue **NotionScan** project -> select the **NotionScan** target -> **Signing & Capabilities** tab.
3. Check **Automatically manage signing**, and set **Team** to your name (Personal Team).
4. If you see a "bundle identifier is not available" error, change **Bundle Identifier** to something unique, e.g. `com.yourname.notionscanner`.

> Note: with a free account the installed app stops working after ~7 days. Just press Run again from Xcode to refresh it.

### 3. Prepare the iPhone

1. Plug the iPhone into the Mac with a cable. On the phone, tap **Trust This Computer**.
2. On the iPhone: **Settings -> Privacy & Security -> Developer Mode -> On**, then restart the phone.
3. (After the first install, if iOS blocks the app: **Settings -> General -> VPN & Device Management** -> trust your developer certificate.)

### 4. Run

1. At the top of Xcode, click the device dropdown and pick your **iPhone**.
2. Press the **Run** button (the play triangle), or Cmd+R.
3. The app builds, installs, and launches on your phone.

---

## Connect Notion (first launch, inside the app)

1. Go to [notion.so/my-integrations](https://www.notion.so/my-integrations) -> **New integration** -> type **Internal** -> create it.
2. Copy the **Internal Integration Secret** (starts with `ntn_`).
3. In Notion, open the **database** you want to upload to -> top-right **...** -> **Connections** -> add your integration. Repeat for any database you want available in the app.
4. In the app: paste the token, tap **Connect**, then pick your **default database**.

## Daily use

Open app -> tap the shutter to capture one or more photos -> tap **Done** -> review (delete any bad shots, pick the database) -> **Upload**. A new row appears in Notion with all the photos attached.

The gear icon (top-left of the camera) lets you see your default database or disconnect Notion.

---

## How it works (for the curious)

| File | Responsibility |
| --- | --- |
| `NotionScanApp.swift` | App entry; shows Onboarding until connected, then the Camera. |
| `AppSettings.swift` | Connection state (token + default database). |
| `KeychainStore.swift` | Stores the token securely in the Keychain. |
| `NotionClient.swift` | All Notion API calls (validate, list databases, upload file, create page). |
| `OnboardingView.swift` | Paste token + pick default database. |
| `CameraModel.swift` / `CameraPreviewView.swift` | AVCaptureSession + live preview. |
| `CameraView.swift` | Camera home screen, batch capture, settings. |
| `ReviewView.swift` | Preview batch, pick database, upload with progress. |

See `PRD.md` for the full product spec.
