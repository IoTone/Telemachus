// ---------- render ----------
async function refreshMe(){ if(!S.token){S.me=null;S.sessionPolicy=null;return;} const r=await api('/api/whoami');
  if(r.ok){ S.me=r.json; S.sessionPolicy=r.json.session_policy||null; }
  else { S.token=null; localStorage.removeItem('tmx_token'); S.me=null; S.sessionPolicy=null; } }

// ---------- inactivity (issue #38, OWASP) ----------
// The SERVER enforces the timeout in resolve-token; this is the courtesy half
// OWASP asks for, so that a session ending is something a person saw coming
// rather than a form that silently stopped working. "Stay signed in" makes a real
// request, which is exactly what refreshes the server's clock.
function idleBar(show, msg){
  const bar=document.getElementById('idlebar'); if(!bar) return;
  if(show){ document.getElementById('idlemsg').textContent=msg;
            document.getElementById('idlestay').textContent=t('idlestay');
            bar.hidden=false; }
  else bar.hidden=true;
}
async function idleStay(){ idleBar(false); await api('/api/whoami'); }
function idleSignOut(){
  idleBar(false);
  S.token=null; localStorage.removeItem('tmx_token'); S.me=null; S.sessionPolicy=null;
  S.forceLogin=true; toast(t('idleout')); render();
}
function idleTick(){
  const pol=S.sessionPolicy;
  if(!S.token || !pol || typeof pol.idle_seconds!=='number'){ idleBar(false); return; }
  const idleFor=(Date.now()-(S.lastReq||Date.now()))/1000;
  const left=Math.ceil(pol.idle_seconds-idleFor);
  const warnAt=typeof pol.warn_seconds==='number'?pol.warn_seconds:0;
  if(left<=0) idleSignOut();
  else if(warnAt>0 && left<=warnAt) idleBar(true, t('idlewarn').replace('{n}', left));
  else idleBar(false);
}
async function translateView(){
  const langs=[['ja','日本語'],['nl','Nederlands'],['es-419','Español (LatAm)'],['en','English'],['fr','Français'],['de','Deutsch']];
  const gl=await api('/api/glossary'); const terms=gl.ok?gl.json.glossary:[];
  const hr=await api('/api/translate'); const hist=hr.ok?hr.json.translations:[];
  // #231: the limit is the SERVER's number, reported on this same read, so the
  // count beside the field cannot disagree with the rule that refuses.
  S.trMax = (hr.ok && hr.json.max_chars) || 0;
  const manage=canManage();
  const opts=langs.map(([c,n])=>`<option value="${c}">${esc(n)}</option>`).join('');
  const termRows=terms.map(x=>`<tr><td class="mono muted">${esc(x.target_lang)}</td><td>${esc(x.term)}</td><td>${esc(x.translation)}</td></tr>`).join('');
  // THE CARD CAN ONLY BE FILLED ONCE ITS MARKUP IS IN THE DOM, and a view
  // returns a string. So the follow is kicked after this pass paints —
  // `cardSwap` finds no `#trjobs` and does nothing if the pass was superseded
  // or the tab changed, which is the whole guard it needs. Coming back to the
  // tab with a job still running therefore picks it up again.
  if((S.trJobs||[]).length) setTimeout(trFollow, 0);
  const histRows=hist.map(x=>`<tr><td class="mono muted">${esc(x.target_lang)}</td><td>${esc((x.source_text||'').slice(0,40))}</td><td>${esc((x.result||'').slice(0,70))}</td></tr>`).join('');
  return `<h2>${t('translate')}</h2>
   <div class="card">
     <label>${t('sourcetext')}</label>
     <textarea id="trsrc" class="grow" rows="4"
       data-h-input="${H((el)=>{growTA(el);trCount();})}"></textarea>
     <div id="trcount" class="muted" style="font-size:12px">${trCountText(0)}</div>
     <div class="row" style="margin-top:8px;align-items:end">
       <div><label>${t('target')}</label><select id="trtgt">${opts}</select></div>
       <div><label><input type="checkbox" id="trgl" checked> ${t('useglossary')}</label></div>
       <div><button id="trgo" class="btn" data-h-click="${H((el,ev)=>doTranslate())}">${t('translate')}</button></div>
     </div>
     <div id="trout" class="mono" style="margin-top:12px;white-space:pre-wrap"></div>
   </div>
   ${trJobsCard(null)}
   <div class="card" style="margin-top:14px"><h3>${t('glossary')} <span class="muted" style="font-size:13px">— team terminology</span></h3>
     ${manage?`<div class="row" style="align-items:end;margin-bottom:8px">
        <div><label>${t('target')}</label><select id="gltgt">${opts}</select></div>
        <div><label>${t('term')}</label><input id="glterm"></div>
        <div><label>${t('translation')}</label><input id="gltr"></div>
        <div><button class="btn sm" data-h-click="${H((el,ev)=>doAddTerm())}">${t('addterm')}</button></div></div>`:''}
     <table><thead><tr><th>lang</th><th>${t('term')}</th><th>${t('translation')}</th></tr></thead><tbody>${termRows}</tbody></table>
   </div>
   <div class="card" style="margin-top:14px"><h3>${t('recent')}</h3>
     <table><thead><tr><th>lang</th><th>${t('sourcetext')}</th><th>${t('translation')}</th></tr></thead><tbody>${histRows}</tbody></table></div>`;
}
// WHAT THE COUNTER IS FOR is not tidiness: past the limit the answer comes back
// WRONG rather than failing (#231), so the number has to be visible BEFORE the
// button is pressed. Over the limit it turns red and says what will happen, and
// the server refuses it anyway — this is the warning, not the enforcement.
// Chat and Agent want the same count against the same kind of limit, so the
// implementation moved to `01-base.js` and these two are the Translate field's
// binding of it. Three copies of the arithmetic would be the drift this console
// has paid for before.
function trCountText(n){ return charCountText(n, S.trMax || 0); }
function trCount(){ charCount('trsrc', 'trcount', S.trMax || 0); }
// ONE SEND, the flag IS the guard and the pending state, and the `finally` is
// what stops one network error leaving the button dead — #174's shape, which
// this call never had. It also shows the CLOCK: a translation of any length
// takes seconds to a minute on a local model, and the old version painted a
// single "…" and gave no sign it was still alive.
//
// A REFUSAL GOES IN THE OUTPUT PANE, NOT IN A TOAST. #231's message is several
// sentences — the length sent, the limit, why longer comes back wrong, and the
// two remedies — and a toast scrolls away in 2.6 seconds with no second chance.
// It is the one thing the person needs to read.
async function doTranslate(){
  // THE GUARD IS AROUND THE ENQUEUE, NOT AROUND THE TRANSLATION. #174's flag
  // covered the whole 20-second call, which is exactly what made a second
  // submission impossible — the complaint #233 was filed about. What still
  // needs guarding is the POST itself: two activations in one tick would
  // enqueue two jobs, and a focused button fires on Enter and Space, so it
  // takes no deliberate double-click. Nothing awaits between the check and the
  // set, and the `finally` is what stops one network error leaving the button
  // dead.
  if(S.trSending) return;
  const text=val('trsrc'), target_lang=val('trtgt'), use_glossary=document.getElementById('trgl').checked;
  if(!text){toast(t('empty'));return;}
  S.trSending=true;
  const out=document.getElementById('trout');
  try {
    const r=await api('/api/translate/job',{method:'POST',body:{text,target_lang,use_glossary}});
    if(r.ok){
      // newest first, and the form is left exactly as it was: the person may
      // edit it and send the next one while this runs, which is the acceptance
      // criterion that could not be met while the answer arrived in the request
      S.trJobs=[r.json.job_id].concat(S.trJobs||[]);
      const c=r.json.sections||1;
      toast(t('traccepted').replace('{c}', c), true);
      trFollow();
    } else {
      // A REFUSAL GOES IN THE OUTPUT PANE, NOT IN A TOAST (#231): the
      // over-the-limit message is several sentences — the length sent, the
      // limit, why longer comes back wrong, and the two remedies — and a toast
      // scrolls away in 2.6 seconds with no second chance.
      out.style.color='var(--bad)';
      out.textContent=(r.json && r.json.error) || t('trfailed');
    }
  } finally { S.trSending=false; }
}

