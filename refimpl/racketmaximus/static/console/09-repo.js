// ---------- repository (slices 49-50) ----------
// Binary documents. The upload is a raw PUT of the File itself — no base64, no JSON
// envelope — so a 30 MB PDF costs 30 MB on the wire instead of 40, and neither end
// has to hold a string copy of it. Downloads go through a blob URL because the
// endpoint needs an Authorization header, which a plain <a href> cannot carry.
function humanBytes(n){
  if(n===null||n===undefined) return '—';
  const u=['B','KB','MB','GB']; let i=0, v=Number(n);
  while(v>=1024 && i<u.length-1){ v/=1024; i++; }
  return (i===0?v:v.toFixed(1))+' '+u[i];
}
function visBadge(v){
  const cls = v==='private' ? 'bad' : (v==='shared' ? 'run' : 'ok');
  return `<span class="badge ${cls}">${esc(v)}</span>`;
}

function repoFilter(on){ S.repoShared=on; renderTab(); }
async function repoView(){
  const r=await api('/api/repo'+(S.repoShared?'?shared=1':''));
  if(!r.ok) return `<h2>${t('repository')}</h2><div class="card"><p class="muted">${esc(r.json.error||'unavailable')}</p></div>`;
  const objs=r.json.objects||[], usage=r.json.usage||{};
  S.repoKeys = objs.map(o=>o.key);
  const rows=objs.map(o=>`<tr>
      <td><b class="mono">${esc(o.key)}</b>
          <div class="muted" style="font-size:12px">${esc(o.content_type)}${o.version>1?` · v${esc(o.version)}`:''}</div></td>
      <td>${visBadge(o.visibility)}</td>
      <td class="muted" style="font-variant-numeric:tabular-nums">${esc(humanBytes(o.size))}</td>
      <td class="muted" style="font-size:12px">${esc(o.updated_at)}</td>
      <td style="white-space:nowrap">
        <button class="btn sm" data-h-click="${H((el,ev)=>repoDownload((o.id),(o.key)))}">${t('download')}</button>
        <button class="btn sm ghost" data-h-click="${H((el,ev)=>repoLink((o.id)))}">${t('link')}</button>
        <button class="btn sm ghost" data-h-click="${H((el,ev)=>repoOpenDetail((o.id)))}">${t('details')}</button>
      </td></tr>`).join('');
  const limit = (usage.limit===null||usage.limit===undefined) ? t('nolimit') : humanBytes(usage.limit);
  return `<h2>${t('repository')}
      <span class="muted" style="font-size:14px">${esc(usage.objects||0)} ${t('objects')} · ${esc(humanBytes(usage.used||0))} / ${esc(limit)} · ${t('store')}: ${esc(usage.store||'?')}</span></h2>
    <div class="card">
      <h3 style="margin:0 0 10px">${t('upload')}</h3>
      <div class="row" style="align-items:end">
        <div style="flex:2"><label>${t('file')}</label><input type="file" id="rfile" data-h-change="${H((el,ev)=>repoFilePicked())}"></div>
        <div style="flex:2"><label>${t('key')}</label>
          <input id="rkey" placeholder="reports/2026/q3.pdf" data-h-input="${H((el,ev)=>repoKeyChanged())}">
          <div id="rovr"></div></div>
        <div style="flex:1"><label>${t('visibility')}</label>
          <select id="rvis">
            <option value="team">${t('vis_team')}</option>
            <option value="private">${t('vis_private')}</option>
          </select></div>
        <div style="flex:none"><button class="btn" data-h-click="${H((el,ev)=>repoUpload())}">${t('upload')}</button></div>
      </div>
      <div class="muted" style="font-size:12px">${t('uploadhint')}</div>
      <div id="rprog"></div>
    </div>
    <div class="card" style="margin-top:14px">
      <div class="row" style="justify-content:space-between;align-items:center">
        <h3 style="margin:0">${t('objects')}</h3>
        <div style="flex:none">
          <button class="btn sm${S.repoShared?' ghost':''}" id="rf_all" data-h-click="${H((el,ev)=>repoFilter(false))}">${t('all')}</button>
          <button class="btn sm${S.repoShared?'':' ghost'}" id="rf_shared" data-h-click="${H((el,ev)=>repoFilter(true))}">${t('sharedwithme')}</button>
          <button class="btn sm ghost" data-h-click="${H((el,ev)=>renderTab())}">${t('refresh')}</button></div></div>
      ${objs.length
        ? `<table style="margin-top:8px"><thead><tr><th>${t('key')}</th><th>${t('visibility')}</th><th>${t('size')}</th><th>${t('updated')}</th><th></th></tr></thead><tbody>${rows}</tbody></table>`
        : `<p class="muted" style="margin-top:8px">${S.repoShared?t('nosharedwithme'):t('norepoobjects')}</p>`}
    </div>
    <div id="rdetail"></div>
    ${await s3Card()}`;
}

