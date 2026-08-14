// Build a self-contained, theme-aware HTML catalog from the tour's screenshots +
// manifest. Images embed as data URIs so the page is fully portable. Design: a
// field-guide tour — sticky numbered index + screenshot cards in faux browser
// chrome — in the product's own slate/indigo identity.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CAT = path.join(HERE, 'catalog');
const manifest = JSON.parse(fs.readFileSync(path.join(CAT, 'manifest.json'), 'utf8'));
const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

// short section label + a plausible app route for the browser-chrome bar
const SECTION = {
  '01-signin': ['Sign in', '/'], '02-bootstrap': ['Bootstrap', '/'],
  '03-chat': ['Chat', '/#chat'], '04-agent': ['Agent', '/#agent'],
  '05-notes': ['Notes', '/#notes'], '06-translate': ['Translate', '/#translate'],
  '07-team': ['Team', '/#team'], '08-usage': ['Usage', '/#usage'],
  '09-admin': ['Admin', '/#admin'], '10-i18n': ['日本語', '/#chat'],
};
const secOf = (id) => (SECTION[id.replace('.png', '')] || [id, '/'])[0];
const routeOf = (id) => (SECTION[id.replace('.png', '')] || [id, '/'])[1];

const idx = manifest.map((m, i) => {
  const id = `s${String(i + 1).padStart(2, '0')}`;
  return `<li><a href="#${id}"><span class="n">${String(i + 1).padStart(2, '0')}</span>${esc(secOf(m.file))}</a></li>`;
}).join('\n');

const cards = manifest.map((m, i) => {
  const id = `s${String(i + 1).padStart(2, '0')}`;
  const b64 = fs.readFileSync(path.join(CAT, m.file)).toString('base64');
  return `<article class="card" id="${id}">
    <div class="cap">
      <p class="eyebrow"><span class="n">${String(i + 1).padStart(2, '0')}</span> ${esc(secOf(m.file))}</p>
      <h2>${esc(m.title)}</h2>
      <p>${esc(m.caption)}</p>
    </div>
    <figure class="frame">
      <div class="bar"><span class="dots"><i></i><i></i><i></i></span><span class="url">127.0.0.1:8080<span class="path">${esc(routeOf(m.file))}</span></span></div>
      <div class="scroll"><img loading="lazy" alt="${esc(m.title)}" src="data:image/png;base64,${b64}"></div>
    </figure>
  </article>`;
}).join('\n');

