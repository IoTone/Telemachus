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

// Against a fresh server this bootstraps the first operator. Against a LIVE box
// that already has one, bootstrap is not available — set VALIDATE_USER /
// VALIDATE_PASS and it signs in instead.
const USER = process.env.VALIDATE_USER || 'demo-validator';
const PASS = process.env.VALIDATE_PASS || 'validate-me-9';
const SIGN_IN = !!process.env.VALIDATE_USER;

// On a live box the instance already has branding an operator chose. Record it on
// the way in and put it back on the way out, so validating a deployment does not
// silently rebrand it.
let restoreBrand = null;

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
// Switch tabs and wait for the NEW render pass to land. `go()` re-renders
// asynchronously: `render()` awaits the i18n policy, `renderTab()` paints a
// "…" placeholder, then the view's own fetches resolve and the real markup
// replaces it. A `waitForSelector` right after `go()` on a tab the page is
// ALREADY showing matches the old DOM, and the next assertion can then run
// against the placeholder — which is how "localization card present in Admin"
// failed once in CI (a slower runner) and never locally. So: remember the
// render sequence number, ask for the tab, and wait until a later pass has
// painted, the placeholder is gone, and the selector is there.
async function goTab(page, tab, sel, { timeout = 15000 } = {}) {
  const before = await page.evaluate(() => renderSeq);
  await page.evaluate(t => window.go(t), tab);
  return until(page, ([b, s]) => {
    const main = document.getElementById('main');
    const placeholder = main && main.children.length === 1 && main.firstElementChild.tagName === 'P' && main.firstElementChild.textContent === '…';
    return renderSeq > b && !placeholder && !!document.querySelector(s);
  }, { timeout, arg: [before, sel] });
}

