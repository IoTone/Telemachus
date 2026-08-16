// Telemachus e2e feature tour — a plain Playwright script (no test runner) so it
// launches fast, logs each step live, and exits non-zero on any hard assertion
// failure. It drives the REAL UI against a running server (default 127.0.0.1:8080),
// captures a captioned screenshot per feature, and writes catalog/manifest.json.
//
// Structural checks are hard (fail the run); model-output waits are soft (a slow
// or absent model won't fail the tour, the screenshot is still captured).
//
//   BASE_URL=http://127.0.0.1:8080 node run-tour.mjs
import { chromium } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(HERE, 'catalog');
fs.mkdirSync(OUT, { recursive: true });
const BASE = process.env.BASE_URL || 'http://127.0.0.1:8080';
const MANIFEST = [];
const ERRORS = [];

const log = (m) => console.log(`[tour] ${m}`);
function assert(cond, msg) { if (!cond) { ERRORS.push(msg); console.error(`  ✗ ASSERT ${msg}`); } else console.log(`  ✓ ${msg}`); }
function withTimeout(p, ms, label) {
  let to; const guard = new Promise((_, rej) => { to = setTimeout(() => rej(new Error(`timeout:${label}`)), ms); });
  return Promise.race([p, guard]).finally(() => clearTimeout(to));
}
async function shot(page, id, title, caption) {
  await page.waitForTimeout(350);
  await page.screenshot({ path: path.join(OUT, `${id}.png`), fullPage: true });
  MANIFEST.push({ file: `${id}.png`, title, caption });
  log(`shot ${id}`);
}
async function go(page, tab, waitSel) {
  await page.evaluate((t) => window.go(t), tab);
  if (waitSel) await page.waitForSelector(waitSel, { timeout: 20000 });
  await page.waitForTimeout(300);
}
// soft: run a model-backed UI action, but never hang the tour on it
async function model(page, fn, label, ms = 45000) {
  try { await withTimeout(page.evaluate(fn), ms, label); log(`model ${label} done`); }
  catch (e) { console.warn(`  ~ ${label}: ${e.message} (continuing)`); }
}

