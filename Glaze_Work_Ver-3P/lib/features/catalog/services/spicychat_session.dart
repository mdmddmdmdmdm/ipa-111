import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Origins whose cookies make up a SpicyChat web session.
const _spicyOrigins = <String>[
  'https://spicychat.ai',
  'https://www.spicychat.ai',
  'https://prod.nd-api.com',
];

/// Google keeps its own session in the shared web view. It is wiped on every
/// fresh sign-in so "Continue with Google" shows the account picker instead of
/// silently signing in with whichever account happened to be there.
const _googleOrigins = <String>[
  'https://accounts.google.com',
  'https://google.com',
  'https://www.google.com',
  'https://apis.google.com',
  'https://accounts.youtube.com',
  'https://myaccount.google.com',
];

/// Safari-like mobile UA **without** the Android WebView `wv` marker.
/// SpicyChat (and Google OAuth) serve a stripped or broken layout to default
/// WebView UAs; this makes the embedded site match the real mobile site and
/// keeps OAuth flows working.
const kSpicyChatUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) '
    'Version/17.4 Mobile/15E148 Safari/604.1';

/// Shared InAppWebView settings for every SpicyChat surface (login sheet,
/// account browser, headless catalog session) so the site renders like the
/// real mobile site and cookies/storage behave consistently.
InAppWebViewSettings spicyChatWebViewSettings({
  bool clearCache = false,
  bool cacheEnabled = true,
}) {
  return InAppWebViewSettings(
    javaScriptEnabled: true,
    domStorageEnabled: true,
    databaseEnabled: true,
    cacheEnabled: cacheEnabled,
    thirdPartyCookiesEnabled: true,
    sharedCookiesEnabled: true,
    isInspectable: false,
    useHybridComposition: true,
    clearCache: clearCache,
    userAgent: kSpicyChatUserAgent,
    supportZoom: true,
    verticalScrollBarEnabled: true,
    horizontalScrollBarEnabled: false,
    allowsInlineMediaPlayback: true,
    mediaPlaybackRequiresUserGesture: false,
    // Match a normal mobile browser viewport so sticky headers / nav render.
    preferredContentMode: UserPreferredContentMode.MOBILE,
    useWideViewPort: true,
    loadWithOverviewMode: true,
  );
}

bool isSpicyChatHost(WebUri? url) {
  final host = (url?.host ?? '').toLowerCase();
  return host == 'spicychat.ai' ||
      host.endsWith('.spicychat.ai') ||
      host == 'www.spicychat.ai';
}

bool isSpicyChatAuthPath(WebUri? url) {
  final path = (url?.path ?? '').toLowerCase();
  return path.contains('/login') ||
      path.contains('/signup') ||
      path.contains('/register') ||
      path.contains('/onboarding') ||
      path.contains('/verify') ||
      path.contains('/auth') ||
      path.contains('/signin');
}

/// Who the web page says is signed in, read from tokens the site stored.
class SpicyChatIdentity {
  final String? email;
  final String? name;

  /// True when a JWT-style token is present in storage or cookies.
  final bool hasToken;

  const SpicyChatIdentity({this.email, this.name, this.hasToken = false});
}

class SpicyChatCookie {
  final String name;
  final String value;
  final String? domain;
  final String path;
  final int? expires;
  final bool secure;
  final bool httpOnly;

  /// The origin the cookie was read from; used again to write it back.
  final String origin;

  const SpicyChatCookie({
    required this.name,
    required this.value,
    required this.origin,
    this.domain,
    this.path = '/',
    this.expires,
    this.secure = false,
    this.httpOnly = false,
  });

  Map<String, dynamic> toJson() => {
    'n': name,
    'v': value,
    'o': origin,
    if (domain != null) 'd': domain,
    'p': path,
    if (expires != null) 'e': expires,
    'sec': secure,
    'ho': httpOnly,
  };

  static SpicyChatCookie? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['n'];
    final value = raw['v'];
    final origin = raw['o'];
    if (name is! String || value is! String || origin is! String) return null;
    final expires = raw['e'];
    return SpicyChatCookie(
      name: name,
      value: value,
      origin: origin,
      domain: raw['d'] is String ? raw['d'] as String : null,
      path: raw['p'] is String ? raw['p'] as String : '/',
      expires: expires is num ? expires.toInt() : null,
      secure: raw['sec'] == true,
      httpOnly: raw['ho'] == true,
    );
  }
}

