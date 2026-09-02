#!/usr/bin/env node

import { chromium } from 'playwright';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import process from 'node:process';
import { performance } from 'node:perf_hooks';
import { spawnSync } from 'node:child_process';
import { createStaticServer, listen as hostingListen, closeServer as hostingCloseServer } from './hosting-server.mjs';

const args = process.argv.slice(2);
const option = (name, fallback = '') => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : fallback;
};
const hostingReleaseValue = option('--hosting-release');
const hostingMode = Boolean(hostingReleaseValue);
const hostingRelease = hostingMode ? path.resolve(hostingReleaseValue) : null;
const sourceHostingManifest = hostingMode ? JSON.parse(fs.readFileSync(path.join(hostingRelease, 'hosting-manifest.json'), 'utf8')) : null;
const manifestPath = hostingMode ? path.join(hostingRelease, sourceHostingManifest.source_web_manifest) : path.resolve(option('--manifest'));
let bundleRoot = hostingMode ? path.join(hostingRelease, 'pages') : path.resolve(option('--bundle'));
const artifactRoot = path.resolve(option('--artifact'));
const fault = option('--fault', 'none');
const startupTimeout = Number(option('--startup-timeout-ms', '15000'));
const inputTimeout = Number(option('--input-timeout-ms', '5000'));
const desktopViewport = { width: 1280, height: 720 };
const smallViewport = { width: 390, height: 844 };
const resizeViewport = { width: 1024, height: 640 };
const started = performance.now();
fs.mkdirSync(artifactRoot, { recursive: true });

