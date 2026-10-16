// Calendar shaped like the real crushon.ai popup: no role/class hints, "OCT" and
// "2026" printed separately, struck-through days after the site's last day.
const fs = require('fs'), path = require('path');
const { chromium } = require('playwright');
const READER = fs.readFileSync(path.join(__dirname, '../../assets/crushon/site_reader.js'), 'utf8');
const HTML = `<!doctype html><body style="background:#111;color:#ddd;font:14px sans-serif">
<div id="bar"><span>Daily R...</span><div id="chip" class="x1"><svg width="12" height="12"></svg><span id="lbl">2026/10/09</span></div></div>
<div id="pop" style="display:none;position:absolute;top:80px;left:20px;width:330px;background:#223"></div>
<script>
let y=2026,m=9,sel='2026-10-09'; const MAX='2026-10-10'; const N=['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
const pad=n=>(n<10?'0':'')+n;
function render(){const pop=document.getElementById('pop');const first=new Date(y,m,1).getDay(),dim=new Date(y,m+1,0).getDate(),pd=new Date(y,m,0).getDate();
let h='<div class="h1" style="display:flex;justify-content:space-between"><div class="b1" id="prev"><svg width="14" height="14"></svg></div><div><span>'+N[m]+'</span> <span>'+y+'</span></div><div class="b1" id="next"><svg width="14" height="14"></svg></div></div>';
h+='<div style="display:grid;grid-template-columns:repeat(7,1fr)">'+['Sun','Mon','Tue','Wed','Thu','Fri','Sat'].map(d=>'<span>'+d+'</span>').join('');
for(let i=first-1;i>=0;i--)h+='<div class="c o">'+(pd-i)+'</div>';
for(let d=1;d<=dim;d++){const iso=y+'-'+pad(m+1)+'-'+pad(d);const dis=iso>MAX;h+='<div class="c" data-iso="'+iso+'" style="'+(dis?'text-decoration:line-through;opacity:.6':'')+'">'+d+'</div>';}
const tail=(7-((first+dim)%7))%7;for(let d=1;d<=tail+7;d++)h+='<div class="c o" style="text-decoration:line-through">'+d+'</div>';
h+='</div>';pop.innerHTML=h;
pop.querySelector('#prev').onclick=()=>{m--;if(m<0){m=11;y--}render()};pop.querySelector('#next').onclick=()=>{m++;if(m>11){m=0;y++}render()};
pop.querySelectorAll('.c[data-iso]').forEach(c=>c.onclick=()=>{const iso=c.dataset.iso;if(iso>MAX)return;sel=iso;document.getElementById('lbl').textContent=iso.replace(/-/g,'/');pop.style.display='none';});}
document.getElementById('chip').onclick=()=>{const p=document.getElementById('pop');p.style.display=p.style.display==='none'?'block':'none';render();};
</script></body>`;
let pass = 0, fail = 0;
const ok = (c, m, x) => { c ? pass++ : fail++; console.log(c ? '  PASS' : '  FAIL', m, c ? '' : JSON.stringify(x)); };
(async () => {
  const b = await chromium.launch(); const p = await (await b.newContext({ viewport: { width: 430, height: 900 } })).newPage();
  await p.setContent(HTML); await p.evaluate(READER); await p.waitForTimeout(300);
  const call = e => p.evaluate(`(async()=>await ${e})()`);
  let d = await call('__gzCO.readDate()');
  ok(d.has && d.iso === '2026-10-09', 'reads chip date', d);
  let r = await call('__gzCO.readDateRange()');
  ok(r.max === '2026-10-10', 'range max is the 10th (struck days excluded)', r);
  ok(r.min === '2026-10-01', 'range min is the 1st', r);
  ok(await p.$eval('#pop', e => e.style.display) === 'none', 'popup closed after reading range');
  r = await call('__gzCO.applyDate("2026-10-07")');
  ok(r.ok, 'applyDate(Oct 7) ok', r);
  ok((await p.textContent('#lbl')) === '2026/10/07', 'chip shows Oct 7', await p.textContent('#lbl'));
  r = await call('__gzCO.applyDate("2026-10-10")');
  ok(r.ok && (await p.textContent('#lbl')) === '2026/10/10', 'applyDate(Oct 10) works', r);
  r = await call('__gzCO.applyDate("2026-10-12")');
  ok(!r.ok && r.reason === 'day-unavailable', 'struck day refused', r);
  r = await call('__gzCO.applyDate("2026-09-20")');
  ok(r.ok && (await p.textContent('#lbl')) === '2026/09/20', 'previous month reachable', [r, await p.textContent('#lbl')]);
  await b.close(); console.log(pass + ' passed, ' + fail + ' failed'); process.exit(fail ? 1 : 0);
})();