/// Everything needed to put a signed-in SpicyChat session back into a clean web
/// view: cookies plus the site's local/session storage. SpicyChat has no
/// password to replay (it emails a code or uses Google/Apple/X/Discord), so the
/// session itself is what gets remembered per account.
class SpicyChatSessionSnapshot {
  final List<SpicyChatCookie> cookies;
  final Map<String, String> local;
  final Map<String, String> session;

  /// The Google sign-in cookies that were present when this account signed in.
  /// Putting them back means "Continue with Google" opens straight onto this
  /// account's Google session instead of an empty Google login.
  final List<SpicyChatCookie> googleCookies;

  const SpicyChatSessionSnapshot({
    this.cookies = const [],
    this.local = const {},
    this.session = const {},
    this.googleCookies = const [],
  });

  bool get isEmpty => cookies.isEmpty && local.isEmpty && session.isEmpty;

  bool get hasGoogle => googleCookies.isNotEmpty;

  String encode() => jsonEncode({
    'v': 2,
    'cookies': [for (final c in cookies) c.toJson()],
    'local': local,
    'session': session,
    'google': [for (final c in googleCookies) c.toJson()],
  });

  static SpicyChatSessionSnapshot? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return null;
      Map<String, String> strings(Object? value) {
        if (value is! Map) return const {};
        return {
          for (final e in value.entries)
            if (e.value is String) e.key.toString(): e.value as String,
        };
      }

      final cookies = <SpicyChatCookie>[];
      final rawCookies = data['cookies'];
      if (rawCookies is List) {
        for (final item in rawCookies) {
          final cookie = SpicyChatCookie.fromJson(item);
          if (cookie != null) cookies.add(cookie);
        }
      }
      final google = <SpicyChatCookie>[];
      final rawGoogle = data['google'];
      if (rawGoogle is List) {
        for (final item in rawGoogle) {
          final cookie = SpicyChatCookie.fromJson(item);
          if (cookie != null) google.add(cookie);
        }
      }
      final snapshot = SpicyChatSessionSnapshot(
        cookies: cookies,
        local: strings(data['local']),
        session: strings(data['session']),
        googleCookies: google,
      );
      return snapshot.isEmpty ? null : snapshot;
    } catch (_) {
      return null;
    }
  }
}

class SpicyChatSessionTools {
  SpicyChatSessionTools._();

  // ---------------------------------------------------------------- cookies

  /// Deletes every SpicyChat cookie (and Google's when [includeGoogle]). Works
  /// on the cookie jar directly, so it needs no page and no waiting.
  static Future<void> wipeCookies({bool includeGoogle = false}) =>
      _wipeOrigins([..._spicyOrigins, if (includeGoogle) ..._googleOrigins]);

  static Future<void> _wipeOrigins(List<String> origins) async {
    final cm = CookieManager.instance();
    for (final origin in origins) {
      final url = WebUri(origin);
      try {
        final cookies = await cm.getCookies(url: url);
        for (final c in cookies) {
          try {
            await cm.deleteCookie(
              url: url,
              name: c.name,
              domain: c.domain,
              path: c.path ?? '/',
            );
          } catch (_) {}
        }
      } catch (_) {}
      try {
        await cm.deleteCookies(url: url);
      } catch (_) {}
    }
  }

  /// Writes the snapshot's cookies back. With [onlyIfMissing] nothing is
  /// written when the jar already holds SpicyChat cookies. With
  /// [includeGoogle] the account's saved Google cookies are put back as well
  /// (Google's current cookies are cleared first, so two accounts never mix).
  /// Returns how many cookies were set.
  static Future<int> restoreCookies(
    SpicyChatSessionSnapshot snapshot, {
    bool onlyIfMissing = false,
    bool includeGoogle = false,
  }) async {
    final cm = CookieManager.instance();
    if (onlyIfMissing) {
      try {
        final existing = await cm.getCookies(url: WebUri(_spicyOrigins.first));
        if (existing.isNotEmpty) return 0;
      } catch (_) {}
    }
    var written = await _writeCookies(cm, snapshot.cookies);
    if (includeGoogle && snapshot.hasGoogle) {
      await _wipeOrigins(_googleOrigins);
      written += await _writeCookies(cm, snapshot.googleCookies);
    }
    return written;
  }

