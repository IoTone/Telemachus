// ---- a picture of work moving through the queue (QVIZ, issue #184) -----------
// An operator has been told "it's slow". Four states look identical in a depth
// count and have different remedies, and the figures that separate them have
// been on `GET /api/admin/queue` and `/api/admin/workers` all along with nothing
// rendering any of them as a shape.
//
// INLINE SVG, NOT A CHART LIBRARY (QVIZ-2). `script-src 'self'` with no
// `'unsafe-inline'` since #110 r6, and bundle assets must be same-origin — so a
// CDN chart library is blocked by policy and a vendored one is a third-party
// dependency shipped for four small pictures, each of which is a `<rect>`. The
// theme tokens are CSS custom properties, so a drawn picture is themed for free
// where a library's canvas would need a second palette.
//
// EVERY FIGURE HERE IS DERIVED FROM THE JOB ROWS (QVIZ-1). There is no counter
// table and no client-side sampling, so the series survive a reload and a
// restart, there is no retention setting, and the picture cannot disagree with
// the table below it — it is the same table.
function qvBar(segs, total){
  // One horizontal stacked bar. THE LEGEND IS DRAWN EVEN WHEN THE QUEUE IS
  // EMPTY, and the bar is not: four zeros beside their colours say what the
  // picture would show and keep the shape of the card stable, where a
  // zero-width `<svg>` says nothing and `n/0` is how a drawing becomes NaN.
  const key = segs.map(s=>`<span class="qvkey"><i style="background:var(--${s.hue})"></i>${esc(s.label)}
    <b>${s.n}</b></span>`).join('');
  const legend = `<p class="qvlegend">${key}</p>`;
  if(!total) return `<p class="muted">${t('qvempty')}</p>${legend}`;
  let x = 0;
  const parts = segs.filter(s=>s.n>0).map(s=>{
    const w = (s.n/total)*100, r = `<rect x="${x}%" y="0" width="${w}%" height="22" fill="var(--${s.hue})">
      <title>${esc(s.label)}: ${s.n}</title></rect>`;
    x += w; return r;
  }).join('');
  return `<svg class="qvbar" viewBox="0 0 100 22" preserveAspectRatio="none" role="img"
      aria-label="${esc(segs.map(s=>s.label+' '+s.n).join(', '))}">${parts}</svg>${legend}`;
}

// A sparkline over a FIXED grid (QVIZ-7): every minute in the window is a
// column whether or not it had a job, so a flat run of zeros is visibly a flat
// run of zeros. Over "the buckets that had rows" a queue that stopped an hour
// ago draws exactly like one working steadily, which is the single distinction
// this picture exists to make.
function qvSpark(label, xs, hue, hint){
  const n = xs.length || 1, max = Math.max(1, ...xs);
  const w = 100/n;
  const bars = xs.map((v,i)=> v>0
    ? `<rect x="${(i*w).toFixed(3)}%" y="${(28-(v/max)*28).toFixed(2)}" width="${(w*0.9).toFixed(3)}%"
         height="${((v/max)*28).toFixed(2)}" fill="var(--${hue})"></rect>`
    : '').join('');
  const total = xs.reduce((a,b)=>a+b,0);
  return `<tr><th title="${esc(hint)}">${esc(label)}</th>
    <td><svg class="qvspark" viewBox="0 0 100 28" preserveAspectRatio="none" role="img"
      aria-label="${esc(label)}: ${total}">${bars}</svg></td>
    <td class="mono muted qvtot">${total}</td>
    <td class="muted qvtot">${t('qvpeak').replace('{n}', max)}</td></tr>`;
}

// Per holding executor, how much of its lease is left. A lease quietly not
// being refreshed is what a failover looks like ninety seconds before it
// happens, and `seconds_left` can legitimately be NEGATIVE — a lease the
// reaper has not swept yet. Clamping that to zero would hide exactly the row
// worth looking at, so it draws empty and is coloured.
function qvLeases(fr){
  if(!fr||!fr.ok) return '';
  const held = (fr.json.executors||[]).filter(e=>e.current);
  if(!held.length) return `<p class="muted">${t('qvnoleases')}</p>`;
  const lease = (fr.json.lease_seconds) || 120;
  const rows = held.map(e=>{
    const left = e.current.seconds_left;
    const frac = Math.max(0, Math.min(1, left/lease));
    const hue = left<=0 ? 'bad' : (frac<0.34 ? 'warn' : 'ok');
    return `<tr><th class="mono">${esc(e.name)}</th>
      <td><svg class="qvspark qvlease" viewBox="0 0 100 14" preserveAspectRatio="none" role="img"
        aria-label="${esc(e.name)} ${wkAge(left)}">
        <rect x="0" y="0" width="100" height="14" fill="var(--line)"></rect>
        <rect x="0" y="0" width="${(frac*100).toFixed(2)}" height="14" fill="var(--${hue})"></rect></svg></td>
      <td class="mono muted qvtot">${left<=0?t('qvexpired'):wkAge(left)}</td>
      <td class="mono muted" style="max-width:16em;overflow:hidden;text-overflow:ellipsis">${esc(e.current.kind)}</td></tr>`;
  }).join('');
  return `<table class="qvtbl"><tbody>${rows}</tbody></table>`;
}