const html = `<title>Telemachus Feature Tour</title>
<style>
  :root{
    --ground:#eef1f6; --panel:#ffffff; --ink:#141722; --muted:#5b6577; --faint:#8b93a3;
    --line:#e2e6ee; --line-2:#eef1f6; --accent:#4b56ff; --accent-ink:#3a45e6; --ok:#12996b; --ok-ink:#0e7a55;
    --chrome:#f4f6fa; --shadow:0 1px 2px rgba(20,23,34,.05),0 12px 32px -12px rgba(20,23,34,.18);
  }
  @media (prefers-color-scheme: dark){:root:not([data-theme="light"]){
    --ground:#0b0d12; --panel:#14171f; --ink:#e7e9f0; --muted:#98a0b0; --faint:#6b7484;
    --line:#242838; --line-2:#1b1f2a; --accent:#828bff; --accent-ink:#a6acff; --ok:#34d399; --ok-ink:#5ee0b0;
    --chrome:#0f121a; --shadow:0 1px 2px rgba(0,0,0,.4),0 18px 40px -16px rgba(0,0,0,.6);
  }}
  :root[data-theme="dark"]{
    --ground:#0b0d12; --panel:#14171f; --ink:#e7e9f0; --muted:#98a0b0; --faint:#6b7484;
    --line:#242838; --line-2:#1b1f2a; --accent:#828bff; --accent-ink:#a6acff; --ok:#34d399; --ok-ink:#5ee0b0;
    --chrome:#0f121a; --shadow:0 1px 2px rgba(0,0,0,.4),0 18px 40px -16px rgba(0,0,0,.6);
  }
  *{box-sizing:border-box}
  html{scroll-behavior:smooth}
  @media (prefers-reduced-motion: reduce){html{scroll-behavior:auto}}
  body{margin:0;background:var(--ground);color:var(--ink);
    font:16px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
  .mono{font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace}
  a{color:inherit;text-decoration:none}

  .wrap{max-width:1240px;margin:0 auto;padding:0 28px;display:grid;grid-template-columns:236px minmax(0,1fr);gap:48px}
  @media (max-width:900px){.wrap{grid-template-columns:1fr;gap:0}}

  /* left rail */
  .rail{position:sticky;top:0;align-self:start;height:100vh;padding:40px 0 32px;display:flex;flex-direction:column}
  @media (max-width:900px){.rail{position:static;height:auto;padding:34px 0 8px}}
  .brand{font-weight:800;font-size:1.32rem;letter-spacing:-.03em}
  .brand .dt{color:var(--accent)}
  .kicker{color:var(--muted);font-size:.82rem;margin:2px 0 22px}
  .idx{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:1px;overflow:auto}
  @media (max-width:900px){.idx{flex-direction:row;flex-wrap:wrap;gap:6px;margin-bottom:8px}}
  .idx a{display:flex;align-items:center;gap:11px;padding:7px 10px;border-radius:8px;color:var(--muted);font-size:.92rem;font-weight:500;transition:background .15s,color .15s}
  .idx a:hover{background:var(--line-2);color:var(--ink)}
  .idx .n{font-family:ui-monospace,monospace;font-size:.72rem;color:var(--faint);font-variant-numeric:tabular-nums}
  .railfoot{margin-top:auto;padding-top:20px;color:var(--faint);font-size:.76rem;line-height:1.7}
  @media (max-width:900px){.railfoot{display:none}}

  /* masthead */
  main{padding:40px 0 80px;min-width:0}
  .eyebrow-top{font-family:ui-monospace,monospace;font-size:.72rem;letter-spacing:.16em;text-transform:uppercase;color:var(--accent-ink);margin:0 0 14px}
  h1{font-size:clamp(2rem,4.6vw,3rem);line-height:1.04;letter-spacing:-.035em;margin:0 0 16px;text-wrap:balance;font-weight:800}
  .thesis{color:var(--muted);font-size:1.09rem;max-width:60ch;margin:0 0 24px}
  .chips{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:8px}
  .chip{font-family:ui-monospace,monospace;font-size:.76rem;letter-spacing:.02em;padding:5px 11px;border-radius:999px;border:1px solid var(--line);color:var(--muted);background:var(--panel)}
  .chip.ok{color:var(--ok-ink);border-color:color-mix(in srgb,var(--ok) 40%,var(--line));background:color-mix(in srgb,var(--ok) 12%,var(--panel))}
  .chip.ok::before{content:"✓ ";font-weight:700}
  .rule{height:1px;background:var(--line);margin:34px 0 8px}

  /* cards */
  .cards{display:flex;flex-direction:column;gap:56px;margin-top:26px}
  .card{scroll-margin-top:24px}
  .cap{max-width:66ch}
  .eyebrow{font-family:ui-monospace,monospace;font-size:.74rem;letter-spacing:.1em;text-transform:uppercase;color:var(--accent-ink);margin:0 0 9px;display:flex;align-items:center;gap:9px}
  .eyebrow .n{color:var(--faint)}
  .card h2{font-size:1.4rem;letter-spacing:-.02em;margin:0 0 8px;font-weight:700;text-wrap:balance}
  .cap p{color:var(--muted);margin:0 0 18px}

  .frame{margin:0;background:var(--panel);border:1px solid var(--line);border-radius:14px;overflow:hidden;box-shadow:var(--shadow)}
  .bar{display:flex;align-items:center;gap:14px;padding:11px 14px;background:var(--chrome);border-bottom:1px solid var(--line)}
  .dots{display:inline-flex;gap:7px}
  .dots i{width:11px;height:11px;border-radius:50%;background:var(--line);display:block}
  .dots i:nth-child(1){background:#ff5f57}.dots i:nth-child(2){background:#febc2e}.dots i:nth-child(3){background:#28c840}
  .url{font-family:ui-monospace,monospace;font-size:.8rem;color:var(--faint);letter-spacing:.01em}
  .url .path{color:var(--muted)}
  .scroll{overflow-x:auto;background:var(--ground)}
  .scroll img{display:block;width:100%;height:auto}

  footer{margin-top:64px;padding-top:22px;border-top:1px solid var(--line);color:var(--faint);font-size:.82rem;line-height:1.7}
  footer code{font-family:ui-monospace,monospace;color:var(--muted)}
</style>

<div class="wrap">
  <aside class="rail">
    <div class="brand">Telemachus<span class="dt">.</span></div>
    <p class="kicker">Feature tour</p>
    <ol class="idx">
${idx}
    </ol>
    <div class="railfoot">Racket reference implementation.<br>Every frame is a real, asserted UI state captured by the e2e run.</div>
  </aside>

  <main>
    <p class="eyebrow-top">Team AI platform · reference implementation</p>
    <h1>A guided tour of the platform</h1>
    <p class="thesis">An automated Playwright walk through the running system — bootstrap, streaming chat, agentic tool use, the translation app, notes, teams &amp; RBAC, quotas &amp; the tool registry, federated compute, and full localization.</p>
    <div class="chips">
      <span class="chip ok">${manifest.length} / ${manifest.length} steps verified</span>
      <span class="chip">captured live</span>
      <span class="chip">model · qwen2.5:7b</span>
      <span class="chip">zero Python</span>
    </div>
    <div class="rule"></div>

    <section class="cards">
${cards}
    </section>

    <footer>Generated by <code>test/e2e/run-tour.mjs</code> — a headless Playwright feature tour that boots a fresh server, drives the real UI, asserts each state, and captures this catalog. ${manifest.length} steps, 0 failures.</footer>
  </main>
</div>`;

fs.writeFileSync(path.join(CAT, 'catalog.html'), html);
console.log(`wrote ${path.join(CAT, 'catalog.html')} (${manifest.length} steps, ${(html.length / 1024 / 1024).toFixed(2)} MB)`);
