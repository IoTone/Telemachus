// ---------- tabs ----------
async function chatView(){
  if(!S.model){ const m=await api('/api/ai/model'); S.model=m.json; }
  // issue #64: the badge said "· simulated" in hardcoded English — the one
  // console string that never reached the catalogs, so a Japanese operator read
  // the word that matters least in the language they had not chosen.
  const badge = S.model?.configured ? `<span class="badge ok">${esc(S.model.model)}</span>`
    : `<span class="badge" style="color:var(--warn)" title="${esc(t('simulatedwhy'))}">${esc(S.model?.model||'local')} · ${esc(t('simulated'))}</span>`;
  return `<h2>${t('chat')} <span class="muted" style="font-size:14px">${t('model')}: ${badge}</span></h2>
    <div class="card">
      <label>${t('prompt')}</label>
      <textarea id="cp" class="grow" rows="3" data-h-keydown="${H((el,ev)=>sendKey(ev,doChat))}"
        data-h-input="${H((el)=>{growTA(el);cpCount();})}">Hello team</textarea>
      <div id="cpcount" class="muted" style="font-size:12px"></div>
      <div class="row" style="align-items:center;gap:8px">
        <button class="btn" id="cpsend" data-h-click="${H((el,ev)=>doChat())}">${t('send')}</button>
        <button class="btn ghost" id="cpstop" style="display:none" data-h-click="${H((el,ev)=>stopStream('chatAbort'))}">${t('stop')}</button>
        <span class="muted" style="font-size:12px">${t('sendhint')}</span>
      </div>
    </div><div id="chatlog"></div>`;
}
// The two prompt fields' bindings of the shared counter (`01-base.js`). The
// limit is the server's own `max_chars`, reported on `/api/ai/model` — never a
// literal here, for the reason #231 gave on the Translate field.
function cpCount(){ charCount('cp', 'cpcount', (S.model && S.model.max_chars) || 0); }
function apCount(){ charCount('ap', 'apcount', (S.model && S.model.max_chars) || 0); }

async function doChat(){
  // #174: one in-flight send. Returning early is the whole guard; everything
  // below releases it in the `finally`, or one network error would leave the
  // button dead with no way back but a reload.
  if(S.chatAbort) return;
  const prompt=val('cp'); if(!prompt) return;
  const log=document.getElementById('chatlog'); const id='b'+Date.now();
  log.insertAdjacentHTML('afterbegin',
    `<div class="bubble" id="${id}"><div class="q">${esc(prompt)}</div><div class="rep"></div><div class="meta muted" style="font-size:12px;margin-top:6px">…</div></div>`);
  const rep=document.querySelector('#'+id+' .rep'), meta=document.querySelector('#'+id+' .meta');
  const headers={'X-Telemachus-Locale':S.lang,'Content-Type':'application/json'}; if(S.token) headers['Authorization']='Bearer '+S.token;
  const ac=new AbortController(); S.chatAbort=ac; sendBusy('cpsend','cpstop',true);
  try{
  let res; try{ res=await fetch('/api/ai/chat/stream',{method:'POST',headers,body:JSON.stringify({prompt}),signal:ac.signal}); }
  catch(e){ if(e.name!=='AbortError') toast('network error'); document.getElementById(id).remove(); return; }
  if(!res.ok){ let j={}; try{j=await res.json()}catch(e){} toast((j.error||'error')+(j.dimension?` (${j.dimension})`:'')); document.getElementById(id).remove(); return; }
  // The prompt is cleared only once the request has been ACCEPTED: a refusal
  // (a quota, a bad request) leaves the text where the person can resend it.
  const box=document.getElementById('cp'); if(box) box.value='';
  const reader=res.body.getReader(), dec=new TextDecoder(); let buf='';
  for(;;){ const {value,done}=await reader.read(); if(done) break; buf+=dec.decode(value,{stream:true});
    let i; while((i=buf.indexOf('\n\n'))>=0){ const line=buf.slice(0,i).trim(); buf=buf.slice(i+2);
      if(!line.startsWith('data:')) continue; let ev={}; try{ ev=JSON.parse(line.slice(5).trim()); }catch(e){ continue; }
      if(ev.token){ if(meta.textContent==='…') meta.textContent=''; rep.textContent += ev.token; }
      if(ev.error) toast(ev.error);
      // issue #64: with no model configured the stream is a deterministic echo of
      // the prompt. Say so where the reply is, rather than letting a reader take
      // it for a model's answer — the server flags it, the console never guesses.
      if(ev.done){ meta.textContent = `${ev.tokens_used} tokens · ${esc(ev.model)} · remaining ${ev.remaining_tokens}`;
        if(ev.simulated) meta.insertAdjacentHTML('beforeend',
          ` · <span style="color:var(--warn)" title="${esc(t('simulatedwhy'))}">\u26a0 ${esc(t('simulated'))}</span>`); }
    } }
  } catch(e){ if(e.name!=='AbortError') throw e;
    // Stopped on purpose: keep what arrived and say so, rather than discarding
    // an answer the reader may already have read half of.
    if(meta) meta.textContent=(meta.textContent==='…'?'':meta.textContent+' · ')+t('stopped');
  } finally { S.chatAbort=null; sendBusy('cpsend','cpstop',false); }
}