const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const entrypoint = hostingMode ? sourceHostingManifest.entrypoint_deployment_path : manifest.entrypoint;
const entryStem = entrypoint.replace(/\.html$/i, '');
const sourceEntryStem = manifest.entrypoint.replace(/\.html$/i, '');
const hostingByOriginal = new Map((sourceHostingManifest?.files || []).map((item) => [item.original_path, item]));
const deploymentPath = (item) => hostingMode ? hostingByOriginal.get(item.path)?.deployment_path : item.path;
const requiredSourceFiles = manifest.files.filter((item) => ['entry_html', 'wasm', 'game_data'].includes(item.content_role) || (item.content_role === 'javascript' && item.path === `${sourceEntryStem}.js`));
const critical = new Map(requiredSourceFiles.map((item) => [deploymentPath(item), item]));
const optionalAssets = manifest.files.filter((item) => !requiredSourceFiles.includes(item)).map((item) => deploymentPath(item));
const wasmPaths = manifest.files.filter((item) => item.content_role === 'wasm').map((item) => deploymentPath(item));
const consoleMessages = [];
const pageErrors = [];
const network = [];
const failedRequests = [];
const pendingEvents = [];
const timings = { server_start_seconds: null, browser_launch_seconds: null, navigation_seconds: null, runtime_ready_seconds: null, input_response_seconds: null, total_seconds: null };
let browser = null;
let server = null;
let assetServer = null;
let browserClosed = false;
let serverClosed = false;
let assetServerClosed = false;
let url = null;
let browserVersion = null;
let siteOrigin = null;
let assetOrigin = null;
let finalizedHostingRoot = null;
const processMarker = `gf-web-acceptance-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;

const contentTypes = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.wasm': 'application/wasm',
  '.pck': 'application/octet-stream', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
};

function safeBundlePath(requestPath) {
  const decoded = decodeURIComponent(requestPath).replace(/^\/+/, '') || entrypoint;
  if (decoded.split('/').some((part) => part === '..' || part === '.')) return null;
  const resolved = path.resolve(bundleRoot, decoded);
  if (resolved !== bundleRoot && !resolved.startsWith(`${bundleRoot}${path.sep}`)) return null;
  return { decoded, resolved };
}

async function listen(serverValue, port = 0) {
  await new Promise((resolve, reject) => {
    serverValue.once('error', reject);
    serverValue.listen(port, '127.0.0.1', resolve);
  });
}

async function closeServer(value) {
  if (!value || !value.listening) return;
  await new Promise((resolve, reject) => value.close((error) => error ? reject(error) : resolve()));
}

function chromiumProcessIds() {
  if (!fs.existsSync('/proc')) return [];
  const ids = [];
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const commandLine = fs.readFileSync(`/proc/${entry}/cmdline`, 'utf8');
      if (commandLine.includes(processMarker)) ids.push(Number(entry));
    } catch {}
  }
  return ids.sort((a, b) => a - b);
}

async function waitForChromiumExit(timeoutMs = 3000) {
  const deadline = performance.now() + timeoutMs;
  let remaining = chromiumProcessIds();
  while (remaining.length > 0 && performance.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
    remaining = chromiumProcessIds();
  }
  return remaining;
}

async function startServer() {
  const start = performance.now();
  if (hostingMode) {
    finalizedHostingRoot = path.join(artifactRoot, 'finalized-local');
    siteOrigin = null;
    const finalizedManifestPath = path.join(finalizedHostingRoot, 'hosting-manifest.json');
    server = createStaticServer({ root: path.join(finalizedHostingRoot, 'pages'), kind: 'site', manifestPath: finalizedManifestPath });
    const assetFault = ['missing_cors', 'wrong_cors', 'bad_mime'].includes(fault) ? fault : 'none';
    assetServer = sourceHostingManifest.cross_origin_required ? createStaticServer({ root: path.join(finalizedHostingRoot, 'r2'), kind: 'assets', manifestPath: finalizedManifestPath, corsOrigin: () => siteOrigin, fault: assetFault }) : null;
    const sitePort = await hostingListen(server);
    siteOrigin = `http://127.0.0.1:${sitePort}`;
    if (assetServer) assetOrigin = `http://127.0.0.1:${await hostingListen(assetServer)}`;
    const effectiveAssetOrigin = fault === 'wrong_asset_origin' ? 'http://127.0.0.1:9' : assetOrigin;
    const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
    const finalizeArgs = ['--site-origin', siteOrigin];
    if (effectiveAssetOrigin) finalizeArgs.push('--asset-origin', effectiveAssetOrigin);
    finalizeArgs.push(hostingRelease, finalizedHostingRoot);
    const finalized = spawnSync(path.join(repoRoot, 'scripts/gf-web-hosting-finalize.sh'), finalizeArgs, { encoding: 'utf8' });
    if (finalized.status !== 0) throw new Error(`HOSTING_FINALIZATION_FAILED: ${finalized.stderr || finalized.stdout}`.trim());
    bundleRoot = path.join(finalizedHostingRoot, 'pages');
    url = `${siteOrigin}/${entrypoint}`;
    timings.server_start_seconds = (performance.now() - start) / 1000;
    return;
  }
  if (fault === 'server_bind_failure') {
    const blocker = http.createServer((_req, res) => res.end('occupied'));
    await listen(blocker);
    const port = blocker.address().port;
    const conflict = http.createServer();
    try {
      await listen(conflict, port);
    } finally {
      await closeServer(conflict);
      await closeServer(blocker);
      serverClosed = true;
    }
    throw new Error('HTTP_SERVER_BIND_FAILED_EXPECTED');
  }
  server = http.createServer((req, res) => {
    let safe;
    try { safe = safeBundlePath(new URL(req.url, 'http://127.0.0.1').pathname); } catch { safe = null; }
    if (!safe) { res.writeHead(403); res.end('forbidden'); return; }
    let stat;
    try { stat = fs.lstatSync(safe.resolved); } catch { res.writeHead(404); res.end('not found'); return; }
    if (!stat.isFile() || stat.isSymbolicLink()) { res.writeHead(404); res.end('not found'); return; }
    let type = contentTypes[path.extname(safe.decoded).toLowerCase()] || 'application/octet-stream';
    if (fault === 'bad_mime' && safe.decoded.endsWith('.wasm')) type = 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': type, 'Content-Length': stat.size, 'Cache-Control': 'no-store' });
    fs.createReadStream(safe.resolved).pipe(res);
  });
  await listen(server);
  timings.server_start_seconds = (performance.now() - start) / 1000;
  url = `http://127.0.0.1:${server.address().port}/${entrypoint}`;
}

