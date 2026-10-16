// Profile page like the screenshots. Tabs: bear(my characters), book, clapper, star, thumb, image
// + a GIF button in the same row. The first tab shows All/Target/Public chips and the user's own
// character (Lily); only the star tab shows Characters/World Cards/... chips and the favorites.
// A leading extra icon makes "4th icon" the WRONG tab, so the reader must confirm by content.
const fs=require('fs'),path=require('path');const {chromium}=require('playwright');
const R=fs.readFileSync(path.join(__dirname,'../../assets/crushon/site_reader.js'),'utf8');
const HTML=`<!doctype html><body style="font:14px sans-serif"><div style="display:flex;gap:24px"><div><b>0</b><br>Followers</div><div><b>0</b><br>Following</div><div><b>2</b><br>Interactions</div></div><div id=tabs style="display:flex;gap:20px;margin:20px">
${[0,1,2,3,4,5,6].map(i=>`<div class=t data-i=${i} style="width:40px;height:40px"><svg width=24 height=24></svg></div>`).join('')}
<div style="width:50px;height:40px;margin-left:120px"><svg width=24 height=24></svg></div></div>
<div id=chips style="display:flex;gap:10px"></div><div id=out></div>
<script>let tab=0;document.querySelectorAll('.t').forEach(t=>t.onclick=()=>{tab=+t.dataset.i;draw()});
function draw(){const c=document.getElementById('chips'),o=document.getElementById('out');
c.innerHTML=tab===4?'<span>Characters</span><span>World Cards</span><span>Memories</span><span>Models</span><span>Folders</span>':'<span>All 1</span><span>Target</span><span>Public</span>';
o.innerHTML=tab===4?[1,2,3].map(n=>'<a href="/character/00000000-0000-4000-8000-00000000000'+n+'"><img alt=c'+n+' src="data:image/gif;base64,R0lGODlhAQABAAAAACw="><h3>Fav '+n+'</h3></a>').join(''):'<a href="/character/aaaaaaaa-0000-4000-8000-000000000000"><h3>Lily</h3></a>';}
draw();</script></body>`;
(async()=>{const b=await chromium.launch();const p=await (await b.newContext({viewport:{width:430,height:900}})).newPage();
await p.setContent(HTML);await p.evaluate(R);
const r=JSON.parse(await p.evaluate(`(async()=>JSON.stringify(await __gzCO.openFavorites()))()`));
console.log(JSON.stringify(r));const names=await p.$$eval('#out h3',a=>a.map(x=>x.textContent));
const ok=r.ok&&names.length===3&&!names.includes('Lily');
console.log(ok?'PASS star tab confirmed, favorites shown (not Lily)':'FAIL '+names);await b.close();process.exit(ok?0:1)})();
