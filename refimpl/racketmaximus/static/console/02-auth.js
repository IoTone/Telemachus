// ---------- auth ----------
// authView()'s inputs are always EMPTY, so any repaint of the sign-in screen
// throws away what has been typed into it — and the screen does get repainted
// while signed out: switching language calls render(), and so does an operator
// saving branding. Switching language after typing a username wiped it, which is
// the "empty login field" this exists to stop. Carry the values across the swap,
// and the caret with them, or focus jumps back to the top of the form.
function paintAuth(app){
  const ids=['lu','lp','lc','bu','bp'];
  const keep=ids.map(id=>{ const e=document.getElementById(id); return [id, e?e.value:null]; });
  const had=document.activeElement && document.activeElement.id;
  const sel=(()=>{ const e=document.activeElement;
    try{ return e && typeof e.selectionStart==='number' ? [e.selectionStart,e.selectionEnd] : null; }
    catch(_){ return null; } })();
  app.innerHTML=authView();
  for(const [id,v] of keep){ if(v!=null){ const e=document.getElementById(id); if(e) e.value=v; } }
  if(had){ const e=document.getElementById(had);
    if(e){ e.focus(); if(sel){ try{ e.setSelectionRange(sel[0],sel[1]); }catch(_){} } } }
  fadeIn(app);
}
// Restart the animation on a node that may already carry the class — without the
// reflow the browser keeps the finished animation and nothing fades.
function fadeIn(el){ el.classList.remove('tmx-enter'); void el.offsetWidth; el.classList.add('tmx-enter'); }
function authView(){
  return `<div class="auth">
    <h1 class="brand">${brandLockup(38)}</h1>
    <p class="muted">${esc(brandTagline())}</p>
    <div class="langtog" style="margin:10px 0 18px">${langBtns()}</div>
    <div class="card">
      <h2>${t('signin')}</h2>
      <label>${t('user')}</label><input id="lu" autofocus>
      <label>${t('pass')}</label><input id="lp" type="password">
      <label>${t('code')}</label><input id="lc">
      <button class="btn" style="width:100%" id="lbtn" data-h-click="${H((el,ev)=>doLogin())}">${t('signin')}</button>
    </div>
    <details class="card" style="margin-top:14px">
      <summary style="cursor:pointer" class="muted">${t('firstrun')}</summary>
      <div style="margin-top:12px">
        <label>${t('user')}</label><input id="bu" value="alice">
        <label>${t('pass')}</label><input id="bp" type="password" value="s3cret">
        <button class="btn ghost" data-h-click="${H((el,ev)=>doBootstrap())}">${t('createop')}</button>
      </div>
    </details>
  </div>`;
}
// Signing in is two rounds of API calls deep (see render), so without this the
// card sits unchanged and unresponsive while they run and the click looks lost —
// the window is invisible on localhost and obvious on a real box. The
// pending state is also the double-submit guard: two doLogin() calls would mint
// two sessions and race two renders.
async function doLogin(){
  if(S.signingIn) return;
  const body={username:val('lu'),password:val('lp')}; const c=val('lc'); if(c) body.code=c;
  S.signingIn=true; const btn=document.getElementById('lbtn');
  if(btn){ btn.disabled=true; btn.textContent=t('signingin'); }
  try{
    const r=await api('/api/login',{method:'POST',body});
    if(r.ok){ setTok(r.json.token); await render(); }
    else {
      if(btn){ btn.disabled=false; btn.textContent=t('signin'); }
      toast(r.json.error||'login failed');
    }
  } finally {
    // in a `finally` because a throw anywhere above would otherwise leave the
    // flag set and the button disabled for ever, with no way back but a reload
    S.signingIn=false;
  }
}
async function doBootstrap(){
  const r=await api('/api/bootstrap',{method:'POST',body:{username:val('bu'),password:val('bp')}});
  if(r.ok){ setTok(r.json.token); toast(r.json.message||'created',true); render(); } else toast(r.json.error||'failed');
}

// ---------- shell ----------
const LANGNAME = {en:'EN', ja:'日本語'};
// Empty when the operator has turned negotiation off — there is nothing to
// choose, so offering a chooser would be a lie.
function langBtns(){ if(!S.i18n.enabled) return '';
  const av = S.i18n.available||['en']; if(av.length<2) return '';
  return av.map(l=>`<button class="${S.lang===l?'active':''}" data-h-click="${H((el,ev)=>setLang((l)))}">${LANGNAME[l]||l.toUpperCase()}</button>`).join(''); }