function attachEvidence(page, profile) {
  page.on('console', (message) => consoleMessages.push({ profile, type: message.type(), text: message.text(), timestamp: new Date().toISOString() }));
  page.on('pageerror', (error) => pageErrors.push({ profile, message: error.message, stack: error.stack || null, timestamp: new Date().toISOString() }));
  page.on('requestfailed', (request) => failedRequests.push({ profile, url: request.url(), failure: request.failure()?.errorText || 'unknown' }));
  page.on('response', (response) => {
    const promise = (async () => {
      const headers = await response.allHeaders();
      const pathname = new URL(response.url()).pathname.replace(/^\//, '');
      network.push({ profile, url: response.url(), origin: new URL(response.url()).origin, path: pathname, status: response.status(), content_type: headers['content-type'] || null, content_length: Number(headers['content-length'] || 0), access_control_allow_origin: headers['access-control-allow-origin'] || null, cache_control: headers['cache-control'] || null, required: critical.has(pathname) });
    })();
    pendingEvents.push(promise);
  });
}

function failedRequiredRequestCount() {
  const unmatchedFailures = failedRequests.filter((item) => {
    const requestPath = new URL(item.url).pathname.replace(/^\//, '');
    return critical.has(requestPath) && !network.some((response) => response.profile === item.profile && response.url === item.url && response.status === 200);
  });
  return unmatchedFailures.length + network.filter((item) => item.required && item.status !== 200).length;
}

async function waitReady(page) {
  const start = performance.now();
  await page.waitForFunction(() => window.GF_WEB_RUNTIME_READY === true, null, { timeout: startupTimeout });
  return (performance.now() - start) / 1000;
}

async function canvasState(page) {
  return page.locator('#canvas').evaluate((canvas) => {
    const rect = canvas.getBoundingClientRect();
    const style = getComputedStyle(canvas);
    return { found: true, width: canvas.width, height: canvas.height, css_width: rect.width, css_height: rect.height, visible: style.visibility !== 'hidden' && style.display !== 'none' && rect.width > 0 && rect.height > 0 };
  });
}

async function canvasDigest(page) {
  const data = await page.locator('#canvas').evaluate((canvas) => canvas.toDataURL('image/png'));
  return { length: data.length, sha256: crypto.createHash('sha256').update(data).digest('hex') };
}

async function canvasVisualState(page) {
  return page.locator('#canvas').evaluate((canvas) => {
    const sample = document.createElement('canvas');
    sample.width = 64;
    sample.height = 64;
    const context = sample.getContext('2d', { willReadFrequently: true });
    context.drawImage(canvas, 0, 0, sample.width, sample.height);
    const pixels = context.getImageData(0, 0, sample.width, sample.height).data;
    const colors = new Set();
    let opaque = 0;
    let minLuminance = 255;
    let maxLuminance = 0;
    for (let index = 0; index < pixels.length; index += 4) {
      const red = pixels[index];
      const green = pixels[index + 1];
      const blue = pixels[index + 2];
      const alpha = pixels[index + 3];
      if (alpha > 0) opaque += 1;
      if (alpha > 0) {
        colors.add(`${red},${green},${blue},${alpha}`);
        const luminance = (red * 299 + green * 587 + blue * 114) / 1000;
        minLuminance = Math.min(minLuminance, luminance);
        maxLuminance = Math.max(maxLuminance, luminance);
      }
    }
    const pixelCount = pixels.length / 4;
    return {
      sample_width: sample.width,
      sample_height: sample.height,
      opaque_pixel_fraction: opaque / pixelCount,
      unique_rgba_count: colors.size,
      luminance_range: opaque > 0 ? maxLuminance - minLuminance : 0,
      passed: opaque / pixelCount > 0.95 && colors.size >= 2 && maxLuminance - minLuminance >= 8,
    };
  });
}

let result = {
  schema_version: '1', status: 'fail', browser: 'chromium', browser_version: null,
  playwright_version: JSON.parse(fs.readFileSync(new URL('../../node_modules/playwright/package.json', import.meta.url), 'utf8')).version,
  node_version: process.version, headless: true, launch_arguments: ['--disable-background-networking', `--${processMarker}`], url: null,
  final_url: null, server: null,
  viewport: desktopViewport, small_viewport: smallViewport, navigation_status: null, wasm_requested: false, wasm_status: null,
  runtime_ready: false, runtime_ready_seconds: null, canvas_found: false, canvas_width: 0, canvas_height: 0,
  rendering: null, keyboard_test: null, mouse_test: null, resize_test: null, small_viewport_test: null,
  console_error_count: 0, page_error_count: 0, failed_required_request_count: 0,
  screenshot: null, total_seconds: null, failure_reason: null, fault, cleanup: null,
  required_manifest_paths: [...critical.keys()], optional_manifest_paths: optionalAssets,
  hosting_profile: sourceHostingManifest?.hosting_profile || null, site_url: null, asset_url: null,
  cross_origin_required: sourceHostingManifest?.cross_origin_required || false, cors: null,
};

try {
  await startServer();
  const launchStart = performance.now();
  browser = await chromium.launch({ headless: true, args: ['--disable-background-networking', `--${processMarker}`] });
  timings.browser_launch_seconds = (performance.now() - launchStart) / 1000;
  browserVersion = browser.version();
  result.browser_version = browserVersion;
  result.url = url;
  result.site_url = siteOrigin || new URL(url).origin;
  result.asset_url = assetOrigin;
  result.server = { bind_address: '127.0.0.1', port: server.address().port, root: bundleRoot, asset_port: assetServer?.address()?.port || null, asset_root: finalizedHostingRoot ? path.join(finalizedHostingRoot, 'r2') : null };

  const context = await browser.newContext({ viewport: desktopViewport, serviceWorkers: 'block' });
  const page = await context.newPage();
  attachEvidence(page, 'desktop');
  if (fault === 'never_ready') await page.addInitScript(() => Object.defineProperty(window, 'GF_WEB_RUNTIME_READY', { configurable: false, get: () => false, set: () => {} }));
  const navStart = performance.now();
  const navigation = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: startupTimeout });
  timings.navigation_seconds = (performance.now() - navStart) / 1000;
  result.navigation_status = navigation?.status() ?? null;
  result.final_url = page.url();
  const readySeconds = await waitReady(page);
  timings.runtime_ready_seconds = readySeconds;
  result.runtime_ready = true;
  result.runtime_ready_seconds = readySeconds;

  if (fault === 'page_exception') await page.evaluate(() => setTimeout(() => { throw new Error('GF_WEB_CONTROLLED_PAGE_EXCEPTION'); }, 0));
  if (fault === 'console_error') await page.evaluate(() => console.error('GF_WEB_CONTROLLED_CONSOLE_ERROR'));
  if (fault === 'zero_canvas') await page.locator('#canvas').evaluate((canvas) => {
    canvas.width = 0; canvas.height = 0;
    canvas.style.setProperty('width', '0px', 'important');
    canvas.style.setProperty('height', '0px', 'important');
    canvas.style.setProperty('display', 'none', 'important');
  });
  if (fault === 'blank_canvas') await page.locator('#canvas').evaluate((canvas) => {
    const blank = document.createElement('canvas');
    blank.id = 'canvas';
    blank.width = canvas.width;
    blank.height = canvas.height;
    blank.style.cssText = canvas.style.cssText;
    canvas.replaceWith(blank);
  });
  await page.waitForTimeout(150);
  const beforeCanvas = await canvasState(page);
  const visualState = await canvasVisualState(page);
  const beforeDigest = await canvasDigest(page);
  result.canvas_found = beforeCanvas.found;
  result.canvas_width = beforeCanvas.width;
  result.canvas_height = beforeCanvas.height;
  result.rendering = { before: beforeDigest, visual: visualState, nonempty: beforeDigest.length > 1000 && visualState.passed, changed_after_input: false };
  if (!beforeCanvas.visible) throw new Error('canvas is missing, hidden, or zero-sized');
  if (!result.rendering.nonempty) throw new Error('canvas rendering is blank or transparent');

  const initialState = await page.evaluate(() => window.GF_WEB_RUNTIME_STATE);
  await page.locator('#canvas').click({ position: { x: Math.max(1, Math.min(50, beforeCanvas.css_width / 2)), y: Math.max(1, Math.min(50, beforeCanvas.css_height / 2)) } });
  await page.waitForFunction(() => window.GF_WEB_MOUSE_RECEIVED === true, null, { timeout: inputTimeout });
  const mouseState = await page.evaluate(() => ({ received: window.GF_WEB_MOUSE_RECEIVED, state: window.GF_WEB_RUNTIME_STATE }));
  result.mouse_test = { action: 'left_click_canvas', passed: mouseState.received === true, observed_state: mouseState.state };

  const inputStart = performance.now();
  await page.keyboard.press(fault === 'input_nonresponsive' ? 'KeyA' : 'Space');
  await page.waitForFunction(() => window.GF_WEB_KEYBOARD_RECEIVED === true && window.GF_WEB_RUNTIME_STATE === 'INPUT_RECEIVED', null, { timeout: inputTimeout });
  timings.input_response_seconds = (performance.now() - inputStart) / 1000;
  const finalState = await page.evaluate(() => window.GF_WEB_RUNTIME_STATE);
  result.keyboard_test = { action: fault === 'input_nonresponsive' ? 'KeyA' : 'Space', initial_state: initialState, expected_state: 'INPUT_RECEIVED', observed_state: finalState, passed: finalState === 'INPUT_RECEIVED', response_seconds: timings.input_response_seconds };
  await page.waitForTimeout(150);
  const afterDigest = await canvasDigest(page);
  result.rendering = { ...result.rendering, after: afterDigest, changed_after_input: beforeDigest.sha256 !== afterDigest.sha256 };

  const screenshotPath = path.join(artifactRoot, 'browser-runtime-ready.png');
  await page.screenshot({ path: screenshotPath, fullPage: true });
  result.screenshot = screenshotPath;
  await page.setViewportSize(resizeViewport);
  await page.waitForTimeout(100);
  const resized = await canvasState(page);
  result.resize_test = { viewport: resizeViewport, runtime_alive: await page.evaluate(() => window.GF_WEB_RUNTIME_READY === true), canvas: resized, passed: resized.visible };
  await context.close();

  const smallContext = await browser.newContext({ viewport: smallViewport, serviceWorkers: 'block' });
  const smallPage = await smallContext.newPage();
  attachEvidence(smallPage, 'small');
  const smallNav = await smallPage.goto(url, { waitUntil: 'domcontentloaded', timeout: startupTimeout });
  const smallReady = await waitReady(smallPage);
  const smallCanvas = await canvasState(smallPage);
  result.small_viewport_test = { viewport: smallViewport, navigation_status: smallNav?.status() ?? null, runtime_ready: true, runtime_ready_seconds: smallReady, canvas: smallCanvas, passed: smallCanvas.visible };
  await smallContext.close();
  await page?.waitForTimeout?.(0).catch(() => {});
  await Promise.allSettled(pendingEvents);

  const requiredNetwork = network.filter((item) => item.required);
  const wasmResponse = network.find((item) => wasmPaths.includes(item.path));
  result.wasm_requested = Boolean(wasmResponse);
  result.wasm_status = wasmResponse ? { path: wasmResponse.path, status: wasmResponse.status, content_type: wasmResponse.content_type, response_size: wasmResponse.content_length } : null;
  if (wasmResponse) result.wasm_status = { ...result.wasm_status, url: wasmResponse.url, origin: wasmResponse.origin, access_control_allow_origin: wasmResponse.access_control_allow_origin };
  result.console_error_count = consoleMessages.filter((item) => item.type === 'error').length;
  result.page_error_count = pageErrors.length;
  result.failed_required_request_count = failedRequiredRequestCount();

  const assertions = [
    [result.navigation_status === 200, 'entrypoint navigation failed'], [result.runtime_ready, 'runtime ready was not reached'],
    [result.wasm_requested && result.wasm_status?.status === 200, 'WASM request did not succeed'],
    [result.wasm_status?.content_type?.startsWith('application/wasm'), 'WASM MIME type is invalid'],
    [beforeCanvas.visible, 'canvas is missing, hidden, or zero-sized'], [result.rendering.nonempty && result.rendering.changed_after_input, 'canvas rendering proof failed'],
    [result.keyboard_test?.passed, 'keyboard input did not reach Godot'], [result.mouse_test?.passed, 'mouse input did not reach Godot'],
    [result.resize_test?.passed && result.resize_test?.runtime_alive, 'resize smoke failed'], [result.small_viewport_test?.passed, 'small viewport smoke failed'],
    [result.console_error_count === 0, 'unexpected console error'], [result.page_error_count === 0, 'uncaught page exception'],
    [result.failed_required_request_count === 0, 'required resource request failed'],
    [[...critical.keys()].every((requiredPath) => requiredNetwork.some((item) => item.path === requiredPath && item.status === 200)), 'not every critical manifest asset was requested successfully'],
  ];
  if (hostingMode && sourceHostingManifest.cross_origin_required) {
    const wasmOrigin = result.wasm_status?.origin;
    assertions.push([wasmOrigin === assetOrigin && wasmOrigin !== siteOrigin, 'WASM was not fetched from the configured asset origin']);
    assertions.push([result.wasm_status?.access_control_allow_origin === siteOrigin, 'asset CORS response did not allow the site origin']);
    result.cors = { required: true, site_origin: siteOrigin, asset_origin: assetOrigin, wasm_allow_origin: result.wasm_status?.access_control_allow_origin || null, passed: result.wasm_status?.access_control_allow_origin === siteOrigin };
  } else if (hostingMode) {
    result.cors = { required: false, passed: true };
  }
  const failed = assertions.find(([passed]) => !passed);
  if (failed) throw new Error(failed[1]);
  result.status = 'pass';
} catch (error) {
  result.status = 'fail';
  result.failure_reason = error instanceof Error ? error.message : String(error);
} finally {
  await Promise.allSettled(pendingEvents);
  const requiredNetwork = network.filter((item) => item.required);
  const wasmResponse = network.find((item) => wasmPaths.includes(item.path));
  result.wasm_requested = Boolean(wasmResponse);
  result.wasm_status = wasmResponse ? { path: wasmResponse.path, status: wasmResponse.status, content_type: wasmResponse.content_type, response_size: wasmResponse.content_length } : result.wasm_status;
  if (wasmResponse) result.wasm_status = { ...result.wasm_status, url: wasmResponse.url, origin: wasmResponse.origin, access_control_allow_origin: wasmResponse.access_control_allow_origin };
  result.failed_required_request_count = failedRequiredRequestCount();
  let browserCloseError = null;
  let serverCloseError = null;
  if (browser) {
    try { await browser.close(); browserClosed = true; } catch (error) { browserCloseError = error instanceof Error ? error.message : String(error); }
  }
  const remainingChromiumProcesses = await waitForChromiumExit();
  if (server) {
    try {
      await closeServer(server);
      if (fault === 'server_close_failure') throw new Error('GF_WEB_CONTROLLED_SERVER_CLOSE_FAILURE');
      serverClosed = true;
    } catch (error) { serverCloseError = error instanceof Error ? error.message : String(error); }
  }
  let assetServerCloseError = null;
  if (assetServer) {
    try { await hostingCloseServer(assetServer); assetServerClosed = true; } catch (error) { assetServerCloseError = error instanceof Error ? error.message : String(error); }
  }
  timings.total_seconds = (performance.now() - started) / 1000;
  result.total_seconds = timings.total_seconds;
  result.cleanup = { browser_closed: (browserClosed || browser === null) && remainingChromiumProcesses.length === 0, server_closed: (serverClosed || server === null) && (assetServerClosed || assetServer === null), site_server_closed: serverClosed || server === null, asset_server_closed: assetServerClosed || assetServer === null, browser_close_error: browserCloseError, server_close_error: serverCloseError, asset_server_close_error: assetServerCloseError, browser_processes_remaining: remainingChromiumProcesses };
  if (browserCloseError || serverCloseError || assetServerCloseError || remainingChromiumProcesses.length > 0) {
    result.status = 'fail';
    result.failure_reason = result.failure_reason || 'browser or server cleanup failed';
  }
  result.console_error_count = consoleMessages.filter((item) => item.type === 'error').length;
  result.page_error_count = pageErrors.length;
  fs.writeFileSync(path.join(artifactRoot, 'console.json'), `${JSON.stringify(consoleMessages, null, 2)}\n`);
  fs.writeFileSync(path.join(artifactRoot, 'page-errors.json'), `${JSON.stringify(pageErrors, null, 2)}\n`);
  fs.writeFileSync(path.join(artifactRoot, 'network.json'), `${JSON.stringify({ responses: network, failed_requests: failedRequests }, null, 2)}\n`);
  fs.writeFileSync(path.join(artifactRoot, 'timings.json'), `${JSON.stringify(timings, null, 2)}\n`);
  fs.writeFileSync(path.join(artifactRoot, 'browser-result.json'), `${JSON.stringify(result, null, 2)}\n`);
  console.log(JSON.stringify(result));
}
process.exit(result.status === 'pass' ? 0 : 1);
