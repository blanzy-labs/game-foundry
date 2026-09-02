#!/usr/bin/env node

import { chromium } from 'playwright';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { performance } from 'node:perf_hooks';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createStaticServer, listen, closeServer } from './hosting-server.mjs';

const args = process.argv.slice(2);
const option = (name) => {
  const index = args.indexOf(name);
  if (index < 0 || !args[index + 1]) throw new Error(`${name} is required`);
  return args[index + 1];
};
const release = path.resolve(option('--hosting-release'));
const artifact = path.resolve(option('--artifact'));
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const sourceHostingManifest = JSON.parse(fs.readFileSync(path.join(release, 'hosting-manifest.json'), 'utf8'));
const sourceManifest = JSON.parse(fs.readFileSync(path.join(release, sourceHostingManifest.source_web_manifest), 'utf8'));
const finalized = path.join(artifact, 'finalized-local');
const finalizedManifestPath = path.join(finalized, 'hosting-manifest.json');
const timeoutMs = 15000;
const started = performance.now();
const processMarker = `gf-web-004-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
fs.mkdirSync(artifact, { recursive: true });

let siteOrigin = null;
let assetOrigin = null;
let browser = null;
let siteServer = null;
let assetServer = null;
const consoleMessages = [];
const pageErrors = [];
const network = [];

const result = {
  slice: 'GF-WEB-004',
  game_id: 'cyber-shield',
  status: 'fail',
  failure_reason: null,
  browser: 'chromium',
  browser_version: null,
  playwright_version: JSON.parse(fs.readFileSync(new URL('../../node_modules/playwright/package.json', import.meta.url), 'utf8')).version,
  hosting_profile: sourceHostingManifest.hosting_profile,
  url: null,
  site_origin: null,
  asset_origin: null,
  runtime_ready: false,
  initial_state: null,
  keyboard_movement: null,
  mouse_movement: null,
  touch_control: null,
  threat_spawn_and_fall: null,
  blocked_threat: null,
  game_over: null,
  spawn_stop: null,
  restart: null,
  wasm: null,
  console_error_count: 0,
  page_error_count: 0,
  screenshots: {},
  cleanup: null,
  total_seconds: null,
};

function run(command, commandArgs) {
  const runResult = spawnSync(command, commandArgs, { encoding: 'utf8' });
  if (runResult.status !== 0) throw new Error(`${path.basename(command)} failed: ${runResult.stderr || runResult.stdout}`.trim());
}

function chromiumProcessIds() {
  if (!fs.existsSync('/proc')) return [];
  const ids = [];
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      if (fs.readFileSync(`/proc/${entry}/cmdline`, 'utf8').includes(processMarker)) ids.push(Number(entry));
    } catch {}
  }
  return ids;
}

async function snapshot(page) {
  return page.evaluate(() => window.CYBER_SHIELD_STATE);
}

async function waitSnapshot(page, predicate) {
  await page.waitForFunction(predicate, null, { timeout: timeoutMs });
  return snapshot(page);
}

function attachEvidence(page) {
  page.on('console', (message) => consoleMessages.push({ type: message.type(), text: message.text(), timestamp: new Date().toISOString() }));
  page.on('pageerror', (error) => pageErrors.push({ message: error.message, stack: error.stack || null, timestamp: new Date().toISOString() }));
  page.on('response', async (response) => {
    try {
      const headers = await response.allHeaders();
      network.push({
        url: response.url(),
        path: new URL(response.url()).pathname.replace(/^\//, ''),
        origin: new URL(response.url()).origin,
        status: response.status(),
        content_type: headers['content-type'] || null,
        content_length: Number(headers['content-length'] || 0),
        access_control_allow_origin: headers['access-control-allow-origin'] || null,
      });
    } catch {}
  });
}

try {
  siteServer = createStaticServer({ root: path.join(finalized, 'pages'), kind: 'site', manifestPath: finalizedManifestPath });
  assetServer = sourceHostingManifest.cross_origin_required
    ? createStaticServer({ root: path.join(finalized, 'r2'), kind: 'assets', manifestPath: finalizedManifestPath, corsOrigin: () => siteOrigin })
    : null;
  siteOrigin = `http://127.0.0.1:${await listen(siteServer)}`;
  if (assetServer) assetOrigin = `http://127.0.0.1:${await listen(assetServer)}`;
  const finalizeArgs = ['--site-origin', siteOrigin];
  if (assetOrigin) finalizeArgs.push('--asset-origin', assetOrigin);
  finalizeArgs.push(release, finalized);
  run(path.join(repoRoot, 'scripts/gf-web-hosting-finalize.sh'), finalizeArgs);

  const url = `${siteOrigin}${sourceHostingManifest.site_route}?gf_test=1`;
  result.url = url;
  result.site_origin = siteOrigin;
  result.asset_origin = assetOrigin;
  browser = await chromium.launch({ headless: true, args: ['--disable-background-networking', `--${processMarker}`] });
  result.browser_version = browser.version();
  const context = await browser.newContext({ viewport: { width: 1280, height: 720 }, hasTouch: true, serviceWorkers: 'block' });
  const page = await context.newPage();
  attachEvidence(page);
  const navigation = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: timeoutMs });
  if (navigation?.status() !== 200) throw new Error(`entrypoint returned HTTP ${navigation?.status()}`);
  const initial = await waitSnapshot(page, () => window.GF_WEB_RUNTIME_READY === true && window.CYBER_SHIELD_STATE?.test_mode === true);
  result.runtime_ready = true;
  result.initial_state = initial;
  if (initial.state !== 'PLAYING' || initial.score !== 0 || initial.breaches !== 0) throw new Error('initial gameplay state is invalid');
  const readyScreenshot = path.join(artifact, 'cyber-shield-ready.png');
  await page.screenshot({ path: readyScreenshot, fullPage: true });
  result.screenshots.ready = readyScreenshot;

  const canvas = page.locator('#canvas');
  const box = await canvas.boundingBox();
  if (!box || box.width <= 0 || box.height <= 0) throw new Error('Godot canvas is not visible');
  await canvas.click({ position: { x: box.width / 2, y: box.height / 2 } });
  const keyboardBefore = (await snapshot(page)).paddle_x;
  await page.keyboard.down('ArrowLeft');
  await page.waitForTimeout(240);
  await page.keyboard.up('ArrowLeft');
  const keyboardAfter = await waitSnapshot(page, () => window.CYBER_SHIELD_STATE?.keyboard_received === true && window.CYBER_SHIELD_STATE.paddle_x < 380);
  result.keyboard_movement = { action: 'ArrowLeft', before_x: keyboardBefore, after_x: keyboardAfter.paddle_x, passed: keyboardAfter.paddle_x < keyboardBefore };

  await page.mouse.move(box.x + box.width * 0.82, box.y + box.height * 0.72);
  const mouseAfter = await waitSnapshot(page, () => window.CYBER_SHIELD_STATE?.mouse_received === true && window.CYBER_SHIELD_STATE.paddle_x > 600);
  result.mouse_movement = { target_fraction_x: 0.82, after_x: mouseAfter.paddle_x, passed: mouseAfter.mouse_received === true && mouseAfter.paddle_x > keyboardAfter.paddle_x };

  await page.touchscreen.tap(box.x + box.width * 0.24, box.y + box.height * 0.72);
  const touchAfter = await waitSnapshot(page, () => window.CYBER_SHIELD_STATE?.touch_received === true && window.CYBER_SHIELD_STATE.paddle_x < 300);
  result.touch_control = { target_fraction_x: 0.24, after_x: touchAfter.paddle_x, passed: touchAfter.touch_received === true };

  await page.keyboard.press('s');
  await page.keyboard.press('s');
  const spawned = await waitSnapshot(page, () => window.CYBER_SHIELD_STATE?.active_threats === 2);
  const firstY = spawned.threats[0].y;
  await page.waitForTimeout(300);
  const falling = await snapshot(page);
  result.threat_spawn_and_fall = {
    spawn_count: spawned.spawn_count,
    labels: spawned.threats.map((threat) => threat.label),
    first_y_before: firstY,
    first_y_after: falling.threats[0].y,
    passed: spawned.active_threats === 2 && falling.threats[0].y > firstY,
  };
  if (!result.threat_spawn_and_fall.passed) throw new Error('controlled threats did not spawn and fall');

  await page.keyboard.press('b');
  const blocked = await waitSnapshot(page, () => window.CYBER_SHIELD_STATE?.score === 1);
  result.blocked_threat = { action: 'test-mode B gameplay input', score: blocked.score, breaches: blocked.breaches, passed: blocked.score === 1 && blocked.breaches === 0 };
  const blockedScreenshot = path.join(artifact, 'cyber-shield-gameplay.png');
  await page.screenshot({ path: blockedScreenshot, fullPage: true });
  result.screenshots.gameplay = blockedScreenshot;

  await page.keyboard.press('m');
  await waitSnapshot(page, () => window.CYBER_SHIELD_STATE?.breaches === 1);
  await page.keyboard.press('m');
  await waitSnapshot(page, () => window.CYBER_SHIELD_STATE?.breaches === 2);
  await page.keyboard.press('m');
  const gameOver = await waitSnapshot(page, () => window.CYBER_SHIELD_STATE?.state === 'GAME_OVER');
  result.game_over = { score: gameOver.score, breaches: gameOver.breaches, state: gameOver.state, active_threats: gameOver.active_threats, passed: gameOver.score === 1 && gameOver.breaches === 3 && gameOver.active_threats === 0 };
  const gameOverScreenshot = path.join(artifact, 'cyber-shield-game-over.png');
  await page.screenshot({ path: gameOverScreenshot, fullPage: true });
  result.screenshots.game_over = gameOverScreenshot;

  const stoppedCount = gameOver.spawn_count;
  await page.keyboard.press('s');
  await page.waitForTimeout(250);
  const stopped = await snapshot(page);
  result.spawn_stop = { before_spawn_count: stoppedCount, after_spawn_count: stopped.spawn_count, active_threats: stopped.active_threats, passed: stopped.spawn_count === stoppedCount && stopped.active_threats === 0 };

  await page.keyboard.press('r');
  const restarted = await waitSnapshot(page, () => window.CYBER_SHIELD_STATE?.state === 'PLAYING' && window.CYBER_SHIELD_STATE?.breaches === 0);
  result.restart = { state: restarted.state, score: restarted.score, breaches: restarted.breaches, active_threats: restarted.active_threats, spawn_count: restarted.spawn_count, passed: restarted.score === 0 && restarted.breaches === 0 && restarted.active_threats === 0 && restarted.spawn_count === 0 };

  await page.waitForTimeout(300);
  const sourceWasm = sourceManifest.files.find((file) => file.content_role === 'wasm');
  const hostingWasm = sourceHostingManifest.files.find((file) => file.original_path === sourceWasm?.path);
  const wasmResponse = network.find((response) => response.path === hostingWasm?.deployment_path);
  result.wasm = wasmResponse ? {
    ...wasmResponse,
    passed: wasmResponse.status === 200 && wasmResponse.content_type?.startsWith('application/wasm') && (!assetOrigin || (wasmResponse.origin === assetOrigin && wasmResponse.access_control_allow_origin === siteOrigin)),
  } : null;
  result.console_error_count = consoleMessages.filter((message) => message.type === 'error').length;
  result.page_error_count = pageErrors.length;
  const gameplayChecks = [result.keyboard_movement, result.mouse_movement, result.touch_control, result.threat_spawn_and_fall, result.blocked_threat, result.game_over, result.spawn_stop, result.restart, result.wasm];
  if (gameplayChecks.some((check) => !check?.passed)) throw new Error('one or more gameplay/browser assertions failed');
  if (result.console_error_count !== 0 || result.page_error_count !== 0) throw new Error('browser console or page errors occurred');
  result.status = 'pass';
  await context.close();
} catch (error) {
  result.status = 'fail';
  result.failure_reason = error instanceof Error ? error.message : String(error);
} finally {
  let browserClosed = browser === null;
  let siteClosed = siteServer === null;
  let assetClosed = assetServer === null;
  if (browser) {
    try { await browser.close(); browserClosed = true; } catch {}
  }
  await new Promise((resolve) => setTimeout(resolve, 100));
  try { await closeServer(siteServer); siteClosed = true; } catch {}
  try { await closeServer(assetServer); assetClosed = true; } catch {}
  const remaining = chromiumProcessIds();
  result.console_error_count = consoleMessages.filter((message) => message.type === 'error').length;
  result.page_error_count = pageErrors.length;
  result.cleanup = { browser_closed: browserClosed && remaining.length === 0, site_server_closed: siteClosed, asset_server_closed: assetClosed, browser_processes_remaining: remaining };
  if (!result.cleanup.browser_closed || !siteClosed || !assetClosed) {
    result.status = 'fail';
    result.failure_reason ||= 'browser or server cleanup failed';
  }
  result.total_seconds = (performance.now() - started) / 1000;
  fs.writeFileSync(path.join(artifact, 'console.json'), `${JSON.stringify(consoleMessages, null, 2)}\n`);
  fs.writeFileSync(path.join(artifact, 'page-errors.json'), `${JSON.stringify(pageErrors, null, 2)}\n`);
  fs.writeFileSync(path.join(artifact, 'network.json'), `${JSON.stringify(network, null, 2)}\n`);
  fs.writeFileSync(path.join(artifact, 'browser-result.json'), `${JSON.stringify(result, null, 2)}\n`);
  console.log(JSON.stringify(result));
}

process.exit(result.status === 'pass' ? 0 : 1);
