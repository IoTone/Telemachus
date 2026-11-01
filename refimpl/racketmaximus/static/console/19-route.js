// ---- linkable URLs (#230) ----------------------------------------------------
//
// Nothing in the console was linkable: you could not send anyone a URL for a
// job, a run, a document or a filtered queue page, a reload always landed on
// Chat, and Back did nothing. `history` was touched ONCE in the whole console —
// `bxSetLang`, which keeps `?lang=` in the funnel's URL because ONB-8 decided a
// funnel is a page people are LINKED to.
//
// HASH, NOT PATHS, and the reason is server-side: `server/routes.rkt` has four
// HTML entry points (`/`, `/index.html`, `/login`, `/activate`) and NO
// catch-all, so `/jobs` would 404 rather than serve the console. Paths would
// need one, which turns every typo into the console instead of a 404 and has to
// be reconciled with `/console/*path`, `/beta/bundle/:plugin/*path` and
// `/api/x/:plugin/bundle/*path`. A fragment needs no server change at all.
//
//   #/jobs
//   #/workflows/runs/<run id>
//   #/repository/<object id>
//   #/admin/queue?status=queued&kind=infer.chat&page=3
//
// THE HASH IS A MIRROR OF STATE, and that asymmetry is the whole design:
// `navigate()` writes it FROM `S`, and a hash that DISAGREES with `S` is an
// inbound navigation — a paste, or Back. Nothing reads the URL to decide what to
// do next except those two moments, so there is no write/read loop to guard.
//
// WHAT MUST NEVER BE IN THE URL, by construction rather than by review:
// `routeFromState` reads five fields and none of them is a credential.
// `S.newToken` and `S.wkToken` hold a freshly minted API or worker token, shown
// once — and a URL is pasted into chat, logged by proxies and kept in browser
// history, which is why `/activate` already strips its token from the bar.
// Unsaved editor text is out for a different reason: a link promising content
// that was never saved is a link that lies, and `go()` already abandons an edit
// on leaving a tab (#180).

// The first write REPLACES rather than pushes, so booting the console does not
// leave an entry you have to press Back through to leave the page.
let routeInit = false;

function routeFromState(){
  const tab = S.tab || 'chat';
  if (tab === 'workflows' && S.wfRun) return '#/workflows/runs/' + encodeURIComponent(S.wfRun);
  if (tab === 'repository' && S.repoDetail) return '#/repository/' + encodeURIComponent(S.repoDetail);
  if (tab === 'admin' || tab === 'health'){
    // the queue's filter and page, which is what makes "look at page 7 of the
    // queue, filtered to queued" a thing one person can send another
    const p = new URLSearchParams(), f = S.qFilter || {};
    for (const k of ['status','kind']) if (f[k]) p.set(k, f[k]);
    const page = Math.floor((S.qOffset||0)/QPAGE) + 1;
    if (page > 1) p.set('page', String(page));
    const q = p.toString();
    return '#/' + tab + (q ? '/queue?' + q : '');
  }
  return '#/' + tab;
}

// Returns false when the hash names nothing this caller can reach — an
// unreachable tab falls back rather than painting a tab that is not in the bar,
// because `visibleTabs()` is decided by permissions and feature switches and a
// link may have come from somebody who holds more than the reader does.
function applyRoute(hash){
  const h = (hash || '').replace(/^#\/?/, '');
  if (!h) return false;
  const cut = h.indexOf('?');
  const path = cut < 0 ? h : h.slice(0, cut);
  const query = cut < 0 ? '' : h.slice(cut + 1);
  const seg = path.split('/').filter(Boolean).map(x => { try { return decodeURIComponent(x); } catch(e){ return x; } });
  const tab = seg[0];
  if (!tab || visibleTabs().indexOf(tab) < 0) return false;
  let wfRun = null, repoDetail = null, qFilter = {}, qOffset = 0;
  if (tab === 'workflows' && seg[1] === 'runs' && seg[2]) wfRun = seg[2];
  if (tab === 'repository' && seg[1]) repoDetail = seg[1];
  if ((tab === 'admin' || tab === 'health') && seg[1] === 'queue'){
    const p = new URLSearchParams(query);
    for (const k of ['status','kind']) { const v = p.get(k); if (v) qFilter[k] = v; }
    // a page number out of range is clamped by the pager itself; here it only
    // has to be a positive integer, because the total is not known yet
    const page = Math.max(1, parseInt(p.get('page') || '1', 10) || 1);
    qOffset = (page - 1) * QPAGE;
  }
  S.tab = tab; S.wfRun = wfRun; S.repoDetail = repoDetail;
  S.qFilter = qFilter; S.qOffset = qOffset;
  return true;
}

// Called from `renderTab()` — the ONE seam every view change passes through, so
// no call site had to learn about the URL. A re-render with unchanged state
// writes nothing, which is what keeps a live run's 1.5s poll from flooding the
// history with an entry per tick.
function navigate(){
  if (!S.me) return;                       // the sign-in screen has no tabs
  let want;
  try { want = routeFromState(); } catch(e){ return; }
  if (location.hash === want) return;
  try {
    if (routeInit) history.pushState(null, '', want);
    else history.replaceState(null, '', want);
    routeInit = true;
  } catch(e){}                             // a URL we cannot write is not worth failing a render over
}

async function routeChanged(){
  if (!S.me) return;
  if (location.hash === routeFromState()) return;   // our own write, or nothing moved
  if (!applyRoute(location.hash)){
    // the hash named something unreachable: put the address bar back rather than
    // leaving it describing a view that is not on screen
    routeInit = false; navigate(); return;
  }
  document.querySelectorAll('nav.tabs button').forEach(b => b.classList.toggle('active', b.dataset.tab === S.tab));
  await renderTab();
}

// BOTH events, deliberately. Back and Forward fire `popstate`; a hash typed into
// the address bar fires `hashchange`, and some engines fire both. The handler
// compares and returns early, so a duplicate costs nothing.
window.addEventListener('popstate', routeChanged);
window.addEventListener('hashchange', routeChanged);
