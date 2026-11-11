// ---- event delegation (issue #27) -------------------------------------------
// Every handler in this file used to be an inline `data-h-click="${H((el,ev)=>…)}"` attribute, which
// forced the console's Content-Security-Policy to keep `script-src
// 'unsafe-inline'` — and 'unsafe-inline' is precisely what lets an injected
// script tag run. Attributes cannot carry a nonce, so the attributes had to go.
// (#110 r6 moved this script out of index.html into static/console/*.js, so the
// per-request nonce that used to authorize it is gone as well: the console's
// policy is a plain `script-src 'self'`, which a same-origin file already
// satisfied. test/console-tests.rkt pins that the shell has no inline block and
// that the files on disk are exactly the ones it loads.)
//
// The transform keeps the call expressions exactly where they were readable:
// a render writes `data-h-click="${H(()=>doThing(row.id))}"`, H parks the closure
// and returns its index, and ONE listener per event type dispatches to it. The
// arguments stay real values instead of being escaped into a string and parsed
// back out, which also removed a class of quoting bug — a note title with an
// apostrophe used to break its own button.
//
// `this` inside a converted handler is the element (`el`), and `event` is `ev`;
// a handler that returns false still suppresses the default action. One real
// behaviour change: only the NEAREST element with a handler for that event runs,
// where inline attributes on nested elements would each fire as the event bubbled.
// The console has no nested clickable regions that relied on that.
// THE TABLE IS SWEPT IN GENERATIONS, and the estimate that used to be here was
// measured and found wrong by about fifty times (#185).
//
// It said: "entries are a closure each, a render pass adds a few dozen… a long
// session accumulates a few thousand — tens of kilobytes, against the certainty
// of a live button going dead." The first half was right for NAVIGATION and
// right for an empty instance. What it did not account for:
//
//   • these cards grow with ROWS. Measured per render pass: Health is
//     `6 + 2·executors + 1·queue-rows` and Admin 19 more — 6/pass on an empty
//     box, 45/pass with six workers and a full queue page.
//   • #184 added an AUTO-REFRESH. At 15 s, a 30-worker fleet and a full page is
//     ~91 a pass, 21,800 an hour, ~175,000 over a shift — and each entry closes
//     over its row, so it retains the row's data too, not just a function.
//
// So they are swept, and the sweep is RANGE-BASED rather than generational for
// one specific reason: `H()` is also called BETWEEN passes — the command palette
// and the help overlay write their markup when they OPEN (#182, #183), and
// `jobTrail`, `kgOpen` and `repoOpenDetail` each register on a click. Those
// elements are on screen while no render pass is running, and a scheme that
// swept everything older than N passes would take the Send button out from under
// somebody typing into the help overlay while the auto-refresh ticked — which is
// exactly the "live button going dead" the old comment was protecting against,
// made reachable by the timer.
//
// So there are TWO registrations. `H()` is swept; `Hk()` is kept for ever, and
// the overlays use it. `hPassStart()`/`hPassEnd()` bracket a render pass, and
// only `H()` entries created INSIDE a bracket are freed — once two further
// passes have completed, so the DOM on screen and the two passes behind it are
// always live.
//
// THE BRACKET HAS TO CLOSE WHEN THE PASS FINISHES PAINTING, not when the next
// one starts, and the first version of this got that wrong: with the range
// closed at the next `hPassStart()`, "between passes" fell INSIDE the previous
// pass's range, so the palette's own input was swept two passes after it opened.
// The e2e gate caught it on its first run, which is the whole reason that
// assertion exists. Both brackets are closed in a `finally`, because both render
// functions return early — superseded mid-flight, or on the sign-in screen — and
// a range left open would swallow every later registration.
//
// `Hk()` is belt and braces on top of that, for the one race the bracket cannot
// close: an overlay opened by a keystroke WHILE a pass is awaiting its fetches
// would otherwise be tagged as part of that pass. Six call sites, all in the two
// overlay files, against a Send button dying under somebody typing.
//
// What this does NOT reclaim, stated rather than implied: the array's LENGTH.
// Freed slots become holes so the closures and their rows are collectable, but
// the slots remain, because the index is the identity an element already holds.
// That is 175,000 empty slots over the shift above — about a megabyte — against
// the tens of megabytes the closures were.
const HANDLERS = [];
function H(fn){ HANDLERS.push(fn); return HANDLERS.length - 1; }
// Registered OUTSIDE the sweep, by name rather than by timing: an overlay that
// the shell keeps on screen while render passes run behind it.
function Hk(fn){ const i = H(fn); H_KEPT.add(i); return i; }
const H_KEPT = new Set();
// [start, end) of recent COMPLETED render passes, oldest first; and the open
// pass's start, or -1 when no pass is painting.
const H_PASSES = [];
let H_OPEN = -1;
// The brackets NEST — `render()` opens one and then awaits `renderTab()`, which
// opens its own — so they are depth-counted. Without this the inner `hPassEnd()`
// closed the OUTER range and the outer `finally` became a no-op, which left any
// registration made after `await renderTab()` outside every bracket. Nothing is
// registered there today; the counter is what stops that from being load-bearing.
let H_DEPTH = 0;
const H_KEEP = 2;                       // completed passes kept beyond the open one
function hPassStart(){ if (H_DEPTH++ === 0) H_OPEN = HANDLERS.length; }
function hPassEnd(){
  if (H_DEPTH > 0) H_DEPTH--;
  if (H_DEPTH > 0) return;              // an inner bracket closing: not the pass
  if (H_OPEN >= 0 && HANDLERS.length > H_OPEN) H_PASSES.push([H_OPEN, HANDLERS.length]);
  H_OPEN = -1;
  while (H_PASSES.length > H_KEEP) {
    const [a, z] = H_PASSES.shift();
    // a hole, not a splice: the index IS the identity, and an element still
    // holding a swept one reaches `typeof fn !== 'function'` in the dispatcher
    // below and does nothing, which is what a bad index has always done.
    for (let i = a; i < z; i++) if (!H_KEPT.has(i)) HANDLERS[i] = undefined;
  }
}

