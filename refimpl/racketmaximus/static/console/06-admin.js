// ---- localization (Admin) ----
// Re-render the whole shell on success: turning the switcher off has to remove it
// from the header in the same beat, and changing the default may change the
// language this very page is written in.
// Blank means "no limit on this axis", which the API spells as null. An empty box
// and a zero must not mean the same thing in a security control.
async function doSessionPolicySave(){
  const num=(id)=>{ const v=(document.getElementById(id)||{}).value; return v===''||v==null?null:Number(v); };
  const idle=num('spidle'), abs=num('spabs'), warn=num('spwarn');
  const r=await api('/api/session-policy',{method:'PUT',body:{
    idle_seconds: idle==null?null:Math.round(idle*60),
    absolute_seconds: abs==null?null:Math.round(abs*3600),
    warn_seconds: warn==null?0:Math.round(warn)}});
  if(r.ok && r.json){ S.adminPolicy=r.json; toast(t('saved')); await refreshMe(); render(); }
  else toast((r.json&&r.json.error)||'error');
}
async function doI18nSave(){
  const r=await api('/api/i18n',{method:'PUT',
    body:{default:val('locdef'), enabled:document.getElementById('locsw').checked}});
  if(r.ok && r.json){ S.i18n=Object.assign(S.i18n,r.json);
    if(!S.i18n.enabled) localStorage.removeItem('tmx_lang');
    toast(t('saved')); render(); }
  else toast((r.json&&r.json.error)||'error');
}
// ---- branding (Admin) ----
// Every write re-reads the server's normalized answer into S.brand and re-renders
// the whole shell, so the header, the sign-in lockup and the preview can never
// disagree with what was actually stored.
// THE REPAINT IS AWAITED, and it was not. Every caller `await`s this function
// and then touches the DOM — `doBrandSave` reads `#brt` again on a second save
// — so each was racing a repaint it had started itself. Awaiting is what they
// were all asking for; it needed `render()` to await `renderTab()` as well, or
// this resolves while the placeholder is on screen and the race merely moves.
//
// It surfaced as a CI-only failure in #210 (demo-validate's second
// `doBrandSave()` found `#brt` null and `val()` threw), and the window is one
// server round trip wide, which is why it had never lost locally.
async function applyBrand(b){ if(b) S.brand=Object.assign(S.brand,b,{logoUrl:b.logo?('/api/beta/asset/'+b.logo):''});
  document.title=S.brand.title||'TMach'; applyTheme(S.brand.theme); await render(); }
// ---- the theme editor (Admin > Branding) ----
// The tokens are the funnel's, so an operator who has skinned a campaign already
// knows this control. Editing previews LIVE (applyTheme against a draft) and only
// Save writes; the server re-checks every token and the contrast floor, so the
// warning here is a courtesy, not the gate.
const THEME_DEFAULTS={bg:'#0b1a2b',surface:'#12253a',ink:'#f2ede1',muted:'#93a4b8',
  brand:'#6fa0d1',brandInk:'#ffffff',radius:'8px',mode:'dark',fontBody:'System'};
function themeDraft(){ if(!S.brand.theme) S.brand.theme=Object.assign({},THEME_DEFAULTS); return S.brand.theme; }
function brandThemeSet(k,v){ themeDraft()[k]=v; applyTheme(S.brand.theme);
  const w=document.getElementById('thwarn'); if(w) w.innerHTML=brandContrast(S.brand.theme); }
// the same pairs and thresholds the server enforces (domain/branding/branding.rkt)
function darkerOf(a,b){ const la=bxLum(a), lb=bxLum(b);
  if(la===null||lb===null) return b;
  return la<lb ? a : b; }
