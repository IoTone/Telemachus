// ---- the command palette and the keyboard (issue #182) ----------------------
// There was no keyboard route to anything in this console: every action was a
// click, including moving between fifteen tabs.
//
// IT HOOKS THE EXISTING DELEGATED keydown PATH, which the issue asks for by
// name. 01-base.js registers one document listener per event type at load; a
// second one for a global shortcut would start the handler-leak and
// double-fire risks over again. `paletteKey` is called from inside that
// listener, BEFORE the `closest('[data-h-keydown]')` lookup — a global shortcut
// is not about an element, so an element-scoped dispatch cannot carry it.
//
// WHAT IT MUST NOT DO is swallow a key somebody is typing. The rule is one
// predicate (`palTyping`), and the asymmetry it produces is deliberate:
// Cmd/Ctrl+K works everywhere, INCLUDING in a text field, because a held
// modifier is unambiguous; a bare `?` opens the shortcut list only when focus
// is NOT in a field, because otherwise it eats a question mark.

// PLATFORM DETECTION, NOT A HARDCODED Cmd. `userAgentData.platform` where it
// exists, `navigator.platform` otherwise — and the LABEL follows the detection,
// or the hint is wrong on two platforms out of three, which is worse than no
// hint.
const PAL_MAC = /mac|iphone|ipad|ipod/i.test(
  (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || '');
function palMod(ev){ return PAL_MAC ? ev.metaKey : ev.ctrlKey; }
function palModLabel(){ return PAL_MAC ? '⌘' : 'Ctrl+'; }

function palTyping(){
  const el = document.activeElement;
  if (!el) return false;
  const tag = (el.tagName || '').toLowerCase();
  return tag === 'input' || tag === 'textarea' || tag === 'select' || el.isContentEditable === true;
}

// ---- what the palette offers ------------------------------------------------
// Three groups, in the issue's own order. `run` is a closure per item, and the
// palette activates by INDEX into the rendered list — which is also what the
// arrow keys move through, so there is one notion of "the selected thing".
//
// A handful of actions per tab, and only ones that already exist as a function
// here: an entry that merely looks plausible would be a button that 404s. The
// map is deliberately small — a palette that lists everything is a menu.
const PAL_ACTIONS = {
  notes:      [['palnewnote',   () => { S.noteEdit = null; edReset('note', '', 'nb'); go('notes'); }]],
  documents:  [['palnewdoc',    () => { S.docEdit = null; edReset('doc', '', 'dc'); go('documents'); }]],
  repository: [['palupload',    () => go('repository')]],
  workflows:  [['palruns',      () => go('workflows')]],
  health:     [['palrefresh',   () => renderTab()]],
  admin:      [['palrefresh',   () => renderTab()]]
};
function palStaticItems(){
  const out = [];
  for (const tab of visibleTabs())
    out.push({ kind: 'tab', label: t(tab), hint: t('paltab'), run: () => go(tab) });
  // #183: an action available on every tab, because the question "how does this
  // work" is not about the tab you happen to be on.
  if (typeof helpBlocked === 'function' && !helpBlocked())
    out.push({ kind: 'action', label: t('helptitle'), hint: t('palaction'),
               run: () => helpOpen() });
  for (const [key, fn] of (PAL_ACTIONS[S.tab] || []))
    out.push({ kind: 'action', label: t(key), hint: t('palaction'), run: fn });
  return out;
}
function palMatch(items, q){
  if (!q) return items;
  const needle = q.toLowerCase();
  return items.filter(x => (x.label || '').toLowerCase().indexOf(needle) >= 0);
}
// Records come from `GET /api/search`, which already answers across notes,
// repository objects and knowledge-graph entities with the per-row `can?`
// filter — so the palette cannot offer a record its user may not read, by
// construction rather than by a check here.
//
// The sequence counter is renderTab()'s rule: two searches can be in flight and
// the SLOWER one would otherwise overwrite the newer list.
let palSeq = 0;
async function palSearch(q){
  const seq = ++palSeq;
  if (!q || q.length < 2) { S.pal.records = []; palPaint(); return; }
  const r = await api('/api/search?q=' + encodeURIComponent(q));
  if (seq !== palSeq || !S.pal.open) return;
  const rows = (r.ok && r.json && r.json.results) ? r.json.results : [];
  S.pal.records = rows.slice(0, 8).map(x => ({
    kind: 'record',
    label: x.title || x.id || '',
    hint: t('palrecord').replace('{type}', x.type || ''),
    run: () => {
      // Jump to where the record LIVES. The search result's own type is what
      // says which tab that is; an entity belongs to the Knowledge tab.
      if (x.type === 'entity') go('knowledge');
      else if (x.type === 'note') go('notes');
      else go('repository');
    }
  }));
  palPaint();
}

// ---- the overlay ------------------------------------------------------------
function palItems(){
  const q = S.pal.q || '';
  return palMatch(palStaticItems(), q).concat(S.pal.records || []);
}
function palPaint(){
  const box = document.getElementById('palette');
  if (!box) return;
  const items = palItems();
  if (S.pal.sel >= items.length) S.pal.sel = Math.max(0, items.length - 1);
  const list = items.map((x, i) => `<li class="${i === S.pal.sel ? 'sel' : ''}"
      data-h-click="${Hk(() => palRun(i))}">
      <span class="pal-k">${esc(x.label)}</span>
      <span class="pal-h muted">${esc(x.hint || '')}</span></li>`).join('')
    || `<li class="pal-none muted">${esc(t('palnone'))}</li>`;
  const ul = document.getElementById('pallist');
  if (ul) { ul.innerHTML = list; return; }       // typing: only the list moves
  box.innerHTML = `<div class="pal-box">
    <input id="palq" autocomplete="off" spellcheck="false"
      placeholder="${esc(t('palplaceholder'))}" value="${esc(S.pal.q || '')}"
      data-h-input="${Hk((el) => { S.pal.q = el.value; S.pal.sel = 0; palPaint(); palSearch(el.value); })}"
      data-h-keydown="${Hk((el, ev) => palInputKey(ev))}">
    <ul id="pallist">${list}</ul>
    <div class="pal-foot muted">${esc(t('palfoot'))}</div></div>`;
}
function palOpen(){
  S.pal = S.pal || {};
  S.pal.open = true; S.pal.q = ''; S.pal.sel = 0; S.pal.records = [];
  const box = document.getElementById('palette');
  if (!box) return;
  box.hidden = false; box.innerHTML = '';
  palPaint();
  const q = document.getElementById('palq');
  if (q) q.focus();
}
function palClose(){
  S.pal = S.pal || {}; S.pal.open = false;
  const box = document.getElementById('palette');
  if (box) { box.hidden = true; box.innerHTML = ''; }
}
function palRun(i){
  const items = palItems();
  const x = items[i];
  palClose();
  if (x && typeof x.run === 'function') x.run();
  return false;
}
function palMove(d){
  const n = palItems().length;
  if (!n) return;
  S.pal.sel = (S.pal.sel + d + n) % n;
  palPaint();
}
function palInputKey(ev){
  if (ev.key === 'ArrowDown') { ev.preventDefault(); palMove(1); return false; }
  if (ev.key === 'ArrowUp')   { ev.preventDefault(); palMove(-1); return false; }
  if (ev.key === 'Enter')     { ev.preventDefault(); return palRun(S.pal.sel); }
  if (ev.key === 'Escape')    { ev.preventDefault(); palClose(); return false; }
}
// ---- the `?` overlay --------------------------------------------------------
// A palette nobody knows about is a palette nobody uses, which is the issue's
// own note. The list is what is really bound, not what would be nice: every row
// here is a key this console actually handles.
function palHelp(on){
  const box = document.getElementById('shortcuts');
  if (!box) return;
  if (!on) { box.hidden = true; box.innerHTML = ''; return; }
  const rows = [
    [palModLabel() + 'K', t('palhpalette')],
    ['?',                 t('palhhelp')],
    [palModLabel() + '/',  t('palhdocs')],
    ['Esc',               t('palhesc')],
    ['Enter',             t('palhenter')],
    ['Shift+Enter',       t('palhshift')]
  ];
  box.hidden = false;
  box.innerHTML = `<div class="pal-box">
    <h3 style="margin:0 0 8px">${esc(t('palhtitle'))}</h3>
    <table>${rows.map(([k, d]) =>
      `<tr><td class="mono" style="width:9em">${esc(k)}</td><td>${esc(d)}</td></tr>`).join('')}</table>
    <div class="pal-foot muted">${esc(t('palhclose'))}</div></div>`;
}
function palHelpOpen(){ return !(document.getElementById('shortcuts') || { hidden: true }).hidden; }

// The one entry point the delegated listener calls. Answers true when it has
// taken the key, so the element dispatch below it is skipped.
function paletteKey(ev){
  if (!S.me) return false;                       // no shell, no shortcuts
  if (palMod(ev) && (ev.key === 'k' || ev.key === 'K')) {
    ev.preventDefault();
    if (S.pal && S.pal.open) palClose(); else { palHelp(false); palOpen(); }
    return true;
  }
  if (ev.key === 'Escape') {
    if (palHelpOpen()) { palHelp(false); return true; }
    if (S.pal && S.pal.open) { palClose(); return true; }
    return false;                                 // let Esc mean what it meant
  }
  // A bare `?` only when nothing is being typed into — otherwise it eats a
  // question mark, which is the one way a help shortcut can make a console
  // worse than it was.
  if (ev.key === '?' && !palMod(ev) && !ev.altKey && !palTyping()) {
    ev.preventDefault();
    palHelp(!palHelpOpen());
    return true;
  }
  return false;
}
