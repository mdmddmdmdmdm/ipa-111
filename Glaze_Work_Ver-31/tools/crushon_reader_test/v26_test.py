"""v26 checks (python playwright):  python3 v26_test.py
 1. Favorites: home page (sidebar + header icons + a video card) -> Profile link ->
    counters -> icon row (bear, book, clapper, STAR, thumb, image, GIF) -> star ->
    chips -> cards. Must NOT click header icons, must land on the star tab.
 2. Daily Ranking badges are read (1 Debut!, 2 up 3, 3 up 8, #4 Debut!).
 3. Videos never play / autoplay is stripped / fullscreen refused.
"""
import os, sys, json
from playwright.sync_api import sync_playwright
R = open(os.path.join(os.path.dirname(__file__), '../../assets/crushon/site_reader.js')).read()
ICON = '<svg width=24 height=24><path d="M0 0h24v24H0z"/></svg>'
CARD = lambda n, extra='': f'''<div class=card style="position:relative;width:180px;margin:6px;display:inline-block"><a href="/character/00000000-0000-4000-8000-00000000000{n}"><div style="position:relative;width:180px;height:240px">
<img alt=c{n} width=180 height=240 src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">{extra}</div><h3>Char {n}</h3></a></div>'''
HOME = '''<!doctype html><body style="font:14px sans-serif;margin:0">
<header style="display:flex;gap:14px;padding:10px;position:sticky;top:0">
 <button id=burger style="width:40px;height:40px">@ICON@</button><button id=toggle style="width:40px;height:40px">@ICON@</button>
 <button id=r18 style="width:40px;height:40px">@ICON@</button><button id=search style="width:40px;height:40px">@ICON@</button><button id=share style="width:40px;height:40px">@ICON@</button></header>
<nav><a href="/">Home</a> <a href="/chats">Recent Chats</a> <a href="/rank">Rankings</a> <a href="/profile">Profile</a></nav>
@VCARD@
<script>window.clicks=[];document.querySelectorAll('header button').forEach(b=>b.addEventListener('click',()=>window.clicks.push(b.id)));</script></body>'''.replace('@ICON@', ICON).replace('@VCARD@', CARD(1,'<video autoplay loop muted src="data:video/mp4;base64,AAAA" style="position:absolute;inset:0;width:180px;height:240px"></video>'))
PROFILE = '''<!doctype html><body style="font:14px sans-serif;margin:0">
<header style="display:flex;gap:14px;padding:10px"><button id=burger style="width:40px;height:40px">@ICON@</button><button style="width:40px;height:40px">@ICON@</button><button style="width:40px;height:40px">@ICON@</button><button style="width:40px;height:40px">@ICON@</button></header>
<h1>Noah Shambley</h1>
<div style="display:flex;gap:24px"><div><b>0</b><br>Followers</div><div><b>0</b><br>Following</div><div><b>2</b><br>Interactions</div><button>Edit</button></div>
<div style="background:#aef;padding:10px">Free <button>Upgrade</button> Message Credits Usage: 0 / 300 <span>Wallet</span></div>
<div id=tabs style="display:flex;gap:20px;margin:20px;align-items:center">
 @TABS@
 <div class=gif style="width:48px;height:44px;margin-left:130px;cursor:pointer">@ICON@</div></div>
<div id=chips style="display:flex;gap:10px"></div><div id=out></div>
<script>let tab=0;window.clicks=[];document.querySelectorAll('.t').forEach(t=>t.addEventListener('click',()=>{tab=+t.dataset.i;window.clicks.push('tab'+tab);draw()}));
document.querySelector('.gif').addEventListener('click',()=>window.clicks.push('gif'));
function draw(){const c=document.getElementById('chips'),o=document.getElementById('out');
c.innerHTML=tab===3?'<span>Characters</span><span>World Cards</span><span>Memories</span><span>Models</span><span>Folders</span>':'<span>All (1)</span><span>Target</span><span>Public</span>';
o.innerHTML=tab===3?[2,3,4].map(n=>'<a href="/character/00000000-0000-4000-8000-00000000000'+n+'"><img alt=c'+n+' width=180 height=200 src="data:image/gif;base64,R0lGODlhAQABAAAAACw="><h3>Fav '+n+'</h3></a>').join(''):'<a href="/character/aaaaaaaa-0000-4000-8000-000000000000"><h3>Lily</h3></a>';}
draw();</script></body>'''.replace('@ICON@', ICON).replace('@TABS@', ''.join('<div class=t data-i=%d style="width:44px;height:44px;cursor:pointer">%s</div>' % (i, ICON) for i in range(6)))
BADGE = lambda inner: f'<div style="position:absolute;left:0;top:0;padding:4px 8px;background:pink">{inner}</div>'
RANK = ('<!doctype html><body style="font:14px sans-serif;margin:0">' +
  CARD(1, BADGE('<svg width=14 height=14></svg><span>1</span> <span>Debut!</span>')) +
  CARD(2, BADGE('<svg width=14 height=14></svg><span>2</span> <svg class="arrow-up" width=10 height=10></svg><span>3</span>')) +
  CARD(3, BADGE('<svg width=14 height=14></svg><span>3</span> <svg class="arrow-down" width=10 height=10></svg><span>8</span>')) +
  CARD(4, BADGE('<span>#</span><span>4</span> <span>Debut!</span>')) + '</body>')