// The counter needs the server's limit, and the agent tab never read it — so it
// makes the same one-line fetch Chat does rather than keeping a literal of its
// own. `S.model` is shared, so a tab change does not pay for it twice.
async function agentView(){
  if(!S.model){ const m=await api('/api/ai/model'); S.model=m.json; }
  return `<h2>${t('agent')} <span class="muted" style="font-size:14px">— the AI uses tools to act on your platform</span></h2>
    <div class="card"><label>${t('prompt')}</label>
      <textarea id="ap" class="grow" rows="3" data-h-keydown="${H((el,ev)=>sendKey(ev,doAgent))}"
        data-h-input="${H((el)=>{growTA(el);apCount();})}">Create a private note titled "Q3 goals" with body "ship v1, hire two, launch". Then list my notes.</textarea>
      <div id="apcount" class="muted" style="font-size:12px"></div>
      <div class="row" style="align-items:center;gap:8px">
        <button class="btn" id="apsend" data-h-click="${H((el,ev)=>doAgent())}">${t('send')}</button>
        <button class="btn ghost" id="apstop" style="display:none" data-h-click="${H((el,ev)=>stopStream('agentAbort'))}">${t('stop')}</button>
        <span class="muted" style="font-size:12px">${t('sendhint')}</span>
      </div></div><div id="agentlog"></div>`;
}
async function doAgent(){
  // #174 again: an agent run is the more expensive of the two to double —
  // a tool-using turn costs thousands of tokens where a chat costs tens.
  if(S.agentAbort) return;
  const prompt=val('ap'); if(!prompt) return;
  const log=document.getElementById('agentlog'); const id='g'+Date.now();
  log.insertAdjacentHTML('afterbegin', `<div class="bubble" id="${id}"><div class="q">${esc(prompt)}</div><div class="steps"></div><div class="rep" style="margin-top:6px"></div></div>`);
  const steps=document.querySelector('#'+id+' .steps'), rep=document.querySelector('#'+id+' .rep');
  const headers={'X-Telemachus-Locale':S.lang,'Content-Type':'application/json'}; if(S.token) headers['Authorization']='Bearer '+S.token;
  const ac=new AbortController(); S.agentAbort=ac; sendBusy('apsend','apstop',true);
  try{
  let res; try{ res=await fetch('/api/agent',{method:'POST',headers,body:JSON.stringify({prompt}),signal:ac.signal}); }
  catch(e){ if(e.name!=='AbortError') toast('network error'); document.getElementById(id).remove(); return; }
  if(!res.ok){ let j={}; try{j=await res.json()}catch(e){} toast((j.error||'error')+(j.dimension?` (${j.dimension})`:'')); document.getElementById(id).remove(); return; }
  const box=document.getElementById('ap'); if(box) box.value='';
  const reader=res.body.getReader(), dec=new TextDecoder(); let buf='';
  for(;;){ const {value,done}=await reader.read(); if(done) break; buf+=dec.decode(value,{stream:true});
    let i; while((i=buf.indexOf('\n\n'))>=0){ const line=buf.slice(0,i).trim(); buf=buf.slice(i+2);
      if(!line.startsWith('data:')) continue; let ev={}; try{ ev=JSON.parse(line.slice(5).trim()); }catch(e){ continue; }
      // WHAT THE MODEL WAS NOT OFFERED IS SAID HERE, or the fitting that makes
      // the agent work on a 4,096-token window would be a silent subtraction.
      // It leads the run rather than trailing it: a run that could not use a
      // tool is explained before the reader watches it not use one.
      if(ev.type==='tools_withheld') steps.insertAdjacentHTML('beforeend', `<div class="bx-warn">${esc(ev.message)}</div>`);
      if(ev.type==='assistant' && ev.text) steps.insertAdjacentHTML('beforeend', `<div class="muted" style="margin:3px 0">💭 ${esc(ev.text)}</div>`);
      if(ev.type==='tool') steps.insertAdjacentHTML('beforeend', `<div style="margin:3px 0">🔧 <b>${esc(ev.name)}</b> <span class="mono muted">${esc(JSON.stringify(ev.args))}</span></div>`);
      if(ev.type==='tool_result') steps.insertAdjacentHTML('beforeend', ev.artifact ? artifactCard(ev.artifact) : `<div class="mono" style="margin:0 0 6px 20px;color:var(--ok);white-space:pre-wrap">${esc(ev.result)}</div>`);
      if(ev.type==='done') rep.innerHTML = `<div>${esc(ev.reply)}</div><div class="muted" style="font-size:12px;margin-top:4px">${ev.rounds} rounds</div>`;
      if(ev.error) toast(ev.error);
    } }
  } catch(e){ if(e.name!=='AbortError') throw e;
    // A stopped agent run has already spent what it spent: the steps it took
    // stay on screen, because they are what the person needs to see.
    steps.insertAdjacentHTML('beforeend', `<div class="muted" style="margin:3px 0">${esc(t('stopped'))}</div>`);
  } finally { S.agentAbort=null; sendBusy('apsend','apstop',false); }
}
// an artifact-shaped tool result (slice 64): the thing a tool produced, as a card
// that opens it, rather than its payload as text
function artifactCard(a){
  const open = a.object_id ? `<button class="btn sm ghost" data-h-click="${H((el,ev)=>kgOpenDoc((a.object_id)))}">${t('details')}</button>`
             : (a.url ? `<a class="btn sm ghost" href="${esc(a.url)}" target="_blank" rel="noopener">${t('open')}</a>` : '');
  return `<div class="card" style="margin:4px 0 8px 20px;padding:8px 10px;display:flex;gap:10px;align-items:center">
    <span class="badge">${esc(a.kind)}</span>
    <div style="flex:1;min-width:0"><b class="mono" style="font-size:13px">${esc(a.title)}</b>
      ${a.summary?`<div class="muted" style="font-size:12px">${esc(a.summary)}</div>`:''}</div>
    <div style="flex:none">${open}</div></div>`;
}
// #245: the tag list and the notes go out TOGETHER. They are independent reads
// and the sign-in slice measured a sequential await as 300ms a call, so the two
// that do not depend on each other share a round.
async function notesView(){
  const q = (S.noteTags||[]).map(x=>'tag='+encodeURIComponent(x)).join('&');
  const [r, tg, mem] = await Promise.all([
    api('/api/notes'+(q?'?'+q:'')),
    api('/api/note-tags'),
    api('/api/members')
  ]);
  const notes=r.ok?r.json.notes:[];
  const allTags=tg.ok?tg.json.tags:[];
  const members=mem.ok?mem.json.members:[];
  const opts=members.map(m=>`<option value="${m.user_id}">${esc(m.username)}</option>`).join('');
  const filter = tagFilterStrip(allTags);
  // #180: there was no way to EDIT a note. `PUT /api/notes/:id` has existed
  // since the routes were written and the console called it nowhere — #113's
  // shape on this side of the wire. An editor for a field you can only fill in
  // once is worth very little, so the edit path lands with the editor.
  const editing = S.noteEdit ? notes.filter(n=>n.id===S.noteEdit)[0] : null;
  // Reported from outside: "the notes view should have a view button, not just
  // edit." The list has rendered each body since #180, so what was missing is a
  // place to READ one — a note alone, with the facts about it, and no editor
  // and no delete button under the cursor. Viewing and editing are the same
  // state slot, so opening one closes the other: two cards claiming the top of
  // the tab would be a layout somebody has to reason about.
  const viewing = (S.noteShow && !editing) ? notes.filter(n=>n.id===S.noteShow)[0] : null;
  const list=notes.map(n=>`<div class="note">
      <h4>${esc(n.title)||'(untitled)'} <span class="badge">${esc(n.visibility)}</span> ${n.owner_user_id===S.me.user_id?'<span class="badge ok">mine</span>':''}</h4>
      <div class="md">${bodyRender(n.body, n.format)}</div>
      ${noteFormatBadge(n)}${noteTagChips(n)}
      <div class="row" style="margin-top:8px">
        <div style="flex:2"><select id="sh_${n.id}">${opts}</select></div>
        <div><button class="btn sm ghost" data-h-click="${H((el,ev)=>doShare((n.id)))}">${t('share')}</button></div>
        <div><button class="btn sm ghost" data-h-click="${H((el,ev)=>noteShow((n.id)))}">${t('view')}</button></div>
        <div><button class="btn sm ghost" data-h-click="${H((el,ev)=>noteEdit((n.id),(n.body),(n.title),(n.visibility),(n.tags),(n.format)))}">${t('edit')}</button></div>
        <div><button class="btn sm ghost"${S.autoTagging===n.id?' disabled':''}
          data-h-click="${H((el,ev)=>doAutoTag((n.id)))}"
          title="${esc(t('autotaghint'))}">${S.autoTagging===n.id?esc(t('autotagging')):t('autotag')}</button></div>
        <div><button class="btn sm bad" data-h-click="${H((el,ev)=>doDelNote((n.id)))}">${t('del')}</button></div>
      </div></div>`).join('') || `<p class="muted">—</p>`;
  const card = viewing
    ? noteViewCard(viewing)
    : editing
    ? `<div class="card"><h3>${t('editnote')} <span class="muted" style="font-size:13px">${esc(editing.title||'')}</span></h3>
      <label>${t('title')}</label><input id="nt" value="${esc(editing.title||'')}">
      <label>${t('body')}</label>${editorHTML('note', {id:'nb', formats:NOTE_FORMATS})}
      <label>${t('tags')}</label><input id="ntags" value="${esc((editing.tags||[]).join(', '))}" placeholder="${esc(t('tagsph'))}">
      <div class="muted" style="font-size:12px;margin:-6px 0 8px">${esc(t('tagshint'))}</div>
      <label>${t('visibility')}</label><select id="nv">${
        ['team','private','shared'].map(x=>`<option${x===editing.visibility?' selected':''}>${x}</option>`).join('')}</select>
      <button class="btn" data-h-click="${H((el,ev)=>doSaveNote())}">${t('save')}</button>
      <button class="btn ghost" style="margin-left:8px" data-h-click="${H((el,ev)=>noteEditCancel())}">${t('cancel')}</button>
      ${noteTools('note','nt')}</div>`
    : `<div class="card"><h3>${t('newnote')}</h3>
      <label>${t('title')}</label><input id="nt" value="Secret plan">
      <label>${t('body')}</label>${editorHTML('note', {id:'nb', value:'only for me', formats:NOTE_FORMATS})}
      <label>${t('tags')}</label><input id="ntags" value="" placeholder="${esc(t('tagsph'))}">
      <div class="muted" style="font-size:12px;margin:-6px 0 8px">${esc(t('tagshint'))}</div>
      <label>${t('visibility')}</label><select id="nv"><option>team</option><option>private</option><option>shared</option></select>
      <button class="btn" data-h-click="${H((el,ev)=>doCreateNote())}">${t('create')}</button>
      ${noteTools('note','nt')}</div>`;
  return `<h2>${t('notes')}</h2>${card}${filter}${list}`;
}

