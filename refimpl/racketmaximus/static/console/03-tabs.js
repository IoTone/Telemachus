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
      <label>${t('prompt')}</label><textarea id="cp" rows="3">Hello team</textarea>
      <button class="btn" data-h-click="${H((el,ev)=>doChat())}">${t('send')}</button>
    </div><div id="chatlog"></div>`;
}
async function doChat(){
  const prompt=val('cp'); const log=document.getElementById('chatlog'); const id='b'+Date.now();
  log.insertAdjacentHTML('afterbegin',
    `<div class="bubble" id="${id}"><div class="q">${esc(prompt)}</div><div class="rep"></div><div class="meta muted" style="font-size:12px;margin-top:6px">…</div></div>`);
  const rep=document.querySelector('#'+id+' .rep'), meta=document.querySelector('#'+id+' .meta');
  const headers={'X-Telemachus-Locale':S.lang,'Content-Type':'application/json'}; if(S.token) headers['Authorization']='Bearer '+S.token;
  let res; try{ res=await fetch('/api/ai/chat/stream',{method:'POST',headers,body:JSON.stringify({prompt})}); }
  catch(e){ toast('network error'); document.getElementById(id).remove(); return; }
  if(!res.ok){ let j={}; try{j=await res.json()}catch(e){} toast((j.error||'error')+(j.dimension?` (${j.dimension})`:'')); document.getElementById(id).remove(); return; }
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
}

async function agentView(){
  return `<h2>${t('agent')} <span class="muted" style="font-size:14px">— the AI uses tools to act on your platform</span></h2>
    <div class="card"><label>${t('prompt')}</label>
      <textarea id="ap" rows="3">Create a private note titled "Q3 goals" with body "ship v1, hire two, launch". Then list my notes.</textarea>
      <button class="btn" data-h-click="${H((el,ev)=>doAgent())}">${t('send')}</button></div><div id="agentlog"></div>`;
}
async function doAgent(){
  const prompt=val('ap'); const log=document.getElementById('agentlog'); const id='g'+Date.now();
  log.insertAdjacentHTML('afterbegin', `<div class="bubble" id="${id}"><div class="q">${esc(prompt)}</div><div class="steps"></div><div class="rep" style="margin-top:6px"></div></div>`);
  const steps=document.querySelector('#'+id+' .steps'), rep=document.querySelector('#'+id+' .rep');
  const headers={'X-Telemachus-Locale':S.lang,'Content-Type':'application/json'}; if(S.token) headers['Authorization']='Bearer '+S.token;
  let res; try{ res=await fetch('/api/agent',{method:'POST',headers,body:JSON.stringify({prompt})}); }
  catch(e){ toast('network error'); document.getElementById(id).remove(); return; }
  if(!res.ok){ let j={}; try{j=await res.json()}catch(e){} toast((j.error||'error')+(j.dimension?` (${j.dimension})`:'')); document.getElementById(id).remove(); return; }
  const reader=res.body.getReader(), dec=new TextDecoder(); let buf='';
  for(;;){ const {value,done}=await reader.read(); if(done) break; buf+=dec.decode(value,{stream:true});
    let i; while((i=buf.indexOf('\n\n'))>=0){ const line=buf.slice(0,i).trim(); buf=buf.slice(i+2);
      if(!line.startsWith('data:')) continue; let ev={}; try{ ev=JSON.parse(line.slice(5).trim()); }catch(e){ continue; }
      if(ev.type==='assistant' && ev.text) steps.insertAdjacentHTML('beforeend', `<div class="muted" style="margin:3px 0">💭 ${esc(ev.text)}</div>`);
      if(ev.type==='tool') steps.insertAdjacentHTML('beforeend', `<div style="margin:3px 0">🔧 <b>${esc(ev.name)}</b> <span class="mono muted">${esc(JSON.stringify(ev.args))}</span></div>`);
      if(ev.type==='tool_result') steps.insertAdjacentHTML('beforeend', ev.artifact ? artifactCard(ev.artifact) : `<div class="mono" style="margin:0 0 6px 20px;color:var(--ok);white-space:pre-wrap">${esc(ev.result)}</div>`);
      if(ev.type==='done') rep.innerHTML = `<div>${esc(ev.reply)}</div><div class="muted" style="font-size:12px;margin-top:4px">${ev.rounds} rounds</div>`;
      if(ev.error) toast(ev.error);
    } }
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
async function notesView(){
  const r=await api('/api/notes'); const notes=r.ok?r.json.notes:[];
  const mem=await api('/api/members'); const members=mem.ok?mem.json.members:[];
  const opts=members.map(m=>`<option value="${m.user_id}">${esc(m.username)}</option>`).join('');
  const list=notes.map(n=>`<div class="note">
      <h4>${esc(n.title)||'(untitled)'} <span class="badge">${esc(n.visibility)}</span> ${n.owner_user_id===S.me.user_id?'<span class="badge ok">mine</span>':''}</h4>
      <div class="muted">${esc(n.body)}</div>
      <div class="row" style="margin-top:8px">
        <div style="flex:2"><select id="sh_${n.id}">${opts}</select></div>
        <div><button class="btn sm ghost" data-h-click="${H((el,ev)=>doShare((n.id)))}">${t('share')}</button></div>
        <div><button class="btn sm bad" data-h-click="${H((el,ev)=>doDelNote((n.id)))}">${t('del')}</button></div>
      </div></div>`).join('') || `<p class="muted">—</p>`;
  return `<h2>${t('notes')}</h2>
    <div class="card"><h3>${t('newnote')}</h3>
      <label>${t('title')}</label><input id="nt" value="Secret plan">
      <label>${t('body')}</label><input id="nb" value="only for me">
      <label>${t('visibility')}</label><select id="nv"><option>team</option><option>private</option><option>shared</option></select>
      <button class="btn" data-h-click="${H((el,ev)=>doCreateNote())}">${t('create')}</button>
    </div>${list}`;
}
async function doCreateNote(){ const r=await api('/api/notes',{method:'POST',body:{title:val('nt'),body:val('nb'),visibility:val('nv')}});
  if(r.ok){ toast('created',true); renderTab(); } else toast(r.json.error||'error'); }
async function doShare(id){ const uid=document.getElementById('sh_'+id).value;
  const r=await api('/api/notes/'+id+'/share',{method:'POST',body:{user_id:uid,permission:'notes:read'}});
  toast(r.ok?'shared':(r.json.error||'error'), r.ok); }
async function doDelNote(id){ const r=await api('/api/notes/'+id,{method:'DELETE'});
  if(r.ok){ toast('deleted',true); renderTab(); } else toast(r.json.error||'error'); }

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
  const featRows = Object.entries(S.features||{}).map(([f,on])=>`<tr><td class="mono">${esc(f)}</td><td>${on?'<span class="badge ok">on</span>':'<span class="badge">off</span>'}</td><td><button class="btn sm ghost" data-h-click="${H((el,ev)=>doToggleFeature((f),(!on)))}">${on?t('disable'):t('enable')}</button></td></tr>`).join('');
  const featCard = manage ? `<div class="card" style="margin-top:14px"><h3>${t('features')} <span class="muted" style="font-size:13px">— activate / deactivate</span></h3>
      <table><thead><tr><th>feature</th><th>status</th><th></th></tr></thead><tbody>${featRows}</tbody></table></div>` : '';
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
      <table><thead><tr><th>${t('tool')}</th><th>permission</th><th>source</th><th>status</th><th></th></tr></thead><tbody>${toolRows}</tbody></table></div>`;
}
async function doSetQuota(){ const r=await api('/api/quota',{method:'POST',body:{dimension:val('qd'),limit:parseInt(val('ql'),10),window:'day'}});
  if(r.ok){ toast('updated',true); renderTab(); } else toast(r.json.error||'error'); }
async function doToggleTool(name,enabled){ const r=await api('/api/tools/'+name,{method:'POST',body:{enabled}});
  if(r.ok){ toast(name+(enabled?' enabled':' disabled'),true); renderTab(); } else toast(r.json.error||'error'); }

