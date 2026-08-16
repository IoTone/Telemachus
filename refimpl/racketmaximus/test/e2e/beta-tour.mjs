// Beta funnel walkthrough — captures the operator SETUP, the public FUNNEL, and the
// LLM-judge REVIEW, against a running beta-mode server (fresh temp DB). Setup runs
// first because the funnel needs the internal team to exist before it accepts leads.
// Shots + captions land in catalog/beta/.  BASE_URL defaults to 127.0.0.1:8080.
import { chromium } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(HERE, 'catalog', 'beta');
fs.mkdirSync(OUT, { recursive: true });
const BASE = process.env.BASE_URL || 'http://127.0.0.1:8080';
const MAN = [];
async function shot(page, id, title, caption) {
  await page.waitForTimeout(350);
  await page.screenshot({ path: path.join(OUT, `${id}.png`), fullPage: true });
  MAN.push({ file: `${id}.png`, title, caption });
  console.log('shot', id);
}

const browser = await chromium.launch({ headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
const page = await browser.newPage({ viewport: { width: 1100, height: 950 } });
try {
  // ── 1. The default experience is the funnel (home routing) ──────────────────
  await page.goto(BASE + '/', { waitUntil: 'networkidle', timeout: 20000 });
  await page.waitForSelector('#bf_name', { timeout: 15000 });
  await shot(page, '01-funnel-landing', 'The funnel is the default experience',
    'With home routing set to beta (TELEMACHUS_HOME=beta), the root route serves the public beta landing — not a login screen. The form is rendered from a pluggable onboarding provider whose copy, fields, and judge prompt are customizable via the SDK.');

  // ── 2. SETUP: staff sign-in → create the operator (and the internal team) ────
  await page.click('a:has-text("Team sign-in")');
  await page.waitForSelector('#lu', { timeout: 10000 });
  await page.click('summary:has-text("First run")');
  await page.fill('#bu', 'alice');
  await page.fill('#bp', 's3cret');
  await shot(page, '02-first-run', 'Setup: create the operator',
    'Staff reach the team behind the funnel via "Team sign-in". On a fresh instance the first run bootstraps the operator/owner (RBAC-5) — the person who will vet inbound prospects — and creates the internal team that owns the pipeline.');
  await page.evaluate(() => window.doBootstrap());
  await page.waitForSelector('nav.tabs', { timeout: 15000 });
  await page.evaluate(() => window.go('beta'));
  await page.waitForTimeout(500);
  await shot(page, '03-review-empty', 'Setup: the review inbox',
    'The owner-only Beta tab is where prospects arrive. Empty to start — no signups yet.');

  // ── 3. THE FUNNEL: a prospect requests access (log out → public view) ────────
  await page.evaluate(() => window.logout());
  await page.waitForSelector('#bf_name', { timeout: 10000 });
  await page.fill('#bf_name', 'Priya Rao');
  await page.fill('#bf_email', 'priya@northwind-robotics.com');
  await page.fill('#bf_company', 'Northwind Robotics');
  await page.fill('#bf_use_case', 'Private on-prem AI for our support + engineering teams — compliance forbids sending data to cloud LLMs.');
  await shot(page, '04-funnel-filled', 'The funnel: a prospect requests access',
    'A qualification submission — captured as a prospect, never as a user account. No password, no login: pre-sales vetting only.');
  await page.waitForTimeout(2600);                                  // min fill-time gate
  await page.click('button:has-text("Request access")');           // browser solves the proof-of-work, then submits
  await page.waitForSelector('#betamsg:has-text("review")', { timeout: 20000 });
  await shot(page, '05-funnel-submitted', 'Submitted — after invisible anti-abuse',
    'On submit the browser transparently solves a proof-of-work and passes the anti-abuse gate (rate limit, signed single-use challenge, honeypot, min fill-time, velocity caps). The prospect just sees a thank-you.');

  // a couple of bot attempts, to populate the owner\'s blocked counters
  await page.evaluate(async () => {
    const post = (b) => fetch('/api/beta/signup', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(b) });
    await post({ name: 'Bot', email: 'bot@spam.xyz' });            // no challenge → rejected, nothing stored
    await post({ name: 'Bot2', email: 'b2@spam.xyz', _hp: 'x' });  // honeypot → silent drop
  });

  // ── 4. REVIEW: owner signs back in; the LLM judge has vetted the prospect ────
  await page.click('a:has-text("Team sign-in")');
  await page.waitForSelector('#lu', { timeout: 10000 });
  await page.fill('#lu', 'alice');
  await page.fill('#lp', 's3cret');
  await page.evaluate(() => window.doLogin());
  await page.waitForSelector('nav.tabs', { timeout: 15000 });
  let judged = false;
  for (let i = 0; i < 120 && !judged; i++) {
    await page.evaluate(() => window.go('beta'));
    await page.waitForTimeout(1000);
    if ((await page.textContent('body')).includes('/100')) judged = true;   // verdict "NN/100" rendered
  }
  await shot(page, '06-owner-review', 'Review: prospects + the LLM judge',
    'The Beta tab lists each prospect with the LLM judge’s verdict (valid? · score/100 · revenue estimate · reasoning) and a count of blocked abusive attempts. The judge ran async through the metered job queue.');

  const q = page.locator('button:has-text("Qualify")').first();
  if (await q.count()) { await q.click(); await page.waitForTimeout(600); await page.evaluate(() => window.go('beta')); await page.waitForTimeout(600); }
  await shot(page, '07-qualified', 'Qualify or reject — vetting only',
    'The owner qualifies (or rejects) each prospect. This vets beta candidates for the internal team; it never provisions a customer account.');
} finally {
  fs.writeFileSync(path.join(OUT, 'manifest.json'), JSON.stringify(MAN, null, 2));
  await browser.close();
}
console.log(`beta walkthrough: ${MAN.length} shots`);
