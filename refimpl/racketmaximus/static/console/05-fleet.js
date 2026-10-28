// ---- the worker fleet (FLEET-3, issue #70) ----------------------------------
// Three questions, three answers, and the card shows all three because they
// legitimately disagree: `status` is derived (is this host alive), `worker_state`
// is what the box REPORTS (is it taking work), `admin_state` is what the
// operator INTENDS (should it be). A drained worker reporting `ready` is a
// healthy machine being held back, and that is the whole point of draining.
//
// This replaced a three-column "Compute" table that showed name, model and
// endpoint — and a pull worker has no endpoint, so every worker drew an empty
// cell while a box that had died an hour ago drew exactly like one mid-job.
function wkAge(sec){
  if(sec==null) return '–';
  const s=Math.max(0,Math.round(sec));
  if(s<90) return s+'s';
  if(s<5400) return Math.round(s/60)+'m';
  if(s<172800) return Math.round(s/3600)+'h';
  return Math.round(s/86400)+'d';
}
// #178: the ✓ ✗ ⧖ figures are over a WINDOW, and the window was a hardcoded
// "24h" in a column header's tooltip — so the three numbers an operator reads
// beside a Drain button said nothing about themselves, and the figure that
// matters most (a lease expiry: this host went quiet mid-job and the platform
// gave the work back to the queue) was the least explained. The window is a
// control now, and the server clamps `hours` to 720, so the list stops there.
const WKWINDOWS = [6, 24, 168, 720];
function wkWindowLabel(h){ return h<48 ? h+'h' : Math.round(h/24)+'d'; }
function wkHours(){ return WKWINDOWS.indexOf(S.wkHours)>=0 ? S.wkHours : 24; }
function wkSetHours(h){ S.wkHours = h; renderTab(); }
function fleetQuery(){ return '?hours='+wkHours(); }
function wkHealth(st){
  const cls = st==='active' ? 'ok' : (st==='stale' ? 'warn' : '');
  return `<span class="badge ${cls}">${esc(st)}</span>`;
}
// Each figure carries its OWN tooltip, and a non-zero failure or expiry is
// coloured: a muted row of three numbers reads as decoration, and two of the
// three are the ones somebody is looking for. Zero stays muted, so a healthy
// fleet is quiet.
function wkFigs(w){
  const fig=(n, sym, key, hue)=>`<span${n?` style="color:var(--${hue})"`:' class="muted"'} title="${esc(t(key))}">${n}&nbsp;${sym}</span>`;
  return [fig(w.done||0, '✓', 'wkdonehint', 'ok'),
          fig(w.error||0, '✗', 'wkerrhint', 'bad'),
          fig(w.leases_expired||0, '⧖', 'wkexpiredhint', 'warn')].join(' ');
}
function workersCard(xr, fr){
  if(!fr||!fr.ok) return '';
  const F=fr.json, ex=F.executors||[], fl=F.fleet||{}, q=F.queue||{};
  const loc = (xr&&xr.ok) ? xr.json.local : null;
  const pulls = ex.filter(e=>e.mode==='pull'), pushes = ex.filter(e=>e.mode!=='pull');
  const now = Math.floor(Date.now()/1000);

  const sum = [
    `<span class="badge">${fl.pull||0} ${t('workers').toLowerCase()}</span>`,
    `<span class="badge ok">${fl.active||0} ${t('wkactive')}</span>`,
    (fl.stale ? `<span class="badge warn">${fl.stale} ${t('wkstale')}</span>` : ''),
    (fl.drained ? `<span class="badge warn">${fl.drained} ${t('wkdrained')}</span>` : ''),
    (fl.paused ? `<span class="badge">${fl.paused} ${t('wkpaused')}</span>` : '')
  ].filter(Boolean).join(' ');

  const row=(e)=>{
    const w=e.window||{}, cur=e.current;
    const drained = e.admin_state==='drained';
    const held = cur ? `<span class="mono">${esc(cur.kind)}</span> <span class="muted">${wkAge(cur.seconds_left==null?null:-cur.seconds_left)||''}</span>`
                     : `<span class="muted">${t('wkidle')}</span>`;
    const lease = cur ? `<span class="muted" title="${esc(t('wkleasehint'))}">${t('wklease')} ${wkAge(cur.seconds_left)}</span>` : '';
    return `<tr${drained?' style="opacity:.62"':''}>
      <td><span class="badge">${e.mode==='pull'?'🛰️':'↗'} ${esc(e.name)}</span>${drained?` <span class="badge warn" title="${esc(t('wkdrainhint'))}">${t('wkdrained')}</span>`:''}</td>
      <td class="mono">${esc(e.model||'–')}</td>
      <td>${wkHealth(e.status)}</td>
      <td>${e.worker_state?`<span class="badge">${esc(e.worker_state)}</span>`:`<span class="muted" title="${esc(t('wkunreportedhint'))}">–</span>`}</td>
      <td class="muted">${e.last_seen_at?wkAge(now-e.last_seen_at):'–'}</td>
      <td>${cur?`${held} ${lease}`:held}</td>
      <td class="mono" style="white-space:nowrap">${wkFigs(w)}</td>
      <td style="white-space:nowrap;border-left:1px solid var(--line)">${e.mode==='pull'?
        (drained ? `<button class="btn sm ghost" data-h-click="${H(()=>wkAdmin(e.id,'resume'))}">${t('wkresume')}</button>`
                 : `<button class="btn sm ghost" data-h-click="${H(()=>wkAdmin(e.id,'drain'))}">${t('wkdrain')}</button>`)
        + ` <button class="btn sm bad" style="margin-left:14px" data-h-click="${H(()=>wkRetire(e.id,e.name))}">${t('wkretire')}</button>`
        : ''}</td></tr>`;
  };

  const locRow = loc ? `<tr><td><span class="badge ok">${t('wklocal')}</span></td><td class="mono">${esc(loc.model)}</td>
    <td><span class="badge ${loc.configured?'ok':'warn'}">${loc.configured?t('wkconfigured'):t('simulated')}</span></td>
    <td colspan="5" class="muted">${t('wklocalhint')}</td></tr>` : '';

  // Executors declared in executors.json are NOT in the fleet read — that one
  // lists DB rows, which is what a drain or a retire can act on. They still
  // belong on this table: dropping them would have made a configured push
  // backend vanish from the console, which is how the screenshot tour caught
  // this card the first time. Shown with no actions, because a file owns them.
  const dbNames = ex.map(e=>e.name);
  const fromFile = ((xr&&xr.ok) ? (xr.json.executors||[]) : [])
    .filter(e=>(e.source||'config')==='config' && dbNames.indexOf(e.name)<0);
  const fileRow=(e)=>`<tr>
      <td><span class="badge">↗ ${esc(e.name)}</span> <span class="badge" title="${esc(t('wkconfighint'))}">${t('wkconfig')}</span></td>
      <td class="mono">${esc(e.model||'–')}</td>
      <td colspan="5" class="mono muted">${esc(e.url||'')}</td><td></td></tr>`;
  const body = [locRow].concat(pulls.map(row)).concat(pushes.map(row)).concat(fromFile.map(fileRow)).join('');
  const none = pulls.length?'':`<p class="muted">${t('wknone')}</p>`;

  // The queue, and the one number a depth count cannot explain. `unclaimable`
  // is jobs NO live worker's capabilities match — never a job a quota holds,
  // which the Jobs tab already badges (QUOTA-3).
  const depth=(q.depth||[]).filter(d=>d.remote);
  const stuck=(q.unclaimable||{}).count||0;
  const queue=`<div class="row" style="margin-top:10px;align-items:center;gap:14px">
    <div><label>${t('wkqueued')}</label><h2>${depth.reduce((a,d)=>a+d.queued,0)}</h2>
      <span class="muted mono">${depth.length?depth.map(d=>esc(d.kind)+' '+d.queued).join(' · '):'–'}</span></div>
    <div><label>${t('wkoldest')}</label><h2>${wkAge(q.oldest_queued_seconds)}</h2></div>
    <div><label title="${esc(t('wkunclaimablehint'))}">${t('wkunclaimable')}</label>
      <h2${stuck?' style="color:var(--warn)"':''}>${stuck}</h2>
      ${stuck?`<span class="muted">${t('wkunclaimablewhy')}</span>`:''}</div>
  </div>`;

  // The window is named on the screen rather than only in a tooltip, and it is
  // selectable: the figures silently change meaning when `hours` does.
  const win = `<div class="row" style="align-items:center;gap:8px;margin:0 0 2px">
    <div style="flex:0 0 auto"><label>${t('wkwindowsel')}</label></div>
    <div style="flex:0 0 auto"><select style="margin:0" data-h-change="${H((el)=>wkSetHours(parseInt(el.value,10)))}">
      ${WKWINDOWS.map(h=>`<option value="${h}"${h===wkHours()?' selected':''}>${wkWindowLabel(h)}</option>`).join('')}
    </select></div>
    <div class="muted" style="font-size:12px">${esc(t('wklegend'))}</div></div>`;

  const tok = S.wkToken ? `<div class="card" style="margin-top:10px;border-color:var(--warn)">
      <label>${t('wktoken')}</label>
      <p class="mono" style="word-break:break-all">${esc(S.wkToken.token)}</p>
      <p class="muted">${t('wktokenhint')}</p>
      <p class="mono muted" style="word-break:break-all">racket cli/telemachus-worker.rkt --url ${esc(location.origin)} --token &lt;${t('wktokenph')}&gt;</p>
      <button class="btn sm ghost" data-h-click="${H(()=>{S.wkToken=null;renderTab();})}">${t('wkgotit')}</button></div>` : '';

  return `<div class="card" id="wkcard" style="margin-top:14px"><h3>${t('workers')} <span class="muted" style="font-size:13px">— ${t('workershint')}</span></h3>
    <p>${sum}</p>
    ${win}
    <table><thead><tr><th>${t('name')}</th><th>${t('model')}</th><th>${t('wkhealth')}</th><th>${t('wkreports')}</th>
      <th>${t('wklastseen')}</th><th>${t('wkholding')}</th>
      <th title="${esc(t('wkwindowhint'))}">${t('wkwindow').replace('{window}', wkWindowLabel(wkHours()))}</th>
      <th style="border-left:1px solid var(--line)"></th></tr></thead>
      <tbody>${body}</tbody></table>
    ${none}
    ${queue}
    <hr>
    <label>${t('wkadd')}</label>
    <div class="row">
      <div><input id="wkn" placeholder="${esc(t('name'))}" maxlength="64"></div>
      <div><input id="wkm" placeholder="${esc(t('model'))}" maxlength="64"></div>
      <div><button class="btn" data-h-click="${H(()=>wkCreate())}">${t('create')}</button></div>
    </div>
    <p class="muted">${t('wkaddhint')}</p>
    ${tok}</div>`;
}
async function wkAdmin(id, what){
  const r=await api('/api/executors/'+encodeURIComponent(id)+'/'+what, {method:'POST'});
  if(r.ok){ toast(t(what==='drain'?'wkdrainedok':'wkresumedok'), true); renderTab(); }
  else toast(r.json.error||'error');
}
// The confirmation says what a retire COSTS and names the reversible thing to do
// instead: a retire revokes the worker token, so it is not how you take a box
// out of rotation for ten minutes.
async function wkRetire(id, name){
  if(!confirm(t('wkretireconfirm').replace('{name}', name))) return;
  const r=await api('/api/executors/'+encodeURIComponent(id), {method:'DELETE'});
  if(r.ok){ toast(t('deleted'), true); renderTab(); } else toast(r.json.error||'error');
}
// The worker token is in the create response and NEVER again, so it is parked in
// S and shown until the operator dismisses it — not toasted, which scrolls away.
async function wkCreate(){
  const name=(document.getElementById('wkn').value||'').trim();
  const model=(document.getElementById('wkm').value||'').trim();
  if(!name){ toast(t('wknamereq')); return; }
  const r=await api('/api/executors', {method:'POST', body:{name, mode:'pull', model: model||undefined}});
  if(!r.ok){ toast(r.json.error||'error'); return; }
  S.wkToken={token:r.json.worker_token||'', name};
  toast(t('wkcreated'), true); renderTab();
}


