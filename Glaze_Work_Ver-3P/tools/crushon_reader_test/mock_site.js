// Mock "CrushOn-like" site used ONLY to test assets/crushon/site_reader.js.
// Variants exercise the awkward front-end behaviours the real site may have.
const http = require('http');
const url = require('url');

const TODAY = new Date('2026-10-12T12:00:00Z');
function seeded(i) { const x = Math.sin(i * 9301 + 49297) * 233280; return x - Math.floor(x); }
const N = 600;
const CHARS = Array.from({ length: N }, (_, i) => ({
  id: 'c' + String(i).padStart(4, '0'),
  name: 'Character ' + i,
  avatar: 'https://cdn.example.test/art/c' + i + '.webp',
  introduction: 'Intro of ' + i,
  tags: [{ id: i % 7, name: ['Fantasy', 'Anime', 'Romance', 'Horror', 'Comedy', 'Villain', 'Cute'][i % 7] }],
  nsfw: i % 5 === 0,
  chatCount: Math.floor(seeded(i) * 100000),
  created: i,                        // higher = newer
  hits: Math.floor(seeded(i + 1000) * 5000),
}));
function order(sort, date) {
  const a = CHARS.slice();
  if (sort === 'popular') a.sort((x, y) => y.chatCount - x.chatCount);
  else if (sort === 'recent-hits') a.sort((x, y) => y.hits - x.hits);
  else if (sort === 'trending') a.sort((x, y) => (y.hits + y.chatCount / 7) - (x.hits + x.chatCount / 7));
  else if (sort === 'new') a.sort((x, y) => y.created - x.created);
  else if (sort === 'daily-ranking') {
    const d = Number(String(date || '2026-10-11').replace(/-/g, ''));
    a.sort((x, y) => ((x.created * 31 + d) % 997) - ((y.created * 31 + d) % 997));
  } else if (sort === 'editor-choice') a.sort((x, y) => (x.created % 13) - (y.created % 13) || x.created - y.created);
  return a;
}
module.exports.order = order;
module.exports.CHARS = CHARS;

const COMMON_HEAD = `<meta name=viewport content="width=device-width,initial-scale=1"><style>
body{margin:0;font-family:sans-serif;background:#111;color:#eee}
header{height:48px;display:flex;gap:12px;align-items:center;padding:0 12px;background:#202020}
aside{position:fixed;left:-300px;top:0;width:200px}
.chips{display:flex;gap:8px;padding:8px}
.chip{padding:6px 12px;background:#333;border-radius:14px;border:0;color:#eee;cursor:pointer}
.menu{position:absolute;background:#222;border:1px solid #444;padding:4px;z-index:50}
.menu div{padding:8px 14px;cursor:pointer}
.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;padding:8px}
.card{display:block;color:inherit;text-decoration:none;background:#222;border-radius:10px;overflow:hidden}
.card img{width:100%;aspect-ratio:3/4;object-fit:cover;object-position:50% 20%;display:block;background:#444}
.modal{position:fixed;inset:0;background:rgba(0,0,0,.8);z-index:100;display:flex;align-items:center;justify-content:center}
</style>`;

const API_JS = `
function wrapImg(u){ return '/_next/image?url=' + encodeURIComponent(u) + '&w=256&q=75'; }
async function api(sort,date,cursor,count){
  const r = await fetch('/api/trpc/character.getCharactersByTag?batch=1&input=' + encodeURIComponent(JSON.stringify({0:{json:{sortTag:sort,date:date||null,cursor,count}}})));
  const j = await r.json(); return j[0].result.data.json;
}`;

