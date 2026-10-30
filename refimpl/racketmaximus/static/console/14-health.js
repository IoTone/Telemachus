// ---- the health screen (issue #179) -----------------------------------------
// "Is this instance healthy" was answerable only by reading five HTTP endpoints
// by hand, and the console showed the FLEET and the QUEUE while nothing showed
// the server itself. This is one screen for an operator who has just been told
// "it's slow".
//
// IT COMPOSES THE WORKERS AND QUEUE CARDS RATHER THAN RE-RENDERING THEIR
// FIGURES. The issue asks for a fleet section and a queue section, and both
// already exist on the Admin tab — drawing those numbers a second time here is
// `executor-can-run?`'s drift and LIVE-IN's shape, two renderings of one answer
// that can disagree about an edge nobody is looking at. What is NEW on this
// screen is the server itself and the budgets; the rest is the same two
// functions reading the same two responses.
//
// `instance:read`, not `instance:manage` — #124 made that permission exist
// precisely so a monitoring credential need not also be able to reset a
// password, and a dashboard is the case that justified it.
//
// NOTHING POLLS. The console's idle clock counts from the last REQUEST (#38),
// so a screen that refreshed itself every ten seconds would hold a session open
// for as long as the tab was left on screen — an idle timeout switched off by a
// convenience. The refresh is a button, and the screen says when it was read.
function hTime(ms){ try{ return new Date(ms).toLocaleTimeString(); }catch(e){ return ''; } }
function hRow(label, value, hint){
  return `<tr><th style="width:38%">${hint?`<span title="${esc(hint)}">${esc(label)}</span>`:esc(label)}</th>
    <td>${value}</td></tr>`;
}
function hBadge(txt, cls){ return `<span class="badge${cls?' '+cls:''}">${esc(txt)}</span>`; }

// The three budgets that actually stall work. `/api/usage` is TEAM-scoped — it
// answers for the caller's own team and there is no instance-wide roll-up — so
// the card says whose figures these are rather than letting an operator read
// them as the instance's. The queue's own `waiting` count, two cards below, is
// the instance-wide version of this question.
const H_BUDGETS = ['ai.tokens.total', 'ai.requests', 'ai.concurrency'];
function healthBudgets(ur){
  if(!ur || !ur.ok) return '';
  const q = (ur.json.quota||[]).filter(d=>H_BUDGETS.indexOf(d.dimension)>=0);
  const rows = q.map(d=>{
    // A limit of null is "no limit set", and `quota-check` reports used: 0 when
    // none is — so a bare pair of numbers would read as an idle team. Say which
    // it is.
    const none = (d.limit==null || d.limit==='null');
    const bar = none ? `<span class="muted">${t('hnolimit')}</span>`
                     : `${d.used} / ${d.limit} <span class="muted">(${d.remaining})</span>`;
    return `<tr><td class="mono">${esc(d.dimension)}</td><td>${bar}</td>
      <td class="muted">${esc(d.window||'')}</td>
      <td class="muted">${d.resets_at?esc(new Date(d.resets_at*1000).toLocaleString()):'—'}</td></tr>`;
  }).join('');
  return `<div class="card" id="hbudgets" style="margin-top:14px">
    <h3>${t('hbudgets')} <span class="muted" style="font-size:13px">— ${t('hbudgetshint')}</span></h3>
    ${quotaHeldCard(ur.json.held)}
    <table><thead><tr><th>${t('dimension')}</th><th>${t('hused')}</th><th>${t('hwindow')}</th>
      <th>${t('resets')}</th></tr></thead><tbody>${rows}</tbody></table></div>`;
}

