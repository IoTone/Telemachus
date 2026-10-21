// ---- Beta tab: prospects | onboarding-page editor ----
async function betaTabView(){
  const seg=`<div style="display:flex;gap:8px;margin-bottom:14px">
     <button class="btn sm ${S.betaSub==='editor'?'ghost':''}" data-h-click="${H((el,ev)=>betaSub('prospects'))}">Prospects</button>
     <button class="btn sm ${S.betaSub==='editor'?'':'ghost'}" data-h-click="${H((el,ev)=>betaSub('editor'))}">Onboarding page</button></div>`;
  return seg + (S.betaSub==='editor' ? await betaEditorView() : await betaView());
}
function betaSub(s){ S.betaSub=s; renderTab(); }
async function betaEditorView(){
  const r=await api('/api/beta/experience'); S.exp = r.ok ? r.json : {};
  return `<div class="bx-ed">
    <div id="bx-controls">${betaControls()}</div>
    <div><div class="muted" style="margin-bottom:8px">Live preview — this is exactly what applicants see</div>
      <div id="bx-preview" style="border:1px solid var(--line);border-radius:12px;overflow:hidden;max-height:70vh;overflow-y:auto">${renderLandingShell(S.exp,'preview')}</div>
      <div style="margin-top:14px;display:flex;gap:10px;align-items:center">
        <button class="btn" data-h-click="${H((el,ev)=>bxSaveDraft())}">Save draft</button>
        <button class="btn ghost" data-h-click="${H((el,ev)=>bxPublish())}">Publish</button>
        <span id="bxmsg" class="muted" style="font-size:13px"></span></div>
    </div></div>`;
}
// working-copy helpers: mutate S.exp, refresh preview (and controls on structural change)
function bxSet(path,val){ const ks=path.split('.'); let o=S.exp; for(let i=0;i<ks.length-1;i++){ o[ks[i]]=o[ks[i]]||{}; o=o[ks[i]]; } o[ks[ks.length-1]]=val; bxPreview(); }
function bxPreview(){ const el=document.getElementById('bx-preview'); if(!el) return;
  const l=S.exp.landing;
  if(l&&l.type==='template'){ el.innerHTML='<iframe class="bx-frame" style="height:70vh" sandbox="allow-scripts allow-forms"></iframe>'; el.querySelector('iframe').srcdoc=bxTemplateDoc(); }
  else if(l&&l.type==='bundle'){ el.innerHTML='<div class="muted" style="padding:24px">Custom bundle active — the live page is served from <span class="mono">/beta/bundle/'+esc(l.plugin||'')+'/</span>. Open it in a new tab to preview.</div>'; }
  else el.innerHTML=renderLandingShell(S.exp,'preview'); }
// client-side render of the Tier-C template for the editor preview (server sanitizes on publish)
function bxTemplateDoc(){ const e=S.exp; const tpl=e.template||'';
  const fld=(e.fields||[]).map(function(f){var t=f.type,lab=esc(f.label||''),k=esc(f.key||'');
    if(t==='textarea')return '<p><label>'+lab+'</label><textarea name="'+k+'"></textarea></p>';
    if(t==='select')return '<p><label>'+lab+'</label><select name="'+k+'"><option></option>'+(f.options||[]).map(function(o){return '<option>'+esc(o)+'</option>';}).join('')+'</select></p>';
    return '<p><label>'+lab+'</label><input name="'+k+'" type="'+((t==='email'||t==='tel')?t:'text')+'"></p>';}).join('');
  var subs={title:esc(e.title||''),subtitle:esc(e.subtitle||''),eyebrow:esc(e.eyebrow||''),logo:esc(e.logo||'Telemachus'),cta:esc(e.cta||'Request access'),footer:esc(e.footer||''),fields:fld,message:'<div data-beta-msg></div>'};
  var body=tpl.replace(/\{\{\s*(\w+)\s*\}\}/g,function(m,k){return (k in subs)?subs[k]:'';});
  return '<!doctype html><html><head><meta charset="utf-8"><base target="_top"></head><body>'+body+'</body></html>'; }