// S3 access keys live beside the documents they reach, not in Team with the bearer
// tokens: the thing an operator needs is the endpoint, the bucket name and a key,
// together, in the order they will paste them.
async function s3Card(){
  const r=await api('/api/s3/credentials');
  if(!r.ok) return '';
  const creds=r.json.credentials||[], ep=r.json.endpoint, bucket=r.json.bucket;
  const rows=creds.map(c=>`<tr>
      <td>${esc(c.name||'—')}</td>
      <td class="mono muted">${esc(c.access_key_id)}</td>
      <td class="mono muted" style="font-size:12px">${(c.scopes||[]).map(esc).join(' ')}</td>
      <td>${c.status==='active'?'<span class="badge ok">active</span>':`<span class="badge">${esc(c.status)}</span>`}</td>
      <td>${c.status==='active'?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>s3Revoke((c.id)))}">${t('revoke')}</button>`:''}</td>
    </tr>`).join('');
  const newkey = S.s3New ? `<div class="card" style="margin-top:10px;border-color:#3a4a24">
      <b>${t('s3once')}</b>
      <pre class="wfjson">AWS_ACCESS_KEY_ID=${esc(S.s3New.access_key_id)}
AWS_SECRET_ACCESS_KEY=${esc(S.s3New.secret_access_key)}</pre></div>` : '';
  const usage = ep
    ? `<pre class="wfjson">aws --endpoint-url ${esc(ep)} s3 ls s3://${esc(bucket)}/
aws --endpoint-url ${esc(ep)} s3 cp report.pdf s3://${esc(bucket)}/reports/</pre>`
    : `<p class="muted">${t('s3off')}</p>`;
  return `<div class="card" style="margin-top:14px">
    <h3 style="margin:0 0 4px">${t('s3keys')}</h3>
    <div class="muted" style="font-size:12px;margin-bottom:10px">${t('s3hint')}</div>
    ${usage}
    <div class="row" style="align-items:end;margin-top:10px">
      <div style="flex:2"><label>${t('name')}</label><input id="s3name" placeholder="laptop"></div>
      <div style="flex:none"><button class="btn" data-h-click="${H((el,ev)=>s3Create())}">${t('createtoken')}</button></div>
    </div>
    ${newkey}
    ${creds.length?`<table style="margin-top:8px"><thead><tr><th>${t('name')}</th><th>access key</th><th>scopes</th><th>${t('status')}</th><th></th></tr></thead><tbody>${rows}</tbody></table>`:''}
  </div>`;
}
async function s3Create(){
  const r=await api('/api/s3/credentials',{method:'POST',body:{name:val('s3name')}});
  if(r.ok){ S.s3New=r.json; toast(t('s3created'),true); renderTab(); } else toast(r.json.error||'error');
}
async function s3Revoke(id){
  const r=await api('/api/s3/credentials/'+encodeURIComponent(id),{method:'DELETE'});
  if(r.ok){ S.s3New=null; toast(t('revoked'),true); renderTab(); } else toast(r.json.error||'error');
}

