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
  await page.fill('#bf_job_title', 'VP Engineering');
  await page.fill('#bf_phone', '+1 415 555 0182');
  await page.fill('#bf_company', 'Northwind Robotics');
  await page.fill('#bf_company_address', '500 Terry Francois Blvd, San Francisco, CA 94158');
  await page.selectOption('#bf_team_size', '51–200');            // custom field → stored generically in attributes (no column)
  await page.fill('#bf_use_case', 'Private on-prem AI for our support + engineering teams — compliance forbids sending data to cloud LLMs.');
  await shot(page, '04-funnel-filled', 'The funnel: a prospect requests access',
    'A qualification submission — role, company, address, and phone give the LLM judge real B2B signal to weigh. Captured as a prospect, never as a user account: no password, no login, pre-sales vetting only.');
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

  // ── 5. SKIN IT: the owner brands the funnel from the console (Tier-A editor) ──
  await page.evaluate(() => { window.S.tab = 'beta'; window.betaSub('editor'); });   // single render, no race
  await page.waitForSelector('#bx-preview .bx', { timeout: 10000 });
  // reskin via the working copy + live preview (same path the on-screen controls drive),
  // including a real logo-image upload through the slice-42 asset store (asset://, local origin)
  await page.evaluate(async () => {
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="150" height="32"><rect width="32" height="32" rx="3" fill="#ffb200"/><text x="16" y="23" font-family="Georgia,serif" font-size="18" font-weight="700" text-anchor="middle" fill="#161009">W</text><text x="42" y="22" font-family="Georgia,serif" font-size="16" font-weight="700" fill="#f7f3e8">WARHAVEN</text></svg>';
    try {
      const r = await fetch('/api/beta/assets', { method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + window.S.token },
        body: JSON.stringify({ mime: 'image/svg+xml', filename: 'logo.svg', data: 'data:image/svg+xml;base64,' + btoa(svg) }) });
      const j = await r.json(); if (j.ref) window.S.exp.logoImage = j.ref;
    } catch (e) {}
    Object.assign(window.S.exp, { logo: 'WARHAVEN', eyebrow: 'Closed technical beta',
      title: 'Enlist for the closed beta', subtitle: 'Limited slots. Sign up for a chance at early access to the front.',
      cta: 'Request access', footer: '© Warhaven Studios — all rights reserved.' });
    Object.assign(window.S.exp.theme || (window.S.exp.theme = {}),
      { brand: '#ffb200', brandInk: '#161009', bg: '#0a0a0b', surface: '#16130d', ink: '#f7f3e8',
        muted: '#b6a98a', radius: '3px', fontBody: 'Serif', heroBg: 'linear-gradient(135deg,#3a2a06,#0a0a0b)' });
    window.bxPreview();
  });
  await page.waitForTimeout(300);
  await page.waitForTimeout(300);
  await shot(page, '08-onboarding-editor', 'Skin it: the console onboarding editor',
    'The owner brands the funnel from the Beta tab — logo, hero copy, theme tokens, detail blocks, form fields, and the judge prompt — with a live preview that is exactly what applicants see. Save draft, then Publish. No code, no redeploy; the same Tier-A shell, reskinned entirely from config.');
} finally {
  fs.writeFileSync(path.join(OUT, 'manifest.json'), JSON.stringify(MAN, null, 2));
  await browser.close();
}
console.log(`beta walkthrough: ${MAN.length} shots`);
