// render the SVG sketches to PNG for the PDF (run from test/e2e where Playwright lives):
//   node docs/book/art/render.mjs   (from the repo root; needs the e2e npm install)
import { createRequire } from 'node:module';
// Playwright is installed under refimpl/racketmaximus/test/e2e; resolve it from there
const e2e = new URL('../../../refimpl/racketmaximus/test/e2e/', import.meta.url);
const { chromium } = createRequire(e2e)('@playwright/test');
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const browser = await chromium.launch({ headless: true, args: ['--no-sandbox','--disable-dev-shm-usage'] });
for (const [name, w, h] of [['telemachus-sketch', 600, 820], ['telemachus-head', 264, 240]]) {
  const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 3 });
  const svg = fs.readFileSync(path.join(HERE, name + '.svg'), 'utf8');
  await page.setContent(`<style>html,body{margin:0;background:transparent}</style>${svg}`);
  await page.screenshot({ path: path.join(HERE, name + '.png'), omitBackground: true });
  await page.close();
}
await browser.close();
console.log('rendered');