// A REGION THAT OUTLIVES THE PASS THAT PAINTED IT NEEDS A SLOT, NOT A BRACKET.
//
// The sweep's premise is that "the DOM on screen and the two passes behind it
// are always live". That holds for a whole tab, which `renderTab()` replaces
// wholesale. It is FALSE for any region that is painted once and then left
// alone while passes run — and there are two kinds:
//
//   the SHELL, because `go()` calls only `renderTab()`, so one `appShell()`
//   paint stays on screen across every later tab change; and
//
//   the UN-SWAPPED SIBLINGS OF A PARTIAL UPDATE. This is the one that bit
//   twice. `cardSwap` opened a bracket, so every refresh counted as a pass —
//   and the Jobs tab's submit form, painted by the tab render and never
//   swapped, was swept after two refreshes. Reported from outside: "if I click
//   on refresh, I can no longer submit a chat from the jobs page". A live poll
//   makes one click enough, because the tick is the second pass.
//
// So a long-lived region goes in a NAMED SLOT: its handlers are kept out of the
// sweep, and the generation it replaces is freed in the same breath. One slot
// holds at most one generation, so this is bounded — `hShell` was the first
// instance and `cardSwap` is the general one.
//
// What it does NOT free, stated: the last generation in a slot whose region has
// been replaced by a TAB render rather than by another swap of the same card.
// That is one card's worth of closures per card id, freed the next time that
// card is swapped. Making a tab render clear every card slot would be wrong —
// the shell's slot must survive exactly that.
// The delegated event types, in ONE place: the listener loop below installs one
// per name, and `hIndicesIn` scans markup for the same set. Two lists would
// disagree the day a fifth event was added, and the failure would be a region
// whose handlers are silently not kept.
const H_EVENTS = ['click','input','change','keydown'];

// Which handler indices a piece of MARKUP actually references. Reading them off
// the markup rather than off a range of the table is what makes a slot immune to
// interleaving: a tab render that completes while a swap is awaiting its fetch
// registers handlers that would fall inside a naive [start, end) range and be
// wrongly kept — or, worse, freed on the next swap.
function hIndicesIn(html){
  const out = [];
  const re = new RegExp('data-h-(?:' + H_EVENTS.join('|') + ')="(\\d+)"', 'g');
  let m; while ((m = re.exec(html))) out.push(+m[1]);
  return out;
}

const H_SLOTS = new Map();              // key -> the indices currently kept
function hKeepSlot(key, html){
  const prev = H_SLOTS.get(key) || [];
  const now = hIndicesIn(html);
  // the new generation is kept BEFORE the old is freed, so an index that appears
  // in both (nothing produces one today, but a future painter might reuse one)
  // survives rather than being freed out from under the markup that names it.
  for (const i of now) H_KEPT.add(i);
  for (const i of prev) if (!now.includes(i)) { H_KEPT.delete(i); HANDLERS[i] = undefined; }
  H_SLOTS.set(key, now);
  return html;
}
// the shell is just the first slot
function hShell(paint){ return hKeepSlot('shell', paint()); }

