// ---- in-product help: ask the documentation (issue #183) ---------------------
// A question, answered out of this instance's OWN documentation with citations
// by file path — or a refusal saying why it could not be. The whole of the
// decision is server-side (`domain/help/answer.rkt`); this is one overlay and
// one POST.
//
// IT LIVES IN THE STATIC SHELL, like the palette's two overlays and for the same
// reason: it is over whatever is on screen, so a tab re-render must not take it
// down mid-answer. The documented cost is the same too — the shell is cached at
// startup, so a live box needs a RESTART to pick this up.
//
// IT IS HIDDEN WHEN IT CANNOT WORK. `S.me.help.reason` comes from whoami, which
// is already fetched on every render pass, so an instance with no embedder or no
// corpus shows no affordance at all rather than a button that explains itself
// after you press it. `locale-empty` is NOT hidden: the corpus exists and the
// answer will come back in another language, which is worth offering and worth
// saying.
function helpBlocked(){
  const r = S.me && S.me.help && S.me.help.reason;
  return r === 'unconfigured' || r === 'empty';
}

function helpOpenNow(){ return !(document.getElementById('helpbox') || { hidden: true }).hidden; }

function helpClose(){
  const box = document.getElementById('helpbox');
  if (!box) return;
  box.hidden = true; box.innerHTML = '';
  S.help = null;
}

function helpOpen(){
  if (helpBlocked()) return;
  palClose(); palHelp(false);
  S.help = S.help || { q: '', rep: null, asking: false };
  helpPaint();
  const i = document.getElementById('helpq');
  if (i) { i.focus(); i.select(); }
}

// Painted rather than re-rendered, `paintAuth()`'s rule: the question somebody
// has typed and the answer they are reading both live in `S.help`, so a repaint
// cannot lose either.
function helpPaint(){
  const box = document.getElementById('helpbox');
  if (!box) return;
  const st = S.help || { q: '', rep: null, asking: false };
  box.hidden = false;
  box.innerHTML = `<div class="pal-box">
    <h3 style="margin:0 0 8px;padding:14px 16px 0">${esc(t('helptitle'))}</h3>
    <div style="padding:0 16px 12px">
      <textarea id="helpq" rows="2" placeholder="${esc(t('helpph'))}"
        data-h-input="${Hk((el) => { S.help.q = el.value; })}"
        data-h-keydown="${Hk((el, ev) => sendKey(ev, doHelpAsk))}"
        >${esc(st.q)}</textarea>
      <button class="btn sm" ${st.asking ? 'disabled' : ''}
        data-h-click="${Hk(() => doHelpAsk())}">${esc(st.asking ? t('helpasking') : t('helpsend'))}</button>
    </div>
    <div id="helpout" style="padding:0 16px 12px;max-height:48vh;overflow:auto">${helpBody(st.rep)}</div>
    <div class="pal-foot muted">${esc(t('helpclose'))}</div></div>`;
}

// WHAT A REFUSAL LOOKS LIKE IS THE HALF THAT MATTERS, so each closed reason has
// its own sentence rather than one "it did not work". The vocabulary is the
// server's (`HELP-ANSWER-REASONS`); an unknown one falls through to the answer,
// which is the honest default for a field this client does not understand.
const HELP_REASON_KEY = {
  'unconfigured':     'helpunconfigured',
  'empty':            'helpempty',
  'locale-empty':     'helplocaleempty',
  'no-model':         'helpnomodel',
  'nothing-relevant': 'helpnone',
  'uncited':          'helpuncited',
  'unfocused':        'helpunfocused'
};

