import { chromium } from '@playwright/test';
const BASE = process.env.BASE || 'http://127.0.0.1:8877';
const errs = []; let pass = 0, fail = 0;
const ok = (n, c, d='') => { if (c) { console.log('  ok   ' + n); pass++; } else { console.log('  FAIL ' + n + (d?' — '+d:'')); fail++; } };

const b = await chromium.launch({ args: ['--no-sandbox','--disable-dev-shm-usage'] });
const page = await b.newPage();
page.on('pageerror', e => errs.push(String(e)));
// The browser logs "Failed to load resource" for every 4xx, and the deliberate
// empty submit below IS a 4xx — that is the app working. Uncaught exceptions and
// every other console error still count.
page.on('console', m => {
  const s = m.text();
  if (m.type() === 'error' && !/Failed to load resource/.test(s)) errs.push(s);
});

await page.goto(BASE, { waitUntil: 'networkidle' });
await page.waitForSelector('.bx-hero h1', { timeout: 20000 });

ok('funnel renders', await page.locator('.bx-hero h1').count() === 1);
ok('language switcher present', await page.locator('.bx-lang button').count() === 2);
const labels = await page.locator('.bx-lang button').allInnerTexts();
ok('offers EN and 日本語', labels.join(',') === 'EN,日本語', labels.join(','));
ok('EN is active first', (await page.locator('.bx-lang button.active').innerText()) === 'EN');
ok('English headline', (await page.locator('.bx-hero h1').innerText()).includes('Join the Telemachus beta'));

// switch to Japanese
await page.click('.bx-lang button:nth-child(2)');
await page.waitForFunction(() => {
  const h = document.querySelector('.bx-hero h1');
  return h && h.innerText.includes('ベータ版に参加する');
}, null, { timeout: 20000 });
ok('headline switched to Japanese', true);
ok('CTA localized', (await page.locator('.bx-cta').innerText()).includes('アクセスを申請'));
const lbls = await page.locator('#betaform label').allInnerTexts();
ok('field labels localized', lbls.some(l => l.includes('勤務先メールアドレス')), lbls.slice(0,3).join(' | '));
ok('details localized', (await page.locator('.bx-details').innerText()).includes('提供内容'));
ok('URL carries ?lang=ja (shareable)', page.url().includes('lang=ja'), page.url());
ok('日本語 is now the active button', (await page.locator('.bx-lang button.active').innerText()) === '日本語');
ok('sign-in link localized too', (await page.locator('.bx-signin').innerText()).includes('チームサインイン'));

// a shared link lands in its language with no clicking
const p2 = await b.newPage();
await p2.goto(BASE + '/?lang=ja', { waitUntil: 'networkidle' });
await p2.waitForSelector('.bx-hero h1', { timeout: 20000 });
ok('shared ?lang=ja link opens in Japanese',
   (await p2.locator('.bx-hero h1').innerText()).includes('ベータ版に参加する'));

// The submit path, in Japanese. Two things have to be Japanese here and they come
// from different places: the console's own chrome (t('bxverifying')) and the
// SERVER's refusal (locales/ja.json, via surface/messages.rkt). Submitting the
// empty form exercises the second — the message a real applicant is most likely
// to see, and the one that was bare English until this change.
// The anti-abuse gate refuses a challenge younger than 2s ("too fast"), and
// switching language re-rendered the page and fetched a fresh one. Without this
// wait the refusal we read back is the CHALLENGE error, not the field error —
// which is exactly how the looser version of this assertion passed while proving
// nothing about locales/ja.json.
await page.waitForTimeout(2600);
// Give it a valid email so the STRUCTURAL check passes and the config-driven one
// is what answers. `name` is required:true in the shipped experience but left
// blank here, so the refusal should name 「氏名」 — the label as rendered, not the
// key `name`.
await page.fill('#bf_email', 'probe@corp.example');
await page.click('.bx-cta');
// wait past the client-side placeholder for the SERVER's answer, or this reads
// t('bxverifying') and proves nothing about locales/ja.json
await page.waitForFunction(() => {
  const m = document.querySelector('#betamsg');
  const s = m ? m.innerText.trim() : '';
  return s.length > 0 && !/本人確認/.test(s);
}, null, { timeout: 20000 });
const msg = await page.locator('#betamsg').innerText();
ok('submit feedback is Japanese, not English', !/[A-Za-z]{4,}/.test(msg), msg);
// The shipped form marks `name` required, so an empty submit is refused by the
// CONFIG-driven check — and the refusal must name the field with the label the
// applicant actually read (「氏名」), not its key (`name`). That is the whole
// point of localizing the experience before validating it.
ok('…refusal names the localized field label', /氏名/.test(msg), msg);
ok('…and it is the required-field message', /入力してください/.test(msg), msg);

ok('no uncaught page errors', errs.length === 0, errs.slice(0,3).join(' | '));
await b.close();
console.log(`\nfunnel-ui: ${pass} passed, ${fail} failed`);
process.exit(fail);
