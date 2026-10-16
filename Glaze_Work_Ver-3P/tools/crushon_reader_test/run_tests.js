const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');
const mock = require('./mock_site');
const READER = fs.readFileSync(path.join(__dirname, '../../assets/crushon/site_reader.js'), 'utf8');

let pass = 0, fail = 0;
function ok(cond, msg, extra) {
  if (cond) { pass++; console.log('  PASS', msg); }
  else { fail++; console.log('  FAIL', msg, extra !== undefined ? JSON.stringify(extra).slice(0, 400) : ''); }
}
const ids = (r) => r.items.map(i => i.id);
const expected = (sort, date, n, nsfw = true) => mock.order(sort, date).filter(c => nsfw || !c.nsfw).slice(0, n).map(c => c.id);

(async () => {
  const server = await mock.start(4173);
  const browser = await chromium.launch();
  async function open(p, w = 430, h = 932) {
    const ctx = await browser.newContext({ viewport: { width: w, height: h }, userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1' });
    const page = await ctx.newPage();
    await page.addInitScript(READER);
    page.on('pageerror', e => console.log('  [pageerror]', e.message));
    await page.goto('http://localhost:4173' + p);
    await page.waitForTimeout(600);
    return page;
  }
  const call = (page, expr) => page.evaluate(`(async()=>{ return await ${expr}; })()`);

  console.log('A: radix-like dropdown, lazy imgs, next/image, overlay, calendar');
  let page = await open('/');
  let info = await call(page, '__gzCO.pageInfo()');
  ok(info.loggedOut === true, 'detects logged-out state', info);
  ok(info.cards >= 2, 'sees cards (sidebar anchor excluded)', info);
  let r = await call(page, '__gzCO.applySort("new")');
  ok(r.ok && r.changed, 'applySort(new) via pointerdown-only dropdown', r);
  await call(page, '__gzCO.settle("", 4000)');
  await call(page, '__gzCO.prepareFeed()');
  let snap = await call(page, '__gzCO.pump(0, 24, 20000)');
  ok(JSON.stringify(ids(snap)) === JSON.stringify(expected('new', null, 24)), 'NEW sort: first 24 match server order exactly', { got: ids(snap).slice(0, 5), want: expected('new', null, 5) });
  ok(snap.items.every(i => i.img && i.img.startsWith('https://cdn.example.test/')), 'next/image wrapper unwrapped to original art URL', snap.items[0]);
  ok(snap.items[0].raw && snap.items[0].raw.tags, 'cards enriched with captured site JSON', snap.items[0]);
  ok(snap.items[0].box && snap.items[0].fit === 'cover' && /20%/.test(snap.items[0].pos), 'measured the site\'s own image box/fit/position', snap.items[0]);
  snap = await call(page, '__gzCO.pump(24, 150, 60000)');
  const all150 = ids(snap);
  ok(all150.length === 126 || all150.length >= 120, 'infinite scroll continued to 150', all150.length);
  const full = (await call(page, '__gzCO.snapshot(0, 150)'));
  ok(JSON.stringify(ids(full)) === JSON.stringify(expected('new', null, 150).slice(0, ids(full).length)) && ids(full).length >= 150, 'NEW sort: 150 cards, same order as site, no dupes/gaps', { len: ids(full).length });
  ok(new Set(ids(full)).size === ids(full).length, 'no duplicates');

  // switch sort: Popular
  r = await call(page, '__gzCO.applySort("popular")');
  await call(page, '__gzCO.settle("", 4000)');
  await call(page, '__gzCO.prepareFeed()');
  snap = await call(page, '__gzCO.pump(0, 60, 40000)');
  ok(JSON.stringify(ids(snap)) === JSON.stringify(expected('popular', null, 60)), 'POPULAR: 60 cards exact order', ids(snap).slice(0, 4));

  // Daily ranking + date
  r = await call(page, '__gzCO.applySort("daily_ranking")');
  ok(r.ok, 'applySort(daily_ranking)', r);
  await call(page, '__gzCO.settle("", 3000)');
  let d = await call(page, '__gzCO.readDate()');
  ok(d.has && d.iso === '2026-10-11', 'reads the SITE\'s own current date (Oct 11), not today', d);
  await call(page, '__gzCO.prepareFeed()');
  snap = await call(page, '__gzCO.pump(0, 30, 30000)');
  ok(JSON.stringify(ids(snap)) === JSON.stringify(expected('daily-ranking', '2026-10-11', 30)), 'DAILY default date feed exact', ids(snap).slice(0, 3));
  r = await call(page, '__gzCO.applyDate("2026-10-12")');
  ok(r.ok === false, 'refuses a date the site does not offer (today is disabled)', r);
  await page.keyboard.press('Escape');
  await page.evaluate(() => { const c = document.getElementById('cal'); if (c) c.remove(); });
  r = await call(page, '__gzCO.applyDate("2026-10-03")');
  ok(r.ok, 'applyDate(2026-10-03) navigates calendar & clicks day', r);
  await call(page, '__gzCO.settle("", 3000)');
  d = await call(page, '__gzCO.readDate()');
  ok(d.iso === '2026-10-03', 'site now shows Oct 3', d);
  await call(page, '__gzCO.prepareFeed()');
  snap = await call(page, '__gzCO.pump(0, 30, 30000)');
  ok(JSON.stringify(ids(snap)) === JSON.stringify(expected('daily-ranking', '2026-10-03', 30)), 'DAILY Oct 3 feed exact', ids(snap).slice(0, 3));
  r = await call(page, '__gzCO.applyDate("2026-08-01")');
  ok(r.ok === false, 'refuses date before the site\'s earliest day', r);
  await page.evaluate(() => { const c = document.getElementById('cal'); if (c) c.remove(); });

  // NSFW toggle
  r = await call(page, '__gzCO.applySort("recent_hits")');
  await call(page, '__gzCO.settle("", 3000)');
  r = await call(page, '__gzCO.applyNsfw(false)');
  ok(r.ok && r.state === false, 'NSFW toggle turned off via real control', r);
  await call(page, '__gzCO.prepareFeed()');
  snap = await call(page, '__gzCO.pump(0, 30, 30000)');
  ok(JSON.stringify(ids(snap)) === JSON.stringify(expected('recent-hits', null, 30, false)), 'SFW feed exact', ids(snap).slice(0, 3));
  await page.context().close();

  console.log('A2: click-only dropdown, rapid sort switching');
  page = await open('/?click');
  for (const k of ['popular', 'new', 'trending', 'new', 'popular']) {
    r = await call(page, `__gzCO.applySort("${k}")`);
    await call(page, '__gzCO.settle("", 3000)');
  }
  await call(page, '__gzCO.prepareFeed()');
  snap = await call(page, '__gzCO.pump(0, 40, 30000)');
  ok(JSON.stringify(ids(snap)) === JSON.stringify(expected('popular', null, 40)), 'after 5 rapid switches the feed is exactly POPULAR', ids(snap).slice(0, 3));
  r = await call(page, '__gzCO.applySort("popular")');
  ok(r.ok && r.changed === false, 're-selecting the current sort is a no-op', r);
  await page.context().close();

  console.log('B: virtualized list in custom scroller, native <select>, /en/character/ links');
  page = await open('/b');
  r = await call(page, '__gzCO.applySort("new")');
  ok(r.ok, 'applySort via native <select>', r);
  await page.waitForTimeout(500);
  await call(page, '__gzCO.prepareFeed()');
  snap = await call(page, '__gzCO.pump(0, 200, 90000)');
  const got = ids(snap);
  ok(got.length >= 200, 'virtualized list: collected 200 cards', got.length);
  ok(JSON.stringify(got) === JSON.stringify(expected('new', null, got.length)), 'virtualized: order exact, no gaps/dupes', { first: got.slice(0, 3) });
  await page.context().close();

  console.log('C: no anchors at all -> network-order fallback');
  page = await open('/c');
  await call(page, '__gzCO.prepareFeed()');
  snap = await call(page, '__gzCO.pump(0, 25, 20000)');
  ok(snap.source === 'net' && snap.items.length >= 20, 'falls back to the site\'s own network order', { source: snap.source, n: snap.items.length });
  ok(JSON.stringify(ids(snap).slice(0, 20)) === JSON.stringify(expected('recent-hits', null, 20)), 'net-order matches server', ids(snap).slice(0, 3));
  await page.context().close();

  console.log('Account favorites tab + search');
  page = await open('/account');
  r = await call(page, '__gzCO.openFavorites()');
  ok(r.ok, 'found Favorites tab despite "(3)" suffix', r);
  await call(page, '__gzCO.prepareFeed()');
  snap = await call(page, '__gzCO.pump(0, 10, 5000)');
  ok(JSON.stringify(ids(snap)) === JSON.stringify(['fav-a', 'fav-b', 'fav-c']), 'favorites content read', ids(snap));
  await page.context().close();
  page = await open('/search');
  r = await call(page, '__gzCO.typeSearch("alice")');
  ok(r.ok, 'search typed + submitted', r);
  await call(page, '__gzCO.prepareFeed()');
  snap = await call(page, '__gzCO.pump(0, 10, 5000)');
  ok(ids(snap).length === 5 && ids(snap)[0] === 'alice-0', 'search results read', ids(snap));
  await page.context().close();

  await browser.close(); server.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
