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
// WHICH WORKER RAN THIS? On a fleet of several GPU hosts that is the first
// question asked of this table, and `executor_id` is a uuid, so the name is
// joined server-side (see JSELECT in scheduler.rkt).
//
// An absent name means TWO different things and conflating them misleads: a
// queued job has not been claimed by anybody yet, while a job that has RUN with
// no holder ran in the server's own pool — an in-process claim leaves
// `executor_id` NULL by design, because the pool mints no executor row.
//
// BOTH CASES SAY SO IN WORDS. A bare dash with the explanation in a `title` was
// the first version and it was reported as the column not working at all, which
// is fair: a tooltip is invisible, and "–" in a column headed `worker` reads as
// missing data rather than as "no worker was involved, by design".
function jobWorker(j){
  if(j.executor && j.executor!=='null') return `<span class="mono">${esc(j.executor)}</span>`;
  if(j.status==='queued')
    return `<span class="muted" title="${esc(t('jobunclaimed'))}">${esc(t('jobunclaimedshort'))}</span>`;
  return `<span class="muted" title="${esc(t('jobinproc'))}">${esc(t('jobinprocshort'))}</span>`;
}

// WHEN, FROM THE EPOCH AND NEVER FROM THE TEXT COLUMN. `created_at` is TEXT
// `CURRENT_TIMESTAMP` and its format differs by dialect; worse,
// `new Date("2026-11-01 05:15:17")` is read as LOCAL time by most engines while
// the value is UTC, so a parsed timestamp would be silently out by the viewer's
// own offset. `created_epoch` is an integer, so the age is arithmetic and the
// absolute time is formatted by the browser in the viewer's own zone.
//
// The ABSOLUTE time is the title and the RELATIVE age is the text: "4m ago" is
// what answers "is this moving?", which is why somebody is looking at this
// column, and the wall-clock time is one hover away for when it is not.
function jobWhen(j){
  const e=j.created_epoch;
  if(e==null||e==='null') return `<span class="muted">–</span>`;
  const abs=new Date(e*1000);
  const age=wkAge(Math.floor(Date.now()/1000)-e);
  // "4m ago" is a sentence, so the word order is the catalog's and not English's
  return `<span class="muted" title="${esc(abs.toLocaleString())}">${esc(t('jobago').replace('{age}', age))}</span>`;
}

// HOW LONG IT TOOK — or how long it has been going, which is the number
// somebody watching a queue actually wants.
//
// The first version answered only for a FINISHED job, so the column was blank
// for exactly the rows a person is staring at. Reported from outside: "Jobs page
// should have durations for the run, or duration so far if not complete."
//
// Both ends are epochs from the same clock (0038 stamps the claim, 0066 the
// terminal write), so this is a duration and not a difference between two
// differently-formatted strings. A RUNNING job has only the first, so the second
// end is now — and it is marked, because "14s" and "14s and counting" are
// different facts and a reader who cannot tell them apart will read a stalled
// job as a fast one.
//
// A QUEUED job has NEITHER end and gets nothing: it has not started, so it has
// no duration, and showing its age here would duplicate the `when` column while
// looking like a run time.
function jobTook(j){
  const a=j.started_epoch;
  if(a==null||a==='null') return '';
  const b=j.finished_epoch;
  const settled = !(b==null||b==='null');
  const d = (settled ? b : Math.floor(Date.now()/1000)) - a;
  if(d<0) return '';
  return settled
    ? ` <span class="muted" title="${esc(t('jobtookhint'))}">· ${esc(wkAge(d))}</span>`
    : ` <span title="${esc(t('jobrunninghint'))}" style="color:var(--accent3)">· ${esc(t('jobsofar').replace('{age}', wkAge(d)))}</span>`;
}

