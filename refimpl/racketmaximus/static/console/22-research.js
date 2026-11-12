// ---------- research: bookmarks, what they say, and a picture (#191 slice 3) ----------
//
// The five `/api/research` routes have existed since slice 1 and nothing a
// PERSON could press reached them. This is that screen: bookmark a page (the
// server archives it against link rot), fetch it again (a new VERSION of the
// same key, so earlier copies stay readable), forget it (the archived page is
// an ordinary document and stays), and see what the knowledge graph learned
// from it.
//
// THE DRAWING IS THE NOTE GRAPH'S `graphLayout`, NOT A SECOND ONE. One seeded,
// fixed-tick layout serves both pictures, so the determinism argument
// (ORG-13, RG-9) is made once. And for the same reason as there: nothing here
// animates, polls or schedules — #38's idle clock counts from the last request,
// and a picture that kept ticking would hold a session open.
//
// What a reader can act on is NAMED rather than shown as an empty list: no
// archived copy yet (fetch again), a page that is not theirs to read, and a
// page Index Knowledge has not read — each has a different remedy.
S.rs = { sel: null, ent: null, hops: 1 };

async function researchView(){
  const r = await api('/api/research');
  if(!r.ok) return `<h2>${t('research')}</h2><div class="card"><p class="muted">${esc(r.json.error||'unavailable')}</p></div>`;
  const src = r.json.sources || [];
  const rows = src.map(s => `<tr>
      <td><b>${esc(s.title && s.title !== 'null' ? s.title : s.url)}</b>
        <div class="muted mono" style="font-size:12px">${esc(s.url)}</div>
        ${s.note && s.note !== 'null' ? `<div class="muted" style="font-size:12px">${esc(s.note)}</div>` : ''}</td>
      <td>${s.archived ? `<span class="badge run">${esc(t('rs_archived'))}</span>`
                       : `<span class="badge bad">${esc(t('rs_notarchived'))}</span>`}
        ${s.last_error && s.last_error !== 'null' ? `<div class="muted" style="font-size:12px" title="${esc(s.last_error)}">${esc(t('rs_lasterror'))}</div>` : ''}</td>
      <td>${jobWhen({ created_epoch: s.last_ok_epoch })}</td>
      <td style="white-space:nowrap">
        <button class="btn sm ghost" data-h-click="${H(() => rsOpen(s.id))}">${t('details')}</button>
        <button class="btn sm ghost" data-h-click="${H(() => rsFetch(s.id))}">${t('rs_refetch')}</button>
        ${s.archived ? `<button class="btn sm ghost" data-h-click="${H(() => kgOpenDoc(s.object_id))}">${t('rs_openpage')}</button>` : ''}
        <button class="btn sm bad" data-h-click="${H(() => rsDelete(s.id))}">${t('del')}</button></td></tr>`).join('');
  return `<h2>${t('research')}</h2>
    <div class="card">
      <div class="muted" style="font-size:12px;margin-bottom:8px">${t('rs_hint')}</div>
      <div class="row" style="align-items:end">
        <div style="flex:2"><label>${t('rs_url')}</label><input id="rsurl" placeholder="https://"
          data-h-keydown="${H((el, ev) => sendKey(ev, rsCreate))}"></div>
        <div style="flex:1"><label>${t('rs_title')}</label><input id="rstitle"></div>
        <div style="flex:1"><label>${t('rs_note')}</label><input id="rsnote"></div>
        <div style="flex:none"><button class="btn" id="rsadd" data-h-click="${H(() => rsCreate())}">${t('rs_add')}</button></div>
      </div>
      ${src.length
        ? `<table style="margin-top:10px"><thead><tr><th>${t('rs_page')}</th><th>${t('rs_state')}</th><th>${t('rs_lastok')}</th><th></th></tr></thead><tbody>${rows}</tbody></table>`
        : `<p class="muted" style="margin-top:10px">${t('rs_none')}</p>`}
    </div>
    <div id="rsdetail">${S.rs.sel ? await rsDetailHtml(S.rs.sel) : ''}</div>`;
}

