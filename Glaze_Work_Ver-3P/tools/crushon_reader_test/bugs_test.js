// Regression tests for the three reported problems (v25):
//   1. Glaze opened Reddit while browsing  -> the reader must never click/navigate to off-site links
//   2. Info tab showed "404 Page Not Found" -> never capture a 404 page; read the real description
//   3. Favorites ignored Latest / Popular   -> drive the profile's own sort dropdown, safely
//
// Usage: node bugs_test.js [path/to/site_reader.js]   (defaults to the shipped reader)
const fs = require('fs');
const path = require('path');
const http = require('http');
const { chromium } = require('playwright');
const READER = fs.readFileSync(process.argv[2] || path.join(__dirname, '../../assets/crushon/site_reader.js'), 'utf8');

let pass = 0, fail = 0;
function ok(cond, msg, extra) {
  if (cond) { pass++; console.log('  PASS', msg); }
  else { fail++; console.log('  FAIL', msg, extra !== undefined ? JSON.stringify(extra).slice(0, 500) : ''); }
}

const ID = '3d54820b-374c-44d2-a0c0-f10435d21b96';
const DESC = `[Sandbox] [Angst / Tragedy Porn] [Slowburn] [ Slice of Life]
Five years ago, you disappeared. Now, you're back.
Senior year was supposed to be simple: survive the exams, graduate, and figure out what the hell to do with the rest of your life.`;

// Server-rendered details page, structured like the real one (see the fetched page text):
// Supporters, Creation Info + Start Chat, "Introduction" + tag headings + description, Comments, Public Memories.
const DETAILS = `<!doctype html><html><head><title>Granitwalls - The Last First DAy - NSFW Character AI Chat - any pov</title>
<meta name="keywords" content="Granitwalls - The Last First DAy,any-pov,dead-dove,enemies-to-lovers,multiple,oc,smut,story,tomboy,female,NSFW AI,NSFW AI CHAT">
</head><body><div class="app"><aside><a href="/">Home</a><a href="/search">Search</a></aside><main>
<section><h2>Supporters</h2><p>Be the first Supporter!</p><button>Support Character</button></section>
<section><h2>Creation Info</h2><a href="/profile/bc02dd58?from=DETAIL">View Profile</a><h1>Granitwalls - The Last First DAy</h1>
<div>4.7K Messages</div><a href="/character/${ID}/chat?from=DETAIL"><button>Start Chat</button></a></section>
<section><div>Introduction</div>
<div class="chips"><h2>Unfiltered</h2><h2>Any Pov</h2><h2>Dead dove</h2><h2>Enemies to lovers</h2><h2>Multiple</h2><h2>OC</h2><h2>Smut</h2><h2>Story</h2><h2>Tomboy</h2><h2>Female</h2></div>
<div class="desc">${DESC.split('\n').map(l => '<p>' + l.replace(/</g, '&lt;') + '</p>').join('')}
<div style="text-align:center"><h2 style="color:#ff5c78">Comments</h2><p>(a section title inside the creator's own styled text)</p><img alt="art" src="https://img.cocdn.co/_image/optimize/https://cdn.crushon.ai/images/x/art.png?q=75&w=1200"></div>
<p>Final line of the description.</p></div></section>
<section><h2>Comments</h2><span>All 0</span><p>Come be the first to leave a comment!</p></section>
<section><h2>Public Memories</h2><span>All 0</span><p>Come to be the first to share your interesting memory!</p></section>
</main></div></body></html>`;

const NOT_FOUND = `<!doctype html><html><head><title>CrushOn AI</title></head><body><div class="app"><aside><a href="/">Home</a></aside><main>
<div style="text-align:center"><img alt="404 Page Not Found" src="data:image/gif;base64,R0lGODlhAQABAAAAACw="><p>Sorry, I can't find the page. Please go back to the previous page.</p></div></main></div></body></html>`;

