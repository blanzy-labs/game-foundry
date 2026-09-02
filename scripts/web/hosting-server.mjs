#!/usr/bin/env node

import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const contentTypes = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.pck': 'application/octet-stream',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.ico': 'image/x-icon',
};

export function safeRootPath(root, requestPath) {
  let decoded = decodeURIComponent(requestPath).replace(/^\/+/, '');
  if (decoded.endsWith('/')) decoded += 'index.html';
  if (!decoded || decoded.split('/').some((part) => part === '..' || part === '.')) return null;
  const resolved = path.resolve(root, decoded);
  if (!resolved.startsWith(`${path.resolve(root)}${path.sep}`)) return null;
  return { decoded, resolved };
}

export function createStaticServer({ root, kind, manifestPath = null, corsOrigin = () => null, fault = 'none' }) {
  return http.createServer((req, res) => {
    let safe = null;
    try { safe = safeRootPath(root, new URL(req.url, 'http://127.0.0.1').pathname); } catch {}
    if (!safe) { res.writeHead(403); res.end('forbidden'); return; }
    if (!['GET', 'HEAD', 'OPTIONS'].includes(req.method || '')) { res.writeHead(405, { Allow: 'GET, HEAD, OPTIONS' }); res.end(); return; }
    const expectedOrigin = corsOrigin();
    const responseOrigin = fault === 'wrong_cors' ? 'http://127.0.0.1:1' : expectedOrigin;
    const corsHeaders = kind === 'assets' && fault !== 'missing_cors' && responseOrigin ? {
      'Access-Control-Allow-Origin': responseOrigin,
      'Access-Control-Allow-Methods': 'GET, HEAD',
      'Vary': 'Origin',
    } : {};
    if (req.method === 'OPTIONS') { res.writeHead(204, corsHeaders); res.end(); return; }
    let stat;
    try { stat = fs.lstatSync(safe.resolved); } catch { res.writeHead(404, corsHeaders); res.end('not found'); return; }
    if (!stat.isFile() || stat.isSymbolicLink()) { res.writeHead(404, corsHeaders); res.end('not found'); return; }
    let real;
    try { real = fs.realpathSync(safe.resolved); } catch { res.writeHead(404, corsHeaders); res.end('not found'); return; }
    const realRoot = fs.realpathSync(root);
    if (!real.startsWith(`${realRoot}${path.sep}`)) { res.writeHead(403, corsHeaders); res.end('forbidden'); return; }
    let record = null;
    if (manifestPath) {
      try {
        const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
        const packageName = kind === 'assets' ? 'r2' : 'pages';
        record = manifest.files.find((item) => item.package === packageName && item.deployment_path === safe.decoded) || null;
      } catch {}
      if (!record) { res.writeHead(404, corsHeaders); res.end('not manifested'); return; }
    }
    let type = record?.mime || contentTypes[path.extname(safe.decoded).toLowerCase()] || 'application/octet-stream';
    if (kind === 'assets' && fault === 'bad_mime' && safe.decoded.endsWith('.wasm')) type = 'application/octet-stream';
    const cacheByClass = { immutable: 'public, max-age=31536000, immutable', revalidate: 'no-cache', 'versioned-site-asset': 'public, max-age=3600' };
    const cache = record ? cacheByClass[record.cache_policy_class] : (kind === 'assets' ? cacheByClass.immutable : (safe.decoded.endsWith('.html') ? cacheByClass.revalidate : cacheByClass['versioned-site-asset']));
    if (!cache) { res.writeHead(500, corsHeaders); res.end('invalid cache contract'); return; }
    const headers = { ...corsHeaders, 'Content-Type': type, 'Content-Length': stat.size, 'Cache-Control': cache };
    res.writeHead(200, headers);
    if (req.method === 'HEAD') { res.end(); return; }
    fs.createReadStream(real).pipe(res);
  });
}

export async function listen(server, port = 0) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
  return server.address().port;
}

export async function closeServer(server) {
  if (!server?.listening) return;
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`${command} failed: ${result.stderr || result.stdout}`.trim());
  return result.stdout;
}

async function cli() {
  const argv = process.argv.slice(2);
  if (argv.length !== 1) throw new Error('usage: hosting-server.mjs HOSTING_RELEASE');
  const release = path.resolve(argv[0]);
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
  run(path.join(repoRoot, 'scripts/gf-web-hosting-verify.sh'), [release]);
  const sourceManifest = JSON.parse(fs.readFileSync(path.join(release, 'hosting-manifest.json'), 'utf8'));
  const finalized = fs.mkdtempSync(path.join(os.tmpdir(), 'game-foundry-web-preview.'));
  fs.rmSync(finalized, { recursive: true });
  let siteOrigin = null;
  const finalizedManifest = path.join(finalized, 'hosting-manifest.json');
  const siteServer = createStaticServer({ root: path.join(finalized, 'pages'), kind: 'site', manifestPath: finalizedManifest });
  const assetServer = sourceManifest.cross_origin_required ? createStaticServer({ root: path.join(finalized, 'r2'), kind: 'assets', manifestPath: finalizedManifest, corsOrigin: () => siteOrigin }) : null;
  let closed = false;
  const shutdown = async (code = 0) => {
    if (closed) return;
    closed = true;
    await Promise.allSettled([closeServer(siteServer), closeServer(assetServer)]);
    fs.rmSync(finalized, { recursive: true, force: true });
    process.exit(code);
  };
  process.on('SIGINT', () => void shutdown(0));
  process.on('SIGTERM', () => void shutdown(0));
  process.on('uncaughtException', (error) => { process.stderr.write(`${error.stack || error}\n`); void shutdown(1); });
  const sitePort = await listen(siteServer);
  siteOrigin = `http://127.0.0.1:${sitePort}`;
  let assetOrigin = '';
  if (assetServer) assetOrigin = `http://127.0.0.1:${await listen(assetServer)}`;
  const finalizeArgs = ['--site-origin', siteOrigin];
  if (assetOrigin) finalizeArgs.push('--asset-origin', assetOrigin);
  finalizeArgs.push(release, finalized);
  run(path.join(repoRoot, 'scripts/gf-web-hosting-finalize.sh'), finalizeArgs);
  const route = sourceManifest.site_route;
  const gameUrl = `${siteOrigin}${route}`;
  process.stdout.write(`Game Foundry local Web preview\n\nGame URL:\n${gameUrl}\n\n`);
  if (assetOrigin) process.stdout.write(`Asset origin:\n${assetOrigin}/\n\n`);
  process.stdout.write(`Hosting profile:\n${sourceManifest.hosting_profile}\n\nPress Ctrl-C to stop.\n`);
  if (process.env.GF_WEB_PREVIEW_READY_FILE) {
    fs.writeFileSync(process.env.GF_WEB_PREVIEW_READY_FILE, `${JSON.stringify({ game_url: gameUrl, site_origin: siteOrigin, asset_origin: assetOrigin || null, pid: process.pid })}\n`);
  }
  await new Promise(() => {});
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  cli().catch((error) => { process.stderr.write(`${error.stack || error}\n`); process.exit(1); });
}
