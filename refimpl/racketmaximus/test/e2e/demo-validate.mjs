// demo-validate.mjs — drive the demo top to bottom and ASSERT.
//
// This is not a screenshot tour. The tours (beta-tour, run-tour, workflow-tour)
// exist to produce pictures and will happily photograph a broken page. This job
// exercises the same product and fails loudly, so it can gate a deploy.
//
// It watches three things at once:
//   1. explicit assertions, per flow, below
//   2. any uncaught page error or console error — a silent JS exception is a
//      broken console even when the assertions happen to pass
//   3. any 5xx from any request the page makes
//
// (3) is the shape of the bug this file was written for: a document write
// returned 500 from `make-directory: ... Permission denied` under the Nix store,
// because the blob root was a relative path resolved at request time against the
// web server's own web root. Everything looked fine until a write.
//
// Note honestly: `validate.sh` gives this job an ABSOLUTE temp data dir for
// isolation, which is already safe, so it cannot reproduce THAT root cause. The
// unit assertion in test/repo-tests.rkt and the boot guard in server/main.rkt
// cover it. What this job does cover is the symptom class: any write path that
// 500s under a live request, in any flow below.
//
//   BASE_URL   default http://127.0.0.1:8835
//   OUT_DIR    where failure screenshots land (default ./catalog/validate)
//
// Exit code is the number of failed checks, so `bash validate.sh` is a gate.

import { chromium } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const BASE = process.env.BASE_URL || 'http://127.0.0.1:8835';
const OUT = process.env.OUT_DIR || path.join(HERE, 'catalog', 'validate');
fs.mkdirSync(OUT, { recursive: true });

const USER = 'demo-validator';
const PASS = 'validate-me-9';