// A PROMPT BAR THAT GROWS WITH WHAT YOU TYPE.
//
// The chat and agent prompts were `rows="3"` and fixed, so anything longer than
// three lines was typed into a slot you could not see the top of — and the one
// place in this console where people paste a lot of text.
//
// It measures `scrollHeight`, and that is NOT the same rule as the editor's
// `edRows`, which counts newlines. The editor turns soft wrap OFF so its line
// gutter can stay aligned (ED-6), which makes a line count exact there and
// wrong here: a prompt bar wraps, so a wrapped line occupies several visual rows
// that no newline count can see. Two functions with different contracts are not
// `executor-can-run?`'s drift — that is about two copies of ONE rule — and a
// shared implementation would have to be the wrong one for one of them.
//
// It is CAPPED. An unbounded bar pushes Send off the bottom of the screen on a
// long paste, which is worse than a scrollbar: the control you are reaching for
// has to stay reachable.
const GROW_MAX_ROWS = 14;
function growTA(el){
  if(!el) return;
  try {
    const cs = getComputedStyle(el);
    const line = parseFloat(cs.lineHeight) || 20;
    const pad = (parseFloat(cs.paddingTop)||0) + (parseFloat(cs.paddingBottom)||0)
              + (parseFloat(cs.borderTopWidth)||0) + (parseFloat(cs.borderBottomWidth)||0);
    const max = Math.round(line * GROW_MAX_ROWS + pad);
    // height must be released before scrollHeight is read, or it only ever grows
    el.style.height = 'auto';
    const want = el.scrollHeight;
    el.style.height = Math.min(want, max) + 'px';
    el.style.overflowY = want > max ? 'auto' : 'hidden';
  } catch(e){}
}
// Called after a render so a PREFILLED prompt is sized on arrival — the console
// ships both prompts with example text, which is exactly the case a grow-on-input
// handler never sees.
function growAll(){ document.querySelectorAll('textarea.grow').forEach(growTA); }

// A CHARACTER COUNT BESIDE A PROMPT FIELD, AGAINST THE SERVER'S OWN LIMIT.
//
// #231 built this for Translate, where past the limit the answer comes back
// WRONG rather than failing, so the number has to be visible before the button
// is pressed. Reported from outside that Chat wants it too — and it does, for
// the same reason and not a cosmetic one: a chat prompt over the window is
// truncated oldest-first by the model server, which silently drops the
// instruction and answers about what is left.
//
// ONE implementation, three fields. Two copies of a budget is LIVE-IN's shape,
// and the limit is never a literal here: it is whatever the server reported on
// the read the tab already makes (`max_chars` on `/api/translate` and on
// `/api/ai/model`), so the count in the browser cannot disagree with the rule
// that refuses.
function charCountText(n, max){
  if (!max) return '';
  return t('trcount').replace('{n}', n.toLocaleString()).replace('{max}', max.toLocaleString());
}
function charCount(srcId, outId, max){
  const el = document.getElementById(srcId), out = document.getElementById(outId);
  if (!el || !out) return;
  const n = el.value.length;
  out.textContent = charCountText(n, max) + (max && n > max ? ' — ' + t('troverlimit') : '');
  out.style.color = (max && n > max) ? 'var(--bad)' : '';
}
// Called after a render for the same reason `growAll` is: both prompts ship
// with example text, which a count-on-input handler never sees.
function countAll(){
  const m = (S.model && S.model.max_chars) || 0;
  charCount('trsrc', 'trcount', S.trMax || 0);
  charCount('cp', 'cpcount', m);
  charCount('ap', 'apcount', m);
}

// REFRESH ONE CARD IN PLACE, WITHOUT A TAB RE-RENDER.
//
// `renderTab()` paints a `…` placeholder BEFORE it awaits its view, which is
// right for a tab change and wrong for a refresh: using it as one makes the
// whole tab blank and repaint on every tick, and on Admin it also re-fires the
// eight requests that tab opens with. That is what a 2s jobs poll and a queue
// page click both did — the "reloads the entire page" this replaces.
//
// It is BRACKETED, and that is not optional: the markup it paints registers
// handlers through `H()`, and a registration made outside a bracket is never
// swept, so a card refreshing every 2.5s would accumulate closures for the life
// of the session — the leak #185 bounded, reintroduced by the thing meant to be
// cheaper than a render. With the bracket the card's handlers live for two
// further passes, by which time this card's DOM has been replaced by a later
// refresh or by a tab render.
//
// `build()` may answer null to decline the swap (a failed fetch), and the
// element is looked up AGAIN after the await: the tab may have changed under it,
// and writing into a card that is no longer on screen would be painting over
// whatever replaced it.
async function cardSwap(id, build){
  if(!document.getElementById(id)) return false;
  // NOT a bracket. A bracket makes every refresh a render pass, and the
  // un-swapped parts of the tab — the Jobs tab's submit form, the filters above
  // a table — were painted by the tab render and are swept two refreshes later.
  // That is the bug this function shipped with, reported as "if I click on
  // refresh, I can no longer submit a chat from the jobs page". A slot keeps
  // only what this card's own markup names, so a refresh cannot reach anything
  // it did not paint.
  const html = await build();
  if(html == null) return false;                // a failed fetch leaves the card alone
  const cur = document.getElementById(id);      // the tab may have changed under us
  if(!cur) return false;
  cur.outerHTML = hKeepSlot('card:' + id, html);
  return true;
}