async function until(page, fn, { timeout = 15000, label = 'condition', arg = undefined } = {}) {
  const t0 = Date.now();
  for (;;) {
    let v = false;
    try { v = await page.evaluate(fn, arg); } catch {}
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
// Console errors count — a silent JS exception is a broken console. But the
// browser also logs "Failed to load resource" for every 4xx, and an expected 4xx
// is the app working: /api/me returns 401 before sign-in and again right after
// sign-out. Those are not app errors, and failing on them would train everyone to
// ignore this gate. Server faults are still caught by the 5xx watcher below.
const EXPECTED_4XX = /Failed to load resource.*\b(401|403|404)\b/i;
page.on('console', m => {
  if (m.type() !== 'error') return;
  const text = m.text();
  if (EXPECTED_4XX.test(text)) return;
  pageErrors.push('console: ' + text);
});
page.on('response', r => { if (r.status() >= 500) httpErrors.push(`${r.status()} ${r.request().method()} ${r.url()}`); });

try {
  // ── 1. the server is up and the sign-in screen renders the shipped brand ────
  step('sign-in screen and default branding');
  await page.goto(BASE + '/login', { waitUntil: 'networkidle', timeout: 30000 });
  await page.waitForSelector('#lu', { timeout: 20000 });
  ok('sign-in form present', await page.locator('#lu').count() === 1);
  ok('Mentor mark rendered', await page.locator('h1.brand svg.tmx-mark').count() === 1);
  ok('wordmark reads TMach', (await page.locator('h1.brand').innerText()).includes('TMach'));
  eq('browser title is the brand', await page.title(), 'TMach');
  const brandApi = await apiCall(page, '/api/branding');
  ok('GET /api/branding is public (no token yet)', brandApi.ok, `status ${brandApi.status}`);
  eq('default branding title', brandApi.json && brandApi.json.title, 'TMach');

  // A repaint of the sign-in screen must not throw away what has been typed.
  // authView()'s inputs are always empty and switching language calls render(),
  // so this wiped the username — an empty login field, mid-sign-in. Fails
  // against the code before paintAuth().
  const langs = await page.locator('.langtog button').count();
  if (langs > 1) {
    // Switching writes localStorage.tmx_lang, and a stored choice legitimately
    // WINS over the instance default — which would silently break step 8b's
    // "console repaints in Japanese". So put the key back exactly as it was and
    // reload, leaving no trace of this check.
    const before = await page.evaluate(() => localStorage.getItem('tmx_lang'));
    await page.fill('#lu', 'typed-before-switch');
    await page.locator('.langtog button').last().click();
    await page.waitForTimeout(1200);
    eq('switching language keeps what was typed into the sign-in form',
       await page.inputValue('#lu'), 'typed-before-switch');
    await page.evaluate((v) => { if (v === null) localStorage.removeItem('tmx_lang');
                                 else localStorage.setItem('tmx_lang', v); }, before);
    await page.goto(BASE + '/login', { waitUntil: 'networkidle', timeout: 30000 });
    await page.waitForSelector('#lu', { timeout: 20000 });
  }

  // ── 2. get into the console: bootstrap (fresh) or sign in (live) ────────────
  step(SIGN_IN ? 'sign in' : 'first-run bootstrap');
  if (SIGN_IN) {
    await page.fill('#lu', USER);
    await page.fill('#lp', PASS);
    await page.evaluate(() => window.doLogin());
  } else {
    await page.click('summary:has-text("First run")');
    await page.fill('#bu', USER);
    await page.fill('#bp', PASS);
    await page.evaluate(() => window.doBootstrap());
  }
  const shell = await until(page, () => !!document.querySelector('nav.tabs'), { timeout: 25000 });
  ok('console shell rendered', shell);
  if (!shell) throw new Error((SIGN_IN ? 'sign-in' : 'bootstrap') + ' did not reach the console');
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

  // ── 3c. the editor, and the Markdown preview as a sanitiser (issue #180) ────
  // A SOURCE assertion cannot establish that mdRender escapes; this runs the
  // real function on the real page. Every case here is an input somebody would
  // actually try.
  step('editor: the Markdown preview');
  {
    const probe = await page.evaluate(() => ({
      tag:    mdRender('<img src=x onerror="alert(1)">'),
      script: mdRender('<script>alert(1)<\/script>'),
      js:     mdRender('[click](javascript:alert(1))'),
      entity: mdRender('[click](&#106;avascript:alert(1))'),
      head:   mdRender('# Title'),
      fence:  mdRender('```\n**not bold**\n```'),
      table:  mdRender('| a | b |\n|---|---|\n| 1 | 2 |'),
      link:   mdRender('[docs](https://example.test/x)'),
      quote:  mdRender('> quoted'),
      list:   mdRender('- one\n- two')
    }));
    ok('an img tag is escaped, not rendered',
      !/<img/i.test(probe.tag) && probe.tag.includes('&lt;img'), probe.tag);
    ok('a script tag is escaped, not rendered',
      !/<script/i.test(probe.script), probe.script);
    ok('a javascript: link is refused', !/href="javascript/i.test(probe.js), probe.js);
    ok('…and an entity-encoded one cannot survive the escape',
      !/href="&#106;avascript/i.test(probe.entity) && !/href="javascript/i.test(probe.entity),
      probe.entity);
    ok('a heading renders', probe.head.includes('<h1>Title</h1>'), probe.head);
    ok('a fenced block keeps its asterisks literal',
      probe.fence.includes('**not bold**') && !probe.fence.includes('<strong>'), probe.fence);
    ok('a pipe table renders', probe.table.includes('<table>') && probe.table.includes('<td>1</td>'),
      probe.table);
    ok('an http link renders with rel=noopener',
      probe.link.includes('href="https://example.test/x"') && probe.link.includes('rel="noopener'),
      probe.link);
    ok('a blockquote renders', probe.quote.includes('<blockquote>'), probe.quote);
    ok('a list renders', probe.list.includes('<li>one</li>'), probe.list);
  }

  // The toolbar, the preview pane and the export, driven through the UI.
  step('editor: the toolbar and the export');
  await goTab(page, 'notes', '#nb');
  await page.fill('#nb', '# Hello\n\nsome *body* text');
  // Split view is a toolbar button; the preview pane only exists once it is on.
  await page.evaluate(() => edToggle('note', 'preview', 'side'));
  await page.waitForSelector('#edprev_note', { timeout: 5000 });
  ok('the preview pane renders the body',
    (await page.innerHTML('#edprev_note')).includes('<h1>Hello</h1>'));
  ok('the count is shown', /\bwords\b|\u8a9e/.test(await page.textContent('#edcount_note')));
  // Line numbers imply wrap off — the tie, through the real toggle.
  await page.evaluate(() => edToggle('note', 'nums'));
  await page.waitForSelector('#ednums_note', { timeout: 5000 });
  ok('the gutter appears with line numbers on',
    (await page.textContent('#ednums_note')).trim().startsWith('1'));
  ok('…and soft wrap is off while they are on',
    (await page.getAttribute('#nb', 'wrap')) === 'off');
  await page.evaluate(() => edToggle('note', 'nums'));
  await page.evaluate(() => edToggle('note', 'preview', 'off'));
  // The export is a Blob and an a[download]; `default-src 'self'` governs this
  // document, so the only question worth asking is whether the policy refuses
  // it. The gate fails on any console error, which is how every other CSP
  // claim in this console was established.
  {
    const before = pageErrors.length;
    const dl = page.waitForEvent('download', { timeout: 8000 }).catch(() => null);
    await page.evaluate(() => edExport('note', 'validator'));
    const got = await dl;
    ok('exporting .md is not refused by the CSP', pageErrors.length === before,
      pageErrors.slice(before).join(' | '));
    ok('…and a download really started', !!got && /\.md$/.test(got.suggestedFilename()),
      got ? got.suggestedFilename() : 'no download event');
  }

  // Editing a note — the path that did not exist before #180.
  step('editor: a note can be edited');
  await page.fill('#nt', 'Editable note');
  await page.fill('#nb', 'first body');
  await page.evaluate(() => window.doCreateNote());
  await page.waitForTimeout(600);
  const edited = await page.evaluate(async () => {
    const r = await fetch('/api/notes', { headers: { Authorization: 'Bearer ' + S.token } });
    const j = await r.json();
    const n = j.notes.filter(x => x.title === 'Editable note')[0];
    noteEdit(n.id, n.body, n.title, n.visibility);
    return n.id;
  });
  await page.waitForTimeout(600);
  await page.fill('#nb', 'second body, edited in place');
  await page.evaluate(() => window.doSaveNote ? doSaveNote() : null);
  await page.waitForTimeout(800);
  const after = await page.evaluate(async (id) => {
    const r = await fetch('/api/notes/' + id, { headers: { Authorization: 'Bearer ' + S.token } });
    return (await r.json()).body;
  }, edited);
  ok('the edit was stored through PUT', after === 'second body, edited in place', after);

  // ── 3d. the command palette and the keyboard (issue #182) ───────────────────
  // Real key events through the real delegated listener: a source assertion can
  // say the hook is wired and only a browser can say the key arrives.
  step('palette: the keyboard');
  await page.evaluate(() => window.go('notes'));
  await page.waitForTimeout(400);
  const MOD = await page.evaluate(() => PAL_MAC ? 'Meta' : 'Control');
  await page.keyboard.press(MOD + '+KeyK');
  await page.waitForSelector('#palq', { timeout: 5000 });
  ok('the palette opens on the platform modifier + K', true);
  ok('…and it offers the tabs',
    (await page.textContent('#pallist')).includes('Notes'));
  // Arrows move the selection, Enter runs it. Typing a tab name and pressing
  // Enter is the whole interaction the issue asks for.
  await page.fill('#palq', 'Repository');
  await page.waitForTimeout(300);
  ok('typing filters the list',
    (await page.textContent('#pallist')).includes('Repository'));
  await page.keyboard.press('Enter');
  await page.waitForTimeout(700);
  ok('Enter activates the selected item', await page.evaluate(() => S.tab) === 'repository');
  ok('…and the palette closed', await page.evaluate(() => !!document.getElementById('palette').hidden));

  // Esc closes it, and does so without disturbing anything else.
  await page.keyboard.press(MOD + '+KeyK');
  await page.waitForSelector('#palq', { timeout: 5000 });
  await page.keyboard.press('Escape');
  await page.waitForTimeout(300);
  ok('Esc closes the palette', await page.evaluate(() => !!document.getElementById('palette').hidden));

  // The `?` overlay — and the rule that matters: it must do nothing while
  // something is being typed into, or it eats a question mark.
  await page.keyboard.press('Shift+Slash');
  await page.waitForTimeout(300);
  ok('? opens the shortcut list',
    await page.evaluate(() => !document.getElementById('shortcuts').hidden));
  await page.keyboard.press('Escape');
  await page.waitForTimeout(250);
  ok('…and Esc closes it',
    await page.evaluate(() => !!document.getElementById('shortcuts').hidden));

  await goTab(page, 'notes', '#nb');
  await page.click('#nb');
  await page.keyboard.type('a ? in a note');
  ok('a bare ? typed into a field does NOT open the overlay',
    await page.evaluate(() => !!document.getElementById('shortcuts').hidden));
  ok('…and the question mark really was typed',
    (await page.inputValue('#nb')).includes('a ? in a note'),
    await page.inputValue('#nb'));
  // …while the MODIFIER works even from inside a field, which is the deliberate
  // asymmetry: a held modifier is unambiguous.
  await page.keyboard.press(MOD + '+KeyK');
  await page.waitForSelector('#palq', { timeout: 5000 });
  ok('the modifier opens the palette from inside a text field', true);
  await page.keyboard.press('Escape');
  await page.waitForTimeout(250);

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

  // ── 6b. the document pipeline: upload → "Run workflow…" → four derived documents
  //        → "Processed by" → an Automation (DWF steps 2 and 4, DSH step 3) ─────
  if (process.env.VALIDATE_PIPELINE === '1') {
    step('document pipeline: run by hand, processed-by panel, automations card');
    await page.evaluate(() => window.go('repository'));
    await page.waitForSelector('#rfile', { timeout: 10000 });
    // a template first, then the invoice
    await page.setInputFiles('#rfile', { name: 'approval.md', mimeType: 'text/markdown',
      buffer: Buffer.from('# Approval\n\nTitle: {{title}}\nSummary: {{summary}}\n') });
    await page.fill('#rkey', 'templates/approval.md');
    await page.evaluate(() => window.repoUpload());
    ok('template uploaded', await until(page, () => document.body.innerText.includes('templates/approval.md'), { timeout: 20000 }));
    await page.setInputFiles('#rfile', { name: 'acme-invoice.txt', mimeType: 'text/plain',
      buffer: Buffer.from('INVOICE\nAcme Corp\nWidgets 1000\nShipping 250.50\nTotal 1250.50\n') });
    await page.fill('#rkey', 'inbox/acme-invoice.txt');
    await page.evaluate(() => window.repoUpload());
    ok('invoice uploaded', await until(page, () => document.body.innerText.includes('inbox/acme-invoice.txt'), { timeout: 20000 }));
    // a budget, or the run sits queued (the default is 2,000 tokens/day)
    await apiCall(page, '/api/quota', { method: 'POST', body: { dimension: 'ai.tokens.total', limit: 1000000, window: 'day' } });
    const inv = await apiCall(page, '/api/repo?prefix=inbox/acme-invoice.txt');
    const invId = ((inv.json && inv.json.objects) || []).map(o => o.id)[0];
    ok('invoice id resolved', !!invId);

    // "Run workflow…" from the document lands on the run form with it prefilled
    await page.evaluate(id => window.repoRunWorkflow(id), invId);
    ok('run form opened on process-upload',
      await until(page, () => typeof S !== 'undefined' && S.wfSel === 'process-upload' && !!document.querySelector('#wfi_0'), { timeout: 15000 }));   // S is a top-level const, not window.S
    const idx = await page.evaluate(() => ({ object_id: S.wfKeys.indexOf('object_id'), schema: S.wfKeys.indexOf('schema'),
                                              template: S.wfKeys.indexOf('template'), locales: S.wfKeys.indexOf('locales') }));
    eq('object_id is prefilled', await page.evaluate(i => document.getElementById('wfi_' + i).value, idx.object_id), invId);
    await page.fill('#wfi_' + idx.template, 'templates/approval.md');
    await page.fill('#wfi_' + idx.locales, '["nl"]');
    await page.fill('#wfi_' + idx.schema, JSON.stringify({ type: 'object', required: ['title', 'summary'],
      properties: { title: { type: 'string' }, summary: { type: 'string' }, date: { type: ['string', 'null'] } } }));
    await page.evaluate(() => window.wfStart());
    ok('run started and the run view opened',
      await until(page, () => !!S.wfRun && document.body.innerText.includes('process-upload'), { timeout: 15000 }));
    const runId = await page.evaluate(() => S.wfRun);
    let runStatus = '';
    for (let i = 0; i < 400 && !['done', 'error', 'canceled'].includes(runStatus); i++) {
      const r = await apiCall(page, '/api/runs/' + runId);
      runStatus = (r.json && r.json.status) || '';
      if (!['done', 'error', 'canceled'].includes(runStatus)) await page.waitForTimeout(500);
    }
    const runJson = (await apiCall(page, '/api/runs/' + runId)).json || {};
    eq('the run finished', runStatus, 'done');
    if (runStatus !== 'done') console.log('      run error: ' + runJson.error);

    // the derived documents sit beside the invoice, and its panel lists them
    await page.evaluate(() => window.go('repository'));
    await page.waitForSelector('#rfile', { timeout: 10000 });
    // `until` serializes its predicate, so a closure over `k` would not survive; pass it as an argument
    for (const k of ['inbox/acme-invoice.txt.extracted.json', 'inbox/acme-invoice.txt.form.md', 'inbox/acme-invoice.txt.form.nl.md'])
      ok('derived document listed: ' + k,
         await page.waitForFunction(key => document.body.innerText.includes(key), k, { timeout: 15000 }).then(() => true, () => false));
    await page.evaluate(id => window.repoOpenDetail(id), invId);
    ok('"Processed by" lists the derived documents and the run',
      await until(page, () => { const el = document.getElementById('rprocessed');
        return !!el && el.innerText.includes('extracted.json') && el.innerText.includes('process-upload'); }, { timeout: 15000 }));
    ok('the share dialog offers capabilities', await page.evaluate(() => !!document.querySelector('#rdcap') && !!document.querySelector('#rdexp')));
    // "Shared with me" renders (empty for the operator, who owns everything here)
    await page.evaluate(() => window.repoFilter(true));
    ok('"Shared with me" filter renders', await until(page, () => !!document.getElementById('rf_shared') && document.body.innerText.includes('Shared with me')));
    await page.evaluate(() => window.repoFilter(false));

    // an Automation: create a trigger from the card, upload into its prefix, watch it fire
    await page.evaluate(() => window.go('workflows'));
    ok('Automations card renders', await until(page, () => !!document.querySelector('#tg_prefix'), { timeout: 15000 }));
    await page.fill('#tg_prefix', 'inbox/auto/');
    await page.fill('#tg_input', JSON.stringify({ schema: { type: 'object', required: ['title', 'summary'],
      properties: { title: { type: 'string' }, summary: { type: 'string' }, date: { type: ['string', 'null'] } } }, template: '', locales: [] }));
    await page.evaluate(() => window.trgCreate());
    ok('trigger listed', await until(page, () => document.body.innerText.includes('inbox/auto/'), { timeout: 15000 }));
    const put = await page.evaluate(async () => {
      const tok = localStorage.getItem('tmx_token');
      const res = await fetch('/api/repo/inbox/auto/scan-001.txt', { method: 'PUT',
        headers: { Authorization: 'Bearer ' + tok, 'Content-Type': 'text/plain' }, body: 'INVOICE Acme, again' });
      return res.status;
    });
    ok('upload into the triggered prefix accepted', put === 200 || put === 201, `status ${put}`);   // 201 for a new key
    const trg = await apiCall(page, '/api/doc-triggers');
    const tid = (((trg.json || {}).triggers) || []).map(x => x.id)[0];
    let fired = null;
    for (let i = 0; i < 200 && !fired; i++) {
      const h = await apiCall(page, '/api/doc-triggers/' + tid);
      const f = (((h.json || {}).fires) || []).find(x => x.key === 'inbox/auto/scan-001.txt');
      if (f && f.run_id) { const r = await apiCall(page, '/api/runs/' + f.run_id); if (r.json && ['done', 'error'].includes(r.json.status)) fired = r.json; }
      if (!fired) await page.waitForTimeout(500);
    }
    ok('the trigger fired and its run finished', !!fired && fired.status === 'done', fired ? fired.error : 'no fire');
    await page.evaluate(id => window.trgHistory(id), tid);
    ok('trigger history shows the fire', await until(page, () => { const el = document.getElementById('tg_history');
      return !!el && el.innerText.includes('inbox/auto/scan-001.txt'); }, { timeout: 10000 }));
  }

  // ── 7. the remaining tabs render at all ─────────────────────────────────────
  step('workflows, jobs, usage render');
  for (const tab of ['workflows', 'jobs', 'usage']) {
    const before = pageErrors.length;
    await page.evaluate(t => window.go(t), tab);
    await page.waitForTimeout(700);
    ok(`${tab} tab renders without a page error`, pageErrors.length === before,
      pageErrors.slice(before).join(' | '));
  }

  // ── 7b. the health screen (issue #179) ──────────────────────────────────────
  // Source assertions in test/console-tests.rkt prove this screen is WIRED;
  // only a browser can say it RENDERS. It is also the one check on the boot
  // file moving to 99-boot.js — a view defined in a file that sorts after the
  // booting one used to be undefined when renderTab() first ran, which is a
  // ReferenceError at load and nothing but a browser sees it.
  step('health screen');
  ok('server card present on Health', await goTab(page, 'health', '#hserver'));
  ok('…and the budgets card', !!(await page.$('#hbudgets')));
  // It COMPOSES the workers and queue cards rather than drawing their figures
  // again, so both must really be on the page.
  ok('…and it composes the workers card', !!(await page.$('#wkcard')));
  ok('…and the queue card', !!(await page.$('#qcard')));
  ok('the server card names the dialect',
    /sqlite|postgre/i.test(await page.textContent('#hserver')));

  // ── 8. Admin › Branding — the new tool, round-tripped through the UI ────────
  step('admin: branding');
  ok('branding card present in Admin', await goTab(page, 'admin', '#brt'));

  // #177 (FEAT-7): the instance feature switches. They existed since #63 and had
  // no UI, so the layer that means "this deployment does not do that" was the
  // only one an operator could not see. READ-ONLY here on purpose: toggling one
  // hides a tab for every team on the box, and the localize block runs 150 lines
  // below — a fixture that changes global state breaking a distant block is a
  // shape this suite has paid for twice. The PUT is covered in server-smoke.sh.
  ok('instance features card present in Admin', await goTab(page, 'admin', '#instfeat'));
  const instFeatRows = await page.locator('#instfeat tbody tr').count();
  eq('every switchable feature is listed', instFeatRows, 5);
  ok('a feature reads as allowed until somebody turns it off',
     (await page.locator('#instfeat tbody').innerText()).includes('chat'));

  // FLEET-3: the Workers card. It replaced a three-column table that showed an
  // empty endpoint for every pull worker and drew a dead box exactly like a busy
  // one, so what is asserted here is that the three ANSWERS are on screen.
  {
    const card = page.locator('#wkcard');
    ok('workers card present in Admin', await card.count() > 0);
    const body = await card.innerText().catch(() => '');
    ok('…and it shows the local model beside the fleet', /local/.test(body));
    ok('…with the queue figure a depth count cannot explain',
       /no worker can run/i.test(body), body.slice(0, 200));
    ok('…and the create form that mints a worker token', await page.locator('#wkn').count() > 0);
  }

  // FLEET-4: the Queue card beside it. The gate fails on any console error, so
  // this also proves the card's delegated filter handlers bind under the CSP —
  // a `data-h-change` that never interpolated is how the funnel once shipped a
  // dead submit button.
  {
    const card = page.locator('#qcard');
    ok('queue card present in Admin', await card.count() > 0);
    const body = await card.innerText().catch(() => '');
    ok('…and it says which ordering it is showing',
       /newest first|order a free worker/i.test(body), body.slice(0, 160));
  }
  restoreBrand = (await apiCall(page, '/api/branding')).json;

  await page.fill('#brt', 'Ithaca Labs');
  await page.fill('#brg', 'Private AI for one team');
  await page.evaluate(() => window.doBrandSave());
  ok('header shows the new title',
    await until(page, () => (document.querySelector('header.top .brand') || {}).innerText?.includes('Ithaca Labs')));
  eq('browser tab title follows branding', await page.title(), 'Ithaca Labs');

  // the tagline is what an unauthenticated visitor sees, so check it there
  const pub = await apiCall(page, '/api/branding');
  eq('branding readable publicly after save', pub.json && pub.json.tagline, 'Private AI for one team');

  // ── the theme: tokens on the branding document become the console's palette ──
  // This is the only end-to-end proof that the token → CSS-variable mapping works;
  // a model test can only say the document was stored.
  await page.evaluate(() => {
    window.brandThemeSet('bg', '#101014');
    window.brandThemeSet('brand', '#c9a227');
  });
  ok('editing a token previews live',
    await until(page, () => getComputedStyle(document.body).backgroundColor === 'rgb(16, 16, 20)'));
  await page.evaluate(() => window.doBrandSave());
  await page.reload({ waitUntil: 'domcontentloaded' });
  ok('…and survives a reload, from the stored theme',
    await until(page, () => getComputedStyle(document.body).backgroundColor === 'rgb(16, 16, 20)',
      { timeout: 15000 }));
  const themed = await apiCall(page, '/api/branding');
  eq('the theme is public, so the sign-in screen wears it too',
    themed.json && themed.json.theme && themed.json.theme.brand, '#c9a227');
  // The server's refusal of an illegible theme is pinned in server-smoke.sh, NOT
  // here: this gate fails on any console error, and a deliberate 400 logs one.
  // the reload above left the console on its default tab — come back before the
  // rest of this step reaches for Admin's controls
  ok('back on Admin after the reload', await goTab(page, 'admin', '#brt'));

  // logo upload replaces the mark
  await page.setInputFiles('#brf', {
    name: 'logo.png', mimeType: 'image/png', buffer: Buffer.from(pngB64, 'base64')
  });
  ok('uploaded logo replaces the mark in the header',
    await until(page, () => !!document.querySelector('header.top .brand img.tmx-logo'), { timeout: 15000 }));

  // put back whatever this instance had before the run
  await goTab(page, 'admin', '#brt');
  const back = await apiCall(page, '/api/branding', { method: 'PUT', body: restoreBrand || {} });
  ok('branding restored to its pre-run value', back.ok, `status ${back.status}`);
  await page.evaluate(b => window.applyBrand(b), restoreBrand || {});
  const wantTitle = (restoreBrand && restoreBrand.title) || 'TMach';
  const headerOk = await until(page, () => {
    const el = document.querySelector('header.top .brand');
    return !!el && (el.innerText || '') + (el.querySelector('img') ? ' [logo]' : '') !== '';
  }, { timeout: 15000 });
  ok('header re-rendered after restore', headerOk);
  eq('browser title restored', await page.title(), wantTitle);
  const finalBrand = (await apiCall(page, '/api/branding')).json;
  eq('stored branding matches what we found', finalBrand && finalBrand.title, wantTitle);
  eq('stored tagline matches what we found', finalBrand && finalBrand.tagline,
     (restoreBrand && restoreBrand.tagline) || '');
  eq('stored logo matches what we found', finalBrand && finalBrand.logo,
     (restoreBrand && restoreBrand.logo) || '');

  // ── 8b. Admin › Localization — the instance default and the off switch ──────
  // The API is covered exhaustively in test/server-smoke.sh; what only a browser
  // can prove is that the switcher actually LEAVES the header when an operator
  // turns negotiation off, and that the console comes back up in the instance's
  // language rather than a hardcoded 'en'.
  step('admin: localization');
  ok('localization card present in Admin', await goTab(page, 'admin', '#locdef'));
  const restoreI18n = (await apiCall(page, '/api/config')).json.localization;
  ok('switcher offered while negotiation is on',
    await page.locator('header.top .langtog button').count() >= 2);

  // default → ja: the console must repaint in Japanese without a reload
  await page.selectOption('#locdef', 'ja');
  await page.evaluate(() => window.doI18nSave());
  ok('console repaints in Japanese',
    await until(page, () => (document.querySelector('nav.tabs') || {}).innerText?.includes('チャット'),
                { timeout: 15000 }));

  // negotiation off: the switcher has to disappear, not merely stop working
  await goTab(page, 'admin', '#locsw');
  await page.uncheck('#locsw');
  await page.evaluate(() => window.doI18nSave());
  ok('language switcher removed when negotiation is off',
    await until(page, () => document.querySelectorAll('header.top .langtog button').length === 0,
                { timeout: 15000 }));
  const off = (await apiCall(page, '/api/config')).json.localization;
  eq('policy reads back as off', off && off.enabled, false);
  eq('…still pinned to ja', off && off.default, 'ja');

  // put the instance back the way we found it
  const backI18n = await apiCall(page, '/api/i18n', { method: 'PUT', body: restoreI18n || {} });
  ok('localization restored to its pre-run value', backI18n.ok, `status ${backI18n.status}`);
  await page.evaluate(() => window.render());
  ok('switcher returns with negotiation back on',
    await until(page, () => document.querySelectorAll('header.top .langtog button').length >= 2,
                { timeout: 15000 }));

  // ── 9. sign out and back in ─────────────────────────────────────────────────
  // ── Localization Manager — the flagship's own surface ───────────────────────
  // ── admin: session security (issue #38) ─────────────────────────────────────
  step('admin: session timeouts');
  ok('session security card present in Admin', await goTab(page, 'admin', '#spidle'));
  const spBefore = (await apiCall(page, '/api/session-policy')).json.policy;
  // the UI talks minutes and hours; the wire talks seconds
  eq('the idle box shows the policy in minutes',
     await page.inputValue('#spidle'), String(Math.round(spBefore.idle_seconds / 60)));
  await page.fill('#spidle', '12');
  await page.fill('#spabs', '2');
  await page.evaluate(() => window.doSessionPolicySave());
  ok('saving converts minutes and hours to seconds', await until(page, () => true) &&
     await (async () => {
       const p = (await apiCall(page, '/api/session-policy')).json.policy;
       return p.idle_seconds === 720 && p.absolute_seconds === 7200;
     })());
  // the caller's own effective policy reaches the console, which is what the
  // inactivity warning counts down against
  const wai = (await apiCall(page, '/api/whoami')).json;
  ok('whoami carries the effective session policy',
     wai.session_policy && wai.session_policy.idle_seconds === 720,
     JSON.stringify(wai.session_policy));
  // The server's refusal of an illegible policy is pinned in test/server-smoke.sh,
  // NOT here: this gate fails on any console error and a deliberate 400 logs one.
  // Widening the expected-4xx filter to cover 400 would hide a real validation bug
  // anywhere else in the run. Same call the branding theme's 400 made.
  // put it back so nothing later in this run is racing a 12-minute window
  await apiCall(page, '/api/session-policy', { method: 'PUT', body: spBefore });

  step('localize: the Localization Manager');
  await page.evaluate(() => window.go('localize'));
  await page.waitForTimeout(900);
  ok('Localize tab renders', await page.locator('h2:has-text("Localize")').count() === 1);

  // import is idempotent, so the gate may run against a box that already did it
  const imp = await apiCall(page, '/api/l10n/import', { method: 'POST' });
  ok('catalogs import', imp.ok, `status ${imp.status}`);

  const ja = await apiCall(page, '/api/l10n/coverage?locale=ja');
  ok('ja coverage reads back', ja.ok && typeof ja.json.total === 'number');
  // The locale filter must actually be applied. This is the regression that
  // matters: `query-param` once compared a string key against symbol keys, so
  // every filter fell back to its default and Dutch was answered with Japanese.
  const qps = await apiCall(page, '/api/l10n/coverage?locale=qps');
  eq('the ?locale filter is really applied', qps.json && qps.json.locale, 'qps');
  ok('an untranslated locale is not reported as done',
     qps.json && qps.json.approved === 0, `approved=${qps.json && qps.json.approved}`);

  // The next two calls PROVOKE refusals on purpose, and the browser logs a console
  // error for each 4xx. Rather than widen the global filter to excuse every 400 —
  // which would hide a real validation bug anywhere else in the run — note the
  // error count here and drop exactly the ones these deliberate calls generate.
  const errMark = pageErrors.length;

  // export must refuse to advertise a language with nothing approved in it
  const emptyExport = await apiCall(page, '/api/l10n/export', { method: 'POST', body: { locale: 'qps' } });
  ok('export refuses an empty catalog', !emptyExport.ok,
     `status ${emptyExport.status} ${JSON.stringify(emptyExport.json)}`);

  // and the review gate is enforced server-side
  const miss = await apiCall(page, '/api/l10n/messages?locale=qps&status=missing&limit=1');
  const m0 = miss.json && miss.json.items && miss.json.items[0];
  ok('missing strings are listable', !!m0);
  if (m0) {
    const sub = await apiCall(page, '/api/l10n/messages/' + m0.message_id,
      { method: 'PUT', body: { locale: 'qps', text: 'Validatiestring' } });
    ok('a translation can be submitted', sub.ok, `status ${sub.status}`);
    const self = await apiCall(page, '/api/l10n/review/' + (sub.json && sub.json.id),
      { method: 'POST', body: { decision: 'approve' } });
    ok('a translator cannot approve their own string', !self.ok,
       `status ${self.status} ${JSON.stringify(self.json)}`);
  }
  pageErrors.length = errMark;   // the refusals above were the point of the test

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
