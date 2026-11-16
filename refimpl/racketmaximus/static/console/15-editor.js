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

// ---- escaping and sentinel hygiene, shared by both renderers ----------------
// ED-4's order lives here: a body is escaped BEFORE any rule sees it, which is
// what makes both renderers sanitisers by construction rather than by a
// sanitiser they could get wrong.
//
// It also drops NUL, and that is not cosmetic. Both renderers lift fenced
// blocks out of the text and put them back at the end through a `\u0000X<n>\u0000`
// sentinel, so a body that CONTAINED one of those sequences could make the
// restore swap in a different block of the same note. In `mdRender` that is a
// rendering oddity and nothing more, because what goes back is already-escaped
// text from the same body; `orgRender` restores an `<a href>` built from a
// validated URL, so the sentinel is load-bearing there. A NUL is not legitimate
// note text in either case, so it is removed once, here, rather than reasoned
// about twice.
function escBody(src){
  return esc(String(src == null ? '' : src)).replace(/\u0000/g, '').replace(/\r\n?/g, '\n');
}

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
  let s = escBody(src);
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

// ---- the org-mode subset (#246, ORG-3…ORG-6) --------------------------------
// A SECOND RENDERER, NOT A REPLACEMENT. ORG-1: `notes.format` is 'markdown' by
// default and 'org' opt in, declared per note and never auto-detected — a body
// beginning `* something` is a valid Markdown bullet AND a valid org headline,
// and they render completely differently, so a detector would silently change
// what somebody's note looks like.
//
// IT SHARES `escBody` AND `mdSafeUrl` WITH `mdRender`, deliberately. A second
// copy of the URL scheme allowlist is the drift this tree has paid for
// repeatedly (`executor-can-run?`, `LIVE-IN`, `escape-like`), and it is the one
// piece of this renderer where a divergence is a stored XSS rather than an ugly
// paragraph. There is no `ORG_SCHEMES`.
//
// THE SUBSET IS STATED (ORG-4). In: headlines `*`…`******`; lists `-`/`+`/`1.`;
// `#+BEGIN_SRC`/`#+BEGIN_EXAMPLE`; `*bold*` `/italic/` `_underline_`
// `=verbatim=` `~code~`; `[[target][description]]` and `[[target]]`; tables
// with a `|---|` separator; `#+TITLE:` and `#+FILETAGS:`; `:tag:tag:` trailing a
// headline. Out: babel of any kind, `#+INCLUDE:` (ORG-5), property drawers and
// TODO keywords (the outliner model, declined with the owner), footnotes, LaTeX
// fragments, and timestamps as a data type rather than as text. Each of those
// renders as its own text, which is the honest failure for a preview.

// Org's own emphasis border rules, which is why this is not simply
// `/\*([^*]+)\*/`. A marker only opens after one of these characters and only
// closes before one of those, and the content may not begin or end with
// whitespace — that is what stops `/` in `https://example.test/a/b` from
// becoming italics, and it is a real body rather than a corner case.
//
// THE CLASSES NAME WHAT IS IN THE ESCAPED TEXT, NOT WHAT THE AUTHOR TYPED. By
// the time these run, a source `"` is `&quot;` and a source `&` is `&amp;`, so
// the character actually preceding a marker after a quoted phrase is `;`. It is
// in the pre-class for that reason and for no other.
const ORG_PRE  = "\\s\\-–—('\"{;&";
const ORG_POST = "\\s\\-–—.,:!?;'\"){}\\[";
function orgEm(t, marker, tag){
  const m = marker.replace(/[*+\/]/g, '\\$&');
  const re = new RegExp('(^|[' + ORG_PRE + '])' + m
    + '([^\\s' + m + '](?:[^\\n]*?[^\\s' + m + '])?)' + m
    + '(?=$|[' + ORG_POST + '])', 'g');
  return t.replace(re, (all, pre, body) => pre + '<' + tag + '>' + body + '</' + tag + '>');
}