// ---- following the jobs this session submitted (#233) -----------------------
//
// ONE REQUEST FOR THE WHOLE CARD, not one per job: `GET /api/jobs` is the
// team's list and the followed ids are a filter on it. A poll per row would
// multiply with the number of translations somebody queues, which is the thing
// this screen now invites them to do.
//
// REFRESHES WHILE A STATUS IS ACTUALLY CHANGING AND NOT A MOMENT LONGER —
// QVIZ-6, the rule the Jobs and Queue cards already follow. The idle clock
// counts from the last REQUEST (#38), so a tab that polled for as long as it
// was open would hold a session alive indefinitely: an idle Translate tab must
// issue nothing, which is #233's fifth acceptance criterion and is why this is
// a generation-counted `setTimeout` rather than an interval.
async function trFollow(){
  return cardSwap('trjobs', async () => {
    const ids=S.trJobs||[];
    if(!ids.length) return trJobsCard(null);
    const r=await api('/api/jobs');
    if(!r.ok) return null;                      // leave the card alone
    const by={}; (r.json.jobs||[]).forEach(j=>{ by[j.id]=j; });
    const jobs=ids.map(id=>by[id]).filter(Boolean);
    const live=jobs.some(j=>j.status==='queued'||j.status==='running'||j.status==='canceling');
    // THE NEWEST SETTLED JOB GOES IN THE OUTPUT PANE, which is where this tab
    // has always painted an answer — and a FAILURE goes there too, for #231's
    // reason: the refusal a translation can meet is several sentences (which
    // section stopped, that nothing was stored, and the two remedies), and the
    // row's `error` badge alone leaves the one thing the person needs to read
    // nowhere on the screen.
    const settled=jobs.find(j=>j.status==='done'||j.status==='error');
    if(settled){
      const out=document.getElementById('trout');
      const res=settled.result && settled.result.result;
      const err=settled.error;
      if(out && typeof res==='string'){ out.style.color=''; out.textContent=res; }
      else if(out && typeof err==='string' && err){ out.style.color='var(--bad)'; out.textContent=err; }
    }
    if(live){ const gen=++S.trPoll;
              setTimeout(()=>{ if(S.tab==='translate'&&S.trPoll===gen) trFollow(); },2000); }
    return trJobsCard(jobs);
  });
}