  static Future<int> _writeCookies(
    CookieManager cm,
    List<SpicyChatCookie> cookies,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var written = 0;
    for (final c in cookies) {
      final expires = c.expires;
      if (expires != null && expires <= now) continue;
      try {
        await cm.setCookie(
          url: WebUri(c.origin),
          name: c.name,
          value: c.value,
          path: c.path,
          domain: c.domain,
          expiresDate: expires,
          isSecure: c.secure,
          isHttpOnly: c.httpOnly,
        );
        written++;
      } catch (_) {}
    }
    return written;
  }

  static Future<List<SpicyChatCookie>> _readCookies([
    List<String> origins = _spicyOrigins,
  ]) async {
    final cm = CookieManager.instance();
    final seen = <String>{};
    final out = <SpicyChatCookie>[];
    for (final origin in origins) {
      try {
        final cookies = await cm.getCookies(url: WebUri(origin));
        for (final c in cookies) {
          final key = '${c.name}|${c.domain ?? origin}|${c.path ?? '/'}';
          if (!seen.add(key)) continue;
          out.add(
            SpicyChatCookie(
              name: c.name,
              value: (c.value ?? '').toString(),
              origin: origin,
              domain: c.domain,
              path: c.path ?? '/',
              expires: c.expiresDate,
              secure: c.isSecure ?? false,
              httpOnly: c.isHttpOnly ?? false,
            ),
          );
        }
      } catch (_) {}
    }
    return out;
  }

  // ---------------------------------------------------------------- storage

  static const String _clearStorageJs = r'''
    try { localStorage.clear(); } catch (e) {}
    try { sessionStorage.clear(); } catch (e) {}
    try {
      if (window.indexedDB && indexedDB.databases) {
        const dbs = await indexedDB.databases();
        await Promise.all(dbs.map((d) => new Promise((res) => {
          try {
            const r = indexedDB.deleteDatabase(d.name);
            r.onsuccess = r.onerror = r.onblocked = () => res();
          } catch (e) { res(); }
        })));
      }
    } catch (e) {}
    try {
      document.cookie.split(';').forEach((c) => {
        const n = c.split('=')[0].trim();
        if (n) document.cookie = n + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/';
      });
    } catch (e) {}
    return true;
  ''';

  /// Clears local storage, session storage, IndexedDB and script-visible
  /// cookies of the page [c] is showing. The page must be on spicychat.ai.
  static Future<void> clearStorage(InAppWebViewController c) async {
    try {
      await c
          .callAsyncJavaScript(functionBody: _clearStorageJs)
          .timeout(const Duration(seconds: 6));
    } catch (_) {}
  }

  static const String _captureStorageJs = r'''
    const authish = /(token|auth|cognito|amplify|session|user|login|jwt|credential|supabase|firebase|clerk|persist|sb-)/i;
    const grab = (store) => {
      const rows = [];
      try {
        for (let i = 0; i < store.length; i++) {
          const k = store.key(i);
          const v = store.getItem(k);
          if (typeof v === 'string') rows.push([k, v]);
        }
      } catch (e) {}
      return rows;
    };
    const pack = (rows) => {
      rows.sort((a, b) => (authish.test(b[0]) ? 1 : 0) - (authish.test(a[0]) ? 1 : 0));
      const out = {};
      let total = 0;
      for (const row of rows) {
        const k = row[0];
        const v = row[1];
        if (v.length > 60000) continue;
        if (total + v.length > 300000) continue;
        out[k] = v;
        total += v.length;
      }
      return out;
    };
    if (location.hostname.indexOf('spicychat.ai') < 0) {
      return JSON.stringify({ local: {}, session: {} });
    }
    return JSON.stringify({
      local: pack(grab(window.localStorage)),
      session: pack(grab(window.sessionStorage)),
    });
  ''';