// The tag list the server DERIVED, as a filter. Each chip toggles; several chips
// are an AND, which is what the server does with a repeated `?tag=`. It is drawn
// from `GET /api/note-tags` and never from the notes on the page, for the reason
// #239's folder strip is: the page is already narrowed by the filter, so a strip
// built from it would lose every tag the current filter excludes — and a filter
// you cannot widen again is worse than no filter.
function tagFilterStrip(tags){
  const on = S.noteTags||[];
  if(!tags.length && !on.length) return '';
  const chip = x => `<button class="btn sm ${on.indexOf(x.tag)>=0?'':'ghost'}"
      data-h-click="${H(()=>noteTagToggle(x.tag))}">${esc(x.tag)} <span class="muted">${x.notes}</span></button>`;
  const clear = on.length
    ? `<button class="btn sm ghost" data-h-click="${H(()=>noteTagClear())}">${t('tagclear')}</button>` : '';
  return `<div class="card" style="padding:10px 14px"><div style="display:flex;flex-wrap:wrap;gap:6px;align-items:center">
    <span class="muted" style="font-size:12px;margin-right:4px">${esc(t('tags'))}</span>
    ${tags.map(chip).join('')}${clear}</div></div>`;
}
// ORG-1's vocabulary, and it is the SERVER's: `NOTE-FORMATS` in notes.rkt is
// what a write is held to, and a console offering a third option would produce
// a refusal naming a format nobody can see where it came from. The order is the
// server's too — Markdown first, because it is the column's default.
const NOTE_FORMATS = ['markdown', 'org'];
// Shown only for an org note. A badge reading "markdown" on every note that has
// ever existed is noise about the default, and this console's own rule
// (PULL-11e, RED-20) is that a field is worth drawing when it tells a reader
// something they could not assume.
function noteFormatBadge(n){
  return n.format === 'org' ? `<div style="margin-top:8px"><span class="badge">${esc(t('fmtorg'))}</span></div>` : '';
}
function noteTagChips(n){
  const ts = n.tags||[];
  if(!ts.length) return '';
  return `<div style="display:flex;flex-wrap:wrap;gap:6px;margin-top:8px">${
    ts.map(x=>`<span class="badge">${esc(x)}</span>`).join('')}</div>`;
}
function noteTagToggle(tag){
  const on = (S.noteTags||[]).slice();
  const i = on.indexOf(tag);
  if(i>=0) on.splice(i,1); else on.push(tag);
  S.noteTags = on; renderTab();
}
function noteTagClear(){ S.noteTags=[]; renderTab(); }
// A tags field is typed, so it is split on commas HERE and normalized by the
// server — the console never decides what a tag may be, or there would be two
// vocabularies and the one a person sees would be the wrong one.
function readTags(){
  return val('ntags').split(',').map(x=>x.trim()).filter(x=>x.length);
}
// Export and "save to the repository" are the issue's fourth ask and they are
// the same two buttons on both surfaces, so they are composed once here rather
// than spelled out in each card.
function noteTools(key, titleId){
  // The LABEL follows the format, because `edExport` writes `.org` for an org
  // note — a button reading "Export .md" that produces a `.org` file would be
  // the kind of quietly wrong detail this console's own notes keep catching.
  const org = edFormat(key) === 'org';
  return `<div class="row" style="margin-top:10px;gap:8px">
    <div style="flex:0 0 auto"><button class="btn sm ghost" id="edexp_${key}"
      data-h-click="${H(()=>edExport(key, (document.getElementById(titleId)||{}).value||'note'))}"
      title="${esc(t(org?'edexportorghint':'edexporthint'))}">${t(org?'edexportorg':'edexport')}</button></div>
    <div style="flex:0 0 auto"><button class="btn sm ghost"
      data-h-click="${H(()=>edToRepo(key, titleId))}"
      title="${esc(t('edtorepohint'))}">${t('edtorepo')}</button></div></div>`;
}
// READ-ONLY, AND THE TIMESTAMPS ARE NOT PARSED. `notes.created_at` and
// `updated_at` are TEXT `CURRENT_TIMESTAMP`, whose format differs by dialect —
// and worse, `new Date("2026-11-01 05:15:17")` is read as LOCAL time by most
// engines while the value is UTC, so a parsed timestamp is silently out by the
// viewer's own offset with nothing to catch it (CARD-3's trap). There are no
// epoch columns on this table, so the string is shown as stored and LABELLED
// UTC rather than converted wrongly.
function noteViewCard(n){
  const mine = n.owner_user_id === S.me.user_id;
  return `<div class="card">
    <h3 style="margin-top:0">${esc(n.title)||'(untitled)'}
      <span class="badge">${esc(n.visibility)}</span>${mine?' <span class="badge ok">mine</span>':''}</h3>
    <div class="md">${bodyRender(n.body, n.format)}</div>
    <div class="muted" style="font-size:12px;margin-top:10px">
      ${esc(t('created'))}: ${esc(n.created_at)} UTC · ${esc(t('updated'))}: ${esc(n.updated_at)} UTC
      · <span class="mono">${esc(n.id)}</span></div>
    <div class="row" style="margin-top:10px;gap:8px">
      <div style="flex:0 0 auto"><button class="btn sm"
        data-h-click="${H(()=>noteEdit(n.id, n.body, n.title, n.visibility, n.tags, n.format))}">${t('edit')}</button></div>
      <div style="flex:0 0 auto"><button class="btn sm ghost"
        data-h-click="${H(()=>noteViewClose())}">${t('close')}</button></div>
    </div></div>`;
}
function noteShow(id){ S.noteShow=id; S.noteEdit=null; edReset('note','', 'nb', 'markdown'); renderTab(); }
function noteViewClose(){ S.noteShow=null; renderTab(); }
// The FORMAT is set here and not re-asserted on every render, for `editorHTML`'s
// own reason: opening a note is what declares which renderer its body wants, and
// a format re-read on each pass would undo the toolbar's own switch.
function noteEdit(id, body, title, vis, tags, format){ S.noteEdit=id; S.noteShow=null; edReset('note', body, 'nb', format); renderTab(); }
function noteEditCancel(){ S.noteEdit=null; edReset('note', '', 'nb', 'markdown'); renderTab(); }
async function doSaveNote(){
  const r=await api('/api/notes/'+S.noteEdit,{method:'PUT',
    body:{title:val('nt'), body:edRead('note'), visibility:val('nv'), tags:readTags(),
          format:edFormat('note')}});
  if(r.ok){ S.noteEdit=null; edReset('note','', 'nb'); toast(t('saved'),true); renderTab(); }
  else toast((r.json&&r.json.error)||'error');
}
async function doCreateNote(){ const r=await api('/api/notes',{method:'POST',
  body:{title:val('nt'),body:edRead('note'),visibility:val('nv'),tags:readTags(),format:edFormat('note')}});
  if(r.ok){ edReset('note','', 'nb'); toast('created',true); renderTab(); } else toast(r.json.error||'error'); }