// `null` is the first paint, before anything has been submitted: the card is
// omitted entirely rather than drawn empty, because a heading over no rows is
// a promise about a feature the person has not used yet.
function trJobsCard(jobs){
  // THE ID IS ON THE CARD ITSELF, not on a wrapper: `cardSwap` replaces the
  // element's `outerHTML`, so a built card without it swaps the id out of the
  // DOM and the next refresh finds nothing — `jobsListCard`'s own shape.
  // The empty form is a bare div rather than '' for the same reason: there has
  // to be something for the first swap to find.
  if(!jobs || !jobs.length) return '<div id="trjobs"></div>';
  const rows=jobs.map(j=>`<tr><td class="mono muted">${esc(j.id.slice(0,8))}</td>`
    + `<td>${jobStatusBadge(j.status)}${jobWaitBadge(j)}</td>`
    + `<td>${trProgress(j)}</td>`
    + `<td style="white-space:nowrap">${jobTook(j)}</td>`
    + `<td>${(j.status==='queued'||j.status==='running')?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>doTrCancel((j.id)))}">${t('cancel')}</button>`:''}</td></tr>`).join('');
  return `<div class="card" id="trjobs" style="margin-top:14px"><h3>${t('trjobs')}</h3>
    <table><thead><tr><th>job</th><th>status</th><th>${t('trcolsections')}</th><th>${t('trcolelapsed')}</th><th></th></tr></thead>
    <tbody>${rows}</tbody></table></div>`;
}

// SAID ONLY WHEN THERE IS MORE THAN ONE UNIT OF WORK. The pair is withdrawn by
// the server for a kind that does not report it (TR-9), and "1 of 1 sections"
// tells a reader nothing — #178's rule about a figure that decorates rather
// than informs.
function trProgress(j){
  const pr=j.progress;
  if(!pr || pr==='null' || !(pr.total>1)) return '';
  const pct=Math.round(100*Math.min(pr.done,pr.total)/pr.total);
  return `<span class="muted">${esc(t('trprogress').replace('{d}', pr.done).replace('{n}', pr.total))}</span>`
    + `<div style="height:4px;background:var(--line);border-radius:2px;margin-top:4px">`
    + `<div style="height:4px;width:${pct}%;background:var(--accent3);border-radius:2px"></div></div>`;
}

// Cancel refreshes THIS card, not the Jobs tab's — `doCancelJob` calls
// `jobsRefresh()`, which on this tab would find no `jobscard` and do nothing,
// leaving a cancelled row still saying `running` until the next poll.
async function doTrCancel(id){
  const r=await api('/api/jobs/'+id+'/cancel',{method:'POST'});
  if(r.ok) toast(t('canceled'),true); else toast((r.json&&r.json.error)||t('error'));
  trFollow();
}

async function doAddTerm(){
  const r=await api('/api/glossary',{method:'POST',body:{target_lang:val('gltgt'),term:val('glterm'),translation:val('gltr')}});
  if(r.ok){ toast('added',true); renderTab(); } else toast(r.json.error||'error');
}
// Views are async, and renderTab() is fired from click handlers without being awaited — so two
// renders can be in flight at once and the SLOWER one would win the innerHTML assignment, painting
// a stale tab over the one you just asked for. Stamp each render and drop any result that a newer
// render has superseded.
let renderSeq = 0;
async function renderTab(){ hPassStart(); try {
  const el=document.getElementById('main'); const seq = ++renderSeq;
  // A PASS CAN OUTLIVE THE SHELL IT PAINTS INTO. Signing out replaces `#app` with
  // the auth view, and a render already in flight — the jobs poll's tick, a
  // click — then found no `#main` and threw "Cannot set properties of null
  // (setting 'innerHTML')", which the e2e gate counts as a page error. There is
  // nothing to paint into, so the pass is DONE; the `finally` closes its bracket.
  if (!el) return;
  // THE FORM IS READ BEFORE IT IS REPLACED. A toolbar button, a tag chip and the
  // view/zen toggles all end in a render, and the render rebuilds the tab from
  // its template — so the title, the tags and the visibility were discarded by
  // any of them while the body survived in S. Reading the draft here is the one
  // seam every render passes through, and it no-ops when no note form is on
  // screen. See `noteDraftRead` in 03-tabs.js.
  noteDraftRead();
  el.innerHTML='<p class="muted">…</p>';
  const html = await ({chat:chatView,agent:agentView,translate:translateView,search:searchView,notes:notesView,documents:documentsView,repository:repoView,workflows:workflowsView,reviews:reviewsView,knowledge:knowledgeView,research:researchView,jobs:jobsView,beta:betaTabView,team:teamView,usage:usageView,health:healthView,localize:localizeView,admin:adminView}[S.tab]||chatView)();
  if (seq !== renderSeq) return;                    // superseded mid-flight — discard, don't clobber
  el.innerHTML = html;
  // #230: the URL mirrors the view, and THIS is the one seam every view change
  // passes through — `go()`, `wfOpen`, `repoOpenDetail`, `qSet`, `qGo` and the
  // palette all end here, so none of them had to learn about the address bar.
  // A re-render with unchanged state writes nothing, which is what stops a live
  // run's 1.5s poll from flooding the history with an entry per tick.
  // a prefilled prompt is sized on arrival; a grow-on-input handler never sees it
  growAll();
  countAll();
  // The viewed note's card is drawn ABOVE the list, so opening a note from a row
  // near the bottom of a long tab painted it off the top of the screen and read
  // as "nothing happened" — the report #176/UX-1 fixed for the repository, which
  // `revealEl` then answered for the run form. Same rule: reveal when it is not
  // already comfortably on screen, and never animate for a reduced-motion reader.
  revealEl('notecard');
  navigate();
  // #185: the bracket closes in a `finally` because of the early return above —
  // a range left open swallows every registration made after the pass, which is
  // how the first version swept the palette's own input.
} finally { hPassEnd(); } }
// allowlisted font stacks — no CDN, no external fetch (privacy + deterministic deps)
function fontStack(n){ const m={System:'ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif',
  Serif:'Georgia,Cambria,"Times New Roman",serif',Mono:'ui-monospace,SFMono-Regular,Menlo,monospace',
  Rounded:'ui-rounded,"SF Pro Rounded",system-ui,sans-serif'}; return m[n]||m.System; }
