// ---- email delivery and notifications ----------------------------------------
//
// THREE CARDS AND TWO AUDIENCES. The transport and the instance's categories are
// the OPERATOR's and sit on Admin; a person's own address and opt-outs sit on
// Usage, which is in the base tab list and so is the one screen every member can
// reach. There is no account tab to put them on, and inventing one for two
// controls would be a tab most people never open.
//
// WHAT IS NOT HERE: the per-delivery body. `GET /api/email-deliveries/:id`
// carries it and the console does not ask — a dead-letter list answers "what is
// failing and why", and a page of message bodies is not that. An operator who
// wants to see exactly what went out has the endpoint.

// The person's own card has to survive a render pass with an unsaved address in
// the box, so the draft lives in S — `paintAuth()`'s rule, and the same reason
// the editor keeps its text there.
// THE CATEGORY NAMES ARE THE TAB LABELS THE CATALOGS ALREADY SHIP, which saves
// four strings and, more to the point, keeps every key a LITERAL: a key composed
// at runtime cannot be scanned for, and #184's lesson is that a catalog test has
// to run in BOTH directions — every key shipped must also be asked for — or a
// hard-coded English literal goes through unnoticed. A composed key would read
// as an orphan in exactly that gate.
const CATLABEL = {workflows:'workflows', jobs:'jobs', documents:'documents', reviews:'reviews'};
function catLabel(c){ return CATLABEL[c] ? tRaw(CATLABEL[c]) : c; }

function emailPendingDraft(){ return (document.getElementById('mlad')||{}).value ?? S.mailDraft ?? ''; }

// ---- the operator's transport -------------------------------------------------
function emailTransportCard(){
  const T = (S.mailT && S.mailT.transport) || null;
  const modes = (S.mailT && S.mailT.security_modes) || ['none','starttls','tls'];
  const sel = (T && T.security) || 'starttls';
  const test = T && T.last_test_epoch
    ? `<p class="muted" style="font-size:12px;margin:6px 0 0">${t('mltested')}: ${esc(new Date(T.last_test_epoch*1000).toLocaleString())} — ${
         T.last_test_ok === true ? `<span class="badge ok">${t('mlok')}</span>`
       : T.last_test_ok === false ? `<span class="badge bad">${esc(T.last_test_error||tRaw('error'))}</span>` : '—'}</p>`
    : '';
  return `<div class="card" id="mlcard" style="margin-top:14px"><h3>${t('mltransport')}</h3>
    <p class="muted" style="margin-top:0">${t('mltransporthint')}</p>
    ${T ? '' : `<p class="badge">${t('mlnone')}</p>`}
    <div class="row">
      <div><label>${t('mlhost')}</label><input id="mlh" value="${esc((T&&T.host)||'')}" placeholder="smtp.example.com"></div>
      <div><label>${t('mlport')}</label><input id="mlp" type="number" min="1" max="65535" value="${esc(String((T&&T.port)||587))}"></div>
      <div><label>${t('mlsec')}</label><select id="mls">${modes.map(m=>`<option value="${esc(m)}"${sel===m?' selected':''}>${esc(m)}</option>`).join('')}</select></div>
    </div>
    <div class="row">
      <div><label>${t('mluser')}</label><input id="mlu" value="${esc((T&&T.username)||'')}" autocomplete="off"></div>
      <div><label>${t('mlpass')}</label><input id="mlw" type="password" autocomplete="new-password" placeholder="${T&&T.has_password?t('mlpasskeep'):''}"></div>
    </div>
    ${T && T.password_stored === 'plaintext'
      ? `<p class="muted" id="mlplain" style="font-size:12px;margin:4px 0 0"><span class="badge bad">${t('mlpwplain')}</span> ${t('mlpwplainhint')}</p>` : ''}
    <div class="row">
      <div><label>${t('mlfrom')}</label><input id="mlf" value="${esc((T&&T.from_address)||'')}" placeholder="tmach@example.com"></div>
      <div><label>${t('mlfromname')}</label><input id="mln" value="${esc((T&&T.from_name)||'')}" placeholder="TMach"></div>
    </div>
    <label>${t('mlbase')}</label><input id="mlb" value="${esc((T&&T.base_url)||'')}" placeholder="https://tmach.example.com">
    <p class="muted" style="font-size:12px;margin:4px 0 0">${t('mlbasehint')}</p>
    <label class="muted" style="display:flex;align-items:center;gap:8px;font-weight:normal;margin-top:8px">
      <input type="checkbox" id="mla"${!T || T.active ? ' checked':''}> ${t('mlactive')}</label>
    ${test}
    <div style="margin-top:10px">
      <button class="btn" data-h-click="${H((el,ev)=>doMailSave())}">${t('save')}</button>
      ${T?`<button class="btn ghost" style="margin-left:8px" data-h-click="${H((el,ev)=>doMailClear())}">${t('mlremove')}</button>`:''}
    </div>
    ${T?`<div class="row" style="margin-top:12px;align-items:end">
      <div><label>${t('mltestto')}</label><input id="mlt" placeholder="you@example.com"></div>
      <div style="flex:0 0 auto"><button class="btn" data-h-click="${H((el,ev)=>doMailTest())}">${t('mltest')}</button></div>
    </div>`:''}</div>`;
}