// QVIZ-3: one job's path, read back out of the trail FLEET-1 already writes —
// `job.lease.expired` names the executor and is written BEFORE the requeue,
// because the requeue clears `executor_id` and afterwards nothing says which
// machine dropped the work. A row of pills, because three hosts once each and
// one host three times are different stories that `2/3` cannot tell apart.
//
// It opens IN PLACE, under the row that was clicked, so the affordance works on
// the Admin tab as well as on Health without either screen needing a region of
// its own to render into.
async function jobTrail(id, el){
  const tr = el.closest('tr'); if(!tr) return;
  const open = tr.nextElementSibling;
  if(open && open.classList.contains('qvtrailrow')){ open.remove(); return; }
  const r = await api('/api/admin/jobs/'+encodeURIComponent(id)+'/trail');
  const row = document.createElement('tr');
  row.className = 'qvtrailrow';
  const cells = tr.children.length;
  if(!r.ok){
    row.innerHTML = `<td colspan="${cells}"><span class="badge bad">${esc((r.json&&r.json.error)||'error')}</span></td>`;
  } else {
    const j = r.json;
    // The pool holds a job in process, which leaves `executor_id` NULL — so the
    // trail honestly says "in process" rather than naming a machine it guessed.
    const pill = (name, sub, hue)=>`<span class="qvpill${hue?' '+hue:''}">${esc(name)}${
      sub?`<i>${esc(sub)}</i>`:''}</span>`;
    const steps = (j.events||[]).map(e=>{
      const who = (e.executor && e.executor!=='null') ? e.executor : t('qvinproc');
      const why = e.action==='job.released'
        ? t('qvreleased').replace('{why}', (e.reason&&e.reason!=='null')?e.reason:'')
        : (e.action==='job.lease.expired' ? t('qvexpiredat') : t('qvexhausted'));
      return pill(who, why, e.action==='job.released' ? 'warn' : 'bad');
    });
    const now = (j.holder && j.holder!=='null') ? [pill(j.holder, t('qvholding'), 'ok')]
              : (j.status==='done' ? [pill(t('qvfinished'), '', 'ok')] : []);
    const all = steps.concat(now);
    row.innerHTML = `<td colspan="${cells}"><div class="qvpath">
      <span class="muted mono">${esc(j.kind)}</span>
      ${all.length?all.join('<span class="qvarrow">→</span>'):`<span class="muted">${t('qvnopath')}</span>`}
      <span class="muted">${t('qvattempts').replace('{a}', j.attempt).replace('{m}', j.max_attempts)
        }${j.releases?' · '+t('qvreleases').replace('{n}', j.releases):''}</span></div></td>`;
  }
  tr.parentNode.insertBefore(row, tr.nextSibling);
}

// QVIZ-6: the refresh is a BUTTON and an interval the operator chooses, and it
// defaults to OFF. The console's idle clock counts from the last REQUEST (#38),
// so a screen that refreshed itself unasked would hold a session open for as
// long as the tab was left up — a security control quietly disabled by a
// convenience. The timer is cleared on every render pass, so leaving the tab
// stops it rather than leaving a request loop running behind another screen.
function qvAutoStop(){ if(S.qvTimer){ clearInterval(S.qvTimer); S.qvTimer = null; } }
function qvAutoSet(sec){
  qvAutoStop();
  S.qvEvery = sec;
  if(sec>0) S.qvTimer = setInterval(()=>{ if(S.tab==='health') renderTab(); else qvAutoStop(); }, sec*1000);
}

function queueVizCard(vr, fr){
  if(!vr||!vr.ok) return '';
  const V = vr.json, b = V.breakdown||{};
  const segs = [
    {label:t('qvunclaimable'), n:b.unclaimable||0, hue:'bad'},
    {label:t('qvpaused'),      n:b.held_by_paused||0, hue:'warn'},
    {label:t('qvwaiting'),     n:b.waiting||0, hue:'accent2'},
    {label:t('qvqueued'),      n:b.queued||0, hue:'ok'}];
  const total = segs.reduce((a,s)=>a+s.n,0);
  // `truncated` is not decoration: the scan is bounded, so a deeper queue than
  // the cap means the bar is a SAMPLE of the oldest rows and says so. CLS-27's
  // rule — a figure that stops reporting its own limits is one an operator
  // over-reads.
  const trunc = b.truncated
    ? ` <span class="badge warn" title="${esc(t('qvtrunchint'))}">${t('qvtrunc').replace('{n}', b.scanned)}</span>`
    : '';
  const mins = Math.round((V.bucket_seconds||60)/60);
  const grain = mins>1 ? ` <span class="muted">${t('qvgrain').replace('{n}', mins)}</span>` : '';
  const every = S.qvEvery||0;
  const opts = [0,15,30,60].map(s=>`<option value="${s}"${every===s?' selected':''}>${
    s?s+'s':t('qvautooff')}</option>`).join('');
  return `<div class="card" id="qvcard" style="margin-top:14px">
    <h3>${t('qvtitle')} <span class="muted" style="font-size:13px">— ${
      t('qvwindow').replace('{h}', (V.window||{}).hours)}${grain}</span></h3>
    <div class="row" style="align-items:center">
      <div><label>${t('qvauto')}</label>
        <select data-h-change="${H((el)=>qvAutoSet(parseInt(el.value,10)||0))}">${opts}</select></div>
      <p class="muted" style="margin:0 0 0 auto">${t('qvautohint')}</p>
    </div>
    <h4>${t('qvstuck')} <span class="muted" style="font-weight:normal">— ${
      t('qvstuckhint')}</span>${trunc}</h4>
    ${qvBar(segs, total)}
    <h4>${t('qvflow')}</h4>
    <table class="qvtbl"><tbody>
      ${qvSpark(t('qvarrivals'), V.arrivals||[], 'accent2', t('qvarrivalshint'))}
      ${qvSpark(t('qvclaims'), V.claims||[], 'warn', t('qvclaimshint'))}
      ${qvSpark(t('qvcompletions'), V.completions||[], 'ok', t('qvcompletionshint'))}
    </tbody></table>
    <h4>${t('qvleases')} <span class="muted" style="font-weight:normal">— ${t('qvleaseshint')}</span></h4>
    ${qvLeases(fr)}</div>`;
}
