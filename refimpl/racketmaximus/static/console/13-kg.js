// ---------- knowledge graph (slice 61) ----------
// Lists with citations, no graph library (KG-6): an entity browser, and for one
// entity its relations and every mention with a link to the document. Everything
// shown passed the mention rule server-side.
S.kg={q:'',type:'',sel:null};
async function knowledgeView(){
  const r=await api('/api/kg/entities?q='+encodeURIComponent(S.kg.q)+'&type='+encodeURIComponent(S.kg.type));
  if(!r.ok) return `<h2>${t('knowledge')}</h2><div class="card"><p class="muted">${esc(r.json.error||'unavailable')}</p></div>`;
  const ents=r.json.entities||[], st=r.json.stats||{}, types=r.json.types||[];
  const rows=ents.map(e=>`<tr>
      <td><b>${esc(e.name)}</b>${e.description?`<div class="muted" style="font-size:12px">${esc(e.description)}</div>`:''}</td>
      <td><span class="badge">${esc(e.type)}</span></td>
      <td class="muted">${esc(e.relation_count)} · ${esc(e.mention_count)}</td>
      <td><button class="btn sm ghost" data-h-click="${H((el,ev)=>kgOpen((e.id)))}">${t('details')}</button></td></tr>`).join('');
  return `<h2>${t('knowledge')}
      <span class="muted" style="font-size:14px">${esc(st.entities||0)} ${t('kg_entities')} · ${esc(st.relations||0)} ${t('kg_relations')} · ${esc(st.documents||0)} ${t('kg_documents')}${st.unextracted?` · ${esc(st.unextracted)} ${t('kg_unextracted')}`:''}</span></h2>
    <div class="card">
      <div class="muted" style="font-size:12px;margin-bottom:8px">${t('kg_hint')}</div>
      <div class="row" style="align-items:end">
        <div style="flex:2"><label>${t('kg_search')}</label><input id="kgq" value="${esc(S.kg.q)}" data-h-keydown="${H((el,ev)=>{if(ev.key==='Enter')kgSearch()})}"></div>
        <div style="flex:1"><label>${t('kg_type')}</label>
          <select id="kgtype"><option value="">${t('kg_alltypes')}</option>${types.map(x=>`<option value="${esc(x)}"${S.kg.type===x?' selected':''}>${esc(x)}</option>`).join('')}</select></div>
        <div style="flex:none"><button class="btn" data-h-click="${H((el,ev)=>kgSearch())}">${t('search')}</button>
          ${canPerm('workflows:run')?`<button class="btn ghost" data-h-click="${H((el,ev)=>kgExtract())}">${t('kg_extract')}</button>`:''}</div>
      </div>
      ${ents.length?`<table style="margin-top:10px"><thead><tr><th>${t('kg_entity')}</th><th>${t('kg_type')}</th><th>${t('kg_relations')} · ${t('kg_mentions')}</th><th></th></tr></thead><tbody>${rows}</tbody></table>`
                   :`<p class="muted" style="margin-top:10px">${t('kg_none')}</p>`}
    </div>
    <div id="kgdetail">${S.kg.sel?await kgDetailHtml(S.kg.sel):''}</div>`;
}
function kgSearch(){ S.kg.q=val('kgq'); S.kg.type=val('kgtype'); S.kg.sel=null; renderTab(); }
async function kgOpen(id){ S.kg.sel=id; const el=document.getElementById('kgdetail'); if(el) el.innerHTML=await kgDetailHtml(id); }
async function kgExtract(){
  const r=await api('/api/kg/extract',{method:'POST'});
  if(r.ok){ toast(t('kg_queued'),true); go('workflows'); S.wfRun=r.json.id; S.wfPoll++; renderTab(); } else toast(r.json.error||'error');
}
function kgOpenDoc(id){ go('repository'); setTimeout(()=>repoOpenDetail(id),400); }
async function kgDetailHtml(id){
  const r=await api('/api/kg/entities/'+encodeURIComponent(id));
  if(!r.ok) return `<div class="card" style="margin-top:14px"><p class="muted">${esc(r.json.error||'not found')}</p></div>`;
  const e=r.json;
  const rels=(e.relations||[]).map(x=>`<tr>
      <td>${x.direction==='out'?`<b>${esc(e.name)}</b>`:`<a href="#" data-h-click="${H((el,ev)=>{kgOpen((x.subject_id));return false})}">${esc(x.subject)}</a>`}</td>
      <td class="mono muted">${esc(x.predicate)}</td>
      <td>${x.direction==='in'?`<b>${esc(e.name)}</b>`:`<a href="#" data-h-click="${H((el,ev)=>{kgOpen((x.object_id));return false})}">${esc(x.object)}</a>`}</td>
      <td class="muted" style="font-size:12px">${(x.mentions||[]).map(m=>`<a href="#" data-h-click="${H((el,ev)=>{kgOpenDoc((m.object_id));return false})}" class="mono">${esc(m.key)}</a>`).join(', ')}</td></tr>`).join('');
  const ments=(e.mentions||[]).map(m=>`<tr><td><a href="#" data-h-click="${H((el,ev)=>{kgOpenDoc((m.object_id));return false})}" class="mono">${esc(m.key)}</a></td>
      <td class="muted">“${esc(m.snippet)}”</td></tr>`).join('');
  return `<div class="card" style="margin-top:14px">
    <div class="row" style="justify-content:space-between;align-items:center">
      <h3 style="margin:0">${esc(e.name)} <span class="badge">${esc(e.type)}</span></h3>
      <div style="flex:none"><button class="btn sm ghost" data-h-click="${H((el,ev)=>{S.kg.sel=null;document.getElementById('kgdetail').innerHTML=''})}">${t('close')}</button></div></div>
    ${e.description?`<p class="muted" style="margin:6px 0 0">${esc(e.description)}</p>`:''}
    <h4 style="margin:12px 0 6px">${t('kg_relations')}</h4>
    ${rels?`<table><tbody>${rels}</tbody></table>`:`<p class="muted">${t('kg_norelations')}</p>`}
    <h4 style="margin:12px 0 6px">${t('kg_mentions')}</h4>
    <table><tbody>${ments}</tbody></table></div>`;
}

