#!/usr/bin/env node
/*
 * NotionScan local server
 *
 * A self-hosted version of the Cloudflare Worker proxy, meant to run on your own
 * machine (e.g. a home server at 192.168.86.239). It does two jobs:
 *
 *   1. MIDDLEWARE / CORS PROXY. The Notion API does not send CORS headers, so a
 *      browser blocks direct calls to https://api.notion.com from a web page.
 *      Every request whose path starts with "/v1/" is forwarded verbatim to
 *      api.notion.com (method, path, query, headers, body) and the response is
 *      returned with permissive CORS headers added. This is the exact same idea
 *      as webapp/cloudflare-worker/worker.js, just running on hardware you own.
 *
 *   2. STATIC HOST (optional, on by default). Every other path is served from
 *      the web app directory. Hosting the app from the same origin as the proxy
 *      means the browser makes same-origin requests, so CORS never even comes up,
 *      and — importantly — the camera API (getUserMedia) only works in a "secure
 *      context": https://… or http://localhost. Serving the app yourself over
 *      HTTPS (see the README's self-signed-certificate step) is what lets the
 *      camera work when you open the app from your phone at 192.168.86.239.
 *
 * Zero dependencies: this uses only Node's built-in http/https/fs/path modules,
 * so there is nothing to `npm install`. Node 18+ is the only requirement.
 *
 * It never logs request bodies, tokens, or responses; it only forwards.
 *
 * Configuration (all optional, via environment variables):
 *   PORT            Port to listen on.            Default: 8787
 *   HOST            Interface to bind.            Default: 0.0.0.0 (all interfaces)
 *   ALLOWED_ORIGIN  CORS allow-list origin.       Default: * (any)
 *   SERVE_STATIC    "false" to disable the host.  Default: enabled
 *   STATIC_DIR      Folder to serve the app from. Default: ../ (the webapp dir)
 *   TLS_CERT        Path to a TLS certificate.    Default: ./certs/cert.pem
 *   TLS_KEY         Path to the matching key.     Default: ./certs/key.pem
 *
 * If both TLS files exist the server starts on HTTPS; otherwise it falls back to
 * plain HTTP (fine for http://localhost, but the camera will not work over HTTP
 * on a LAN IP — see the README).
 */

"use strict";

const http = require("http");
const https = require("https");
const fs = require("fs");
const path = require("path");

const NOTION_HOST = "api.notion.com";

// --- Configuration -----------------------------------------------------------

const PORT = Number(process.env.PORT || 8787);
const HOST = process.env.HOST || "0.0.0.0";
const ALLOWED_ORIGIN = process.env.ALLOWED_ORIGIN || "*";
const SERVE_STATIC = process.env.SERVE_STATIC !== "false";
const STATIC_DIR = path.resolve(process.env.STATIC_DIR || path.join(__dirname, ".."));
const TLS_CERT = process.env.TLS_CERT || path.join(__dirname, "certs", "cert.pem");
const TLS_KEY = process.env.TLS_KEY || path.join(__dirname, "certs", "key.pem");

// --- CORS ---------------------------------------------------------------------

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
    "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type, Notion-Version",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

// --- Notion proxy -------------------------------------------------------------

function proxyToNotion(req, res, url) {
  // Forward the incoming headers, but drop the ones that describe the connection
  // to *us* so Node sets them correctly for the upstream TLS connection.
  const headers = { ...req.headers };
  delete headers.host;
  delete headers.origin;
  delete headers.referer;
  delete headers.connection;
  headers.host = NOTION_HOST;

  const upstream = https.request(
    {
      hostname: NOTION_HOST,
      port: 443,
      method: req.method,
      path: url.pathname + url.search,
      headers,
    },
    (upstreamRes) => {
      // Copy Notion's response headers and layer CORS on top. Notion's
      // Content-Security-Policy is meant for its own site and only gets in the
      // way here, so drop it (mirrors the Cloudflare Worker).
      const responseHeaders = { ...upstreamRes.headers };
      delete responseHeaders["content-security-policy"];
      Object.assign(responseHeaders, corsHeaders());

      res.writeHead(upstreamRes.statusCode, responseHeaders);
      upstreamRes.pipe(res);
    }
  );

  upstream.on("error", (err) => {
    res.writeHead(502, { "Content-Type": "application/json", ...corsHeaders() });
    res.end(
      JSON.stringify({
        object: "error",
        status: 502,
        code: "proxy_error",
        message: `Local NotionScan proxy could not reach Notion: ${err.message}`,
      })
    );
  });

  // Stream the request body (JSON or multipart photo upload) straight through.
  req.pipe(upstream);
}

// --- Static file host ---------------------------------------------------------

const MIME_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".txt": "text/plain; charset=utf-8",
};

function sendFile(res, filePath) {
  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("Not found");
      return;
    }
    const type = MIME_TYPES[path.extname(filePath).toLowerCase()] || "application/octet-stream";
    res.writeHead(200, { "Content-Type": type });
    res.end(data);
  });
}

function serveStatic(req, res, url) {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.writeHead(405, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("Method not allowed");
    return;
  }

  let pathname = decodeURIComponent(url.pathname);
  if (pathname.endsWith("/")) pathname += "index.html";

  // Resolve inside STATIC_DIR and refuse anything that escapes it (path traversal).
  const filePath = path.normalize(path.join(STATIC_DIR, pathname));
  if (filePath !== STATIC_DIR && !filePath.startsWith(STATIC_DIR + path.sep)) {
    res.writeHead(403, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("Forbidden");
    return;
  }

  fs.stat(filePath, (err, stat) => {
    if (!err && stat.isDirectory()) {
      sendFile(res, path.join(filePath, "index.html"));
      return;
    }
    sendFile(res, filePath);
  });
}

// --- Router -------------------------------------------------------------------

function handler(req, res) {
  // Answer CORS preflight checks without bothering Notion.
  if (req.method === "OPTIONS") {
    res.writeHead(204, corsHeaders());
    res.end();
    return;
  }

  const url = new URL(req.url, "http://localhost");

  // Anything under /v1/ is a Notion API call → proxy it.
  if (url.pathname.startsWith("/v1/")) {
    proxyToNotion(req, res, url);
    return;
  }

  if (SERVE_STATIC) {
    serveStatic(req, res, url);
    return;
  }

  res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8", ...corsHeaders() });
  res.end("Not found. This server proxies Notion API paths under /v1/.");
}

// --- Boot ---------------------------------------------------------------------

const hasTls = fs.existsSync(TLS_CERT) && fs.existsSync(TLS_KEY);
let server;
let scheme;

if (hasTls) {
  server = https.createServer(
    { cert: fs.readFileSync(TLS_CERT), key: fs.readFileSync(TLS_KEY) },
    handler
  );
  scheme = "https";
} else {
  server = http.createServer(handler);
  scheme = "http";
}

server.listen(PORT, HOST, () => {
  const where = HOST === "0.0.0.0" ? "all interfaces" : HOST;
  console.log(`NotionScan local server listening on ${scheme}://${where}:${PORT}`);
  console.log(`  • Notion proxy : ${scheme}://<this-host>:${PORT}/v1/...  (set this base URL in Settings → API proxy)`);
  console.log(`  • Static host  : ${SERVE_STATIC ? `serving ${STATIC_DIR}` : "disabled"}`);
  console.log(`  • CORS origin  : ${ALLOWED_ORIGIN}`);
  if (!hasTls) {
    console.log(
      "  • TLS          : OFF (plain HTTP). The camera needs a secure context, so over a LAN IP\n" +
        "                   generate a certificate (see README) to serve over HTTPS."
    );
  }
});