  /// Captures the session [c] currently holds. Returns null when nothing could
  /// be read.
  static Future<SpicyChatSessionSnapshot?> capture(
    InAppWebViewController c,
  ) async {
    final cookies = await _readCookies();
    final google = await _readCookies(_googleOrigins);
    var local = <String, String>{};
    var session = <String, String>{};
    try {
      final result = await c
          .callAsyncJavaScript(functionBody: _captureStorageJs)
          .timeout(const Duration(seconds: 6));
      final value = result?.value;
      if (value is String) {
        final data = jsonDecode(value);
        if (data is Map) {
          Map<String, String> strings(Object? v) => v is Map
              ? {
                  for (final e in v.entries)
                    if (e.value is String) e.key.toString(): e.value as String,
                }
              : <String, String>{};
          local = strings(data['local']);
          session = strings(data['session']);
        }
      }
    } catch (_) {}
    final snapshot = SpicyChatSessionSnapshot(
      cookies: cookies,
      local: local,
      session: session,
      googleCookies: google,
    );
    return snapshot.isEmpty ? null : snapshot;
  }

  /// JS that writes the snapshot's storage into the current spicychat.ai page
  /// and returns `added:N`. With [overwrite] the page's own storage is cleared
  /// first; without it only missing keys are filled in.
  static String restoreStorageJs(
    SpicyChatSessionSnapshot snapshot, {
    required bool overwrite,
  }) {
    final local = jsonEncode(snapshot.local);
    final session = jsonEncode(snapshot.session);
    return '(function(){try{'
        'if(location.hostname.indexOf("spicychat.ai")<0)return "added:0";'
        'var L=$local,S=$session,ow=$overwrite,n=0;'
        'if(ow){try{localStorage.clear();sessionStorage.clear();}catch(e){}}'
        'Object.keys(L).forEach(function(k){try{'
        'if(ow||localStorage.getItem(k)===null){localStorage.setItem(k,L[k]);n++;}'
        '}catch(e){}});'
        'Object.keys(S).forEach(function(k){try{'
        'if(ow||sessionStorage.getItem(k)===null){sessionStorage.setItem(k,S[k]);n++;}'
        '}catch(e){}});'
        'return "added:"+n;}catch(e){return "added:0";}})();';
  }

  // --------------------------------------------------------------- identity

  static const String _identityJs = r'''
    const out = { email: null, name: null, jwt: false };
    const isEmail = (s) => typeof s === 'string' && /^[^@\s]{1,100}@[^@\s]{1,100}\.[^@\s]{1,20}$/.test(s);
    const b64 = (s) => {
      s = s.replace(/-/g, '+').replace(/_/g, '/');
      while (s.length % 4) s += '=';
      return decodeURIComponent(escape(atob(s)));
    };
    const nameKeys = ['preferred_username', 'username', 'nickname', 'display_name', 'displayname', 'handle', 'name'];
    const authKeyRe = /(token|access|id_token|refresh|auth|session|bearer|cognito|amplify|supabase|firebase|clerk|jwt|credential)/i;
    let nameRank = 99;
    const visit = (v, depth, keyHint) => {
      if (v === null || v === undefined || depth > 5) return;
      if (typeof v === 'string') {
        if (/^eyJ[\w-]+\.[\w-]+\.[\w-]*$/.test(v)) {
          out.jwt = true;
          try { visit(JSON.parse(b64(v.split('.')[1])), depth + 1); } catch (e) {}
        } else if (keyHint && authKeyRe.test(keyHint) && v.length > 20 && v.length < 8000) {
          // Opaque access tokens stored under auth-ish keys still count.
          out.jwt = true;
        } else if (v.length < 20000 && (v[0] === '{' || v[0] === '[')) {
          try { visit(JSON.parse(v), depth + 1); } catch (e) {}
        }
        return;
      }
      if (Array.isArray(v)) { v.slice(0, 30).forEach((x) => visit(x, depth + 1)); return; }
      if (typeof v === 'object') {
        Object.keys(v).slice(0, 80).forEach((k) => {
          const x = v[k];
          const kl = k.toLowerCase();
          if (typeof x === 'string') {
            if (!out.email && kl.indexOf('email') >= 0 && isEmail(x)) out.email = x;
            const r = nameKeys.indexOf(kl.replace('cognito:', ''));
            if (r >= 0 && r < nameRank && x.length > 0 && x.length < 60 && !isEmail(x) && !/^[0-9a-f-]{24,}$/i.test(x)) {
              out.name = x;
              nameRank = r;
            }
          }
          visit(x, depth + 1, k);
        });
      }
    };
    const scan = (store) => {
      try {
        for (let i = 0; i < store.length; i++) {
          const k = store.key(i);
          visit(store.getItem(k), 0, k);
        }
      } catch (e) {}
    };
    scan(window.localStorage);
    scan(window.sessionStorage);
    try {
      document.cookie.split(';').forEach((c) => {
        const i = c.indexOf('=');
        if (i > 0) {
          const name = c.slice(0, i).trim();
          visit(decodeURIComponent(c.slice(i + 1).trim()), 0, name);
        }
      });
    } catch (e) {}
    return JSON.stringify(out);
  ''';