// default the key to the filename, so the common case needs no typing
function repoFilePicked(){
  const f=document.getElementById('rfile').files[0];
  const k=document.getElementById('rkey');
  if(f && !k.value) k.value=f.name;
  repoKeyChanged();
}
// say out loud what an existing path means, before the button is pressed
function repoKeyChanged(){
  const k=(document.getElementById('rkey')||{}).value||'';
  const hit=(S.repoKeys||[]).indexOf(k.trim())>=0;
  const sel=document.getElementById('rvis');
  const note=document.getElementById('rovr');
  if(sel) sel.disabled=hit;
  if(note) note.innerHTML = hit ? `<span class="badge run">${t('willversion')}</span>` : '';
}

async function repoUpload(){
  const f=document.getElementById('rfile').files[0];
  if(!f) return toast('choose a file first');
  const key=val('rkey')||f.name, vis=val('rvis');
  // Uploading to a path that already exists is a NEW VERSION, not a new document —
  // so the form's visibility select must not travel with it. Sending it would let a
  // re-upload silently re-open a document its owner had made private, which is the
  // one thing "the creator sets the visibility" must never allow by accident.
  const overwrite = (S.repoKeys||[]).indexOf(key) >= 0;
  const prog=document.getElementById('rprog');
  prog.innerHTML=`<p class="muted">${t('uploading')} ${esc(f.name)} (${esc(humanBytes(f.size))})…</p>`;
  const q='?filename='+encodeURIComponent(f.name)
        + (overwrite ? '' : '&visibility='+encodeURIComponent(vis));
  // the raw File goes as the body; the browser sets no Content-Type of its own for a
  // Blob body unless we ask, so the file's own type is passed explicitly
  const res=await fetch('/api/repo/'+key.split('/').map(encodeURIComponent).join('/')+q, {
    method:'PUT',
    headers:{'Authorization':'Bearer '+S.token,
             'Content-Type': f.type||'application/octet-stream'},
    body: f });
  let j={}; try{ j=await res.json(); }catch(e){}
  prog.innerHTML='';
  if(res.ok){ document.getElementById('rfile').value='';
              toast(overwrite ? t('newversion') : t('uploaded'), true); renderTab(); }
  else toast(j.error||('upload failed ('+res.status+')'));
}

// The content endpoint needs a bearer token, so the file is fetched and handed to
// the browser as an object URL rather than linked directly.
async function repoDownload(id, key){
  const res=await fetch('/api/repo-obj/'+encodeURIComponent(id)+'/content',
                        {headers:{'Authorization':'Bearer '+S.token}});
  if(!res.ok) return toast('download failed ('+res.status+')');
  const blob=await res.blob();
  const url=URL.createObjectURL(blob);
  const a=document.createElement('a');
  a.href=url; a.download=(key||'download').split('/').pop();
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(()=>URL.revokeObjectURL(url), 30000);
}

// A presigned link: shareable, time-boxed, no token needed by whoever opens it.
// Shown rather than silently copied, because a link that grants access to a document
// is a thing someone should look at before they paste it somewhere.
async function repoLink(id){
  const r=await api('/api/repo-obj/'+encodeURIComponent(id)+'/presign?expires=900',{method:'POST'});
  if(!r.ok) return toast(r.json.error||'error');
  const mins=Math.round((r.json.expires_in||900)/60);
  const el=document.getElementById('rdetail');
  el.innerHTML=`<div class="card" style="margin-top:14px;border-color:#3a4a24">
    <div class="row" style="justify-content:space-between;align-items:center">
      <h3 style="margin:0">${t('link')} — <span class="mono">${esc(r.json.key)}</span></h3>
      <div style="flex:none">
        <button class="btn sm" data-h-click="${H((el,ev)=>repoCopyLink())}">${t('copy')}</button>
        <button class="btn sm ghost" data-h-click="${H((el,ev)=>document.getElementById('rdetail').innerHTML='')}">${t('close')}</button>
      </div></div>
    <div class="muted" style="font-size:12px;margin:6px 0">${t('linkhint').replace('{m}', mins)}</div>
    <pre class="wfjson" id="rlink">${esc(r.json.url)}</pre></div>`;
}
function repoCopyLink(){
  const el=document.getElementById('rlink'); if(!el) return;
  navigator.clipboard.writeText(el.textContent).then(()=>toast(t('copied'),true),
                                                     ()=>toast('copy failed'));
}