function pageA() {
  return `<!doctype html><html><head><title>CrushOn mock A</title>${COMMON_HEAD}</head><body>
<header><a href="/">Home</a><a href="/auth/signin">Log In</a></header>
<aside><a href="/chat/zzz">Recent chat</a><a href="/character/c0001">Sidebar char</a></aside>
<div id=gift class=modal><div style="background:#333;padding:20px"><p>Gift!</p><button id=giftclose>Close</button></div></div>
<div class=chips><button class=chip>Characters</button><button class=chip>Memories</button></div>
<div class=chips>
  <button class=chip id=sortbtn aria-haspopup=menu>Recent Hits</button>
  <button class=chip id=gender>gender all</button>
  <button class=chip id=unf role=switch aria-pressed=true>Unfiltered</button>
  <span id=datewrap style="display:none"><button class=chip id=datebtn>Oct 11</button></span>
</div>
<div id=menuhost></div>
<div class=grid id=grid></div><div id=sentinel style="height:40px"></div>
<script>
${API_JS}
const state={sort:'recent-hits',date:null,cursor:0,loading:false,done:false,nsfw:true};
const AVAIL_MAX='2026-10-11', AVAIL_MIN='2026-09-20';
document.getElementById('giftclose').onclick=()=>document.getElementById('gift').remove();
const LABELS={'popular':'Popular','recent-hits':'Recent Hits','trending':'Trending','new':'New','daily-ranking':'Daily Ranking','editor-choice':"Editor\u2019s Choice",'following':'Following'};
const sortbtn=document.getElementById('sortbtn');
// Radix-like: opens on POINTERDOWN, ignores click.
if(location.search.includes('click')){ sortbtn.addEventListener('click',toggleMenu); } else sortbtn.addEventListener('pointerdown',(e)=>{ if(e.button!==0)return; toggleMenu(); });
function toggleMenu(){
  const host=document.getElementById('menuhost');
  if(host.firstChild){host.innerHTML='';return;}
  const m=document.createElement('div'); m.className='menu'; m.setAttribute('role','menu');
  Object.keys(LABELS).forEach(k=>{ const d=document.createElement('div'); d.setAttribute('role','menuitem'); d.textContent=LABELS[k];
    d.addEventListener('click',()=>choose(k)); m.appendChild(d); });
  host.appendChild(m);
}
function choose(k){ state.sort=k; document.getElementById('menuhost').innerHTML=''; sortbtn.textContent=LABELS[k];
  document.getElementById('datewrap').style.display = k==='daily-ranking'?'inline':'none';
  state.date = k==='daily-ranking'?AVAIL_MAX:null; document.getElementById('datebtn').textContent=fmt(state.date||AVAIL_MAX);
  reset(); }
function fmt(iso){ const d=new Date(iso+'T12:00:00Z'); return d.toLocaleString('en',{month:'short',timeZone:'UTC'})+' '+d.getUTCDate(); }
document.getElementById('unf').onclick=(e)=>{ const b=e.currentTarget; const on=b.getAttribute('aria-pressed')!=='true'; b.setAttribute('aria-pressed',on); state.nsfw=on; reset(); };
// custom calendar with disabled days
const datebtn=document.getElementById('datebtn');
let cal={y:2026,m:10};
datebtn.onclick=()=>{ const ex=document.getElementById('cal'); if(ex){ex.remove();return;} cal={y:2026,m:10}; drawCal(); };
function drawCal(){ let c=document.getElementById('cal'); if(!c){ c=document.createElement('div'); c.id='cal'; c.setAttribute('role','dialog'); c.className='menu'; c.style.top='120px'; document.body.appendChild(c);} 
  const names=['January','February','March','April','May','June','July','August','September','October','November','December'];
  const dim=new Date(cal.y,cal.m,0).getDate();
  let h='<div><button aria-label="Previous month" id=pm>&lt;</button> <span>'+names[cal.m-1]+' '+cal.y+'</span> <button aria-label="Next month" id=nm>&gt;</button></div><div role=grid>';
  for(let d=1; d<=dim; d++){ const iso=cal.y+'-'+String(cal.m).padStart(2,'0')+'-'+String(d).padStart(2,'0'); const dis=iso>AVAIL_MAX||iso<AVAIL_MIN;
    h+='<button class="day'+(dis?' disabled':'')+'" '+(dis?'disabled aria-disabled=true':'')+' data-iso='+iso+'>'+d+'</button>'; }
  c.innerHTML=h+'</div>';
  c.querySelector('#pm').onclick=()=>{cal.m--; if(cal.m<1){cal.m=12;cal.y--;} drawCal();};
  c.querySelector('#nm').onclick=()=>{cal.m++; if(cal.m>12){cal.m=1;cal.y++;} drawCal();};
  c.querySelectorAll('.day:not(.disabled)').forEach(b=>b.onclick=()=>{ state.date=b.dataset.iso; datebtn.textContent=fmt(state.date); c.remove(); reset(); });
}
function reset(){ document.getElementById('grid').innerHTML=''; state.cursor=0; state.done=false; state.loading=false; window.scrollTo(0,0); more(); }
const io=new IntersectionObserver(es=>{ if(es.some(e=>e.isIntersecting)) more(); },{rootMargin:'200px'});
const lazy=new IntersectionObserver(es=>es.forEach(e=>{ if(e.isIntersecting){ const im=e.target; if(im.dataset.src){ im.src=im.dataset.src; delete im.dataset.src; } lazy.unobserve(im);} }),{rootMargin:'50px'});
async function more(){
  if(state.loading||state.done) return; state.loading=true;
  const my=state.sort+state.date+state.nsfw;
  const r=await api(state.sort,state.date,state.cursor,20);
  if(my!==state.sort+state.date+state.nsfw){ state.loading=false; return; }
  const items=r.items.filter(c=>state.nsfw||!c.nsfw);
  if(!r.items.length){state.done=true;}
  state.cursor+=r.items.length;
  const g=document.getElementById('grid');
  items.forEach(c=>{ const a=document.createElement('a'); a.className='card'; a.href='/character/'+c.id;
    const im=document.createElement('img'); im.alt=c.name; im.dataset.src=wrapImg(c.avatar); im.srcset=''; a.appendChild(im);
    const h=document.createElement('h3'); h.textContent=c.name; a.appendChild(h); g.appendChild(a); lazy.observe(im); });
  state.loading=false;
  setTimeout(()=>{ const s=document.getElementById('sentinel'); io.unobserve(s); io.observe(s); },50);
}
reset(); io.observe(document.getElementById('sentinel'));
</script></body></html>`;
}