  /// Reads the signed-in user's email / username out of the tokens SpicyChat
  /// stored. Used to label the account in the Accounts list.
  static Future<SpicyChatIdentity> readIdentity(
    InAppWebViewController c,
  ) async {
    try {
      final result = await c
          .callAsyncJavaScript(functionBody: _identityJs)
          .timeout(const Duration(seconds: 6));
      final value = result?.value;
      if (value is String) {
        final data = jsonDecode(value);
        if (data is Map) {
          String? text(Object? v) {
            if (v is! String) return null;
            final t = v.trim();
            return t.isEmpty ? null : t;
          }

          return SpicyChatIdentity(
            email: text(data['email']),
            name: text(data['name']),
            hasToken: data['jwt'] == true,
          );
        }
      }
    } catch (_) {}
    return const SpicyChatIdentity();
  }

  /// JS that walks localStorage / sessionStorage for a usable Bearer token
  /// (Kinde / Cognito access token, or any auth-looking JWT / opaque token).
  /// SpicyChat's character detail API requires Authorization: Bearer …
  static const String _accessTokenJs = r'''
    const authKey = /(access[_-]?token|id[_-]?token|bearer|authorization|auth[_-]?token|token|jwt|cognito|kinde|refresh)/i;
    const jwtish = /^[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+$/;
    const candidates = [];
    const visit = (v, depth, key) => {
      if (depth > 6 || v == null) return;
      if (typeof v === 'string') {
        const s = v.trim();
        if (s.length < 20 || s.length > 8000) return;
        // Prefer JWT-looking values under auth keys, then any long token under auth keys.
        const keyScore = (key && authKey.test(key)) ? 2 : 0;
        if (jwtish.test(s)) candidates.push({ t: s, s: keyScore + 3 });
        else if (keyScore > 0 && /^[A-Za-z0-9\-_+/=.]+$/.test(s)) candidates.push({ t: s, s: keyScore + 1 });
        else if ((s[0] === '{' || s[0] === '[') && s.length < 20000) {
          try { visit(JSON.parse(s), depth + 1, key); } catch (e) {}
        }
        return;
      }
      if (Array.isArray(v)) { v.slice(0, 40).forEach((x) => visit(x, depth + 1, key)); return; }
      if (typeof v === 'object') {
        Object.keys(v).slice(0, 100).forEach((k) => visit(v[k], depth + 1, k));
      }
    };
    const scan = (store) => {
      try {
        for (let i = 0; i < store.length; i++) {
          const k = store.key(i);
          visit(store.getItem(k), 0, k);
        }
      } catch (e) {}
    };
    scan(window.localStorage);
    scan(window.sessionStorage);
    candidates.sort((a, b) => b.s - a.s);
    return candidates.length ? candidates[0].t : null;
  ''';

  /// Returns a Bearer token string from the page's storage, or null.
  static Future<String?> readAccessToken(InAppWebViewController c) async {
    try {
      final result = await c
          .callAsyncJavaScript(functionBody: _accessTokenJs)
          .timeout(const Duration(seconds: 6));
      final value = result?.value;
      if (value is String) {
        final t = value.trim();
        if (t.isNotEmpty && t != 'null') return t;
      }
    } catch (_) {}
    return null;
  }

  // -------------------------------------------------------- page automation