async function repoOpenDetail(id){
  const [m, g, tg, pr] = await Promise.all([
    api('/api/repo-obj/'+encodeURIComponent(id)),
    api('/api/repo-obj/'+encodeURIComponent(id)+'/grants'),
    api('/api/share-targets'),
    api('/api/repo-obj/'+encodeURIComponent(id)+'/processing')]);
  const el=document.getElementById('rdetail');
  if(!m.ok){ toast(m.json.error||'error'); return; }
  const o=m.json, grants=(g.ok?g.json.grants:[])||[];
  const users=(tg.ok?tg.json.users:[])||[], teams=(tg.ok?tg.json.teams:[])||[];
  const proc=pr.ok?pr.json:{derived:[],derived_from:[],runs:[]};
  const vrows=(o.versions||[]).map(v=>`<tr>
      <td>v${esc(v.version)}${v.current?' <span class="badge ok">current</span>':''}</td>
      <td class="muted" style="font-variant-numeric:tabular-nums">${esc(humanBytes(v.size))}</td>
      <td class="mono muted" style="font-size:12px">${esc(String(v.digest).slice(0,12))}…</td>
      <td class="muted" style="font-size:12px">${esc(v.created_at)}</td>
      <td>${v.current?'':`<button class="btn sm ghost" data-h-click="${H((el,ev)=>repoDownloadVersion((id),(v.id),(o.key)))}">${t('download')}</button>`}</td>
    </tr>`).join('');
  // one row per principal: who, what they may do, until when — and revoke (DSH step 3)
  const grows=grants.length
    ? grants.map(x=>`<tr><td>${x.principal_type==='team'?'<span class="badge">'+t('teamsec')+'</span> ':''}${esc(x.name||x.username||x.principal_id)}</td>
        <td class="mono muted">${esc(t('cap_'+(x.capability||'view')))}${x.expired?' <span class="badge bad">'+t('expired')+'</span>':(x.expires_at?' · '+t('until')+' '+esc(x.expires_at.slice(0,10)):'')}</td>
        <td><button class="btn sm bad" data-h-click="${H((el,ev)=>repoUnshare((id),(x.principal_type),(x.principal_id)))}">${t('revoke')}</button></td></tr>`).join('')
    : `<tr><td colspan="3" class="muted">${t('noshares')}</td></tr>`;
  // a person on this team, or a team in this org (DSH-6) — never anyone outside it
  const uopts=users.filter(x=>x.user_id!==o.owner_user_id)
    .map(x=>`<option value="user:${esc(x.user_id)}">${esc(x.username)}</option>`).join('');
  const topts=teams.map(x=>`<option value="team:${esc(x.id)}">${esc(x.name)}${x.own?' ('+t('thisteam')+')':''}</option>`).join('');
  const opts=(uopts?`<optgroup label="${t('people')}">${uopts}</optgroup>`:'')+(topts?`<optgroup label="${t('teamsec')}">${topts}</optgroup>`:'');
  // "Processed by": what came out of this document, where it came from, every run that touched it (DWF step 4)
  const drows=(proc.derived||[]).map(d=>`<tr><td><b class="mono">${esc(d.key)}</b><div class="muted" style="font-size:12px">${esc(d.content_type)}${d.version>1?' · v'+esc(d.version):''}</div></td>
      <td class="muted">${esc(d.step_id||'—')}</td>
      <td class="muted" style="font-size:12px">${esc(d.created_at)}</td>
      <td style="white-space:nowrap"><button class="btn sm ghost" data-h-click="${H((el,ev)=>repoOpenDetail((d.object_id)))}">${t('details')}</button>${d.run_id?` <button class="btn sm ghost" data-h-click="${H((el,ev)=>repoViewRun((d.run_id)))}">${t('viewrun')}</button>`:''}</td></tr>`).join('');
  const frows=(proc.derived_from||[]).map(d=>`<tr><td>${t('derivedfrom')} <b class="mono">${esc(d.key||d.source_object_id)}</b></td>
      <td class="muted">${esc(d.step_id||'—')}</td><td class="muted" style="font-size:12px">${esc(d.created_at)}</td>
      <td style="white-space:nowrap"><button class="btn sm ghost" data-h-click="${H((el,ev)=>repoOpenDetail((d.source_object_id)))}">${t('details')}</button>${d.run_id?` <button class="btn sm ghost" data-h-click="${H((el,ev)=>repoViewRun((d.run_id)))}">${t('viewrun')}</button>`:''}</td></tr>`).join('');
  const rrows=(proc.runs||[]).map(r=>`<tr><td>${esc(r.slug||'—')}${r.trigger_id?' <span class="badge">'+t('bytrigger')+'</span>':''}</td>
      <td>${wfBadge(r.status)}</td><td class="muted" style="font-size:12px">${esc(r.created_at)}</td>
      <td><button class="btn sm ghost" data-h-click="${H((el,ev)=>repoViewRun((r.id)))}">${t('viewrun')}</button></td></tr>`).join('');
  const processed = (drows||frows||rrows)
    ? `<div id="rprocessed" style="margin-top:14px"><h4 style="margin:0 0 6px">${t('processedby')}</h4>
        ${(drows||frows)?`<table><tbody>${frows}${drows}</tbody></table>`:''}
        ${rrows?`<table style="margin-top:6px"><thead><tr><th>${t('workflow')}</th><th>${t('status')}</th><th>${t('started')}</th><th></th></tr></thead><tbody>${rrows}</tbody></table>`:''}</div>`
    : `<div id="rprocessed" class="muted" style="margin-top:14px;font-size:12px">${t('notprocessed')}</div>`;
  el.innerHTML=`<div class="card" style="margin-top:14px">
    <div class="row" style="justify-content:space-between;align-items:center">
      <h3 style="margin:0" class="mono">${esc(o.key)}</h3>
      <div style="flex:none">
        <button class="btn sm" data-h-click="${H((el,ev)=>repoRunWorkflow((id)))}">${t('runwf_doc')}</button>
        <button class="btn sm bad" data-h-click="${H((el,ev)=>repoDelete((id)))}">${t('del')}</button>
        <button class="btn sm ghost" data-h-click="${H((el,ev)=>document.getElementById('rdetail').innerHTML='')}">${t('close')}</button>
      </div></div>
    <div class="row" style="margin-top:12px;align-items:end">
      <div style="flex:1"><label>${t('visibility')}</label>
        <select id="rdvis" data-h-change="${H((el,ev)=>repoSetVis((id)))}">
          ${['team','private','shared'].map(v=>`<option value="${v}"${o.visibility===v?' selected':''}>${t('vis_'+v)}</option>`).join('')}
        </select></div>
      <div style="flex:2"><label>${t('sharewith')}</label>
        <select id="rdshare">${opts||`<option value="">${t('noothers')}</option>`}</select></div>
      <div style="flex:1"><label>${t('capability')}</label>
        <select id="rdcap"><option value="view">${t('cap_view')}</option><option value="edit">${t('cap_edit')}</option><option value="manage">${t('cap_manage')}</option></select></div>
      <div style="flex:1"><label>${t('expires')}</label><input type="date" id="rdexp"></div>
      <div style="flex:none"><button class="btn" data-h-click="${H((el,ev)=>repoShare((id)))}">${t('share')}</button></div>
    </div>
    <div class="muted" style="font-size:12px;margin-bottom:12px">${t('vishint')} ${t('caphint')}</div>
    <div class="row">
      <div><h4 style="margin:0 0 6px">${t('sharedwith')}</h4>
        <table><tbody>${grows}</tbody></table></div>
      <div><h4 style="margin:0 0 6px">${t('versions')}</h4>
        <table><tbody>${vrows}</tbody></table></div>
    </div>
    ${processed}</div>`;
}
function repoViewRun(runId){ go('workflows'); S.wfRun=runId; S.wfPoll++; renderTab(); }

