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
// A HEADER, NOT A LEGEND BESIDE THE CONTROL (reported from outside: "what is
// the meaning of the numbers 73 ✓ 0 ✗ 0 ⧖ — this needs a table header or
// something"). #178 gave each figure its own tooltip and put a legend under the
// window selector, and that was not enough for the plain reason that it was in
// the wrong place: a tooltip is invisible until you suspect there is something
// to hover, and a muted line above a table is not what somebody reading a cell
// looks at. It is the column HEADER now and the legend is NOT also printed above
// the table — the search card's lesson, where the heading said "Search" three
// times on one screen.
//
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
    `<span class="badge">${fl.pull||0} ${esc(t('workers').toLowerCase())}</span>`,
    `<span class="badge ok">${fl.active||0} ${esc(t('wkactive'))}</span>`,
    (fl.stale ? `<span class="badge warn">${fl.stale} ${esc(t('wkstale'))}</span>` : ''),
    (fl.drained ? `<span class="badge warn">${fl.drained} ${esc(t('wkdrained'))}</span>` : ''),
    (fl.paused ? `<span class="badge">${fl.paused} ${esc(t('wkpaused'))}</span>` : '')
  ].filter(Boolean).join(' ');

  // WHICH MODEL? There are TWO records and the card was reading the wrong one.
  //
  // `executors.model` is a static column set ONCE at create time from a value an
  // operator typed; nothing ever updates it and it governs no matching.
  // `capabilities.models` is what the worker DECLARES on every claim, recorded by
  // `observe-capabilities!`, and it is what `executor-can-run?` actually matches
  // a job's `requirements.model` against. FLEET-2 added the second for exactly
  // this reason — "an aspirational record cannot answer the question" — and this
  // card went on rendering the field it replaced. The visible result was a fleet
  // where one worker showed a model and three showed a dash, because the three
  // were created without one (their unit's `TMACH_WORKER_MODELS` is what governs
  // them) while all four were declaring correctly on every poll.
  //
  // So: observed first, the static column only as a FALLBACK and marked as
  // unconfirmed — a value nobody has confirmed and one observed on the last claim
  // are different claims about the world, and PULL-11e's rule is that a field a
  // reader learns to distrust is worse than an honest absence.
  //
  // A PUSH backend is the exception and not a special case: we CALL it, so it
  // never claims and has nothing to declare. Its row's own `model` is the answer.
  const wkModels=(e)=>{
    if(e.mode!=='pull') return `<span class="mono">${esc(e.model||'–')}</span>`;
    const obs=(e.capabilities&&e.capabilities.models)||[];
    // the ORDER is load-bearing, which is why they are joined as declared rather
    // than sorted: the FIRST is what the worker answers with when a job names no
    // model at all.
    if(obs.length) return `<span class="mono" title="${esc(t('wkmodelsobs'))}">${esc(obs.join(', '))}</span>`;
    if(e.model) return `<span class="mono muted" title="${esc(t('wkmodelunconfirmed'))}">${esc(e.model)}*</span>`;
    return `<span class="muted" title="${esc(t('wkmodelnone'))}">–</span>`;
  };

  const row=(e)=>{
    const w=e.window||{}, cur=e.current;
    const drained = e.admin_state==='drained';
    const held = cur ? `<span class="mono">${esc(cur.kind)}</span> <span class="muted">${wkAge(cur.seconds_left==null?null:-cur.seconds_left)||''}</span>`
                     : `<span class="muted">${esc(t('wkidle'))}</span>`;
    const lease = cur ? `<span class="muted" title="${esc(t('wkleasehint'))}">${esc(t('wklease'))} ${wkAge(cur.seconds_left)}</span>` : '';
    return `<tr${drained?' style="opacity:.62"':''}>
      <td><span class="badge">${e.mode==='pull'?'🛰️':'↗'} ${esc(e.name)}</span>${drained?` <span class="badge warn" title="${esc(t('wkdrainhint'))}">${esc(t('wkdrained'))}</span>`:''}</td>
      <td>${wkModels(e)}</td>
      <td>${wkHealth(e.status)}</td>
      <td>${e.worker_state?`<span class="badge">${esc(e.worker_state)}</span>`:`<span class="muted" title="${esc(t('wkunreportedhint'))}">–</span>`}</td>
      <td class="muted">${e.last_seen_at?wkAge(now-e.last_seen_at):'–'}</td>
      <td>${cur?`${held} ${lease}`:held}</td>
      <td class="mono" style="white-space:nowrap">${wkFigs(w)}</td>
      <td style="white-space:nowrap;border-left:1px solid var(--line)">${e.mode==='pull'?
        (drained ? `<button class="btn sm ghost" data-h-click="${H(()=>wkAdmin(e.id,'resume'))}">${esc(t('wkresume'))}</button>`
                 : `<button class="btn sm ghost" data-h-click="${H(()=>wkAdmin(e.id,'drain'))}">${esc(t('wkdrain'))}</button>`)
        + ` <button class="btn sm bad" style="margin-left:14px" data-h-click="${H(()=>wkRetire(e.id,e.name))}">${esc(t('wkretire'))}</button>`
        : ''}</td></tr>`;
  };

  const locRow = loc ? `<tr><td><span class="badge ok">${esc(t('wklocal'))}</span></td><td class="mono">${esc(loc.model)}</td>
    <td><span class="badge ${loc.configured?'ok':'warn'}">${loc.configured?esc(t('wkconfigured')):esc(t('simulated'))}</span></td>
    <td colspan="5" class="muted">${esc(t('wklocalhint'))}</td></tr>` : '';

  // Executors declared in executors.json are NOT in the fleet read — that one
  // lists DB rows, which is what a drain or a retire can act on. They still
  // belong on this table: dropping them would have made a configured push
  // backend vanish from the console, which is how the screenshot tour caught
  // this card the first time. Shown with no actions, because a file owns them.
  const dbNames = ex.map(e=>e.name);
  const fromFile = ((xr&&xr.ok) ? (xr.json.executors||[]) : [])
    .filter(e=>(e.source||'config')==='config' && dbNames.indexOf(e.name)<0);
  const fileRow=(e)=>`<tr>
      <td><span class="badge">↗ ${esc(e.name)}</span> <span class="badge" title="${esc(t('wkconfighint'))}">${esc(t('wkconfig'))}</span></td>
      <td class="mono">${esc(e.model||'–')}</td>
      <td colspan="5" class="mono muted">${esc(e.url||'')}</td><td></td></tr>`;
  const body = [locRow].concat(pulls.map(row)).concat(pushes.map(row)).concat(fromFile.map(fileRow)).join('');
  const none = pulls.length?'':`<p class="muted">${esc(t('wknone'))}</p>`;

  // The queue, and the one number a depth count cannot explain. `unclaimable`
  // is jobs NO live worker's capabilities match — never a job a quota holds,
  // which the Jobs tab already badges (QUOTA-3).
  const depth=(q.depth||[]).filter(d=>d.remote);
  const stuck=(q.unclaimable||{}).count||0;
  // #172: a THIRD answer to "why is this not running". `stuck` is "nothing can
  // run it"; this is "a machine that can has said it is not taking work", which
  // the readiness gate produces every time a GPU host loses its card. They were
  // one number, and it read 0 while a queue sat still.
  const heldp=(q.held_by_paused||{}).count||0;
  const queue=`<div class="row" style="margin-top:10px;align-items:center;gap:14px">
    <div><label>${esc(t('wkqueued'))}</label><h2>${depth.reduce((a,d)=>a+d.queued,0)}</h2>
      <span class="muted mono">${depth.length?depth.map(d=>esc(d.kind)+' '+d.queued).join(' · '):'–'}</span></div>
    <div><label>${esc(t('wkoldest'))}</label><h2>${wkAge(q.oldest_queued_seconds)}</h2></div>
    <div><label title="${esc(t('wkunclaimablehint'))}">${esc(t('wkunclaimable'))}</label>
      <h2${stuck?' style="color:var(--warn)"':''}>${stuck}</h2>
      ${stuck?`<span class="muted">${esc(t('wkunclaimablewhy'))}</span>`:''}</div>
    <div><label title="${esc(t('wkheldpausedhint'))}">${esc(t('wkheldpaused'))}</label>
      <h2${heldp?' style="color:var(--warn)"':''}>${heldp}</h2>
      ${heldp?`<span class="muted">${esc(t('wkheldpausedwhy'))}</span>`:''}</div>
  </div>`;

  // The window is named on the screen rather than only in a tooltip, and it is
  // selectable: the figures silently change meaning when `hours` does.
  const win = `<div class="row" style="align-items:center;gap:8px;margin:0 0 2px">
    <div style="flex:0 0 auto"><label>${esc(t('wkwindowsel'))}</label></div>
    <div style="flex:0 0 auto"><select style="margin:0" data-h-change="${H((el)=>wkSetHours(parseInt(el.value,10)))}">
      ${WKWINDOWS.map(h=>`<option value="${h}"${h===wkHours()?' selected':''}>${wkWindowLabel(h)}</option>`).join('')}
    </select></div>
    </div>`;

  const tok = S.wkToken ? `<div class="card" style="margin-top:10px;border-color:var(--warn)">
      <label>${esc(t('wktoken'))}</label>
      <p class="mono" style="word-break:break-all">${esc(S.wkToken.token)}</p>
      <p class="muted">${esc(t('wktokenhint'))}</p>
      <p class="mono muted" style="word-break:break-all">racket cli/telemachus-worker.rkt --url ${esc(location.origin)} --token &lt;${esc(t('wktokenph'))}&gt;</p>
      <button class="btn sm ghost" data-h-click="${H(()=>{S.wkToken=null;renderTab();})}">${esc(t('wkgotit'))}</button></div>` : '';

  return `<div class="card" id="wkcard" style="margin-top:14px"><h3>${esc(t('workers'))} <span class="muted" style="font-size:13px">— ${esc(t('workershint'))}</span></h3>
    <p>${sum}</p>
    ${win}
    <table><thead><tr><th>${esc(t('name'))}</th><th title="${esc(t('wkmodelshint'))}">${esc(t('wkmodels'))}</th><th>${esc(t('wkhealth'))}</th><th>${esc(t('wkreports'))}</th>
      <th>${esc(t('wklastseen'))}</th><th>${esc(t('wkholding'))}</th>
      <th title="${esc(t('wkwindowhint'))}">${esc(t('wkwindow').replace('{window}', wkWindowLabel(wkHours())))}<br>
        <span class="muted" style="font-weight:400;font-size:11px">${esc(t('wklegend'))}</span></th>
      <th style="border-left:1px solid var(--line)"></th></tr></thead>
      <tbody>${body}</tbody></table>
    ${none}
    ${queue}
    <hr>
    <label>${esc(t('wkadd'))}</label>
    <div class="row">
      <div><input id="wkn" placeholder="${esc(t('name'))}" maxlength="64"></div>
      <div><input id="wkm" placeholder="${esc(t('model'))}" maxlength="64"></div>
      <div><button class="btn" data-h-click="${H(()=>wkCreate())}">${esc(t('create'))}</button></div>
    </div>
    <p class="muted">${esc(t('wkaddhint'))}</p>
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
// The page size has ONE home: `queueQuery` asks the server for it and the
// pager computes the page count from it. Two literals would disagree the day
// one changed, and the symptom would be a pager that offers a page the
// listing never fills. Declared ABOVE its first use — a top-level `const`
// does not hoist, and while nothing calls these during script evaluation,
// #110 r6 paid for that assumption once already.
const QPAGE = 25;
function queueQuery(){
  const f=S.qFilter||{};
  const qs=Object.keys(f).filter(k=>f[k]).map(k=>k+'='+encodeURIComponent(f[k]));
  qs.push('limit='+QPAGE); qs.push('offset='+(S.qOffset||0));
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
function qPages(){ return Math.max(1, Math.ceil((S.qTotal||0)/QPAGE)); }
function qCur(){ return Math.min(qPages(), Math.floor((S.qOffset||0)/QPAGE)+1); }

// A FILTER OR A PAGE CHANGE SWAPS THIS CARD, NOT THE TAB.
//
// Both used to call `renderTab()`, which on Admin re-fires the eight requests
// that tab opens with AND paints a `…` placeholder over the whole screen before
// it awaits — so changing page blanked the page, scrolled it to the top and
// re-read the metrics, the session policy, the executors, the fleet and the
// instance features to show twenty-five different rows of one table.
async function qRefresh(){
  return cardSwap('qcard', async () => {
    const qr = await api('/api/admin/queue'+queueQuery());
    // `fr` is only ever used for the kind dropdown, and a refresh must not have
    // to re-read the fleet to fill it — the full render caches the list in
    // S.qKinds, so the options survive a swap that never asked for them.
    return qr.ok ? queueCard(qr, null) : null;
  });
}
function qSet(k,v){ S.qFilter=Object.assign({}, S.qFilter||{}, {[k]:v}); S.qOffset=0; qRefresh(); }
function qGo(page){
  const n=Math.min(Math.max(1, page|0), qPages());
  S.qOffset=(n-1)*QPAGE;
  qRefresh();
}
function qPage(d){ qGo(qCur()+d); }
// NUMBERED, WITH A WINDOW AND A JUMP. `←`/`→` alone cannot answer "how much is
// there" or get you to the end of a long queue, which is where the interesting
// rows are when something has gone wrong — the drain order puts the oldest
// queued job FIRST, but a `recent` listing of a thousand settled jobs buries
// last night's failures pages deep.
//
// THE ARITHMETIC IS `pagerHTML`'S NOW, and the clamp and the jump box went with
// it — the notes listing wanted the same pager, and a second copy of a window
// computation with a gate behind only one of them is the drift this tree names
// everywhere. What stays here is what is the QUEUE's: its page size, where the
// offset lives, and that a page change swaps this card rather than the tab.
function qPager(Q, rows){
  return pagerHTML({ total: Q.total || 0, offset: Q.offset || 0, size: QPAGE,
                     shown: rows.length, go: qGo });
}
function queueCard(qr, fr){
  if(!qr||!qr.ok) return '';
  const Q=qr.json, rows=Q.jobs||[], f=S.qFilter||{};
  // the pager needs the total and the kind list on a refresh that re-read
  // neither, so a FULL render is what keeps them current
  S.qTotal = Q.total||0;
  if(fr) S.qKinds = qKinds(fr);
  // UPDATES ARRIVE WHILE THE QUEUE IS MOVING, in place, and stop when it stops.
  // The jobs tab's rule (QVIZ-6): the idle clock counts from the last REQUEST,
  // so a queue that ticked for as long as the tab was open would hold a session
  // alive indefinitely. A settled queue schedules nothing.
  const live = rows.some(j=>j.status==='queued'||j.status==='running'||j.status==='canceling');
  if(live){ const gen=++S.qPoll;
    setTimeout(()=>{ if(S.qPoll===gen && document.getElementById('qcard')) qRefresh(); }, 2500); }
  const sel=(k,opts,lbl)=>`<div><label>${lbl}</label><select data-h-change="${H((el)=>qSet(k,el.value))}">
    ${['',...opts].map(o=>`<option value="${esc(o)}"${(f[k]||'')===o?' selected':''}>${o?esc(o):'—'}</option>`).join('')}
  </select></div>`;
  const row=(j)=>{
    // Two different facts, never merged: held by the platform, or runnable by
    // nobody. The first clears itself; the second needs a machine.
    const wait = j.waiting ? `<span class="badge warn" title="${esc(t('wkheldhint'))}">${esc(j.waiting.reason)}</span>` : '';
    const stuck = (j.runnable===false) ? `<span class="badge warn" title="${esc(t('wkunclaimablehint'))}">${esc(t('qnoworker'))}</span>` : '';
    const lease = (j.lease_seconds_left==null) ? '' :
      `<span class="muted" title="${esc(t('wkleasehint'))}">${esc(t('wklease'))} ${wkAge(j.lease_seconds_left)}</span>`;
    return `<tr>
      <td class="mono">${esc(j.kind)}${j.sub_job?` <span class="badge" title="${esc(t('qsubhint'))}">${esc(t('qsub'))}</span>`:''}</td>
      <td><span class="badge">${esc(j.status)}</span> ${wait} ${stuck}</td>
      <td class="muted">${wkAge(j.age_seconds)}</td>
      <td>${esc(j.team||'–')}${j.org?` <span class="muted">${esc(j.org)}</span>`:''}</td>
      <td class="mono muted">${j.executor?esc(j.executor):'–'} ${lease}</td>
      <td class="mono muted">${j.attempt}/${j.max_attempts}</td>
      <td class="muted" style="max-width:26em">${j.error?esc(j.error):''}</td>
      <td><button class="btn sm ghost" title="${esc(t('qvpathhint'))}"
        data-h-click="${H((el)=>jobTrail(j.id, el))}">${esc(t('qvpath'))}</button></td></tr>`;
  };
  const pager = qPager(Q, rows);
  // `order` is reported rather than assumed: a list that LOOKED like the drain
  // order and was not would mislead about what runs next.
  const ord = Q.order==='drain' ? t('qdrainorder') : t('qrecentorder');
  return `<div class="card" id="qcard" style="margin-top:14px"><div class="row" style="justify-content:space-between;align-items:center"><h3 style="margin:0">${esc(t('queue'))} <span class="muted" style="font-size:13px">— ${esc(ord)}</span></h3>
      <div class="row" style="align-items:center;gap:10px;margin:0">${live?`<span class="muted" style="font-size:13px">${esc(t('qlive'))}</span>`:''}<button class="btn sm ghost" data-h-click="${H(()=>qRefresh())}">${esc(t('refresh'))}</button></div></div>
    <div class="row">
      ${sel('status',['queued','running','canceling','done','error','canceled'],t('status'))}
      ${sel('kind',fr?qKinds(fr):(S.qKinds||[]),t('qkind'))}
    </div>
    ${rows.length?`<table><thead><tr><th>${esc(t('qkind'))}</th><th>${esc(t('status'))}</th><th>${esc(t('qage'))}</th>
      <th>${esc(t('team'))}</th><th>${esc(t('workers'))}</th><th>${esc(t('qattempt'))}</th><th></th><th></th></tr></thead>
      <tbody>${rows.map(row).join('')}</tbody></table>`
     :`<p class="muted">${esc(t('qempty'))}</p>`}
    ${pager}</div>`;
}

async function adminView(){
  const r=await api('/api/admin/status');
  const mr=await api('/api/metrics'); const M=mr.ok?mr.json:{};
  const spr=await api('/api/session-policy'); if(spr.ok) S.adminPolicy=spr.json;   // issue #38
  const stat=(k,l)=>`<div class="card"><label>${l}</label><h2>${M[k]??'–'}</h2></div>`;
  const body = r.ok ? `<div class="row">${stat('users','users')}${stat('teams','teams')}${stat('notes','notes')}${stat('translations','translations')}${stat('active_tokens','tokens')}${stat('audit_events','audit')}</div>` : `<p class="badge">${esc(r.json.error||'error')}</p>`;
  // #177's read joins the three that already go together rather than becoming a
  // fourth sequential round trip — it depends on none of them, and this tab is
  // already the slowest in the console.
  // The email reads JOIN the round rather than becoming two more sequential
  // round trips — they depend on nothing here, and this tab is already the
  // slowest in the console (#177's own argument for the same move).
  const [xr,fr,qr,ifr,mtr,mnr]=await Promise.all([api('/api/executors'), api('/api/admin/workers'+fleetQuery()),
                                      api('/api/admin/queue'+queueQuery()), api('/api/instance-features'),
                                      api('/api/email-transport'), api('/api/email-notify')]);
  if(ifr.ok) S.instFeat=ifr.json;
  if(mtr.ok) S.mailT=mtr.json;
  if(mnr.ok) S.mailN=mnr.json;
  const compute=workersCard(xr, fr) + queueCard(qr, fr);
  const B = S.brand;
  const brandCard=`<div class="card" style="margin-top:14px"><h3>${esc(t('branding'))}</h3>
    <p class="muted" style="margin-top:0">${esc(t('brandinghint'))}</p>
    <div class="row">
      <div><label>${esc(t('brandtitle'))}</label><input id="brt" maxlength="48" value="${esc(B.title||'')}"></div>
      <div><label>${esc(t('brandtagline'))}</label><input id="brg" maxlength="160" placeholder="${esc(t('tagline'))}" value="${esc(B.tagline||'')}"></div>
    </div>
    <label>${esc(t('brandlogo'))}</label>
    <div class="row" style="align-items:center">
      <div style="flex:0 0 auto;min-width:0">
        <span class="brand" style="font-size:20px">${brandLockup(30)}</span>
      </div>
      <div><input type="file" id="brf" accept="image/png,image/jpeg,image/svg+xml,image/webp" data-h-change="${H((el,ev)=>doBrandLogo(el))}"></div>
      ${B.logo?`<div style="flex:0 0 auto"><button class="btn sm ghost" data-h-click="${H((el,ev)=>doBrandLogoClear())}">${esc(t('brandclearlogo'))}</button></div>`:''}
    </div>
    ${brandThemeEditor()}
    <div style="margin-top:10px"><button class="btn" data-h-click="${H((el,ev)=>doBrandSave())}">${esc(t('save'))}</button>
      <button class="btn ghost" style="margin-left:8px" data-h-click="${H((el,ev)=>doBrandReset())}">${esc(t('brandreset'))}</button>
      <button class="btn ghost" style="margin-left:8px" data-h-click="${H((el,ev)=>doBrandThemeReset())}">${esc(t('brandthemereset'))}</button></div></div>`;
  // Localization: instance-wide, `instance:manage`, and the reason it sits beside
  // Branding rather than in a user preference pane — it is what an ANONYMOUS
  // visitor gets, so it cannot live behind a sign-in.
  const I = S.i18n;
  const locCard=`<div class="card" style="margin-top:14px"><h3>${esc(t('localization'))}</h3>
    <p class="muted" style="margin-top:0">${esc(t('lochint'))}</p>
    <div class="row">
      <div><label>${esc(t('deflocale'))}</label>
        <select id="locdef">${(I.available||['en']).map(l=>`<option value="${esc(l)}"${I.default===l?' selected':''}>${esc(LANGNAME[l]||l)}</option>`).join('')}</select></div>
      <div><label>&nbsp;</label>
        <label class="muted" style="display:flex;align-items:center;gap:8px;font-weight:normal">
          <input type="checkbox" id="locsw"${I.enabled?' checked':''}> ${esc(t('loctoggle'))}</label></div>
    </div>
    <p class="muted" style="margin-top:6px;font-size:12px">${esc(t('locoffhint'))}</p>
    <p class="muted" style="font-size:12px">${esc(t('locavail'))}: ${(I.available||[]).map(l=>esc(LANGNAME[l]||l)).join(' \u00b7 ')}</p>
    <div style="margin-top:10px"><button class="btn" data-h-click="${H((el,ev)=>doI18nSave())}">${esc(t('save'))}</button></div></div>`;
  // issue #38: minutes and hours in the UI, seconds on the wire. An operator
  // thinking about "thirty minutes" should not have to multiply.
  const SP=(S.adminPolicy&&S.adminPolicy.policy)||{};
  const mins=(v)=>typeof v==='number'?Math.round(v/60):'';
  const hrs=(v)=>typeof v==='number'?(Math.round(v/360)/10):'';
  const secCard=`<div class="card" style="margin-top:14px"><h3>${esc(t('sessionsec'))}</h3>
    <div class="row">
      <div><label>${esc(t('idlelabel'))}</label><input id="spidle" type="number" min="1" value="${mins(SP.idle_seconds)}"></div>
      <div><label>${esc(t('abslabel'))}</label><input id="spabs" type="number" min="1" step="0.5" value="${hrs(SP.absolute_seconds)}"></div>
      <div><label>${esc(t('warnlabel'))}</label><input id="spwarn" type="number" min="0" value="${typeof SP.warn_seconds==='number'?SP.warn_seconds:60}"></div>
    </div>
    <p class="muted" style="margin-top:6px;font-size:12px">${esc(t('sessionhint'))}</p>
    <div style="margin-top:10px"><button class="btn" data-h-click="${H((el,ev)=>doSessionPolicySave())}">${esc(t('save'))}</button></div></div>`;
  const seedCard=`<div class="card" style="margin-top:14px"><h3>${esc(t('testing'))}</h3>
    <p class="muted" style="margin-top:0">Populate this team with sample notes, documents, and queued jobs (chat · translate · agent).</p>
    <button class="btn" data-h-click="${H((el,ev)=>doSeedSamples())}">${esc(t('seed'))}</button></div>`;
  return `<h2>${esc(t('admin'))}</h2>${body}${compute}${instFeatCard()}${emailTransportCard()}${emailNotifyCard()}${brandCard}${locCard}${secCard}${seedCard}`;
}

// #177: the OPERATOR's feature switches. They have existed since #63 and were
// reachable only by HTTP, which made the one layer that means "this deployment
// does not do that" the only layer with no UI.
//
// TWO states here, not the three the team card shows, and that is a deliberate
// departure from what the issue asked for. The document stores only `false`:
// absence and a stored `true` are both "this layer does not object", and at the
// INSTANCE tier there is no layer above to object, so an explicit `true` is
// inert — a control that wrote one would be offering an operator a setting that
// computes nothing, which is the same refusal `feature-problem` makes for an
// unknown key. So "allow" REMOVES the key. A `true` written by hand over HTTP
// still reads as allowed, and is normalized away the first time it is toggled.
function instFeatCard(){
  const F = S.instFeat;
  if(!F) return '';                       // not an operator, or the read failed
  const doc = F.features||{};
  const rows = (F.known||[]).map(f=>{
    const off = doc[f]===false;
    const status = off ? `<span class="badge bad">${esc(t('featoff'))}</span>`
                       : `<span class="badge ok">${esc(t('featallowed'))}</span>`;
    return `<tr><td class="mono">${esc(f)}</td><td>${status}</td>
      <td><button class="btn sm ${off?'ghost':'bad'}" data-h-click="${H((el,ev)=>doInstFeature((f),(off)))}">${off?esc(t('featallow')):esc(t('featturnoff'))}</button></td></tr>`;
  }).join('');
  return `<div class="card" style="margin-top:14px"><h3>${esc(t('instfeatures'))}</h3>
    <p class="muted" style="margin-top:0">${esc(t('instfeathint'))}</p>
    <table id="instfeat"><thead><tr><th>feature</th><th>status</th><th></th></tr></thead><tbody>${rows}</tbody></table></div>`;
}
// THE PUT REPLACES THE WHOLE DOCUMENT — there is no per-feature route at this
// tier, because `feature-problem` validates the document as a unit. Sending one
// key would wipe every other switch the operator had set, silently.
async function doInstFeature(name, allow){
  const doc = Object.assign({}, (S.instFeat&&S.instFeat.features)||{});
  if(allow) delete doc[name]; else doc[name]=false;
  const r = await api('/api/instance-features',{method:'PUT',body:{features:doc}});
  if(!r.ok){ toast(r.json.error||'error'); return; }
  S.instFeat = r.json;
  toast(t(allow?'featallowdone':'featoffdone').replace('{f}', name), true);
  // render(), not renderTab(): turning a feature off hides its tab for every
  // team on the box INCLUDING this one, and the tab list is built in render().
  render();
}
