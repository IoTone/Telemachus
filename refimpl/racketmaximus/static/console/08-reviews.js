// ---------- reviews (LAY-1..3): the work a workflow parked for a person ----------
function reviewSubject(v){
  const s = v.subject;
  if (s == null) return '';
  if (typeof s === 'string') return s;
  // the common shape is {result: …}; show that rather than make a person read JSON
  if (typeof s === 'object' && !Array.isArray(s) && typeof s.result === 'string') return s.result;
  try { return JSON.stringify(s, null, 2); } catch(e){ return String(s); }
}
function reviewCard(v, open){
  const checks = (v.checklist||[]).map(c=>`
    <div style="margin-top:8px"><label>${esc(c.label)}${c.required?' *':''}</label>
      ${open?`<input id="rvq_${esc(v.id)}_${esc(c.key)}" placeholder="${esc(t('reviewnote'))}">`
            :`<div class="muted">${esc((v.answers||{})[c.key]||'—')}</div>`}</div>`).join('');
  const decided = v.status === 'decided';
  const head = `<div class="row" style="justify-content:space-between;align-items:center">
      <h3 style="margin:0">${esc(v.title)}</h3>
      <span class="muted">${decided?`${esc(t('reviewverdict_'+v.verdict)||v.verdict)}`
                                   :(v.four_eyes?esc(t('reviewfoureyes')):'')}</span></div>`;
  const body = `${v.instructions?`<p class="muted">${esc(v.instructions)}</p>`:''}
      <label>${t('reviewof')}</label>
      <pre class="mono" style="white-space:pre-wrap;max-height:220px;overflow:auto">${esc(reviewSubject(v))}</pre>
      ${checks}`;
  const actions = open ? `
      <div style="margin-top:10px"><label>${t('rationale')}</label>
        <textarea id="rvr_${esc(v.id)}" rows="2" placeholder="${esc(t('reviewwhy'))}"></textarea></div>
      <div class="row" style="margin-top:10px">
        <button class="btn" data-h-click="${H((el,ev)=>doDecide(v,'approve'))}">${t('reviewapprove')}</button>
        <button class="btn ghost" data-h-click="${H((el,ev)=>doDecide(v,'revise'))}">${t('reviewrevise')}</button>
        <button class="btn ghost" data-h-click="${H((el,ev)=>doDecide(v,'reject'))}">${t('reviewreject')}</button>
      </div>` : `<div class="muted" style="margin-top:10px">${esc(v.rationale||'')}</div>`;
  return `<div class="card" style="margin-top:14px">${head}${body}${actions}</div>`;
}
async function reviewsView(){
  const show = S.revShow || 'pending';
  const r = await api('/api/reviews?status='+encodeURIComponent(show));
  const items = (r.ok && r.json.reviews) ? r.json.reviews : [];
  const pick = ['pending','decided'].map(x=>
    `<button class="btn sm ${show===x?'':'ghost'}" data-h-click="${H((el,ev)=>{S.revShow=x; renderTab();})}">${x==='pending'?t('reviewpending'):t('reviewdecided')}</button>`).join(' ');
  const list = items.length
    ? items.map(v=>reviewCard(v, show==='pending')).join('')
    : `<div class="card" style="margin-top:14px"><p class="muted">${t('reviewnone')}</p></div>`;
  return `<h2>${t('reviews')}</h2><div class="row">${pick}</div>${list}`;
}
async function doDecide(v, verdict){
  const answers = {};
  (v.checklist||[]).forEach(c=>{ const e=document.getElementById('rvq_'+v.id+'_'+c.key);
                                 if(e && e.value.trim()) answers[c.key]=e.value.trim(); });
  const rt = document.getElementById('rvr_'+v.id);
  const r = await api('/api/reviews/'+v.id+'/decide',
                      {method:'POST', body:{verdict, rationale:(rt?rt.value:''), answers}});
  if(r.ok){ toast(t('reviewrecorded'), true); renderTab(); } else toast(r.json.error||'error');
}
// a queued job the platform is holding says so beside its status (issue #55).
// `waiting` is ABSENT when nothing holds it — it is then simply waiting for a
// free worker, and a badge claiming otherwise would be an invention.
function jobWaitBadge(j){
  const w=j.waiting; if(!w) return '';
  const txt = w.reason==='concurrency'
    ? t('heldbycap').replace('{limit}', esc(String(w.limit)))
    : t('heldbyquota').replace('{dimension}', esc(w.dimension||''));
  return ` <span class="badge op">${txt}</span>`;
}
async function jobsView(){
  const r=await api('/api/jobs'); const jobs=r.ok?r.json.jobs:[];
  const rows=jobs.map(j=>`<tr><td class="mono muted">${esc(j.id.slice(0,8))}</td><td>${esc(j.kind)}</td><td>${jobStatusBadge(j.status)}${jobWaitBadge(j)}</td><td class="muted">${esc(jobResultText(j))}</td><td>${(j.status==='queued'||j.status==='running')?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>doCancelJob((j.id)))}">${t('cancel')}</button>`:''}</td></tr>`).join('');
  return `<h2>${t('jobs')}</h2>
    <div class="card"><h3>${t('submitjob')}</h3>
      <div class="row" style="align-items:end">
        <div><label>kind</label><select id="jk"><option value="chat">chat</option><option value="translate">translate</option></select></div>
        <div style="flex:1"><label>${t('prompt')} / ${t('sourcetext')}</label><input id="jtext"></div>
        <div><label>${t('target')}</label><input id="jtgt" value="ja" style="width:90px"></div>
        <div><button class="btn" data-h-click="${H((el,ev)=>doSubmitJob())}">${t('submit')}</button></div></div></div>
    <div class="card" style="margin-top:14px"><div class="row" style="justify-content:space-between;align-items:center"><h3 style="margin:0">${t('jobs')}</h3><button class="btn sm ghost" data-h-click="${H((el,ev)=>renderTab())}">${t('refresh')}</button></div>
      <table style="margin-top:8px"><thead><tr><th>id</th><th>kind</th><th>status</th><th>result</th><th></th></tr></thead><tbody>${rows}</tbody></table></div>`;
}
async function doSubmitJob(){
  const kind=val('jk'), text=val('jtext');
  const payload = kind==='translate' ? {text, target_lang: val('jtgt')} : {prompt: text};
  const r=await api('/api/jobs',{method:'POST',body:{kind,payload}});
  if(r.ok){ toast('queued',true); renderTab(); } else toast(r.json.error||'error');
}
async function doCancelJob(id){
  const r=await api('/api/jobs/'+id+'/cancel',{method:'POST'});
  if(r.ok){ toast('canceled',true); renderTab(); } else toast(r.json.error||'error');
}
