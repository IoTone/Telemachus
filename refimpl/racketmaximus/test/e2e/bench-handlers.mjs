// #185's first bullet, measured in a real browser: "H() pushes a closure on
// every render pass and nothing ever clears the array."
//
// The existing comment in 01-base.js estimates "a long session accumulates a few
// thousand — tens of kilobytes". #184's auto-refresh makes that reachable on a
// timer, so the arithmetic is worth checking rather than trusting.
import { chromium } from '@playwright/test';

const BASE = process.env.BASE_URL || 'http://127.0.0.1:8899';
const USER = process.env.U || 'bench-op';
const PASS = process.env.P || 'bench-me-9';

const b = await chromium.launch({ args: ['--no-sandbox', '--disable-dev-shm-usage'] });
const page = await b.newPage();
const errs = [];
page.on('pageerror', e => errs.push(String(e)));
await page.goto(BASE, { waitUntil: 'domcontentloaded' });
await page.waitForSelector('#lu', { timeout: 20000 });
await page.click('summary:has-text("First run")');
await page.fill('#bu', USER); await page.fill('#bp', PASS);
await page.evaluate(() => window.doBootstrap());
await page.waitForSelector('nav.tabs', { timeout: 25000 });
await page.waitForTimeout(1500);

// TWO figures, and the difference between them is the whole of #185's fix.
// `length` is the array's extent and by design never shrinks — the index IS an
// element's identity, so a swept entry becomes a HOLE rather than being spliced
// out. `live` counts the entries that still hold a closure, which is what
// retains memory. Measuring only `length` cannot see the sweep at all, which is
// how the first run of this script reported no change against a working fix.
const H = () => page.evaluate(() => (typeof HANDLERS === 'undefined' ? -1 : HANDLERS.length));
const live = () => page.evaluate(() =>
  (typeof HANDLERS === 'undefined' ? -1 : HANDLERS.reduce((n, f) => n + (typeof f === 'function' ? 1 : 0), 0)));
const bytes = () => page.evaluate(() => {
  // a rough live-heap figure; Chromium exposes it behind performance.memory
  try { return performance.memory ? performance.memory.usedJSHeapSize : -1; } catch (e) { return -1; }
});

async function goTab(tab) {
  await page.evaluate((t) => go(t), tab);
  await page.waitForTimeout(700);
}

const rows = [];
const tabs = ['chat','notes','repository','workflows','search','knowledge','usage','admin','health'];
let prev = await H();
console.log(`after sign-in: HANDLERS = ${prev}`);
for (const t of tabs) {
  const before = await H();
  await goTab(t);
  const after = await H();
  rows.push({ tab: t, added: after - before, total: after, live: await live() });
  console.log(`  ${t.padEnd(12)} +${String(after - before).padStart(4)}   length ${String(after).padStart(5)}   live ${await live()}`);
}

// the repeat cost of ONE tab, which is what an auto-refresh does
for (const t of ['health','admin']) {
  await goTab(t);
  const a = await H();
  for (let i = 0; i < 10; i++) await page.evaluate(() => renderTab());
  await page.waitForTimeout(1200);
  const z = await H();
  console.log(`\n  ${t}: 10 further render passes added ${z - a} (${((z - a) / 10).toFixed(1)} per pass)`);
  rows.push({ tab: `${t} x10 re-render`, added: z - a, total: z });
}

// THE CARDS GROW WITH ROWS, so a figure from an empty instance is the floor and
// not the number. The Workers card draws three buttons per executor and the
// Queue card has drawn a trail button per row since #184, so the per-pass cost
// is `chrome + 3·executors + 1·queue-rows` — which is what an auto-refresh
// multiplies. Measure the SLOPE rather than quoting one box's total.
async function seed(nExec, nJobs) {
  await page.evaluate(async ({ nExec, nJobs }) => {
    for (let i = 0; i < nExec; i++) {
      await api('/api/executors', { method: 'POST',
        body: { name: 'bench-' + i, mode: 'pull', model: 'm',
                capabilities: { kinds: ['infer.chat'], models: ['m'] } } });
    }
    for (let i = 0; i < nJobs; i++) {
      await api('/api/jobs', { method: 'POST', body: { kind: 'infer.chat', payload: { messages: [] } } });
    }
  }, { nExec, nJobs });
}

async function perPass(tab, n) {
  await goTab(tab);
  const a = await H();
  for (let i = 0; i < n; i++) await page.evaluate(() => renderTab());
  await page.waitForTimeout(1500);
  return ((await H()) - a) / n;
}

// What a long run actually costs: many passes, then the LIVE count. Bounded, the
// live figure settles at roughly three passes' worth however long this runs;
// unbounded it tracks `length`.
async function soak(tab, n) {
  await goTab(tab);
  for (let i = 0; i < n; i++) await page.evaluate(() => renderTab());
  await page.waitForTimeout(2000);
  const L = await H(), v = await live();
  console.log(`\n  soak: ${n} passes of ${tab} — length ${L}, live ${v} (${(100*v/L).toFixed(1)}% retained)`);
  rows.push({ tab: `soak ${tab} x${n}`, total: L, live: v });
}

console.log('\n-- the slope: per-pass cost against fleet size and queue depth --');
for (const [nE, nJ] of [[0, 0], [6, 10], [12, 30]]) {
  if (nE || nJ) await seed(nE === 0 ? 0 : (nE === 6 ? 6 : 6), nJ === 10 ? 10 : 20);
  const h = await perPass('health', 5);
  const ad = await perPass('admin', 5);
  const counts = await page.evaluate(async () => {
    const x = await api('/api/executors'); const q = await api('/api/admin/queue');
    return { execs: (x.ok ? (x.json.executors || x.json || []).length : 0),
             rows: (q.ok ? (q.json.jobs || []).length : 0) };
  });
  console.log(`  executors=${String(counts.execs).padStart(2)} queue rows=${String(counts.rows).padStart(2)}` +
              `   health ${h.toFixed(1)}/pass   admin ${ad.toFixed(1)}/pass`);
  rows.push({ tab: `slope exec=${counts.execs} rows=${counts.rows}`, health: h, admin: ad });
}

await soak('health', 120);
await soak('admin', 120);

const heap = await bytes();
console.log(`\nHANDLERS length: ${await H()}   live: ${await live()}   heap: ${heap > 0 ? (heap/1048576).toFixed(1)+' MiB' : 'n/a'}`);
console.log(`page errors: ${errs.length}${errs.length ? ' — ' + errs.join(' | ') : ''}`);
console.log('\nJSON ' + JSON.stringify(rows));
await b.close();
