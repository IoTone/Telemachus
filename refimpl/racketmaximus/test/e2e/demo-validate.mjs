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

  // ── 3b. tags on a note (#245) ───────────────────────────────────────────────
  // The UI wiring, not the rules: the rules are in note-tags-tests.rkt and the
  // HTTP shape is in server-smoke. What only a browser can say is that the field
  // is read, the chips are drawn, and the filter strip actually narrows the list.
  step('notes: tags');
  await goTab(page, 'notes', '#ntags');
  await page.fill('#nt', 'Levee 7 survey');
  await page.fill('#nb', 'due in March');
  // typed with mixed case and loose spacing, which the SERVER normalizes — the
  // console deliberately does not, or there would be two vocabularies
  await page.fill('#ntags', 'Survey,   LEVEE 7 ');
  await page.evaluate(() => window.doCreateNote());
  ok('the note arrives with normalized tags',
    await until(page, () => document.body.innerText.includes('Levee 7 survey')));
  ok('…and its tags are drawn as chips',
    await page.evaluate(() => {
      const n = [...document.querySelectorAll('.note')]
        .find(d => d.innerText.includes('Levee 7 survey'));
      return !!n && n.innerText.includes('levee 7') && n.innerText.includes('survey');
    }));
  ok('…lower-cased and collapsed by the server, not by the console',
    await page.evaluate(() => !document.body.innerText.includes('LEVEE 7')));

  // a second note so the filter has something to exclude
  await page.fill('#nt', 'Budget review');
  await page.fill('#nb', 'q3');
  await page.fill('#ntags', 'budget');
  await page.evaluate(() => window.doCreateNote());
  ok('the second note is listed too',
    await until(page, () => document.body.innerText.includes('Budget review')));

  // the strip is the SERVER's derived list; clicking a chip narrows the page
  ok('the derived tag strip is drawn',
    await page.evaluate(() => document.body.innerText.includes('Clear filter')
                              || !!document.querySelector('.card button.btn.sm')));
  await page.evaluate(() => window.noteTagToggle('budget'));
  ok('a tag chip narrows the list',
    await until(page, () => document.body.innerText.includes('Budget review')
                         && !document.body.innerText.includes('Levee 7 survey')));
  ok('…and S.noteTags carries it',
    await page.evaluate(() => (S.noteTags || []).join(',') === 'budget'));
  // two chips are an AND, which is what a repeated ?tag= means server-side
  await page.evaluate(() => window.noteTagToggle('survey'));
  ok('two tags are an AND, so nothing matches both',
    await until(page, () => !document.body.innerText.includes('Budget review')
                         && !document.body.innerText.includes('Levee 7 survey')));
  await page.evaluate(() => window.noteTagClear());
  ok('clearing the filter brings both back',
    await until(page, () => document.body.innerText.includes('Budget review')
                         && document.body.innerText.includes('Levee 7 survey')));
  // RESET, or the two tabs stand in a filter and every later assertion that
  // looks for a note is filtered out — #239's e2e block paid for exactly this
  ok('the filter is reset for the blocks below',
    await page.evaluate(() => (S.noteTags || []).length === 0));

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

  // ── 3c2. the org-mode preview, as the same sanitiser (issue #246, ORG-3) ───
  // ORG-3's rule: `orgRender` takes `mdRender`'s own safety order and SHARES
  // `escBody` and `mdSafeUrl` with it. A Markdown renderer is effectively a
  // sanitiser, so this cannot be a source assertion — it runs the real function
  // on the real page, exactly as the block above does, and the inputs are the
  // ones somebody would actually try.
  step('editor: the org-mode preview');
  {
    const probe = await page.evaluate(() => ({
      tag:     orgRender('<img src=x onerror="alert(1)">'),
      script:  orgRender('<script>alert(1)<\/script>'),
      js:      orgRender('[[javascript:alert(1)][click]]'),
      entity:  orgRender('[[&#106;avascript:alert(1)][click]]'),
      bare:    orgRender('[[javascript:alert(1)]]'),
      head:    orgRender('* Title'),
      deep:    orgRender('*** Third level'),
      src:     orgRender('#+BEGIN_SRC racket\n*not bold* /not italic/\n#+END_SRC'),
      example: orgRender('#+BEGIN_EXAMPLE\n| not | a | table |\n#+END_EXAMPLE'),
      include: orgRender('#+INCLUDE: "/etc/passwd"'),
      em:      orgRender('a *bold* and /italic/ and _under_ and =verb= and ~code~ here'),
      url:     orgRender('see https://example.test/a/b/c now'),
      link:    orgRender('[[https://example.test/x][docs]]'),
      internal:orgRender('[[Some Other Note][see this]]'),
      title:   orgRender('#+TITLE: My notes'),
      filetags:orgRender('#+FILETAGS: :levee:q3:'),
      htags:   orgRender('* Inspection :work:urgent:'),
      table:   orgRender('| a | b |\n|---+---|\n| 1 | 2 |'),
      list:    orgRender('- one\n- two'),
      ordered: orgRender('1. first\n2. second'),
      outside: orgRender(':PROPERTIES:\n:ID: 42\n:END:')
    }));
    // the four that matter, and they are the same four the Markdown block asks
    ok('org: an img tag is escaped, not rendered',
      !/<img/i.test(probe.tag) && probe.tag.includes('&lt;img'), probe.tag);
    ok('org: a script tag is escaped, not rendered',
      !/<script/i.test(probe.script), probe.script);
    ok('org: a javascript: link target is refused',
      !/href="javascript/i.test(probe.js) && probe.js.includes('org-link'), probe.js);
    ok('…and an entity-encoded one cannot survive the escape',
      !/href="&#106;avascript/i.test(probe.entity) && !/href="javascript/i.test(probe.entity),
      probe.entity);
    ok('…and a BARE javascript: target is refused too',
      !/<a /i.test(probe.bare), probe.bare);
    // ORG-4's subset, construct by construct
    ok('org: a headline renders', probe.head.includes('<h1>Title</h1>'), probe.head);
    ok('org: three stars is an h3', probe.deep.includes('<h3>Third level</h3>'), probe.deep);
    ok('org: a source block keeps its markers literal',
      probe.src.includes('*not bold*') && probe.src.includes('/not italic/')
        && !probe.src.includes('<strong>') && !probe.src.includes('<em>'), probe.src);
    ok('org: an example block is not read as a table',
      probe.example.includes('| not | a | table |') && !probe.example.includes('<table>'),
      probe.example);
    // ORG-5 — refused BY NAME and visibly, and it does not echo the path it was
    // asked to read: the refusal is about the directive, not about a file.
    ok('org: #+INCLUDE: is refused visibly',
      probe.include.includes('org-refused') && /INCLUDE/.test(probe.include)
        && !probe.include.includes('/etc/passwd'), probe.include);
    ok('org: the five emphasis markers render',
      probe.em.includes('<strong>bold</strong>') && probe.em.includes('<em>italic</em>')
        && probe.em.includes('<u>under</u>') && (probe.em.match(/<code>/g) || []).length === 2,
      probe.em);
    // THE ONE THAT JUSTIFIES ORG'S BORDER RULES rather than a naive
    // `/\/(.+?)\//`: a URL in a paragraph is a real body, not a corner case.
    ok('org: a URL in a paragraph is not read as italics',
      !probe.url.includes('<em>') && probe.url.includes('example.test/a/b/c'), probe.url);
    ok('org: an external link renders with rel=noopener',
      probe.link.includes('href="https://example.test/x"') && probe.link.includes('rel="noopener'),
      probe.link);
    // ORG-6 in this slice: an internal target is a MARKED span and not an
    // anchor, because nothing resolves a note id yet and a link that goes
    // nowhere is worse than a marker that says what it is.
    ok('org: an internal link is a marker, not a dead anchor',
      probe.internal.includes('org-link') && probe.internal.includes('see this')
        && !/<a /i.test(probe.internal), probe.internal);
    ok('org: #+TITLE: renders as the heading', probe.title.includes('My notes'), probe.title);
    ok('org: #+FILETAGS: renders as badges',
      probe.filetags.includes('levee') && probe.filetags.includes('q3')
        && (probe.filetags.match(/badge/g) || []).length === 2, probe.filetags);
    ok('org: a headline’s trailing :tags: render and leave the text alone',
      probe.htags.includes('Inspection') && !probe.htags.includes(':work:')
        && probe.htags.includes('work') && probe.htags.includes('urgent'), probe.htags);
    ok('org: a table renders', probe.table.includes('<table>') && probe.table.includes('<td>1</td>'),
      probe.table);
    ok('org: a list renders', probe.list.includes('<li>one</li>'), probe.list);
    ok('org: an ordered list renders', probe.ordered.includes('<ol>'), probe.ordered);
    // ORG-4's honest failure: anything outside the subset renders as its own
    // text rather than disappearing.
    ok('org: a property drawer renders as its own text',
      probe.outside.includes(':PROPERTIES:') && probe.outside.includes(':ID: 42'), probe.outside);
  }

  // The format is a declared property of the NOTE, so the switch has to reach
  // the preview AND the write. Driven through the real control.
  step('editor: the body format reaches the preview and the write');
  await goTab(page, 'notes', '#nb');
  // THE PREVIEW GOES ON FIRST, and the order is load-bearing for a reason worth
  // knowing: `edToggle` calls `renderTab()`, which rebuilds the form's plain
  // inputs from the template — so a title typed before it is discarded. That is
  // pre-existing and belongs to the whole Notes form (title, tags and
  // visibility are all plain inputs); what this block is about is that the
  // FORMAT switch does not do the same thing.
  await page.evaluate(() => edToggle('note', 'preview', 'side'));
  await page.waitForSelector('#edprev_note', { timeout: 5000 });
  await page.fill('#nt', 'Org note');
  await page.fill('#nb', '* A headline\n\nwith *bold* text');
  ok('the Markdown preview reads the stars as a bullet',
    (await page.innerHTML('#edprev_note')).includes('<li>'),
    await page.innerHTML('#edprev_note'));
  await page.selectOption('#edfmt_note', 'org');
  await page.waitForSelector('#edprev_note h1', { timeout: 5000 });
  ok('…and switching to org reads them as a headline',
    (await page.innerHTML('#edprev_note')).includes('<h1>A headline</h1>'),
    await page.innerHTML('#edprev_note'));
  ok('the format control kept its choice', (await page.inputValue('#edfmt_note')) === 'org');
  // THE ASSERTION THIS BLOCK EXISTS FOR, and the gate is what found it needed:
  // the first version of `edSetFormat` called `renderTab()`, which rebuilds the
  // form's plain inputs from the template — so switching the format silently
  // discarded the title and the note was created under the template's own
  // placeholder. The export label follows the format in the same breath.
  ok('…and the title somebody typed survived the switch',
    (await page.inputValue('#nt')) === 'Org note', await page.inputValue('#nt'));
  ok('…and the export label follows the format',
    /\.org/.test(await page.textContent('#edexp_note')), await page.textContent('#edexp_note'));
  await page.evaluate(() => window.doCreateNote());
  await page.waitForTimeout(600);
  {
    const got = await page.evaluate(async () => {
      const r = await fetch('/api/notes', { headers: { Authorization: 'Bearer ' + S.token } });
      const j = await r.json();
      const n = j.notes.filter(x => x.title === 'Org note')[0];
      return n ? { format: n.format, body: n.body } : null;
    });
    ok('an org note is stored as org', got && got.format === 'org', JSON.stringify(got));
    ok('…and its body is stored verbatim', got && got.body.indexOf('* A headline') === 0,
      got ? got.body : 'no note');
  }
  await page.evaluate(() => { edToggle('note', 'preview', 'off'); noteEditCancel(); });

  // ── 3c3. the edges a note declares (#246 slice 2, ORG-8/ORG-9/ORG-15) ──────
  // The renderer half first, as a pure function on the real page: the
  // resolution map is OPTIONAL and its absence must be slice 1's behaviour
  // exactly, which is what the §3c2 probes above depend on.
  step('notes: a link drawn resolved, broken, and unresolved');
  {
    const probe = await page.evaluate(() => ({
      none:    orgRender('[[Some Note][see]]'),
      okmark:  orgRender('[[Some Note][see]]', { 'Some Note': true }),
      broken:  orgRender('[[Some Note][see]]', { 'Some Note': false }),
      // THE CASE THE ESCAPED KEY EXISTS FOR: by the time the rules run a source
      // `&` is `&amp;`, so a map keyed on what the server stored would miss it.
      amp:     orgRender('[[A &  B][x]]', { 'A &amp;  B': false }),
      ext:     orgRender('[[https://example.test/x][e]]', { 'https://example.test/x': false })
    }));
    ok('an unresolved marker is slice 1’s plain one',
      /class="org-link"/.test(probe.none), probe.none);
    ok('a resolved link is marked resolved',
      /class="org-link ok"/.test(probe.okmark), probe.okmark);
    ok('a broken link is drawn visibly broken',
      /class="org-link broken"/.test(probe.broken), probe.broken);
    ok('…and a target carrying an ampersand is matched too',
      /class="org-link broken"/.test(probe.amp), probe.amp);
    ok('an external link is still an anchor, whatever the map says',
      /<a href="https:\/\/example\.test\/x"/.test(probe.ext), probe.ext);
  }

  // Now the panel, through the real view card and the real route.
  step('notes: the links panel, and what it does not say');
  const linkIds = await page.evaluate(async () => {
    const mk = (b) => fetch('/api/notes', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + S.token, 'Content-Type': 'application/json' },
      body: JSON.stringify(b)
    }).then(r => r.json());
    const hub = await mk({ title: 'Levee hub', body: 'the hub' });
    const src = await mk({ title: 'Levee notes', format: 'org',
                           body: '* Survey\n\nsee [[Levee hub][the hub]] and [[Gone missing]]\n' });
    return { hub: hub.id, src: src.id };
  });
  await page.evaluate((id) => noteShow(id), linkIds.src);
  await page.waitForSelector('ul.org-edges', { timeout: 5000 });
  {
    const card = await page.innerHTML('#app');
    ok('the resolved link is offered as the note it reaches',
      card.includes('Levee hub'), 'no destination title');
    ok('the broken one is reported with its target and a reason',
      card.includes('Gone missing') && /org-link broken/.test(card), 'no broken marker');
    // ORG-9 — there is nothing to say about an edge that was dropped, and the
    // console must not invent a figure for one.
    ok('nothing is reported as withheld', !/withheld/i.test(card));
    // ORG-15 — the reverse read, on the note being pointed at
    await page.evaluate((id) => noteShow(id), linkIds.hub);
    await page.waitForSelector('ul.org-edges', { timeout: 5000 });
    const back = await page.innerHTML('#app');
    ok('…and the target shows what links to it', back.includes('Levee notes'), back.length + ' chars');
  }
  // A fixture that changes global state breaks a distant block — this file's own
  // repeated lesson, and #239's e2e block paid it again. Close the card.
  await page.evaluate(() => noteViewClose());

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

  // ── 3e. in-product help is HIDDEN when it cannot work (issue #183) ──────────
  // This instance has no embedder and no corpus, which is every fresh install.
  // So the half worth asserting in a browser is the ABSENCE of the affordance —
  // a panel that explains itself only after you press it is worse than no panel,
  // and on a configured box this state cannot be reproduced at all.
  step('help: nothing offered when nothing can answer');
  ok('whoami says which half is missing',
    await page.evaluate(() => window.S.me.help.reason === 'unconfigured'),
    await page.evaluate(() => JSON.stringify(window.S.me.help)));
  ok('…so no Docs button is in the header',
    await page.evaluate(() => !document.querySelector('header .kbd-hint[title*="documentation"]')));
  // …and the shortcut does nothing rather than opening an overlay that would
  // have to apologise for itself.
  await page.keyboard.press(MOD + '+Slash');
  await page.waitForTimeout(200);
  ok('…and the shortcut opens nothing',
    await page.evaluate(() => !!document.getElementById('helpbox').hidden));
  ok('…while the overlay the shell reserves for it is still there',
    await page.evaluate(() => !!document.getElementById('helpbox')));

  // ── 3e2. …and when it CAN answer, the answer reaches the panel ──────────────
  // THE BUG THIS EXISTS FOR SHIPPED, AND §3e ABOVE IS WHY IT COULD NOT BE SEEN.
  // `doHelpAsk` assigned the WRAPPER `api()` returns — {ok, status, json} —
  // where the body belongs, so `helpBody` read `reason`, `answer` and
  // `citations` off an object with none of them and rendered the empty string
  // for every question ever asked. Reported from outside as "Help is broken,
  // doesn't respond to chat", with the server answering perfectly all along.
  //
  // §3e asserts the HIDDEN half, which is all a fresh install can show — and
  // that is exactly the trap: the branch CI can reach was covered and the branch
  // a user meets was not. So this one STUBS `api` and drives the real
  // `doHelpAsk`, which needs no embedder, no corpus and no model. The console's
  // scripts are classic, so `api` is a writable global.
  step('help: a reply reaches the panel');
  const helpHtml = await page.evaluate(async () => {
    const saved = window.api;
    window.api = async () => ({ ok: true, status: 200, json: {
      answer: 'Raise the window with OLLAMA_CONTEXT_LENGTH.',
      citations: [{ path: 'docs/ops/gpu-fleet-runbook.md', heading: 'Models' }],
      reason: null } });
    try {
      window.S.help = { q: 'how do I raise the context window?', rep: null, asking: false };
      await window.doHelpAsk();
      return document.getElementById('helpout').innerHTML;
    } finally { window.api = saved; }
  });
  ok('the answer text is rendered', helpHtml.includes('OLLAMA_CONTEXT_LENGTH'), helpHtml.slice(0, 200));
  ok('…and the citation is listed', helpHtml.includes('gpu-fleet-runbook.md'), helpHtml.slice(0, 200));
  ok('…and nothing of the wrapper leaks in', !/\bstatus\b.*200/.test(helpHtml));

  // A REFUSAL HAS TO LAND SOMEWHERE TOO, and the old code could not tell one
  // from an answer: both became a wrapper with no `answer`, so a 403 for a quota
  // was also silence. It is a toast now, like every other call in this console.
  const helpRefusal = await page.evaluate(async () => {
    const saved = window.api, savedToast = window.toast;
    let toasted = null;
    window.toast = (m) => { toasted = m; };
    window.api = async () => ({ ok: false, status: 403, json: { error: 'Forbidden: chat:use' } });
    try {
      window.S.help = { q: 'x', rep: null, asking: false };
      await window.doHelpAsk();
      return { toasted, body: document.getElementById('helpout').innerHTML };
    } finally { window.api = saved; window.toast = savedToast; }
  });
  ok('a refused question says so', (helpRefusal.toasted || '').includes('chat:use'),
    JSON.stringify(helpRefusal));
  ok('…and does not leave the last answer on screen', helpRefusal.body === '',
    JSON.stringify(helpRefusal.body).slice(0, 160));
  // HELP-23: AN ANSWER THAT NAMED NO SOURCE STILL SHOWS WHAT IT WAS READ FROM.
  // Reported from outside as "ask the documentation is still broken" — and the
  // panel and the endpoint were both working. What the reader met was a correct
  // answer under an orange warning saying it was declining: measured over ten
  // real questions against the live corpus, FOUR came back flagged while
  // carrying a good answer, because on this model `uncited` usually means the
  // model answered and did not bracket anything. This is the branch that was
  // wrong, so it is driven here rather than asserted over the source.
  const helpUncited = await page.evaluate(async () => {
    const saved = window.api;
    window.api = async () => ({ ok: true, status: 200, json: {
      answer: 'Export both keys and run rewrap.',
      citations: [],
      passages: [{ path: 'docs/ops/secrets-at-rest-runbook.md', heading: 'Rotating',
                   text: 'Export TMACH_SECRET_KEY_OLD and run rewrap.' }],
      reason: 'uncited' } });
    try {
      window.S.help = { q: 'how do I rotate the key?', rep: null, asking: false };
      await window.doHelpAsk();
      return document.getElementById('helpout').innerHTML;
    } finally { window.api = saved; }
  });
  ok('an uncited answer is still shown', helpUncited.includes('run rewrap'),
    helpUncited.slice(0, 200));
  ok('…and the passages it was read from are listed',
    helpUncited.includes('secrets-at-rest-runbook.md'), helpUncited.slice(0, 300));
  ok('…numbered, so a [1] in the prose resolves for a reader',
    helpUncited.includes('[1]'), helpUncited.slice(0, 300));
  await page.evaluate(() => { window.helpClose && window.helpClose(); });

  // ── 3f. an open overlay survives render passes behind it (#185) ─────────────
  // #185 bounded the delegated-handler table: entries created inside a render
  // pass are freed once two further passes have completed. That is safe only
  // because `H()` is ALSO called between passes — the palette and the help
  // overlay write their markup when they open, and `jobTrail`/`kgOpen` register
  // on a click — and those registrations are deliberately never swept.
  //
  // This is the assertion that makes the design's one risk falsifiable: the
  // overlay is opened, several passes run behind it (which is precisely what
  // #184's auto-refresh does on a timer), and its controls must still be bound.
  // Without this case the sweep could take the Send button out from under
  // somebody typing, and nothing would fail.
  step('an open overlay survives render passes behind it');
  await page.evaluate(() => { S.pal = S.pal || {}; palOpen(); });
  await page.waitForTimeout(300);
  const palBound = async () => page.evaluate(() => {
    const el = document.querySelector('#palette [data-h-input], #palette [data-h-keydown]');
    if (!el) return 'no-input';
    const idx = +(el.getAttribute('data-h-input') ?? el.getAttribute('data-h-keydown'));
    return typeof HANDLERS[idx] === 'function' ? 'bound' : 'SWEPT';
  });
  ok('the palette opens with its input bound', (await palBound()) === 'bound');
  for (let i = 0; i < 6; i++) await page.evaluate(() => renderTab());
  await page.waitForTimeout(800);
  ok('…and six render passes behind it do not unbind it', (await palBound()) === 'bound',
    await palBound());
  // and the sweep really is running, or the assertion above passes for the wrong
  // reason — a table nothing sweeps keeps every handler bound trivially.
  ok('…while the pass handlers behind it WERE swept',
    await page.evaluate(() => HANDLERS.some((f, i) => f === undefined && i > 10)));
  await page.keyboard.press('Escape');
  await page.waitForTimeout(200);

  // ── 3g. THE TAB BAR SURVIVES BEING USED ─────────────────────────────────────
  // The bug this pins was reported from outside: "once I click on a few of the
  // tabs (try agents, then translate), none of the tabs stay responsive." §3f
  // above proves an OVERLAY survives passes behind it and could not see this,
  // because the shell is not an overlay and nobody had asked whether it is swept.
  //
  // It is the same defect from the other side: `go()` calls only `renderTab()`,
  // so one `appShell()` paint stays on screen across every later tab change,
  // while its handlers were registered inside `render()`'s bracket and swept
  // after H_KEEP further passes. The failure is SILENT — a hole reaches the
  // dispatcher's `typeof fn !== 'function'` guard and returns — so nothing
  // errored, no request was made, and the page looked perfectly healthy.
  //
  // So this clicks the tabs as a person does, by DISPATCHING ON THE BUTTON
  // rather than calling `go()`, which is the whole point: `go()` would work fine
  // against the broken version. Three clicks is already past the old limit (the
  // control dies on the second), and the measured reproduction was two.
  step('the tab bar survives being used');
  const tabBound = async () => page.evaluate(() => {
    const bs = [...document.querySelectorAll('nav.tabs button')];
    if (!bs.length) return 'no-tabs';
    const dead = bs.filter(b => typeof HANDLERS[+b.getAttribute('data-h-click')] !== 'function');
    return dead.length ? 'DEAD:' + dead.map(b => b.dataset.tab).join(',') : 'bound';
  });
  ok('the tab bar starts bound', (await tabBound()) === 'bound', await tabBound());
  for (const tab of ['agent', 'translate', 'search', 'notes', 'jobs']) {
    await page.click(`nav.tabs button[data-tab="${tab}"]`);
    await page.waitForTimeout(400);
  }
  ok('…and five real tab CLICKS later every tab is still bound',
    (await tabBound()) === 'bound', await tabBound());
  // the click must actually have moved the tab, or the assertion above is about
  // a tab bar nobody used — the silent failure mode means a dead button looks
  // exactly like a working one from the outside.
  ok('…and the last click really did change tab',
    await page.evaluate(() => S.tab === 'jobs'), await page.evaluate(() => S.tab));
  // the header's own controls ride in the same shell paint and died with it
  ok('…and the shell header survived with it',
    await page.evaluate(() => [...document.querySelectorAll('header.top [data-h-click]')]
      .every(b => typeof HANDLERS[+b.getAttribute('data-h-click')] === 'function')));
  // …and the sweep is still running, or all of the above passes for the wrong
  // reason, exactly as §3f's last assertion guards against.
  ok('…while the pass handlers behind them WERE swept',
    await page.evaluate(() => HANDLERS.some((f, i) => f === undefined && i > 10)));

  // ── 3h. the jobs list names the worker, and refreshes only while work is live
  // #172's lesson on the console's side: "which worker ran this" is the first
  // question asked of a fleet, and the column carried a uuid or nothing at all.
  step('jobs: the worker column');
  await goTab(page, 'jobs', 'table');
  ok('the jobs table has a worker column',
    await page.evaluate(() => [...document.querySelectorAll('table thead th')]
      .some(th => th.textContent.trim().length && /worker|ワーカー/i.test(th.textContent))));
  // A settled list must NOT leave a poll running: the idle clock counts from the
  // last request (#38), so a jobs tab that ticked for ever would hold a session
  // open — QVIZ-6's objection, which is why this polls on live work rather than
  // on an interval. Asserted by the absence of the live notice when nothing is.
  ok('…and a list with nothing live says so by not claiming to refresh',
    await page.evaluate(() => {
      const live = [...document.querySelectorAll('table tbody tr')].some(
        tr => /queued|running|canceling/i.test(tr.textContent));
      const notice = document.body.textContent.includes('refreshing while work is live');
      return live === notice;          // the notice appears exactly when it is true
    }));

  // ── 3h2. REFRESHING A CARD MUST NOT KILL THE REST OF THE TAB ───────────────
  // Reported from outside: "if I click on refresh, I can no longer submit a chat
  // from the jobs page." `cardSwap` opened a render-pass bracket, so every
  // refresh counted as a pass — and the submit form, painted by the tab render
  // and never swapped, was swept two refreshes later. A live poll makes ONE
  // click enough, because the tick is the second pass.
  //
  // §3g asserts the SHELL survives tab clicks and could not see this: the shell
  // is in a slot, and the victim here is an ordinary sibling card in the tab's
  // own pass. So this clicks the real Refresh button repeatedly and checks the
  // control that is NOT in the card being swapped.
  step('refreshing the jobs list leaves the rest of the tab alive');
  await goTab(page, 'jobs', '#jobscard');
  const submitBound = () => page.evaluate(() => {
    const b = [...document.querySelectorAll('button')].find(x => x.closest('#jobscard') === null
      && x.hasAttribute('data-h-click') && !x.closest('nav.tabs') && !x.closest('header.top'));
    if (!b) return 'no-submit';
    return typeof HANDLERS[+b.getAttribute('data-h-click')] === 'function' ? 'bound' : 'DEAD';
  });
  ok('the submit button starts bound', (await submitBound()) === 'bound', await submitBound());
  for (let i = 0; i < 4; i++) {
    await page.click('#jobscard button.btn.sm');     // the card's own Refresh
    await page.waitForTimeout(500);
  }
  ok('…and four refreshes later it is STILL bound', (await submitBound()) === 'bound',
    await submitBound());
  // the swapped card's own controls must be bound too, or the slot freed what it
  // had just painted
  ok('…as are the refreshed card\'s own controls',
    await page.evaluate(() => [...document.querySelectorAll('#jobscard [data-h-click]')]
      .every(el => typeof HANDLERS[+el.getAttribute('data-h-click')] === 'function')));
  // …and the slot must still be RECLAIMING, or this passes by never freeing
  // anything — the bound #185 exists for
  ok('…while the slot still frees the generation it replaced',
    await page.evaluate(() => H_SLOTS.has('card:jobscard') && HANDLERS.some(f => f === undefined)));

  // ── 3i. the queue pager's arithmetic, and a refresh that does NOT re-render ──
  // The page window, the ellipses and the clamp are a pure function with
  // interesting EDGES, so they are exercised by calling the real one in the real
  // page — §3c's rule for the Markdown sanitiser: a question about what the code
  // COMPUTES cannot be answered by a source assertion.
  step('the queue pager computes its window');
  await goTab(page, 'admin', '#qcard');
  const pager = async (total, offset) => page.evaluate(([tt, oo]) => {
    const keepT = S.qTotal, keepO = S.qOffset;
    S.qTotal = tt; S.qOffset = oo;
    const html = qPager({ total: tt, offset: oo }, new Array(Math.min(25, tt - oo)).fill({}));
    S.qTotal = keepT; S.qOffset = keepO;
    // the page numbers offered, in order, and which one is current
    const d = document.createElement('div'); d.innerHTML = html;
    const nums = [...d.querySelectorAll('button')].map(b => b.textContent.trim());
    const cur = [...d.querySelectorAll('button[aria-current="page"]')].map(b => b.textContent.trim());
    return { nums, cur, ell: (html.match(/…/g) || []).length, jump: !!d.querySelector('input[type=number]') };
  }, [total, offset]);

  const p1 = await pager(10, 0);
  ok('a single page offers no pager at all', p1.nums.length === 0 && p1.ell === 0,
    JSON.stringify(p1));
  const p2 = await pager(500, 0);         // page 1 of 20
  ok('on page 1 the window starts at 1 and the last page is reachable',
    p2.cur[0] === '1' && p2.nums.includes('20') && p2.ell === 1, JSON.stringify(p2));
  const p3 = await pager(500, 250);       // page 11 of 20 — ellipsis BOTH sides
  ok('…mid-range it ellipsises both sides and keeps first and last',
    p3.cur[0] === '11' && p3.nums.includes('1') && p3.nums.includes('20') && p3.ell === 2,
    JSON.stringify(p3));
  const p4 = await pager(500, 475);       // last page
  ok('…and on the last page the window ends there',
    p4.cur[0] === '20' && p4.nums.includes('1'), JSON.stringify(p4));
  ok('…with a jump box on every multi-page view', p2.jump && p3.jump && p4.jump);
  // the clamp: the only way to ask for page 900 of 20 is to type it, and the
  // useful answer is the last page rather than a refusal
  ok('a page number out of range is CLAMPED, not refused',
    await page.evaluate(() => {
      const keepT = S.qTotal, keepO = S.qOffset;
      S.qTotal = 500; S.qOffset = 0;
      const pages = qPages();
      const lo = Math.min(Math.max(1, -5 | 0), pages), hi = Math.min(Math.max(1, 900 | 0), pages);
      S.qTotal = keepT; S.qOffset = keepO;
      return pages === 20 && lo === 1 && hi === 20;
    }));

  // THE PROPERTY THE REPORT WAS ABOUT: a refresh must not re-render the tab.
  // `renderTab()` bumps `renderSeq` and paints a `…` placeholder first, so if a
  // filter change went through it the sequence would move and the screen would
  // blank. A filter is used rather than a page because it needs no 25 rows.
  step('a queue filter swaps the card without re-rendering the tab');
  const seqBefore = await page.evaluate(() => renderSeq);
  await page.evaluate(() => qSet('status', 'done'));
  await page.waitForTimeout(1200);
  ok('the card is still there after the swap', await page.evaluate(() => !!document.getElementById('qcard')));
  ok('…and renderTab was never called', await page.evaluate(() => renderSeq) === seqBefore,
    `renderSeq ${seqBefore} -> ${await page.evaluate(() => renderSeq)}`);
  ok('…and the filter really took', await page.evaluate(() => (S.qFilter || {}).status) === 'done');
  // the swapped card's own controls must be BOUND — cardSwap brackets its
  // registrations, and an unbracketed swap would leak them while a mis-swept one
  // would leave the pager dead, which is #185's bug in a card
  ok('…and the swapped card\'s controls are bound',
    await page.evaluate(() => [...document.querySelectorAll('#qcard [data-h-click],#qcard [data-h-change]')]
      .every(el => typeof HANDLERS[+(el.getAttribute('data-h-click') ?? el.getAttribute('data-h-change'))] === 'function')));
  await page.evaluate(() => qSet('status', ''));
  await page.waitForTimeout(800);

  // ── 3j. LINKABLE URLS (#230) ────────────────────────────────────────────────
  // Nothing in the console was linkable: no URL for a job, a run, a document or
  // a filtered queue page, a reload always landed on Chat, and Back did nothing.
  // These are behaviour assertions in a real browser because the question is
  // what the router COMPUTES and what the history stack then does — neither of
  // which a source assertion can answer.
  step('linkable URLs: the hash mirrors the view');
  await goTab(page, 'jobs', '#jobscard');
  ok('a tab change writes the hash', await page.evaluate(() => location.hash) === '#/jobs',
    await page.evaluate(() => location.hash));
  await goTab(page, 'team', 'table');
  ok('…and changing tab again moves it', await page.evaluate(() => location.hash) === '#/team');

  // A LIVE POLL MUST NOT FLOOD THE HISTORY. `renderTab()` is the seam that
  // writes the URL and a live run re-renders every 1.5s, so an unconditional
  // push would leave an entry per tick and Back would need a hundred presses.
  const lenBefore = await page.evaluate(() => history.length);
  for (let i = 0; i < 5; i++) await page.evaluate(() => renderTab());
  await page.waitForTimeout(700);
  ok('five re-renders of the same view add NO history entries',
    await page.evaluate(() => history.length) === lenBefore,
    `${lenBefore} -> ${await page.evaluate(() => history.length)}`);

  // BACK moves through the views visited
  await page.goBack();
  await page.waitForTimeout(900);
  ok('Back returns to the previous view',
    await page.evaluate(() => location.hash) === '#/jobs' && await page.evaluate(() => S.tab) === 'jobs',
    `${await page.evaluate(() => location.hash)} / ${await page.evaluate(() => S.tab)}`);
  ok('…and the tab bar shows it', await page.evaluate(() =>
    document.querySelector('nav.tabs button.active')?.dataset.tab) === 'jobs');

  // A PASTED URL survives a reload — the whole point
  await page.goto(BASE + '/#/usage', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('nav.tabs button', { timeout: 20000 });
  await page.waitForTimeout(1200);
  ok('a pasted hash decides the view after a reload',
    await page.evaluate(() => S.tab) === 'usage', await page.evaluate(() => S.tab));

  // THE QUEUE'S FILTER AND PAGE are what make "look at page 2, filtered to done"
  // sendable — and the page number is what the earlier pagination work asked for
  await page.goto(BASE + '/#/admin/queue?status=done&page=2', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#qcard', { timeout: 25000 });
  await page.waitForTimeout(800);
  ok('a hash carries the queue filter and page',
    await page.evaluate(() => (S.qFilter || {}).status) === 'done'
    && await page.evaluate(() => S.qOffset) === 25,
    JSON.stringify(await page.evaluate(() => ({ f: S.qFilter, o: S.qOffset }))));

  // AN UNREACHABLE HASH FALLS BACK rather than painting a tab that is not in
  // the bar: `visibleTabs()` is decided by permissions and feature switches, and
  // a link may come from somebody who holds more than the reader does.
  await page.goto(BASE + '/#/not-a-tab', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('nav.tabs button', { timeout: 20000 });
  await page.waitForTimeout(1200);
  ok('an unreachable hash falls back to a real view',
    (await page.evaluate(() => visibleTabs())).includes(await page.evaluate(() => S.tab)),
    await page.evaluate(() => S.tab));
  ok('…and the address bar is put back rather than left lying',
    await page.evaluate(() => location.hash) !== '#/not-a-tab',
    await page.evaluate(() => location.hash));

  // A CREDENTIAL MUST NEVER REACH THE URL. `S.newToken`/`S.wkToken` hold a
  // freshly minted token shown once, and a URL is pasted into chat, logged by
  // proxies and kept in history — which is why /activate already strips its own.
  ok('a minted token never appears in the route',
    await page.evaluate(() => {
      const keep = S.newToken, keepW = S.wkToken, keepTab = S.tab;
      S.newToken = { token: 'SECRET-API-TOKEN' }; S.wkToken = { token: 'SECRET-WORKER-TOKEN' };
      S.tab = 'team';
      const r = routeFromState();
      S.newToken = keep; S.wkToken = keepW; S.tab = keepTab;
      return !/SECRET/.test(r);
    }));
  ok('…nor does unsaved editor text',
    await page.evaluate(() => {
      const keep = S.noteEdit, keepTab = S.tab;
      S.noteEdit = { body: 'UNSAVED-DRAFT' }; S.tab = 'notes';
      const r = routeFromState();
      S.noteEdit = keep; S.tab = keepTab;
      return !/UNSAVED/.test(r);
    }));

  // the funnel's own shareable param must still survive a hash being written
  await page.goto(BASE + '/?login=1#/jobs', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('nav.tabs button', { timeout: 20000 });
  await page.waitForTimeout(900);
  ok('an existing query string survives the hash',
    (await page.evaluate(() => location.search)).includes('login=1'),
    await page.evaluate(() => location.search + location.hash));

  // ── 3k. two usability reports: the prompt bar and the run duration ──────────
  // "For the chat screen, we should have an expanding chat bar." The prompts
  // were rows="3" and fixed, which is the one place in this console where people
  // paste a lot of text.
  step('chat: the prompt bar grows with what you type');
  await goTab(page, 'chat', '#cp');
  const h0 = await page.evaluate(() => document.getElementById('cp').getBoundingClientRect().height);
  await page.fill('#cp', Array.from({length: 9}, (_, i) => 'line ' + (i + 1)).join('\n'));
  await page.waitForTimeout(500);
  const h1 = await page.evaluate(() => document.getElementById('cp').getBoundingClientRect().height);
  ok('typing nine lines grows the bar', h1 > h0 + 30, `${Math.round(h0)} -> ${Math.round(h1)}`);
  // …and it is CAPPED, or Send is pushed off the bottom of the screen on a paste
  await page.fill('#cp', Array.from({length: 400}, (_, i) => 'line ' + i).join('\n'));
  await page.waitForTimeout(500);
  const h2 = await page.evaluate(() => document.getElementById('cp').getBoundingClientRect().height);
  ok('…and 400 lines do NOT grow it without bound', h2 < 600, `${Math.round(h2)}px`);
  ok('…so the Send button is still on screen', await page.evaluate(() => {
    const r = document.getElementById('cpsend').getBoundingClientRect();
    return r.top > 0 && r.bottom < window.innerHeight + 400;   // in the document, not pushed miles down
  }));
  ok('…and it scrolls once it is capped', await page.evaluate(() =>
    getComputedStyle(document.getElementById('cp')).overflowY === 'auto'));
  await page.fill('#cp', 'Hello team');

  // "Jobs page should have durations for the run, or duration so far if not
  // complete." The first version answered only for a FINISHED job, so the column
  // was blank for exactly the rows a person is staring at.
  step('jobs: a running job shows how long it has been going');
  ok('a running job reports elapsed time, a queued one does not',
    await page.evaluate(() => {
      const now = Math.floor(Date.now() / 1000);
      const running = jobTook({ started_epoch: now - 42, finished_epoch: null, status: 'running' });
      const done    = jobTook({ started_epoch: now - 42, finished_epoch: now - 30, status: 'done' });
      const queued  = jobTook({ started_epoch: null, finished_epoch: null, status: 'queued' });
      return /4[0-9]s/.test(running) && running !== done && done.length > 0 && queued === '';
    }),
    await page.evaluate(() => {
      const now = Math.floor(Date.now() / 1000);
      return JSON.stringify({ running: jobTook({started_epoch:now-42,finished_epoch:null}),
                              queued: jobTook({started_epoch:null,finished_epoch:null}) });
    }));
  // the two must be DISTINGUISHABLE, or a stalled job reads as a fast one
  ok('…and the running figure is marked as still going',
    await page.evaluate(() => {
      const now = Math.floor(Date.now() / 1000);
      const r = jobTook({ started_epoch: now - 42, finished_epoch: null });
      const d = jobTook({ started_epoch: now - 42, finished_epoch: now - 42 + 42 });
      return r !== d && r.length > d.length;
    }));

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

  // ── 5b. repository: Details takes you to the panel ──────────────────────────
  // Placed AFTER §5, because it needs an object to open: at §3k the repository
  // is still empty and the assertion failed for a reason with nothing to do
  // with the scroll it is about.
  // "When you click on details it seems like nothing happens. It's true,
  // something happens way at the bottom of the screen." `#rdetail` sits AFTER
  // the object table, so on a repository of any size the panel paints below the
  // fold and the click produces no visible change. A scroll, not a modal: the
  // panel is a detail of the row you came from, read alongside the list, with
  // its own Close — a modal would mean an overlay, `Hk()`, and Esc ordered
  // against the palette's and the help overlay's.
  step('repository: Details takes you to the panel');
  await goTab(page, 'repository', 'table');
  // THE VIEWPORT IS SHRUNK, AND THAT IS WHAT MAKES THIS TEST MEAN ANYTHING.
  // The gate's repository holds one object, so at 1000px the whole page fits and
  // the panel is in view whether or not anything scrolled — the first version of
  // this assertion passed against code with the scroll REMOVED, which is a test
  // that agrees with any change. A short viewport puts the panel genuinely below
  // the fold, the way a real repository of any size does.
  const vp = page.viewportSize();
  await page.setViewportSize({ width: vp.width, height: 320 });
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(300);
  const detailBtn = page.locator('table button', { hasText: /details/i }).first();
  ok('there is a Details button to click', await detailBtn.count() > 0);
  // …and it is WIRED, which is the click path
  ok('…and it is bound', await page.evaluate(() => {
    const b = [...document.querySelectorAll('table button')].find(x => /details/i.test(x.textContent));
    return !!b && typeof HANDLERS[+b.getAttribute('data-h-click')] === 'function';
  }));
  // THE PANEL IS OPENED PROGRAMMATICALLY, not by clicking, and that is the only
  // way this can test OUR code: Playwright's `click()` scrolls its target into
  // view first, so the click's own auto-scroll brings the panel along with it
  // and the assertion passes with `repoRevealDetail()` REMOVED. Measured — the
  // first version of this did exactly that. A real person clicking a Details
  // button half way down a long list does not get that favour.
  const objId = await page.evaluate(async () => {
    const r = await api('/api/repo?limit=1');
    return r.ok && r.json.objects && r.json.objects[0] ? r.json.objects[0].id : null;
  });
  ok('an object to open', !!objId);
  if (objId) {
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(200);
    const before = await page.evaluate(() => {
      const el = document.getElementById('rdetail');
      return el ? Math.round(el.getBoundingClientRect().top) : null;
    });
    ok('…and the panel starts BELOW the fold', before !== null && before >= 320,
      `top ${before} of 320`);
    await page.evaluate((id) => repoOpenDetail(id), objId);
    await page.waitForTimeout(1800);
    ok('the detail panel is filled', await page.evaluate(() =>
      !!document.getElementById('rdetail') && !!document.getElementById('rdetail').firstChild));
    ok('…and it is ON SCREEN afterwards', await page.evaluate(() => {
      const r = document.getElementById('rdetail').getBoundingClientRect();
      return r.top >= -2 && r.top < window.innerHeight;
    }), await page.evaluate(() => Math.round(document.getElementById('rdetail').getBoundingClientRect().top)
      + ' of ' + window.innerHeight));
    // a RE-open while it is already in view must not jump again: the panel is
    // re-rendered after a visibility change, a share and a revoke
    const y1 = await page.evaluate(() => window.scrollY);
    await page.evaluate(() => repoRevealDetail());
    await page.waitForTimeout(600);
    ok('…and revealing it again while visible does not jump',
      Math.abs(await page.evaluate(() => window.scrollY) - y1) < 4,
      `${y1} -> ${await page.evaluate(() => window.scrollY)}`);
  }
  await page.setViewportSize(vp);
  await page.waitForTimeout(300);

  // ── 5c. a project is a key PREFIX (#239) ────────────────────────────────────
  // "Right now all docs go into one big bucket. It should be possible to organize
  // a project around an S3 style bucket path." The STORAGE always could — keys
  // have been `/`-separated paths since slice 49 and `?prefix=` has filtered on
  // them since — so what this asserts is the two surfaces that could not: the
  // folder strip, and the editor filing into a path.
  //
  // IN THE BROWSER, because the strip is DOM and a source assertion cannot say
  // that it renders — §3c's rule for the Markdown sanitiser. The crumb trail is
  // also a pure function of the prefix with interesting edges, so `pathNav` is
  // CALLED with a fabricated folder list, the way §3i calls the pager.
  step('a project is a key prefix (#239)');
  await page.evaluate(async () => {
    const put = (key) => fetch('/api/repo/' + key.split('/').map(encodeURIComponent).join('/')
                               + '?filename=' + encodeURIComponent(key.split('/').pop())
                               + '&visibility=team',
      { method: 'PUT',
        headers: { 'Authorization': 'Bearer ' + S.token, 'Content-Type': 'application/pdf' },
        body: 'x' });
    // `_` is the everyday folder name AND a LIKE wildcard: the prefix window is
    // escaped, and the escape means nothing unless the statement names an escape
    // character — which it did not, so this folder answered empty on SQLite.
    await put('levee_7/survey.pdf');
    await put('levee_7/chapters/01.pdf');
    await put('leveeX7/other.pdf');
  });
  await goTab(page, 'repository', 'table');
  await page.waitForTimeout(400);
  const folders = () => page.evaluate(() =>
    [...document.querySelectorAll('button')].map(b => b.textContent.trim()).filter(x => /\/$/.test(x)));
  ok('the folder strip is drawn', (await folders()).includes('levee_7/'),
    JSON.stringify(await folders()));
  // CLICKING it, not calling `repoGo` — the strip has to be wired
  await page.evaluate(() => {
    const b = [...document.querySelectorAll('button')].find(x => x.textContent.trim() === 'levee_7/');
    b.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await page.waitForTimeout(900);
  const inside = await page.evaluate(() => ({
    crumbs: [...document.querySelectorAll('button')].map(b => b.textContent.trim()),
    keys: [...document.querySelectorAll('table td b.mono')].map(b => b.textContent.trim()),
    rkey: (document.getElementById('rkey') || {}).value
  }));
  // THE UNDERSCORE FOLDER HAS ITS OBJECT IN IT. Against the unescaped statement
  // this is where the gate fails, on the default dialect, with an empty folder.
  ok('…and opening it lists that folder\'s own object', inside.keys.includes('survey.pdf'),
    JSON.stringify(inside.keys));
  // `?immediate=1`: without it the subtree comes too and the view looks identical
  // to the one above it
  ok('…and not what sits in a subfolder of it',
    !inside.keys.some(k => k.indexOf('chapters/01.pdf') === 0 || k === 'chapters/01.pdf'),
    JSON.stringify(inside.keys));
  ok('…with a crumb back to the top', inside.crumbs.some(c => /^All paths$/i.test(c)),
    JSON.stringify(inside.crumbs.slice(0, 6)));
  // the upload form files into where you are standing, or it is the one control
  // on the tab that ignores it
  eq('…and the upload form is prefilled with the folder', inside.rkey, 'levee_7/');
  // the subfolder is reachable from here, which is what makes it navigation
  ok('…and the subfolder is offered', (await folders()).includes('chapters/'),
    JSON.stringify(await folders()));

  // the crumb arithmetic, called directly: a question about what the code
  // COMPUTES cannot be answered by grepping it
  const crumbHTML = await page.evaluate(() =>
    pathNav({ prefixes: [{ name: 'c', prefix: 'a/b/c/' }], truncated: true }, 'a/b/', () => {}));
  ok('pathNav draws a crumb per segment', (crumbHTML.match(/>a</g) || []).length === 1
     && (crumbHTML.match(/>b</g) || []).length === 1, crumbHTML.slice(0, 200));
  ok('…says so when it had to stop listing', /\/\/|more paths|More paths/i.test(crumbHTML)
     || crumbHTML.indexOf('foldercut') >= 0 || /listing/i.test(crumbHTML));

  // the Documents tab files into the SAME prefix, which is what makes "write
  // chapters, build up a report, upload information" one project
  await goTab(page, 'documents', '#dt');
  await page.waitForTimeout(300);
  const filed = await page.evaluate(async () => {
    const r = await api('/api/documents', { method: 'POST',
      body: { title: 'Chapter One', key: 'levee_7/chapters/', content: '# one' } });
    return r.ok ? r.json.key : ('error: ' + JSON.stringify(r.json));
  });
  // A KEY ENDING IN `/` IS A FOLDER: the console sends the project it is looking
  // at, and that as a literal key would be refused for its empty last segment.
  ok('a document is filed into a project, with the filename composed',
    /^levee_7\/chapters\/chapter-one-[0-9a-f]{8}\.md$/.test(filed), filed);
  await goTab(page, 'documents', '#dt');
  await page.waitForTimeout(400);
  ok('…and the Documents tab lists it although it is not under documents/',
    await page.evaluate(() => document.body.textContent.indexOf('Chapter One') >= 0));
  ok('…showing the path it was filed at',
    await page.evaluate(() => document.body.textContent.indexOf('levee_7/chapters/') >= 0));
  // THIS BLOCK LEAVES THE TWO TABS STANDING IN A FOLDER, AND THAT BROKE §6b.
  // The pipeline section uploads to `templates/approval.md` and then asserts the
  // page shows that key — with the Repository tab still filtered to `levee_7/`
  // the object is uploaded perfectly well and simply not listed, so two
  // assertions failed in a block with nothing to do with paths. Same shape as the
  // smoke fixture that minted a second team owner and broke a membership block
  // 300 lines below: a fixture that changes global state puts it back.
  await page.evaluate(() => { S.repoPrefix = ''; S.docPrefix = ''; S.docOffset = 0; });
  await goTab(page, 'repository', 'table');
  await page.waitForTimeout(300);
  ok('…and this block leaves both tabs back at the top',
    await page.evaluate(() => !S.repoPrefix && !S.docPrefix));

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
    // #239: AN UPLOAD LANDS YOU IN THE FOLDER IT WENT TO, and inside a folder the
    // key column shows the LEAF — the crumb trail carries the path, the way any
    // file browser does. So the full key is no longer one visible substring, and
    // asserting the crumb AND the leaf is strictly stronger than the single
    // `includes` it replaces: it also establishes that we are standing in the
    // right folder, which is what the e2e gate caught this slice getting wrong.
    ok('template uploaded, and the view is standing in its folder',
      await until(page, () => document.body.innerText.includes('approval.md')
                           && [...document.querySelectorAll('button')].some(b => b.textContent.trim() === 'templates')
                           && S.repoPrefix === 'templates/', { timeout: 20000 }));
    await page.setInputFiles('#rfile', { name: 'acme-invoice.txt', mimeType: 'text/plain',
      buffer: Buffer.from('INVOICE\nAcme Corp\nWidgets 1000\nShipping 250.50\nTotal 1250.50\n') });
    await page.fill('#rkey', 'inbox/acme-invoice.txt');
    await page.evaluate(() => window.repoUpload());
    ok('invoice uploaded, in its own folder',
      await until(page, () => document.body.innerText.includes('acme-invoice.txt')
                           && S.repoPrefix === 'inbox/', { timeout: 20000 }));
    // a budget, or the run sits queued (the default is 2,000 tokens/day)
    await apiCall(page, '/api/quota', { method: 'POST', body: { dimension: 'ai.tokens.total', limit: 1000000, window: 'day' } });
    const inv = await apiCall(page, '/api/repo?prefix=inbox/acme-invoice.txt');
    const invId = ((inv.json && inv.json.objects) || []).map(o => o.id)[0];
    ok('invoice id resolved', !!invId);

    // "RUN WORKFLOW…" FROM A DOCUMENT: the form is prefilled, AND the person is
    // taken to it. Reported from outside as "the workflow UI doesn't seem to
    // populate anything you enter from a document in the repository" — and the
    // prefill assertion below has passed for as long as the feature has existed.
    // What was wrong is UX-1 in the sibling surface: the form sits under a table
    // of thirteen definitions, measured at y=1285 with `scrollY` 0 on a 900px
    // viewport, so the click changed nothing anybody could see.
    //
    // THE GATE CALLED `repoRunWorkflow` PROGRAMMATICALLY, WHICH IS NOT WHAT A
    // PERSON DOES. It opens the panel and CLICKS the real button now; the click
    // auto-scrolls to the BUTTON, never to the form, which does not exist yet.
    // The short viewport is what makes the assertion mean anything (UX-1's own
    // lesson, where the first version passed with the scroll removed).
    const vpw = page.viewportSize();
    await page.setViewportSize({ width: vpw.width, height: 700 });
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.evaluate(id => window.repoOpenDetail(id), invId);
    ok('the detail panel opened', await until(page, () => {
      const el = document.getElementById('rdetail'); return !!el && el.innerText.includes('Run workflow'); }, { timeout: 15000 }));
    await page.locator('#rdetail button', { hasText: 'Run workflow' }).click();
    ok('run form opened on process-upload',
      await until(page, () => typeof S !== 'undefined' && S.wfSel === 'process-upload' && !!document.querySelector('#wfi_0'), { timeout: 15000 }));   // S is a top-level const, not window.S
    await page.waitForTimeout(1800);                       // the reveal is a SMOOTH scroll
    ok('…and the run form is ON SCREEN, not below the fold', await page.evaluate(() => {
      const r = document.getElementById('wfform').getBoundingClientRect();
      return r.top >= -2 && r.top < window.innerHeight;
    }), await page.evaluate(() => Math.round(document.getElementById('wfform').getBoundingClientRect().top)
      + ' of ' + window.innerHeight));
    // …and revealing it again while it is visible must not jump: `wfSelect` runs
    // on every re-render of this tab, and a jump per render is its own annoyance
    const wy = await page.evaluate(() => window.scrollY);
    await page.evaluate(() => revealEl('wfform'));
    await page.waitForTimeout(600);
    ok('…and revealing it again while visible does not jump',
      Math.abs(await page.evaluate(() => window.scrollY) - wy) < 4,
      `${wy} -> ${await page.evaluate(() => window.scrollY)}`);
    await page.setViewportSize(vpw);
    await page.waitForTimeout(300);
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
    // The derived documents sit BESIDE the invoice, so the folder view is where
    // they belong — stand in `inbox/` and the leaf names are what is on screen.
    await page.evaluate(() => { S.repoPrefix = 'inbox/'; });
    await goTab(page, 'repository', 'table');
    for (const k of ['acme-invoice.txt.extracted.json', 'acme-invoice.txt.form.md', 'acme-invoice.txt.form.nl.md'])
      ok('derived document listed: inbox/' + k,
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

  // ── 7c. the queue's pictures (QVIZ, issue #184) ─────────────────────────────
  // console-tests.rkt proves the card is wired and that the drawing is ours
  // rather than a chart library's. Only a browser can say that four hand-written
  // SVGs actually render under `script-src 'self'` — and the gate fails on any
  // console error, which is how every other CSP claim in this console was
  // established rather than argued.
  ok('the queue visualization renders on Health', !!(await page.$('#qvcard')));
  const qvSparks = await page.locator('#qvcard svg.qvspark').count();
  ok('…three flow sparklines, one per series', qvSparks >= 3);
  // The grid is every minute in the window, not "the minutes that had rows":
  // a queue that has STOPPED must not draw like one that is busy (QVIZ-7). The
  // suite has run jobs by now, so at least one bar is drawn.
  const qvBars = await page.locator('#qvcard svg.qvspark rect').count();
  ok('…with at least one bar drawn from real rows', qvBars > 0);
  // The LEGEND is unconditional and the BAR is not: an empty queue draws four
  // zeros beside their colours rather than a zero-width rectangle, which keeps
  // the card's shape stable and says what the picture would show. This gate's
  // queue is usually empty by the time it gets here, which is exactly why the
  // two are asserted separately.
  ok('the four states are named with their counts',
    (await page.locator('#qvcard .qvkey').count()) === 4);
  const qvQueued = (await page.locator('#qvcard .qvkey b').allTextContents())
    .reduce((a, x) => a + (parseInt(x, 10) || 0), 0);
  ok('…and the stacked bar is drawn exactly when something is queued',
    (qvQueued > 0) === !!(await page.$('#qvcard svg.qvbar')));
  // QVIZ-6: the refresh is explicit and OFF by default, because the idle clock
  // counts from the last request (#38).
  const qvSel = page.locator('#qvcard select').first();
  ok('auto-refresh is offered and is off', (await qvSel.inputValue()) === '0');

  // QVIZ-3: one job's path opens IN PLACE under the row, so the affordance works
  // on the Admin tab as well as here without either screen owning a region.
  const qvTrailBtn = page.locator('#qcard tbody tr button').first();
  if (await qvTrailBtn.count()) {
    await qvTrailBtn.click();
    await page.locator('#qcard tr.qvtrailrow').first().waitFor({ timeout: 5000 });
    ok('a job trail opens under its own row', !!(await page.$('#qcard tr.qvtrailrow')));
    const pathText = await page.textContent('#qcard tr.qvtrailrow');
    ok('…and says which attempt it is on', /\d+\/\d+/.test(pathText));
    await qvTrailBtn.click();
    ok('…and a second click closes it rather than stacking a copy',
      (await page.locator('#qcard tr.qvtrailrow').count()) === 0);
  } else {
    ok('a job trail opens under its own row (skipped: the queue is empty)', true);
  }

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

  // ── admin + usage: email delivery and notifications (MAIL) ─────────────────
  // `console-tests.rkt` proves the cards are wired, that a blank password box
  // sends no field and that the confirmation token is stripped. Only a browser
  // can say the cards RENDER under `script-src 'self'` — and the gate fails on
  // any console error, which is how every other CSP claim in this console was
  // established rather than argued.
  step('admin: email delivery');
  ok('the email transport card renders in Admin', await goTab(page, 'admin', '#mlcard'));
  ok('…with the notification categories beside it', !!(await page.$('#mlncard')));
  // ABSENCE MEANS OFF at the instance layer, which is the whole of MAIL-14 — so
  // a fresh instance draws every category UNCHECKED. A card that arrived with
  // them ticked would be one upgrade away from mailing everybody.
  const mlBoxes = await page.locator('#mlncard input[type=checkbox][data-cat]').count();
  ok('every category has a switch', mlBoxes === 4, String(mlBoxes));
  const mlOn = await page.locator('#mlncard input[type=checkbox][data-cat]:checked').count();
  ok('…and none is on until an operator names it', mlOn === 0, String(mlOn));
  // The password box is EMPTY even when one is stored, and its placeholder says
  // the stored one is kept: the field cannot show a credential, and a blank box
  // that silently cleared it is the failure doMailSave's own guard prevents.
  eq('the password box never shows a stored credential', await page.inputValue('#mlw'), '');

  step('usage: a person\'s own notifications');
  ok('the notification card renders on Usage', await goTab(page, 'usage', '#mlminecard'));
  ok('…with an address field', !!(await page.$('#mlad')));
  // A PERSON MAY NOT TURN ON WHAT THE INSTANCE HAS NOT ENABLED, so where the
  // only outcome would be a refusal there is no button at all (FEAT-8's locked
  // row). Nothing is enabled at the instance here, so every row is in that state.
  const mlEnableBtns = await page.locator('#mlminecard tbody button').count();
  ok('no button is offered where the only outcome is a refusal', mlEnableBtns === 0,
     String(mlEnableBtns));

  // A CONFIRMATION TOKEN IS TAKEN OUT OF THE ADDRESS BAR, and only a browser can
  // say so: `/activate` already strips its own, for the reason a URL is pasted
  // into chat, logged by proxies and kept in history. The token below is
  // nonsense on purpose — what is asserted is that it does not SURVIVE in the
  // URL, not that it verifies.
  step('usage: a confirmation token does not stay in the URL');
  await page.evaluate(() => {
    history.replaceState(null, '', location.pathname + '?verify_email=tk_notarealtoken#/usage');
  });
  await page.evaluate(() => window.claimVerifyToken());
  const urlAfter = await page.evaluate(() => location.href);
  ok('the token is gone from the address bar', !urlAfter.includes('tk_notarealtoken'), urlAfter);
  ok('…and the destination is kept', urlAfter.includes('#/usage'), urlAfter);
  ok('…and it was stashed for the request', await page.evaluate(() => S.verifyEmail) === 'tk_notarealtoken');
  // Put it back, so nothing later in this run is holding a token that will be
  // spent on the next render pass — a fixture that changes global state restores
  // it, which this gate has paid for once already.
  await page.evaluate(() => { S.verifyEmail = null; });

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