function mixHex(a,b,p){ const rgb=h=>{ const x=String(h||'').trim().replace(/^#/,'');
    const f=x.length===3?x.split('').map(c=>c+c).join(''):x;
    return [0,2,4].map(i=>parseInt(f.slice(i,i+2),16)); };
  const A=rgb(a),B=rgb(b);
  if(A.some(isNaN)||B.some(isNaN)) return a;
  return '#'+A.map((v,i)=>Math.round(p*v+(1-p)*B[i]).toString(16).padStart(2,'0')).join(''); }
function brandContrast(th){
  th=Object.assign({},THEME_DEFAULTS,th||{});
  // the button ground is mixed, not `brand` itself — mirror BUTTON-MIX (50%) and
  // the mode-dependent dark side
  const btn=mixHex(th.brand, darkerOf(th.ink,th.bg), 0.5);
  const checks=[[t('think'),th.ink,th.bg,4.5],[t('thmuted'),th.muted,th.bg,4.5],
    [t('thsurface'),th.ink,th.surface,4.5],[t('thbrandink'),th.brandInk,btn,4.5],
    [t('thbrand'),th.brand,th.bg,3.0]];
  const bad=checks.map(([label,fg,bg,min])=>{ const r=bxContrast(fg,bg);
    return r===null||r>=min?null:{label,ratio:r,min}; }).filter(Boolean);
  if(!bad.length) return '';
  return `<div class="bx-warn" style="margin-top:8px"><b>${esc(t('thcontrast'))}</b>${bad.map(w=>
    `<div>${esc(w.label)} — <b>${w.ratio.toFixed(2)}:1</b> (${w.min}:1)</div>`).join('')}
    <div class="muted" style="margin-top:6px">${esc(t('thcontrasthint'))}</div></div>`; }
function brandThemeEditor(){
  const th=Object.assign({},THEME_DEFAULTS,S.brand.theme||{});
  const col=(k,label)=>`<div><label>${esc(label)}</label>
    <input type="color" value="${esc(th[k])}" data-h-input="${H((el,ev)=>brandThemeSet((k),el.value))}"></div>`;
  const pick=(k,label,opts)=>`<div><label>${esc(label)}</label><select data-h-change="${H((el,ev)=>brandThemeSet((k),el.value))}">
    ${opts.map(o=>`<option value="${esc(o)}"${th[k]===o?' selected':''}>${esc(o)}</option>`).join('')}</select></div>`;
  return `<h4 style="margin:16px 0 4px">${esc(t('brandtheme'))}</h4>
    <p class="muted" style="margin-top:0">${esc(t('brandthemehint'))}</p>
    <div class="row">${col('bg',t('thbg'))}${col('surface',t('thsurface'))}${col('ink',t('think'))}${col('muted',t('thmuted'))}</div>
    <div class="row">${col('brand',t('thbrand'))}${col('brandInk',t('thbrandink'))}
      ${pick('mode',t('thmode'),['dark','light'])}${pick('fontBody',t('thfont'),['System','Serif','Mono','Rounded'])}
      ${pick('radius',t('thradius'),['0px','4px','8px','12px','16px'])}</div>
    <div id="thwarn">${brandContrast(th)}</div>`; }
async function doBrandThemeReset(){
  S.brand.theme=Object.assign({},THEME_DEFAULTS); applyTheme(S.brand.theme); await doBrandSave(); }

async function doBrandSave(){
  const r=await api('/api/branding',{method:'PUT',
    body:{title:val('brt'),tagline:val('brg'),logo:S.brand.logo||'',theme:S.brand.theme||undefined}});
  if(r.ok){ await applyBrand(r.json); toast(t('saved'),true); } else toast(r.json.error||'error');
}
async function doBrandReset(){
  S.brand.theme=Object.assign({},THEME_DEFAULTS);
  const r=await api('/api/branding',{method:'PUT',body:{title:'TMach',tagline:'',logo:'',theme:S.brand.theme}});
  if(r.ok){ await applyBrand(r.json); toast(t('saved'),true); } else toast(r.json.error||'error');
}
async function doBrandLogoClear(){
  const r=await api('/api/branding',{method:'PUT',body:{title:S.brand.title,tagline:S.brand.tagline,logo:''}});
  if(r.ok){ await applyBrand(r.json); toast(t('saved'),true); } else toast(r.json.error||'error');
}
async function doBrandLogo(input){
  const f=input.files&&input.files[0]; if(!f) return;
  const b64=await new Promise((res,rej)=>{ const rd=new FileReader();
    rd.onload=()=>res(String(rd.result).split(',')[1]); rd.onerror=rej; rd.readAsDataURL(f); });
  const r=await api('/api/branding/logo',{method:'POST',body:{mime:f.type,filename:f.name,data:b64}});
  if(r.ok){ await applyBrand(r.json.branding); toast(t('saved'),true); } else toast(r.json.error||'error');
}

async function doSeedSamples(){
  const r=await api('/api/admin/seed',{method:'POST'});
  if(r.ok){ toast(`seeded ${r.json.notes} notes, ${r.json.documents} docs, ${r.json.jobs} jobs`,true); renderTab(); }
  else toast(r.json.error||'error');
}

