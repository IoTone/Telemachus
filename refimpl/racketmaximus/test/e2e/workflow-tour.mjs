// Workflow engine walkthrough — drives the console's Workflows tab against a running
// server, capturing a definition shipped by a plugin, a run in flight, a completed
// run with its map fan-out, and a deliberately failed run. Shots + captions land in
// catalog/workflow/.  BASE_URL defaults to 127.0.0.1:8835.
//
// A real model makes the translation steps meaningful; without TELEMACHUS_MODEL_URL
// the server's simulated echo still exercises every step, so the tour passes on CI.
import { chromium } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(HERE, 'catalog', 'workflow');
fs.mkdirSync(OUT, { recursive: true });
const BASE = process.env.BASE_URL || 'http://127.0.0.1:8835';
const SLUG = process.env.WF_SLUG || 'translate-chat';
const MAN = [];
async function shot(page, id, title, caption) {
  await page.waitForTimeout(350);
  await page.screenshot({ path: path.join(OUT, `${id}.png`), fullPage: true });
  MAN.push({ file: `${id}.png`, title, caption });
  console.log('shot', id);
}
// poll the badge the run header renders, not a fixed sleep — a step's duration is
// the model's, not ours
async function settle(page, timeoutMs = 180000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const s = await page.$eval('.card .badge', e => e.textContent).catch(() => '?');
    if (s === 'done' || s === 'error' || s === 'canceled') return s;
    await page.waitForTimeout(1200);
  }
  throw new Error('run did not settle within ' + timeoutMs + 'ms');
}

const browser = await chromium.launch({ headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
const page = await browser.newPage({ viewport: { width: 1280, height: 950 } });
try {
  // ── sign in (bootstrap the operator on a fresh instance) ────────────────────
  await page.goto(BASE + '/', { waitUntil: 'networkidle', timeout: 20000 });
  await page.waitForSelector('#lu', { timeout: 15000 });
  await page.fill('#lu', 'alice'); await page.fill('#lp', 's3cret');
  await page.evaluate(() => window.doLogin());
  const ok = await page.waitForSelector('nav.tabs', { timeout: 8000 }).catch(() => null);
  if (!ok) {                                   // fresh DB — no operator yet
    await page.click('summary:has-text("First run")');
    await page.fill('#bu', 'alice'); await page.fill('#bp', 's3cret');
    await page.evaluate(() => window.doBootstrap());
    await page.waitForSelector('nav.tabs', { timeout: 15000 });
  }

  // ── 1. the definitions a team can run ───────────────────────────────────────
  await page.click('nav.tabs button[data-tab="workflows"]');
  await page.waitForSelector('h2:has-text("Workflows")', { timeout: 10000 });
  await page.waitForTimeout(400);
  await shot(page, '01-definitions', 'Workflows a team can run',
    'Every definition the team can reach, whatever authored it. This one arrived from a plugin: `define-workflow` emitted a spec, and the spec was materialized into the team on first lookup — the source badge says so. A spec POSTed to /api/workflows lands in the same table and is validated by the same code, because the spec is the contract.');

  // ── 2. the run form is generated from the spec's own input map ──────────────
  await page.click('table button:has-text("Run")');
  await page.waitForSelector('#wfi_0', { timeout: 10000 });
  await page.fill('#wfi_0', 'The quarterly report is ready for review.');
  await shot(page, '02-run-form', 'The form is the spec',
    "Fields are generated from the spec's `input` declaration — the same declaration the server enforces before a run starts, so the form cannot drift from what is accepted. Under the name: the step chain, in document order.");

  // ── 3. in flight ────────────────────────────────────────────────────────────
  await page.click('.card button.btn:not(.ghost):not(.sm):has-text("Run")');
  await page.waitForSelector('h2:has-text("' + SLUG + '")', { timeout: 15000 });
  await page.waitForTimeout(1500);
  await shot(page, '03-in-flight', 'A run in flight',
    'Each step is a scheduler job, and each step row is the run\'s state — nothing lives in memory, so a run survives a restart and the console can simply poll. Cancel marks the run; the pending step no-ops when it is claimed (cancelable, not preemptible).');

  // ── 4. completed, with the map fan-out ──────────────────────────────────────
  const st = await settle(page);
  await page.waitForTimeout(600);
  await shot(page, '04-completed', 'Completed — including the fan-out',
    'A `map` step fans one template over a list; its children are the indented rows, one per item, each retried on its own. The parent collects them into `{results: [...]}` — which is what the next step binds to. Final status: ' + st + '.');

  // ── 5. a failed run: the engine stops the whole run ─────────────────────────
  await page.evaluate(() => window.api('/api/tools/translate_text', { method: 'POST', body: { enabled: false } }));
  await page.evaluate(() => window.wfBack());
  await page.waitForSelector('table button:has-text("Run")', { timeout: 10000 });
  await page.click('table button:has-text("Run")');
  await page.waitForSelector('#wfi_0', { timeout: 10000 });
  await page.fill('#wfi_0', 'This message never makes it past step two.');
  await page.click('.card button.btn:not(.ghost):not(.sm):has-text("Run")');
  await page.waitForSelector('h2:has-text("' + SLUG + '")', { timeout: 15000 });
  await settle(page);
  await page.waitForTimeout(600);
  await shot(page, '05-failed', 'A step fails, the run stops',
    'The tool was disabled mid-tour to force a failure. The step exhausts its retries, then the run itself goes to error carrying which step failed and why — siblings that had not started stay queued rather than running on. Permission, quota, and the org gate are re-checked per step, so a run can never do what its starter could not.');
  await page.evaluate(() => window.api('/api/tools/translate_text', { method: 'POST', body: { enabled: true } }));
} finally {
  fs.writeFileSync(path.join(OUT, 'manifest.json'), JSON.stringify(MAN, null, 2));
  await browser.close();
}
console.log(`workflow walkthrough: ${MAN.length} shots`);