for (const evname of H_EVENTS) {
  document.addEventListener(evname, (ev) => {
    // #182: the command palette and the `?` overlay are GLOBAL shortcuts, so
    // they are not about an element and an element-scoped dispatch cannot
    // carry them. They hook this listener rather than adding a second one —
    // a second document listener is where the handler-leak and double-fire
    // risks this dispatcher exists to remove would start over. It runs BEFORE
    // the lookup and says whether it took the key.
    if (evname === 'keydown' && typeof paletteKey === 'function' && paletteKey(ev)) return;
    // #183: the help overlay is a global shortcut too, through the same door.
    // AFTER the palette's, because the palette owns Esc when ITS overlay is
    // open and `helpKey` claims Esc only when its own is — two handlers both
    // taking Esc unconditionally is how one of them starts closing the other's.
    if (evname === 'keydown' && typeof helpKey === 'function' && helpKey(ev)) return;
    const el = ev.target && ev.target.closest && ev.target.closest('[data-h-' + evname + ']');
    if (!el) return;
    const fn = HANDLERS[+el.getAttribute('data-h-' + evname)];
    if (typeof fn !== 'function') return;
    // `return false` used to stop an <a href="#"> from navigating, because that is
    // what a false return from an inline handler means. A delegated listener's
    // return value is ignored by the browser, so honour it here or every one of
    // those links starts jumping to the top of the page.
    if (fn(el, ev) === false) ev.preventDefault();
  });
}

const S = { token: localStorage.getItem('tmx_token')||null, lang: localStorage.getItem('tmx_lang')||'en',
  i18n: {enabled:true, default:'en', available:['en']}, me:null, tab:'chat', model:null, features:{}, featRows:[], instFeat:null, newToken:null, home:'login', forceLogin:false, betaChallenge:null, betaSub:'prospects', exp:null, wfSel:null, wfSpec:null, wfRun:null, wfPoll:0, jobPoll:0, trPoll:0, trJobs:[], trSending:false, qPoll:0, qTotal:0, qKinds:[],
  // the AbortController of a stream in flight, or null: the guard and the
  // pending state in one, as S.signingIn is for the sign-in button (#174)
  chatAbort:null, agentAbort:null,
  // the Workers card's figure window, in hours (#178) — the server clamps to 720
  wkHours:24 };
// The console's strings are no longer here. English is the source of truth in
// static/ui-strings.json (a JSON surface the extractor folds into locales/en.json
// under the `ui.` namespace); every other language is a catalog under locales/,
// produced and reviewed with the Localization Manager like the server's strings.
// The console fetches its catalog pre-auth from GET /api/i18n/catalog, already
// resolved through the fallback chain, so one fetch per language is enough.

// The Mentor mark (docs/design/brand/) — a helm whose two diamond eyes are an
// owl's and whose nasal guard is the stem of a T. The eyes CROSS the guard, so
// the three holes are one continuous void: two diamonds threaded on a line.
// Three size-specific drawings, not one scaled — going small the diamonds open
// up and the guard widens, or the face silts shut. The gold brow bar that
// completes the T needs a second colour, so it lives only in the asset files;
// here the mark is one path inheriting currentColor.
//
// fill-rule is NONZERO with every hole wound counter-clockwise. It matters:
// under evenodd two overlapping holes CANCEL, so every eye/guard crossing would
// fill back in and weld the face shut.
const MARK_SIL = 'M13 53 V31 a19 19 0 0 1 38 0 V53 Z';
const MARK_D = {
  16: 'M18.5 34 L26 41.5 L33.5 34 L26 26.5 Z M30.5 34 L38 41.5 L45.5 34 L38 26.5 Z M28.5 30 v23 h7 V30 Z',
  32: 'M20 34 L26.5 40.5 L33 34 L26.5 27.5 Z M31 34 L37.5 40.5 L44 34 L37.5 27.5 Z M29 26 v27 h6 V26 Z',
  64: 'M20.5 34 L26.5 40 L32.5 34 L26.5 28 Z M31.5 34 L37.5 40 L43.5 34 L37.5 28 Z M29.5 26 v27 h5 V26 Z'
};
function markSVG(px){
  const d = MARK_D[px <= 20 ? 16 : px <= 40 ? 32 : 64];
  return `<svg class="tmx-mark" viewBox="0 0 64 64" width="${px}" height="${px}" aria-hidden="true" focusable="false">
    <path d="${MARK_SIL} ${d}" fill="currentColor" fill-rule="nonzero"/></svg>`;
}
S.cat = {};
const t = k => S.cat['ui.'+k] || k;
async function loadCatalog(){
  const r = await api('/api/i18n/catalog?locale='+encodeURIComponent(S.lang));
  if (r.ok && r.json && r.json.messages) { S.cat = r.json.messages; S.catLocale = S.lang; document.documentElement.lang = S.lang; }
}