function bxRerender(){ const c=document.getElementById('bx-controls'); if(c) c.innerHTML=betaControls(); bxPreview(); }
// upload a brand asset (logo/hero/font) → asset://<id> stored at `target` path
async function bxUpload(input,target){ const f=input.files&&input.files[0]; if(!f) return;
  const rd=new FileReader();
  rd.onload=async()=>{ const r=await api('/api/beta/assets',{method:'POST',body:{mime:f.type||'application/octet-stream',filename:f.name,data:rd.result}});
    if(r.ok){ bxSet(target,r.json.ref); toast('uploaded',true); bxRerender(); } else toast((r.json&&r.json.error)||'upload failed'); };
  rd.readAsDataURL(f); }
function bxGet(path){ return path.split('.').reduce((o,k)=>o&&o[k],S.exp); }
function bxClear(target){ bxSet(target,''); bxRerender(); }
const BX_STARTER_TEMPLATE = '<style>\n  body{margin:0;font:16px/1.6 ui-sans-serif,system-ui,sans-serif;background:#0b1a2b;color:#f2ede1}\n  .wrap{max-width:560px;margin:0 auto;padding:40px 22px}\n  .eyebrow{letter-spacing:.16em;text-transform:uppercase;font-size:12px;color:#c9a227;font-weight:700}\n  h1{font-size:2rem;line-height:1.1;margin:.2em 0 .3em}\n  form{background:#12253a;border:1px solid #24384f;border-radius:12px;padding:22px;margin-top:18px}\n  label{display:block;font-size:12px;text-transform:uppercase;color:#93a4b8;margin:0 0 4px}\n  input,select,textarea{width:100%;box-sizing:border-box;background:#0b1a2b;border:1px solid #24384f;color:#f2ede1;border-radius:8px;padding:10px 12px;font:inherit}\n  p{margin:0 0 12px}\n  button{width:100%;margin-top:6px;background:#c9a227;color:#132c46;border:0;border-radius:8px;padding:12px;font-weight:800;cursor:pointer}\n</style>\n<div class="wrap">\n  <div class="eyebrow">{{eyebrow}}</div>\n  <h1>{{title}}</h1>\n  <p>{{subtitle}}</p>\n  <form>\n    {{fields}}\n    <button data-beta-submit>{{cta}}</button>\n    {{message}}\n  </form>\n</div>';
function bxSetLanding(v){
  if(v==='bundle') S.exp.landing={type:'bundle',plugin:(S.exp.landing&&S.exp.landing.plugin)||'beta-onboarding'};
  else if(v==='template'){ S.exp.landing={type:'template'}; if(!S.exp.template) S.exp.template=BX_STARTER_TEMPLATE; }
  else S.exp.landing={type:'shell'};
  bxRerender(); }
function bxAsset(label,target,accept){ const has=bxGet(target);
  return `<label>${label}</label><input type="file" accept="${accept}" data-h-change="${H((el,ev)=>bxUpload(el,(target)))}">${has?`<div class="muted" style="margin:-6px 0 12px;font-size:12px">uploaded ✓ &nbsp;<a href="#" data-h-click="${H((el,ev)=>{bxClear((target));return false})}">remove</a></div>`:''}`; }
function bxAddDetail(){ (S.exp.details=S.exp.details||[]).push({heading:'',body:''}); bxRerender(); }
function bxDelDetail(i){ S.exp.details.splice(i,1); bxRerender(); }
function bxAddField(){ const fs=(S.exp.fields=S.exp.fields||[]); fs.push({key:'field'+(fs.length+1),label:'New field',type:'text',required:false}); bxRerender(); }
function bxDelField(i){ S.exp.fields.splice(i,1); bxRerender(); }
function bxSetField(i,prop,val){
  if(prop==='options') val=val.split(',').map(s=>s.trim()).filter(Boolean);
  // A number input hands back a STRING. Storing "13" would publish a constraint
  // the server then ignores (it wants an integer) — a silent no-op, which is the
  // worst outcome for a validation rule. Blank removes the key entirely.
  if(prop==='minlength'||prop==='maxlength'){
    const n=parseInt(val,10);
    if(!Number.isInteger(n)||n<=0){ delete S.exp.fields[i][prop]; bxPreview(); return; }
    val=n;
  }
  S.exp.fields[i][prop]=val;
  if(prop==='type'||prop==='required') bxRerender(); else bxPreview(); }