function jobsRows(jobs){
  return jobs.map(j=>`<tr><td class="mono muted">${esc(j.id.slice(0,8))}</td><td>${esc(j.kind)}</td>`
    + `<td>${jobStatusBadge(j.status)}${jobWaitBadge(j)}</td>`
    + `<td style="white-space:nowrap">${jobWhen(j)}${jobTook(j)}</td>`
    + `<td>${jobWorker(j)}</td>`
    + `<td class="muted">${esc(jobResultText(j))}</td>`
    + `<td>${(j.status==='queued'||j.status==='running')?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>doCancelJob((j.id)))}">${t('cancel')}</button>`:''}</td></tr>`).join('');
}

// The LIST is its own card so a refresh can swap it alone. The submit form above
// it holds whatever the person has typed, and re-rendering the tab to show a new
// row would throw that away as well as blanking the screen.
function jobsListCard(jobs){
  // REFRESH WHILE THE STATUS IS ACTUALLY CHANGING, AND NOT A MOMENT LONGER.
  //
  // A plain interval was the other option and QVIZ-6 is why it is not taken:
  // the idle clock counts from the last REQUEST (#38), so a screen that
  // refreshed itself for as long as it was left open would hold a session
  // alive indefinitely — a security control switched off by a convenience.
  // This ticks only while some job is queued, running or canceling, and the
  // last settling job stops it, so an idle console really does go idle.
  //
  // It swaps THIS CARD rather than calling `renderTab()`, which paints a `…`
  // placeholder before it awaits — as a 2s poll that blanked and repainted the
  // whole tab on every tick.
  const live = jobs.some(j=>j.status==='queued'||j.status==='running'||j.status==='canceling');
  if(live){ const gen=++S.jobPoll;
    setTimeout(()=>{ if(S.tab==='jobs'&&S.jobPoll===gen) jobsRefresh(); },2000); }
  return `<div class="card" id="jobscard" style="margin-top:14px"><div class="row" style="justify-content:space-between;align-items:center"><h3 style="margin:0">${t('jobs')}</h3>
      <div class="row" style="align-items:center;gap:10px;margin:0">${
        live?`<span class="muted" style="font-size:13px">${esc(t('joblive'))}</span>`:''
      }<button class="btn sm ghost" data-h-click="${H((el,ev)=>jobsRefresh())}">${t('refresh')}</button></div></div>
      <table style="margin-top:8px"><thead><tr><th>id</th><th>kind</th><th>${t('status')}</th>
        <th title="${esc(t('jobwhenhint'))}">${t('jobwhen')}</th>
        <th>${t('worker')}</th><th>result</th><th></th></tr></thead>
      <tbody>${jobsRows(jobs)}</tbody></table></div>`;
}

async function jobsRefresh(){
  return cardSwap('jobscard', async () => {
    const r=await api('/api/jobs');
    return r.ok ? jobsListCard(r.json.jobs||[]) : null;
  });
}

// WHAT APPEARS HERE AND WHAT DOES NOT, said in words. Reported from outside as
// "jobs don't seem to be populating anymore, no new jobs since 9+ hours ago" —
// and the queue was perfectly healthy: the newest row really was nine hours old,
// because everything done in between was Chat (which STREAMS, so there is no job
// to row), Translate (synchronous — the request IS the work) and Ask (a direct
// call). None of the three creates a scheduler job, so a screen that lists
// scheduler jobs correctly showed nothing new, and a correct empty answer to an
// unasked question reads exactly like a broken one.
//
// The honest fix is to say so. Making a translation a job instead is the real
// answer and is #233 — it is what gives it progress, a cancel and a place in
// this list — but the silence is a defect of its own and is not waiting on that.
async function jobsView(){
  const r=await api('/api/jobs'); const jobs=r.ok?r.json.jobs:[];
  return `<h2>${t('jobs')}</h2>
    <div class="card"><h3>${t('submitjob')}</h3>
      <div class="row" style="align-items:end">
        <div><label>kind</label><select id="jk"><option value="chat">chat</option><option value="translate">translate</option></select></div>
        <div style="flex:1"><label>${t('prompt')} / ${t('sourcetext')}</label><input id="jtext"></div>
        <div><label>${t('target')}</label><input id="jtgt" value="ja" style="width:90px"></div>
        <div><button class="btn" data-h-click="${H((el,ev)=>doSubmitJob())}">${t('submit')}</button></div></div>
      <p class="muted" style="margin:8px 0 0;font-size:13px">${esc(t('jobkindhint'))}</p></div>
    ${jobsListCard(jobs)}
    <p class="muted" style="font-size:13px;margin-top:10px">${esc(t('jobscope'))}</p>`;
}
async function doSubmitJob(){
  const kind=val('jk'), text=val('jtext');
  const payload = kind==='translate' ? {text, target_lang: val('jtgt')} : {prompt: text};
  const r=await api('/api/jobs',{method:'POST',body:{kind,payload}});
  if(r.ok){ toast(t('queued'),true); jobsRefresh(); } else toast(r.json.error||t('error'));
}
async function doCancelJob(id){
  const r=await api('/api/jobs/'+id+'/cancel',{method:'POST'});
  if(r.ok){ toast(t('canceled'),true); jobsRefresh(); } else toast(r.json.error||t('error'));
}