// ONE send, #174's shape: the flag is the guard and the pending state, and
// nothing awaits between the check and the set. A create FETCHES the page, so
// it is slow enough for a second press to land.
async function rsCreate(){
  if(S.rsSending) return;
  const url = val('rsurl');
  if(!url) return;
  S.rsSending = true;
  const b = document.getElementById('rsadd'); if(b) b.disabled = true;
  try {
    const r = await api('/api/research', { method: 'POST',
      body: { url, title: val('rstitle') || undefined, note: val('rsnote') || undefined } });
    if(!r.ok){ toast(r.json.error || 'error'); return; }
    const f = r.json.fetched || {};
    toast(f.ok === false ? t('rs_fetchfailed') : t('created'), f.ok !== false);
    S.rs.sel = r.json.source ? r.json.source.id : (r.json.id || null);
    S.rs.ent = null;
    renderTab();
  } finally {
    S.rsSending = false;
    const b2 = document.getElementById('rsadd'); if(b2) b2.disabled = false;
  }
}

async function rsFetch(id){
  const r = await api('/api/research/' + encodeURIComponent(id) + '/fetch', { method: 'POST' });
  if(!r.ok){ toast(r.json.error || 'error'); return; }
  const f = r.json.fetched || {};
  toast(!f.ok ? t('rs_fetchfailed') : (f.unchanged ? t('rs_unchanged') : t('rs_newversion')), !!f.ok);
  renderTab();
}

async function rsDelete(id){
  if(!confirm(t('rs_delconfirm'))) return;
  const r = await api('/api/research/' + encodeURIComponent(id), { method: 'DELETE' });
  if(!r.ok){ toast(r.json.error || 'error'); return; }
  toast(t('deleted'), true);
  if(S.rs.sel === id){ S.rs.sel = null; S.rs.ent = null; }
  renderTab();
}

async function rsOpen(id){
  S.rs.sel = id; S.rs.ent = null; S.rs.hops = 1;
  const el = document.getElementById('rsdetail');
  if(el){ el.innerHTML = await rsDetailHtml(id); revealEl('rsdetail'); }
}

// Which remedy, in words. An empty list is never left to speak for itself.
function rsEntitiesNote(r){
  if(r.reason === 'not-archived') return t('rs_notarchivedhint');
  if(r.reason === 'unreadable') return t('rs_unreadable');
  if(!(r.entities || []).length) return r.extracted ? t('rs_noentities') : t('rs_unread');
  if(!r.extracted) return t('rs_stale');
  return '';
}

async function rsDetailHtml(id){
  const [sr, er] = await Promise.all([
    api('/api/research/' + encodeURIComponent(id)),
    api('/api/research/' + encodeURIComponent(id) + '/entities')]);
  if(!sr.ok) return `<div class="card" style="margin-top:14px"><p class="muted">${esc(sr.json.error || 'not found')}</p></div>`;
  const s = sr.json, ents = er.ok ? er.json : { entities: [], reason: 'unreadable' };
  const note = rsEntitiesNote(ents);
  const list = (ents.entities || []).map(e => `<tr>
      <td><a href="#" data-h-click="${H(() => { rsGraph(e.id); return false; })}">${esc(e.name)}</a></td>
      <td><span class="badge">${esc(e.type)}</span></td>
      <td class="muted">${esc(e.mention_count)}</td></tr>`).join('');
  return `<div class="card" style="margin-top:14px">
    <div class="row" style="justify-content:space-between;align-items:center">
      <h3 style="margin:0">${esc(s.title && s.title !== 'null' ? s.title : s.url)}</h3>
      <div style="flex:none"><button class="btn sm ghost" data-h-click="${H(() => rsClose())}">${t('close')}</button></div></div>
    <div class="muted mono" style="font-size:12px">${esc(s.url_canon)}</div>
    <p class="muted" style="font-size:12px;margin:6px 0 0">${esc(t('rs_fetches').replace('{n}', s.fetches))}
      ${s.content_type && s.content_type !== 'null' ? ` · <span class="mono">${esc(s.content_type)}</span>` : ''}</p>
    <h4 style="margin:12px 0 6px">${t('rs_entities')}</h4>
    ${note ? `<p class="muted" id="rsentnote">${esc(note)}</p>` : ''}
    ${list ? `<table id="rsents"><thead><tr><th>${t('kg_entity')}</th><th>${t('kg_type')}</th><th>${t('kg_mentions')}</th></tr></thead><tbody>${list}</tbody></table>` : ''}
    <div id="rsgraph">${S.rs.ent ? await rsGraphHtml(S.rs.ent) : ''}</div>
  </div>`;
}

function rsClose(){ S.rs.sel = null; S.rs.ent = null; const el = document.getElementById('rsdetail'); if(el) el.innerHTML = ''; }

