// #247 — THE NOTE GRAPH, drawn by hand as inline SVG (ORG-13).
//
// Not d3: `script-src 'self'` blocks a CDN, so it would be ~280 KB vendored
// into this directory, and every other picture this console has it draws by
// hand (QVIZ-2, and the queue's own bars one file along).
//
// Not RG-9's deterministic radial layout either, and that is a standing
// decision being NARROWED rather than ignored. RG-9 declined a force simulation
// for the DERIVED graph on three grounds; two of them do not survive the move
// to an authored graph of tens of nodes — the dependency (answered by not
// taking one) and the ~200 lines of physics (what follows is ~40). THE
// OBJECTION THAT SURVIVES IS NON-DETERMINISM, because this project's gates are
// its evidence and a layout no screenshot reproduces and no e2e assertion can
// pin a node in is a feature with nothing behind it.
//
// 🔑 SO THERE IS NO ANIMATION LOOP AND NO `requestAnimationFrame`. A fixed seed
// and a fixed tick count are run ONCE, synchronously, and the result is drawn
// still. That is what answers QVIZ-6 as well as the gates: #38's idle clock
// counts from the last REQUEST, and a canvas that kept ticking would hold a
// session open for as long as the tab was left open — an idle timeout switched
// off by something that looks like polish. It is also why a reader DRAGGING a
// node is not here: that is a loop, and it is LAY-12's plugin canvas.
const GRAPH_W = 760, GRAPH_H = 440, GRAPH_TICKS = 200, GRAPH_SEED = 0x5eed1e;

