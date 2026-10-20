// Screenshots of the web app against the fake hub, headless Chromium, at
// desktop and phone sizes in light and dark. Run by tool/preview/shoot.sh.
//
//   node shoot.mjs <base url> <out dir> [only]
import { chromium } from 'playwright';
import fs from 'node:fs';

const [base, out, only] = process.argv.slice(2);
fs.mkdirSync(out, { recursive: true });

const desktop = { width: 1440, height: 900 };
const phone = { width: 412, height: 892 };

// name, viewport, scheme, the agent to open (by its row label), then steps:
// ['key', k] presses a key, ['type', text] types, ['wheel', x, y, dy]
// scrolls at a point, ['click', x, y], ['wait', ms].
const shots = [
  ['desktop-keys', desktop, 'light', null, [['click', 900, 700], ['key', 'j'], ['key', 'j'], ['key', 'j'], ['wait', 1200]]],
  ['desktop-search', desktop, 'dark', null, [['click', 900, 700], ['key', '/'], ['type', 'firm'], ['wait', 600]]],
  ['desktop-scrolled', desktop, 'light', 'infra/proxy', [['wheel', 900, 400, -2500], ['wait', 1500]]],
  ['desktop-send', desktop, 'dark', 'infra/backups', [['key', 'Enter'], ['type', 'Ship it: tag v0.4 and push'], ['key', 'Enter'], ['wait', 120]]],
  ['desktop-sent', desktop, 'dark', 'infra/backups', [['key', 'Enter'], ['type', 'Ship it: tag v0.4 and push'], ['key', 'Enter'], ['wait', 2500]]],
  ['desktop-dialog-keys', desktop, 'light', 'roster/app', [['key', 'Enter'], ['key', '3'], ['wait', 150]]],
  ['phone-scrolled', phone, 'light', 'infra/proxy', [['wheel', 200, 400, -1800], ['wait', 1500]]],
  ['desktop-top', desktop, 'dark', 'roster/app', [
    ['wheel', 900, 400, -8000], ['wait', 900], ['wheel', 900, 400, -8000], ['wait', 900], ['wheel', 900, 400, -8000],
    ['wait', 900], ['wheel', 900, 400, -8000], ['wait', 900], ['wheel', 900, 400, -8000], ['wait', 900],
    ['wheel', 900, 400, -8000], ['wait', 1200]]],
  ['desktop-settings', desktop, 'light', null, [['tap', 'More'], ['tap', 'Settings'], ['wait', 800]]],
  ['desktop-new-agent', desktop, 'dark', null, [['tap', 'New agent'], ['wait', 800]]],
  ['desktop-loading', desktop, 'light', 'infra', [], { settle: 1200 }],
  ['phone-pair', phone, 'dark', null, [], { paired: false }],
  ['desktop-list', desktop, 'light', null],
  ['desktop-light', desktop, 'light', 'roster/app'],
  ['desktop-dark', desktop, 'dark', 'roster/app'],
  ['desktop-dark-edit', desktop, 'dark', 'rator-firmware/ui'],
  ['desktop-light-idle', desktop, 'light', 'infra/proxy', [['click', 650, 679], ['wait', 400]]],
  ['phone-list-light', phone, 'light', null],
  ['phone-list-dark', phone, 'dark', null],
  ['phone-agent-light', phone, 'light', 'roster/app'],
  ['phone-agent-dark', phone, 'dark', 'rator-firmware/ui'],
  ['phone-agent-dark-idle', phone, 'dark', 'infra/backups'],
];

const browser = await chromium.launch();
for (const [name, viewport, colorScheme, agent, steps = [], opts = {}] of shots) {
  if (only && !name.includes(only)) continue;
  const ctx = await browser.newContext({ viewport, colorScheme, deviceScaleFactor: viewport === phone ? 2 : 1 });
  if (opts.paired !== false) await ctx.addInitScript(() => localStorage.setItem('roster.token', 'tok-preview'));
  const page = await ctx.newPage();
  page.on('console', (m) => { if (m.type() === 'error') console.log(`[${name}] console: ${m.text()}`); });
  await page.goto(base);
  await page.waitForSelector('flt-semantics-placeholder, flutter-view', { timeout: 30000 });
  await page.waitForTimeout(opts.settle ?? 2500);
  if (agent) {
    // Turn on Flutter's semantics tree, so rows can be found by their text.
    await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
    await page.waitForTimeout(500);
    // The row's button: one whose text has the agent's name on a line of its own.
    const buttons = page.locator('flt-semantics[role=button]');
    const k = await buttons.evaluateAll((els, a) =>
      els.findIndex((e) => e.textContent.split('\n').map((l) => l.trim()).some((l) => l === a || l.startsWith(a + ' '))), agent);
    if (k < 0) throw new Error(`no row for ${agent}`);
    await buttons.nth(k).click();
    await page.waitForTimeout(opts.settle ?? 2500);
  }
  for (const [what, ...args] of steps) {
    if (what === 'key') await page.keyboard.press(args[0]);
    else if (what === 'type') await page.keyboard.type(args[0], { delay: 15 });
    else if (what === 'wheel') { await page.mouse.move(args[0], args[1]); await page.mouse.wheel(0, args[2]); }
    else if (what === 'click') await page.mouse.click(args[0], args[1]);
    else if (what === 'wait') await page.waitForTimeout(args[0]);
    else if (what === 'tap') {
      // A button by its label or tooltip, through the semantics tree.
      await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
      await page.waitForTimeout(300);
      const all = page.locator('flt-semantics[role=button], flt-semantics[role=menuitem], flt-semantics[role=menuitemcheckbox]');
      const k = await all.evaluateAll((els, t) => els.findIndex((e) =>
        (e.getAttribute('aria-label') ?? '').trim() === t || e.textContent.trim() === t), args[0]);
      if (k < 0) throw new Error(`no button ${args[0]}`);
      await all.nth(k).click();
    }
    await page.waitForTimeout(150);
  }
  await page.screenshot({ path: `${out}/${name}.png` });
  console.log(`${out}/${name}.png`);
  await ctx.close();
}
await browser.close();