const browser = await chromium.launch({ headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
try {
  // 1 — sign-in
  log('goto /'); await page.goto(BASE + '/', { waitUntil: 'domcontentloaded', timeout: 20000 });
  await page.waitForSelector('#lu', { timeout: 15000 });
  assert(await page.getByText('Sign in').first().isVisible(), 'login screen renders');
  await shot(page, '01-signin', 'Sign in',
    'The reference UI on first load — password + optional 2FA, an EN / 日本語 toggle, and a first-run path to create the initial operator.');

  // 2 — bootstrap the first operator
  log('bootstrap');
  await page.locator('summary', { hasText: 'First run' }).click();
  await page.fill('#bu', 'alice'); await page.fill('#bp', 's3cret');
  await shot(page, '02-bootstrap', 'First-run bootstrap',
    'Creating the first operator. Under RBAC-5 the first owner bootstraps as the instance operator — a distinct tier above team owners.');
  await page.evaluate(() => window.doBootstrap());
  await page.waitForSelector('nav.tabs', { timeout: 15000 });
  assert(await page.locator('nav.tabs').isVisible(), 'signed in — app shell visible');

  // 3 — streaming chat
  log('chat'); await go(page, 'chat', '#cp');
  await page.fill('#cp', 'In one sentence, what is Telemachus?');
  await model(page, () => window.doChat(), 'chat');
  assert((await page.locator('#chatlog .rep').first().innerText().catch(() => '')).length > 0, 'chat produced a reply');
  await shot(page, '03-chat', 'Streaming chat',
    'A token-streamed reply from the local model (qwen2.5:7b), admitted through the per-team concurrency governor and metered against AI quotas.');

  // 4 — agentic tool use
  log('agent'); await go(page, 'agent', '#ap');
  await page.fill('#ap', "Create a note titled 'Investor demo' with body 'Telemachus launch next week' using your tools.");
  await model(page, () => window.doAgent(), 'agent', 60000);
  await shot(page, '04-agent', 'Agentic tool use',
    'The agent plans, calls the create_note tool (🔧), receives the result, and answers — the same registry that also serves plugins, MCP, and sandboxed tools.');

  // 5 — notes
  log('notes'); await go(page, 'notes', '#nt');
  await shot(page, '05-notes', 'Notes',
    'The ownable/shareable resource behind RBAC — team / private / shared visibility. The "Investor demo" note here was created by the agent in the previous step.');

  // 6 — translation app (glossary + live EN→JA)
  log('translate'); await go(page, 'translate', '#trsrc');
  await page.fill('#glterm', 'platform'); await page.fill('#gltr', 'プラットフォーム'); await page.selectOption('#gltgt', 'ja');
  await page.evaluate(() => window.doAddTerm());
  await go(page, 'translate', '#trsrc');
  await page.fill('#trsrc', 'Welcome to Telemachus, the team AI platform.'); await page.selectOption('#trtgt', 'ja');
  await model(page, () => window.doTranslate(), 'translate');
  assert((await page.locator('#trout').innerText().catch(() => '')).length > 0, 'translation produced output');
  await shot(page, '06-translate', 'Translation app',
    'The first user-facing app: live EN→JA translation with a team glossary for consistent terminology and a metered history. The same engine translates whole locale catalogs (the localization dogfood).');

  // 7 — teams & RBAC
  log('team'); await go(page, 'team', '#mu');
  await page.fill('#mu', 'bob'); await page.fill('#mp', 'bobpw123'); await page.selectOption('#mr', 'member');
  await page.evaluate(() => window.doAddMember());
  await go(page, 'team', '#mu');
  assert(await page.getByText('bob').first().isVisible().catch(() => false), 'member bob added');
  await shot(page, '07-team', 'Teams & RBAC',
    'Members and roles (owner / admin / member / viewer). Every API call is authorized through the AuthzService; tokens are capped by issuer-permissions ∩ scopes.');

  // 8 — quotas + tool registry
  log('usage'); await go(page, 'usage', 'text=ai.tokens.total');
  assert(await page.getByText('mcp__mock__add').first().isVisible().catch(() => false), 'MCP tool listed');
  assert(await page.getByText('oop__notes-helper__save_idea').first().isVisible().catch(() => false), 'sandboxed tool listed');
  await shot(page, '08-usage', 'Quotas & tool registry',
    'Windowed usage vs. limits, and every agent tool with a source badge: built-in, 🔌 plugin, mcp:mock (external MCP server), and 🛡️ oop:notes-helper (sandboxed out-of-process, with declared scopes).');

  // 9 — admin + federated compute
  log('admin'); await go(page, 'admin', 'text=Compute');
  assert(await page.getByText('gpu-sim').first().isVisible().catch(() => false), 'federated executor listed');
  await shot(page, '09-admin', 'Admin & federated compute',
    'Operator-only instance view. The Compute table lists the local node (qwen2.5:7b) and federated executors (🛰️ gpu-sim) — the pluggable seam for remote/HPC compute.');

  // 10 — localization
  log('i18n'); await page.evaluate(() => { window.setLang('ja'); window.go('chat'); });
  await page.waitForTimeout(700);
  assert((await page.locator('nav.tabs').innerText()).includes('チャット'), 'UI switches to Japanese');
  await shot(page, '10-i18n', 'Localized top to bottom',
    'One toggle re-renders the entire UI in Japanese (ICU MessageFormat catalogs, fallback chain, source-hash staleness) — localization is a core piece, not an afterthought.');
} catch (e) {
  ERRORS.push(`fatal: ${e.message}`);
  console.error('FATAL', e);
} finally {
  fs.writeFileSync(path.join(OUT, 'manifest.json'), JSON.stringify(MANIFEST, null, 2));
  await browser.close();
}

console.log(`\n[tour] ${MANIFEST.length} screenshots, ${ERRORS.length} failure(s)`);
if (ERRORS.length) { ERRORS.forEach((e) => console.error(' - ' + e)); process.exit(1); }