function healthServer(sr){
  if(!sr || !sr.ok) return `<div class="card" id="hserver"><h3>${t('hserver')}</h3>
    <p class="badge bad">${esc((sr&&sr.json&&sr.json.error)||'error')}</p></div>`;
  const st = sr.json;
  const b = (S.me && S.me.build) || {};
  const now = Math.floor(Date.now()/1000);
  // Uptime is DERIVED from the build's start time rather than reported as a
  // number the server counts: the same field the footer already renders, so
  // there is one clock and not two that drift by a request's latency.
  const up = b.started ? wkAge(now - b.started) : '–';
  const sch = st.schema || {};
  const pending = sch.pending || [];
  // Migration runs at boot, so a pending one means one FAILED — the whole
  // point of naming the ids rather than counting them (startup.rkt's own
  // message says the same thing to the log, where nobody is looking later).
  const schema = pending.length
    ? `${hBadge(t('hschemapending').replace('{n}', pending.length), 'bad')}
       <span class="mono muted">${pending.map(esc).join(', ')}</span>`
    : `${hBadge(sch.applied+' / '+sch.known, 'ok')} <span class="muted">${t('hmigrations')}</span>`;
  const sealed = st.secrets === 'sealed';
  const secrets = sealed
    ? `${hBadge(t('hsealed'), 'ok')}${st.secret_key_id&&st.secret_key_id!=='null'
         ? ` <span class="mono muted">${esc(st.secret_key_id)}</span>`:''}`
    : `${hBadge(t('hplaintext'), 'warn')} <span class="muted">${t('hplaintexthint')}</span>`;
  const commit = b.commit_short
    ? ` <span class="mono muted" title="${esc(b.commit||'')}">${b.commit==='dev'?esc(t('builddev')):esc(b.commit_short)}</span>`
    : '';
  const drain = (st.drain_seconds===0)
    ? `<span class="muted">${t('hdrainnow')}</span>`
    : `${esc(String(st.drain_seconds))}s`;
  return `<div class="card" id="hserver">
    <h3>${t('hserver')} <span class="muted" style="font-size:13px">— ${t('healthhint')}</span></h3>
    <table>
      ${hRow(t('version'), `<span class="mono">${esc(st.version||'')}</span>${commit}`)}
      ${hRow(t('huptime'), esc(up))}
      ${hRow(t('hdb'), `<span class="mono">${esc(st.dialect||'–')}</span>`)}
      ${hRow(t('hschema'), schema)}
      ${hRow(t('hsecrets'), secrets)}
      ${hRow(t('htls'), st.tls?hBadge(t('featon'),'ok'):hBadge(t('hoff')))}
      ${hRow(t('hblob'), `<span class="mono">${esc((st.blob_store||{}).name||'–')}</span>
         <span class="muted" style="font-size:12px">${t('hblobhint')}</span>`)}
      ${hRow(t('hdrain'), drain, t('hdrainhint'))}
      ${hRow(t('hmt'), st.multitenant?hBadge(t('featon'),'ok'):hBadge(t('hoff')))}
      ${hRow(t('haccounts'), esc(t('haccountsline')
          .replace('{users}', st.users).replace('{teams}', st.teams).replace('{orgs}', st.orgs)))}
    </table></div>`;
}

async function healthView(){
  // One round. None of the five depends on another, and this screen is the
  // console's widest read — five sequential calls is what made the Admin tab
  // slow enough to notice (the sign-in slice measured 300ms a call).
  const [sr, ur, xr, fr, qr, vr] = await Promise.all([
    api('/api/admin/status'),
    api('/api/usage'),
    api('/api/executors'),
    api('/api/admin/workers'+fleetQuery()),
    api('/api/admin/queue'+queueQuery()),
    // #184: the pictures. It joins the round rather than becoming a sixth
    // sequential call, and it shares `fleetQuery()`'s window so the drawings
    // and the figures below them are over the same hours.
    api('/api/admin/queue/flow'+fleetQuery())]);
  const read = hTime(Date.now());
  return `<h2>${t('health')}</h2>
    <p class="muted" style="margin:-.4em 0 1em">
      <span id="hread">${esc(t('hread').replace('{time}', read))}</span>
      <button class="btn sm ghost" style="margin-left:10px"
        data-h-click="${H(()=>renderTab())}">${t('refresh')}</button></p>
    ${healthServer(sr)}
    ${healthBudgets(ur)}
    ${queueVizCard(vr, fr)}
    ${workersCard(xr, fr)}
    ${queueCard(qr, fr)}`;
}
