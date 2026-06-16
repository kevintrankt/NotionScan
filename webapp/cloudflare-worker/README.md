# NotionScan CORS proxy (optional)

The Notion API doesn't return [CORS](https://developer.mozilla.org/docs/Web/HTTP/CORS) headers, so a browser refuses to let a web page call `https://api.notion.com` directly. The native iOS app isn't affected (native apps don't enforce CORS), but the web app is.

This folder is a **one-file Cloudflare Worker** that forwards requests to Notion and adds the missing CORS headers. It's free to deploy and means the NotionScan web app can run fully client-side from GitHub Pages.

> **You only need this if you see a CORS error in the web app.** If you wrap the web app in a native shell (e.g. Capacitor) or run a browser with web security disabled for testing, you can skip it.

## Deploy

1. Create a free [Cloudflare account](https://dash.cloudflare.com/sign-up).
2. Install Wrangler: `npm install -g wrangler` then `wrangler login`.
3. From this folder, run `wrangler deploy`.
4. Copy the deployed URL, e.g. `https://notionscan-proxy.YOUR-NAME.workers.dev`.
5. In NotionScan → **Settings → API proxy**, paste that URL and tap **Save proxy URL**.

That's it — every Notion call now flows through your Worker.

## Security

Your Notion integration token passes **through** this Worker on its way to Notion. That's fine when it's *your* Worker, but it's exactly why you must **deploy your own** rather than borrow someone else's — otherwise you'd be handing your token to a stranger.

The Worker never logs or stores anything; it only forwards. To be extra safe, uncomment `ALLOWED_ORIGIN` in `wrangler.toml` and set it to your site's origin so only your deployment can use the proxy.
