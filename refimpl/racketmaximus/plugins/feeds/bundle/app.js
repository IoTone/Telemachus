const token = localStorage.getItem('tmx_token');
const auth = { Authorization: 'Bearer ' + token };
let STATUSES = ['open','claimed','done','dropped'];

// ---- wear the instance's (or the company's) theme -------------------------
const HEX = /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/;
const FONTS = { System:'ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif',
                Serif:'Georgia,Cambria,"Times New Roman",serif',
                Mono:'ui-monospace,SFMono-Regular,Menlo,monospace',
                Rounded:'ui-rounded,"SF Pro Rounded",system-ui,sans-serif' };
async function applyBrandTheme(){
  try {
    const r = await fetch('/api/branding', { headers: auth });
    if(!r.ok) return;
    const b = await r.json();
    document.title = (b.title ? b.title + ' — ' : '') + 'Feed work queue';
    const th = b.theme; if(!th) return;
    const s = document.documentElement.style;
    const put = (name, key) => { if(HEX.test(String(th[key]||''))) s.setProperty(name, th[key]); };
    put('--bg','bg'); put('--panel','surface'); put('--ink','ink');
    put('--muted','muted'); put('--brand','brand'); put('--brandink','brandInk');
    if(/^[0-9]{1,2}px$/.test(String(th.radius||''))) s.setProperty('--radius', th.radius);
    if(FONTS[th.fontBody]) s.setProperty('--font', FONTS[th.fontBody]);
  } catch (e) { /* unthemed is a fine fallback; never block the screen on it */ }
}

// The status list comes from the SERVER's own answer, so this screen cannot
// offer a status the queue does not have — the `available locales` rule.
function fillStatuses(){
  const sel = document.getElementById('status');
  if(sel.options.length) return;
  const opts = [['','actionable (open + claimed)'], ['all','all']]
                 .concat(STATUSES.map(s => [s, s]));
  for(const [v,label] of opts){
    const o = document.createElement('option'); o.value = v; o.textContent = label;
    sel.appendChild(o);
  }
}

const when = (epoch) => {
  if(epoch === null || epoch === undefined) return '—';
  const d = new Date(epoch * 1000);
  return isNaN(d) ? '—' : d.toISOString().slice(0,10);
};

async function load(){
  fillStatuses();
  const q = new URLSearchParams();
  const st = document.getElementById('status').value;
  const feed = document.getElementById('feed').value.trim();
  const skill = document.getElementById('skill').value.trim();
  if(st) q.set('status', st);
  if(feed) q.set('feed', feed);
  if(skill) q.set('skill', skill);
  const body = document.getElementById('rows');
  const summary = document.getElementById('summary');
  summary.textContent = '…';
  const r = await fetch('/api/x/feeds/queue?' + q.toString(), { headers: auth });
  const j = await r.json().catch(() => ({}));
  if(!r.ok){ summary.textContent = j.error || 'failed'; body.replaceChildren(); return; }
  if(Array.isArray(j.statuses) && j.statuses.length) STATUSES = j.statuses;
  summary.textContent = j.count + (j.count === 1 ? ' item' : ' items') + ' — ' + (j.order || '');
  document.getElementById('empty').hidden = j.count > 0;
  body.replaceChildren();
  for(const it of (j.items || [])){
    const tr = document.createElement('tr');
    const td = (fill) => { const c = document.createElement('td'); fill(c); tr.appendChild(c); return c; };
    td(c => { c.className = 'pri'; c.textContent = it.priority; });
    td(c => {
      const a = document.createElement('a');
      a.href = '/api/repo-obj/' + encodeURIComponent(it.object_id) + '/content';
      a.textContent = it.title || it.key;
      a.style.color = 'var(--ink)';
      c.appendChild(a);
      if(it.feed_slug){
        const p = document.createElement('span'); p.className = 'pill';
        p.textContent = it.feed_slug; c.appendChild(document.createTextNode(' ')); c.appendChild(p);
      }
    });
    td(c => c.textContent = when(it.due));
    td(c => {
      for(const s of (it.skills || [])){
        const p = document.createElement('span'); p.className = 'pill'; p.textContent = s;
        c.appendChild(p);
      }
      if(!(it.skills || []).length) c.textContent = '—';
    });
    td(c => c.textContent = it.status);
    td(c => {
      for(const next of STATUSES){
        if(next === it.status) continue;
        const b = document.createElement('button');
        b.className = 'ghost'; b.textContent = next; b.style.marginRight = '.3rem';
        b.onclick = async () => {
          b.disabled = true;
          await fetch('/api/x/feeds/items/' + encodeURIComponent(it.object_id) + '/status',
                      { method: 'POST',
                        headers: Object.assign({ 'Content-Type': 'application/json' }, auth),
                        body: JSON.stringify({ status: next }) });
          load();
        };
        c.appendChild(b);
      }
    });
    body.appendChild(tr);
  }
}

document.getElementById('go').onclick = load;
applyBrandTheme().then(load);
