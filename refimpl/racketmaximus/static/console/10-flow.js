// ---------- workflows (slice 48) ----------
// The console is a client of exactly the HTTP contract curl uses: list definitions,
// POST a run, poll the run. It knows nothing about how a step executes — that stays
// in the engine, which is why a plugin-shipped workflow and a JSON-published one
// render identically here.
function wfBadge(s){
  const cls = s==='done'?'ok':(s==='error'?'bad':(s==='running'?'run':''));
  return `<span class="badge ${cls}">${esc(s)}</span>`;
}
function wfJson(v,label){
  if(v===null||v===undefined||v==='null') return '';
  const j=JSON.stringify(v,null,2);
  if(j==='{}'||j==='null'||j===undefined) return '';
  return `<details><summary class="muted" style="cursor:pointer;font-size:12px">${esc(label)}</summary><pre class="wfjson">${esc(j)}</pre></details>`;
}
// a step's output is {result: …} — show the result inline, full object one click away
function wfOut(st){
  if(st.status==='error') return `<span style="color:var(--bad)">${esc((st.error||'failed').slice(0,140))}</span>`;
  const art = st.output && st.output.result && st.output.result.artifact;
  if(art && art.kind && art.title) return artifactCard(art) + wfJson(st.output,'json');
  const o=st.output; if(!o||o==='null'||typeof o!=='object') return '<span class="muted">—</span>';
  if(Array.isArray(o.results))                       // a map parent — its children carry the detail
    return `<span class="muted">${o.results.length} ${t('results').toLowerCase()}</span>${wfJson(o,'json')}`;
  const r=('result' in o)?o.result:o;
  const line=(typeof r==='string'?r:JSON.stringify(r))||'';
  return `<span class="mono" style="font-size:13px">${esc(line.slice(0,140))}${line.length>140?'…':''}</span>${wfJson(o,'json')}`;
}