// ---- the queue, job by job (FLEET-4, issue #70) -----------------------------
// The Workers card above carries the queue's three summary numbers. This is what
// is actually in it: each row's age, its holder and lease countdown, and for a
// queued one the two separate answers to "why is this not running" —
//
//   `waiting`  the platform is holding it (a cap, a budget), which QUOTA-3 also
//              shows on the Jobs tab. It clears on its own.
//   `runnable` false means no live worker can run it at all. Nothing clears that
//              but an operator.
//
// Read-only on purpose: cancelling is team-tier (owner-ok or jobs:cancel), and
// an operator stopping another company's job is its own decision.
function queueQuery(){
  const f=S.qFilter||{};
  const qs=Object.keys(f).filter(k=>f[k]).map(k=>k+'='+encodeURIComponent(f[k]));
  qs.push('limit=25'); qs.push('offset='+(S.qOffset||0));
  return '?'+qs.join('&');
}
// The kinds worth offering are the ones the fleet read already names: what is in
// the queue now, plus every remote kind this build registers. Building the list
// from the rows on the current PAGE would make a filter vanish the moment it
// was used.
function qKinds(fr){
  if(!fr||!fr.ok) return [];
  const q=fr.json.queue||{};
  const here=(q.depth||[]).map(d=>d.kind), remote=q.remote_kinds||[];
  return Array.from(new Set(here.concat(remote))).sort();
}
function qSet(k,v){ S.qFilter=Object.assign({}, S.qFilter||{}, {[k]:v}); S.qOffset=0; renderTab(); }
function qPage(d){ S.qOffset=Math.max(0,(S.qOffset||0)+d); renderTab(); }
function queueCard(qr, fr){
  if(!qr||!qr.ok) return '';
  const Q=qr.json, rows=Q.jobs||[], f=S.qFilter||{};
  const sel=(k,opts,lbl)=>`<div><label>${lbl}</label><select data-h-change="${H((el)=>qSet(k,el.value))}">
    ${['',...opts].map(o=>`<option value="${esc(o)}"${(f[k]||'')===o?' selected':''}>${o?esc(o):'—'}</option>`).join('')}
  </select></div>`;
  const row=(j)=>{
    // Two different facts, never merged: held by the platform, or runnable by
    // nobody. The first clears itself; the second needs a machine.
    const wait = j.waiting ? `<span class="badge warn" title="${esc(t('wkheldhint'))}">${esc(j.waiting.reason)}</span>` : '';
    const stuck = (j.runnable===false) ? `<span class="badge warn" title="${esc(t('wkunclaimablehint'))}">${t('qnoworker')}</span>` : '';
    const lease = (j.lease_seconds_left==null) ? '' :
      `<span class="muted" title="${esc(t('wkleasehint'))}">${t('wklease')} ${wkAge(j.lease_seconds_left)}</span>`;
    return `<tr>
      <td class="mono">${esc(j.kind)}${j.sub_job?` <span class="badge" title="${esc(t('qsubhint'))}">${t('qsub')}</span>`:''}</td>
      <td><span class="badge">${esc(j.status)}</span> ${wait} ${stuck}</td>
      <td class="muted">${wkAge(j.age_seconds)}</td>
      <td>${esc(j.team||'–')}${j.org?` <span class="muted">${esc(j.org)}</span>`:''}</td>
      <td class="mono muted">${j.executor?esc(j.executor):'–'} ${lease}</td>
      <td class="mono muted">${j.attempt}/${j.max_attempts}</td>
      <td class="muted" style="max-width:26em">${j.error?esc(j.error):''}</td></tr>`;
  };
  const from=(Q.offset||0)+1, to=(Q.offset||0)+rows.length;
  const pager = Q.total>rows.length ? `<p class="muted">${t('qshowing').replace('{from}',from).replace('{to}',to).replace('{total}',Q.total)}
      <button class="btn sm ghost" data-h-click="${H(()=>qPage(-25))}"${(Q.offset||0)<=0?' disabled':''}>←</button>
      <button class="btn sm ghost" data-h-click="${H(()=>qPage(25))}"${to>=Q.total?' disabled':''}>→</button></p>` : '';
  // `order` is reported rather than assumed: a list that LOOKED like the drain
  // order and was not would mislead about what runs next.
  const ord = Q.order==='drain' ? t('qdrainorder') : t('qrecentorder');
  return `<div class="card" id="qcard" style="margin-top:14px"><h3>${t('queue')} <span class="muted" style="font-size:13px">— ${esc(ord)}</span></h3>
    <div class="row">
      ${sel('status',['queued','running','canceling','done','error','canceled'],t('status'))}
      ${sel('kind',qKinds(fr),t('qkind'))}
    </div>
    ${rows.length?`<table><thead><tr><th>${t('qkind')}</th><th>${t('status')}</th><th>${t('qage')}</th>
      <th>${t('team')}</th><th>${t('workers')}</th><th>${t('qattempt')}</th><th></th></tr></thead>
      <tbody>${rows.map(row).join('')}</tbody></table>`
     :`<p class="muted">${t('qempty')}</p>`}
    ${pager}</div>`;
}