// ONE send, #174's shape: the flag IS the guard and the pending state, there is
// no `await` between the check and the set, and it is cleared in a `finally` or
// one network error leaves the button dead for the rest of the session. A model
// call against the team's budget is exactly what must not be fired twice by a
// double click.
async function doAutoTag(id){
  if(S.autoTagging) return;
  S.autoTagging = id;
  renderTab();
  try {
    const r = await api('/api/notes/'+id+'/autotag', {method:'POST', body:{}});
    if(!r.ok){ toast((r.json&&r.json.error)||'error'); return; }
    const added = r.json.added||[], dropped = r.json.dropped||[];
    // "it proposed nothing" and "it proposed things I could not use" are
    // different answers and the toast says which
    if(added.length) toast(t('autotagged')+' '+added.join(', '), true);
    else if(dropped.length) toast(t('autotagnone')+' ('+dropped.length+')');
    else toast(t('autotagnone'));
    renderTab();
  } finally { S.autoTagging = null; }
}
async function doShare(id){ const uid=document.getElementById('sh_'+id).value;
  const r=await api('/api/notes/'+id+'/share',{method:'POST',body:{user_id:uid,permission:'notes:read'}});
  toast(r.ok?'shared':(r.json.error||'error'), r.ok); }
async function doDelNote(id){ const r=await api('/api/notes/'+id,{method:'DELETE'});
  if(r.ok){ if(S.noteEdit===id){ S.noteEdit=null; edReset('note','', 'nb'); } toast('deleted',true); renderTab(); } else toast(r.json.error||'error'); }