// Instance branding (Admin > Branding). Loaded before auth, because the sign-in
// screen has to render it for someone who has no token yet. Defaults keep the
// shipped identity, so an untouched instance still has a name.
S.brand = {title:'TMach', tagline:'', logo:'', logoUrl:''};
// Mint a bundle ticket and open the plugin's page (issue #43). The window is
// opened FIRST, synchronously: a popup blocker refuses a window opened after an
// await, and the user's click is what it wants to see.
async function pluginOpen(id){
  const w = window.open('', '_blank');
  const r = await api('/api/x/'+encodeURIComponent(id)+'/bundle-ticket', {method:'POST', body:{}});
  if(r.ok && r.json && r.json.url){ if(w) w.location = r.json.url; else window.location = r.json.url; }
  else { if(w) w.close(); toast((r.json&&r.json.error)||'error'); }
}
window.pluginOpen = pluginOpen;

async function loadBranding(){
  const r = await api('/api/branding');
  if(r.ok && r.json) S.brand = Object.assign(S.brand, r.json);
  document.title = S.brand.title || 'TMach';
  applyTheme(S.brand.theme);
}
// The console's palette, from the branding document's theme tokens — the SAME
// vocabulary the beta funnel uses (brand, brandInk, bg, surface, ink, muted,
// radius, mode, fontBody), so a customer's palette is written once and worn by
// both. /api/branding is public and this runs on every render pass, so the
// sign-in screen is themed too, and a company's own theme lands the moment its
// bearer resolves (TEN-2d: by Host before that).
//
// Values are validated by the server and re-checked here with the same pattern —
// they go into a style property, so a token is a value, never a declaration.
const THEME_HEX = /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/;
function themeOk(v){ return typeof v==='string' && THEME_HEX.test(v.trim()); }
// A ground tinted toward the ink: the console needs a second panel and a hairline
// that the token set does not spell out, and deriving them keeps a theme to the
// few decisions an integrator actually wants to make. color-mix is ignored by a
// browser that lacks it, which falls back to the stylesheet's own value.
function mix(a,b,pct){ return `color-mix(in srgb, ${a} ${pct}%, ${b})`; }
function applyTheme(th){
  const r = document.documentElement.style;
  const KEYS = ['--bg','--panel','--panel2','--line','--fg','--muted','--accent','--accent2','--accent3','--radius','--font'];
  if(!th || typeof th!=='object'){ KEYS.forEach(k=>r.removeProperty(k)); return; }
  const c = (k,d)=> themeOk(th[k]) ? th[k].trim() : d;
  const bg=c('bg','#0b1a2b'), surface=c('surface','#12253a'), ink=c('ink','#f2ede1');
  const muted=c('muted','#93a4b8'), brand=c('brand','#6fa0d1'), brandInk=c('brandInk','#ffffff');
  const light = th.mode==='light';
  r.setProperty('--bg', bg);
  r.setProperty('--panel', surface);
  r.setProperty('--panel2', mix(ink, surface, light?6:8));      // inputs, table stripes
  r.setProperty('--line', mix(ink, surface, light?18:16));      // hairlines
  r.setProperty('--fg', ink);
  r.setProperty('--muted', muted);
  r.setProperty('--accent', brand);
  // A button ground is the brand deepened toward whichever side of the theme is
  // dark — measured, not taken from `mode`: the background on a dark theme, the
  // ink on a light one, where mixing toward the background would wash the brand
  // out. 50% is BUTTON-MIX in domain/branding/branding.rkt, which checks the
  // label's contrast against exactly this ground.
  const deep = darkerOf(ink, bg);
  r.setProperty('--accent2', mix(brand, deep, 50));             // button ground
  r.setProperty('--accent3', mix(brand, deep, 65));             // …and its hover
  r.setProperty('--btn-ink', brandInk);
  if(/^[0-9]{1,2}px$/.test(String(th.radius||''))) r.setProperty('--radius', th.radius);
  r.setProperty('--font', fontStack(th.fontBody));
}
// The instance localization policy. Public, and fetched on EVERY render pass —
// including for a signed-in user, who otherwise would never see an operator turn
// the switcher off. Applying it is what settles S.lang: a stored per-browser
// preference only wins while the operator allows switching AND still ships that
// catalog. Otherwise the instance default is the answer, which is the whole point
// of the setting — a Japanese instance greets a first-time visitor in Japanese.
async function loadI18n(){
  const r = await api('/api/config');
  if(r.ok && r.json){
    if(r.json.localization) S.i18n = Object.assign(S.i18n, r.json.localization);
    S.home = r.json.home || S.home;
    S.cfg = r.json;
  }
  const pref = localStorage.getItem('tmx_lang');
  const avail = S.i18n.available || ['en'];
  S.lang = (S.i18n.enabled && pref && avail.indexOf(pref)>=0) ? pref : S.i18n.default;
}
// The lockup: an uploaded logo REPLACES the mark and the wordmark both — an
// operator who supplies their own logo is not asking for ours beside it. The
// trailing dot is ours, so it goes with the mark.
function brandLockup(px){
  if(S.brand.logoUrl)
    return `<img class="tmx-logo" src="${esc(S.brand.logoUrl)}" alt="${esc(S.brand.title)}" style="height:${Math.round(px*1.15)}px">`;
  return `${markSVG(px)}<span>${esc(S.brand.title)}<span class="dot">.</span></span>`;
}
const brandTagline = () => S.brand.tagline || t('tagline');

