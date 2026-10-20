// Renders web/favicon.svg into every PNG the web app and the Android
// launcher use. Run by tool/preview/icons.sh, in the Playwright image.
import { chromium } from 'playwright';
import fs from 'node:fs';

const svg = fs.readFileSync('/app/web/favicon.svg', 'utf8');
const out = [
  ['web/favicon.png', 32, false],
  ['web/icons/Icon-192.png', 192, false],
  ['web/icons/Icon-512.png', 512, false],
  // Maskable: the mark inside the safe zone, the background to the edges.
  ['web/icons/Icon-maskable-192.png', 192, true],
  ['web/icons/Icon-maskable-512.png', 512, true],
  ['android/app/src/main/res/mipmap-mdpi/ic_launcher.png', 48, false],
  ['android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72, false],
  ['android/app/src/main/res/mipmap-xhdpi/ic_launcher.png', 96, false],
  ['android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png', 144, false],
  ['android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png', 192, false],
];

const browser = await chromium.launch();
const page = await browser.newPage();
for (const [path, size, maskable] of out) {
  await page.setViewportSize({ width: size, height: size });
  const inner = maskable
    ? `<div style="width:${size}px;height:${size}px;background:#00594F;display:grid;place-items:center">
         <img src="data:image/svg+xml;base64,${Buffer.from(svg.replace('rx="15"', 'rx="0"')).toString('base64')}" style="width:${size}px;height:${size}px">
       </div>`
    : `<img src="data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}" style="width:${size}px;height:${size}px;display:block">`;
  await page.setContent(`<html><body style="margin:0;background:transparent">${inner}</body></html>`);
  await page.screenshot({ path: `/app/${path}`, omitBackground: true });
  console.log(path);
}
await browser.close();
