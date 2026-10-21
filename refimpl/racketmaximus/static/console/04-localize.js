// ---------- Localization Manager (the flagship) ----------
// The catalogs on disk stay the shipping artifact; this is the workflow around
// them. Import pulls them in, people translate and review here, export writes the
// APPROVED strings back. Nothing else reaches the product.
const L10N_STATUS_BADGE = {
  missing:'', machine:'badge op', drafted:'badge', needs_review:'badge op', approved:'badge ok', stale:'badge bad'
};
function l10nBadge(st){
  return `<span class="${L10N_STATUS_BADGE[st]||'badge'}">${esc(st.replace('_',' '))}</span>`;
}
async function localizeView(){
  const S3 = S.l10n;
  const cov = await api(`/api/l10n/coverage?locale=${encodeURIComponent(S3.locale)}`);
  if(!cov.ok) return `<h2>${t('localize')}</h2><p class="badge bad">${esc(cov.json.error||'error')}</p>`;
  const c = cov.json;
  const known = Array.from(new Set([...(c.locales||[]), 'ja','nl','es-419'])).filter(x=>x!=='en').sort();

  const qs = new URLSearchParams({locale:S3.locale, limit:'50', offset:String(S3.offset)});
  if(S3.status) qs.set('status', S3.status);
  if(S3.ns)     qs.set('namespace', S3.ns);
  if(S3.q)      qs.set('q', S3.q);
  const ms = await api('/api/l10n/messages?'+qs.toString());
  const items = ms.ok ? ms.json.items : [];
  const total = ms.ok ? ms.json.total : 0;

  const manage = canPerm('localization:manage');
  const review = canPerm('localization:review');
  const write  = canPerm('localization:translate');

  const bar = `<div style="height:8px;background:var(--panel2);border-radius:999px;overflow:hidden;margin:6px 0 2px">
      <div style="height:100%;width:${c.pct}%;background:var(--ok)"></div></div>`;

  const statusCounts = Object.entries(c.by_status||{})
    .filter(([,n])=>n>0)
    .map(([k,n])=>`${l10nBadge(k)} ${n}`).join(' &nbsp; ');

  const rows = items.map(i=>{
    const tid = i.translation_id;
    const mine = i.translated_by && S.me && i.translated_by === S.me.user_id;
    const canApprove = review && tid && i.status !== 'approved' && i.status !== 'missing' && !mine;
    return `<tr>
      <td class="mono" style="font-size:12px;vertical-align:top;white-space:nowrap">${esc(i.key)}</td>
      <td style="vertical-align:top;max-width:280px">${esc(i.source_text)}</td>
      <td style="vertical-align:top;min-width:260px">
        <textarea id="l10n_${esc(i.message_id)}" rows="2" ${write?'':'disabled'}>${esc(i.text)}</textarea></td>
      <td style="vertical-align:top;white-space:nowrap">${l10nBadge(i.status)}</td>
      <td style="vertical-align:top;white-space:nowrap">
        ${write?`<button class="btn sm" data-h-click="${H((el,ev)=>l10nSave((i.message_id)))}">${t('save')}</button>`:''}
        ${canApprove?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>l10nReview((tid),'approve'))}">${t('l10napprove')}</button>
                      <button class="btn sm ghost" data-h-click="${H((el,ev)=>l10nReview((tid),'reject'))}">${t('l10nreject')}</button>`:''}
        ${(review && mine && tid && i.status!=='approved')?`<span class="muted" style="font-size:12px">${esc(t('l10nself'))}</span>`:''}
      </td></tr>`;
  }).join('');

  const pager = `<div class="row" style="margin-top:8px">
      ${S3.offset>0?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>l10nPage((Math.max(0,S3.offset-50))))}">« prev</button>`:''}
      ${(S3.offset+50)<total?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>l10nPage((S3.offset+50)))}">next »</button>`:''}
      <span class="muted" style="font-size:12px;align-self:center">${S3.offset+1}–${Math.min(S3.offset+50,total)} / ${total}</span></div>`;

  return `<h2>${t('localize')}</h2>
    <p class="muted" style="margin-top:0">${esc(t('l10nhint'))}</p>
    <div class="card">
      <div class="row" style="align-items:end">
        <div style="flex:0 0 170px"><label>${t('l10ntarget')}</label>
          <select data-h-change="${H((el,ev)=>l10nSetLocale(el.value))}">
            ${known.map(l=>`<option value="${esc(l)}" ${l===S3.locale?'selected':''}>${esc(l)}</option>`).join('')}
          </select></div>
        <div style="flex:2">
          <label>${t('l10ncoverage')} — ${c.approved} / ${c.total} (${c.pct}%)</label>
          ${bar}<div style="font-size:12px">${statusCounts}</div></div>
        <div style="flex:0 0 auto">
          ${manage?`<button class="btn sm ghost" data-h-click="${H((el,ev)=>l10nImport())}">${t('l10nimport')}</button>
                    <button class="btn sm" data-h-click="${H((el,ev)=>l10nDraft())}">${t('l10ndraft')}</button>
                    <button class="btn sm ghost" data-h-click="${H((el,ev)=>l10nExport())}">${t('l10nexport')}</button>`:''}
        </div>
      </div>
    </div>
    <div class="card" style="margin-top:14px">
      <div class="row" style="align-items:end">
        <div style="flex:0 0 180px"><label>${t('l10nstatus')}</label>
          <select data-h-change="${H((el,ev)=>l10nFilter('status',el.value))}">
            <option value="">${t('l10nall')}</option>
            ${['missing','machine','drafted','needs_review','approved','stale'].map(x=>
              `<option value="${x}" ${S3.status===x?'selected':''}>${x.replace('_',' ')}</option>`).join('')}
          </select></div>
        <div style="flex:0 0 160px"><label>namespace</label>
          <select data-h-change="${H((el,ev)=>l10nFilter('ns',el.value))}">
            <option value="">all</option>
            ${(c.by_namespace||[]).map(n=>`<option value="${esc(n.namespace)}" ${S3.ns===n.namespace?'selected':''}>${esc(n.namespace)} (${n.approved}/${n.total})</option>`).join('')}
          </select></div>
        <div style="flex:2"><label>${t('l10nsearch')}</label>
          <input id="l10nq" value="${esc(S3.q)}" data-h-change="${H((el,ev)=>l10nFilter('q',el.value))}"></div>
      </div>
      ${items.length? `<table><thead><tr><th>${t('l10nkey')}</th><th>${t('l10nsource')}</th><th>${t('l10ntranslation')}</th><th>${t('l10nstatus')}</th><th></th></tr></thead><tbody>${rows}</tbody></table>${pager}`
                    : `<p class="muted">${esc(t('l10nnothing'))}</p>`}
    </div>`;
}
function l10nSetLocale(v){ S.l10n.locale=v; S.l10n.offset=0; renderTab(); }
function l10nFilter(k,v){ S.l10n[k]=v; S.l10n.offset=0; renderTab(); }
function l10nPage(off){ S.l10n.offset=off; renderTab(); }
async function l10nSave(mid){
  const el=document.getElementById('l10n_'+mid); if(!el) return;
  const r=await api('/api/l10n/messages/'+mid,{method:'PUT',body:{locale:S.l10n.locale,text:el.value}});
  if(r.ok){ toast(t('saved'),true); renderTab(); } else toast(r.json.error||'error');
}
async function l10nReview(tid,decision){
  const r=await api('/api/l10n/review/'+tid,{method:'POST',body:{decision}});
  if(r.ok){ toast(t('saved'),true); renderTab(); } else toast(r.json.error||'error');
}
async function l10nImport(){
  const r=await api('/api/l10n/import',{method:'POST'});
  if(r.ok){ toast(`+${r.json.added} keys, ${r.json.linked} linked, ${r.json.updated} changed`,true); renderTab(); }
  else toast(r.json.error||'error');
}
async function l10nDraft(){
  const r=await api('/api/l10n/draft',{method:'POST',body:{locale:S.l10n.locale,namespace:S.l10n.ns||''}});
  if(r.ok){
    const b=r.json.budget||{};
    const short = typeof b.remaining==='number' && typeof b.estimate==='number' && b.estimate>b.remaining;
    toast(t('draftqueued').replace('{n}',r.json.queued).replace('{b}',r.json.batches),true);
    // Over budget, the queue just stops and looks like a hang. Say so now.
    if(short) toast(t('draftbudget').replace('{need}',b.estimate).replace('{left}',b.remaining));
  } else toast(r.json.error||'error');
}
async function l10nExport(){
  const r=await api('/api/l10n/export',{method:'POST',body:{locale:S.l10n.locale}});
  if(r.ok) toast(`wrote ${r.json.written} approved strings — restart to serve them`,true);
  else toast(r.json.error||'error');
}


