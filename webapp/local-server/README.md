# NotionScan local server (self-hosted middleware)

Run the NotionScan middleware on **your own machine** — for example a home
server at `192.168.86.239` — instead of (or alongside) the Cloudflare Worker.

It is a single, **zero-dependency** Node script (`server.js`) that does two things:

1. **Notion CORS proxy.** The Notion API doesn't send CORS headers, so a browser
   refuses to call `https://api.notion.com` directly from a web page. Any request
   whose path starts with `/v1/` is forwarded to Notion and returned with the
   missing CORS headers added. This is the same job as the Cloudflare Worker, on
   hardware you own.
2. **Static host (optional, on by default).** Every other path is served from the
   `webapp/` folder. Hosting the app from the same origin as the proxy means the
   browser makes *same-origin* requests (so CORS never even comes up), and — just
   as important — the camera (`getUserMedia`) only works in a **secure context**
   (`https://…` or `http://localhost`). Serving the app yourself over HTTPS is
   what makes the camera work when you open it from your phone at `192.168.86.239`.

> **Recommended setup:** serve the app *and* proxy from this one server over
> HTTPS, and point the app's API proxy at the same address. One box, one origin,
> camera works, no CORS, no mixed-content surprises.

---

## 1. Install Node.js on your local server

You need **Node.js 18 or newer** (it ships the `fetch`/streaming features this
uses). Pick the line that matches your server's OS.

**Debian / Ubuntu / Raspberry Pi OS:**

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs git
```

**Fedora / RHEL / CentOS:**

```bash
sudo dnf install -y nodejs git
```

**macOS (Homebrew):**

```bash
brew install node git
```

**Any OS, no root (via nvm):**

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
# restart your shell, then:
nvm install 22
```

Verify:

```bash
node --version   # should print v18.x or newer
```

There is **nothing to `npm install`** — the server has no dependencies.

## 2. Get the code onto the server

```bash
git clone https://github.com/kevintrankt/NotionScan.git
cd NotionScan/webapp/local-server
```

The local server ships on the default branch (`main`), so a plain clone is all
you need — no `git checkout` of a feature branch required.

## 3. Generate an HTTPS certificate (needed for the camera)

Over a LAN IP the camera only works on HTTPS, so create a self-signed
certificate that lists your server's IP. A helper script is included:

```bash
chmod +x make-cert.sh
./make-cert.sh 192.168.86.239
```

This writes `certs/cert.pem` and `certs/key.pem`, which `server.js` picks up
automatically. (Prefer to do it by hand? It's just:
`openssl req -x509 -newkey rsa:2048 -nodes -keyout certs/key.pem -out certs/cert.pem -days 3650 -subj "/CN=192.168.86.239" -addext "subjectAltName=IP:192.168.86.239"`.)

> Skip this step only if you'll access the app exclusively from
> `http://localhost` on the server itself — there, HTTP is already a secure
> context.

## 4. Run it

```bash
npm start
# or: node server.js
```

You'll see something like:

```
NotionScan local server listening on https://all interfaces:8787
  • Notion proxy : https://<this-host>:8787/v1/...  (set this base URL in Settings → API proxy)
  • Static host  : serving /home/you/NotionScan/webapp
  • CORS origin  : *
```

Open the firewall for the port if needed:

```bash
sudo ufw allow 8787/tcp           # Debian/Ubuntu
# or: sudo firewall-cmd --add-port=8787/tcp --permanent && sudo firewall-cmd --reload
```

## 5. Use it from your phone

1. On your phone (same Wi‑Fi), open **`https://192.168.86.239:8787`**.
2. Your browser warns about the self-signed certificate — choose **Advanced →
   Proceed/Visit anyway**. (You only do this once per device.)
3. The NotionScan app loads. Go to **Settings → API proxy** and set it to
   **`https://192.168.86.239:8787`**, then **Save proxy URL**.
4. Paste your Notion token, pick a database, and start scanning. Because the app
   and the proxy share one origin, Notion calls just work.

---

## Configuration

All optional, set as environment variables before `node server.js`:

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `8787` | Port to listen on. |
| `HOST` | `0.0.0.0` | Interface to bind (`0.0.0.0` = reachable on the LAN). |
| `ALLOWED_ORIGIN` | `*` | Restrict CORS to one origin (e.g. your GitHub Pages site). |
| `SERVE_STATIC` | enabled | Set to `false` to run as a *proxy only* (no static host). |
| `STATIC_DIR` | `../` | Folder to serve the app from. |
| `TLS_CERT` / `TLS_KEY` | `./certs/*.pem` | TLS files; if both exist the server uses HTTPS, else HTTP. |

Example — proxy only, locked to your GitHub Pages origin:

```bash
SERVE_STATIC=false ALLOWED_ORIGIN=https://YOUR_USERNAME.github.io node server.js
```

### Using it as a proxy for a GitHub Pages app

If you'd rather keep hosting the app on GitHub Pages, run this server as a
proxy and set **Settings → API proxy** to `https://192.168.86.239:8787`. Two
things to know: the Pages site is HTTPS, so the proxy **must** be HTTPS too
(browsers block HTTPS→HTTP "mixed content"), and you'll need to visit
`https://192.168.86.239:8787` once to accept the self-signed certificate so the
browser will trust it for background requests.

## Run it persistently (Linux / systemd)

A ready-to-edit unit file, `notionscan.service`, is included:

```bash
# edit the User= and WorkingDirectory= paths first, then:
sudo cp notionscan.service /etc/systemd/system/notionscan.service
sudo systemctl daemon-reload
sudo systemctl enable --now notionscan
systemctl status notionscan
```

It restarts on failure and starts on boot.

## Security

- Your Notion token passes **through** this server on its way to Notion. That's
  fine because it's *your* server — but only run code you trust, and don't expose
  it to the public internet. Keep it on your LAN.
- The server never logs or stores requests, bodies, or tokens; it only forwards.
- `certs/` and `*.pem` are git-ignored so your private key never gets committed.
- For a little extra safety, set `ALLOWED_ORIGIN` to your exact app origin so no
  other web page can route traffic through your proxy.
