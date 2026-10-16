// Character page like the screenshots: tab row (Info/Memories/Comment/Supporters),
// then a styled HTML description with banner, pictures and labelled text.
const fs=require('fs'),path=require('path');const {chromium}=require('playwright');
const R=fs.readFileSync(path.join(__dirname,'../../assets/crushon/site_reader.js'),'utf8');
const HTML=`<!doctype html><body style="font:14px sans-serif"><header><a href="/">back</a><h1>Roommate's Thicc Problems</h1></header>
<div class=tabs style="display:flex;gap:20px"><div>Info</div><div>Memories <small>30</small></div><div>Comment <small>92</small></div><div>Supporters</div></div>
<div class=panel><div style="text-align:center;font-family:Poppins"><h2 style="color:#FF9BAD">Roommate's Thicc Problems</h2>
<span style="color:#FF9BAD">50+ Images | Astra Yao | Frustrated Roommate | ZZZ</span></div>
<h2 style="color:#ff5c78">Character Profile</h2>
<div style="background:#2D2226" onclick="evil()"><h3>Astra Yao</h3><img alt="a" src="/_next/image?url=https%3A%2F%2Fcdn.example.com%2Fastra.png&w=640&q=75">
<p><b style="color:#ff9bad">Personality:</b> Bubbly, expressive, playful.</p>
<p><b>Background:</b> A 21-year-old college student &amp; roommate.</p><script>alert(1)</script></div></div>
<footer><button>Start Chat</button></footer></body>`;
(async()=>{const b=await chromium.launch();const p=await (await b.newContext({viewport:{width:430,height:900}})).newPage();
await p.setContent(HTML);await p.evaluate(R);
const r=JSON.parse(await p.evaluate(`(async()=>JSON.stringify(await __gzCO.captureInfo()))()`));
console.log(JSON.stringify(r,null,1).slice(0,1500));
const ok=r.ok&&/Personality/.test(r.html)&&/background:#2D2226/i.test(r.html)&&!/<script|onclick|Start Chat/.test(r.html)
 &&r.images[0]==='https://cdn.example.com/astra.png'&&!/Memories/.test(r.html);
console.log(ok?'PASS info panel captured':'FAIL');await b.close();process.exit(ok?0:1)})();