function helpBody(rep){
  if (!rep) return '';
  const reason = rep.reason || null;
  const note = reason && HELP_REASON_KEY[reason]
    ? `<div class="bx-warn">${esc(t(HELP_REASON_KEY[reason]))}</div>` : '';
  // The ANSWER is Markdown-ish prose, so it goes through the editor's renderer
  // rather than a second one — ED-4's escape-first rule is what makes it safe,
  // and a second renderer here would be the drift this console already paid for.
  const answer = (typeof rep.answer === 'string' && rep.answer)
    ? `<div class="md">${mdRender(rep.answer)}</div>` : '';
  // The passage NUMBER rides on each citation, so the `[2]` the answer carries
  // in its prose resolves to a line the reader can see (HELP-23).
  const cites = (rep.citations || []).length
    ? `<div class="help-sec">${esc(t('helpsources'))}</div><ul class="help-cites">${
        rep.citations.map(c => `<li>${c.index ? `<span class="muted">[${c.index}]</span> ` : ''}<span class="mono">${esc(c.path)}</span>${
          c.heading ? ' — ' + esc(c.heading) : ''}</li>`).join('')}</ul>` : '';
  // THE PASSAGES ARE SHOWN WHENEVER THERE ARE NO CITATIONS TO SHOW, which is a
  // widening of the `no-model` case and the fix for what was reported as "ask
  // the documentation is still broken".
  //
  // Measured over ten real questions against the live corpus (HELP-23): four
  // came back flagged while carrying a perfectly good answer, because on this
  // model `uncited` usually means the model answered and did not bracket
  // anything — not that it is declining. So the reader met a correct answer
  // under an orange warning telling them it was a refusal, and nothing under
  // Sources at all. Now the passages the answer was read FROM are listed
  // whenever the citations are empty: `content_search: false`'s posture, report
  // what did not run and keep what did.
  const passages = (!(rep.citations || []).length && (rep.passages || []).length)
    ? `<div class="help-sec">${esc(t('helpread'))}</div>${
        rep.passages.map((p, i) => `<div class="help-p"><div class="mono muted">[${i + 1}] ${esc(p.path)}${
          p.heading ? ' — ' + esc(p.heading) : ''}</div><div>${
          esc(p.text.slice(0, 400))}…</div></div>`).join('')}` : '';
  return note + answer + cites + passages;
}

// ONE SEND, and the flag IS the guard and the pending state — #174's shape,
// including the `finally`: without it one network error leaves the button
// disabled with no way back but a reload. Nothing may `await` between the check
// and the set, or two activations in one tick both get past it.
async function doHelpAsk(){
  if (!S.help || S.help.asking) return;
  const q = (S.help.q || '').trim();
  if (!q) return;
  S.help.asking = true;
  helpPaint();
  try {
    // `api()` answers a WRAPPER — {ok, status, json} — and this assigned the
    // wrapper itself, so `helpBody` read `reason`, `answer` and `citations` off
    // an object that has none of them, every field came back undefined, and the
    // panel rendered the EMPTY STRING for every question ever asked. Reported
    // from outside as "help doesn't respond". The server was answering
    // perfectly: probed in process against the live corpus, "why do my jobs
    // stay queued" came back "your team has exceeded its AI budget" in 0.9s.
    //
    // A REFUSAL HAS TO LAND SOMEWHERE TOO. The old code could not tell a 403
    // from an answer either, because both became a wrapper with no `answer` —
    // so a quota refusal was also silence. `helpBody` is for the server's own
    // closed reasons (HELP-19); an HTTP failure is a different thing and gets
    // the toast every other call in this console uses.
    const r = await api('/api/help', { method: 'POST', body: { question: q } });
    if (r.ok) S.help.rep = r.json;
    else { S.help.rep = null; toast((r.json && r.json.error) || t('helpfailed')); }
  } catch (e) {
    toast(String((e && e.message) || e));
  } finally {
    if (S.help) { S.help.asking = false; helpPaint(); }
  }
}

// The keyboard route, through the palette's single delegated entry point rather
// than a listener of its own. `?` is taken by the shortcut list, so this is
// Cmd/Ctrl+/ — the key a browser's own help uses, and unambiguous with a
// modifier held (PAL-3's asymmetry).
function helpKey(ev){
  if (!S.me || helpBlocked()) return false;
  if (palMod(ev) && (ev.key === '/' || ev.key === '?')) {
    ev.preventDefault();
    if (helpOpenNow()) helpClose(); else helpOpen();
    return true;
  }
  if (ev.key === 'Escape' && helpOpenNow()) { helpClose(); return true; }
  return false;
}