// The server is the authority; this only decides what to SHOW. A surface the
// caller cannot use is worse than a missing one — it offers work that will 403.
function canPerm(perm){
  const ps = (S.me && S.me.permissions) || [];
  if (ps.includes('*:*') || ps.includes(perm)) return true;
  const [area] = perm.split(':');
  return ps.includes(area + ':*');
}
S.l10n = {locale:'ja', status:'', ns:'', q:'', offset:0};
const esc = s => (''+ (s??'')).replace(/[&<>"]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

// `raw` is a body that is already TEXT and goes out as-is with its own content
// type — `POST /api/notes/import`, whose entire input IS an org file (ORG-11), is
// the one route in this plane shaped that way. It goes through `api()` rather
// than a bare `fetch` so it still stamps the idle clock (#38), carries the
// bearer and the locale, and is read back the same way as everything else.
async function api(path, {method='GET', body=null, raw=null, contentType=null}={}){
  // issue #38: the client's idle clock counts from the last REQUEST, never from
  // the last mouse move. The server measures requests, so a timer driven by
  // pointer activity would cheerfully show a live session the server had already
  // expired — the one failure mode an inactivity warning must not have.
  S.lastReq = Date.now();
  const headers = {'X-Telemachus-Locale': S.lang};
  if (S.token) headers['Authorization'] = 'Bearer '+S.token;
  if (body) headers['Content-Type'] = 'application/json';
  if (raw != null) headers['Content-Type'] = contentType || 'text/plain; charset=utf-8';
  const res = await fetch(path, {method, headers,
    body: raw != null ? raw : (body ? JSON.stringify(body) : null)});
  let json={}; try{ json = await res.json(); }catch(e){}
  return {ok:res.ok, status:res.status, json};
}
function toast(msg, ok=false){ const el=document.getElementById('toast'); el.textContent=msg; el.className='toast show'+(ok?' ok':'');
  setTimeout(()=>el.className='toast',2600); }
function setLang(l){ if(!S.i18n.enabled) return; if((S.i18n.available||[]).indexOf(l)<0) return;
  S.lang=l; localStorage.setItem('tmx_lang',l); render(); }
function setTok(tk){ S.token=tk; localStorage.setItem('tmx_token',tk); }
// issue #118: this used to clear localStorage and call NOTHING, so the bearer it
// discarded stayed valid on the server until it expired — on a shared machine,
// for up to the absolute cap. The revoke is awaited but its failure is ignored on
// purpose: a network error must still sign you out of THIS browser, which is the
// part the person can see, and a token nobody holds any more is the lesser
// problem. Not `await`ed before clearing state either — the request carries the
// token it is revoking, so it has to go out first.
async function logout(){
  const tok = S.token;
  if (tok) { try { await api('/api/logout', {method:'POST'}); } catch (e) {} }
  S.token=null; localStorage.removeItem('tmx_token'); S.me=null; S.forceLogin=false; render();
}
const val = id => document.getElementById(id).value.trim();

// ---- sending a prompt (issues #174, #181) ----------------------------------
// Enter sends, Shift+Enter inserts a newline. `isComposing` (and the 229 that
// older engines report instead) is what keeps this usable in Japanese: the
// Enter that CONFIRMS an IME conversion arrives as an ordinary keydown, and
// sending a half-typed prompt on it would make the console unusable in the
// language it already ships in.
function sendKey(ev, fn){
  if(ev.key!=='Enter' || ev.shiftKey || ev.isComposing || ev.keyCode===229) return;
  ev.preventDefault(); fn(); return false;
}
// One send at a time. The flag is BOTH the guard and the pending state, which
// is the shape `S.signingIn` already has on the sign-in button: without it two
// activations started two streams and the team was billed for both (#174).
// A focused button activates on Enter and Space as well as a click, so this
// never needed a deliberate double-click.
function sendBusy(sendId, stopId, busy){
  const b=document.getElementById(sendId), s=document.getElementById(stopId);
  if(b){ b.disabled=busy; b.textContent = busy ? t('sending') : t('send'); }
  if(s) s.style.display = busy ? '' : 'none';
}
// A stream is abandoned by aborting its fetch: the reader then throws, the
// partial answer stays on screen and is marked, and the guard clears in the
// `finally` — a stop that left the flag set would block every later send.
function stopStream(key){ const ac=S[key]; if(ac) ac.abort(); }


// ---- taking somebody to the thing they just asked for -----------------------
//
// "WHEN YOU CLICK ON DETAILS IT SEEMS LIKE NOTHING HAPPENS" (UX-1), then the
// same report about the workflow run form: "the workflow UI doesn't seem to
// populate anything you enter from a document in the repository". The form was
// populated every time — the e2e gate asserts `object_id` is prefilled and has
// passed for as long as the feature has existed — and it was 385px BELOW THE
// FOLD, behind a table of thirteen definitions. Measured at a 900px viewport:
// `#wfi_0` at y=1285, `scrollY` 0. The click changed nothing anybody could see.
//
// So this is one rule with two askers rather than a second copy of it, which is
// `executor-can-run?`'s drift argument: the half that is easy to get wrong is
// not the scroll, it is WHEN NOT TO. It only moves when the target is not
// already in view, because both callers are re-invoked for reasons that are not
// a fresh request — `repoOpenDetail` after a visibility change, a share and a
// revoke, `wfSelect` whenever the Workflows tab re-renders — and a jump on each
// of those is its own annoyance.
//
// A scroll and not a modal, for UX-1's reasons: neither of these is a dialog,
// both are read alongside the list above them, both have their own Close, and a
// modal means `Hk()`, a focus trap and Esc ordered against the palette's and the
// help overlay's (#182/#183).
//
// `prefers-reduced-motion` is honoured: the point is to arrive, not to glide.
function revealEl(id){
  const el = document.getElementById(id);
  if (!el || !el.firstChild) return;
  try {
    const r = el.getBoundingClientRect();
    if (r.top >= 0 && r.top < (window.innerHeight || 0) * 0.75) return;
    const reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    el.scrollIntoView({ block: 'start', behavior: reduce ? 'auto' : 'smooth' });
  } catch(e) {
    try { el.scrollIntoView(); } catch(e2) {}   // an engine without the options form
  }
}

// ---------- a project is a key PREFIX (#239) ----------
// ONE component, two tabs. The Repository files uploads into a path and the
// Documents tab writes chapters into the same one, so #239's use case — "write
// chapters, build up a report, upload information" — is one project seen from two
// surfaces. A crumb trail drawn twice would drift, which is `executor-can-run?`'s
// rule arriving in the console (and `visibleTabs()`'s, PAL-5).
//
// THE FOLDERS ARE THE SERVER'S ANSWER AND NOT A TREE BUILT FROM THE PAGE. The
// listing is bounded and `can?`-filtered per row, so folders derived from the keys
// on screen would show only the folders this page happens to reach — and would
// show one the caller may not read anything in. `repo-prefixes` answers that
// question directly and says when it had to stop (`truncated`).
//
// `go` is the tab's own navigator, because each one keeps its own prefix in `S`
// and has its own paging to reset.
function pathNav(folders, prefix, go){
  const segs = (prefix || '').split('/').filter(s => s.length);
  const crumbs = [`<button class="btn sm${prefix ? ' ghost' : ''}" data-h-click="${H(() => go(''))}">${esc(t('allpaths'))}</button>`];
  let acc = '';
  segs.forEach(s => {
    acc += s + '/';
    const at = acc;                      // captured per crumb, not the loop's
    crumbs.push(`<span class="muted">/</span><button class="btn sm${at === prefix ? '' : ' ghost'}" data-h-click="${H(() => go(at))}">${esc(s)}</button>`);
  });
  const kids = (folders && folders.prefixes) || [];
  // A plain flex box, NOT `.row`: that one's children are flex COLUMNS, which is
  // what staggered the search button (CSS-1) — a wrapping strip of buttons wants
  // neither the columns nor the bottom margin.
  const strip = s => `<div style="display:flex;flex-wrap:wrap;gap:6px;align-items:center">${s}</div>`;
  const folderStrip = kids.length
    ? strip(kids.map(f => `<button class="btn sm ghost" data-h-click="${H(() => go(f.prefix))}">${esc(f.name)}/</button>`).join(''))
    : '';
  const cut = (folders && folders.truncated)
    ? `<div class="muted" style="font-size:12px;margin-top:4px">${esc(t('foldercut'))}</div>` : '';
  return strip(crumbs.join('')) + folderStrip + cut;
}

// ── a numbered pager, for any listing that offers a window ────────────────────
//
// ONE HOME, TWO ASKERS. The arithmetic — the window around the current page, the
// two ellipses, first and last always reachable, the clamp — is ONE rule, and
// this tree's own line is that two copies of one rule drift. It was written for
// the queue (CARD-4/5) with `qGo`/`qPages`/`QPAGE` baked in, so the notes pager
// would have been a second copy of a computation only the queue's one has a gate
// behind. `pathNav` above takes its `go` the same way and for the same reason.
//
// THE PAGE SIZE IS THE CALLER'S AND IS PASSED IN, not read from a constant here:
// each surface has its own (`QPAGE`, `NPAGE`), each is spelled once in its own
// file and used both to ASK the server and to compute the page count, which is
// what stops a pager offering a page the listing never fills.
//
// `shown` IS THE LENGTH OF THE PAGE AS RENDERED, WHICH IS NOT `size`. Every
// listing here applies `can?` per row after the SQL window (CLS-27), so a page
// can be shorter than its limit with rows still behind it — the "showing x–y of
// n" line therefore reads `shown` and the page COUNT reads `total`, and the two
// disagreeing is the honest report rather than a bug to paper over.
//
// First and last are always offered, so the range is visible even when the
// window is nowhere near either end; the ellipsis is NOT a button, because a
// control whose destination a reader cannot predict is worse than none. The
// strings are the `q*` catalog keys — named for where they first appeared, not
// for the queue, and shared rather than duplicated per surface.
function pagerHTML(o){
  const total = o.total || 0, size = o.size, off = o.offset || 0, go = o.go;
  const pages = Math.max(1, Math.ceil(total / size));
  const cur = Math.min(pages, Math.floor(off / size) + 1);
  const from = total ? off + 1 : 0, to = off + (o.shown || 0);
  const showing = `<span class="muted">${esc(t('qshowing').replace('{from}',from).replace('{to}',to).replace('{total}',total))}</span>`;
  if(pages<=1) return `<p style="margin-top:8px">${showing}</p>`;
  const btn=(label,page,opts)=>{
    const op = opts || {};
    if(op.disabled) return `<button class="btn sm ghost" disabled>${label}</button>`;
    return `<button class="btn sm ${op.active?'':'ghost'}" ${op.title?`title="${esc(op.title)}"`:''}
      data-h-click="${H(()=>go(page))}"${op.active?' aria-current="page"':''}>${label}</button>`;
  };
  // the jump box is honest about its own bounds: a page number outside the range
  // is CLAMPED rather than refused, because the only way to produce one is to
  // type it and the useful answer to "page 900 of 6" is page 6
  const jump = el => { const n = parseInt(el.value,10); if(!isNaN(n)) go(Math.min(Math.max(1,n),pages)); };
  const win=2, nums=[];
  let lo=Math.max(1,cur-win), hi=Math.min(pages,cur+win);
  if(lo>1){ nums.push(btn('1',1,{active:cur===1})); if(lo>2) nums.push(`<span class="muted">…</span>`); }
  for(let p=lo;p<=hi;p++) nums.push(btn(String(p),p,{active:p===cur}));
  if(hi<pages){ if(hi<pages-1) nums.push(`<span class="muted">…</span>`); nums.push(btn(String(pages),pages,{active:cur===pages})); }
  return `<div class="row qpager" style="align-items:center;gap:6px;margin-top:10px;flex-wrap:wrap">
    ${showing}
    <span style="flex:1 1 auto"></span>
    ${btn('«',1,{disabled:cur<=1,title:t('qfirst')})}
    ${btn('‹',cur-1,{disabled:cur<=1,title:t('qprev')})}
    ${nums.join('')}
    ${btn('›',cur+1,{disabled:cur>=pages,title:t('qnext')})}
    ${btn('»',pages,{disabled:cur>=pages,title:t('qlast')})}
    <label style="margin:0 0 0 10px;white-space:nowrap">${esc(t('qjump'))}
      <input type="number" min="1" max="${pages}" value="${cur}" style="width:5.5em;margin-left:6px"
        data-h-change="${H((el)=>jump(el))}"
        data-h-keydown="${H((el,ev)=>{ if(ev.key==='Enter'&&!ev.isComposing){ jump(el); return false; } })}">
      <span class="muted">/ ${pages}</span></label></div>`;
}
