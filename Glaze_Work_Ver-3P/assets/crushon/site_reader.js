/* Glaze – CrushOn Site Reader (in-page half).
 *
 * Injected at document start into a hidden WebView that is showing the real
 * crushon.ai site. It does NOT guess any API. It:
 *   1. drives the site's own UI (sort dropdown, date control, tags, search,
 *      favorites tab) exactly like a person would, and
 *   2. reads the cards the site renders, in the order the site renders them,
 *      scrolling the site's own infinite list for as long as needed, and
 *   3. passively records the JSON the site itself fetches so each card can be
 *      enriched with tags / counts / full-size art.
 *
 * Everything is exposed on window.__gzCO and is idempotent.
 */
(function () {
  'use strict';
  if (window.__gzCO && window.__gzCO.version >= 3) return;


  // ---------------------------------------------------------------- no video, ever
  // Character cards autoplay short preview videos. In a hidden iOS web view a
  // playing <video> is handed to the system's full-screen player, which takes over
  // the whole app (the art "popping up" while you scroll). The reader only needs
  // the pictures, so media is switched off here: play() does nothing, autoplay is
  // stripped, sources are removed, full-screen / picture-in-picture are refused.
  // (The Dart side also blocks the media requests natively.)
  (function killMedia() {
    try {
      var MP = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
      var origLoad = MP && MP.load;
      if (MP) {
        MP.play = function () { try { this.pause(); } catch (e) {} return Promise.resolve(); };
        MP.load = function () {};
      }
      var VP = window.HTMLVideoElement && window.HTMLVideoElement.prototype;
      if (VP) {
        VP.webkitEnterFullscreen = function () {};
        VP.webkitEnterFullScreen = function () {};
        VP.requestPictureInPicture = function () { return Promise.reject(new Error('blocked')); };
      }
      var deny = function () { return Promise.reject(new Error('fullscreen blocked')); };
      ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen'].forEach(function (n) {
        try { if (window.Element && Element.prototype[n]) Element.prototype[n] = deny; } catch (e) {}
      });
      function calm(m) {
        try {
          m.removeAttribute('autoplay');
          m.setAttribute('playsinline', '');
          m.setAttribute('webkit-playsinline', '');
          m.setAttribute('preload', 'none');
          m.setAttribute('disablepictureinpicture', '');
          m.removeAttribute('controls');
          m.muted = true;
          if (m.hasAttribute('src') || m.querySelector('source')) {
            m.removeAttribute('src');
            [].slice.call(m.querySelectorAll('source')).forEach(function (x) { x.remove(); });
            if (origLoad) origLoad.call(m);   // abort whatever it was fetching
          }
          m.pause();
        } catch (e) {}
      }
      function sweep(root) {
        try {
          if (root.matches && root.matches('video,audio')) calm(root);
          if (root.querySelectorAll) [].slice.call(root.querySelectorAll('video,audio')).forEach(calm);
        } catch (e) {}
      }
      function arm() {
        var de = document.documentElement;
        if (!de) { setTimeout(arm, 5); return; }
        try {
          var st = document.createElement('style');
          st.textContent = 'video,audio{visibility:hidden!important}';
          (document.head || de).appendChild(st);
        } catch (e) {}
        sweep(de);
        new MutationObserver(function (muts) {
          for (var i = 0; i < muts.length; i++) {
            var added = muts[i].addedNodes;
            for (var j = 0; j < added.length; j++) if (added[j].nodeType === 1) sweep(added[j]);
            if (muts[i].type === 'attributes' && muts[i].target && /^(VIDEO|AUDIO)$/.test(muts[i].target.tagName)) calm(muts[i].target);
          }
        }).observe(de, { childList: true, subtree: true, attributes: true, attributeFilter: ['autoplay', 'src'] });
      }
      arm();
    } catch (e) {}
  })();

  var S = {
    feed: [],            // ordered card records (the truth)
    map: new Map(),      // id -> record
    els: new Map(),      // id -> DOM element (last seen)
    raw: new Map(),      // any id-ish key -> raw JSON object the site fetched
    netOrder: [],        // ids in network arrival order (fallback only)
    netSet: new Set(),
    netSeq: 0,
    lastNetAt: 0,
    exhausted: false,
    parent: null,        // DOM parent of the feed's cards
    virtual: false,      // list recycles DOM nodes -> must scroll in small steps
    logs: []
  };

  function log(m) {
    try {
      S.logs.push(new Date().toISOString().slice(11, 19) + ' ' + m);
      if (S.logs.length > 250) S.logs.shift();
    } catch (e) {}
  }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function norm(s) {
    return String(s == null ? '' : s).toLowerCase()
      .replace(/[\u2018\u2019\u201B`\u00B4']/g, '')
      .replace(/[^a-z0-9]+/g, ' ').trim();
  }
  function ownText(el) {
    var t = '';
    try { t = (el.innerText || el.textContent || ''); } catch (e) {}
    return t.replace(/\s+/g, ' ').trim();
  }
  function visible(el) {
    if (!el || !el.getBoundingClientRect) return false;
    var r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    var cs;
    try { cs = getComputedStyle(el); } catch (e) { return true; }
    if (cs.visibility === 'hidden' || cs.display === 'none') return false;
    if (parseFloat(cs.opacity) === 0) return false;
    return true;
  }


  // ---------------------------------------------------------------- external links
  // This hidden browser must NEVER leave crushon.ai. crushon.ai's sidebar/footer
  // carries social icons (Discord, Reddit, X, Telegram...). A synthetic click on one
  // of those is a real navigation, and on iOS a reddit.com link is handed to the
  // Reddit app / Safari (universal links), which is what made Glaze "open Reddit"
  // while browsing. So: (1) never click an external anchor, (2) swallow any click
  // that reaches one, (3) neutralise window.open. The Dart side also cancels
  // off-site navigations (shouldOverrideUrlLoading) as a second layer.
  function isExternalHref(h) {
    if (h == null) return false;
    h = String(h).trim();
    if (!h) return false;
    if (/^(#|\?|javascript:|about:|blob:|data:)/i.test(h)) return false;
    if (/^\/(?!\/)/.test(h)) return false;
    try {
      var x = new URL(h, location.href);
      if (x.protocol !== 'http:' && x.protocol !== 'https:') return true; // mailto:, tel:, reddit://, intent:...
      return !/(^|\.)crushon\.ai$/i.test(x.hostname);
    } catch (e) { return false; }
  }
  function externalAnchorOf(el) {
    try {
      var a = el && el.closest ? el.closest('a[href]') : null;
      return a && isExternalHref(a.getAttribute('href')) ? a : null;
    } catch (e) { return null; }
  }
  try {
    ['click', 'auxclick'].forEach(function (type) {
      document.addEventListener(type, function (ev) {
        var a = externalAnchorOf(ev.target);
        if (a) {
          ev.preventDefault();
          ev.stopImmediatePropagation();
          log('blocked external link click: ' + String(a.getAttribute('href')).slice(0, 80));
        }
      }, true);
    });
    window.open = function (u) { log('blocked window.open ' + String(u || '').slice(0, 80)); return null; };
    var origAnchorClick = HTMLAnchorElement.prototype.click;
    HTMLAnchorElement.prototype.click = function () {
      if (isExternalHref(this.getAttribute('href'))) { log('blocked anchor.click() to external link'); return; }
      return origAnchorClick.apply(this, arguments);
    };
  } catch (e) {}

  // ---------------------------------------------------------------- network
  var IMG_KEYS = ['avatar', 'avatarUrl', 'avatar_url', 'image', 'imageUrl', 'image_url',
    'cover', 'coverUrl', 'poster', 'thumbnail', 'thumbnailUrl', 'picture', 'img',
    'photo', 'portrait', 'profileImage'];
  var TEXT_KEYS = ['introduction', 'greeting', 'brief', 'description', 'tags', 'personality'];

  function hasAny(o, keys) {
    for (var i = 0; i < keys.length; i++) {
      if (o[keys[i]] != null && o[keys[i]] !== '') return true;
    }
    return false;
  }
  function charLike(o) {
    if (!o || typeof o !== 'object' || Array.isArray(o)) return false;
    var id = o.id != null ? o.id : (o.characterId != null ? o.characterId : o.uuid);
    var name = o.name != null ? o.name : (o.characterName != null ? o.characterName : o.title);
    if (id == null || typeof name !== 'string' || !name) return false;
    return hasAny(o, IMG_KEYS) || hasAny(o, ['introduction', 'greeting', 'brief']);
  }
  function idKeys(o) {
    var ks = [];
    ['id', 'characterId', 'uuid', 'slug'].forEach(function (k) {
      if (o[k] != null && o[k] !== '') ks.push(String(o[k]));
    });
    return ks;
  }
  function ingestJson(root) {
    var found = [], nodes = 0;
    (function walk(n, d) {
      if (n == null || d > 9 || nodes > 20000) return;
      nodes++;
      if (Array.isArray(n)) { for (var i = 0; i < n.length; i++) walk(n[i], d + 1); return; }
      if (typeof n !== 'object') return;
      if (charLike(n)) found.push(n);
      for (var k in n) {
        if (Object.prototype.hasOwnProperty.call(n, k)) {
          var v = n[k];
          if (v && typeof v === 'object') walk(v, d + 1);
        }
      }
    })(root, 0);
    if (!found.length) return 0;
    found.forEach(function (o) {
      var keys = idKeys(o);
      keys.forEach(function (k) {
        var ex = S.raw.get(k);
        if (!ex) { S.raw.set(k, o); return; }
        // Keep the richer object, but never lose fields.
        var merged = Object.assign({}, ex, o);
        S.raw.set(k, merged);
      });
      var primary = String(o.id != null ? o.id : (o.characterId != null ? o.characterId : o.uuid));
      if (hasAny(o, IMG_KEYS) && !S.netSet.has(primary)) {
        S.netSet.add(primary);
        S.netOrder.push(primary);
      }
    });
    S.netSeq++;
    S.lastNetAt = Date.now();
    return found.length;
  }
  function onBody(url, text) {
    try {
      if (!text || text.length > 6000000) return;
      var c = text.charCodeAt(0);
      while ((c === 32 || c === 10 || c === 13 || c === 9) && text.length) { text = text.slice(1); c = text.charCodeAt(0); }
      if (c !== 123 && c !== 91) return; // { or [
      var n = ingestJson(JSON.parse(text));
      if (n) log('net +' + n + ' <- ' + String(url).slice(0, 90));
    } catch (e) {}
  }
  function inspectable(url) {
    if (!url) return false;
    url = String(url);
    if (/\/_next\/static|\.(js|css|png|jpe?g|gif|webp|svg|woff2?|ico|mp4|webm)(\?|$)/i.test(url)) return false;
    return true;
  }
  try {
    var of = window.fetch;
    if (of && !of.__gz) {
      var nf = function (input) {
        var p = of.apply(this, arguments);
        try {
          var url = typeof input === 'string' ? input : (input && input.url) || '';
          if (inspectable(url)) {
            p.then(function (r) {
              try { r.clone().text().then(function (t) { onBody(url, t); }, function () {}); } catch (e) {}
            }, function () {});
          }
        } catch (e) {}
        return p;
      };
      nf.__gz = true;
      window.fetch = nf;
    }
    var XO = XMLHttpRequest.prototype.open, XS = XMLHttpRequest.prototype.send;
    if (!XO.__gz) {
      XMLHttpRequest.prototype.open = function (m, u) { this.__gzUrl = u; return XO.apply(this, arguments); };
      XMLHttpRequest.prototype.open.__gz = true;
      XMLHttpRequest.prototype.send = function () {
        var x = this;
        try {
          if (inspectable(x.__gzUrl)) {
            x.addEventListener('load', function () {
              try {
                if (x.responseType === '' || x.responseType === 'text') onBody(x.__gzUrl, x.responseText);
                else if (x.responseType === 'json' && x.response) ingestJson(x.response);
              } catch (e) {}
            });
          }
        } catch (e) {}
        return XS.apply(this, arguments);
      };
    }
  } catch (e) {}

  // ---------------------------------------------------------------- scanning
  var CHAR_RE = /\/characters?\/([^\/?#]+)/i;
  var BAD_IDS = { create: 1, 'new': 1, edit: 1, search: 1, list: 1 };
  function idFromHref(h) {
    if (!h) return null;
    var m = CHAR_RE.exec(h);
    if (!m) return null;
    var id;
    try { id = decodeURIComponent(m[1]); } catch (e) { id = m[1]; }
    if (!id || BAD_IDS[id.toLowerCase()]) return null;
    return id;
  }
  function inLandmark(el) {
    return !!(el.closest && el.closest('nav,aside,header,footer,[role=navigation],[role=dialog],[aria-modal=true]'));
  }
  function bestSrcFromImg(img) {
    var cands = [];
    var cs = img.currentSrc || '';
    if (cs) cands.push(cs);
    var ss = img.getAttribute('srcset') || img.getAttribute('data-srcset') || '';
    if (ss) {
      var best = null, bw = -1;
      ss.split(',').forEach(function (part) {
        var p = part.trim().split(/\s+/);
        if (!p[0]) return;
        var w = parseFloat(p[1]) || 1;
        if (/x$/.test(p[1] || '')) w = parseFloat(p[1]) * 1000;
        if (w > bw) { bw = w; best = p[0]; }
      });
      if (best) cands.unshift(best);
    }
    ['src', 'data-src', 'data-lazy-src', 'data-original'].forEach(function (a) {
      var v = img.getAttribute(a);
      if (v) cands.push(v);
    });
    for (var i = 0; i < cands.length; i++) {
      var c = cands[i];
      if (!c || /^data:image\/(gif|svg)/i.test(c) || /^blob:/i.test(c)) continue;
      if (/^data:/i.test(c) && c.length < 400) continue;
      return abs(c);
    }
    return '';
  }
  function abs(u) {
    try { return new URL(u, location.href).toString(); } catch (e) { return u; }
  }
  // next/image wraps the real CDN URL in /_next/image?url=ENCODED&w=..; the
  // wrapper is a *downscaled* copy, so prefer the original.
  function unwrapNextImage(u) {
    try {
      if (/\/_next\/image/.test(u)) {
        var q = new URL(u, location.href).searchParams.get('url');
        if (q) return abs(q);
      }
    } catch (e) {}
    return u;
  }
  function bgImageOf(el) {
    try {
      var all = [el].concat([].slice.call(el.querySelectorAll('*'), 0, 60));
      var best = '', ba = 0;
      for (var i = 0; i < all.length; i++) {
        var bg = getComputedStyle(all[i]).backgroundImage;
        if (bg && bg !== 'none') {
          var m = /url\((['"]?)(.*?)\1\)/.exec(bg);
          if (m && m[2] && !/^data:image\/svg/.test(m[2])) {
            var r = all[i].getBoundingClientRect();
            if (r.width * r.height >= ba) { ba = r.width * r.height; best = abs(m[2]); }
          }
        }
      }
      return best;
    } catch (e) { return ''; }
  }
  function lookupRaw(id, href) {
    var r = S.raw.get(id);
    if (r) return r;
    var m = CHAR_RE.exec(href || '');
    if (m && S.raw.get(m[1])) return S.raw.get(m[1]);
    return null;
  }

  function scanCards() {
    var anchors = [].slice.call(document.querySelectorAll('a[href]')).filter(function (a) {
      return idFromHref(a.getAttribute('href')) && !inLandmark(a) && visible(a);
    });
    if (!anchors.length) return [];
    var idCache = new Map();
    function idsIn(el) {
      var c = idCache.get(el);
      if (c) return c;
      var set = new Set();
      var as = el.querySelectorAll ? el.querySelectorAll('a[href]') : [];
      for (var i = 0; i < as.length; i++) {
        var id = idFromHref(as[i].getAttribute('href'));
        if (id) set.add(id);
      }
      idCache.set(el, set);
      return set;
    }
    var cardOf = new Map(); // cardEl -> {id, a}
    anchors.forEach(function (a) {
      var id = idFromHref(a.getAttribute('href'));
      var el = a;
      while (el.parentElement && el.parentElement !== document.body && el.parentElement !== document.documentElement) {
        var p = el.parentElement;
        if (idsIn(p).size > 1) break;
        el = p;
      }
      if (!cardOf.has(el)) cardOf.set(el, { id: id, a: a });
    });
    // group cards by parent: the feed is the biggest group.
    var groups = new Map();
    cardOf.forEach(function (v, el) {
      var p = el.parentElement;
      if (!groups.has(p)) groups.set(p, []);
      groups.get(p).push(el);
    });
    var bestP = null, bestN = -1, bestArea = -1;
    groups.forEach(function (els, p) {
      var area = 0;
      els.forEach(function (e) { var r = e.getBoundingClientRect(); area += r.width * r.height; });
      if (els.length > bestN || (els.length === bestN && area > bestArea)) { bestN = els.length; bestArea = area; bestP = p; }
    });
    S.parent = bestP;
    var cards = groups.get(bestP) || [];
    cards.sort(function (x, y) {
      if (x === y) return 0;
      var pos = x.compareDocumentPosition(y);
      return (pos & 4) ? -1 : 1; // x precedes y
    });
    var out = [];
    var seen = new Set();
    cards.forEach(function (el) {
      var meta = cardOf.get(el);
      if (!meta || seen.has(meta.id)) return;
      seen.add(meta.id);
      out.push(describeCard(el, meta));
    });
    return out;
  }


  // Daily Ranking cards carry a badge in the top-left corner of the art: a crown
  // or "#", the position, then "Debut!" or an arrow with the places gained/lost.
  function badgeText(el) {
    var out = [];
    try {
      var w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      var n;
      while ((n = w.nextNode())) { var t = n.nodeValue.replace(/\s+/g, ' ').trim(); if (t) out.push(t); }
    } catch (e) {}
    return out.join(' ');
  }
  function rankBadgeOf(card) {
    var cr = card.getBoundingClientRect();
    if (!cr.width) return null;
    var best = null, bestA = -1;
    var nodes = card.querySelectorAll('div,span,p,b,strong,i');
    for (var i = 0; i < nodes.length && i < 500; i++) {
      var n = nodes[i];
      var r = n.getBoundingClientRect();
      if (r.width < 8 || r.width > cr.width * 0.7 || r.height < 8 || r.height > 64) continue;
      if (r.left - cr.left > 48 || r.top - cr.top > 48) continue;      // hugs the top-left corner
      var m = /^#?\s*(\d{1,4})(?:\s+(debut!?|\d{1,3}))?$/i.exec(badgeText(n));
      if (!m) continue;
      var a = r.width * r.height;      // the badge container, not just its number
      if (a <= bestA) continue;
      bestA = a;
      var note = '';
      if (m[2]) {
        if (/^debut/i.test(m[2])) note = 'Debut!';
        else {
          var down = /(down|decreas|fall|\u2193|\u2198|rotate\(\s*(90|-?270)|rotate-90)/i.test(n.innerHTML || '');
          note = (down ? '\u2193' : '\u2191') + m[2];
        }
      }
      best = { rank: parseInt(m[1], 10), note: note };
    }
    return best;
  }

  function describeCard(el, meta) {
    var href = meta.a.getAttribute('href');
    var imgs = [].slice.call(el.querySelectorAll('img'));
    var bestImg = null, ba = -1;
    imgs.forEach(function (im) {
      var r = im.getBoundingClientRect();
      var a = r.width * r.height;
      if (a > ba) { ba = a; bestImg = im; }
    });
    var src = '', box = null, fit = '', pos = '', nat = null;
    if (bestImg) {
      src = unwrapNextImage(bestImg.currentSrc ? bestSrcFromImg(bestImg) : bestSrcFromImg(bestImg));
      var r = bestImg.getBoundingClientRect();
      box = [Math.round(r.width), Math.round(r.height)];
      try {
        var cs = getComputedStyle(bestImg);
        fit = cs.objectFit || '';
        pos = cs.objectPosition || '';
      } catch (e) {}
      if (bestImg.naturalWidth) nat = [bestImg.naturalWidth, bestImg.naturalHeight];
    }
    if (!src) {
      var bg = bgImageOf(el);
      if (bg) {
        src = unwrapNextImage(bg);
        var rr = el.getBoundingClientRect();
        box = box || [Math.round(rr.width), Math.round(rr.height)];
        fit = fit || 'cover';
      }
    }
    var vid = el.querySelector('video');
    if (!src && vid && vid.poster) src = abs(vid.poster);

    var name = '';
    var raw = lookupRaw(meta.id, href);
    if (raw) name = String(raw.name || raw.characterName || raw.title || '');
    if (!name) {
      var h = el.querySelector('h1,h2,h3,h4,h5,[class*="name" i],[class*="title" i]');
      if (h) name = ownText(h);
    }
    if (!name && bestImg && bestImg.alt) name = bestImg.alt;
    if (!name) name = meta.a.getAttribute('title') || meta.a.getAttribute('aria-label') || '';
    if (!name) name = (ownText(el).split('\n')[0] || '').slice(0, 80);
    var rb = rankBadgeOf(el);
    return {
      id: meta.id, href: href, name: name, img: src,
      box: box, fit: fit, pos: pos, nat: nat, _el: el,
      rank: rb ? rb.rank : null, rankNote: rb ? rb.note : ''
    };
  }

  function mergeScan(cards) {
    var prevIdx = -1, added = 0;
    for (var i = 0; i < cards.length; i++) {
      var c = cards[i];
      S.els.set(c.id, c._el);
      var ex = S.map.get(c.id);
      if (ex) {
        if (!ex.img && c.img) ex.img = c.img;
        if ((!ex.name || ex.name.length < 2) && c.name) ex.name = c.name;
        if (c.box && (!ex.box || c.box[0] * c.box[1] > ex.box[0] * ex.box[1])) { ex.box = c.box; ex.fit = c.fit; ex.pos = c.pos; }
        if (c.nat && !ex.nat) ex.nat = c.nat;
        if (c.rank && !ex.rank) { ex.rank = c.rank; ex.rankNote = c.rankNote; }
        prevIdx = S.feed.indexOf(ex);
        continue;
      }
      var rec = { id: c.id, href: c.href, name: c.name, img: c.img, box: c.box, fit: c.fit, pos: c.pos, nat: c.nat, rank: c.rank || null, rankNote: c.rankNote || '' };
      var idx = prevIdx + 1;
      if (prevIdx === -1 && S.feed.length > 0) {
        var later = -1;
        for (var j = i + 1; j < cards.length; j++) {
          var e2 = S.map.get(cards[j].id);
          if (e2) { later = S.feed.indexOf(e2); break; }
        }
        idx = later >= 0 ? later : S.feed.length;
      }
      S.feed.splice(idx, 0, rec);
      S.map.set(rec.id, rec);
      prevIdx = idx;
      added++;
    }
    return added;
  }
  function scan() { return mergeScan(scanCards()); }

  // ---------------------------------------------------------------- scrolling
  function getScroller() {
    if (!S.parent && S.scrollEl && S.scrollEl.isConnected) return S.scrollEl;
    var el = S.parent;
    while (el && el !== document.body && el !== document.documentElement) {
      var cs;
      try { cs = getComputedStyle(el); } catch (e) { break; }
      if (/(auto|scroll|overlay)/.test(cs.overflowY) && el.scrollHeight > el.clientHeight + 40) { S.scrollEl = el; return el; }
      el = el.parentElement;
    }
    if (S.parent) S.scrollEl = null;
    return document.scrollingElement || document.documentElement;
  }
  function isRoot(sc) { return sc === document.scrollingElement || sc === document.documentElement || sc === document.body; }
  function scrollTop0() {
    var sc = getScroller();
    if (isRoot(sc)) window.scrollTo(0, 0); else sc.scrollTop = 0;
  }
  function fire(el, type) { try { el.dispatchEvent(new Event(type, { bubbles: true })); } catch (e) {} }
  function scrollDown() {
    var sc = getScroller();
    var lastId = S.feed.length ? S.feed[S.feed.length - 1].id : null;
    var lastEl = lastId ? S.els.get(lastId) : null;
    try { if (lastEl && lastEl.isConnected) lastEl.scrollIntoView({ block: 'end' }); } catch (e) {}
    if (isRoot(sc)) {
      window.scrollTo(0, Math.max(document.documentElement.scrollHeight, document.body.scrollHeight));
      fire(window, 'scroll');
    } else {
      sc.scrollTop = sc.scrollHeight;
      fire(sc, 'scroll');
    }
  }
  async function jiggle() {
    var sc = getScroller();
    if (isRoot(sc)) { window.scrollBy(0, -700); fire(window, 'scroll'); } else { sc.scrollTop = Math.max(0, sc.scrollTop - 700); fire(sc, 'scroll'); }
    await sleep(250);
    scrollDown();
  }

  // A virtualized list only keeps the rows near the viewport in the DOM, so a
  // jump to the bottom would skip everything in between. Detect it (rows we
  // already recorded have been detached) and switch to small, overlapping steps.
  function looksVirtual() {
    if (S.feed.length < 6) return false;
    var current = new Set(scanCards().map(function (c) { return c.id; }));
    var detached = 0, checked = 0;
    for (var i = 0; i < Math.min(8, S.feed.length); i++) {
      var id = S.feed[i].id, el = S.els.get(id);
      checked++;
      if (!current.has(id) && el && !el.isConnected) detached++;
    }
    return checked > 0 && detached >= Math.min(3, checked);
  }
  function stepDown(frac) {
    var sc = getScroller();
    var h = isRoot(sc) ? window.innerHeight : sc.clientHeight;
    var dy = Math.max(120, Math.round(h * frac));
    if (isRoot(sc)) { window.scrollBy(0, dy); fire(window, 'scroll'); }
    else { sc.scrollTop = sc.scrollTop + dy; fire(sc, 'scroll'); }
  }
  function atBottom() {
    var sc = getScroller();
    if (isRoot(sc)) return window.innerHeight + window.scrollY >= Math.max(document.documentElement.scrollHeight, document.body.scrollHeight) - 4;
    return sc.scrollTop + sc.clientHeight >= sc.scrollHeight - 4;
  }
  async function stepPump(target, deadline) {
    // Continue downward from the current position in overlapping steps.
    var stuck = 0;
    while (S.feed.length < target && Date.now() < deadline && !S.exhausted) {
      var before = S.feed.length, bn = S.netSeq, wasBottom = atBottom();
      stepDown(0.7);
      await sleep(190);
      scan();
      // overlap guard: if nothing we see is already known we may have skipped rows
      var cur = scanCards();
      if (S.feed.length && cur.length && !cur.some(function (c) { return S.map.has(c.id) && S.feed.indexOf(S.map.get(c.id)) >= S.feed.length - 40; }) && S.feed.length === before) {
        var sc2 = getScroller();
        if (isRoot(sc2)) window.scrollBy(0, -Math.round(window.innerHeight * 0.45)); else sc2.scrollTop = Math.max(0, sc2.scrollTop - Math.round(sc2.clientHeight * 0.45));
        await sleep(190); scan();
      }
      if (S.feed.length > before) { stuck = 0; continue; }
      if (wasBottom || atBottom()) {
        // at the end of what is loaded: give the site time to fetch more
        await waitGrowth(before, bn, 3200);
        if (S.feed.length > before) { stuck = 0; continue; }
        stuck++;
        if (stuck === 1) await jiggle();
        if (stuck >= 3) { S.exhausted = true; log('exhausted (virtual) at ' + S.feed.length); }
      } else {
        stuck++;
        if (stuck > 12) { S.exhausted = true; }
      }
    }
  }

  async function waitGrowth(before, beforeNet, timeout) {
    var t0 = Date.now();
    while (Date.now() - t0 < timeout) {
      await sleep(160);
      scan();
      if (S.feed.length > before) { await sleep(120); scan(); return true; }
      if (S.netSeq !== beforeNet && Date.now() - S.lastNetAt > 450) {
        await sleep(200); scan();
        if (S.feed.length > before) return true;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------- overlays
  function dismissOverlays() {
    var clicked = 0;
    try {
      var layers = [].slice.call(document.querySelectorAll(
        '[role=dialog],[aria-modal=true],[class*="modal" i],[class*="dialog" i],[class*="popup" i],[class*="overlay" i],[class*="gift" i]'));
      layers.forEach(function (layer) {
        if (!visible(layer)) return;
        if (layer.querySelector('[role=option],[role=menuitem],[role=listbox],[role=menu],[role=menuitemradio]')) return;
        var role = layer.getAttribute('role');
        if (role === 'menu' || role === 'listbox' || role === 'tooltip') return;
        var cs = getComputedStyle(layer), r = layer.getBoundingClientRect();
        var coverage = (r.width * r.height) / Math.max(1, innerWidth * innerHeight);
        var floating = cs.position === 'fixed' || cs.position === 'absolute' || role === 'dialog' || layer.getAttribute('aria-modal') === 'true';
        if (!floating || coverage < 0.12) return;
        if (layer.querySelectorAll('a[href*="/character/"]').length > 3) return;
        var btns = [].slice.call(layer.querySelectorAll('button,[role=button],a'));
        var closer = btns.find(function (b) {
          var t = norm(ownText(b)), al = norm(b.getAttribute('aria-label') || '');
          return /^(close|skip|no thanks|maybe later|not now|got it|dismiss|later|cancel|continue as guest|x)$/.test(t) ||
            /^(close|dismiss)$/.test(al) || ownText(b) === '\u00D7' || ownText(b) === '\u2715';
        });
        var txt = norm(ownText(layer));
        if (!closer && /(over 18|18 years|age verification|adult)/.test(txt)) {
          closer = btns.find(function (b) { return /^(i am over 18|im over 18|i am 18|enter|i agree|yes|confirm|continue)/.test(norm(ownText(b))); });
        }
        if (!closer && /(cookie|consent|privacy)/.test(txt)) {
          closer = btns.find(function (b) { return /^(accept all|accept|agree|allow all|ok|got it)$/.test(norm(ownText(b))); });
        }
        if (closer) { realClick(closer); clicked++; }
      });
    } catch (e) {}
    if (clicked) log('dismissed ' + clicked + ' overlay(s)');
    return clicked;
  }

  // ---------------------------------------------------------------- clicking
  function realClick(el) {
    if (!el) return false;
    if (externalAnchorOf(el)) { log('refused to click an external link'); return false; }
    try { el.scrollIntoView({ block: 'center', inline: 'center' }); } catch (e) {}
    var r = el.getBoundingClientRect();
    var x = r.left + r.width / 2, y = r.top + r.height / 2;
    var P = window.PointerEvent || MouseEvent;
    function mk(type, C, buttons, extra) {
      var init = { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, button: 0, buttons: buttons };
      if (extra) for (var k in extra) init[k] = extra[k];
      try { el.dispatchEvent(new C(type, init)); } catch (e) {}
    }
    var pe = { pointerType: 'mouse', isPrimary: true, pointerId: 1 };
    mk('pointerover', P, 0, pe); mk('mouseover', MouseEvent, 0);
    mk('pointerdown', P, 1, pe); mk('mousedown', MouseEvent, 1);
    try { if (el.focus) el.focus({ preventScroll: true }); } catch (e) {}
    mk('pointerup', P, 0, pe); mk('mouseup', MouseEvent, 0);
    mk('click', MouseEvent, 0);
    return true;
  }
  function isControl(el) {
    var role = el.getAttribute && el.getAttribute('role');
    var tag = (el.tagName || '').toLowerCase();
    return /^(button|a|select|summary|label|input)$/.test(tag) ||
      /^(option|menuitem|menuitemradio|menuitemcheckbox|button|tab|switch|radio|checkbox|combobox)$/.test(role || '') ||
      !!(el.getAttribute && el.getAttribute('aria-haspopup'));
  }
  function clickableAncestor(el) {
    if (el && !isControl(el) && el.querySelectorAll) {
      var inner = [].slice.call(el.querySelectorAll('button,[role=button],[role=tab],[role=switch],a[href],[aria-haspopup]')).filter(visible);
      if (inner.length === 1) return inner[0];
    }
    var cur = el;
    for (var i = 0; i < 6 && cur; i++) {
      var role = cur.getAttribute && cur.getAttribute('role');
      var tag = (cur.tagName || '').toLowerCase();
      if (/^(button|a|li|label|summary)$/.test(tag) || /^(option|menuitem|menuitemradio|menuitemcheckbox|button|tab|switch|radio|checkbox)$/.test(role || '')) return cur;
      if (cur.onclick || (getComputedStyle(cur).cursor === 'pointer')) return cur;
      cur = cur.parentElement;
    }
    return el;
  }
  function inCard(el) {
    var a = el.closest && el.closest('a[href]');
    return !!(a && idFromHref(a.getAttribute('href')));
  }
  function setNativeValue(input, value) {
    var tag = (input.tagName || '').toUpperCase();
    var proto = tag === 'TEXTAREA' ? HTMLTextAreaElement.prototype
      : tag === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
    setter.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // All visible elements whose own text normalises to one of `labels`.
  function findByText(labels, opts) {
    opts = opts || {};
    var want = labels.map(norm);
    var sel = opts.selector || 'button,[role=button],[role=option],[role=menuitem],[role=menuitemradio],[role=tab],[role=combobox],[aria-haspopup],li,a,label,div,span,p';
    var out = [];
    [].slice.call(document.querySelectorAll(sel)).forEach(function (el) {
      if (!visible(el) || inCard(el)) return;
      var t = norm(ownText(el));
      if (!t || t.length > 40) return;
      if (want.indexOf(t) >= 0) out.push(el);
    });
    // keep only the deepest match of any ancestor chain
    return out.filter(function (el) {
      return !out.some(function (o) { return o !== el && el.contains(o); });
    });
  }

  // ---------------------------------------------------------------- sort
  var SORT_ALIASES = {
    'popular': ['popular', 'most popular'],
    'recent_hits': ['recent hits', 'recent hit', 'recent'],
    'trending': ['trending'],
    'new': ['new', 'newest', 'latest'],
    'daily_ranking': ['daily ranking', 'daily rank', 'daily'],
    'editor_choice': ['editors choice', 'editor choice', 'editors pick', 'editors'],
    'following': ['following']
  };
  var ALL_SORT_LABELS = [];
  Object.keys(SORT_ALIASES).forEach(function (k) { ALL_SORT_LABELS = ALL_SORT_LABELS.concat(SORT_ALIASES[k]); });

  function topFirst(a, b) { return a.getBoundingClientRect().top - b.getBoundingClientRect().top; }

  function findSortTrigger() {
    var sels = document.querySelectorAll('select');
    for (var i = 0; i < sels.length; i++) {
      if (!visible(sels[i])) continue;
      var opts = [].slice.call(sels[i].options).map(function (o) { return norm(o.text); });
      if (opts.filter(function (o) { return ALL_SORT_LABELS.indexOf(o) >= 0; }).length >= 2) return { kind: 'select', el: sels[i] };
    }
    var els = findByText(ALL_SORT_LABELS).filter(function (el) {
      // not an option inside an open list
      return !el.closest('[role=listbox],[role=menu],[data-radix-popper-content-wrapper]');
    });
    els.sort(topFirst);
    for (var j = 0; j < els.length; j++) {
      var c = clickableAncestor(els[j]);
      if (c && visible(c)) return { kind: 'click', el: c, label: ownText(els[j]) };
    }
    return null;
  }
  function currentSortKey() {
    var t = findSortTrigger();
    if (!t) return null;
    var label = t.kind === 'select' ? t.el.options[t.el.selectedIndex].text : (t.label || ownText(t.el));
    var n = norm(label);
    for (var k in SORT_ALIASES) if (SORT_ALIASES[k].indexOf(n) >= 0) return { key: k, label: label };
    return { key: null, label: label };
  }
  function discoverSortOptions() {
    var found = [];
    var cands = [].slice.call(document.querySelectorAll('[role=option],[role=menuitem],[role=menuitemradio],[role=listbox] *,[role=menu] *,[data-radix-popper-content-wrapper] *,li'));
    cands.forEach(function (el) {
      if (!visible(el)) return;
      var t = norm(ownText(el));
      if (ALL_SORT_LABELS.indexOf(t) >= 0 && found.indexOf(ownText(el)) < 0) found.push(ownText(el));
    });
    return found;
  }

  async function applySort(key) {
    var aliases = SORT_ALIASES[key] || [norm(key)];
    var steps = [];
    dismissOverlays();
    var trig = findSortTrigger();
    if (!trig) {
      steps.push('no sort control found');
      return { ok: false, reason: 'no-sort-control', steps: steps, controls: describeControls() };
    }
    var cur = currentSortKey();
    steps.push('current=' + (cur && cur.label));
    if (cur && cur.key === key) return { ok: true, label: cur.label, changed: false, steps: steps };

    if (trig.kind === 'select') {
      var sel = trig.el, idx = -1;
      for (var i = 0; i < sel.options.length; i++) if (aliases.indexOf(norm(sel.options[i].text)) >= 0) idx = i;
      if (idx < 0) return { ok: false, reason: 'option-missing', steps: steps };
      markAction();
      setNativeValue(sel, sel.options[idx].value);
      steps.push('select -> ' + sel.options[idx].text);
      return { ok: true, label: sel.options[idx].text, changed: true, steps: steps };
    }

    var optionEl = null;
    function lookOption() {
      var matches = findByText(aliases).filter(function (el) { return el !== trig.el && !trig.el.contains(el) && !el.contains(trig.el); });
      // prefer ones inside a popup/list
      var inPop = matches.filter(function (el) { return el.closest('[role=listbox],[role=menu],[data-radix-popper-content-wrapper],[class*="dropdown" i],[class*="menu" i],[class*="popover" i],[class*="select" i]'); });
      return (inPop[0] || matches[0]) || null;
    }
    for (var attempt = 0; attempt < 3 && !optionEl; attempt++) {
      if (attempt === 0) realClick(trig.el);
      else if (attempt === 1) { try { trig.el.click(); } catch (e) {} }
      else {
        try { trig.el.focus(); } catch (e) {}
        ['keydown', 'keyup'].forEach(function (t) { trig.el.dispatchEvent(new KeyboardEvent(t, { key: 'ArrowDown', code: 'ArrowDown', bubbles: true })); });
      }
      for (var w = 0; w < 8 && !optionEl; w++) { await sleep(120); optionEl = lookOption(); }
      steps.push('open attempt ' + attempt + (optionEl ? ' ok' : ' no-option'));
    }
    if (!optionEl) {
      return { ok: false, reason: 'option-not-found', steps: steps, options: discoverSortOptions(), controls: describeControls() };
    }
    var options = discoverSortOptions();
    var target = clickableAncestor(optionEl);
    markAction();
    realClick(target);
    steps.push('clicked ' + ownText(optionEl));
    await sleep(250);
    return { ok: true, label: ownText(optionEl), changed: true, steps: steps, options: options };
  }

  // after any UI action: wait until the feed visibly changes and goes quiet.
  function sigNow() {
    var cs = scanCards();
    return cs.slice(0, 8).map(function (c) { return c.id; }).join(',');
  }
  async function settle(prevSig, maxMs) {
    var t0 = Date.now(), changed = false;
    while (Date.now() - t0 < maxMs) {
      await sleep(200);
      var s = sigNow();
      if (s && s !== prevSig) { changed = true; }
      var quiet = Date.now() - S.lastNetAt > 700;
      if (changed && quiet) { await sleep(300); return { changed: true }; }
    }
    return { changed: changed };
  }

  // ---------------------------------------------------------------- date
  var MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function isoOf(y, m, d) { return y + '-' + pad(m) + '-' + pad(d); }
  function inferYear(m, d) {
    var now = new Date(), y = now.getFullYear();
    if (new Date(y, m - 1, d).getTime() > now.getTime() + 86400000 * 2) y -= 1;
    return y;
  }
  function parseDateText(t) {
    t = String(t || '');
    var m = /(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})/.exec(t);
    if (m) return isoOf(+m[1], +m[2], +m[3]);
    var mon = '(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?';
    m = new RegExp('\\b' + mon + '\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s+(\\d{4}))?', 'i').exec(t);
    if (m) { var mi = MONTHS.indexOf(m[1].toLowerCase()) + 1; return isoOf(m[3] ? +m[3] : inferYear(mi, +m[2]), mi, +m[2]); }
    m = new RegExp('\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+' + mon + '(?:,?\\s+(\\d{4}))?', 'i').exec(t);
    if (m) { var mj = MONTHS.indexOf(m[2].toLowerCase()) + 1; return isoOf(m[3] ? +m[3] : inferYear(mj, +m[1]), mj, +m[1]); }
    m = /\b(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?\b/.exec(t);
    if (m && +m[1] <= 12 && +m[2] <= 31) { var yy = m[3] ? (+m[3] < 100 ? 2000 + +m[3] : +m[3]) : inferYear(+m[1], +m[2]); return isoOf(yy, +m[1], +m[2]); }
    return null;
  }
  function findDateControl() {
    var inputs = [].slice.call(document.querySelectorAll('input[type=date]'));
    if (inputs.length) return { kind: 'native', el: inputs[0] };
    var cands = [].slice.call(document.querySelectorAll('button,[role=button],[aria-haspopup],div,span,a,input'));
    var hits = [];
    cands.forEach(function (el) {
      if (!visible(el) || inCard(el) || el.closest('[role=dialog],[role=grid],table')) return;
      var t = el.tagName === 'INPUT' ? el.value : ownText(el);
      if (!t || t.length > 28) return;
      if (parseDateText(t)) hits.push(el);
    });
    if (!hits.length) {
      var byAria = [].slice.call(document.querySelectorAll('[aria-label*="calendar" i],[aria-label*="date" i],[aria-label*="day" i]')).filter(function (e) { return visible(e) && !inCard(e); });
      if (byAria.length) return { kind: 'click', el: clickableAncestor(byAria[0]), label: ownText(byAria[0]) };
      return null;
    }
    hits.sort(function (a, b) {
      var ca = isControl(a) ? 0 : 1, cb = isControl(b) ? 0 : 1;
      if (ca !== cb) return ca - cb;
      return a.getBoundingClientRect().width * a.getBoundingClientRect().height - b.getBoundingClientRect().width * b.getBoundingClientRect().height;
    });
    var el = hits[0];
    return { kind: 'click', el: clickableAncestor(el), label: el.tagName === 'INPUT' ? el.value : ownText(el) };
  }
  function readDate() {
    var c = findDateControl();
    if (!c) return { has: false };
    if (c.kind === 'native') {
      return { has: true, kind: 'native', label: c.el.value || '', iso: c.el.value || null, min: c.el.min || null, max: c.el.max || null };
    }
    return { has: true, kind: 'click', label: c.label || '', iso: parseDateText(c.label) };
  }
  // ---- calendar popup: found by CONTENT (weekday header + day numbers), not by
  // class/role, because the site's popup has neither role=dialog nor role=grid
  // and prints month ("OCT") and year ("2026") as separate pieces.
  var MONTH_FULL = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];
  function countNumCells(el) {
    var n = 0, els = el.querySelectorAll('button,td,[role=gridcell],[role=button],div,span,li,p');
    for (var i = 0; i < els.length && i < 400; i++) { if (/^\d{1,2}$/.test(ownText(els[i])) && !els[i].querySelector('button,td,[role=gridcell]')) n++; }
    return n;
  }
  function findCalendarRoot() {
    var best = null, bestArea = Infinity;
    var all = [].slice.call(document.querySelectorAll('div,section,aside,table,[role=dialog],[role=grid]'));
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (!visible(el) || el.closest('a[href]')) continue;
      var t = '';
      try { t = (el.innerText || '').toLowerCase(); } catch (e) { continue; }
      if (t.length < 40 || t.length > 1200) continue;
      if (t.indexOf('sun') < 0 || t.indexOf('mon') < 0 || t.indexOf('wed') < 0 || t.indexOf('fri') < 0 || t.indexOf('sat') < 0) continue;
      var r = el.getBoundingClientRect(), area = r.width * r.height;
      if (area >= bestArea) continue;
      if (countNumCells(el) < 28) continue;
      best = el; bestArea = area;
    }
    if (!best) {
      var legacy = [].slice.call(document.querySelectorAll('[role=dialog],[role=grid],.react-datepicker,.rdp,[class*="calendar" i],[class*="datepicker" i],[class*="date-picker" i]')).filter(function (e) {
        return visible(e) && countNumCells(e) >= 28;
      });
      legacy.sort(function (a, b) { return a.getBoundingClientRect().width * a.getBoundingClientRect().height - b.getBoundingClientRect().width * b.getBoundingClientRect().height; });
      best = legacy[0] || null;
    }
    // The smallest match is often just the day grid; the month/year header and
    // the prev/next buttons are siblings, so climb until the header is inside.
    var cur = best;
    for (var k = 0; k < 4 && cur && !monthYearOfRoot(cur); k++) {
      var up = cur.parentElement;
      if (!up || up === document.body || (up.innerText || '').length > 900) break;
      cur = up;
    }
    return cur || best;
  }
  function monthYearOfRoot(root) {
    var t = '';
    try { t = root.innerText || ''; } catch (e) {}
    var head = t.split(/\b(sun|mon)\b/i)[0] || t;
    var mm = /\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b/i.exec(head);
    var yy = /\b(19|20)\d{2}\b/.exec(head);
    if (!mm || !yy) return null;
    return { y: +yy[0], m: MONTHS.indexOf(mm[1].toLowerCase()) + 1 };
  }
  function struck(el, root) {
    var cur = el;
    for (var i = 0; i < 4 && cur && cur !== root.parentElement; i++) {
      var cs;
      try { cs = getComputedStyle(cur); } catch (e) { break; }
      if (/line-through/.test(cs.textDecorationLine || cs.textDecoration || '')) return true;
      if (cur.getAttribute && (cur.getAttribute('aria-disabled') === 'true' || cur.disabled)) return true;
      if (/(disabled|unavailable)/i.test(String(cur.className || ''))) return true;
      cur = cur.parentElement;
    }
    return false;
  }
  // Day cells of the MONTH shown (previous/next month filler cells are removed
  // by order: the shown month is the ascending run that starts at 1).
  function dayCells(root) {
    var els = [].slice.call(root.querySelectorAll('button,[role=gridcell],td,[role=button],div,span,li,p'));
    var cells = [];
    els.forEach(function (el) {
      if (!visible(el)) return;
      var t = ownText(el);
      if (!/^\d{1,2}$/.test(t)) return;
      if (el.querySelector('button,td,[role=gridcell]')) return;
      // keep the outermost element that has exactly this text (the clickable one)
      var p = el.parentElement;
      if (p && p !== root && ownText(p) === t && visible(p)) return;
      cells.push({ el: el, d: +t });
    });
    cells.sort(function (a, b) {
      var ra = a.el.getBoundingClientRect(), rb = b.el.getBoundingClientRect();
      return (Math.round(ra.top / 6) - Math.round(rb.top / 6)) || (ra.left - rb.left);
    });
    var start = -1;
    for (var i = 0; i < cells.length; i++) { if (cells[i].d === 1) { start = i; break; } }
    if (start < 0) return [];
    var out = [], prev = 0;
    for (var j = start; j < cells.length; j++) {
      if (cells[j].d !== prev + 1) break;
      prev = cells[j].d;
      out.push({ el: cells[j].el, d: cells[j].d, off: struck(cells[j].el, root) });
    }
    return out;
  }
  function calendarNav(root) {
    var hdr = null;
    var all = [].slice.call(root.querySelectorAll('*'));
    var wk = all.filter(function (e) { return /^(sun|su)$/i.test(ownText(e)); })[0];
    var wkTop = wk ? wk.getBoundingClientRect().top : root.getBoundingClientRect().top + 90;
    var cands = [].slice.call(root.querySelectorAll('button,[role=button],svg,a,div,span')).filter(function (e) {
      if (!visible(e)) return false;
      var r = e.getBoundingClientRect();
      if (r.bottom > wkTop + 2 || r.width > 80 || r.height > 80) return false;
      if (/\d/.test(ownText(e)) && ownText(e).length > 2) return false;
      return !!e.querySelector('svg') || e.tagName.toLowerCase() === 'svg' || /^(button)$/i.test(e.tagName) || /^[<>‹›«»←→]$/.test(ownText(e)) || /(prev|next|chevron|arrow)/i.test(String(e.className && e.className.baseVal != null ? e.className.baseVal : e.className) + (e.getAttribute('aria-label') || ''));
    }).map(function (e) { return e.tagName.toLowerCase() === 'svg' ? clickableAncestor(e) : e; });
    var seen = [];
    cands = cands.filter(function (e) { if (seen.indexOf(e) >= 0) return false; seen.push(e); return true; });
    if (cands.length < 2) return { prev: null, next: null };
    cands.sort(function (a, b) { return a.getBoundingClientRect().left - b.getBoundingClientRect().left; });
    return { prev: cands[0], next: cands[cands.length - 1] };
  }
  async function openCalendar() {
    var c = findDateControl();
    if (!c || c.kind === 'native') return { c: c, root: null };
    var root = findCalendarRoot();
    if (!root) {
      realClick(c.el);
      for (var i = 0; i < 12 && !root; i++) { await sleep(150); root = findCalendarRoot(); }
    }
    return { c: c, root: root };
  }
  async function closeCalendar(c) {
    var root = findCalendarRoot();
    if (!root) return;
    var confirm = [].slice.call(root.querySelectorAll('button')).find(function (b) { return /^(ok|apply|done|confirm|close)$/.test(norm(ownText(b))); });
    if (confirm) { realClick(confirm); await sleep(150); }
    if (findCalendarRoot()) {
      ['keydown', 'keyup'].forEach(function (t) { document.dispatchEvent(new KeyboardEvent(t, { key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true })); });
      await sleep(150);
    }
    if (findCalendarRoot() && c && c.el) { realClick(c.el); await sleep(150); }
  }
  // Range of days the site allows: enabled days of the month it shows, plus a
  // look at neighbouring months (limited steps) so min/max are real dates.
  async function readDateRange() {
    var d = readDate();
    if (!d.has || d.kind === 'native') return d;
    var o = await openCalendar();
    if (!o.root) return { has: true, kind: 'click', label: d.label, iso: d.iso, rangeError: 'calendar-not-found' };
    var root = o.root, min = null, max = null;
    async function scanMonth() {
      var hdr = monthYearOfRoot(root);
      if (!hdr) return null;
      var cells = dayCells(root), en = cells.filter(function (x) { return !x.off; });
      if (en.length) {
        var lo = isoOf(hdr.y, hdr.m, en[0].d), hi = isoOf(hdr.y, hdr.m, en[en.length - 1].d);
        if (!min || lo < min) min = lo;
        if (!max || hi > max) max = hi;
      }
      return { hdr: hdr, enabled: en.length, total: cells.length };
    }
    var cur = await scanMonth();
    // newest month first: if the shown month has days after the last enabled one
    // they are struck, so max is known. Check next month only when the whole
    // month is enabled.
    if (cur && cur.enabled === cur.total && cur.total > 0) {
      var nav = calendarNav(root);
      for (var i = 0; i < 3 && nav.next; i++) {
        realClick(nav.next); await sleep(220);
        root = findCalendarRoot() || root;
        var s = await scanMonth();
        if (!s || !s.enabled) break;
        if (s.enabled < s.total) break;
        nav = calendarNav(root);
      }
    }
    // earliest: only walk back a few months while a month is fully enabled
    await closeCalendar(o.c);
    return { has: true, kind: 'click', label: d.label, iso: d.iso, min: min, max: max };
  }
  async function applyDate(iso) {
    var parts = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso || '');
    if (!parts) return { ok: false, reason: 'bad-date' };
    var Y = +parts[1], M = +parts[2], D = +parts[3];
    var c = findDateControl();
    if (!c) return { ok: false, reason: 'no-date-control' };
    if (c.kind === 'native') {
      if ((c.el.min && iso < c.el.min) || (c.el.max && iso > c.el.max)) return { ok: false, reason: 'out-of-range', min: c.el.min, max: c.el.max };
      markAction();
      setNativeValue(c.el, iso);
      return { ok: true, kind: 'native' };
    }
    if (parseDateText(c.label) === iso) return { ok: true, kind: 'click', unchanged: true };
    var o = await openCalendar();
    var root = o.root;
    if (!root) return { ok: false, reason: 'calendar-not-found' };
    for (var step = 0; step < 36; step++) {
      root = findCalendarRoot() || root;
      var hdr = monthYearOfRoot(root);
      if (hdr && (hdr.y !== Y || hdr.m !== M)) {
        var wantBack = (hdr.y * 12 + hdr.m) > (Y * 12 + M);
        var nav = calendarNav(root);
        var btn = wantBack ? nav.prev : nav.next;
        if (!btn) return { ok: false, reason: 'no-month-nav' };
        realClick(btn); await sleep(220); continue;
      }
      var cells = dayCells(root);
      var cell = cells.filter(function (x) { return x.d === D; })[0];
      if (!cell) return { ok: false, reason: 'day-not-found' };
      if (cell.off) { await closeCalendar(c); return { ok: false, reason: 'day-unavailable' }; }
      markAction();
      realClick(clickableAncestor(cell.el));
      await sleep(300);
      var confirm = findCalendarRoot() && [].slice.call(findCalendarRoot().querySelectorAll('button')).find(function (b) { return /^(ok|apply|done|confirm|select)$/.test(norm(ownText(b))); });
      if (confirm) realClick(confirm);
      await sleep(200);
      if (findCalendarRoot()) await closeCalendar(c);
      return { ok: true, kind: 'click' };
    }
    await closeCalendar(c);
    return { ok: false, reason: 'month-not-reached' };
  }

  // ---------------------------------------------------------------- nsfw/tags
  function stateOf(el) {
    var cur = el;
    for (var i = 0; i < 4 && cur; i++) {
      var ap = cur.getAttribute && (cur.getAttribute('aria-pressed') || cur.getAttribute('aria-checked') || cur.getAttribute('aria-selected'));
      if (ap === 'true') return true;
      if (ap === 'false') return false;
      var ds = cur.getAttribute && cur.getAttribute('data-state');
      if (ds && /^(on|checked|active|selected|open)$/i.test(ds)) return true;
      if (ds && /^(off|unchecked|inactive)$/i.test(ds)) return false;
      var inp = cur.querySelector && cur.querySelector('input[type=checkbox],input[type=radio]');
      if (inp) return !!inp.checked;
      var cls = String(cur.className || '');
      if (/(^|[\s_-])(active|selected|checked|enabled|on)([\s_-]|$)/i.test(cls)) return true;
      cur = cur.parentElement;
    }
    return null;
  }
  async function applyNsfw(want) {
    var els = findByText(['unfiltered', 'nsfw']);
    els.sort(topFirst);
    for (var i = 0; i < els.length; i++) {
      var tgt = clickableAncestor(els[i]);
      var st = stateOf(tgt);
      if (st === null) continue;
      if (st === !!want) return { ok: true, state: st, changed: false };
      var prev = sigNow();
      markAction();
      realClick(tgt);
      await sleep(350);
      var after = stateOf(tgt);
      await settle(prev, 6000);
      return { ok: after === !!want, state: after, changed: true };
    }
    return { ok: false, state: null, reason: 'toggle-state-unknown' };
  }
  async function applyTags(tags) {
    var applied = [], missing = [];
    for (var i = 0; i < tags.length; i++) {
      var tag = tags[i];
      var found = findByText([tag])[0];
      if (!found) {
        var opener = findByText(['filter', 'filters', 'tags', 'tag', 'all tags', 'more'])[0];
        if (opener) { realClick(clickableAncestor(opener)); await sleep(350); found = findByText([tag])[0]; }
      }
      if (!found) { missing.push(tag); continue; }
      var st = stateOf(clickableAncestor(found));
      if (st === true) { applied.push(tag); continue; }
      var prev = sigNow();
      markAction();
      realClick(clickableAncestor(found));
      await settle(prev, 6000);
      applied.push(tag);
    }
    return { applied: applied, missing: missing };
  }

  // ---------------------------------------------------------------- search / account
  async function typeSearch(query) {
    var inputs = [].slice.call(document.querySelectorAll('input[type=search],input[type=text],input:not([type]),input[placeholder*="search" i]')).filter(visible);
    var input = inputs.find(function (i) { return /search/i.test((i.placeholder || '') + (i.getAttribute('aria-label') || '') + (i.type || '') + (i.name || '')); }) || inputs[0];
    if (!input) return { ok: false, reason: 'no-search-input', controls: describeControls() };
    var prev = sigNow();
    markAction();
    input.focus();
    setNativeValue(input, query);
    await sleep(150);
    ['keydown', 'keypress', 'keyup'].forEach(function (t) {
      input.dispatchEvent(new KeyboardEvent(t, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
    });
    var form = input.closest('form');
    if (form) { try { form.requestSubmit ? form.requestSubmit() : form.submit(); } catch (e) {} }
    var res = await settle(prev, 9000);
    return { ok: true, changed: res.changed };
  }

  // ---------------------------------------------------------------- profile + star tab
  // Favourites live on the PROFILE page: avatar/Profile link -> the row of icon-only
  // tabs under the plan card (bear, book, clapper, STAR, thumb, image + a GIF
  // button) -> click the star -> Characters chip -> scroll down to the cards.
  //
  // Everything is anchored on what is certainly there: the profile's
  // "Followers / Following / Interactions" counters. The icon row is the first row
  // of >= 4 icon-only controls BELOW those counters, so the header icons (search,
  // 18+, avatar...), sidebar and social icons can never be mistaken for it.
  function inFixedLayer(el) {
    for (var p = el; p && p.nodeType === 1 && p !== document.documentElement; p = p.parentElement) {
      var role = p.getAttribute && p.getAttribute('role');
      if (role === 'dialog' || role === 'menu' || role === 'listbox') return true;
      var cs; try { cs = getComputedStyle(p); } catch (e) { continue; }
      if (cs.position === 'fixed') return true;
    }
    return false;
  }
  // The counters of the profile PAGE (the avatar menu prints the same words inside
  // a popup / fixed layer, which is skipped). Returns the lowest bottom edge or null.
  function profileStats() {
    var kinds = {}, bottom = -1;
    [].slice.call(document.querySelectorAll('div,span,p,a,button,li')).forEach(function (e) {
      if (!visible(e) || inCard(e)) return;
      var t = ownText(e);
      if (!t || t.length > 24) return;
      var n = norm(t).replace(/^\d+ ?[kmb]? /, '');
      if (n !== 'followers' && n !== 'following' && n !== 'interactions') return;
      if (inFixedLayer(e)) return;
      kinds[n] = 1;
      var r = e.getBoundingClientRect();
      if (r.bottom > bottom) bottom = r.bottom;
    });
    return Object.keys(kinds).length >= 2 ? bottom : null;
  }
  function isIconOnly(e) {
    if (!visible(e) || inCard(e)) return false;
    if (externalAnchorOf(e)) return false;
    var r = e.getBoundingClientRect();
    if (r.width < 18 || r.width > 130 || r.height < 18 || r.height > 100) return false;
    if (!e.querySelector('svg,img') && !/^(svg|img)$/i.test(e.tagName || '')) return false;
    return ownText(e) === '';
  }
  function iconCandidates() {
    var seen = new Set(), out = [];
    [].slice.call(document.querySelectorAll('button,[role=tab],[role=button],a,li,div,span,svg')).forEach(function (e) {
      if (!isIconOnly(e)) return;
      var t = clickableAncestor(e);
      if (!t || seen.has(t)) return;
      if (externalAnchorOf(t)) return;
      var r = t.getBoundingClientRect();
      if (r.width < 18 || r.width > 140 || r.height < 18 || r.height > 110) return;
      seen.add(t);
      out.push({ el: t, cx: r.left + r.width / 2, cy: r.top + r.height / 2, r: r });
    });
    return out;
  }
  // The first row of >= 4 icon-only controls under the profile counters (left to right).
  function findIconRow() {
    var below = profileStats();
    if (below === null) return null;
    var cands = iconCandidates().filter(function (c) { return c.r.top >= below - 2; });
    cands.sort(function (a, b) { return a.cy - b.cy; });
    var rows = [];
    cands.forEach(function (c) {
      var row = rows.length ? rows[rows.length - 1] : null;
      if (row && Math.abs(row.cy - c.cy) <= 12) {
        if (!row.items.some(function (x) { return Math.abs(x.cx - c.cx) < 6; })) row.items.push(c);
      } else rows.push({ cy: c.cy, items: [c] });
    });
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].items.length >= 4) {
        var items = rows[i].items.sort(function (a, b) { return a.cx - b.cx; });
        // The GIF button sits apart at the far right: leave it out of the tabs.
        if (items.length >= 6) {
          var gaps = [];
          for (var g = 1; g < items.length; g++) gaps.push(items[g].cx - items[g - 1].cx);
          var sg = gaps.slice().sort(function (a, b) { return a - b; });
          var medGap = sg[Math.floor(sg.length / 2)];
          if (gaps[gaps.length - 1] > medGap * 1.8) items = items.slice(0, -1);
        }
        return items.map(function (x) { return x.el; });
      }
    }
    return null;
  }
  function describeIcons() {
    var out = [];
    var below = profileStats();
    iconCandidates().forEach(function (c) {
      var e = c.el;
      var cls = String(e.className && e.className.baseVal != null ? e.className.baseVal : e.className || '').slice(0, 24);
      out.push(e.tagName.toLowerCase() + (cls ? '.' + cls.replace(/\s+/g, '.') : '') + '@' + Math.round(c.cx) + ',' + Math.round(c.cy) +
        (below !== null && c.r.top < below - 2 ? '(above-stats)' : ''));
    });
    return out.slice(0, 30);
  }
  function pickStarTab(row) {
    for (var i = 0; i < row.length; i++) {
      var sig = (row[i].getAttribute('aria-label') || '') + ' ' + (row[i].title || '') + ' ' + (row[i].getAttribute('data-testid') || '') + ' ' + String(row[i].className && row[i].className.baseVal != null ? row[i].className.baseVal : row[i].className) + ' ' + (row[i].innerHTML || '').slice(0, 600);
      if (/(favou?rite|star)/i.test(sig)) return row[i];
    }
    return row.length > 3 ? row[3] : null;
  }
  function starOpen() {
    return [].slice.call(document.querySelectorAll('button,[role=tab],[role=button],div,span')).some(function (e) {
      return visible(e) && !inCard(e) && !inFixedLayer(e) && ownText(e).length < 20 && /^(world cards?|memories|models|folders)$/.test(norm(ownText(e)));
    });
  }
  async function waitProfile(ms) {
    for (var t = 0; t < ms; t += 300) { if (profileStats() !== null) return true; await sleep(300); }
    return profileStats() !== null;
  }
  // Gets to the profile page from wherever the browser is (home, a menu, a 404...).
  async function goToProfile() {
    if (profileStats() !== null) return true;
    // An open avatar menu would hide the page behind it.
    try { document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); } catch (e) {}
    function profileLinks() {
      return [].slice.call(document.querySelectorAll('a[href]')).filter(function (a) {
        var h = (a.getAttribute('href') || '').split('#')[0];
        if (isExternalHref(h) || inCard(a)) return false;
        var label = norm(ownText(a) || a.getAttribute('aria-label') || a.title || '');
        return label === 'profile' || label === 'my profile' ||
          /^\/([a-z]{2}(-[A-Za-z]{2})?\/)?(profile|my-profile|me)\/?(\?.*)?$/.test(h);
      }).sort(function (a, b) { return (visible(b) ? 1 : 0) - (visible(a) ? 1 : 0); });
    }
    // 1) a same-site Profile link (sidebar / drawer; works even when the drawer is closed)
    var links = profileLinks();
    for (var i = 0; i < Math.min(3, links.length); i++) {
      markAction();
      realClick(links[i]);
      await sleep(700);
      await settle(sigNow(), 5000);
      if (await waitProfile(5000)) return true;
    }
    // 2) any control that just says "Profile"
    var byText = findByText(['profile', 'my profile']).filter(function (e) { return !inCard(e) && ownText(e).length < 20; });
    for (var j = 0; j < Math.min(3, byText.length); j++) {
      markAction();
      realClick(clickableAncestor(byText[j]));
      await sleep(700);
      await settle(sigNow(), 5000);
      if (await waitProfile(5000)) return true;
    }
    // 3) the avatar in the header -> menu -> Profile
    var av = [].slice.call(document.querySelectorAll('button,[role=button],a,div,img')).filter(function (e) {
      if (!visible(e) || inCard(e)) return false;
      var r = e.getBoundingClientRect();
      return r.top < 120 && r.left > window.innerWidth * 0.55 && r.width >= 24 && r.width <= 64 && Math.abs(r.width - r.height) < 6 && /^[A-Za-z0-9]?$/.test(ownText(e));
    }).sort(function (a, b) { return b.getBoundingClientRect().left - a.getBoundingClientRect().left; });
    if (av.length) {
      markAction();
      realClick(clickableAncestor(av[0]));
      await sleep(700);
      var mi = findByText(['profile', 'my profile', 'my account']).filter(function (e) { return visible(e) && !inCard(e); });
      if (mi.length) { realClick(clickableAncestor(mi[0])); await sleep(900); await settle(sigNow(), 5000); }
      if (await waitProfile(5000)) return true;
    }
    return profileStats() !== null;
  }
  async function openProfileFavorites() {
    if (!(await goToProfile())) {
      return { ok: false, reason: 'profile-page-not-reached', controls: describeControls(), icons: describeIcons() };
    }
    var row = null;
    for (var w0 = 0; w0 < 15 && !row; w0++) { row = findIconRow(); if (!row) await sleep(400); }
    if (!row) return { ok: false, reason: 'no-icon-tab-row-under-profile-counters', controls: describeControls(), icons: describeIcons() };
    // The star tab is confirmed by its content: once open, the profile shows the
    // Characters / World Cards / Memories / Models / Folders chips (the first tab
    // shows All / Target / Public). Never trust a click that did not change that.
    var opened = starOpen();
    var first = pickStarTab(row);
    var order = [first].concat(row.filter(function (e) { return e !== first; })).slice(0, 6);
    for (var oi = 0; oi < order.length && !opened; oi++) {
      var prev = sigNow();
      markAction();
      realClick(order[oi]);
      await settle(prev, 4000);
      for (var w = 0; w < 8 && !opened; w++) { opened = starOpen(); if (!opened) await sleep(300); }
      if (opened) log('star tab = icon #' + oi + ' of ' + row.length);
      else { var again = findIconRow(); if (again && again.length === row.length) order = order.map(function (e, k) { return again[row.indexOf(e)] || e; }); }
    }
    if (!opened) return { ok: false, reason: 'star-tab-not-confirmed', count: row.length, controls: describeControls(), icons: describeIcons() };
    // sub-tab "Characters"
    var sub = [].slice.call(document.querySelectorAll('button,[role=tab],[role=button],div,span')).filter(function (e) {
      return visible(e) && !inCard(e) && !inFixedLayer(e) && norm(ownText(e)) === 'characters';
    }).sort(function (a, b) { return a.getBoundingClientRect().width * a.getBoundingClientRect().height - b.getBoundingClientRect().width * b.getBoundingClientRect().height; });
    if (sub.length) { var p2 = sigNow(); markAction(); realClick(clickableAncestor(sub[0])); await settle(p2, 7000); }
    // Scroll DOWN to the favourites: wait for the cards to render, then bring the
    // first one into view (the list sits below the profile header and chips).
    for (var cw = 0; cw < 15 && !scanCards().length; cw++) await sleep(400);
    var firstCards = scanCards();
    if (firstCards.length) {
      try { firstCards[0].scrollIntoView({ block: 'start' }); } catch (e) {}
    } else {
      try { window.scrollTo(0, Math.max(0, window.innerHeight * 0.6)); } catch (e) {}
    }
    await sleep(400);
    return { ok: true, label: 'profile star tab', cards: scanCards().length };
  }

  // ---- Favorites sort: the profile's own dropdown ("Latest" / "Popular") ----------
  // Its vocabulary is deliberately separate from the home feed's sort: the profile
  // header also prints "Following" (a follower count label), which the home-feed
  // vocabulary would mistake for the sort control and click.
  var FAV_SORT_ALIASES = { 'new': ['latest', 'new', 'newest'], 'popular': ['popular', 'most popular'] };
  var FAV_SORT_LABELS = FAV_SORT_ALIASES['new'].concat(FAV_SORT_ALIASES['popular']);
  var POPUP_SEL = '[role=listbox],[role=menu],[data-radix-popper-content-wrapper],[class*="dropdown" i],[class*="popover" i],[class*="menu" i]';
  function favSortKeyOf(label) {
    var n = norm(label);
    for (var k in FAV_SORT_ALIASES) if (FAV_SORT_ALIASES[k].indexOf(n) >= 0) return k;
    return null;
  }
  function docTop(el) { return el.getBoundingClientRect().top + (window.pageYOffset || 0); }
  function favSortTrigger() {
    var sels = [].slice.call(document.querySelectorAll('select')).filter(visible);
    for (var i = 0; i < sels.length; i++) {
      var o = [].slice.call(sels[i].options).map(function (x) { return norm(x.text); });
      if (o.filter(function (t) { return FAV_SORT_LABELS.indexOf(t) >= 0; }).length >= 2) return { kind: 'select', el: sels[i], tEl: sels[i] };
    }
    // Only controls BELOW the Characters / World Cards / ... chips can be the sort.
    var chips = findByText(['characters', 'world cards', 'memories', 'models', 'folders']);
    var minTop = 0;
    chips.forEach(function (c) { var b = docTop(c) + c.getBoundingClientRect().height; if (b > minTop) minTop = b; });
    var els = findByText(FAV_SORT_LABELS).filter(function (el) {
      return !el.closest(POPUP_SEL) && docTop(el) >= minTop - 6;
    });
    els.sort(function (a, b) { return docTop(a) - docTop(b); });
    for (var j = 0; j < els.length; j++) {
      var c2 = clickableAncestor(els[j]);
      if (c2 && visible(c2) && !externalAnchorOf(c2)) return { kind: 'click', el: c2, tEl: els[j] };
    }
    return null;
  }
  function currentFavoritesSort() {
    var t = favSortTrigger();
    if (!t) return { key: null, label: '' };
    var label = t.kind === 'select' ? t.el.options[t.el.selectedIndex].text : ownText(t.tEl);
    return { key: favSortKeyOf(label), label: label };
  }
  async function applyFavoritesSort(key) {
    var aliases = FAV_SORT_ALIASES[key];
    if (!aliases) return { ok: false, reason: 'unknown-sort' };
    var steps = [];
    dismissOverlays();
    var trig = favSortTrigger();
    if (!trig) return { ok: false, reason: 'no-favorites-sort-control', controls: describeControls() };
    var cur = currentFavoritesSort();
    steps.push('current=' + cur.label);
    if (cur.key === key) return { ok: true, changed: false, label: cur.label, steps: steps };
    if (trig.kind === 'select') {
      var sel = trig.el, idx = -1;
      for (var i = 0; i < sel.options.length; i++) if (aliases.indexOf(norm(sel.options[i].text)) >= 0) idx = i;
      if (idx < 0) return { ok: false, reason: 'option-missing', steps: steps };
      var p0 = sigNow(); markAction();
      setNativeValue(sel, sel.options[idx].value);
      await settle(p0, 8000);
      return { ok: true, changed: true, label: sel.options[idx].text, steps: steps };
    }
    function lookOption() {
      var m = findByText(aliases).filter(function (el) { return el !== trig.tEl && !trig.el.contains(el) && !el.contains(trig.el); });
      var inPop = m.filter(function (el) { return el.closest(POPUP_SEL); });
      return inPop[0] || m[0] || null;
    }
    var optionEl = null;
    for (var attempt = 0; attempt < 3 && !optionEl; attempt++) {
      if (attempt === 0) realClick(trig.el);
      else if (attempt === 1) { try { trig.el.click(); } catch (e) {} }
      else {
        try { trig.el.focus(); } catch (e) {}
        ['keydown', 'keyup'].forEach(function (t) { trig.el.dispatchEvent(new KeyboardEvent(t, { key: 'ArrowDown', code: 'ArrowDown', bubbles: true })); });
      }
      for (var w = 0; w < 8 && !optionEl; w++) { await sleep(120); optionEl = lookOption(); }
      steps.push('open attempt ' + attempt + (optionEl ? ' ok' : ' no-option'));
    }
    if (!optionEl) return { ok: false, reason: 'favorites-sort-option-not-found', steps: steps, controls: describeControls() };
    var prev = sigNow();
    markAction();
    realClick(clickableAncestor(optionEl));
    steps.push('clicked ' + ownText(optionEl));
    var r = await settle(prev, 9000);
    // Confirm by what the page now shows.
    var after = currentFavoritesSort();
    return { ok: after.key === key || after.key === null, changed: true, label: ownText(optionEl), now: after.label, listChanged: r.changed, steps: steps };
  }
  var FAV_RE = /^(my )?(favou?rites?|favou?rited|liked|saved|starred|collection|bookmarks?)( \d+)?$/;
  async function openFavorites() {
    var pf = null;
    try { pf = await openProfileFavorites(); if (pf && pf.ok) return pf; } catch (e) { log('profile favorites failed: ' + e); pf = { reason: 'script-error: ' + e }; }
    var all = [].slice.call(document.querySelectorAll('button,[role=tab],[role=button],a,li,div,span')).filter(function (el) {
      return visible(el) && !inCard(el) && FAV_RE.test(norm(ownText(el))) && ownText(el).length < 30;
    });
    all.sort(function (a, b) { return a.getBoundingClientRect().width * a.getBoundingClientRect().height - b.getBoundingClientRect().width * b.getBoundingClientRect().height; });
    if (!all.length) {
      // Menus are often collapsed behind a hamburger / "Open sidebar" button.
      var burger = [].slice.call(document.querySelectorAll('button,[role=button],a,div')).filter(function (el) {
        return visible(el) && /(open sidebar|menu|sidebar|navigation)/i.test((el.getAttribute('aria-label') || '') + ' ' + (el.title || '') + ' ' + (ownText(el).length < 20 ? ownText(el) : ''));
      });
      for (var b = 0; b < Math.min(2, burger.length) && !all.length; b++) {
        realClick(clickableAncestor(burger[b]));
        await sleep(450);
        all = [].slice.call(document.querySelectorAll('button,[role=tab],[role=button],a,li,div,span')).filter(function (el) {
          return visible(el) && !inCard(el) && FAV_RE.test(norm(ownText(el))) && ownText(el).length < 30;
        });
      }
    }
    if (!all.length) return { ok: false, reason: (pf && pf.reason) || 'no-favorites-tab', controls: (pf && pf.controls) || describeControls(), icons: (pf && pf.icons) || describeIcons() };
    all.sort(function (a, b) { return a.getBoundingClientRect().width * a.getBoundingClientRect().height - b.getBoundingClientRect().width * b.getBoundingClientRect().height; });
    var prev = sigNow();
    markAction();
    realClick(clickableAncestor(all[0]));
    var r = await settle(prev, 9000);
    return { ok: true, changed: r.changed, label: ownText(all[0]) };
  }
  function describeControls() {
    var out = [];
    [].slice.call(document.querySelectorAll('button,[role=tab],[role=button],[role=option],[role=menuitem],a,select,input')).forEach(function (el) {
      if (!visible(el) || inCard(el)) return;
      var t = (el.tagName === 'INPUT' ? ('input:' + (el.placeholder || el.type)) : ownText(el)).slice(0, 36);
      if (t && out.indexOf(t) < 0) out.push(t);
    });
    return out.slice(0, 70);
  }

  // ---------------------------------------------------------------- public API
  function pageInfo() {
    var title = document.title || '';
    var cf = /just a moment|attention required|verify you are human/i.test(title) ||
      !!document.querySelector('#challenge-form,.cf-turnstile,iframe[src*="challenges.cloudflare"],#cf-challenge-running');
    var loggedOut = !!([].slice.call(document.querySelectorAll('a[href*="/auth/signin"],a[href*="/login"],a[href*="/signin"]')).find(visible)) ||
      !!findByText(['log in', 'sign in', 'login']).filter(function (e) { return !e.closest('[role=dialog]'); }).length;
    var nCards = scanCards().length;
    // A 404 page never shows character cards, so only look when there are none (keeps this poll cheap).
    return { href: location.href, title: title, cf: cf, loggedOut: loggedOut, cards: nCards, ready: document.readyState, notFound: nCards === 0 && isNotFoundDoc(document) };
  }

  function resetFeed() {
    S.feed = []; S.map = new Map(); S.els = new Map();
    S.exhausted = false; S.parent = null;
  }
  // Called right before a UI action that will make the site load a new list.
  function markAction() { S.netOrder = []; S.netSet = new Set(); }
  function resetFeedKeepMode() { var v = S.virtual; resetFeed(); S.virtual = v; }

  function shapeRaw(r) {
    if (!r) return null;
    var out = {};
    for (var k in r) {
      if (!Object.prototype.hasOwnProperty.call(r, k)) continue;
      var v = r[k];
      if (typeof v === 'string' && v.length > 20000) v = v.slice(0, 20000);
      out[k] = v;
    }
    return out;
  }
  function snapshot(from, to) {
    var recs = S.feed;
    var source = 'dom';
    if (!recs.length && S.netOrder.length) {
      source = 'net';
      recs = S.netOrder.map(function (id) {
        var r = S.raw.get(id) || {};
        return { id: id, href: '/character/' + id, name: String(r.name || r.characterName || r.title || id), img: '', box: null, fit: '', pos: '', nat: null };
      });
    }
    var slice = recs.slice(from, to).map(function (c) {
      return { id: c.id, href: c.href, name: c.name, img: c.img, box: c.box, fit: c.fit, pos: c.pos, nat: c.nat, rank: c.rank || null, rankNote: c.rankNote || '', raw: shapeRaw(lookupRaw(c.id, c.href)) };
    });
    return { items: slice, total: recs.length, exhausted: S.exhausted, source: source };
  }
  async function fillImages(from, to) {
    var missing = S.feed.slice(from, to).filter(function (r) { return !r.img; });
    for (var i = 0; i < missing.length && i < 40; i++) {
      var el = S.els.get(missing[i].id);
      if (el && el.isConnected) {
        try { el.scrollIntoView({ block: 'center' }); } catch (e) {}
        await sleep(140);
        scan();
      }
    }
  }

  async function pump(from, target, maxMs) {
    var t0 = Date.now();
    dismissOverlays();
    if (!S.feed.length) { scrollTop0(); await sleep(350); }
    scan();
    var stagn = 0;
    while (S.feed.length < target && Date.now() - t0 < maxMs && !S.exhausted) {
      if (S.virtual) { await stepPump(target, t0 + maxMs); break; }
      var before = S.feed.length, bn = S.netSeq;
      scrollDown();
      await waitGrowth(before, bn, 3200);
      if (S.feed.length > before) {
        stagn = 0;
        if (looksVirtual()) {
          // we probably skipped rows: restart from the top in small steps
          log('virtual list detected -> stepwise re-collect');
          S.virtual = true;
          var keepRaw = S.raw;
          resetFeed(); S.virtual = true; S.raw = keepRaw;
          scrollTop0(); await sleep(400); scan();
        }
        continue;
      }
      stagn++;
      if (stagn === 1) await jiggle();
      if (stagn >= 3) { S.exhausted = true; log('exhausted at ' + S.feed.length); }
    }
    scan();
    await fillImages(from, target);
    return snapshot(from, target);
  }

  async function prepareFeed() {
    // call after any UI change: forget old cards, start from a clean top.
    resetFeedKeepMode();
    scrollTop0();
    await sleep(350);
    scan();
    return { cards: S.feed.length };
  }


  // ---- Character page "Info" panel capture (display description) ----------
  // Finds the rendered Info tab body of a /character/<id> page and returns a
  // cleaned copy of its HTML (inline styles and images kept, scripts/handlers
  // removed) plus its plain text. The app shows the HTML as the display
  // description and derives a text-only memory description from it.
  var SITE_BASE = /^https?:/i.test(location.href) ? location.href : 'https://crushon.ai/';
  function absUrl(u) {
    try { return new URL(u, SITE_BASE).href; } catch (e) { return u; }
  }
  function unwrapNextImage(u) {
    try {
      var x = new URL(u, SITE_BASE);
      if (x.pathname.indexOf('/_next/image') >= 0 && x.searchParams.get('url')) {
        return absUrl(x.searchParams.get('url'));
      }
      // img.cocdn.co/_image/optimize/<original url>?q=75&w=1200
      var mo = /\/_image\/optimize\/(https?:\/\/.+)$/i.exec(x.pathname + x.search.replace(/[?&](q|w)=\d+/g, '').replace(/^\?$/, ''));
      if (mo) return mo[1];
    } catch (e) {}
    return u;
  }
  function cleanClone(el) {
    var c = el.cloneNode(true);
    var kill = c.querySelectorAll('script,iframe,object,embed,link,meta,noscript,video,audio,button,svg,input,textarea,select,form');
    for (var i = 0; i < kill.length; i++) if (kill[i].parentNode) kill[i].parentNode.removeChild(kill[i]);
    var all = c.querySelectorAll('*');
    for (var j = 0; j < all.length; j++) {
      var n = all[j];
      var attrs = Array.prototype.slice.call(n.attributes || []);
      for (var k = 0; k < attrs.length; k++) {
        var an = attrs[k].name.toLowerCase();
        if (an.indexOf('on') === 0 || an === 'class' || an === 'id' || an.indexOf('data-') === 0 ||
            an.indexOf('aria-') === 0 || an === 'srcset' || an === 'sizes' || an === 'loading' ||
            an === 'decoding' || an === 'fetchpriority' || an === 'tabindex' || an === 'role') {
          n.removeAttribute(attrs[k].name);
        }
      }
      if (n.tagName === 'IMG') {
        var live = el.querySelectorAll('img');
        var src = n.getAttribute('src') || n.getAttribute('data-src') || '';
        if (!src || src.indexOf('data:') === 0) {
          // lazy placeholder: use the live element's resolved source
          for (var q = 0; q < live.length; q++) {
            if ((live[q].alt || '') === (n.getAttribute('alt') || '') && live[q].currentSrc) { src = live[q].currentSrc; break; }
          }
        }
        if (src) n.setAttribute('src', unwrapNextImage(absUrl(src)));
      }
      if (n.tagName === 'A') {
        var h = n.getAttribute('href');
        if (h && !/^javascript:/i.test(h)) n.setAttribute('href', absUrl(h)); else n.removeAttribute('href');
      }
      var st = n.getAttribute && n.getAttribute('style');
      if (st && /expression\(|javascript:|@import|behavior:/i.test(st)) n.removeAttribute('style');
    }
    return c;
  }
  var TAB_WORDS = ['info', 'memories', 'comment', 'comments', 'supporters'];
  function findInfoPanel() {
    // 1) locate the tab row (Info / Memories / Comment / Supporters)
    var best = null, bestScore = 0;
    var cand = document.querySelectorAll('div,nav,ul,section');
    for (var i = 0; i < cand.length; i++) {
      var el = cand[i];
      if (el.children.length < 2 || el.children.length > 8) continue;
      var hits = 0;
      for (var j = 0; j < el.children.length; j++) {
        var w = norm(ownText(el.children[j])).replace(/[0-9\s]+$/g, '');
        if (TAB_WORDS.indexOf(w) >= 0) hits++;
      }
      if (hits >= 3 && hits > bestScore) { best = el; bestScore = hits; }
    }
    if (best) {
      // 2) the panel is the first following sibling (of the row or its parents) with real content
      var node = best;
      for (var up = 0; up < 5 && node && node !== document.body; up++, node = node.parentElement) {
        var sib = node.nextElementSibling;
        while (sib) {
          if (ownText(sib).length > 60 || sib.querySelector('img')) return sib;
          sib = sib.nextElementSibling;
        }
      }
    }
    // 3) fallback: the element with the most text that holds no tab row and is not the page body
    var main = document.querySelector('main') || document.body;
    var pick = null, pl = 0;
    var els = main.querySelectorAll('div,section,article');
    for (var m = 0; m < els.length; m++) {
      var e2 = els[m];
      if (best && e2.contains(best)) continue;
      var tl = ownText(e2).length;
      if (tl > pl && tl < 60000) { pl = tl; pick = e2; }
    }
    return pick;
  }
  function textFromHtmlEl(el) {
    var c = cleanClone(el);
    var blocks = c.querySelectorAll('p,div,br,li,h1,h2,h3,h4,h5,h6,tr,section');
    for (var i = 0; i < blocks.length; i++) blocks[i].appendChild(document.createTextNode('\n'));
    return (c.textContent || '').replace(/[ \t\u00a0]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  }
  // ---- "Page not found" detection --------------------------------------------
  // A character route that does not exist renders the site's own 404 artwork. The old
  // "biggest block of text" fallback captured that artwork as the character's
  // description (heart + "404 Page Not Found" in Glaze's Info tab).
  var NOT_FOUND_RE = /(page not found|could not be found|cant find the page|can t find the page)/;
  function looksNotFoundText(t) {
    var n = norm(t);
    return n.length < 900 && NOT_FOUND_RE.test(n);
  }
  function findLabel(root, word) {
    var live = root === document;
    var els = root.querySelectorAll('h1,h2,h3,h4,h5,h6,div,span,p,label,strong,b');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (el.children.length > 1) continue;
      if (norm(el.textContent) !== word) continue;
      if (live && !visible(el)) continue;
      return el;
    }
    return null;
  }
  function isNotFoundDoc(doc) {
    try {
      var title = norm(doc.title || '');
      if (NOT_FOUND_RE.test(title) || /^404( |$)/.test(title)) return true;
      var body = doc.body;
      if (!body) return false;
      if (findLabel(doc, 'introduction')) return false; // a real character page
      var nodes = body.querySelectorAll('h1,h2,h3,h4,p,div,span,img');
      for (var i = 0; i < nodes.length && i < 5000; i++) {
        var el = nodes[i];
        if (el.tagName === 'IMG') {
          if (NOT_FOUND_RE.test(norm(el.getAttribute('alt') || ''))) return true;
          continue;
        }
        if (el.children.length > 2) continue;
        var t = norm(el.textContent || '');
        if (t.length < 80 && NOT_FOUND_RE.test(t)) return true;
      }
    } catch (e) {}
    return false;
  }

  // ---- Description capture ----------------------------------------------------
  // On a character page the description sits under an "Introduction" label, after the
  // row of tag chips and before the "Comments" / "Public Memories" sections. Works on
  // the live page AND on server-rendered HTML parsed with DOMParser (so a hydration
  // hiccup or a client-side 404 state cannot lose it).
  var INFO_STOP = ['comments', 'comment', 'public memories', 'memories', 'supporters', 'related characters',
    'recommended', 'you may also like', 'similar characters', 'more from creator'];
  function tagSetOf(doc) {
    var set = {};
    try {
      var m = doc.querySelector('meta[name="keywords"]');
      var kw = m ? (m.getAttribute('content') || '') : '';
      kw.split(',').forEach(function (k) { var n = norm(k); if (n) set[n] = 1; });
    } catch (e) {}
    set['unfiltered'] = 1;
    return set;
  }
  function dropLeadingChips(wrap, tags) {
    var all = wrap.querySelectorAll('*'), kill = [];
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (el.children.length) continue;
      var t = (el.textContent || '').trim();
      if (!t) {
        if (el.tagName === 'IMG' || el.tagName === 'PICTURE' || el.tagName === 'VIDEO') break;
        continue;
      }
      var n = norm(t);
      if (t.length <= 30 && (tags[n] || (!tags.__real && /^H[2-6]$/.test(el.tagName)))) { kill.push(el); continue; }
      break;
    }
    kill.forEach(function (k) {
      var p = k.parentNode;
      if (k.parentNode) k.parentNode.removeChild(k);
      while (p && p !== wrap && !(p.textContent || '').trim() && !(p.querySelector && p.querySelector('img'))) {
        var q = p.parentNode; if (q) q.removeChild(p); p = q;
      }
    });
  }
  function buildInfoFromIntro(doc) {
    var live = doc === document;
    var label = findLabel(doc, 'introduction');
    if (!label) return null;
    var all = [].slice.call(doc.querySelectorAll('*'));
    var li = all.indexOf(label), stop = null;
    for (var i = li + 1; i < all.length; i++) {
      var e = all[i];
      if (label.contains(e) || e.children.length > 1) continue;
      var n = norm(e.textContent || '');
      if (INFO_STOP.indexOf(n) < 0 || (e.textContent || '').trim().length > 30) continue;
      if (live && !visible(e)) continue;
      // Headings inside the creator's own (inline-styled) HTML are part of the description.
      var st = e.closest('[style]');
      if (st && !st.contains(label)) continue;
      stop = e; break;
    }
    var rng = doc.createRange();
    rng.setStartAfter(label);
    if (stop) rng.setEndBefore(stop);
    else { var mainEl = doc.querySelector('main') || doc.body; rng.setEndAfter(mainEl.lastChild || mainEl); }
    var wrap = doc.createElement('div');
    wrap.appendChild(rng.cloneContents());
    var tags = tagSetOf(doc);
    tags.__real = Object.keys(tags).length > 1;
    dropLeadingChips(wrap, tags);
    return packInfo(wrap, doc);
  }
  function packInfo(wrap, doc) {
    var html = cleanClone(wrap).innerHTML;
    if (html.length > 400000) html = html.slice(0, 400000);
    var imgs = [];
    wrap.querySelectorAll('img').forEach(function (im) {
      var u = im.currentSrc || im.getAttribute('src') || '';
      if (u && u.indexOf('data:') !== 0) imgs.push(unwrapNextImage(absUrl(u)));
    });
    return { html: html, text: textFromHtmlEl(wrap).slice(0, 60000), images: imgs.slice(0, 60) };
  }
  function infoLooksValid(r) {
    if (!r) return false;
    var text = (r.text || '').trim();
    if (!text && !(r.images && r.images.length)) return false;
    if (looksNotFoundText(text)) return false;
    if (/private space exclusive to you and fantasy ai characters/i.test(text)) return false; // generic site blurb
    if (!text && r.images && r.images.some(function (u) { return /404|not.?found/i.test(u); })) return false;
    return true;
  }
  function wakeLazyImages() {
    // The live page lazy-loads pictures; resolve the placeholders before cloning.
    [].slice.call(document.querySelectorAll('img')).forEach(function (im) {
      var a = im.getAttribute('src') || '';
      if (im.currentSrc && (!a || a.indexOf('data:') === 0)) { try { im.setAttribute('src', im.currentSrc); } catch (e) {} }
    });
  }
  async function infoFromServerHtml(id) {
    var url = '/character/' + encodeURIComponent(id) + '/details';
    try {
      var res = await fetch(url, { credentials: 'include', headers: { accept: 'text/html' } });
      if (!res.ok) return { ok: false, reason: 'http-' + res.status };
      var html = await res.text();
      var doc = new DOMParser().parseFromString(html, 'text/html');
      if (isNotFoundDoc(doc)) return { ok: false, reason: 'not-found' };
      var r = buildInfoFromIntro(doc);
      if (!infoLooksValid(r)) return { ok: false, reason: 'no-intro-in-server-html' };
      r.ok = true; r.source = 'server-html';
      return r;
    } catch (e) { return { ok: false, reason: 'fetch-failed: ' + e }; }
  }
  async function captureInfo(id) {
    dismissOverlays();
    try { window.scrollTo(0, 0); } catch (e) {}
    if (isNotFoundDoc(document)) return { ok: false, reason: 'not-found', href: location.href };
    if (!id) { var mm = CHAR_RE.exec(location.pathname || ''); id = mm ? mm[1] : ''; }
    var why = [];
    // 1) the live page, anchored on the "Introduction" label (give hydration a moment)
    var r = null;
    for (var t = 0; t < 6; t++) {
      wakeLazyImages();
      r = buildInfoFromIntro(document);
      if (infoLooksValid(r)) { r.ok = true; r.source = 'live-intro'; return r; }
      await sleep(500);
    }
    why.push('live-intro');
    // 2) the server-rendered HTML of the details page
    if (id) {
      var ssr = await infoFromServerHtml(id);
      if (ssr.ok) return ssr;
      why.push('server-html:' + ssr.reason);
    }
    // 3) older layouts: the panel under an Info / Memories / Comment / Supporters tab row
    var el = null;
    for (var t2 = 0; t2 < 4 && !el; t2++) { el = findInfoPanel(); if (!el) await sleep(500); }
    if (el) {
      try {
        var h = Math.min(el.scrollHeight || 0, 20000);
        for (var y = 0; y < h; y += 700) { window.scrollTo(0, y); await sleep(60); }
        window.scrollTo(0, 0);
        await sleep(250);
      } catch (e) {}
      wakeLazyImages();
      var legacy = packInfo(el, document);
      if (infoLooksValid(legacy)) { legacy.ok = true; legacy.source = 'tab-panel'; return legacy; }
      why.push('tab-panel-invalid');
    }
    return { ok: false, reason: 'no-description-found (' + why.join(', ') + ')' };
  }

  function pageData() {
    var nd = document.getElementById('__NEXT_DATA__');
    function meta(p) {
      var m = document.querySelector('meta[property="' + p + '"],meta[name="' + p + '"]');
      return m ? m.getAttribute('content') : '';
    }
    var raws = [];
    S.raw.forEach(function (v, k) { if (raws.indexOf(v) < 0) raws.push(v); });
    return {
      href: location.href, title: document.title,
      nextData: nd ? nd.textContent.slice(0, 600000) : null,
      og: { title: meta('og:title'), description: meta('og:description'), image: meta('og:image') },
      netSeq: S.netSeq, netQuietMs: Date.now() - (S.lastNetAt || 0),
      raws: raws.slice(-60).map(shapeRaw),
      text: ownText(document.body).slice(0, 8000)
    };
  }

  window.__gzCO = {
    version: 3,
    state: S,
    log: log, logs: function () { return S.logs.slice(-80); },
    pageInfo: pageInfo, scan: scan, resetFeed: resetFeed, prepareFeed: prepareFeed, markAction: markAction,
    pump: pump, snapshot: snapshot,
    currentSort: currentSortKey, discoverSortOptions: discoverSortOptions, applySort: applySort,
    readDate: readDate, readDateRange: readDateRange, applyDate: applyDate,
    applyNsfw: applyNsfw, applyTags: applyTags,
    typeSearch: typeSearch, openFavorites: openFavorites, openProfileFavorites: openProfileFavorites,
    pageData: pageData, captureInfo: captureInfo, describeControls: describeControls,
    applyFavoritesSort: applyFavoritesSort, currentFavoritesSort: currentFavoritesSort, isNotFound: function () { return isNotFoundDoc(document); },
    isExternalHref: isExternalHref, describeIcons: describeIcons, profileStats: profileStats,
    dismissOverlays: dismissOverlays, settle: settle, sigNow: sigNow,
    _norm: norm, _parseDateText: parseDateText, _findDateControl: findDateControl
  };
})();
