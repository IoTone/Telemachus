// ---- one editor, two surfaces (issue #180) ----------------------------------
// The issue asks to decide up front whether this is Notes-only or the shared
// one, and names the outcome to avoid: "three bare textareas becoming three
// different editors". So it is ONE component, and Notes and Documents both use
// it. What is deliberately NOT converted is the beta funnel's template editor:
// its content is HTML rather than Markdown and it already has a live preview of
// its own (`renderLandingShell(cfg,'preview')`), so folding it in here would
// mean one component serving two different languages and two different previews.
//
// AND THE ENABLING HALF WAS NOT AN EDITOR AT ALL: THERE WAS NO WAY TO EDIT.
// The console could create a note and delete it and nothing else — the body was
// an `<input>`, not even a textarea — and Documents was the same. `PUT
// /api/notes/:id` and `PUT /api/documents/:id` have both existed since the
// routes were written, with `GET …/:id` beside them carrying the body. #113's
// shape in the console: a capability the server has always offered and no
// surface reaches. An editor for a field you can only ever fill in once is
// worth very little, so the edit path lands with it.
//
// NO CDN AND NO VENDORED LIBRARY. `script-src 'self'` with no 'unsafe-inline'
// (#110 r6) blocks a CDN outright, and a vendored editor is third-party code
// shipped to get four features. The Markdown subset below is the one this
// platform's own documents are written in — `docs/book/TRANSLATING.md` already
// requires "headings, lists, pipe tables, fenced code" and nothing more,
// because pandoc has to render the same book in two editions.