// ---- the operator's categories ------------------------------------------------
// ABSENCE MEANS OFF here, which is the opposite of the instance feature card, so
// the copy says so: an operator NAMES the categories their instance sends. A
// checkbox is the honest control for two states, where #177's feature card needed
// three columns because a layer above it could also object.
function emailNotifyCard(){
  const N = S.mailN || {};
  const cats = N.known || [];
  const doc = N.categories || {};
  const evs = N.events || {};
  const rows = cats.map(c=>`<tr>
      <td><label style="display:flex;align-items:center;gap:8px;font-weight:normal">
        <input type="checkbox" data-cat="${esc(c)}"${doc[c]===true?' checked':''}> ${esc(catLabel(c))}</label></td>
      <td class="muted mono" style="font-size:12px">${(evs[c]||[]).map(esc).join(', ')}</td></tr>`).join('');
  return `<div class="card" id="mlncard" style="margin-top:14px"><h3>${t('mlnotify')}</h3>
    <p class="muted" style="margin-top:0">${t('mlnotifyhint')}</p>
    <table><thead><tr><th>${t('mlcategory')}</th><th>${t('mlevents')}</th></tr></thead><tbody>${rows}</tbody></table>
    <div style="margin-top:10px"><button class="btn" data-h-click="${H((el,ev)=>doMailNotifySave())}">${t('save')}</button></div></div>`;
}

// ---- a person's own -----------------------------------------------------------
function myNotifyCard(){
  const P = S.mailP || {};
  const A = P.address || {};
  const cats = P.categories || [];
  const state = A.address
    ? `<span class="badge ok">${t('mlconfirmed')}</span> <span class="mono">${esc(A.address)}</span>`
    : A.pending
      ? `<span class="badge">${t('mlawaiting')}</span> <span class="mono">${esc(A.pending)}</span>`
      : `<span class="muted">${t('mlnoaddr')}</span>`;
  const rows = cats.map(c=>`<tr>
      <td>${esc(catLabel(c.category))}</td>
      <td>${c.enabled?`<span class="badge ok">${t('enable')}d</span>`:`<span class="badge">${t('disable')}d</span>`}</td>
      <td class="muted" style="font-size:12px">${c.disabled_by?esc(tRaw('mlby')+' '+c.disabled_by):''}</td>
      <td>${
        // A PERSON MAY ALWAYS TURN ONE OFF and may never turn one on past a
        // layer above them, so the Enable button is absent where the refusal is
        // the only possible outcome — FEAT-8's locked row, and for its reason: a
        // control whose only outcome is a 409 is worse than no control.
        c.enabled
          ? `<button class="btn sm ghost" data-h-click="${H((el,ev)=>doMyNotify(c.category,false))}">${t('disable')}</button>`
          : c.disabled_by==='user'
            ? `<button class="btn sm ghost" data-h-click="${H((el,ev)=>doMyNotify(c.category,true))}">${t('enable')}</button>`
            : ''}</td></tr>`).join('');
  return `<div class="card" id="mlminecard" style="margin-top:14px"><h3>${t('mlmine')}</h3>
    <p class="muted" style="margin-top:0">${t('mlminehint')}</p>
    <p style="margin:0 0 8px">${state}</p>
    <div class="row" style="align-items:end">
      <div><label>${t('mladdr')}</label><input id="mlad" value="${esc(emailPendingDraft())}" placeholder="you@example.com"></div>
      <div style="flex:0 0 auto"><button class="btn" data-h-click="${H((el,ev)=>doMyAddress())}">${t('save')}</button></div>
      ${(A.address||A.pending)?`<div style="flex:0 0 auto"><button class="btn sm ghost" data-h-click="${H((el,ev)=>doMyAddressClear())}">${t('remove')}</button></div>`:''}
    </div>
    ${cats.length?`<table style="margin-top:10px"><thead><tr><th>${t('mlcategory')}</th><th>${t('status')}</th><th></th><th></th></tr></thead><tbody>${rows}</tbody></table>`:''}</div>`;
}