// asset://<id> → our own origin (never an external URL); data:/http passthrough
function assetUrl(ref){ if(!ref) return ''; return ref.indexOf('asset://')===0 ? '/api/beta/asset/'+ref.slice(8) : ref; }
// theme tokens → inline CSS custom properties; values sanitized to prevent style breakout
function bxSan(v){ return String(v==null?'':v).replace(/[;"{}<>]/g,''); }
function bxVars(cfg){ const th=(cfg&&cfg.theme)||{}; const mode=th.mode||'dark';
  const line=th.line||(mode==='light'?'rgba(0,0,0,.12)':'rgba(255,255,255,.10)');
  const hero=th.heroImage
    ? `linear-gradient(rgba(0,0,0,.45),rgba(0,0,0,.45)),url(${assetUrl(th.heroImage)}) center/cover`
    : (th.heroBg||'transparent');
  const font=th.fontFile ? 'bxcustom,'+fontStack(th.fontBody) : fontStack(th.fontBody);
  const pairs=[['--bx-bg',th.bg||'#0b1a2b'],['--bx-surface',th.surface||'#12253a'],['--bx-ink',th.ink||'#f2ede1'],
    ['--bx-muted',th.muted||'#93a4b8'],['--bx-brand',th.brand||'#c9a227'],['--bx-brandink',th.brandInk||'#132c46'],
    ['--bx-radius',th.radius||'12px'],['--bx-hero',hero],['--bx-line',line],
    ['--bx-font',font],['--bx-fontd',th.fontFile?'bxcustom,'+fontStack(th.fontDisplay||th.fontBody):fontStack(th.fontDisplay||th.fontBody)]];
  return pairs.map(([k,v])=>k+':'+bxSan(v)).join(';'); }
// one field input (scoped ids bf_<key>); shared by the live page and the editor preview
// The funnel's own language switcher. Driven by `cfg.locales`, which the server
// derives from the experience document — so it can only ever offer a language the
// funnel actually has copy for. Hidden when the operator has turned negotiation
// off instance-wide, and when there is only one language to pick.
function bxLangBtns(cfg){
  const av = (cfg && cfg.locales) || [];
  if(!S.i18n.enabled || av.length < 2) return '';
  const cur = (cfg && cfg.locale) || S.lang;
  return `<span class="bx-lang">${av.map(l=>
    `<button type="button" class="${cur===l?'active':''}" data-h-click="${H((el,ev)=>bxSetLang((l)))}">${esc(LANGNAME[l]||l.toUpperCase())}</button>`
  ).join('')}</span>`;
}
// ?lang= is the funnel's carrier, not localStorage: a funnel is a page people are
// LINKED to, so the switcher has to leave a shareable URL behind. It also sets
// S.lang so the chrome ("Thanks — your request is in review") follows the copy.
function bxSetLang(l){
  S.lang = l;
  try{
    const u = new URL(location.href);
    u.searchParams.set('lang', l);
    history.replaceState(null, '', u);
  }catch(e){}
  render();
}
// The SERVER is the authority on whether a submission is acceptable — these
// attributes are here for the things only the browser can do: cap typing at
// maxlength, put a numeric keypad in front of a 法人番号 on a phone, and mark a
// required field for assistive tech. Deliberately NOT a second copy of the
// validation messages, which would drift from locales/*.json the first time one
// of them changed.
function bxAttrs(f){
  let a='';
  if(f.required) a+=' required aria-required="true"';
  if(Number.isInteger(f.minlength)&&f.minlength>0) a+=` minlength="${f.minlength}"`;
  if(Number.isInteger(f.maxlength)&&f.maxlength>0) a+=` maxlength="${f.maxlength}"`;
  if(f.digits) a+=' inputmode="numeric" pattern="[0-9]*"';
  return a;
}
function bxField(f){ const id='bf_'+f.key; const req=f.required?' *':'';
  const at=bxAttrs(f);
  if(f.type==='textarea') return `<label>${esc(f.label)}${req}</label><textarea id="${id}" rows="3"${at}></textarea>`;
  if(f.type==='select') return `<label>${esc(f.label)}${req}</label><select id="${id}"${f.required?' required':''}><option value=""></option>${(f.options||[]).map(o=>`<option>${esc(o)}</option>`).join('')}</select>`;
  const itype=f.type==='email'?'email':(f.type==='tel'?'tel':'text');
  return `<label>${esc(f.label)}${req}</label><input id="${id}" type="${itype}"${f.type==='tel'?' inputmode="tel" autocomplete="tel"':''}${at}>`; }
// the Tier-A landing shell — same component for the public page ('live') and the editor ('preview')
function renderLandingShell(cfg, mode){
  cfg=cfg||{}; const live=mode!=='preview'; const fields=cfg.fields||[];
  const nav=(cfg.nav||[]).map(n=>`<a href="${live?esc(n.href||'#'):'#'}">${esc(n.label||'')}</a>`).join('');
  const details=(cfg.details||[]).filter(d=>d&&(d.heading||d.body)).map(d=>`<div><h3>${esc(d.heading||'')}</h3><p>${esc(d.body||'')}</p></div>`).join('');
  const form=`<div id="betaform">${fields.map(bxField).join('')}
      <input id="bf__hp" name="_hp" tabindex="-1" autocomplete="off" aria-hidden="true" style="position:absolute;left:-9999px;width:1px;height:1px;opacity:0">
      <button class="bx-cta" ${live?`data-h-click="${H((el,ev)=>doBetaSignup())}"`:'disabled'}>${esc(cfg.cta||'Request access')}</button></div>
      <div id="betamsg" style="margin-top:10px"></div>`;
  const th=cfg.theme||{};
  const fontFace = th.fontFile ? `<style>@font-face{font-family:bxcustom;font-display:swap;src:url(${esc(assetUrl(th.fontFile))})}</style>` : '';
  // The Mentor mark rides along only on an UNBRANDED funnel. An operator who has
  // uploaded a logo, or renamed the wordmark, is running their own brand here —
  // putting our helm beside "Acme" would be worse than showing no mark at all.
  const logoText = cfg.logo || 'TMach';
  const logo = cfg.logoImage
    ? `<img class="bx-logo-img" src="${esc(assetUrl(cfg.logoImage))}" alt="${esc(cfg.logo||'')}">`
    : `<div class="bx-logo">${logoText === 'TMach' ? markSVG(26) : ''}<span>${esc(logoText)}</span></div>`;
  return `${fontFace}<div class="bx" style="${bxVars(cfg)}"><div class="bx-wrap">
    <header class="bx-head">${logo}<nav class="bx-nav">${nav}${live?bxLangBtns(cfg):''}</nav></header>
    <section class="bx-hero">${cfg.eyebrow?`<div class="bx-eyebrow">${esc(cfg.eyebrow)}</div>`:''}<h1>${esc(cfg.title||'')}</h1><p>${esc(cfg.subtitle||'')}</p></section>
    <div class="bx-main">
      <div class="bx-card">${form}</div>
      <div class="bx-details">${details||''}${live&&cfg.showSignIn!==false?`<p class="bx-signin" style="margin-top:8px"><a href="#" data-h-click="${H((el,ev)=>{teamSignIn();return false})}">${t('teamsignin')} →</a></p>`:''}</div>
    </div>
    <footer class="bx-foot">${esc(cfg.footer||'')}</footer>
  </div></div>`;
}
// ?lang= wins over the instance default so a shared link lands in its language.
function funnelLang(){
  const q = new URLSearchParams(location.search).get('lang');
  return (q && S.i18n.enabled) ? q : S.lang;
}
async function betaLandingView(){
  const lang=funnelLang();
  const r=await api('/api/beta/config?lang='+encodeURIComponent(lang));
  const cfg=r.ok?r.json:{title:'Beta',subtitle:'',fields:[],locales:[]};
  // The server decides which locale the funnel is actually answered in; follow it
  // so the chrome cannot end up in a different language from the copy — and
  // re-fetch the chrome's own catalog when that moves it (the shell loaded the
  // catalog for the instance default before it knew about ?lang=; without this
  // the copy was Japanese and the sign-in link and "verifying…" stayed English).
  if(cfg.locale) S.lang=cfg.locale;
  if(S.catLocale!==S.lang) await loadCatalog();
  const ch=await api('/api/beta/challenge'); S.betaChallenge = ch.ok?ch.json:null;   // issued at load → human fill time passes the min-age gate
  return renderLandingShell(cfg,'live');
}
// FNV-1a 32-bit — byte-for-byte identical to domain/beta/antispam.rkt powhash (ASCII).
function powhash(s){ let h=2166136261>>>0; for(let i=0;i<s.length;i++){ h=(h^s.charCodeAt(i))>>>0; h=Math.imul(h,16777619)>>>0; } return h>>>0; }
function solvePow(nonce,difficulty){ const mask=(difficulty>=32)?0xFFFFFFFF:(((1<<difficulty)>>>0)-1); for(let n=0;;n++){ if((powhash(nonce+':'+n)&mask)===0) return n; } }
async function doBetaSignup(){
  const msg=document.getElementById('betamsg'); msg.innerHTML=`<span class="muted">${esc(t('bxverifying'))}</span>`;
  // no ?lang= needed: an overlay may localize a field's LABEL but never its key,
  // so the submitted body is identical in every language (experience.rkt).
  const cfgR=await api('/api/beta/config'); const fields=cfgR.ok?cfgR.json.fields:[];
  if(!S.betaChallenge){ const chR=await api('/api/beta/challenge'); S.betaChallenge=chR.ok?chR.json:null; }
  if(!S.betaChallenge){ msg.innerHTML=`<span class="badge">${esc(t('bxrestart'))}</span>`; return; }
  const {challenge,difficulty,honeypot}=S.betaChallenge;
  const pow=solvePow(challenge.split('.')[0], difficulty);      // proof of work (CPU cost per signup)
  const body={}; for(const f of fields){ const el=document.getElementById('bf_'+f.key); if(el) body[f.key]=el.value; }
  const hp=document.getElementById('bf__hp'); body[honeypot||'_hp']=hp?hp.value:'';
  body.challenge=challenge; body.pow=pow;
  const res=await api('/api/beta/signup',{method:'POST',body});
  if(res.ok){ document.getElementById('betaform').style.display='none';
    msg.innerHTML=`<b>${esc(t('bxthanks'))}</b><br><span class="muted">${esc(t('bxtouch'))}</span>`; }
  else { S.betaChallenge=null; msg.innerHTML=`<span class="badge">${esc(res.json.error||'error')}</span>`; }   // drop the used/stale challenge
}
function teamSignIn(){ S.forceLogin=true; render(); }
function activateView(token){
  return `<div class="auth">
    <h1 class="brand">${brandLockup(38)}</h1>
    <p class="muted">${t('welcome')}</p>
    <div class="card">
      <h2>${t('setpw')}</h2>
      <input type="hidden" id="atok" value="${esc(token)}">
      <label>${t('newpw')}</label><input id="apw" type="password" autofocus>
      <label>${t('confirmpw')}</label><input id="apw2" type="password">
      <button class="btn" style="width:100%" data-h-click="${H((el,ev)=>doActivate())}">${t('activate')}</button>
    </div></div>`;
}
async function doActivate(){
  const pw=val('apw'), pw2=val('apw2'), token=document.getElementById('atok').value;
  if(pw.length<8){ toast('password must be at least 8 characters'); return; }
  if(pw!==pw2){ toast('passwords do not match'); return; }
  const r=await api('/api/activate',{method:'POST',body:{token,password:pw}});
  if(r.ok){ S.token=r.json.token; localStorage.setItem('tmx_token',S.token); history.replaceState({},'','/'); toast('welcome!',true); render(); }
  else toast(r.json.error||'activation failed');
}
// #239: the Documents tab files into the SAME prefix the Repository tab
// navigates, which is what makes "write chapters, build up a report, upload
// information" one project rather than two trees.
function docGo(prefix){ S.docPrefix=prefix; S.docOffset=0; S.docEdit=null; renderTab(); }
async function documentsView(){
  const off=S.docOffset||0;
  const prefix=S.docPrefix||'';
  const r=await api('/api/documents?offset='+off+(prefix?'&prefix='+encodeURIComponent(prefix):''));
  const docs=r.ok?r.json.documents:[]; const next=r.ok?r.json.next_offset:null;
  const nav=r.ok?pathNav(r.json.folders, prefix, docGo):'';
  // #180: `PUT /api/documents/:id` has existed as long as the route table and
  // the console called it nowhere, exactly as for notes. Same editor, same
  // edit path — the issue's "three bare textareas becoming three different
  // editors" is avoided by there being one component, not three.
  const editing = S.docEdit ? docs.filter(d=>d.id===S.docEdit)[0] : null;
  const rows=docs.map(d=>`<tr><td>${esc(d.title||'—')}<div class="muted mono" style="font-size:12px">${esc(d.key||'')}</div></td><td><span class="badge">${esc(d.visibility)}</span></td><td class="muted">${esc((d.content||'').slice(0,60))}</td><td><button class="btn sm ghost" data-h-click="${H((el,ev)=>docEdit((d.id),(d.content)))}">${t('edit')}</button> <button class="btn sm ghost" data-h-click="${H((el,ev)=>doDelDoc((d.id)))}">${t('del')}</button></td></tr>`).join('');
  const card = editing
    ? `<div class="card"><h3>${t('editdoc')} <span class="muted" style="font-size:13px">${esc(editing.title||'')}</span></h3>
      <label>${t('title')}</label><input id="dt" value="${esc(editing.title||'')}">
      <div class="muted mono" style="font-size:12px;margin-top:4px">${esc(editing.key||'')}</div>
      <div class="muted" style="font-size:12px">${t('docmovehint')}</div>
      <label>${t('content')}</label>${editorHTML('doc', {id:'dc'})}
      <label>${t('visibility')}</label><select id="dv">${
        ['team','private'].map(x=>`<option${x===editing.visibility?' selected':''}>${x}</option>`).join('')}</select>
      <button class="btn" data-h-click="${H((el,ev)=>doSaveDoc())}">${t('save')}</button>
      <button class="btn ghost" style="margin-left:8px" data-h-click="${H((el,ev)=>docEditCancel())}">${t('cancel')}</button>
      <div class="row" style="margin-top:10px;gap:8px"><div style="flex:0 0 auto"><button class="btn sm ghost"
        data-h-click="${H(()=>edExport('doc', (document.getElementById('dt')||{}).value||'document'))}">${t('edexport')}</button></div></div></div>`
    : `<div class="card"><h3>${t('newdoc')}</h3>
      <label>${t('title')}</label><input id="dt">
      <label>${t('key')}</label><input id="dk" placeholder="levee-7/chapters/" value="${esc(prefix)}">
      <div class="muted" style="font-size:12px">${t('dockeyhint')}</div>
      <label>${t('content')}</label>${editorHTML('doc', {id:'dc'})}
      <label>${t('visibility')}</label><select id="dv"><option>team</option><option>private</option></select>
      <button class="btn" data-h-click="${H((el,ev)=>doCreateDoc())}">${t('create')}</button>
      <div class="row" style="margin-top:10px;gap:8px"><div style="flex:0 0 auto"><button class="btn sm ghost"
        data-h-click="${H(()=>edExport('doc', (document.getElementById('dt')||{}).value||'document'))}">${t('edexport')}</button></div></div></div>`;
  return `<h2>${t('documents')}</h2>
    ${card}
    <div class="card" style="margin-top:14px">${nav?`<div style="margin-bottom:10px">${nav}</div>`:''}<table><thead><tr><th>${t('title')}</th><th>${t('visibility')}</th><th>${t('content')}</th><th></th></tr></thead><tbody>${rows}</tbody></table>
      <div class="row" style="margin-top:8px">${off>0?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>doMoreDocs(0))}">« first</button>`:''}${(typeof next==='number')?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>doMoreDocs((next)))}">more »</button>`:''}</div></div>`;
}
function docEdit(id, content){ S.docEdit=id; edReset('doc', content, 'dc'); renderTab(); }
function docEditCancel(){ S.docEdit=null; edReset('doc', '', 'dc'); renderTab(); }
async function doSaveDoc(){
  const r=await api('/api/documents/'+S.docEdit,{method:'PUT',
    body:{title:val('dt'), content:edRead('doc'), visibility:val('dv')}});
  if(r.ok){ S.docEdit=null; edReset('doc','', 'dc'); toast(t('saved'),true); renderTab(); }
  else toast((r.json&&r.json.error)||'error');
}
async function doCreateDoc(){ const r=await api('/api/documents',{method:'POST',body:{title:val('dt'),content:edRead('doc'),key:val('dk'),visibility:val('dv')}});
  if(r.ok){ S.docOffset=0; edReset('doc','', 'dc'); toast('created',true); renderTab(); } else toast(r.json.error||'error'); }
async function doDelDoc(id){ const r=await api('/api/documents/'+id,{method:'DELETE'});
  if(r.ok){ if(S.docEdit===id){ S.docEdit=null; edReset('doc','', 'dc'); } toast('deleted',true); renderTab(); } else toast(r.json.error||'error'); }
function doMoreDocs(off){ S.docOffset=off; renderTab(); }
function jobStatusBadge(s){ return s==='done'?'<span class="badge ok">done</span>':`<span class="badge">${esc(s)}</span>`; }
function jobResultText(j){
  if(j.status==='error') return j.error||'';
  const r=j.result; if(!r||r==='null') return '';
  if(typeof r==='object') return (r.reply||r.result||JSON.stringify(r)).toString().slice(0,70);
  return (''+r).slice(0,70);
}