// "Run workflow…" on a document (DWF-7): the SAME run endpoint a trigger will use,
// so what works by hand works on upload. Lands on the Workflows tab with the
// shipped pipeline selected and this document prefilled; template and locales
// are prefilled EMPTY, which the pipeline reads as "skip the form" / "no
// translations" — the form sends them as-is rather than dropping them.
const PIPELINE_EXAMPLE_SCHEMA={type:'object',required:['title','summary'],
  properties:{title:{type:'string'},summary:{type:'string'},date:{type:['string','null']}}};
async function repoRunWorkflow(id){
  S.wfPrefill={object_id:id, schema:JSON.stringify(PIPELINE_EXAMPLE_SCHEMA,null,2), template:'', locales:'[]'};
  go('workflows');
  const r=await api('/api/workflows/process-upload');
  if(r.ok){ S.wfSel='process-upload'; S.wfSpec=r.json; S.wfKeys=Object.keys((r.json.spec||{}).input||{}); }
  else toast(r.json.error||'error');
  renderTab();
}

async function repoDownloadVersion(id, versionId, key){
  const res=await fetch('/api/repo-obj/'+encodeURIComponent(id)+'/content?version='+encodeURIComponent(versionId),
                        {headers:{'Authorization':'Bearer '+S.token}});
  if(!res.ok) return toast('download failed ('+res.status+')');
  const blob=await res.blob(), url=URL.createObjectURL(blob);
  const a=document.createElement('a'); a.href=url; a.download=(key||'download').split('/').pop();
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(()=>URL.revokeObjectURL(url), 30000);
}
async function repoSetVis(id){
  const r=await api('/api/repo-obj/'+encodeURIComponent(id)+'/visibility',
                    {method:'POST',body:{visibility:val('rdvis')}});
  if(r.ok){ toast(t('visupdated'),true); repoOpenDetail(id); } else toast(r.json.error||'error');
}
async function repoShare(id){
  const who=val('rdshare'); if(!who) return toast(t('noothers'));
  const [principal_type, principal_id]=who.split(':');
  const body={principal_type, principal_id, capability:val('rdcap')||'view'};
  const exp=val('rdexp'); if(exp) body.expires_at=exp+'T23:59:59Z';     // "until this day", inclusive
  const r=await api('/api/repo-obj/'+encodeURIComponent(id)+'/share',{method:'POST',body});
  if(r.ok){ toast(t('shared'),true); repoOpenDetail(id); } else toast(r.json.error||'error');
}
async function repoUnshare(id,ptype,pid){
  const r=await api('/api/repo-obj/'+encodeURIComponent(id)+'/unshare',{method:'POST',body:{principal_type:ptype||'user',principal_id:pid}});
  if(r.ok){ toast(t('revoked'),true); repoOpenDetail(id); } else toast(r.json.error||'error');
}
async function repoDelete(id){
  const r=await api('/api/repo-obj/'+encodeURIComponent(id),{method:'DELETE'});
  if(r.ok){ document.getElementById('rdetail').innerHTML=''; toast(t('deleted'),true); renderTab(); }
  else toast(r.json.error||'error');
}