// ── tiny harness ─────────────────────────────────────────────────────────────
let pass = 0;
const failures = [];
let currentStep = 'startup';
function ok(name, cond, detail) {
  if (cond) { pass++; console.log(`  ok   ${name}`); }
  else { failures.push({ step: currentStep, name, detail }); console.log(`  FAIL ${name}${detail ? ' — ' + detail : ''}`); }
  return !!cond;
}
function eq(name, actual, expected) {
  return ok(name, actual === expected, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
function step(n) { currentStep = n; console.log(`\n▸ ${n}`); }

const pageErrors = [];
const httpErrors = [];

async function shot(page, id) {
  try { await page.screenshot({ path: path.join(OUT, `${id}.png`), fullPage: true }); } catch {}
}

// Wait until a predicate evaluated in the page becomes true.
async function until(page, fn, { timeout = 15000, label = 'condition' } = {}) {
  const t0 = Date.now();
  for (;;) {
    let v = false;
    try { v = await page.evaluate(fn); } catch {}
    if (v) return true;
    if (Date.now() - t0 > timeout) return false;
    await page.waitForTimeout(150);
  }
}

// Call the JSON API with the console's own token — used where the check is about
// bytes or persistence rather than about the widget.
async function apiCall(page, pathname, init = {}) {
  return page.evaluate(async ([p, i]) => {
    const tok = localStorage.getItem('tmx_token');
    const res = await fetch(p, {
      method: i.method || 'GET',
      headers: Object.assign({ 'Content-Type': 'application/json' }, tok ? { Authorization: 'Bearer ' + tok } : {}),
      body: i.body ? JSON.stringify(i.body) : undefined
    });
    let json = null; try { json = await res.json(); } catch {}
    return { status: res.status, ok: res.ok, json };
  }, [pathname, init]);
}

const browser = await chromium.launch({ headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } });

page.on('pageerror', e => pageErrors.push(String(e)));
page.on('console', m => { if (m.type() === 'error') pageErrors.push('console: ' + m.text()); });
page.on('response', r => { if (r.status() >= 500) httpErrors.push(`${r.status()} ${r.request().method()} ${r.url()}`); });

try {
  // ── 1. the server is up and the sign-in screen renders the shipped brand ────
  step('sign-in screen and default branding');
  await page.goto(BASE + '/login', { waitUntil: 'networkidle', timeout: 30000 });
  await page.waitForSelector('#lu', { timeout: 20000 });
  ok('sign-in form present', await page.locator('#lu').count() === 1);
  ok('Mentor mark rendered', await page.locator('h1.brand svg.tmx-mark').count() === 1);
  ok('wordmark reads Telemachus', (await page.locator('h1.brand').innerText()).includes('Telemachus'));
  eq('browser title is the brand', await page.title(), 'Telemachus');
  const brandApi = await apiCall(page, '/api/branding');
  ok('GET /api/branding is public (no token yet)', brandApi.ok, `status ${brandApi.status}`);
  eq('default branding title', brandApi.json && brandApi.json.title, 'Telemachus');

  // ── 2. first run: bootstrap the operator ────────────────────────────────────
  step('first-run bootstrap');
  await page.click('summary:has-text("First run")');
  await page.fill('#bu', USER);
  await page.fill('#bp', PASS);
  await page.evaluate(() => window.doBootstrap());
  const shell = await until(page, () => !!document.querySelector('nav.tabs'), { timeout: 25000 });
  ok('console shell rendered after bootstrap', shell);
  if (!shell) throw new Error('bootstrap did not reach the console');
  const tabs = await page.locator('nav.tabs button').allInnerTexts();
  ok('core tabs present', ['Notes', 'Documents', 'Repository', 'Admin'].every(x => tabs.includes(x)), tabs.join(','));

  // ── 3. notes ────────────────────────────────────────────────────────────────
  step('notes: create');
  await page.evaluate(() => window.go('notes'));
  await page.waitForSelector('#nt', { timeout: 10000 });
  await page.fill('#nt', 'Validator note');
  await page.fill('#nb', 'created by demo-validate');
  await page.evaluate(() => window.doCreateNote());
  ok('note appears in the list',
    await until(page, () => document.body.innerText.includes('Validator note')));

  // ── 4. documents: create, then EDIT — the write path that was broken ────────
  step('documents: create and edit');
  await page.evaluate(() => window.go('documents'));
  await page.waitForSelector('#dt', { timeout: 10000 });
  await page.fill('#dt', 'Validator doc');
  await page.fill('#dc', 'ORIGINAL body from demo-validate');
  await page.evaluate(() => window.doCreateDoc());
  ok('document appears in the list',
    await until(page, () => document.body.innerText.includes('Validator doc')));

  const list = await apiCall(page, '/api/documents');
  const docs = (list.json && (list.json.documents || list.json.items || list.json)) || [];
  const doc = (Array.isArray(docs) ? docs : []).find(d => d && d.title === 'Validator doc');
  ok('document is retrievable over the API', !!doc);

  if (doc) {
    // The reported failure: this returned 500 with a Permission denied mkdir
    // inside the read-only Nix store.
    const edit = await apiCall(page, '/api/documents/' + doc.id, {
      method: 'PUT',
      body: { title: 'Validator doc', content: 'EDITED body from demo-validate', visibility: 'team' }
    });
    ok('document EDIT succeeds (blob write under a live request)', edit.ok,
      `status ${edit.status} ${JSON.stringify(edit.json && edit.json.error || '')}`);
    const after = await apiCall(page, '/api/documents/' + doc.id);
    eq('edited content persisted', after.json && after.json.content, 'EDITED body from demo-validate');
  }

  // ── 5. repository: upload a binary, get the same bytes back ─────────────────
  step('repository: upload and byte-identical download');
  await page.evaluate(() => window.go('repository'));
  await page.waitForSelector('#rfile', { timeout: 10000 });
  // a small PNG, so this is a real binary round-trip and not a text one
  const pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAIAQMAAAD+wSzIAAAABlBMVEX///+/v7+jQ3Y5AAAADklEQVQI12P4AIX8EAgALgAD/aNpbtEAAAAASUVORK5CYII=';
  await page.setInputFiles('#rfile', {
    name: 'validator.png', mimeType: 'image/png', buffer: Buffer.from(pngB64, 'base64')
  });
  await page.evaluate(() => window.repoUpload());
  ok('uploaded object appears in the repository',
    await until(page, () => document.body.innerText.includes('validator.png'), { timeout: 20000 }));

  const roundTrip = await page.evaluate(async (expected) => {
    const tok = localStorage.getItem('tmx_token');
    const h = { Authorization: 'Bearer ' + tok };
    const l = await (await fetch('/api/repo?limit=50', { headers: h })).json();
    const items = l.objects || l.items || [];
    const o = items.find(x => (x.key || '').includes('validator.png'));
    if (!o) return { found: false };
    const buf = new Uint8Array(await (await fetch('/api/repo-obj/' + o.id + '/content', { headers: h })).arrayBuffer());
    let bin = ''; buf.forEach(b => bin += String.fromCharCode(b));
    return { found: true, same: btoa(bin) === expected, size: buf.length };
  }, pngB64);
  ok('object listed via the API', roundTrip.found);
  if (roundTrip.found) ok('download is byte-identical to the upload', roundTrip.same, `got ${roundTrip.size} bytes`);

  // ── 6. search reaches document content ──────────────────────────────────────
  step('search');
  await page.evaluate(() => window.go('search'));
  await page.waitForSelector('#sq', { timeout: 10000 });
  await page.fill('#sq', 'demo-validate');
  await page.evaluate(() => window.doSearch());
  ok('search returns the seeded content',
    await until(page, () => {
      const el = document.getElementById('sres');
      return !!el && /Validator (doc|note)/.test(el.innerText);
    }, { timeout: 15000 }));

  // ── 7. the remaining tabs render at all ─────────────────────────────────────
  step('workflows, jobs, usage render');
  for (const tab of ['workflows', 'jobs', 'usage']) {
    const before = pageErrors.length;
    await page.evaluate(t => window.go(t), tab);
    await page.waitForTimeout(700);
    ok(`${tab} tab renders without a page error`, pageErrors.length === before,
      pageErrors.slice(before).join(' | '));
  }

  // ── 8. Admin › Branding — the new tool, round-tripped through the UI ────────
  step('admin: branding');
  await page.evaluate(() => window.go('admin'));
  await page.waitForSelector('#brt', { timeout: 15000 });
  ok('branding card present in Admin', await page.locator('#brt').count() === 1);

  await page.fill('#brt', 'Ithaca Labs');
  await page.fill('#brg', 'Private AI for one team');
  await page.evaluate(() => window.doBrandSave());
  ok('header shows the new title',
    await until(page, () => (document.querySelector('header.top .brand') || {}).innerText?.includes('Ithaca Labs')));
  eq('browser tab title follows branding', await page.title(), 'Ithaca Labs');

  // the tagline is what an unauthenticated visitor sees, so check it there
  const pub = await apiCall(page, '/api/branding');
  eq('branding readable publicly after save', pub.json && pub.json.tagline, 'Private AI for one team');

  // logo upload replaces the mark
  await page.setInputFiles('#brf', {
    name: 'logo.png', mimeType: 'image/png', buffer: Buffer.from(pngB64, 'base64')
  });
  ok('uploaded logo replaces the mark in the header',
    await until(page, () => !!document.querySelector('header.top .brand img.tmx-logo'), { timeout: 15000 }));

  // reset puts the shipped identity back
  await page.evaluate(() => window.go('admin'));
  await page.waitForSelector('#brt', { timeout: 10000 });
  await page.evaluate(() => window.doBrandReset());
  ok('reset restores the Mentor mark',
    await until(page, () => {
      const b = document.querySelector('header.top .brand');
      return !!b && !!b.querySelector('svg.tmx-mark') && b.innerText.includes('Telemachus');
    }, { timeout: 15000 }));
  eq('reset restores the browser title', await page.title(), 'Telemachus');

  // ── 9. sign out and back in ─────────────────────────────────────────────────
  step('sign out and sign back in');
  await page.evaluate(() => window.logout());
  ok('signed out to the sign-in screen',
    await until(page, () => !!document.querySelector('#lu')));
  await page.fill('#lu', USER);
  await page.fill('#lp', PASS);
  await page.evaluate(() => window.doLogin());
  ok('signed back in', await until(page, () => !!document.querySelector('nav.tabs'), { timeout: 20000 }));

  // ── 10. nothing blew up along the way ───────────────────────────────────────
  step('no errors anywhere in the run');
  ok('no uncaught page/console errors', pageErrors.length === 0, pageErrors.slice(0, 5).join(' | '));
  ok('no 5xx responses', httpErrors.length === 0, httpErrors.slice(0, 5).join(' | '));

} catch (e) {
  failures.push({ step: currentStep, name: 'unexpected exception', detail: String(e && e.stack || e) });
  console.log('\nEXCEPTION during: ' + currentStep + '\n' + (e && e.stack || e));
  await shot(page, 'exception');
} finally {
  if (failures.length) await shot(page, 'final-state');
  await browser.close();
}

console.log(`\n${'─'.repeat(60)}`);
console.log(`demo-validate: ${pass} passed, ${failures.length} failed`);
for (const f of failures) console.log(`  ✗ [${f.step}] ${f.name}${f.detail ? '\n      ' + f.detail : ''}`);
if (failures.length) console.log(`\nscreenshots: ${OUT}`);
console.log(failures.length ? 'demo-validate: FAIL' : 'demo-validate: PASS');
process.exit(failures.length ? 1 : 0);