// Profile page like the screenshots: header with "Following" stat, a row of 6 icon tabs + GIF button,
// a footer/sidebar row of SOCIAL icons (external links), chips, "Latest" sort dropdown, cards.
const FAVS = [
  { id: '00000000-0000-4000-8000-000000000001', name: 'Alpha', pop: 5, date: 1 },
  { id: '00000000-0000-4000-8000-000000000002', name: 'Bravo', pop: 50, date: 3 },
  { id: '00000000-0000-4000-8000-000000000003', name: 'Charlie', pop: 20, date: 2 },
];
const PROFILE = (withTabs = true) => `<!doctype html><html><head><title>Profile</title></head><body style="font:14px sans-serif;margin:0">
<div id=head style="display:flex;gap:20px;padding:10px"><div><b>0</b><br>Followers</div><div id=following><b>0</b><br>Following</div><div><b>2</b><br>Interactions</div></div>
${withTabs ? `<div id=tabs style="display:flex;gap:20px;margin:20px">${[0, 1, 2, 3, 4, 5].map(i => `<button class=t data-i=${i} style="width:40px;height:40px"><svg width=24 height=24></svg></button>`).join('')}<div style="width:50px;height:40px;margin-left:80px"><svg width=24 height=24></svg></div></div>` : ''}
<div id=chips style="display:flex;gap:10px;min-height:30px"></div>
<div id=sortwrap style="margin:10px;position:relative"><button id=sortbtn style="width:140px;height:40px">Latest</button>
  <div id=menu style="display:none;position:absolute;top:44px;left:0;background:#222;color:#fff;width:140px"><div class=opt data-k=new style="padding:8px">Latest</div><div class=opt data-k=popular style="padding:8px">Popular</div></div></div>
<div id=out style="margin-top:10px"></div>
<footer id=social style="display:flex;gap:20px;margin:400px 20px 20px">
  <a href="https://discord.gg/xyz" target=_blank style="width:40px;height:40px;display:block"><svg width=24 height=24></svg></a>
  <a id=reddit href="https://www.reddit.com/r/CrushOn/" target=_blank style="width:40px;height:40px;display:block"><svg width=24 height=24></svg></a>
  <a href="https://x.com/crushon" target=_blank style="width:40px;height:40px;display:block"><svg width=24 height=24></svg></a>
  <a href="https://t.me/crushon" target=_blank style="width:40px;height:40px;display:block"><svg width=24 height=24></svg></a>
  <a href="https://instagram.com/crushon" target=_blank style="width:40px;height:40px;display:block"><svg width=24 height=24></svg></a></footer>
<script>
window.__clicks=[];
document.addEventListener('click',e=>{window.__clicks.push((e.target.closest('[id],[data-i]')||e.target).id||e.target.tagName)},true);
const FAVS=${JSON.stringify(FAVS)}; let tab=0, sort='new';
document.querySelectorAll('.t').forEach(t=>t.onclick=()=>{tab=+t.dataset.i;draw()});
document.getElementById('sortbtn').onclick=()=>{const m=document.getElementById('menu');m.style.display=m.style.display==='none'?'block':'none'};
document.querySelectorAll('.opt').forEach(o=>o.onclick=()=>{sort=o.dataset.k;document.getElementById('sortbtn').textContent=o.textContent;document.getElementById('menu').style.display='none';draw()});
function draw(){const c=document.getElementById('chips'),o=document.getElementById('out');
 c.innerHTML=tab===3?'<span>Characters</span><span>World Cards</span><span>Memories</span><span>Models</span><span>Folders</span>':'<span>All 1</span><span>Target</span><span>Public</span>';
 const list=tab===3?FAVS.slice().sort((a,b)=>sort==='popular'?b.pop-a.pop:b.date-a.date):[{id:'aaaaaaaa-0000-4000-8000-000000000000',name:'Lily'}];
 o.innerHTML=list.map(x=>'<a href="/character/'+x.id+'"><img alt="'+x.name+'" src="data:image/gif;base64,R0lGODlhAQABAAAAACw="><h3>'+x.name+'</h3></a>').join('');}
${withTabs ? 'draw();' : "document.getElementById('chips').innerHTML='<span>All</span>';"}
</script></body></html>`;

