// ---- contrast checking for the theme editor (WCAG 2.x relative luminance) ----
// A brandable public page is easy to theme into illegibility — this catches it while editing
// rather than after publishing. Only flags hex; gradients/CSS functions are skipped, not guessed.
function bxLum(hex){ const h=String(hex||'').trim().replace(/^#/,'');
  const full = h.length===3 ? h.split('').map(c=>c+c).join('') : h;
  if(!/^[0-9a-fA-F]{6}$/.test(full)) return null;
  const ch=[0,2,4].map(i=>parseInt(full.slice(i,i+2),16)/255)
    .map(c=> c<=0.03928 ? c/12.92 : Math.pow((c+0.055)/1.055,2.4));
  return 0.2126*ch[0]+0.7152*ch[1]+0.0722*ch[2]; }
function bxContrast(a,b){ const la=bxLum(a), lb=bxLum(b); if(la===null||lb===null) return null;
  return (Math.max(la,lb)+0.05)/(Math.min(la,lb)+0.05); }
function bxContrastWarnings(th){
  th=th||{};
  const bg=th.bg||'#0b1a2b', ink=th.ink||'#f2ede1', muted=th.muted||'#93a4b8';
  const brand=th.brand||'#c9a227', brandInk=th.brandInk||'#132c46';
  // pair, threshold, why it matters — 4.5:1 is the WCAG AA floor for body text, 3:1 for large/UI
  const checks=[
    ['Text on background',      ink,      bg,       4.5],
    ['Muted text on background',muted,    bg,       4.5],
    ['Button label on brand',   brandInk, brand,    4.5],
    ['Brand on background',     brand,    bg,       3.0],
  ];
  const bad=checks.map(([label,fg,bgc,min])=>{ const r=bxContrast(fg,bgc);
      return r===null||r>=min ? null : {label,ratio:r,min}; }).filter(Boolean);
  if(!bad.length) return '';
  return `<div class="bx-warn"><b>Low contrast</b>${bad.map(w=>
    `<div>${esc(w.label)} — <b>${w.ratio.toFixed(2)}:1</b> (needs ${w.min}:1)</div>`).join('')}
    <div class="muted" style="margin-top:6px">Readers may not be able to see this text.</div></div>`; }
function betaControls(){ const e=S.exp||{}; const th=e.theme||{};
  const iv=(p,v)=>`value="${esc(v==null?'':v)}"`;
  const color=(label,path,def)=>`<div><label>${label}</label><input type="color" ${iv(path.split('.').reduce((o,k)=>o&&o[k],e)||def)} data-h-input="${H((el,ev)=>bxSet((path),el.value))}"></div>`;
  const fieldRow=(f,i)=>`<div class="fieldrow">
      <div class="row"><div><label>Label</label><input ${iv(f.label)} data-h-input="${H((el,ev)=>bxSetField((i),'label',el.value))}"></div>
        <div><label>Key</label><input ${iv(f.key)} data-h-input="${H((el,ev)=>bxSetField((i),'key',el.value))}"></div></div>
      <div class="row"><div><label>Type</label><select data-h-change="${H((el,ev)=>bxSetField((i),'type',el.value))}">${['text','email','tel','textarea','select'].map(t=>`<option ${f.type===t?'selected':''}>${t}</option>`).join('')}</select></div>
        <div style="flex:0 0 auto"><label>Required</label><input type="checkbox" style="width:auto" ${f.required?'checked':''} data-h-change="${H((el,ev)=>bxSetField((i),'required',el.checked))}"></div></div>
      ${f.type==='select'?`<label>Options (comma-separated)</label><input ${iv((f.options||[]).join(', '))} data-h-input="${H((el,ev)=>bxSetField((i),'options',el.value))}">`:''}
      ${f.type==='select'?'':`<div class="row">
        <div><label>Min length</label><input type="number" min="0" ${iv(f.minlength)} data-h-input="${H((el,ev)=>bxSetField((i),'minlength',el.value))}"></div>
        <div><label>Max length</label><input type="number" min="0" ${iv(f.maxlength)} data-h-input="${H((el,ev)=>bxSetField((i),'maxlength',el.value))}"></div>
        <div style="flex:0 0 auto"><label>Digits only</label><input type="checkbox" style="width:auto" ${f.digits?'checked':''} data-h-change="${H((el,ev)=>bxSetField((i),'digits',el.checked))}"></div></div>`}
      <button class="btn sm bad" data-h-click="${H((el,ev)=>bxDelField((i)))}">Remove field</button></div>`;
  const detailRow=(d,i)=>`<div class="fieldrow"><label>Heading</label><input ${iv(d.heading)} data-h-input="${H((el,ev)=>{S.exp.details[(i)].heading=el.value;bxPreview()})}">
      <label>Body</label><textarea rows="2" data-h-input="${H((el,ev)=>{S.exp.details[(i)].body=el.value;bxPreview()})}">${esc(d.body||'')}</textarea>
      <button class="btn sm bad" data-h-click="${H((el,ev)=>bxDelDetail((i)))}">Remove</button></div>`;
  const lt=(e.landing&&e.landing.type)||'shell';
  const isBundle=lt==='bundle', isTemplate=lt==='template';
  return `<div class="card">
    <div class="sec">Rendering</div>
    <label>Landing renderer</label>
    <select data-h-change="${H((el,ev)=>bxSetLanding(el.value))}">
      <option value="shell" ${lt==='shell'?'selected':''}>Built-in — Tier A (themeable, no code)</option>
      <option value="template" ${isTemplate?'selected':''}>Custom HTML template — Tier C</option>
      <option value="bundle" ${isBundle?'selected':''}>Custom plugin bundle — Tier B</option>
    </select>
    ${isBundle?`<label>Plugin name</label><input ${iv(e.landing.plugin)} data-h-input="${H((el,ev)=>bxSet('landing.plugin',el.value))}">
      <div class="muted" style="font-size:12px;margin:-6px 0 12px">Served from <span class="mono">/beta/bundle/${esc(e.landing.plugin||'')}/</span>. The controls below still configure the SDK payload (fields, judge); the bundle owns the look.</div>`:''}
    ${isTemplate?`<label>HTML template</label>
      <textarea class="mono" rows="12" style="font-size:12px" data-h-input="${H((el,ev)=>bxSet('template',el.value))}">${esc(e.template||'')}</textarea>
      <div class="muted" style="font-size:12px;margin:-6px 0 12px">Placeholders: <span class="mono">{{title}} {{subtitle}} {{eyebrow}} {{logo}} {{cta}} {{footer}} {{fields}} {{message}}</span>. Scripts, event handlers and dangerous tags are stripped on publish; the page renders in a sandboxed iframe and submission is wired for you (a <span class="mono">[data-beta-submit]</span> button).</div>`:''}
    <div class="sec">Branding</div>
    <label>Logo text</label><input ${iv(e.logo)} data-h-input="${H((el,ev)=>bxSet('logo',el.value))}">
    ${bxAsset('Logo image (overrides text)','logoImage','image/*')}
    <label>Eyebrow</label><input ${iv(e.eyebrow)} data-h-input="${H((el,ev)=>bxSet('eyebrow',el.value))}">
    <label>Hero title</label><input ${iv(e.title)} data-h-input="${H((el,ev)=>bxSet('title',el.value))}">
    <label>Hero subtitle</label><textarea rows="2" data-h-input="${H((el,ev)=>bxSet('subtitle',el.value))}">${esc(e.subtitle||'')}</textarea>
    <label>Button label</label><input ${iv(e.cta)} data-h-input="${H((el,ev)=>bxSet('cta',el.value))}">
    <label>Footer</label><textarea rows="2" data-h-input="${H((el,ev)=>bxSet('footer',el.value))}">${esc(e.footer||'')}</textarea>
    <label style="display:flex;align-items:center;gap:8px;text-transform:none;letter-spacing:0">
      <input type="checkbox" style="width:auto;margin:0" ${e.showSignIn!==false?'checked':''}
             data-h-change="${H((el,ev)=>bxSet('showSignIn',el.checked))}">
      Show the team sign-in link on the landing page</label>
    <div class="muted" style="font-size:12px;margin:-6px 0 12px">Your team can always sign in at <code>/login</code>, whether or not this is shown.</div>

    <div class="sec">Theme</div>
    <div class="bx-swatches">
      ${color('Brand','theme.brand','#c9a227')}${color('Brand text','theme.brandInk','#132c46')}
      ${color('Background','theme.bg','#0b1a2b')}${color('Surface','theme.surface','#12253a')}
      ${color('Text','theme.ink','#f2ede1')}${color('Muted','theme.muted','#93a4b8')}</div>
    ${bxContrastWarnings(th)}
    <div class="row" style="margin-top:10px">
      <div><label>Font</label><select data-h-change="${H((el,ev)=>bxSet('theme.fontBody',el.value))}">${['System','Serif','Rounded','Mono'].map(f=>`<option ${th.fontBody===f?'selected':''}>${f}</option>`).join('')}</select></div>
      <div><label>Corner radius</label><input ${iv(th.radius||'12px')} data-h-input="${H((el,ev)=>bxSet('theme.radius',el.value))}"></div></div>
    <label>Hero background (color or CSS gradient)</label><input ${iv(th.heroBg)} data-h-input="${H((el,ev)=>bxSet('theme.heroBg',el.value))}">
    ${bxAsset('Hero image (overlaid, overrides background)','theme.heroImage','image/*')}
    ${bxAsset('Custom font (woff2/woff/ttf/otf)','theme.fontFile','.woff2,.woff,.ttf,.otf,font/*')}

    <div class="sec">Detail blocks</div>
    ${(e.details||[]).map(detailRow).join('')}
    <button class="btn sm ghost" data-h-click="${H((el,ev)=>bxAddDetail())}">+ Add block</button>

    <div class="sec">Form fields</div>
    ${(e.fields||[]).map(fieldRow).join('')}
    <button class="btn sm ghost" data-h-click="${H((el,ev)=>bxAddField())}">+ Add field</button>

    <div class="sec">LLM judge prompt <span class="muted" style="text-transform:none">(never shown to applicants)</span></div>
    <textarea rows="4" data-h-input="${H((el,ev)=>bxSet('judge-system',el.value))}">${esc(e['judge-system']||'')}</textarea>
  </div>`;
}
async function bxSaveDraft(){ const m=document.getElementById('bxmsg'); const r=await api('/api/beta/experience',{method:'PUT',body:S.exp});
  if(r.ok){ if(m)m.textContent='Draft saved'; toast('draft saved',true);} else toast(r.json.error||'error'); }
async function bxPublish(){ const m=document.getElementById('bxmsg'); await api('/api/beta/experience',{method:'PUT',body:S.exp});
  const r=await api('/api/beta/experience/publish',{method:'POST'});
  if(r.ok){ if(m)m.textContent='Published — live at the beta URL'; toast('published',true);} else toast(r.json.error||'error'); }
