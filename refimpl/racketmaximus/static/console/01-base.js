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
// The table is never cleared: entries are a closure each, a render pass adds a
// few dozen, and dropping them would risk unbinding an element still on screen
// from a partial re-render. A long session accumulates a few thousand — tens of
// kilobytes, against the certainty of a live button going dead.
const HANDLERS = [];
function H(fn){ HANDLERS.push(fn); return HANDLERS.length - 1; }
for (const evname of ['click','input','change','keydown']) {
  document.addEventListener(evname, (ev) => {
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
  i18n: {enabled:true, default:'en', available:['en']}, me:null, tab:'chat', model:null, features:{}, featRows:[], instFeat:null, newToken:null, home:'login', forceLogin:false, betaChallenge:null, betaSub:'prospects', exp:null, wfSel:null, wfSpec:null, wfRun:null, wfPoll:0,
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

async function api(path, {method='GET', body=null}={}){
  // issue #38: the client's idle clock counts from the last REQUEST, never from
  // the last mouse move. The server measures requests, so a timer driven by
  // pointer activity would cheerfully show a live session the server had already
  // expired — the one failure mode an inactivity warning must not have.
  S.lastReq = Date.now();
  const headers = {'X-Telemachus-Locale': S.lang};
  if (S.token) headers['Authorization'] = 'Bearer '+S.token;
  if (body) headers['Content-Type'] = 'application/json';
  const res = await fetch(path, {method, headers, body: body?JSON.stringify(body):null});
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