function pageB() { // virtualized list in custom scroller + native <select>
  return `<!doctype html><html><head><title>mock B</title>${COMMON_HEAD}
<style>#scroller{height:calc(100vh - 100px);overflow:auto;position:relative}#inner{position:relative}
.vi{position:absolute;left:0;right:0;height:120px}</style></head><body>
<header><a href="/auth/signin">Log In</a></header>
<div class=chips><select id=sel><option>Popular</option><option selected>Recent Hits</option><option>Trending</option><option>New</option></select></div>
<div id=scroller><div id=inner></div></div>
<script>
${API_JS}
const MAP={'Popular':'popular','Recent Hits':'recent-hits','Trending':'trending','New':'new'};
let sort='recent-hits', data=[], loading=false, done=false;
const H=120, sc=document.getElementById('scroller'), inner=document.getElementById('inner');
document.getElementById('sel').onchange=e=>{ sort=MAP[e.target.value]; data=[]; done=false; inner.innerHTML=''; sc.scrollTop=0; inner.style.height='0px'; load(); };
async function load(){ if(loading||done)return; loading=true; const r=await api(sort,null,data.length,30); if(!r.items.length) done=true; data=data.concat(r.items); inner.style.height=(data.length*H)+'px'; loading=false; render(); }
function render(){ const first=Math.floor(sc.scrollTop/H), n=Math.ceil(sc.clientHeight/H)+2; inner.innerHTML='';
  for(let i=Math.max(0,first-1);i<Math.min(data.length,first+n);i++){ const c=data[i]; const d=document.createElement('div'); d.className='vi'; d.style.top=(i*H)+'px';
   d.innerHTML='<a class=card href="/en/character/'+c.id+'"><img src="'+c.avatar+'" style="aspect-ratio:auto;height:90px;width:90px;object-fit:contain"><h3>'+c.name+'</h3></a>'; inner.appendChild(d);} 
  if(sc.scrollTop+sc.clientHeight>sc.scrollHeight-400) load(); }
sc.addEventListener('scroll',render); load();
</script></body></html>`;
}