P_BODY = PROFILE.split('<body style="font:14px sans-serif;margin:0">')[1].split('<script>')[0]
P_SCRIPT = PROFILE.split('<script>')[1].split('</script>')[0]
SPA = '''(cfg)=>{ document.addEventListener('click', e=>{ const a=e.target.closest('a[href="/profile"]'); if(!a) return;
  e.preventDefault(); document.body.innerHTML=cfg.body; (0,eval)(cfg.script); history.pushState({}, '', '/profile'); }, true); }'''
fails = []
def check(name, ok, info=''):
    print(('PASS ' if ok else 'FAIL ') + name + (' ' + str(info) if info else ''))
    if not ok: fails.append(name)

with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(viewport={'width': 430, 'height': 900})
    ctx.add_init_script(R)                         # like the real document-start user script
    page = ctx.new_page()
    pages = {'/': HOME, '/profile': PROFILE, '/rank': RANK}
    def handle(route):
        req = route.request
        if req.resource_type != 'document':
            return route.fulfill(status=200, body='')
        path = '/' + req.url.split('://', 1)[1].split('/', 1)[1].split('?')[0]
        route.fulfill(status=200, content_type='text/html', body=pages.get(path, '<html>404</html>'))
    page.route('**/*', handle)
    # --- 1. favorites
    page.goto('https://crushon.test/')
    page.wait_for_timeout(300)
    home_clicks = page.evaluate('window.clicks.length')
    page.evaluate(SPA, {'body': P_BODY, 'script': P_SCRIPT})
    r = json.loads(page.evaluate("(async()=>JSON.stringify(await __gzCO.openFavorites()))()"))
    names = page.eval_on_selector_all('#out h3', 'a=>a.map(x=>x.textContent)')
    clicks = page.evaluate('window.clicks')
    check('favorites ok', r.get('ok') is True, r)
    check('favorites are the star tab cards (not Lily)', names == ['Fav 2', 'Fav 3', 'Fav 4'], names)
    check('only tab clicks on the profile, no GIF', 'gif' not in clicks and clicks and clicks[0] == 'tab3', clicks)
    check('no header icon was clicked on the way', home_clicks == 0 and 'burger' not in clicks and 'search' not in clicks, clicks)
    # --- 2. rank
    page.goto('https://crushon.test/rank'); page.wait_for_timeout(300)
    snap = json.loads(page.evaluate("JSON.stringify((__gzCO.scan(), __gzCO.snapshot(0,10)))"))
    got = [(i['rank'], i['rankNote']) for i in snap['items']]
    check('rank badges', got == [(1, 'Debut!'), (2, '\u21913'), (3, '\u21938'), (4, 'Debut!')], got)
    # --- 3. media
    page.goto('https://crushon.test/'); page.wait_for_timeout(300)
    v = page.evaluate('''(()=>{const v=document.querySelector('video');return {auto:v.hasAttribute('autoplay'),src:v.hasAttribute('src'),paused:v.paused,inline:v.hasAttribute('playsinline')}})()''')
    check('video: autoplay stripped, src removed, paused, inline', (not v['auto']) and (not v['src']) and v['paused'] and v['inline'], v)
    pl = page.evaluate('''(async()=>{const v=document.querySelector('video');await v.play();let fs='none';try{await v.requestFullscreen();fs='allowed'}catch(e){fs='refused'}return {paused:v.paused,fs}})()''')
    check('video: play() is a no-op, fullscreen refused', pl['paused'] and pl['fs'] == 'refused', pl)
    b.close()
sys.exit(1 if fails else 0)