const requests = [];
function startServer(port) {
  return new Promise(res => {
    const srv = http.createServer((req, rsp) => {
      const u = req.url.split('?')[0];
      rsp.setHeader('content-type', 'text/html; charset=utf-8');
      if (u === `/character/${ID}/details`) return rsp.end(DETAILS);
      if (u === `/character/${ID}`) { rsp.statusCode = 404; return rsp.end(NOT_FOUND); }
      if (u === '/profile') return rsp.end(PROFILE(true));
      if (u === '/social-only') return rsp.end(PROFILE(false));
      if (u === '/shell') return rsp.end('<!doctype html><title>CrushOn</title><body><div id=root></div></body>');
      rsp.statusCode = 404; rsp.end(NOT_FOUND);
    }).listen(port, () => res(srv));
  });
}

(async () => {
  const srv = await startServer(4180);
  const browser = await chromium.launch();
  async function open(p) {
    const ctx = await browser.newContext({ viewport: { width: 430, height: 900 } });
    await ctx.route(/^https?:\/\/(?!localhost)/, route => { requests.push(route.request().url()); route.abort(); });
    const page = await ctx.newPage();
    const nav = [];
    page.on('framenavigated', f => { if (f === page.mainFrame()) nav.push(f.url()); });
    page.on('popup', pp => nav.push('POPUP:' + pp.url()));
    await page.addInitScript(READER);
    page.on('pageerror', e => console.log('  [pageerror]', e.message));
    await page.goto('http://localhost:4180' + p);
    await page.waitForTimeout(400);
    page.__nav = nav;
    return page;
  }
  const call = (page, expr) => page.evaluate(`(async()=>JSON.stringify(await ${expr}))()`).then(JSON.parse);

  // ---------------------------------------------------------------- 1. Reddit
  console.log('1. Never leave crushon.ai (Reddit)');
  let page = await open('/social-only');
  let r = await call(page, '__gzCO.openFavorites()');
  ok(r.ok === false, 'a row of social icons is NOT mistaken for the profile tabs', r);
  ok(!requests.some(u => /reddit|discord|x\.com|t\.me|instagram/.test(u)), 'no request went to Reddit/Discord/X/Telegram/Instagram', requests);
  ok(page.__nav.every(u => u.startsWith('http://localhost')) , 'main frame never left the site', page.__nav);
  let clicked = await page.evaluate('window.__clicks');
  ok(!clicked.includes('reddit'), 'the Reddit link was never clicked', clicked);

  page = await open('/profile');
  const rc = await page.evaluate(`(function(){ var a=document.getElementById('reddit'); var r=__gzCO; a.click(); a.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true})); return 'done'; })()`);
  await page.waitForTimeout(400);
  ok(page.__nav.every(u => u.startsWith('http://localhost')) && !page.__nav.some(u => u.startsWith('POPUP')), 'even a direct a.click() / synthetic click on the Reddit link is swallowed', page.__nav);
  ok(!requests.some(u => /reddit/.test(u)), 'still no request to Reddit', requests);
  const ext = await page.evaluate(`[__gzCO.isExternalHref('https://www.reddit.com/r/x'), __gzCO.isExternalHref('reddit://r/x'), __gzCO.isExternalHref('/character/1'), __gzCO.isExternalHref('https://crushon.ai/en/x'), __gzCO.isExternalHref('https://cdn.crushon.ai/a.png'), __gzCO.isExternalHref('mailto:a@b.c')]`);
  ok(JSON.stringify(ext) === JSON.stringify([true, true, false, false, false, true]), 'isExternalHref classification', ext);

  // ---------------------------------------------------------------- 2. Favorites + sort
  console.log('2. Favorites: star tab, scroll to the list, Latest / Popular');
  page = await open('/profile');
  r = await call(page, '__gzCO.openFavorites()');
  ok(r.ok === true, 'star tab opened with social row present', r);
  let names = await page.$$eval('#out h3', a => a.map(x => x.textContent));
  ok(names.length === 3 && !names.includes('Lily'), 'favorites shown (not the first tab\'s own character)', names);
  const scrolled = await page.evaluate(`(function(){ var h=document.querySelector('#out a'); var r=h.getBoundingClientRect(); return r.top>=0 && r.top < innerHeight; })()`);
  ok(scrolled, 'first favourite card is scrolled into view');
  let cur = await call(page, '__gzCO.currentFavoritesSort()');
  ok(cur.key === 'new', 'reads the current sort (Latest)', cur);
  r = await call(page, '__gzCO.applyFavoritesSort("popular")');
  names = await page.$$eval('#out h3', a => a.map(x => x.textContent));
  ok(r.ok && JSON.stringify(names) === JSON.stringify(['Bravo', 'Charlie', 'Alpha']), 'Popular reorders favourites by popularity', { r, names });
  r = await call(page, '__gzCO.applyFavoritesSort("new")');
  names = await page.$$eval('#out h3', a => a.map(x => x.textContent));
  ok(r.ok && JSON.stringify(names) === JSON.stringify(['Bravo', 'Charlie', 'Alpha'].sort((a, b) => FAVS.find(f => f.name === b).date - FAVS.find(f => f.name === a).date)), 'Latest reorders favourites newest first', { r, names });
  r = await call(page, '__gzCO.applyFavoritesSort("new")');
  ok(r.ok && r.changed === false, 'asking for the sort already shown is a no-op', r);
  clicked = await page.evaluate('window.__clicks');
  ok(!clicked.includes('following'), 'the "Following" stat was never clicked as if it were the sort', clicked);
  ok(page.__nav.every(u => u.startsWith('http://localhost')), 'no navigation away during favourites', page.__nav);

  // ---------------------------------------------------------------- 3. Description
  console.log('3. Description: 404 never captured; real description read');
  page = await open('/character/' + ID);
  ok((await call(page, '__gzCO.pageInfo()')).notFound === true, 'pageInfo.notFound true on the 404 route');
  r = await call(page, `__gzCO.captureInfo(${JSON.stringify(ID)})`);
  ok(r.ok === false && r.reason === 'not-found', 'captureInfo refuses a 404 page (no more heart + "404 Page Not Found")', r);

  page = await open('/character/' + ID + '/details');
  ok((await call(page, '__gzCO.pageInfo()')).notFound === false, 'pageInfo.notFound false on the real page');
  r = await call(page, `__gzCO.captureInfo(${JSON.stringify(ID)})`);
  ok(r.ok === true && r.source === 'live-intro', 'description captured from the live page', { ok: r.ok, source: r.source, reason: r.reason });
  const T = (r.text || '');
  ok(/Five years ago, you disappeared/.test(T) && /Final line of the description/.test(T), 'description text is the real description', T.slice(0, 200));
  ok(!/Unfiltered|Any Pov|Tomboy|Public Memories|Come be the first|Start Chat|Supporters|Introduction/.test(T.replace(/\(a section title[^)]*\)/, '')), 'no tag chips / comments / memories / buttons leaked in', T);
  ok(/color:\s*#ff5c78|color: rgb\(255, 92, 120\)/i.test(r.html) && /\(a section title inside/.test(T), 'a "Comments" title INSIDE the creator\'s styled text does not cut the description short');
  ok(r.images && r.images[0] === 'https://cdn.crushon.ai/images/x/art.png', 'picture URL unwrapped from img.cocdn.co/_image/optimize/…', r.images);
  ok(!/<script|onclick/.test(r.html), 'html is sanitised');

  page = await open('/shell');
  r = await call(page, `__gzCO.captureInfo(${JSON.stringify(ID)})`);
  ok(r.ok === true && r.source === 'server-html' && /Five years ago/.test(r.text), 'falls back to the details page\'s server HTML when the live page has nothing', { ok: r.ok, source: r.source, reason: r.reason });

  await browser.close();
  srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