// ---- the handlers -------------------------------------------------------------
async function doMailSave(){
  const body = {host:val('mlh'), port:parseInt(val('mlp'),10), security:val('mls'),
                from_address:val('mlf'), from_name:val('mln')||null,
                base_url:val('mlb')||null, active:document.getElementById('mla').checked,
                username:val('mlu')||null};
  // AN ABSENT PASSWORD LEAVES THE STORED ONE ALONE, which is why a blank box
  // sends NO field rather than an empty string: otherwise saving a changed port
  // would clear the credential and the operator would find out from a dead letter.
  const pw = val('mlw');
  if(pw) body.password = pw;
  const r = await api('/api/email-transport',{method:'PUT',body});
  if(r.ok){ toast(tRaw('saved'),true); renderTab(); } else toast((r.json&&r.json.error)||tRaw('error'));
}
async function doMailClear(){
  if(!confirm(tRaw('mlremoveask'))) return;
  const r = await api('/api/email-transport',{method:'DELETE'});
  if(r.ok){ toast(tRaw('saved'),true); renderTab(); } else toast((r.json&&r.json.error)||tRaw('error'));
}
async function doMailTest(){
  const to = val('mlt');
  if(!to){ toast(tRaw('mltestto')); return; }
  const r = await api('/api/email-transport/test',{method:'POST',body:{to}});
  // IT ANSWERS 200 EVEN WHEN THE RELAY REFUSED, so `r.ok` is not the verdict —
  // the body is. A toast that said "sent" because the request succeeded is the
  // exact confusion this endpoint's own shape exists to avoid.
  if(r.ok && r.json && r.json.ok) toast(tRaw('mltestok'),true);
  else toast((r.json&&(r.json.error||tRaw('error')))||tRaw('error'));
  renderTab();
}
// THE WHOLE DOCUMENT, because there is no per-category route at this tier — a
// request carrying only the switch that moved would wipe the others silently and
// nothing would fail (FEAT-7's recorded trap).
async function doMailNotifySave(){
  const doc = {};
  document.querySelectorAll('input[type=checkbox][data-cat]').forEach(b=>{
    if(b.checked) doc[b.dataset.cat] = true;
  });
  const r = await api('/api/email-notify',{method:'PUT',body:{categories:doc}});
  if(r.ok){ toast(tRaw('saved'),true); renderTab(); } else toast((r.json&&r.json.error)||tRaw('error'));
}
async function doMyNotify(category, enabled){
  const r = await api('/api/email-prefs',{method:'PUT',body:{category,enabled}});
  if(r.ok){ S.mailP = Object.assign({}, S.mailP, {categories:r.json.categories}); renderTab(); }
  else toast((r.json&&r.json.error)||tRaw('error'));
}
async function doMyAddress(){
  const a = val('mlad');
  if(!a){ toast(tRaw('mladdr')); return; }
  S.mailDraft = a;
  const r = await api('/api/email-address',{method:'PUT',body:{address:a}});
  if(r.ok){ S.mailDraft=''; toast(r.json.note||tRaw('saved'),!!r.json.queued); renderTab(); }
  else toast((r.json&&r.json.error)||tRaw('error'));
}
async function doMyAddressClear(){
  const r = await api('/api/email-address',{method:'DELETE'});
  if(r.ok){ S.mailDraft=''; toast(tRaw('saved'),true); renderTab(); } else toast((r.json&&r.json.error)||tRaw('error'));
}

// ---- confirming an address ----------------------------------------------------
// THE TOKEN ARRIVES IN THE SEARCH STRING AND IS STRIPPED AT ONCE, which is
// `/activate`'s own pattern and for its reason: a URL is pasted into chat, logged
// by proxies and kept in browser history, so a credential must not stay in the
// address bar. It is stashed in `S` so it survives the sign-in that may be needed
// first — the confirmation is AUTHENTICATED (the link opens the console and the
// console POSTs it with the caller's bearer), because this platform has kept a
// no-cookie JSON API precisely so no GET mutates anything.
function claimVerifyToken(){
  let tok = null;
  try { tok = new URLSearchParams(location.search).get('verify_email'); } catch(e){}
  if(!tok) return;
  S.verifyEmail = tok;
  try {
    const u = new URL(location.href);
    u.searchParams.delete('verify_email');
    history.replaceState(null, '', u.pathname + (u.search||'') + (u.hash||''));
  } catch(e){}
}
// Spent ONCE, whatever happens: a token that failed is not worth retrying on
// every render pass, and a bad token and an expired one are one answer anyway.
async function spendVerifyToken(){
  const tok = S.verifyEmail;
  if(!tok || !S.me) return;
  S.verifyEmail = null;
  const r = await api('/api/email-address/verify',{method:'POST',body:{token:tok}});
  if(r.ok) toast(tRaw('mlconfirmedtoast'),true);
  else toast((r.json&&r.json.error)||tRaw('error'));
}