async function adminView(){
  const r=await api('/api/admin/status');
  const mr=await api('/api/metrics'); const M=mr.ok?mr.json:{};
  const spr=await api('/api/session-policy'); if(spr.ok) S.adminPolicy=spr.json;   // issue #38
  const stat=(k,l)=>`<div class="card"><label>${l}</label><h2>${M[k]??'–'}</h2></div>`;
  const body = r.ok ? `<div class="row">${stat('users','users')}${stat('teams','teams')}${stat('notes','notes')}${stat('translations','translations')}${stat('active_tokens','tokens')}${stat('audit_events','audit')}</div>` : `<p class="badge">${esc(r.json.error||'error')}</p>`;
  const [xr,fr,qr]=await Promise.all([api('/api/executors'), api('/api/admin/workers'+fleetQuery()),
                                      api('/api/admin/queue'+queueQuery())]);
  const compute=workersCard(xr, fr) + queueCard(qr, fr);
  const B = S.brand;
  const brandCard=`<div class="card" style="margin-top:14px"><h3>${t('branding')}</h3>
    <p class="muted" style="margin-top:0">${t('brandinghint')}</p>
    <div class="row">
      <div><label>${t('brandtitle')}</label><input id="brt" maxlength="48" value="${esc(B.title||'')}"></div>
      <div><label>${t('brandtagline')}</label><input id="brg" maxlength="160" placeholder="${esc(t('tagline'))}" value="${esc(B.tagline||'')}"></div>
    </div>
    <label>${t('brandlogo')}</label>
    <div class="row" style="align-items:center">
      <div style="flex:0 0 auto;min-width:0">
        <span class="brand" style="font-size:20px">${brandLockup(30)}</span>
      </div>
      <div><input type="file" id="brf" accept="image/png,image/jpeg,image/svg+xml,image/webp" data-h-change="${H((el,ev)=>doBrandLogo(el))}"></div>
      ${B.logo?`<div style="flex:0 0 auto"><button class="btn sm ghost" data-h-click="${H((el,ev)=>doBrandLogoClear())}">${t('brandclearlogo')}</button></div>`:''}
    </div>
    ${brandThemeEditor()}
    <div style="margin-top:10px"><button class="btn" data-h-click="${H((el,ev)=>doBrandSave())}">${t('save')}</button>
      <button class="btn ghost" style="margin-left:8px" data-h-click="${H((el,ev)=>doBrandReset())}">${t('brandreset')}</button>
      <button class="btn ghost" style="margin-left:8px" data-h-click="${H((el,ev)=>doBrandThemeReset())}">${t('brandthemereset')}</button></div></div>`;
  // Localization: instance-wide, `instance:manage`, and the reason it sits beside
  // Branding rather than in a user preference pane — it is what an ANONYMOUS
  // visitor gets, so it cannot live behind a sign-in.
  const I = S.i18n;
  const locCard=`<div class="card" style="margin-top:14px"><h3>${t('localization')}</h3>
    <p class="muted" style="margin-top:0">${t('lochint')}</p>
    <div class="row">
      <div><label>${t('deflocale')}</label>
        <select id="locdef">${(I.available||['en']).map(l=>`<option value="${esc(l)}"${I.default===l?' selected':''}>${esc(LANGNAME[l]||l)}</option>`).join('')}</select></div>
      <div><label>&nbsp;</label>
        <label class="muted" style="display:flex;align-items:center;gap:8px;font-weight:normal">
          <input type="checkbox" id="locsw"${I.enabled?' checked':''}> ${t('loctoggle')}</label></div>
    </div>
    <p class="muted" style="margin-top:6px;font-size:12px">${t('locoffhint')}</p>
    <p class="muted" style="font-size:12px">${t('locavail')}: ${(I.available||[]).map(l=>esc(LANGNAME[l]||l)).join(' \u00b7 ')}</p>
    <div style="margin-top:10px"><button class="btn" data-h-click="${H((el,ev)=>doI18nSave())}">${t('save')}</button></div></div>`;
  // issue #38: minutes and hours in the UI, seconds on the wire. An operator
  // thinking about "thirty minutes" should not have to multiply.
  const SP=(S.adminPolicy&&S.adminPolicy.policy)||{};
  const mins=(v)=>typeof v==='number'?Math.round(v/60):'';
  const hrs=(v)=>typeof v==='number'?(Math.round(v/360)/10):'';
  const secCard=`<div class="card" style="margin-top:14px"><h3>${t('sessionsec')}</h3>
    <div class="row">
      <div><label>${t('idlelabel')}</label><input id="spidle" type="number" min="1" value="${mins(SP.idle_seconds)}"></div>
      <div><label>${t('abslabel')}</label><input id="spabs" type="number" min="1" step="0.5" value="${hrs(SP.absolute_seconds)}"></div>
      <div><label>${t('warnlabel')}</label><input id="spwarn" type="number" min="0" value="${typeof SP.warn_seconds==='number'?SP.warn_seconds:60}"></div>
    </div>
    <p class="muted" style="margin-top:6px;font-size:12px">${t('sessionhint')}</p>
    <div style="margin-top:10px"><button class="btn" data-h-click="${H((el,ev)=>doSessionPolicySave())}">${t('save')}</button></div></div>`;
  const seedCard=`<div class="card" style="margin-top:14px"><h3>${t('testing')}</h3>
    <p class="muted" style="margin-top:0">Populate this team with sample notes, documents, and queued jobs (chat · translate · agent).</p>
    <button class="btn" data-h-click="${H((el,ev)=>doSeedSamples())}">${t('seed')}</button></div>`;
  return `<h2>${t('admin')}</h2>${body}${compute}${brandCard}${locCard}${secCard}${seedCard}`;
}