// A graph change SWAPS THE GRAPH, not the tab (NPG-10's rule): `renderTab()`
// paints a placeholder and would throw away a URL somebody was typing into the
// create field above.
async function rsGraphSwap(){
  const el = document.getElementById('rsgraph');
  if(!el) return;
  el.innerHTML = S.rs.ent ? await rsGraphHtml(S.rs.ent) : '';
}
function rsGraph(id){ S.rs.ent = id; S.rs.hops = 1; rsGraphSwap(); }
function rsSetHops(v){ const n = parseInt(v, 10); S.rs.hops = (n === 2) ? 2 : 1; rsGraphSwap(); }

async function rsGraphHtml(id){
  const r = await api('/api/kg/entities/' + encodeURIComponent(id) + '/graph?hops=' + S.rs.hops);
  if(!r.ok) return `<p class="muted">${esc(r.json.error || 'not found')}</p>`;
  const G = r.json, focus = (G.nodes || []).find(n => n.focus) || {};
  const sel = [1, 2].map(d => `<option value="${d}"${d === S.rs.hops ? ' selected' : ''}>${d}</option>`).join('');
  return `<div class="card" id="rsgraphcard" style="margin-top:12px">
    <div class="row" style="gap:8px;align-items:flex-end">
      <div style="flex:1"><h4 style="margin:0">${esc(t('rs_graph').replace('{n}', focus.name || ''))}</h4></div>
      <div style="flex:none"><label>${t('rs_hops')}</label>
        <select data-h-change="${H(el => rsSetHops(el.value))}">${sel}</select></div>
      <div style="flex:none"><button class="btn sm ghost" data-h-click="${H(() => { S.rs.ent = null; rsGraphSwap(); })}">${t('close')}</button></div>
    </div>
    <p class="muted" style="font-size:12px;margin:6px 0 0">${esc(t('rs_graphcount')
      .replace('{n}', (G.nodes || []).length).replace('{e}', (G.edges || []).length))}</p>
    ${G.truncated ? `<p class="muted" style="font-size:12px">${esc(t('rs_truncated').replace('{cap}', G.cap))}</p>` : ''}
    ${entityGraphSVG(G)}</div>`;
}

// The drawing. `graphLayout` and `graphLabel` are 21-notegraph.js's — the same
// seeded, fixed-tick layout — and the classes are its too, so both pictures
// read alike. A node REFOCUSES the picture on that entity; the focus itself
// has nothing to do, so it offers nothing.
function entityGraphSVG(G){
  const nodes = (G.nodes || []).map(n => ({ id: n.id, title: n.name, type: n.type, focus: n.focus }));
  const edges = G.edges || [];
  if(!nodes.length) return '';
  const deg = {};
  for(const e of edges){ deg[e.from] = (deg[e.from] || 0) + 1; deg[e.to] = (deg[e.to] || 0) + 1; }
  const laid = graphLayout(nodes, edges);
  const at = {};
  for(const p of laid) at[p.node.id] = p;
  const lines = edges.map(e => {
    const a = at[e.from], b = at[e.to];
    if(!a || !b) return '';
    return `<line x1="${a.x}" y1="${a.y}" x2="${b.x}" y2="${b.y}" class="ng-edge"><title>${esc(a.node.title + ' ' + e.predicate + ' ' + b.node.title)}</title></line>`;
  }).join('');
  const dots = laid.map(p => {
    const nd = p.node;
    const r = Math.min(13, 5 + Math.sqrt(deg[nd.id] || 0) * 2.4);
    const full = `${nd.title} (${nd.type})`;
    const dot = `<circle cx="${p.x}" cy="${p.y}" r="${r}" class="ng-node${nd.focus ? ' ng-focus' : ''}"><title>${esc(full)}</title></circle>`;
    const label = `<text x="${p.x}" y="${p.y + r + 11}" class="ng-label">${esc(graphLabel(nd.title))}</text>`;
    return nd.focus
      ? `<g class="ng-g">${dot}${label}</g>`
      : `<g class="ng-g ng-click" data-h-click="${H(() => rsGraph(nd.id))}" role="button" tabindex="0" aria-label="${esc(full)}">${dot}${label}</g>`;
  }).join('');
  return `<svg class="ng-svg" id="rssvg" viewBox="0 0 ${GRAPH_W} ${GRAPH_H}" role="img"
      aria-label="${esc(t('rs_graph').replace('{n}', (nodes.find(n => n.focus) || {}).title || ''))}">${lines}${dots}</svg>`;
}