// ---- the Markdown subset ----------------------------------------------------
// WHAT MAKES THIS SAFE IS THE ORDER: everything is HTML-escaped FIRST, and the
// rules below then run over already-escaped text and emit a closed set of tags.
// Nothing from the source is ever passed through as markup, so there is no
// sanitiser to get wrong — a `<script>` in a note is `&lt;script&gt;` before any
// rule sees it. The console's CSP is the backstop and not the defence: an
// injected inline handler would be refused by `script-src 'self'` anyway, but a
// preview that depended on that would be one policy change from being a stored
// XSS.
//
// The subset is stated rather than open-ended, and anything outside it renders
// as its own text — which is the honest failure for a preview.
const MD_SCHEMES = /^(https?:\/\/|mailto:|\/|#)/i;
function mdSafeUrl(u){ return MD_SCHEMES.test(u); }
function mdInline(t){
  return t
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>')
    // The url is already escaped, so a quote in it is `&quot;` and cannot close
    // the attribute; `javascript:` fails the allowlist, and an entity-encoded
    // one cannot survive the escape (its `&` is `&amp;` by now).
    .replace(/\[([^\]]*)\]\(([^)\s]+)\)/g, (m, txt, url) =>
      mdSafeUrl(url) ? `<a href="${url}" target="_blank" rel="noopener noreferrer">${txt}</a>` : m);
}
function mdRender(src){
  let s = esc(String(src == null ? '' : src)).replace(/\r\n?/g, '\n');
  // Fenced code comes out first and goes back last, so no inline rule runs
  // inside it — `**bold**` in a code block is not bold, which is the whole
  // point of a code block.
  const code = [];
  s = s.replace(/```[^\n]*\n([\s\S]*?)```/g, (m, body) => {
    code.push(body.replace(/\n$/, ''));
    return '\u0000C' + (code.length - 1) + '\u0000';
  });
  const lines = s.split('\n');
  const out = [];
  let i = 0;
  const isTableSep = (l) => /^\s*\|?[\s:-]*-[\s:|-]*\|?\s*$/.test(l) && l.indexOf('-') >= 0;
  const cells = (l) => l.replace(/^\s*\|/, '').replace(/\|\s*$/, '').split('|').map(c => c.trim());
  while (i < lines.length) {
    const l = lines[i];
    if (/^\u0000C\d+\u0000$/.test(l.trim())) { out.push(l.trim()); i++; continue; }
    if (!l.trim()) { i++; continue; }
    let m;
    if ((m = l.match(/^(#{1,6})\s+(.*)$/))) {
      out.push(`<h${m[1].length}>${mdInline(m[2].trim())}</h${m[1].length}>`); i++; continue;
    }
    if (/^\s*(---+|\*\*\*+|___+)\s*$/.test(l)) { out.push('<hr>'); i++; continue; }
    if (/^\s*&gt;/.test(l)) {                                  // `>` is escaped by now
      const buf = [];
      while (i < lines.length && /^\s*&gt;/.test(lines[i])) { buf.push(lines[i].replace(/^\s*&gt;\s?/, '')); i++; }
      out.push(`<blockquote>${mdInline(buf.join(' '))}</blockquote>`); continue;
    }
    if (l.indexOf('|') >= 0 && i + 1 < lines.length && isTableSep(lines[i + 1])) {
      const head = cells(l); i += 2;
      const body = [];
      while (i < lines.length && lines[i].indexOf('|') >= 0 && lines[i].trim()) { body.push(cells(lines[i])); i++; }
      out.push(`<table><thead><tr>${head.map(c => `<th>${mdInline(c)}</th>`).join('')}</tr></thead>`
        + `<tbody>${body.map(r => `<tr>${r.map(c => `<td>${mdInline(c)}</td>`).join('')}</tr>`).join('')}</tbody></table>`);
      continue;
    }
    if (/^\s*([-*+]|\d+\.)\s+/.test(l)) {
      const ordered = /^\s*\d+\./.test(l);
      const items = [];
      while (i < lines.length && /^\s*([-*+]|\d+\.)\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\s*([-*+]|\d+\.)\s+/, '')); i++;
      }
      const tag = ordered ? 'ol' : 'ul';
      out.push(`<${tag}>${items.map(x => `<li>${mdInline(x)}</li>`).join('')}</${tag}>`);
      continue;
    }
    const buf = [];
    while (i < lines.length && lines[i].trim() && !/^(#{1,6}\s|\s*&gt;|\s*([-*+]|\d+\.)\s)/.test(lines[i])
           && !/^\u0000C\d+\u0000$/.test(lines[i].trim())) { buf.push(lines[i]); i++; }
    if (buf.length) out.push(`<p>${mdInline(buf.join('\n'))}</p>`);
    else i++;
  }
  return out.join('\n').replace(/\u0000C(\d+)\u0000/g, (m, n) => `<pre class="md-code"><code>${code[+n]}</code></pre>`);
}

// ---- the editor ------------------------------------------------------------
// The four view preferences are per-VIEWER conveniences, so they live in
// localStorage and every read and write is wrapped: the accessor throws in a
// private window and can come back empty with cleared site data, and a toolbar
// that cannot render because a preference could not be read would be a poor
// trade. The TEXT is never stored there — it lives in S, so a render pass does
// not lose what has been typed (paintAuth()'s rule, for the same reason).
const ED_PREFS = ['preview', 'wrap', 'mono', 'nums'];
const ED_DEFAULTS = { preview: 'off', wrap: true, mono: false, nums: false };
function edPrefs(){
  if (S.edPrefs) return S.edPrefs;
  let p = Object.assign({}, ED_DEFAULTS);
  try {
    const raw = localStorage.getItem('tmx_ed');
    if (raw) { const got = JSON.parse(raw); for (const k of ED_PREFS) if (k in got) p[k] = got[k]; }
  } catch (e) {}
  S.edPrefs = p; return p;
}
function edSavePrefs(){ try { localStorage.setItem('tmx_ed', JSON.stringify(S.edPrefs)); } catch (e) {} }
function edState(key, initial){
  S.ed = S.ed || {};
  if (!S.ed[key]) S.ed[key] = { value: initial == null ? '' : String(initial), zen: false, el: 'ed_' + key };
  return S.ed[key];
}
// THE TEXTAREA KEEPS THE ID THE FIELD IT REPLACED HAD (`nb`, `dc`), because
// three harnesses and the screenshot tour `page.fill('#nb', …)` — breaking them
// to rename a field would be a cost with nothing on the other side.
function edId(key){ return (S.ed && S.ed[key] && S.ed[key].el) || ('ed_' + key); }
// Read from the DOM and fall back to the stored value. The two agree whenever
// the delegated `input` handler has run, and the fallback is what covers the
// cases where it has not: a value set programmatically, and `preview: only`,
// where `.ed-input` is display:none but the textarea is still in the document
// holding the text.
function edRead(key){
  const el = document.getElementById(edId(key));
  return el ? el.value : edGet(key);
}
function edSet(key, v){ edState(key).value = v; }
function edGet(key){ return (S.ed && S.ed[key]) ? S.ed[key].value : ''; }
function edReset(key, v, id){
  S.ed = S.ed || {};
  S.ed[key] = { value: v == null ? '' : String(v), zen: false, el: id || ('ed_' + key) };
}
function edCount(v){
  const chars = v.length;
  const words = v.trim() ? v.trim().split(/\s+/).length : 0;
  const lines = v.split('\n').length;
  return t('edcount').replace('{words}', words).replace('{chars}', chars).replace('{lines}', lines);
}
// LINE NUMBERS IMPLY NO SOFT WRAP, and that is a correctness tie rather than a
// preference. A wrapped logical line occupies several visual rows, so a gutter
// of logical numbers stops aligning with what is on screen the moment one line
// wraps — and a gutter that is subtly wrong is worse than none. With wrap off
// the textarea is auto-sized to its line count instead, so it has no internal
// vertical scroll to synchronise and the two columns line up with no scroll
// handler at all. (A `scroll` event does not bubble, so the delegated
// dispatcher could not carry one anyway.)
function edWrap(key){ return edPrefs().nums ? false : edPrefs().wrap; }
function edRows(v, min){ return Math.max(min || 8, v.split('\n').length); }
function edGutter(v){
  const n = v.split('\n').length;
  let s = '';
  for (let i = 1; i <= n; i++) s += i + '\n';
  return s;
}
function edToggle(key, what, value){
  const p = edPrefs();
  if (what === 'preview') p.preview = value;
  else p[what] = !p[what];
  edSavePrefs();
  renderTab();
}
function edZen(key, on){ edState(key).zen = !!on; renderTab(); }
// The delegated `input` handler: one place updates the preview, the count, the
// gutter and the stored text. Writing the value back into S is what makes a
// later render pass non-destructive.
function edInput(key, el){
  const v = el.value;
  edSet(key, v);
  const p = edPrefs();
  if (p.nums) {
    el.rows = edRows(v, 8);
    const g = document.getElementById('ednums_' + key);
    if (g) g.textContent = edGutter(v);
  }
  const c = document.getElementById('edcount_' + key);
  if (c) c.textContent = edCount(v);
  if (p.preview !== 'off') {
    const pv = document.getElementById('edprev_' + key);
    if (pv) pv.innerHTML = mdRender(v);
  }
}
function edKey(key, ev){
  if (ev.key === 'Escape' && edState(key).zen) { edZen(key, false); return false; }
}
// Export is a Blob and an `a[download]`, which is the only way to put a file on
// somebody's disk from a page. `default-src 'self'` governs this document, so
// the one thing worth proving is that the download is not refused by the policy
// — test/e2e/demo-validate.mjs clicks it and the gate fails on any console
// error, which is how every other CSP claim in this console was established.
function edExport(key, name){
  const v = edRead(key);
  try {
    const blob = new Blob([v], { type: 'text/markdown;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = (name || 'note') + '.md';
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 0);
  } catch (e) { toast(t('edexportfail')); }
}
// "Save to the repository as a document" — the issue's fourth ask, and it is
// one existing endpoint: a text document IS a repository object since the 0022
// fold (content_type text/markdown, the title in the version's filename). So
// this is not a new write path, it is the one the Documents tab already uses.
async function edToRepo(key, titleId){
  const title = (document.getElementById(titleId) || {}).value || '';
  const content = edRead(key);
  if (!content.trim()) { toast(t('edempty')); return; }
  const r = await api('/api/documents', { method: 'POST', body: { title: title || t('untitled'), content, visibility: 'team' } });
  if (r.ok) toast(t('edsaved'), true); else toast((r.json && r.json.error) || 'error');
}
// The toolbar and the two panes. `key` scopes every id, so two editors on one
// screen cannot collide.
function editorHTML(key, opts){
  opts = opts || {};
  const st = edState(key, opts.value);
  if (opts.id) st.el = opts.id;
  const p = edPrefs();
  const v = st.value;
  const wrap = edWrap(key);
  const seg = (val, label) => `<button class="btn sm ${p.preview === val ? '' : 'ghost'}"
      data-h-click="${H(() => edToggle(key, 'preview', val))}">${esc(label)}</button>`;
  const tog = (what, label) => `<button class="btn sm ${p[what] ? '' : 'ghost'}"
      data-h-click="${H(() => edToggle(key, what))}">${esc(label)}</button>`;
  const bar = `<div class="ed-bar">
    <span class="ed-seg">${seg('off', t('edwrite'))}${seg('side', t('edsplit'))}${seg('only', t('edpreview'))}</span>
    <span class="ed-seg">${tog('nums', t('ednums'))}${
      p.nums ? `<button class="btn sm ghost" disabled title="${esc(t('edwraphint'))}">${esc(t('edwrap'))}</button>`
             : tog('wrap', t('edwrap'))}${tog('mono', t('edmono'))}</span>
    <span class="sp" style="flex:1"></span>
    <span class="muted" id="edcount_${key}" style="font-size:12px">${esc(edCount(v))}</span>
    <button class="btn sm ghost" data-h-click="${H(() => edZen(key, !st.zen))}"
      title="${esc(t('edzenhint'))}">${st.zen ? esc(t('edleavezen')) : esc(t('edzen'))}</button>
  </div>`;
  const nums = p.nums ? `<pre class="ed-nums" id="ednums_${key}" aria-hidden="true">${esc(edGutter(v))}</pre>` : '';
  const ta = `<textarea class="ed-ta${p.mono ? ' mono' : ''}" id="${esc(st.el)}" rows="${p.nums ? edRows(v, 8) : (opts.rows || 10)}"
      wrap="${wrap ? 'soft' : 'off'}" spellcheck="true"
      data-h-input="${H((el) => edInput(key, el))}"
      data-h-keydown="${H((el, ev) => edKey(key, ev))}">${esc(v)}</textarea>`;
  const prev = p.preview === 'off' ? ''
    : `<div class="ed-prev md" id="edprev_${key}">${mdRender(v)}</div>`;
  return `<div class="ed${st.zen ? ' zen' : ''}${p.preview === 'side' ? ' split' : ''}${p.preview === 'only' ? ' prevonly' : ''}">
    ${bar}
    <div class="ed-panes">
      <div class="ed-input">${nums}${ta}</div>
      ${prev}
    </div></div>`;
}