// ---- Automations (slice 58, DWF step 4): triggers, "when a document matching this
// lands, run that workflow with it". The card shows the team's remaining AI budget
// because a trigger whose runs sit queued is a team out of tokens, not a broken trigger.
async function automationsCard(defs){
  const r=await api('/api/doc-triggers');
  if(!r.ok) return '';
  const trg=r.json.triggers||[], b=r.json.budget||{};
  const budget=(b.limit===null||b.limit===undefined) ? t('nolimit') : `${esc(b.remaining)} / ${esc(b.limit)} ${t('tokensleft')}`;
  const rows=trg.map(x=>`<tr>
      <td><b>${esc(x.workflow_slug)}</b><div class="muted mono" style="font-size:12px">${esc(x.match_prefix||'*')}${x.match_types?' · '+esc(x.match_types):''}${x.match_attrs&&Object.keys(x.match_attrs).length?' · '+esc(Object.entries(x.match_attrs).map(([k,v])=>k+':'+v).join(', ')):''}${x.fire_on_derived?' · '+t('trigger_derived'):''}</div></td>
      <td>${x.enabled?'<span class="badge ok">'+t('enabled')+'</span>':'<span class="badge">'+t('disabled')+'</span>'}</td>
      <td style="white-space:nowrap">
        <button class="btn sm ghost" data-h-click="${H((el,ev)=>trgHistory((x.id)))}">${t('fires')}</button>
        ${canPerm('workflows:write')?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>trgToggle((x.id),(x.enabled?'false':'true')))}">${x.enabled?t('disable'):t('enable')}</button>
        <button class="btn sm bad" data-h-click="${H((el,ev)=>trgDelete((x.id)))}">${t('del')}</button>`:''}
      </td></tr>`).join('');
  const wopts=defs.map(d=>`<option value="${esc(d.slug)}"${d.slug==='process-upload'?' selected':''}>${esc(d.name||d.slug)}</option>`).join('');
  const form=canPerm('workflows:write')?`<div class="row" style="align-items:end;margin-top:10px">
      <div style="flex:1"><label>${t('workflow')}</label><select id="tg_wf">${wopts}</select></div>
      <div style="flex:1"><label>${t('trigger_prefix')}</label><input id="tg_prefix" placeholder="inbox/invoices/"></div>
      <div style="flex:1"><label>${t('trigger_types')}</label><input id="tg_types" placeholder="application/pdf, text/plain"></div>
      <div style="flex:1"><label>${t('trigger_attrs')}</label><input id="tg_attrs" placeholder="doc_type:invoice"></div>
      <div style="flex:none"><label><input type="checkbox" id="tg_derived"> ${t('trigger_derived')}</label></div>
    </div>
    <label>${t('trigger_input')}</label>
    <textarea id="tg_input" rows="4">${esc(JSON.stringify({schema:PIPELINE_EXAMPLE_SCHEMA,template:'',locales:[]},null,1))}</textarea>
    <div style="margin-top:8px"><button class="btn" data-h-click="${H((el,ev)=>trgCreate())}">${t('addtrigger')}</button></div>`:'';
  return `<div class="card" style="margin-top:14px">
    <div class="row" style="justify-content:space-between;align-items:center">
      <h3 style="margin:0">${t('automations')}</h3>
      <div class="muted" style="flex:none;font-size:12px">${t('budget')}: ${budget}</div></div>
    <div class="muted" style="font-size:12px;margin:4px 0 8px">${t('automationshint')}</div>
    ${trg.length?`<table><thead><tr><th>${t('workflow')}</th><th>${t('status')}</th><th></th></tr></thead><tbody>${rows}</tbody></table>`
                :`<p class="muted">${t('notriggers')}</p>`}
    <div id="tg_history"></div>
    ${form}</div>`;
}
async function trgCreate(){
  let input={}; const raw=(val('tg_input')||'').trim();
  if(raw){ try{ input=JSON.parse(raw); }catch(e){ return toast('input: invalid JSON'); } }
  // `key:value, key2:value2` — the same words as the ?attr= filter on the
  // repository, so an operator who can find documents by type triggers on it in
  // the spelling they already know. The server validates; a malformed pair is a
  // 400 that names it, which is better than guessing here.
  const match_attrs={};
  for(const pair of (val('tg_attrs')||'').split(',')){
    const s=pair.trim(); if(!s) continue;
    const i=s.indexOf(':'); if(i<1) return toast('attributes: write key:value');
    match_attrs[s.slice(0,i).trim()]=s.slice(i+1).trim();
  }
  const r=await api('/api/doc-triggers',{method:'POST',body:{workflow_slug:val('tg_wf'),match_prefix:val('tg_prefix'),
    match_types:val('tg_types'),match_attrs,input,fire_on_derived:!!document.getElementById('tg_derived').checked}});
  if(r.ok){ toast(t('triggeradded'),true); renderTab(); } else toast(r.json.error||'error');
}
async function trgToggle(id,on){
  const r=await api('/api/doc-triggers/'+encodeURIComponent(id),{method:'PATCH',body:{enabled:on}});
  if(r.ok) renderTab(); else toast(r.json.error||'error');
}
async function trgDelete(id){
  const r=await api('/api/doc-triggers/'+encodeURIComponent(id),{method:'DELETE'});
  if(r.ok){ toast(t('deleted'),true); renderTab(); } else toast(r.json.error||'error');
}
async function trgHistory(id){
  const r=await api('/api/doc-triggers/'+encodeURIComponent(id));
  const el=document.getElementById('tg_history'); if(!el) return;
  if(!r.ok) return toast(r.json.error||'error');
  const fires=r.json.fires||[];
  el.innerHTML=`<div style="margin-top:8px"><b>${t('fires')}</b> — <span class="mono muted">${esc(r.json.match_prefix||'*')}</span>
    ${fires.length?`<table style="margin-top:4px"><tbody>${fires.map(f=>`<tr><td class="mono">${esc(f.key||f.object_id)}</td>
      <td class="muted" style="font-size:12px">${esc(f.fired_at)}</td>
      <td>${f.run_id?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>repoViewRun((f.run_id)))}">${t('viewrun')}</button>`:`<span class="badge bad">${esc(f.error||'—')}</span>`}</td></tr>`).join('')}</tbody></table>`
                 :`<p class="muted" style="margin:4px 0 0">${t('nofires')}</p>`}</div>`;
}

async function workflowsView(){
  if(S.wfRun) return await wfRunView(S.wfRun);
  const [dr,rr]=await Promise.all([api('/api/workflows'),api('/api/runs')]);
  if(!dr.ok) return `<h2>${t('workflows')}</h2><div class="card"><p class="muted">${esc(dr.json.error||'unavailable')}</p></div>`;
  const defs=dr.json.workflows||[], runs=rr.ok?(rr.json.runs||[]):[];
  const defRows=defs.map(d=>`<tr>
      <td><b>${esc(d.name||d.slug)}</b><div class="muted mono" style="font-size:12px">${esc(d.slug)}</div></td>
      <td class="muted">v${esc(d.version)}</td>
      <td><span class="badge">${esc(d.source||'api')}</span></td>
      <td class="muted">${esc(d.step_count)}</td>
      <td><button class="btn sm${S.wfSel===d.slug?' ghost':''}" data-h-click="${H((el,ev)=>wfSelect((d.slug)))}">${t('runwf')}</button></td>
    </tr>`).join('');
  const runRows=runs.map(r=>`<tr>
      <td class="mono muted">${esc(r.id.slice(0,8))}</td>
      <td>${esc(r.slug||'—')}</td>
      <td>${wfBadge(r.status)}</td>
      <td class="muted">${esc(r.steps_used)} ${t('stepsused')}</td>
      <td class="muted" style="font-size:12px">${esc(r.created_at)}</td>
      <td><button class="btn sm ghost" data-h-click="${H((el,ev)=>wfOpen((r.id)))}">${t('viewrun')}</button></td>
    </tr>`).join('');
  return `<h2>${t('workflows')}</h2>
    <div class="card">
      <div class="row" style="justify-content:space-between;align-items:center">
        <h3 style="margin:0">${t('definitions')}</h3>
        <div style="flex:none"><button class="btn sm ghost" data-h-click="${H((el,ev)=>renderTab())}">${t('refresh')}</button></div></div>
      ${defs.length?`<table style="margin-top:8px"><thead><tr><th>${t('workflow')}</th><th>${t('version')}</th><th>${t('source')}</th><th>${t('steps')}</th><th></th></tr></thead><tbody>${defRows}</tbody></table>`
                   :`<p class="muted" style="margin-top:8px">${t('nodefs')}</p>`}
    </div>
    ${S.wfSel?wfRunForm():''}
    ${await automationsCard(defs)}
    <div class="card" style="margin-top:14px"><h3 style="margin:0 0 8px">${t('runs')}</h3>
      ${runs.length?`<table><thead><tr><th>id</th><th>workflow</th><th>${t('status')}</th><th></th><th>${t('started')}</th><th></th></tr></thead><tbody>${runRows}</tbody></table>`
                   :`<p class="muted">${t('noruns')}</p>`}</div>`;
}

// The run form is generated from the spec's own `input` map — the same declaration
// `check-input!` enforces server-side, so the form can't drift from what is accepted.
function wfRunForm(){
  const d=S.wfSpec; if(!d) return '';
  const spec=d.spec||{}, inputs=spec.input||{}, keys=S.wfKeys||[], pre=S.wfPrefill||{};
  const fields=keys.length?keys.map((k,i)=>{
    const ty=inputs[k], pv=(k in pre)?String(pre[k]):'';
    const lab=`<label>${esc(k)}<span class="muted" style="text-transform:none;letter-spacing:0"> · ${esc(ty)}</span></label>`;
    if(ty==='object'||ty==='array') return `${lab}<textarea id="wfi_${i}" rows="${pv.split('\n').length>3?8:3}" placeholder="${ty==='array'?'[]':'{}'}">${esc(pv)}</textarea>`;
    if(ty==='boolean')              return `${lab}<select id="wfi_${i}"><option value="false">false</option><option value="true"${pv==='true'?' selected':''}>true</option></select>`;
    return `${lab}<input id="wfi_${i}"${ty==='number'?' type="number"':''} value="${esc(pv)}">`;
  }).join(''):'<p class="muted">This workflow takes no input.</p>';
  const desc=(d.description&&d.description!=='null')?`<p class="muted" style="margin:0 0 10px">${esc(d.description)}</p>`:'';
  const chain=(spec.steps||[]).map(x=>esc(x.id)).join(' → ');
  return `<div class="card" style="margin-top:14px">
    <h3 style="margin:0 0 4px">${t('runwf')} — ${esc(d.name||d.slug)}</h3>${desc}
    <div class="muted mono" style="font-size:12px;margin-bottom:12px">${esc(d.slug)} v${esc(d.version)} · ${chain}</div>
    ${fields}
    <button class="btn" data-h-click="${H((el,ev)=>wfStart())}">${t('runwf')}</button>
    <button class="btn ghost" data-h-click="${H((el,ev)=>wfSelect(null))}">${t('cancel')}</button></div>`;
}

async function wfSelect(slug){
  S.wfPrefill=null;
  if(!slug){ S.wfSel=null; S.wfSpec=null; S.wfKeys=[]; return renderTab(); }
  const r=await api('/api/workflows/'+encodeURIComponent(slug));
  if(!r.ok) return toast(r.json.error||'error');
  S.wfSel=slug; S.wfSpec=r.json; S.wfKeys=Object.keys((r.json.spec||{}).input||{});
  renderTab();
}
async function wfStart(){
  const d=S.wfSpec; if(!d) return;
  const inputs=(d.spec||{}).input||{}, keys=S.wfKeys||[], body={};
  for(let i=0;i<keys.length;i++){
    const k=keys[i], ty=inputs[k], el=document.getElementById('wfi_'+i); if(!el) continue;
    const raw=el.value.trim();
    // a prefilled input is sent even when empty — "" and [] are meaningful to the
    // document pipeline (skip the form / no translations); an untouched blank on
    // any other workflow is still omitted
    if(raw===''){ if(S.wfPrefill&&(k in S.wfPrefill)) body[k]=(ty==='array')?[]:(ty==='object')?{}:''; continue; }
    if(ty==='number'){ const n=Number(raw); if(Number.isNaN(n)) return toast(k+': not a number'); body[k]=n; }
    else if(ty==='boolean'){ body[k]=(raw==='true'); }
    else if(ty==='object'||ty==='array'){ try{ body[k]=JSON.parse(raw); }catch(e){ return toast(k+': invalid JSON'); } }
    else body[k]=raw;
  }
  const r=await api('/api/workflows/'+encodeURIComponent(d.slug)+'/run',{method:'POST',body:{input:body}});
  if(r.ok){ S.wfSel=null; S.wfSpec=null; S.wfPrefill=null; S.wfRun=r.json.id; toast('started',true); renderTab(); }
  else toast(r.json.error||'error');
}
function wfOpen(id){ S.wfRun=id; S.wfPoll++; renderTab(); }
function wfBack(){ S.wfRun=null; S.wfPoll++; renderTab(); }
async function wfCancel(id){
  const r=await api('/api/runs/'+encodeURIComponent(id)+'/cancel',{method:'POST'});
  toast(r.ok?'canceled':(r.json.error||'error'), r.ok); renderTab();
}

async function wfRunView(id){
  const r=await api('/api/runs/'+encodeURIComponent(id));
  if(!r.ok) return `<h2>${t('runs')}</h2><div class="card"><p class="muted">${esc(r.json.error||'not found')}</p>
    <button class="btn ghost" data-h-click="${H((el,ev)=>wfBack())}">${t('back')}</button></div>`;
  const run=r.json, steps=run.steps||[];
  const live=(run.status==='queued'||run.status==='running');
  // a step row survives a restart because it IS the state — so polling the run is
  // enough; there is no in-memory progress to miss.
  if(live){ const gen=++S.wfPoll;
    setTimeout(()=>{ if(S.tab==='workflows'&&S.wfRun===id&&S.wfPoll===gen) renderTab(); },1500); }
  const kidsOf=s=>steps.filter(x=>x.parent_id===s.id);         // a map fan-out's children
  const row=(s,kid)=>`<tr${kid?' class="wfkid"':''}>
      <td class="mono">${esc(s.step_id)}</td>
      <td>${wfBadge(s.status)}${s.attempt>1?`<span class="muted" style="font-size:12px"> · try ${esc(s.attempt)}</span>`:''}</td>
      <td>${wfOut(s)}</td></tr>`;
  const rows=steps.filter(s=>!s.parent_id).map(s=>row(s,false)+kidsOf(s).map(k=>row(k,true)).join('')).join('');
  const err=(run.error&&run.error!=='null')
    ? `<div class="card" style="margin-top:14px;border-color:#5e332c"><b style="color:var(--bad)">error</b>
       <div class="mono" style="font-size:13px;margin-top:6px">${esc(run.error)}</div></div>` : '';
  return `<h2>${esc(run.slug||t('runs'))} <span class="muted mono" style="font-size:14px">${esc(run.id.slice(0,8))}…</span></h2>
    <div class="card">
      <div class="row" style="justify-content:space-between;align-items:center">
        <div style="flex:none">${wfBadge(run.status)} <span class="muted">${esc(run.steps_used)} ${t('stepsused')}</span>${live?' <span class="muted">· live</span>':''}</div>
        <div style="flex:none">${live?`<button class="btn sm bad" data-h-click="${H((el,ev)=>wfCancel((run.id)))}">${t('cancel')}</button> `:''}<button class="btn sm ghost" data-h-click="${H((el,ev)=>renderTab())}">${t('refresh')}</button> <button class="btn sm ghost" data-h-click="${H((el,ev)=>wfBack())}">${t('back')}</button></div>
      </div>
      ${wfJson(run.input,t('input'))}${wfJson(run.output,t('output'))}
    </div>${err}
    <div class="card" style="margin-top:14px"><h3 style="margin:0 0 8px">${t('steps')}</h3>
      <table><thead><tr><th>step</th><th>${t('status')}</th><th>${t('output')}</th></tr></thead><tbody>${rows}</tbody></table></div>`;
}

async function betaView(){
  const r=await api('/api/beta/prospects'); const ps=r.ok?r.json.prospects:[];
  const cfg=await api('/api/beta/config'); const fields=cfg.ok?(cfg.json.fields||[]):[];   // details rendered generically from the experience's field defs
  const blocked=r.ok?(r.json.blocked||{}):{}; const bt=Object.values(blocked).reduce((a,b)=>a+(b||0),0);
  const bcard = bt>0 ? `<div class="card" style="margin-bottom:12px"><b>🛡️ Blocked ${bt} abusive attempt(s)</b> <span class="muted" style="font-size:12px">${Object.entries(blocked).map(([k,v])=>esc(k)+': '+v).join(' · ')}</span></div>` : '';
  const verdict=j=>{
    if(!j||j==='null'||typeof j!=='object') return '<span class="muted">judging…</span>';
    return `<span class="badge ${j.valid?'ok':''}">${j.valid?'valid':'flagged'}</span> ${j.score??'?'}/100 · ${esc(j.revenue_estimate||'')}<div class="muted" style="font-size:12px">${esc(j.reasoning||'')}</div>`;
  };
  // value of a field, whether it's a typed column or lives in the attributes blob
  const pval=(p,k)=>{ const v=p[k]; if(v!==undefined&&v!==null&&v!=='') return v; const a=p.attributes||{}; return (a&&a[k])||''; };
  const details=p=>fields.filter(f=>f.key!=='name'&&f.key!=='email'&&pval(p,f.key))
    .map(f=>`<div class="muted" style="font-size:12px"><span style="opacity:.7">${esc(f.label)}:</span> ${esc(pval(p,f.key))}</div>`).join('')||'<span class="muted">—</span>';
  const rows=ps.map(p=>`<tr>
      <td>${esc(p.name)}<div class="muted" style="font-size:12px">${esc(p.email)}</div></td>
      <td>${details(p)}</td>
      <td>${verdict(p.judge)}</td>
      <td><span class="badge">${esc(p.status)}</span></td>
      <td>${(p.status==='qualified'||p.status==='rejected')?'':`<button class="btn sm" data-h-click="${H((el,ev)=>doDecide((p.id),'qualified'))}">${t('qualify')}</button> <button class="btn sm ghost" data-h-click="${H((el,ev)=>doDecide((p.id),'rejected'))}">${t('reject')}</button>`}</td>
    </tr>`).join('');
  return `<h2>${t('beta')} — prospects</h2>${bcard}
    <div class="card"><table><thead><tr><th>prospect</th><th>details</th><th>LLM judge</th><th>status</th><th></th></tr></thead>
      <tbody>${rows||'<tr><td colspan="5" class="muted">No signups yet.</td></tr>'}</tbody></table></div>`;
}
async function doDecide(id,decision){
  const r=await api('/api/beta/prospects/'+id+'/decide',{method:'POST',body:{decision}});
  if(r.ok){ toast(decision,true); renderTab(); } else toast(r.json.error||'error');
}
