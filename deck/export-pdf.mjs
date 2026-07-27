// Render deck/index.html to a 1280x720 (16:9) PDF, one slide per page.
// Usage:  npx --yes playwright@1.49.1 install chromium   (once)
//         node deck/export-pdf.mjs
// playwright is not a repo dependency; it is resolved from wherever it is installed.
// Set PLAYWRIGHT_PATH if it lives outside the default node resolution path, e.g.
//   PLAYWRIGHT_PATH=/tmp/deck-tools/node_modules/playwright node deck/export-pdf.mjs
const pw = await import(process.env.PLAYWRIGHT_PATH || 'playwright');
// playwright ships CJS; when loaded by path the named exports land on .default
const { chromium } = pw.chromium ? pw : pw.default;
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = 'file://' + join(here, 'index.html');
const out = join(here, 'arc-fx-lending-deck.pdf');

// --no-sandbox is required inside containers/devcontainers where user namespaces
// are unavailable; without it chromium.launch() hangs instead of erroring.
const browser = await chromium.launch({
  timeout: 60_000,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
});
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });

await page.goto(src, { waitUntil: 'load', timeout: 60_000 });
// Google Fonts arrive over the network; make sure they are laid out before printing.
await page.evaluate(() => document.fonts.ready);
await page.waitForTimeout(600);

await page.pdf({
  path: out,
  width: '1280px',
  height: '720px',
  printBackground: true,
  margin: { top: '0', right: '0', bottom: '0', left: '0' },
  preferCSSPageSize: false,
});

const slides = await page.locator('.slide').count();
await browser.close();
console.log(`✓ ${out}  (${slides} slides)`);
