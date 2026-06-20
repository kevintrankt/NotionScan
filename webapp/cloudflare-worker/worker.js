/*
 * NotionScan CORS proxy — Cloudflare Worker
 *
 * The Notion API does not send CORS headers, so a browser blocks direct calls to
 * https://api.notion.com from a web page. This tiny Worker sits in between: it
 * forwards every request to api.notion.com unchanged (method, path, headers,
 * body) and adds permissive CORS headers to the response, so the NotionScan web
 * app can talk to Notion from any origin.
 *
 * Deploy (free):
 *   1. Create a Cloudflare account and install Wrangler: `npm i -g wrangler`.
 *   2. In this folder run `wrangler deploy` (a minimal wrangler.toml is included).
 *   3. Copy the resulting *.workers.dev URL.
 *   4. In NotionScan → Settings → "API proxy", paste that URL and Save.
 *
 * Security note: your integration token passes THROUGH this Worker on its way to
 * Notion. Deploy your OWN Worker — never point the app at a proxy you don't
 * control, or you would be handing your Notion token to a stranger. This Worker
 * never logs or stores anything; it only forwards.
 *
 * Optional hardening: set the ALLOWED_ORIGIN variable (e.g. to your GitHub Pages
 * origin) to restrict which site may use the proxy.
 */

const NOTION_ORIGIN = "https://api.notion.com";

export default {
  async fetch(request, env) {
    const allowedOrigin = env?.ALLOWED_ORIGIN || "*";

    // Preflight: answer CORS checks without touching Notion.
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders(allowedOrigin) });
    }

    const url = new URL(request.url);
    const target = NOTION_ORIGIN + url.pathname + url.search;

    // Forward the request verbatim. We strip hop-by-hop/host headers so Cloudflare
    // sets them correctly for the upstream connection.
    const headers = new Headers(request.headers);
    headers.delete("host");
    headers.delete("origin");
    headers.delete("referer");

    const init = {
      method: request.method,
      headers,
      body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
      redirect: "follow",
    };

    const upstream = await fetch(target, init);

    // Copy the upstream response and layer on CORS headers.
    const responseHeaders = new Headers(upstream.headers);
    for (const [key, value] of Object.entries(corsHeaders(allowedOrigin))) {
      responseHeaders.set(key, value);
    }
    // Content-Security-Policy from Notion can interfere; it's irrelevant here.
    responseHeaders.delete("content-security-policy");

    return new Response(upstream.body, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers: responseHeaders,
    });
  },
};

function corsHeaders(origin) {
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type, Notion-Version",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}
