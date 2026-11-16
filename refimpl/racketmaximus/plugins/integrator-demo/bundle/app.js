// The console stores the session token here; this screen is served from the
// same origin and its API route requires the same bearer.
const token = localStorage.getItem('tmx_token');
const auth = { Authorization: 'Bearer ' + token };

// ---- wear the instance's (or the company's) theme -------------------------
// GET /api/branding is public and carries the same theme tokens the console
// maps. Sending the bearer means a company's own theme answers on any host.
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
    document.title = (b.title ? b.title + ' — ' : '') + 'Lane ETA';
    const th = b.theme; if(!th) return;
    const s = document.documentElement.style;
    const put = (name, key) => { if(HEX.test(String(th[key]||''))) s.setProperty(name, th[key]); };
    put('--bg','bg'); put('--panel','surface'); put('--ink','ink');
    put('--muted','muted'); put('--brand','brand'); put('--brandink','brandInk');
    if(/^[0-9]{1,2}px$/.test(String(th.radius||''))) s.setProperty('--radius', th.radius);
    if(FONTS[th.fontBody]) s.setProperty('--font', FONTS[th.fontBody]);
  } catch (e) { /* unthemed is a fine fallback; never block the screen on it */ }
}
applyBrandTheme();

// ---- call this plugin's own route ----------------------------------------
document.getElementById('go').onclick = async () => {
  const lane = document.getElementById('lane').value;
  const out = document.getElementById('out');
  out.textContent = '…';
  const r = await fetch('/api/x/integrator-demo/eta?lane=' + encodeURIComponent(lane), { headers: auth });
  const j = await r.json().catch(() => ({}));
  out.textContent = r.ok ? `${j.lane}: about ${j.days} days` : (j.error || 'failed');
};