async function teamView(){
  const r=await api('/api/members'); const members=r.ok?r.json.members:[];
  const manage=canManage();
  const me = S.me ? S.me.user_id : null;
  const ROLES=['owner','admin','member','viewer'];
  const rows=members.map(m=>{
    const own = m.user_id===me;
    const roleCell = (manage && !own)
      ? `<select data-h-change="${H((el,ev)=>doSetMemberRole(m.user_id, el.value))}">${
           ROLES.map(x=>`<option value="${x}"${x===m.role?' selected':''}>${esc(x)}</option>`).join('')}</select>`
      : `<span class="badge">${esc(m.role)}</span>`;
    const act = (manage && !own)
      ? `<button class="btn sm ghost" data-h-click="${H((el,ev)=>doRemoveMember(m.user_id, m.username))}">${t('remove')}</button>`
      : '';
    return `<tr><td>${esc(m.username)}</td><td>${roleCell}</td><td class="mono muted">${esc(m.user_id.slice(0,8))}…</td><td>${act}</td></tr>`;
  }).join('');
  const tks = manage ? await api('/api/tokens') : {ok:false};
  const tokens = tks.ok ? tks.json.tokens : [];
  const aud = manage ? await api('/api/audit') : {ok:false};
  const audits = aud.ok ? aud.json.audit : [];
  const tokRows = tokens.map(x=>`<tr><td>${esc(x.name||'—')}</td><td class="mono muted">${esc(x.prefix)}…</td><td class="mono muted">${(x.scopes||[]).map(esc).join(' ')}</td><td>${x.status==='active'?'<span class="badge ok">active</span>':'<span class="badge">'+esc(x.status)+'</span>'}</td><td>${x.status==='active'?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>doRevokeToken((x.id)))}">${t('revoke')}</button>`:''}</td></tr>`).join('');
  const newTokBox = S.newToken ? `<div class="card" style="border-color:var(--ok);margin:0 0 10px"><b>New token — copy now, shown once:</b><br><span class="mono" style="word-break:break-all">${esc(S.newToken)}</span></div>` : '';
  const tokCard = manage ? `<div class="card" style="margin-top:14px"><h3>${t('apitokens')}</h3>${newTokBox}
      <div class="row" style="align-items:end;margin-bottom:8px"><div><label>${t('name')||'name'}</label><input id="tkn"></div>
      <div><label>scopes</label><input id="tks" value="*:read"></div>
      <div><button class="btn sm" data-h-click="${H((el,ev)=>doCreateToken())}">${t('createtoken')}</button></div></div>
      <table><thead><tr><th>name</th><th>prefix</th><th>scopes</th><th>status</th><th></th></tr></thead><tbody>${tokRows}</tbody></table></div>` : '';
  const audRows = audits.slice(0,20).map(a=>`<tr><td class="mono muted">${esc((a.at||'').replace('T',' ').slice(0,19))}</td><td>${esc(a.action)}</td><td class="mono muted">${esc((a.actor_id||'').slice(0,8))}</td><td class="mono muted">${a.resource_type?esc(a.resource_type)+' '+esc((a.resource_id||'').slice(0,8)):''}</td></tr>`).join('');
  const audCard = manage ? `<div class="card" style="margin-top:14px"><h3>${t('audit')} <span class="muted" style="font-size:13px">— recent activity</span></h3>
      <table><thead><tr><th>time</th><th>action</th><th>actor</th><th>resource</th></tr></thead><tbody>${audRows}</tbody></table></div>` : '';
  // #177: THREE statuses, not two. A feature is on; or this team turned it off;
  // or a layer ABOVE this team did, which a team cannot undo — the attempt is a
  // 409 naming the layer (FEAT-1's tighten-only rule). So where `disabled_by` is
  // not "team" there is no Enable control at all, rather than a button whose
  // only outcome is a refusal. Disable stays available even then: a team
  // recording its own intention survives the instance's switch being flipped
  // back, which is the one thing that makes the team row worth keeping.
  const featRows = (S.featRows||[]).map(x=>{
    const f=x.feature, on=x.enabled, by=x.disabled_by||'';
    const above = !on && by && by!=='team';
    const status = on ? `<span class="badge ok">${esc(t('featon'))}</span>`
                      : `<span class="badge">${esc(t('featoff'))}</span>`;
    const act = above ? `<span class="muted" style="font-size:12px">${esc(t('featlocked'))}</span>`
      : `<button class="btn sm ghost" data-h-click="${H((el,ev)=>doToggleFeature((f),(!on)))}">${on?t('disable'):t('enable')}</button>`;
    return `<tr><td class="mono">${esc(f)}</td><td>${status}</td><td class="mono muted">${esc(by)}</td><td>${act}</td></tr>`;
  }).join('');
  const featCard = manage ? `<div class="card" style="margin-top:14px"><h3>${t('features')} <span class="muted" style="font-size:13px">— activate / deactivate</span></h3>
      <table><thead><tr><th>feature</th><th>status</th><th>${t('featdecided')}</th><th></th></tr></thead><tbody>${featRows}</tbody></table></div>` : '';
  return `<h2>${t('team')}</h2>
    <div class="card"><table><thead><tr><th>${t('user')}</th><th>${t('role')}</th><th>id</th></tr></thead><tbody>${rows}</tbody></table></div>
    <div class="card" style="margin-top:14px"><h3>${t('addmember')}</h3>
      <div class="row"><div><label>${t('user')}</label><input id="mu"></div><div><label>${t('pass')}</label><input id="mp" type="password"></div>
      <div><label>${t('role')}</label><select id="mr"><option>member</option><option>admin</option><option>viewer</option></select></div></div>
      <button class="btn" data-h-click="${H((el,ev)=>doAddMember())}">${t('addmember')}</button>
    </div>
    <div class="card" style="margin-top:14px"><h3>${t('chpw')}</h3>
      <label>${t('curpw')}</label><input id="pc" type="password">
      <label>${t('newpw')}</label><input id="pn" type="password">
      <button class="btn" data-h-click="${H((el,ev)=>doChangePw())}">${t('updpw')}</button>
    </div>${featCard}${tokCard}${audCard}`;
}
async function doToggleFeature(name,on){
  const r=await api('/api/features/'+name,{method:'POST',body:{enabled:on}});
  if(r.ok){ toast(name+(on?' enabled':' disabled'),true); render(); } else toast(r.json.error||'error');
}
async function doCreateToken(){
  const scopes=val('tks').split(/\s+/).filter(Boolean);
  const r=await api('/api/tokens',{method:'POST',body:{name:val('tkn'),scopes}});
  if(r.ok){ S.newToken=r.json.token; toast('token created',true); renderTab(); } else toast(r.json.error||'error');
}
async function doRevokeToken(id){
  const r=await api('/api/tokens/'+id,{method:'DELETE'});
  if(r.ok){ toast('revoked',true); renderTab(); } else toast(r.json.error||'error');
}
async function doChangePw(){
  const r=await api('/api/password',{method:'POST',body:{current_password:val('pc'),new_password:val('pn')}});
  // issue #54: the server revokes every session the old password could have minted,
  // including this one, so the token in hand is already dead — sign out rather than
  // let the next request fail with a bare 401.
  if(r.ok){ toast(t('pwsignedout'),true); logout(); }
  else toast(r.json.error||'error');
}
async function doSetMemberRole(uid, role){
  const r=await api('/api/members/'+uid,{method:'PATCH',body:{role}});
  if(r.ok){ toast(t('rolechanged'),true); renderTab(); } else toast(r.json.error||'error');
}
async function doRemoveMember(uid, name){
  if(!confirm(t('removeconfirm').replace('{name}', name))) return;
  const r=await api('/api/members/'+uid,{method:'DELETE'});
  if(r.ok){ toast(t('memberremoved'),true); renderTab(); } else toast(r.json.error||'error');
}
async function doAddMember(){ const r=await api('/api/members',{method:'POST',body:{username:val('mu'),password:val('mp'),role:val('mr')}});
  if(r.ok){ toast('added',true); renderTab(); } else toast(r.json.error||'error'); }

function canManage(){ if(!S.me) return false; if(S.me.is_operator) return true;
  return (S.me.permissions||[]).some(p=>p==='*:*'||p==='settings:manage'||p==='*:manage'); }
// issue #55: a budget that has stopped the team's queued work says so HERE,
// where the limits are, naming the dimension and who can raise it. Without it an
// over-budget team sees jobs sitting in `queued` and reads it as a hang — which
// is exactly how it was read.
function quotaHeldCard(held){
  if(!held) return '';
  const fill = (k)=>t(k).replace('{dimension}', esc(held.dimension||''))
                        .replace('{used}', esc(String(held.used)))
                        .replace('{limit}', esc(String(held.limit)));
  const body = held.scope==='org' ? fill('quotaheldorg') : fill('quotaheldteam');
  // resets_at is epoch SECONDS and absent for a sliding window, so the sentence
  // is only added when the server actually named a boundary
  const when = held.resets_at ? ' '+t('quotaresets').replace('{when}',
                 esc(new Date(held.resets_at*1000).toLocaleString())) : '';
  // an org-tier limit is not the team operator's to raise, so do not promise it
  const who = (S.me && S.me.is_operator && held.scope!=='org') ? t('quotaraiseop') : t('quotaraiseask');
  return `<div class="card" style="border-color:var(--warn,#c9a227);margin-bottom:14px">
      <h3>⏸ ${t('quotaheldtitle')}</h3><p style="margin:0">${body}${when} ${who}</p></div>`;
}
async function usageView(){
  const r=await api('/api/usage'); const q=r.ok?r.json.quota:[];
  const held=r.ok?r.json.held:null;
  const tr=await api('/api/tools'); const tools=tr.ok?tr.json.tools:[];
  const pr=await api('/api/plugins'); const plugins=pr.ok?pr.json.plugins:[];
  const op=await api('/api/oop'); const oops=op.ok?op.json.plugins:[];
  // A person's own notification address and opt-outs. No permission — their own
  // rows, the rule `GET /api/sessions` already follows — and it lives on Usage
  // because that tab is in the base list, so it is the one screen every member
  // can reach. There is no account tab, and inventing one for two controls would
  // be a tab most people never open.
  const mpr=await api('/api/email-prefs'); if(mpr.ok) S.mailP=mpr.json;
  const manage=canManage();
  const rows=q.map(d=>`<tr><td class="mono">${esc(d.dimension)}</td><td>${d.used}</td><td>${d.limit}</td><td>${d.remaining}</td>
      <td class="muted">${d.resets_at?esc(new Date(d.resets_at*1000).toLocaleString()):'—'}</td></tr>`).join('');
  const opForm = S.me.is_operator ? `<div class="card" style="margin-top:14px"><h3>${t('setquota')}</h3>
      <div class="row"><div><label>${t('dimension')}</label><select id="qd"><option>ai.tokens.total</option><option>ai.requests</option><option>ai.concurrency</option></select></div>
      <div><label>${t('limit')}</label><input id="ql" value="50"></div></div>
      <button class="btn" data-h-click="${H((el,ev)=>doSetQuota())}">${t('setquota')}</button></div>` : '';
  const toolRows=tools.map(x=>`<tr><td class="mono">${esc(x.name)}</td><td class="mono muted">${esc(x.permission)}</td>
      <td>${x.source==='built-in'?'<span class="badge">built-in</span>':`<span class="badge ok">🔌 ${esc(x.source)}</span>`}</td>
      <td>${x.enabled?'<span class="badge ok">on</span>':'<span class="badge">off</span>'}</td>
      <td>${manage?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>doToggleTool((x.name),(!x.enabled)))}">${x.enabled?t('disable'):t('enable')}</button>`:''}</td></tr>`).join('');
  // issue #43: a plugin with a page gets a link. Opening it needs a ticket — the
  // page is authenticated and a browser navigation carries no bearer — so the
  // link mints one and opens the URL the server hands back.
  const plugLine = plugins.length ? `<p class="muted" style="margin:0 0 8px">🔌 ${plugins.map(p=>
    p.bundle ? `<a href="#" data-h-click="${H((el,ev)=>{pluginOpen(p.id);return false})}">${esc(p.name)}</a> v${esc(p.version)}`
             : esc(p.name)+' v'+esc(p.version)).join(', ')}</p>` : '';
  const oopLine = oops.length ? `<p class="muted" style="margin:0 0 8px">🛡️ sandboxed: ${oops.map(p=>esc(p.name)+' <span class="mono">['+(p.scopes||[]).map(esc).join(', ')+']</span>').join(' · ')}</p>` : '';
  return `<h2>${t('usage')}</h2>
    ${quotaHeldCard(held)}
    <div class="card"><table><thead><tr><th>${t('dimension')}</th><th>used</th><th>limit</th><th>remaining</th><th>${t('resets')}</th></tr></thead><tbody>${rows}</tbody></table></div>${opForm}
    <div class="card" style="margin-top:14px"><h3>${t('tools')} <span class="muted" style="font-size:13px">— agent capabilities</span></h3>
      ${plugLine}${oopLine}
      <table><thead><tr><th>${t('tool')}</th><th>permission</th><th>source</th><th>status</th><th></th></tr></thead><tbody>${toolRows}</tbody></table></div>
    ${myNotifyCard()}`;
}
async function doSetQuota(){ const r=await api('/api/quota',{method:'POST',body:{dimension:val('qd'),limit:parseInt(val('ql'),10),window:'day'}});
  if(r.ok){ toast('updated',true); renderTab(); } else toast(r.json.error||'error'); }
async function doToggleTool(name,enabled){ const r=await api('/api/tools/'+name,{method:'POST',body:{enabled}});
  if(r.ok){ toast(name+(enabled?' enabled':' disabled'),true); renderTab(); } else toast(r.json.error||'error'); }