// `=verbatim=`, `~code~` and links come out before emphasis runs and go back
// after it, for `mdRender`'s own reason: `*not bold*` inside `~code~` is not
// bold, and a target like `[[https://x/a_b_c][d]]` must not have its
// underscores read as emphasis. Everything restored here was built from
// already-escaped text, or from a URL `mdSafeUrl` admitted.
// `resolved` is OPTIONAL and the default is slice 1's behaviour exactly: with no
// map every internal target is drawn as a plain marker, which is what the §3c2
// probes call it with. With one, ORG-8's "the renderer draws it visibly broken"
// becomes literal.
//
// ITS KEYS ARE THE ESCAPED FORM OF THE TARGET, and that is forced rather than
// sloppy: by the time any rule here runs, a source `&` is `&amp;`, so a map
// keyed on what the SERVER stored would miss every target containing one.
// `linkResolution` in `03-tabs.js` is the one place that builds it and it
// escapes each key once — there is no second spelling of this.
function orgInline(t, resolved){
  const held = [];
  const hold = (html) => { held.push(html); return '\u0000V' + (held.length - 1) + '\u0000'; };
  // verbatim and code first — they are the two constructs that suppress
  // everything inside them
  t = t.replace(/=([^\s=][^=\n]*?)=(?=$|[\s\-.,:!?;'")}\]])/g, (m, body) => hold('<code>' + body + '</code>'));
  t = t.replace(/~([^\s~][^~\n]*?)~(?=$|[\s\-.,:!?;'")}\]])/g, (m, body) => hold('<code>' + body + '</code>'));
  // ORG-6 — a link's target is either an external URL or a note. An
  // `http(s)`/`mailto:` target becomes an anchor through the SHARED allowlist,
  // so `[[javascript:alert(1)][click]]` and its entity-encoded form are both
  // refused by exactly the rule that refuses them in Markdown.
  //
  // AN INTERNAL TARGET IS NOT AN ANCHOR IN THIS SLICE, and that is deliberate
  // rather than unfinished: nothing resolves a note id or a title yet (ORG-7's
  // `note_links` is slice 2) and the console's router has no note route, so an
  // `<a>` here would be a link that goes nowhere — which is worse than a marker
  // that says what it is. It renders as its description with the raw target in
  // the title attribute, and slice 2 is what makes it navigable.
  const link = (target, desc) => {
    const text = desc && desc.trim() ? desc : target;
    if (mdSafeUrl(target)) {
      return hold('<a href="' + target + '" target="_blank" rel="noopener noreferrer">' + text + '</a>');
    }
    // ORG-8 — a link to a note that is not there is drawn VISIBLY BROKEN. A link
    // that silently became plain text is how a reader concludes the editor ate
    // their markup. `undefined` is "nobody has resolved this", which is the
    // preview while you type, and it draws as the plain marker.
    const state = resolved ? resolved[target] : undefined;
    const cls = state === undefined ? 'org-link' : (state ? 'org-link ok' : 'org-link broken');
    return hold('<span class="' + cls + '" title="' + target + '">' + text + '</span>');
  };
  t = t.replace(/\[\[([^\]\[]+)\]\[([^\]\[]*)\]\]/g, (m, target, desc) => link(target.trim(), desc));
  t = t.replace(/\[\[([^\]\[]+)\]\]/g, (m, target) => link(target.trim(), ''));
  t = orgEm(t, '*', 'strong');
  t = orgEm(t, '/', 'em');
  t = orgEm(t, '_', 'u');
  return t.replace(/\u0000V(\d+)\u0000/g, (m, n) => held[+n]);
}

// `:tag:tag:` trailing a headline is RENDERED and never stored (ORG-12): a
// headline is not a note, so storing them would make a note's tag set depend on
// a tree this build deliberately does not model.
function orgHeadline(text, resolved){
  const m = text.match(/^(.*?)\s+(:(?:[^\s:]+:)+)\s*$/);
  if (!m) return orgInline(text.trim(), resolved);
  const tags = m[2].split(':').filter(x => x.length);
  return orgInline(m[1].trim(), resolved)
    + tags.map(x => ' <span class="badge">' + x + '</span>').join('');
}

function orgRender(src, resolved){
  let s = escBody(src);
  // The blocks come out first and go back last, so no inline rule runs inside
  // one — the asterisks in a `#+BEGIN_SRC` block stay literal, which is the
  // whole point of a source block.
  const code = [];
  s = s.replace(/^[ \t]*#\+BEGIN_(SRC|EXAMPLE)\b[^\n]*\n([\s\S]*?)^[ \t]*#\+END_\1[ \t]*$/gim,
    (m, kind, body) => {
      code.push(body.replace(/\n$/, ''));
      return '\u0000C' + (code.length - 1) + '\u0000';
    });
  const lines = s.split('\n');
  const out = [];
  let i = 0;
  const isTableSep = (l) => /^\s*\|[\s:+|-]*-[\s:+|-]*\|?\s*$/.test(l);
  const isTableRow = (l) => /^\s*\|/.test(l);
  const cells = (l) => l.replace(/^\s*\|/, '').replace(/\|\s*$/, '').split('|').map(c => c.trim());
  while (i < lines.length) {
    const l = lines[i];
    if (/^\u0000C\d+\u0000$/.test(l.trim())) { out.push(l.trim()); i++; continue; }
    if (!l.trim()) { i++; continue; }
    let m;
    // ORG-5 — `#+INCLUDE:` IS REFUSED BY NAME AND VISIBLY. In real org it reads
    // a file from the filesystem, which is an LFI with the author's own note as
    // the weapon; rendering it as plain text would be safe and would leave an
    // operator wondering why the content never appears. Same call as an unknown
    // theme token and an unknown classifier backend: a directive that silently
    // does nothing is the hardest thing on a surface to diagnose.
    if (/^[ \t]*#\+INCLUDE:/i.test(l)) {
      out.push('<p class="org-refused">' + t('orgnoinclude') + '</p>'); i++; continue;
    }
    if ((m = l.match(/^[ \t]*#\+TITLE:[ \t]*(.*)$/i))) {
      out.push('<h1 class="org-title">' + orgInline(m[1].trim(), resolved) + '</h1>'); i++; continue;
    }
    if ((m = l.match(/^[ \t]*#\+FILETAGS:[ \t]*(.*)$/i))) {
      const tags = m[1].split(':').map(x => x.trim()).filter(x => x.length);
      out.push('<p class="org-filetags">'
        + tags.map(x => '<span class="badge">' + x + '</span>').join(' ') + '</p>');
      i++; continue;
    }
    // A headline needs a SPACE after its stars, which is what separates
    // `** Heading` from a paragraph opening with `**emphasis**`.
    if ((m = l.match(/^(\*{1,6})[ \t]+(.*)$/))) {
      const n = m[1].length;
      out.push('<h' + n + '>' + orgHeadline(m[2], resolved) + '</h' + n + '>'); i++; continue;
    }
    if (isTableRow(l) && i + 1 < lines.length && isTableSep(lines[i + 1])) {
      const head = cells(l); i += 2;
      const body = [];
      while (i < lines.length && isTableRow(lines[i]) && !isTableSep(lines[i])) { body.push(cells(lines[i])); i++; }
      out.push('<table><thead><tr>' + head.map(c => '<th>' + orgInline(c, resolved) + '</th>').join('') + '</tr></thead>'
        + '<tbody>' + body.map(r => '<tr>' + r.map(c => '<td>' + orgInline(c, resolved) + '</td>').join('') + '</tr>').join('')
        + '</tbody></table>');
      continue;
    }
    if (/^\s*([-+]|\d+[.)])\s+/.test(l)) {
      const ordered = /^\s*\d+[.)]/.test(l);
      const items = [];
      while (i < lines.length && /^\s*([-+]|\d+[.)])\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\s*([-+]|\d+[.)])\s+/, '')); i++;
      }
      const tag = ordered ? 'ol' : 'ul';
      out.push('<' + tag + '>' + items.map(x => '<li>' + orgInline(x, resolved) + '</li>').join('') + '</' + tag + '>');
      continue;
    }
    // Everything else is a paragraph, which is where every construct outside
    // ORG-4's subset lands: a property drawer, a TODO keyword, a footnote
    // reference and a `#+OPTIONS:` line all render as their own text.
    const buf = [];
    while (i < lines.length && lines[i].trim()
           && !/^(\*{1,6}[ \t]|\s*([-+]|\d+[.)])\s|[ \t]*#\+(TITLE|FILETAGS|INCLUDE):)/i.test(lines[i])
           && !isTableRow(lines[i])
           && !/^\u0000C\d+\u0000$/.test(lines[i].trim())) { buf.push(lines[i]); i++; }
    if (buf.length) out.push('<p>' + orgInline(buf.join('\n'), resolved) + '</p>');
    else i++;
  }
  return out.join('\n').replace(/\u0000C(\d+)\u0000/g,
    (m, n) => '<pre class="md-code"><code>' + code[+n] + '</code></pre>');
}

// ONE place picks the renderer, so no caller has to switch on a format and no
// caller can forget to. An unknown or absent format is Markdown — the column's
// default, and what every note written before #246 carries.
function bodyRender(src, format, resolved){
  return format === 'org' ? orgRender(src, resolved) : mdRender(src);
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
function edState(key, initial, format){
  S.ed = S.ed || {};
  if (!S.ed[key]) S.ed[key] = { value: initial == null ? '' : String(initial), zen: false,
                                el: 'ed_' + key, fmt: format || 'markdown' };
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
function edReset(key, v, id, format){
  S.ed = S.ed || {};
  S.ed[key] = { value: v == null ? '' : String(v), zen: false, el: id || ('ed_' + key),
                fmt: format || 'markdown' };
}
// The format is per-EDITOR state and not a view preference, which is the line
// `edPrefs` draws: preview/wrap/mono/nums are what this VIEWER likes and live in
// localStorage, while the format is a property of the note being edited and is
// stored on it (ORG-1). Putting it in localStorage would make somebody's last
// note decide how their next one renders.
function edFormat(key){ return (S.ed && S.ed[key] && S.ed[key].fmt) || 'markdown'; }
// IT DOES NOT CALL `renderTab()`, AND THE E2E GATE IS WHAT ESTABLISHED THAT IT
// MUST NOT. A tab render rebuilds the form's plain inputs from the template, so
// a switch that re-rendered discarded the TITLE somebody had just typed and the
// note was created under the template's own placeholder. The editor's text
// survives a render because it lives in S (#180); a plain `<input>` does not.
//
// So the two things the format actually decides are repainted in place, which is
// CARD-2's rule one level down: a partial update is not a render pass. It is
// also cheaper than the render it replaces.
//
// WHAT IS NOT FIXED HERE, stated rather than left to be discovered: `edToggle`
// and `edZen` still call `renderTab()`, so the toolbar's view buttons lose a
// typed title in exactly the same way. That is pre-existing and it is the whole
// Notes form's question (title, tags and visibility are all plain inputs), not
// the format control's.
function edSetFormat(key, fmt){
  edState(key).fmt = fmt;
  // the preview, under the new renderer — `edInput` is the one place that
  // repaints it, so there is no second copy of "which renderer does this pane
  // want"
  const el = document.getElementById(edId(key));
  if (el) edInput(key, el);
  // …and the export label, which follows the format because `edExport` writes
  // `.org` for an org note
  const x = document.getElementById('edexp_' + key);
  if (x) {
    const org = fmt === 'org';
    x.textContent = tRaw(org ? 'edexportorg' : 'edexport');
    x.title = tRaw(org ? 'edexportorghint' : 'edexporthint');
  }
  // …and anything the SURROUNDING FORM shows because of the format. ORG-12 makes
  // the Notes form's tags field depend on it, and that field is the tab's rather
  // than the editor's — so the editor announces the change and does not reach
  // into it. Looked up by name because a later file may hook it, which is the
  // same seam `paletteKey` and `helpKey` already use in `01-base.js`.
  //
  // The e2e gate is what asked for this: slice 1 made this a PARTIAL update to
  // stop a render pass discarding a typed title, which also meant the field no
  // longer followed the switch.
  if (typeof edFormatChanged === 'function') edFormatChanged(key, fmt);
}
function edCount(v){
  const chars = v.length;
  const words = v.trim() ? v.trim().split(/\s+/).length : 0;
  const lines = v.split('\n').length;
  return tRaw('edcount').replace('{words}', words).replace('{chars}', chars).replace('{lines}', lines);
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
    if (pv) pv.innerHTML = bodyRender(v, edFormat(key));
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
  // An org note downloads as `.org`, because a `.md` holding org markup is a
  // file whose name is wrong about its contents. `text/org` is not a registered
  // media type (ORG-11 records the same thing for the server's own download), so
  // the body goes out as plain text and the EXTENSION is what carries the
  // format — which is what every org editor keys on anyway.
  const org = edFormat(key) === 'org';
  try {
    const blob = new Blob([v], { type: (org ? 'text/plain' : 'text/markdown') + ';charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = (name || 'note') + (org ? '.org' : '.md');
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 0);
  } catch (e) { toast(tRaw('edexportfail')); }
}
// "Save to the repository as a document" — the issue's fourth ask, and it is
// one existing endpoint: a text document IS a repository object since the 0022
// fold (content_type text/markdown, the title in the version's filename). So
// this is not a new write path, it is the one the Documents tab already uses.
async function edToRepo(key, titleId){
  const title = (document.getElementById(titleId) || {}).value || '';
  const content = edRead(key);
  if (!content.trim()) { toast(tRaw('edempty')); return; }
  const r = await api('/api/documents', { method: 'POST', body: { title: title || t('untitled'), content, visibility: 'team' } });
  if (r.ok) toast(tRaw('edsaved'), true); else toast((r.json && r.json.error) || 'error');
}
// The toolbar and the two panes. `key` scopes every id, so two editors on one
// screen cannot collide.
function editorHTML(key, opts){
  opts = opts || {};
  const st = edState(key, opts.value, opts.format);
  if (opts.id) st.el = opts.id;
  // `opts.format` SEEDS a fresh state and never overrides a live one, exactly as
  // `opts.value` does. Re-asserting it on every render would make the format
  // control unusable: `edSetFormat` re-renders, and the next render would put
  // the note's stored format straight back. Opening a note is what sets it, and
  // that is `edReset`'s job.
  const p = edPrefs();
  const v = st.value;
  const wrap = edWrap(key);
  const seg = (val, label) => `<button class="btn sm ${p.preview === val ? '' : 'ghost'}"
      data-h-click="${H(() => edToggle(key, 'preview', val))}">${esc(label)}</button>`;
  const tog = (what, label) => `<button class="btn sm ${p[what] ? '' : 'ghost'}"
      data-h-click="${H(() => edToggle(key, what))}">${esc(label)}</button>`;
  // ORG-1 — the format is OFFERED only where the surface stores one. Documents
  // are repository objects with a content type and no `format` column, so the
  // control would be a switch with nowhere to save to.
  const fmtSel = opts.formats
    ? `<span class="ed-seg"><select class="ed-fmt" id="edfmt_${key}" aria-label="${t('orgformat')}"
        data-h-change="${H((el) => edSetFormat(key, el.value))}">${
        opts.formats.map(f => `<option value="${esc(f)}"${f === st.fmt ? ' selected' : ''}>${esc(tRaw('fmt' + f))}</option>`).join('')
      }</select></span>` : '';
  const bar = `<div class="ed-bar">
    <span class="ed-seg">${seg('off', tRaw('edwrite'))}${seg('side', tRaw('edsplit'))}${seg('only', tRaw('edpreview'))}</span>
    <span class="ed-seg">${tog('nums', tRaw('ednums'))}${
      p.nums ? `<button class="btn sm ghost" disabled title="${t('edwraphint')}">${t('edwrap')}</button>`
             : tog('wrap', tRaw('edwrap'))}${tog('mono', tRaw('edmono'))}</span>
    ${fmtSel}
    <span class="sp" style="flex:1"></span>
    <span class="muted" id="edcount_${key}" style="font-size:12px">${esc(edCount(v))}</span>
    <button class="btn sm ghost" data-h-click="${H(() => edZen(key, !st.zen))}"
      title="${t('edzenhint')}">${st.zen ? t('edleavezen') : t('edzen')}</button>
  </div>`;
  const nums = p.nums ? `<pre class="ed-nums" id="ednums_${key}" aria-hidden="true">${esc(edGutter(v))}</pre>` : '';
  const ta = `<textarea class="ed-ta${p.mono ? ' mono' : ''}" id="${esc(st.el)}" rows="${p.nums ? edRows(v, 8) : (opts.rows || 10)}"
      wrap="${wrap ? 'soft' : 'off'}" spellcheck="true"
      data-h-input="${H((el) => edInput(key, el))}"
      data-h-keydown="${H((el, ev) => edKey(key, ev))}">${esc(v)}</textarea>`;
  const prev = p.preview === 'off' ? ''
    : `<div class="ed-prev md" id="edprev_${key}">${bodyRender(v, edFormat(key))}</div>`;
  return `<div class="ed${st.zen ? ' zen' : ''}${p.preview === 'side' ? ' split' : ''}${p.preview === 'only' ? ' prevonly' : ''}">
    ${bar}
    <div class="ed-panes">
      <div class="ed-input">${nums}${ta}</div>
      ${prev}
    </div></div>`;
}