// The field and the button are one `.searchbar` control (#176), full card width.
// The `label` is gone and the button's own word with it: the heading already says
// Search, so the old shape said it three times on one screen. A button with only
// a glyph needs an accessible name, hence title + aria-label — never a bare 🔍.
// `sendKey` is #174's shared Enter rule; the field has always sent on Enter and
// it must go on doing so.
async function searchView(){
  return `<h2>${t('search')}</h2>
    <div class="card">
      <div class="searchbar">
        <input id="sq" data-h-keydown="${H((el,ev)=>sendKey(ev,doSearch))}" placeholder="${t('searchph')}">
        <button class="btn" title="${esc(t('search'))}" aria-label="${esc(t('search'))}"
          data-h-click="${H((el,ev)=>doSearch())}">\u{1F50D}</button>
      </div>
      <div id="sres"></div></div>`;
}
// Two of this function's three messages shipped as English literals in a console
// that is otherwise entirely in the catalogs — so a Japanese operator searched
// and was told "no results" in English.
async function doSearch(){
  const q=val('sq'); const el=document.getElementById('sres');
  if(q.length<2){ el.innerHTML=`<p class="muted">${esc(t('searchmin'))}</p>`; return; }
  const r=await api('/api/search?q='+encodeURIComponent(q));
  const res=r.ok?r.json.results:[];
  el.innerHTML = res.length
    ? `<table><thead><tr><th>type</th><th>title</th><th>${t('results')}</th><th></th></tr></thead><tbody>`+
      res.map(x=>`<tr><td><span class="badge${x.type==='file'?' run':''}">${esc(x.type)}</span></td>
        <td class="${x.type==='file'?'mono':''}">${esc(x.title||'')}</td>
        <td class="muted">${esc(x.snippet||'')}</td>
        <td>${x.type==='file'?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>repoDownload((x.id),(x.title||'')))}">${t('download')}</button>`:''}</td></tr>`).join('')+`</tbody></table>`
    : `<p class="muted">${esc(t('noresults'))}</p>`;
}
// `render` awaits at several points (two rounds of fetches, then the tab's own).
// Anything that changes S while one is in flight — logout nulling S.me is the
// easy one — used to let the stale run resume and paint with the new state
// half-applied, which
// threw "Cannot read properties of null (reading 'is_operator')" out of
// appShell(). A generation counter makes the older run stand down at each await
// boundary, so the newest render always wins and no half-render reaches the DOM.
let shellSeq = 0;
async function render(){
  const seq = ++shellSeq;
  const stale = () => seq !== shellSeq;
  const app=document.getElementById('app');
  if(!S.idleWired){
    S.idleWired=true;
    const stay=document.getElementById('idlestay');
    if(stay) stay.addEventListener('click', idleStay);
    // 5s is fine: the warning counts down in whole seconds and the server is the
    // authority either way, so this only has to be prompt enough to be useful
    setInterval(idleTick, 5000);
  }
  const atok=new URLSearchParams(location.search).get('token');
  if(atok && location.pathname.replace(/\/$/,'').endsWith('/activate')){ app.innerHTML=activateView(atok); return; }
  // Two rounds, not five. These three are independent: branding and the instance
  // config are public, and whoami reads neither. Running them one after another
  // made every sign-in five sequential round trips — ~2.3s at 300ms each, which
  // is invisible on localhost and the whole of what made signing in feel slow.
  //
  // What is NOT parallelizable, and why the shape is two rounds rather than one:
  // loadCatalog needs the locale loadI18n resolves (?locale=, not the header),
  // and /api/features needs the principal refreshMe resolves. The theme still
  // lands before the first paint, because the whole round is awaited before
  // anything reaches #app.
  //
  // Ordering note: api() sends X-Telemachus-Locale: S.lang, so branding and
  // whoami now go out with the locale from the PREVIOUS pass. Neither reads it —
  // branding is operator-authored and whoami is ids, permissions and policy
  // numbers, with its `locale` field read from the database rather than the
  // header. Do not move a locale-SENSITIVE call into this round.
  await Promise.all([loadBranding(), loadI18n(), refreshMe()]);
  if(stale()) return;
  if(!S.me){
    await loadCatalog(); if(stale()) return;   // the sign-in screen's own copy
    const cfg = S.cfg ? {ok:true, json:S.cfg} : await api('/api/config');   // loadI18n() already fetched it
    if(stale()) return; S.home = cfg.ok ? cfg.json.home : 'login';
    const atLoginPath = location.pathname.replace(/\/$/,'').endsWith('/login');
    const forceLogin = S.forceLogin || atLoginPath || new URLSearchParams(location.search).get('login')==='1';
    if(S.home==='beta' && !forceLogin){
      const l = cfg.ok && cfg.json.landing;
      if(l && l.type==='bundle' && l.url){ location.replace(l.url); return; }   // Tier-B: hand-coded plugin bundle
      if(l && l.type==='template' && l.url){                                    // Tier-C: sandboxed custom HTML template
        app.innerHTML='<iframe class="bx-frame" sandbox="allow-scripts allow-forms allow-top-navigation-by-user-activation" src="'+l.url+'"></iframe>'; return; }
      const bx=await betaLandingView(); if(stale()) return;
      app.innerHTML=bx; return;                                                 // Tier-A: built-in themeable shell
    }
    paintAuth(app); return;
  }
  // round two, signed in: the catalog and the feature list do not depend on each
  // other, so they go together
  const [, fr] = await Promise.all([loadCatalog(), api('/api/features')]);
  if(stale()) return;
  // #177: the ROWS are what the server sent, and the map is derived from them in
  // the same breath. `GET /api/features` carries `disabled_by` — which layer said
  // no — and this used to drop it on the floor, so the team's Features card could
  // only ever show two states and offered an Enable button that a layer above
  // would 409. Two independently built maps is LIVE-IN's shape; one derivation
  // cannot disagree with itself.
  S.featRows = fr.ok ? fr.json.features : [];
  S.features = Object.fromEntries(S.featRows.map(x=>[x.feature,x.enabled]));
  if(S.features[S.tab]===false) S.tab='team';
  if(!S.me) return;                      // signed out while we were awaiting
  const wasAuth=!!document.getElementById('lu');
  app.innerHTML=appShell();
  if(wasAuth) fadeIn(app);                // sign-in → shell is a transition, not a cut
  renderTab(); }
window.localizeView=localizeView; window.l10nSetLocale=l10nSetLocale; window.l10nFilter=l10nFilter;
window.l10nPage=l10nPage; window.l10nSave=l10nSave; window.l10nReview=l10nReview;
window.l10nImport=l10nImport; window.l10nDraft=l10nDraft; window.l10nExport=l10nExport;
window.doLogin=doLogin; window.doBootstrap=doBootstrap; window.setLang=setLang; window.logout=logout; window.go=go;
window.doChat=doChat; window.doAgent=doAgent; window.doCreateNote=doCreateNote; window.doShare=doShare; window.doDelNote=doDelNote;
window.doAddMember=doAddMember; window.doSetQuota=doSetQuota; window.doChangePw=doChangePw; window.doToggleTool=doToggleTool;
window.doActivate=doActivate; window.doCreateToken=doCreateToken; window.doRevokeToken=doRevokeToken; window.doSearch=doSearch; window.doToggleFeature=doToggleFeature;
window.doCreateDoc=doCreateDoc; window.doDelDoc=doDelDoc; window.doMoreDocs=doMoreDocs;
window.doSubmitJob=doSubmitJob; window.doCancelJob=doCancelJob; window.doSeedSamples=doSeedSamples;
window.bxSetLang=bxSetLang; window.doBetaSignup=doBetaSignup; window.teamSignIn=teamSignIn; window.betaLandingView=betaLandingView; window.doDecide=doDecide;
window.betaSub=betaSub; window.bxSet=bxSet; window.bxSaveDraft=bxSaveDraft; window.bxPublish=bxPublish;
window.bxAddField=bxAddField; window.bxDelField=bxDelField; window.bxSetField=bxSetField;
window.bxAddDetail=bxAddDetail; window.bxDelDetail=bxDelDetail; window.bxUpload=bxUpload; window.bxClear=bxClear; window.bxSetLanding=bxSetLanding; window.S=S;
render();