function appShell(){
  // #177: TWELVE names go through this filter and only FIVE can ever match —
  // `known-features` is chat / agent / translate / search / workflows, which is
  // exactly the set of features `server/routes.rkt` carries a `#:feature` for.
  // For the other seven `S.features[x]` is undefined, so `!== false` always
  // holds and the tab is always shown. The filter is kept over the whole list
  // deliberately: it is how a tab starts hiding the day its feature becomes
  // switchable, which needs a `#:feature` on its routes first — a decision about
  // what an operator may turn off, not something a tab list should assume.
  // `reviews`, `localize`, `beta` and `admin` are spliced in BELOW, after the
  // filter, so they are outside it entirely and are gated by permission instead.
  const tabs=['chat','agent','translate','search','notes','documents','repository','workflows','knowledge','jobs','team','usage'].filter(x=>S.features[x]!==false);
  if(canPerm('reviews:read')) tabs.splice(tabs.indexOf('workflows')+1, 0, 'reviews');
  if(canPerm('localization:read')) tabs.splice(tabs.indexOf('usage'), 0, 'localize');
  // #179: `instance:read`, which `instance:manage` implies by name (#124), so
  // an operator keeps it and a monitoring credential scoped to the read gets
  // the screen without being able to reset a password. Spliced rather than
  // pushed, so it sits beside Usage where an operator already looks for
  // numbers rather than after the Admin tab.
  if(canPerm('instance:read')) tabs.splice(tabs.indexOf('usage')+1, 0, 'health');
  if(canManage()) tabs.push('beta'); if(S.me.is_operator) tabs.push('admin');
  return `<header class="top">
      <span class="brand">${brandLockup(22)}</span>
      <span class="sp"></span>
      <span class="langtog">${langBtns()}</span>
      <span class="chip">${esc(S.me.user_id.slice(0,8))}… ${S.me.is_operator?`<span class="badge op">${t('operator')}</span>`:''}</span>
      <button class="btn ghost sm" data-h-click="${H((el,ev)=>logout())}">${t('logout')}</button>
    </header>
    <nav class="tabs">${tabs.map(x=>`<button data-tab="${x}" class="${S.tab===x?'active':''}" data-h-click="${H((el,ev)=>go((x)))}">${t(x)}</button>`).join('')}</nav>
    <main class="wrap" id="main"></main>
    ${buildFooter()}`;
}
// WHICH BUILD IS THIS? Two instances of this platform a day apart are identical
// on screen, and the version alone would not have told them apart — it is
// 0.1.0 on both. The COMMIT is the field that answers it, so it is the one
// rendered in full on hover and short in the line.
//
// Signed-in only, by #11's rule: the version, the KDF and the TLS state were
// deliberately moved off the public `/health` because an exact version is a
// shopping list. `S.me.build` comes from whoami, which is authenticated and
// already fetched on every render pass. An older server that does not send it
// renders nothing rather than a blank or a guess.
function buildFooter(){
  const b = (S.me && S.me.build) || null;
  if(!b) return '';
  const started = b.started ? new Date(b.started*1000).toLocaleString() : '';
  const commit = b.commit_short || '';
  const dev = (b.commit === 'dev');
  return `<footer class="build">
    <span>${esc(S.brand.title||'TMach')} <span class="mono">${esc(b.version||'')}</span></span>
    ${commit?`<span class="mono" title="${esc(b.commit)}${started?' \u00b7 '+esc(t('buildstarted'))+' '+esc(started):''}">${
        dev ? esc(t('builddev')) : esc(commit)}</span>`:''}
    ${b.source?`<a href="${esc(b.source)}" target="_blank" rel="noopener noreferrer">${t('buildsource')}</a>`:''}
  </footer>`;
}
function go(tab){ S.tab=tab; S.newToken=null;
  if(tab!=='workflows'){ S.wfRun=null; S.wfSel=null; S.wfSpec=null; }   // leaving drops any run poll in flight
  if(tab!=='repository'){ S.repoDetail=null; S.s3New=null; }
  // #180: leaving a tab abandons an edit in progress, the same way it drops a
  // run poll. Keeping it would show a Save button on a card whose note is no
  // longer on screen.
  if(tab!=='notes'){ S.noteEdit=null; edReset('note','', 'nb'); }
  if(tab!=='documents'){ S.docEdit=null; edReset('doc','', 'dc'); }
  S.wfPoll++;
  document.querySelectorAll('nav.tabs button').forEach(b=>b.classList.toggle('active', b.dataset.tab===tab));
  renderTab(); }