  /// Reports the typed email and the sign-in button used back to Flutter, so
  /// the saved account gets a real name and remembers how it signs in.
  static const String authHookJs = r'''
(function(){
  if (window.__glazeAuthHook) return;
  window.__glazeAuthHook = true;
  var emailRe = /^[^@\s]{1,100}@[^@\s]{1,100}\.[^@\s]{1,20}$/;
  var send = function(name, v){
    try { if (window.flutter_inappwebview) window.flutter_inappwebview.callHandler(name, v); } catch (e) {}
  };
  document.addEventListener('input', function(ev){
    var t = ev.target;
    if (t && t.tagName === 'INPUT') {
      var v = (t.value || '').trim();
      if (emailRe.test(v)) send('glazeEmailSeen', v);
    }
  }, true);
  document.addEventListener('click', function(ev){
    var n = ev.target;
    var depth = 0;
    while (n && depth < 5 && !(n.tagName === 'BUTTON' || n.tagName === 'A' || (n.getAttribute && n.getAttribute('role') === 'button'))) {
      n = n.parentElement;
      depth++;
    }
    if (!n) return;
    var t = ((n.innerText || n.textContent || '') + '').toLowerCase();
    var m = null;
    if (t.indexOf('google') >= 0) m = 'google';
    else if (t.indexOf('apple') >= 0) m = 'apple';
    else if (t.indexOf('discord') >= 0) m = 'discord';
    else if (/with x\b/.test(t)) m = 'x';
    if (m) send('glazeMethodSeen', m);
  }, true);
})();
''';

  /// Outlines the button the user should press for [method] (and scrolls it
  /// into view) without clicking anything. Used when the automatic press did
  /// not work, so the one-tap path is obvious. Returns `found` or `none`.
  static String highlightJs(String method) {
    final safeMethod = jsonEncode(method);
    return '''
(function(){
  try {
    var method = $safeMethod;
    var want = method === 'x' ? 'continue with x'
        : (method === 'email' ? 'continue' : 'continue with ' + method);
    var btns = Array.from(document.querySelectorAll('button, a, [role=button]'));
    var b = btns.find(function(n){
      return ((n.innerText || n.textContent || '') + '').toLowerCase().indexOf(want) >= 0;
    });
    if (!b) return 'none';
    b.style.outline = '3px solid #ff4d8d';
    b.style.outlineOffset = '2px';
    b.scrollIntoView({block: 'center'});
    return 'found';
  } catch (e) { return 'none'; }
})()
''';
  }

  /// Presses the sign-in buttons for a saved account: "Continue with <site>"
  /// for Google/Apple/X/Discord accounts, or fills the saved email and presses
  /// Continue so SpicyChat emails the code. Returns `email`, `oauth`,
  /// `waiting`, `noemail` or `err`.
  static String autoPressJs(String? email, String method) {
    final safeEmail = jsonEncode(email ?? '');
    final safeMethod = jsonEncode(method);
    return '''
(function(){
  try {
    var email = $safeEmail;
    var method = $safeMethod;
    var btns = Array.from(document.querySelectorAll('button, a, [role=button]'));
    var textOf = function(n){ return ((n.innerText || n.textContent || '') + '').toLowerCase().trim(); };
    if (method === 'google' || method === 'apple' || method === 'discord' || method === 'x') {
      var want = method === 'x' ? 'continue with x' : 'continue with ' + method;
      var b = btns.find(function(n){ return textOf(n).indexOf(want) >= 0; });
      if (b) {
        try {
          b.style.outline = '3px solid #ff4d8d';
          b.style.outlineOffset = '2px';
          b.scrollIntoView({block: 'center'});
        } catch (e) {}
        b.click();
        return 'oauth';
      }
      return 'waiting';
    }
    if (!email) return 'noemail';
    var input = Array.from(document.querySelectorAll('input')).find(function(i){
      var t = (i.type || '').toLowerCase();
      var hint = ((i.name || '') + (i.id || '') + (i.placeholder || '')).toLowerCase();
      return t === 'email' || (t === 'text' && hint.indexOf('email') >= 0);
    });
    if (!input) return 'waiting';
    if (!input.value) {
      input.focus();
      var d = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
      if (d && d.set) d.set.call(input, email); else input.value = email;
      input.dispatchEvent(new Event('input', {bubbles: true}));
      input.dispatchEvent(new Event('change', {bubbles: true}));
    }
    var go = btns.find(function(n){
      var t = textOf(n);
      return t === 'continue' || t === 'next' || t === 'send code' || t === 'sign in' || t === 'log in';
    });
    if (go) { setTimeout(function(){ go.click(); }, 350); return 'email'; }
    return 'waiting';
  } catch (e) { return 'err'; }
})()
''';
  }
}