function pageC() { // no anchors at all: div cards with click handlers
  return `<!doctype html><html><head><title>mock C</title>${COMMON_HEAD}</head><body><div id=list></div>
<script>${API_JS}
let cur=0, busy=false; async function more(){ if(busy)return; busy=true; const r=await api('recent-hits',null,cur,20); busy=false; cur+=r.items.length; r.items.forEach(c=>{const d=document.createElement('div'); d.textContent=c.name; d.onclick=()=>{}; document.getElementById('list').appendChild(d);}); }
more(); window.addEventListener('scroll',()=>{ if(innerHeight+scrollY>document.body.scrollHeight-300) more(); });
</script></body></html>`;
}

function pageAccount() {
  return `<!doctype html><html><head><title>account</title>${COMMON_HEAD}</head><body>
<header><a href="/">Home</a></header><div class=chips><button class=chip id=t1>Characters</button><button class=chip id=t2>Favorites (3)</button></div>
<div class=grid id=grid></div><script>
function show(ids){ const g=document.getElementById('grid'); g.innerHTML=''; ids.forEach(id=>{ const a=document.createElement('a'); a.className='card'; a.href='/character/'+id; a.innerHTML='<img src="https://cdn.example.test/'+id+'.webp"><h3>'+id+'</h3>'; g.appendChild(a); }); }
show(['mine1','mine2']);
t1.onclick=()=>show(['mine1','mine2']); t2.onclick=()=>show(['fav-a','fav-b','fav-c']);
</script></body></html>`;
}
function pageSearch() {
  return `<!doctype html><html><head><title>search</title>${COMMON_HEAD}</head><body>
<input type=search placeholder="Search characters" id=q><div class=grid id=grid></div><script>
q.addEventListener('keydown',e=>{ if(e.key==='Enter'){ const g=document.getElementById('grid'); g.innerHTML=''; for(let i=0;i<5;i++){ const a=document.createElement('a'); a.className='card'; a.href='/character/'+q.value+'-'+i; a.innerHTML='<img src="https://cdn.example.test/'+i+'.webp"><h3>'+q.value+' '+i+'</h3>'; g.appendChild(a);} } });
</script></body></html>`;
}

const server = http.createServer((req, res) => {
  const u = url.parse(req.url, true);
  if (u.pathname.startsWith('/api/trpc/')) {
    const input = JSON.parse(u.query.input)[0].json;
    const items = order(input.sortTag, input.date).slice(input.cursor, input.cursor + input.count);
    res.setHeader('content-type', 'application/json');
    return res.end(JSON.stringify([{ result: { data: { json: { items, nextCursor: input.cursor + items.length } } } }]));
  }
  res.setHeader('content-type', 'text/html');
  if (u.pathname === '/' || u.pathname === '/a') return res.end(pageA());
  if (u.pathname === '/b') return res.end(pageB());
  if (u.pathname === '/c') return res.end(pageC());
  if (u.pathname === '/account') return res.end(pageAccount());
  if (u.pathname === '/search') return res.end(pageSearch());
  res.statusCode = 404; res.end('nf');
});
module.exports.start = (port) => new Promise(r => server.listen(port, () => r(server)));
if (require.main === module) module.exports.start(4173).then(() => console.log('mock on 4173'));