// mulberry32. A seeded generator rather than `Math.random`, for the one reason
// above: the jitter has to be the same jitter every time. It is used ONLY to
// break the symmetry of the starting circle — with every node placed exactly on
// a ring, equal and opposite forces leave a symmetric graph frozen in its
// starting shape, which looks like a layout that did not run.
function graphRng(seed){
  let a = seed >>> 0;
  return function(){
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Fruchterman-Reingold, cooled over a fixed number of ticks: every pair repels,
// every edge pulls, and a weak pull to the middle keeps a disconnected
// component from drifting off the canvas rather than being clamped against it.
//
// THE NODE ORDER IS THE SERVER'S AND IT IS DETERMINISTIC — created_at DESC with
// the listing's own tiebreak for the whole-team view, and a breadth-first walk
// over a SORTED frontier for a neighbourhood. That matters as much as the seed:
// a seeded layout over an arbitrary subset, or over the same subset in a
// different order, is still an arbitrary picture.
//
// Positions are ROUNDED to a tenth, so the SVG a gate reads is byte-stable
// across engines whose floating point differs in the last place.
function graphLayout(nodes, edges){
  const n = nodes.length;
  const rnd = graphRng(GRAPH_SEED);
  const ix = {};
  nodes.forEach((nd, i) => { ix[nd.id] = i; });
  const x = new Float64Array(n), y = new Float64Array(n);
  for(let i = 0; i < n; i++){
    const a = (2 * Math.PI * i) / Math.max(1, n);
    const r = Math.min(GRAPH_W, GRAPH_H) * 0.34 * (0.65 + 0.35 * rnd());
    x[i] = GRAPH_W / 2 + r * Math.cos(a);
    y[i] = GRAPH_H / 2 + r * Math.sin(a);
  }
  const E = [];
  for(const e of edges){
    const a = ix[e.from], b = ix[e.to];
    if(a != null && b != null && a !== b) E.push([a, b]);
  }
  const k = Math.max(26, Math.sqrt((GRAPH_W * GRAPH_H) / Math.max(1, n)) * 0.62);
  const dx = new Float64Array(n), dy = new Float64Array(n);
  for(let step = 0; step < GRAPH_TICKS; step++){
    const cool = 1 - step / GRAPH_TICKS;
    dx.fill(0); dy.fill(0);
    for(let i = 0; i < n; i++) for(let j = i + 1; j < n; j++){
      let ax = x[i] - x[j], ay = y[i] - y[j];
      let d2 = ax * ax + ay * ay;
      // two nodes in exactly one place have no direction to push apart along,
      // so the tie is broken by their INDEX rather than by the generator —
      // a second random draw here would depend on how many ties came before it
      if(d2 < 0.01){ ax = 0.1 + 0.01 * (i - j); ay = 0.1; d2 = ax * ax + ay * ay; }
      const d = Math.sqrt(d2), f = (k * k) / d2;
      dx[i] += (ax / d) * f; dy[i] += (ay / d) * f;
      dx[j] -= (ax / d) * f; dy[j] -= (ay / d) * f;
    }
    for(const pair of E){
      const a = pair[0], b = pair[1];
      const ax = x[a] - x[b], ay = y[a] - y[b];
      const d = Math.max(0.01, Math.sqrt(ax * ax + ay * ay)), f = (d * d) / k;
      dx[a] -= (ax / d) * f; dy[a] -= (ay / d) * f;
      dx[b] += (ax / d) * f; dy[b] += (ay / d) * f;
    }
    for(let i = 0; i < n; i++){
      dx[i] += (GRAPH_W / 2 - x[i]) * 0.02;
      dy[i] += (GRAPH_H / 2 - y[i]) * 0.02;
      const d = Math.sqrt(dx[i] * dx[i] + dy[i] * dy[i]);
      if(d > 0){
        const lim = Math.min(d, 18 * cool + 1);
        x[i] += (dx[i] / d) * lim;
        y[i] += (dy[i] / d) * lim;
      }
      x[i] = Math.max(26, Math.min(GRAPH_W - 26, x[i]));
      y[i] = Math.max(24, Math.min(GRAPH_H - 24, y[i]));
    }
  }
  return nodes.map((nd, i) => ({
    node: nd,
    x: Math.round(x[i] * 10) / 10,
    y: Math.round(y[i] * 10) / 10
  }));
}

// The query the card asks for. `?note=` is ORG-16's DEFAULT view; the whole-team
// map is behind the explicit control, because a team of five thousand notes has
// no readable whole-graph picture under any layout whatsoever (RG-9).
function graphQuery(){
  if(!S.graphNote) return '';
  return '?note=' + encodeURIComponent(S.graphNote) + '&depth=' + (S.graphDepth || 1);
}

// A LABEL IS TRUNCATED IN THE MARKUP, not with CSS. SVG has no text overflow,
// so a long title would simply run across its neighbours; the full one is in a
// `<title>`, which is also what a screen reader reads.
function graphLabel(s){
  const str = String(s || '');
  return str.length > 22 ? str.slice(0, 21) + '…' : str;
}

// 🔑 AN UNRESOLVED TARGET IS DRAWN, HOLLOW, AND ORG-9a IS WHAT MAKES THAT SAFE.
// "Four notes point at a note nobody has written" is the most useful thing this
// picture says, and it is org-roam's and Obsidian's own behaviour. Under slice
// 2's resolution an UNREADABLE target answered differently from a nonexistent
// one, so such a node would have told the reader which of a colleague's private
// notes exist. The two answers are indistinguishable now, so a phantom repeats
// only what the caller themselves typed.
//
// It is NOT clickable, because there is no note to open — a node whose click
// does nothing is worse than one that plainly offers nothing.
function noteGraphSVG(G){
  const nodes = G.nodes || [], edges = G.edges || [];
  if(!nodes.length) return `<p class="muted">${esc(t('ngraphempty'))}</p>`;
  const deg = {};
  for(const e of edges){ deg[e.from] = (deg[e.from] || 0) + 1; deg[e.to] = (deg[e.to] || 0) + 1; }
  const laid = graphLayout(nodes, edges);
  const at = {};
  for(const p of laid) at[p.node.id] = p;
  const lines = edges.map(e => {
    const a = at[e.from], b = at[e.to];
    if(!a || !b) return '';
    return `<line x1="${a.x}" y1="${a.y}" x2="${b.x}" y2="${b.y}" class="ng-edge"></line>`;
  }).join('');
  const dots = laid.map(p => {
    const nd = p.node;
    const r = Math.min(13, 5 + Math.sqrt(deg[nd.id] || 0) * 2.4);
    const cls = 'ng-node' + (nd.missing ? ' ng-missing' : '') + (nd.focus ? ' ng-focus' : '');
    const label = `<text x="${p.x}" y="${p.y + r + 11}" class="ng-label">${esc(graphLabel(nd.title))}</text>`;
    const full = nd.missing
      ? `${nd.title} — ${esc(t('ngraphmissing'))}`
      : nd.title || '(untitled)';
    const dot = `<circle cx="${p.x}" cy="${p.y}" r="${r}" class="${cls}"><title>${esc(full)}</title></circle>`;
    return nd.missing
      ? `<g class="ng-g">${dot}${label}</g>`
      : `<g class="ng-g ng-click" data-h-click="${H(() => noteShow(nd.id))}"
           role="button" tabindex="0" aria-label="${esc(full)}">${dot}${label}</g>`;
  }).join('');
  return `<svg class="ng-svg" viewBox="0 0 ${GRAPH_W} ${GRAPH_H}" role="img"
      aria-label="${esc(t('ngraph'))}: ${nodes.length}">${lines}${dots}</svg>`;
}

// What was left out, in words. ORG-16 reports BOTH ways of stopping and they
// have DIFFERENT remedies, which is the whole reason the server answers a
// closed `reason` rather than a boolean: narrow the question, ask for less
// depth, or accept that this team has no single picture. A figure with no
// remedy beside it is #178's decoration.
function graphNotes(G){
  const out = [];
  if(G.truncated){
    const key = G.reason === 'neighbourhood' ? 'ngraphnb'
              : G.reason === 'scan' ? 'ngraphscan' : 'ngraphcap';
    out.push(`<p class="muted" style="font-size:12px">${esc(t(key))}</p>`);
  }
  if(G.ambiguous > 0)
    out.push(`<p class="muted" style="font-size:12px">${
      esc(t('ngraphamb').replace('{n}', G.ambiguous))}</p>`);
  return out.join('');
}

function noteGraphCard(G, focusTitle){
  const depth = S.graphDepth || 1;
  const sel = [1, 2, 3].map(d =>
    `<option value="${d}"${d === depth ? ' selected' : ''}>${d}</option>`).join('');
  const head = S.graphNote
    ? esc(t('ngraphfocus').replace('{t}', focusTitle || ''))
    : esc(t('ngraphteam'));
  const count = esc(t('ngraphnodes')
    .replace('{n}', (G.nodes || []).length)
    .replace('{e}', (G.edges || []).length)
    .replace('{total}', G.total));
  return `<div class="card" id="ngraph"><h3 style="margin-top:0">${esc(t('ngraph'))}
      <span class="muted" style="font-size:13px">${head}</span></h3>
    <div class="row" style="gap:8px;align-items:flex-end">
      <div style="flex:0 0 auto"><button class="btn sm ghost"
        data-h-click="${H(() => graphSetFocus(null))}"
        ${S.graphNote ? '' : 'disabled'}>${esc(t('ngraphteam'))}</button></div>
      ${S.graphNote ? `<div style="flex:0 0 auto"><label>${esc(t('ngraphdepth'))}</label>
        <select data-h-change="${H(el => graphSetDepth(el.value))}">${sel}</select></div>` : ''}
      <div style="flex:1"></div>
      <div style="flex:0 0 auto"><button class="btn sm ghost"
        data-h-click="${H(() => graphClose())}">${esc(t('ngraphhide'))}</button></div>
    </div>
    <p class="muted" style="font-size:12px;margin:6px 0 0">${count}</p>
    ${graphNotes(G)}
    ${noteGraphSVG(G)}</div>`;
}

// A DEPTH CHANGE SWAPS THE CARD, NOT THE TAB (NPG-10, ORG-1's `edSetFormat`
// one more time). `renderTab()` paints a `…` placeholder and re-fires all of
// this tab's requests, and the create form's title is a plain `<input>` — so
// redrawing the graph would throw away a half-written note.
async function graphSwap(){
  await cardSwap('ngraph', async () => {
    const r = await api('/api/notes/graph' + graphQuery());
    if(!r.ok) return null;
    const focus = (r.json.nodes || []).find(n => n.focus);
    return noteGraphCard(r.json, focus ? focus.title : '');
  });
}
function graphSetDepth(v){
  const d = parseInt(v, 10);
  S.graphDepth = (d >= 1 && d <= 3) ? d : 1;
  graphSwap();
}
function graphSetFocus(id){ S.graphNote = id || null; S.graphDepth = 1; graphSwap(); }
// Opening and closing DO re-render the tab, deliberately: the card is not on
// screen in either the before or the after state, so there is nothing to swap —
// and the read itself rides the tab's own `Promise.all` round rather than
// becoming a fourth sequential await on it.
function graphOpen(id){ S.graphOpen = true; S.graphNote = id || null; S.graphDepth = 1; renderTab(); }
function graphClose(){ S.graphOpen = false; renderTab(); }
