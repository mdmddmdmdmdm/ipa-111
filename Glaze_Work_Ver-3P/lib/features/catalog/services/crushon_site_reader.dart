import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'crushon_session.dart';

void _log(String m) => debugPrint('[CrushOn-reader] $m');

const _origin = 'https://crushon.ai';

/// Keeps the reader's hidden desktop-sized browsers from painting over the app
/// on iOS (see AppDelegate.hideDesktopSizedWebViews). No-op elsewhere.
const _hiddenWebViews = MethodChannel('app.glaze.flutter/hidden_webviews');
Future<void> _hideReaderViews() async {
  if (kIsWeb || !Platform.isIOS) return;
  try {
    await _hiddenWebViews.invokeMethod<void>('hide');
  } catch (_) {}
}
const _readerAsset = 'assets/crushon/site_reader.js';

/// Marker the iOS side looks for in a web view's injected user script to know
/// the view is one of the reader's hidden browsers (see AppDelegate). It is a
/// JS comment, so the website never sees it.
const _readerMarker = '/*GLAZE_HIDDEN_READER*/';

/// Native rules that stop every video / audio request in the reader's browsers.
/// WebKit's rule syntax has no alternation (`a|b`), so one simple rule each.
final List<ContentBlocker> _mediaBlockers = <ContentBlocker>[
  ContentBlocker(
    trigger: ContentBlockerTrigger(
      urlFilter: '.*',
      resourceType: [ContentBlockerTriggerResourceType.MEDIA],
    ),
    action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
  ),
  for (final ext in const ['mp4', 'webm', 'm4v', 'mov', 'm3u8', 'mpd'])
    ContentBlocker(
      trigger: ContentBlockerTrigger(urlFilter: '.*\\.$ext'),
      action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
    ),
];

/// Thrown when the reader cannot do what was asked. [message] is shown to the
/// user as-is, so it always says what failed and what to try.
class CrushOnReaderException implements Exception {
  final String message;
  const CrushOnReaderException(this.message);
  @override
  String toString() => message;
}

/// Thrown into a queued job that a newer request replaced. Callers that
/// already have a newer search in flight simply drop it.
class CrushOnSuperseded implements Exception {
  const CrushOnSuperseded();
  @override
  String toString() => 'CrushOn request superseded';
}

/// One card exactly as the site shows it.
class CrushOnReadItem {
  final String id;
  final String href;
  final String name;
  final String img;
  final double? boxW;
  final double? boxH;
  final String fit;
  final String pos;

  /// Position badge the site prints on Daily Ranking cards (null elsewhere),
  /// and its note: `Debut!`, `↑3` (places gained) or `↓2` (places lost).
  final int? rank;
  final String rankNote;

  /// The JSON object the site itself fetched for this card (tags, counts,
  /// full-size art…), when the page loaded one.
  final Map<String, dynamic>? raw;

  const CrushOnReadItem({
    required this.id,
    required this.href,
    required this.name,
    required this.img,
    this.boxW,
    this.boxH,
    this.fit = '',
    this.pos = '',
    this.rank,
    this.rankNote = '',
    this.raw,
  });

  factory CrushOnReadItem.fromJson(Map<String, dynamic> j) {
    double? w, h;
    final box = j['box'];
    if (box is List && box.length == 2) {
      w = (box[0] as num?)?.toDouble();
      h = (box[1] as num?)?.toDouble();
    }
    final raw = j['raw'];
    return CrushOnReadItem(
      id: (j['id'] ?? '').toString(),
      href: (j['href'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      img: (j['img'] ?? '').toString(),
      boxW: w,
      boxH: h,
      fit: (j['fit'] ?? '').toString(),
      pos: (j['pos'] ?? '').toString(),
      rank: (j['rank'] as num?)?.toInt(),
      rankNote: (j['rankNote'] ?? '').toString(),
      raw: raw is Map ? Map<String, dynamic>.from(raw) : null,
    );
  }
}

/// A window of the site's list.
class CrushOnPage {
  final List<CrushOnReadItem> items;

  /// True when there is nothing after [items] on the site.
  final bool exhausted;

  /// Whether more items exist beyond this window.
  final bool hasMore;

  const CrushOnPage({
    required this.items,
    required this.exhausted,
    required this.hasMore,
  });
}

/// What the site's Daily Ranking date control currently shows.
class CrushOnDailyInfo {
  final bool hasControl;

  /// The label exactly as the site prints it ("Oct 11").
  final String label;
  final String? iso;
  final String? minIso;
  final String? maxIso;

  const CrushOnDailyInfo({
    this.hasControl = false,
    this.label = '',
    this.iso,
    this.minIso,
    this.maxIso,
  });
}

/// Live, site-reported date for the Daily Ranking chip.
final ValueNotifier<CrushOnDailyInfo> crushOnDailyInfo =
    ValueNotifier<CrushOnDailyInfo>(const CrushOnDailyInfo());

/// Card-art framing measured from the site's own cards, so the app crops
/// images the same way the site does instead of guessing.
class CrushOnImageHints {
  CrushOnImageHints._();

  /// width / height of the site's card image box.
  static double aspect = 3 / 4;
  static bool contain = false;
  static double alignX = 0; // -1 left .. 1 right
  static double alignY = 0; // -1 top  .. 1 bottom
  static bool measured = false;

  static void updateFrom(List<CrushOnReadItem> items) {
    final ratios = <double>[];
    String fit = '';
    String pos = '';
    for (final i in items) {
      final w = i.boxW, h = i.boxH;
      if (w != null && h != null && w > 20 && h > 20) {
        ratios.add(w / h);
        if (fit.isEmpty && i.fit.isNotEmpty) fit = i.fit;
        if (pos.isEmpty && i.pos.isNotEmpty) pos = i.pos;
      }
    }
    if (ratios.length < 2) return;
    ratios.sort();
    final median = ratios[ratios.length ~/ 2];
    aspect = median.clamp(0.5, 1.8).toDouble();
    contain = fit == 'contain' || fit == 'scale-down';
    final a = _parsePos(pos);
    alignX = a.$1;
    alignY = a.$2;
    measured = true;
  }

  static (double, double) _parsePos(String pos) {
    if (pos.isEmpty) return (0, 0);
    double axis(String t, bool horizontal) {
      switch (t) {
        case 'left':
          return -1;
        case 'right':
          return 1;
        case 'top':
          return -1;
        case 'bottom':
          return 1;
        case 'center':
          return 0;
      }
      if (t.endsWith('%')) {
        final v = double.tryParse(t.substring(0, t.length - 1));
        if (v != null) return (v / 50 - 1).clamp(-1.0, 1.0).toDouble();
      }
      return 0;
    }

    final parts = pos.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return (axis(parts[0], true), 0);
    return (axis(parts[0], true), axis(parts[1], false));
  }
}

/// A view the worker is currently showing, so repeated page loads continue the
/// same infinite scroll instead of re-driving the UI.
class _ViewState {
  String key = '';
  final List<CrushOnReadItem> cache = [];
  bool exhausted = false;
}

/// One hidden browser showing crushon.ai.
class _Worker {
  _Worker(this.name, {required this.width, required this.height});

  final String name;
  final double width;
  final double height;

  HeadlessInAppWebView? _hv;
  InAppWebViewController? _c;
  Completer<void>? _starting;
  Completer<void>? _loadStop;
  Future<void> _gate = Future<void>.value();
  String? _source;
  Timer? _idle;

  final _ViewState view = _ViewState();
  Duration idleDispose = const Duration(minutes: 8);

  Future<T> run<T>(Future<T> Function() job) {
    final done = Completer<T>();
    _gate = _gate.then((_) async {
      _idle?.cancel();
      unawaited(_hideReaderViews());
      // The reader scrolls for many seconds per job; re-assert "hidden" the
      // whole time instead of only when the job starts.
      final keepHidden = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => unawaited(_hideReaderViews()),
      );
      try {
        done.complete(await job());
      } catch (e, st) {
        done.completeError(e, st);
      } finally {
        keepHidden.cancel();
        unawaited(_hideReaderViews());
        _idle = Timer(idleDispose, () {
          _log('$name idle — disposing');
          unawaited(dispose());
        });
      }
    });
    return done.future;
  }

  Future<String> _readerSource() async =>
      _source ??= await rootBundle.loadString(_readerAsset);

  Future<void> ensureStarted() {
    if (_c != null) return Future<void>.value();
    final existing = _starting;
    if (existing != null) return existing.future;
    final c = Completer<void>();
    _starting = c;
    _start().then((_) {
      _starting = null;
      c.complete();
    }).catchError((Object e, StackTrace st) {
      _starting = null;
      c.completeError(e, st);
    });
    return c.future;
  }

  Future<void> _start() async {
    _log('$name: starting');
    await CrushOnWebSession.instance.ensureLoaded();
    await _seedCookies();
    final source = await _readerSource();
    final created = Completer<void>();
    _loadStop = Completer<void>();
    final hv = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_origin)),
      initialSize: Size(width, height),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: '$_readerMarker\n$source',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        cacheEnabled: true,
        thirdPartyCookiesEnabled: true,
        sharedCookiesEnabled: true,
        isInspectable: false,
        useHybridComposition: true,
        userAgent: CrushOnWebSession.instance.userAgent,
        // This browser is invisible and driven by script: it must never open
        // windows or follow links off crushon.ai (social icons: Reddit, Discord...).
        useShouldOverrideUrlLoading: true,
        javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: false,
        // No video, ever. CrushOn cards autoplay preview videos; on iOS a playing
        // <video> in a hidden web view is handed to the system's FULL-SCREEN player,
        // which takes over the whole app (the pop-ups while scrolling). The reader
        // only needs the pictures, so: play inline (never full-screen), nothing
        // starts without a tap, no picture-in-picture / AirPlay, and every media
        // request is blocked natively. site_reader.js also disables <video> itself.
        allowsInlineMediaPlayback: true,
        mediaPlaybackRequiresUserGesture: true,
        allowsPictureInPictureMediaPlayback: false,
        allowsAirPlayForMediaPlayback: false,
        contentBlockers: _mediaBlockers,
      ),
      shouldOverrideUrlLoading: (controller, action) async {
        // Sub-frames (ads, Cloudflare widgets, analytics) are not navigations the
        // user would ever see; only top-level page changes can leave the site.
        if (action.isForMainFrame == false) return NavigationActionPolicy.ALLOW;
        final url = action.request.url;
        if (isCrushOnReaderAllowedUrl(url)) return NavigationActionPolicy.ALLOW;
        _log('$name: blocked off-site navigation to ${url?.host}');
        return NavigationActionPolicy.CANCEL;
      },
      onCreateWindow: (controller, action) async {
        _log('$name: blocked new window ${action.request.url?.host}');
        return false;
      },
      onWebViewCreated: (controller) {
        _c = controller;
        if (!created.isCompleted) created.complete();
      },
      onLoadStop: (controller, url) async {
        // The document-start script normally already ran; this is a harmless
        // safety net (the script is idempotent) for engines that skip it.
        try {
          await controller.evaluateJavascript(source: source);
        } catch (_) {}
        final c = _loadStop;
        if (c != null && !c.isCompleted) c.complete();
      },
    );
    await hv.run();
    _hv = hv;
    unawaited(_hideReaderViews());
    await created.future;
    unawaited(_hideReaderViews());
    await _awaitLoad();
    unawaited(_hideReaderViews());
    await _clearChallenge();
    _log('$name: ready');
  }

  Future<void> _seedCookies() async {
    final header = CrushOnWebSession.instance.cookieHeader;
    if (header == null || header.isEmpty) return;
    final cm = CookieManager.instance();
    for (final part in header.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final n = part.substring(0, eq).trim();
      final v = part.substring(eq + 1).trim();
      if (n.isEmpty) continue;
      try {
        await cm.setCookie(
          url: WebUri(_origin),
          name: n,
          value: v,
          domain: 'crushon.ai',
          path: '/',
          isSecure: true,
        );
      } catch (_) {}
    }
  }

  Future<void> _awaitLoad() async {
    final c = _loadStop;
    if (c == null) return;
    try {
      await c.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      _log('$name: load timeout — continuing');
    }
    // Let the SPA hydrate.
    await Future<void>.delayed(const Duration(milliseconds: 900));
  }

  /// Opens [url] and waits for the document. Never call JS before this.
  Future<void> navigate(String url) async {
    await ensureStarted();
    final c = _c;
    if (c == null) throw const CrushOnReaderException('CrushOn view not available.');
    _loadStop = Completer<void>();
    view.key = '';
    view.cache.clear();
    view.exhausted = false;
    try {
      await c.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } catch (e) {
      _log('$name: loadUrl error $e');
    }
    await _awaitLoad();
    await _clearChallenge();
  }

  /// Waits (up to ~30s) for a Cloudflare interstitial to resolve itself.
  Future<void> _clearChallenge() async {
    for (var i = 0; i < 30; i++) {
      final info = await _tryInfo();
      if (info == null || info['cf'] != true) {
        await _persistCookies();
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw const CrushOnReaderException(
      'CrushOn is showing a Cloudflare check. Open Third-party providers → '
      'CrushOn → Sign in, wait for the full site to load, tap Done, then retry.',
    );
  }

  Future<void> _persistCookies() async {
    try {
      final cookies = await CookieManager.instance().getCookies(url: WebUri(_origin));
      final header = cookies
          .where((x) => x.value.toString().isNotEmpty)
          .map((x) => '${x.name}=${x.value}')
          .join('; ');
      if (header.isNotEmpty) {
        await CrushOnWebSession.instance.setFromWebView(
          cookieHeader: header,
          userAgent: CrushOnWebSession.instance.userAgent,
        );
      }
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _tryInfo() async {
    try {
      final r = await js('return JSON.stringify(__gzCO.pageInfo());', timeout: 8);
      return r is Map<String, dynamic> ? r : null;
    } catch (_) {
      return null;
    }
  }

  /// Runs [body] as an async function in the page and decodes its JSON result.
  Future<dynamic> js(String body, {int timeout = 60}) async {
    final c = _c;
    if (c == null) throw const CrushOnReaderException('CrushOn view not available.');
    CallAsyncJavaScriptResult? res;
    try {
      res = await c
          .callAsyncJavaScript(functionBody: body)
          .timeout(Duration(seconds: timeout));
    } on TimeoutException {
      throw const CrushOnReaderException('CrushOn took too long to respond. Try again.');
    }
    if (res == null) throw const CrushOnReaderException('CrushOn view returned nothing.');
    if (res.error != null) {
      throw CrushOnReaderException('CrushOn page script error: ${res.error}');
    }
    final v = res.value;
    if (v is String) {
      if (v.isEmpty) return null;
      try {
        return jsonDecode(v);
      } catch (_) {
        return v;
      }
    }
    return v;
  }

  Future<void> invalidate() => dispose();

  Future<void> dispose() async {
    _idle?.cancel();
    final hv = _hv;
    _hv = null;
    _c = null;
    _starting = null;
    _loadStop = null;
    view.key = '';
    view.cache.clear();
    view.exhausted = false;
    try {
      await hv?.dispose();
    } catch (_) {}
  }
}

/// Reads crushon.ai by driving the real site.
///
/// CrushOn is a Next.js SPA: choosing "Popular" or "Daily Ranking" never
/// changes the URL, and the list is an infinite scroll with no page numbers, so
/// there is no URL (and no stable private API) to call. Instead this clicks the
/// real controls in a hidden browser, scrolls the real list, and reports the
/// cards in the exact order the site shows them.
class CrushOnSiteReader {
  CrushOnSiteReader._();
  static final CrushOnSiteReader instance = CrushOnSiteReader._();

  // Wide layout: sidebar and filter chips are visible without extra taps.
  final _Worker _feed = _Worker('feed', width: 1100, height: 1000);
  final _Worker _aux = _Worker('aux', width: 1100, height: 1000);
  final _Worker _detail = _Worker('detail', width: 1100, height: 1000);

  int _feedGen = 0;
  String? _latestDailyIso;
  int _auxGen = 0;

  static const _maxRaw = 900;

  Future<void> invalidate() async {
    await _feed.dispose();
    await _aux.dispose();
    await _detail.dispose();
  }

  /// A same-origin GET from inside the signed-in CrushOn page, so the request
  /// carries the account's own session cookies. Returns `{status, body}` where
  /// body is the raw response text. Used by the Provider Characters tab to read
  /// the account's chat history.
  Future<Map<String, dynamic>> fetchSessionJson(String path) {
    final url = path.startsWith('http') ? path : '$_origin$path';
    return _aux.run(() async {
      await _aux.ensureStarted();
      await _aux.navigate('$_origin/');
      final r = await _aux.js(
        'const res = await fetch(${jsonEncode(url)}, '
        '{credentials: "include", headers: {"accept": "application/json"}});'
        'const body = await res.text();'
        'return JSON.stringify({status: res.status, body: body});',
        timeout: 45,
      );
      if (r is Map) return Map<String, dynamic>.from(r);
      return <String, dynamic>{'status': 0, 'body': ''};
    });
  }

  // ------------------------------------------------------------------ browse

  /// A window [from]..[to) of the home feed for the given sort / filters.
  ///
  /// [sortKey] is the Glaze key (`popular`, `recent_hits`, `trending`, `new`,
  /// `daily_ranking`, `editor_choice`, `following`).
  Future<CrushOnPage> browse({
    required String sortKey,
    required bool nsfw,
    required List<String> tags,
    String? date,
    required int from,
    required int to,
  }) {
    final gen = ++_feedGen;
    final tagKey = (List<String>.from(tags)..sort()).join(',');
    final key = 'browse|$sortKey|${date ?? ''}|$nsfw|$tagKey';
    return _feed.run(() async {
      void check() {
        if (gen != _feedGen) throw const CrushOnSuperseded();
      }

      check();
      await _feed.ensureStarted();
      check();
      final v = _feed.view;
      if (v.key != key) {
        final hadTags = v.key.isNotEmpty && !v.key.endsWith('|');
        final needFresh = hadTags || tags.isNotEmpty || !await _onHome(_feed);
        if (needFresh) await _feed.navigate('$_origin/');
        check();
        await _applyBrowse(_feed, sortKey, nsfw, tags, date, check);
        check();
        await _feed.js('return JSON.stringify(await __gzCO.prepareFeed());');
        v.cache.clear();
        v.exhausted = false;
        v.key = key;
      }
      return _window(_feed, from, to, check, nsfwGuard: !nsfw, tags: tags);
    });
  }

  Future<bool> _onHome(_Worker w) async {
    final info = await w._tryInfo();
    final href = (info?['href'] ?? '').toString();
    final uri = Uri.tryParse(href);
    if (uri == null) return false;
    final p = uri.path;
    return p == '/' || RegExp(r'^/[a-z]{2}(-[A-Za-z]{2})?/?$').hasMatch(p);
  }

  Future<void> _applyBrowse(
    _Worker w,
    String sortKey,
    bool nsfw,
    List<String> tags,
    String? date,
    void Function() check,
  ) async {
    final info = await w._tryInfo();
    if (sortKey == 'following' && info?['loggedOut'] == true) {
      throw const CrushOnReaderException('Sign in to CrushOn to see Following.');
    }

    final sort = await w.js(
      'return JSON.stringify(await __gzCO.applySort(${jsonEncode(sortKey)}));',
      timeout: 40,
    );
    check();
    if (sort is! Map || sort['ok'] != true) {
      final reason = sort is Map ? '${sort['reason']}' : 'unknown';
      final controls = sort is Map && sort['controls'] is List
          ? (sort['controls'] as List).take(25).join(' · ')
          : '';
      _log('applySort failed: $sort');
      throw CrushOnReaderException(
        'Could not select "$sortKey" on crushon.ai ($reason). '
        'The site layout may have changed.'
        '${controls.isEmpty ? '' : ' Controls seen: $controls'}',
      );
    }
    _log('sort -> ${sort['label']} steps=${sort['steps']}');

    // NSFW switch (best effort; items are also guarded on the Dart side).
    try {
      final r = await w.js(
        'return JSON.stringify(await __gzCO.applyNsfw(${nsfw ? 'true' : 'false'}));',
        timeout: 25,
      );
      _log('nsfw sync -> $r');
    } catch (e) {
      _log('nsfw sync failed: $e');
    }
    check();

    if (tags.isNotEmpty) {
      try {
        final r = await w.js(
          'return JSON.stringify(await __gzCO.applyTags(${jsonEncode(tags)}));',
          timeout: 60,
        );
        _log('tags -> $r');
        // Tags UI may have reset the sort; re-assert it (no-op when unchanged).
        await w.js(
          'return JSON.stringify(await __gzCO.applySort(${jsonEncode(sortKey)}));',
          timeout: 40,
        );
      } catch (e) {
        _log('tags failed: $e');
      }
      check();
    }

    if (sortKey == 'daily_ranking') {
      await _syncDaily(w, date, check);
    } else if (crushOnDailyInfo.value.hasControl) {
      crushOnDailyInfo.value = const CrushOnDailyInfo();
    }
  }

  Future<void> _syncDaily(_Worker w, String? date, void Function() check) async {
    Future<CrushOnDailyInfo> read() async {
      final d = await w.js('return JSON.stringify(__gzCO.readDate());', timeout: 15);
      if (d is Map && d['has'] == true) {
        return CrushOnDailyInfo(
          hasControl: true,
          label: (d['label'] ?? '').toString(),
          iso: d['iso']?.toString(),
          minIso: (d['min'] ?? '').toString().isEmpty ? null : d['min'].toString(),
          maxIso: (d['max'] ?? '').toString().isEmpty ? null : d['max'].toString(),
        );
      }
      return const CrushOnDailyInfo();
    }

    CrushOnDailyInfo withLatest(CrushOnDailyInfo i) {
      final iso = i.iso;
      if (iso != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(iso)) {
        final cur = _latestDailyIso;
        if (cur == null || iso.compareTo(cur) > 0) _latestDailyIso = iso;
      }
      if (i.maxIso != null || _latestDailyIso == null) return i;
      return CrushOnDailyInfo(
        hasControl: i.hasControl,
        label: i.label,
        iso: i.iso,
        minIso: i.minIso,
        maxIso: _latestDailyIso,
      );
    }

    var info = withLatest(await read());
    crushOnDailyInfo.value = info;
    // Ask the site's own calendar which days it allows (it may allow days the
    // app has never seen, e.g. the 10th), and use that for the picker bounds.
    try {
      final rr = await w.js(
        'return JSON.stringify(await __gzCO.readDateRange());',
        timeout: 25,
      );
      if (rr is Map && rr['has'] == true) {
        final mx = (rr['max'] ?? '').toString();
        final mn = (rr['min'] ?? '').toString();
        final iso = RegExp(r'^\d{4}-\d{2}-\d{2}$');
        if (iso.hasMatch(mx)) _latestDailyIso = mx;
        info = CrushOnDailyInfo(
          hasControl: true,
          label: info.label,
          iso: info.iso,
          minIso: iso.hasMatch(mn) ? mn : info.minIso,
          maxIso: iso.hasMatch(mx) ? mx : info.maxIso,
        );
        crushOnDailyInfo.value = info;
      }
    } catch (e) {
      _log('readDateRange failed: $e');
    }
    final want = (date ?? '').trim();
    final isIso = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(want);
    if (info.hasControl && isIso && info.iso != want) {
      try {
        final r = await w.js(
          'return JSON.stringify(await __gzCO.applyDate(${jsonEncode(want)}));',
          timeout: 40,
        );
        _log('date $want -> $r');
        check();
        await w.js(
          'return JSON.stringify(await __gzCO.settle("", 5000));',
          timeout: 15,
        );
      } catch (e) {
        _log('applyDate failed: $e');
      }
      final keepMin = info.minIso;
      final after = withLatest(await read());
      info = CrushOnDailyInfo(
        hasControl: after.hasControl,
        label: after.label,
        iso: after.iso,
        minIso: after.minIso ?? keepMin,
        maxIso: after.maxIso,
      );
      crushOnDailyInfo.value = info;
    }
  }

  // ------------------------------------------------------------------ search

  Future<CrushOnPage> search({
    required String query,
    required bool nsfw,
    required int from,
    required int to,
  }) {
    final gen = ++_auxGen;
    final key = 'search|$query|$nsfw';
    return _aux.run(() async {
      void check() {
        if (gen != _auxGen) throw const CrushOnSuperseded();
      }

      check();
      await _aux.ensureStarted();
      final v = _aux.view;
      if (v.key != key) {
        await _aux.navigate('$_origin/search');
        check();
        try {
          await _aux.js(
            'return JSON.stringify(await __gzCO.applyNsfw(${nsfw ? 'true' : 'false'}));',
            timeout: 25,
          );
        } catch (_) {}
        final r = await _aux.js(
          'return JSON.stringify(await __gzCO.typeSearch(${jsonEncode(query)}));',
          timeout: 40,
        );
        check();
        if (r is! Map || r['ok'] != true) {
          final controls = r is Map && r['controls'] is List
              ? (r['controls'] as List).take(20).join(' · ')
              : '';
          throw CrushOnReaderException(
            'Could not find the search box on crushon.ai.'
            '${controls.isEmpty ? '' : ' Controls seen: $controls'}',
          );
        }
        await _aux.js('return JSON.stringify(await __gzCO.prepareFeed());');
        v.cache.clear();
        v.exhausted = false;
        v.key = key;
      }
      return _window(_aux, from, to, check, nsfwGuard: !nsfw, tags: const []);
    });
  }

  // --------------------------------------------------------------- favorites

  // Start on the home page (it always has the sidebar's Profile link); the
  // in-page code then goes to the profile and opens the star tab by itself.
  static const _favoriteUrls = <String>[
    '$_origin/',
    '$_origin/profile',
    '$_origin/account',
    '$_origin/en/account',
  ];

  /// The signed-in account's favourites, read from the profile's star tab.
  ///
  /// [sortKey] is `new` (the site's "Latest") or `popular`, applied through the
  /// profile's own sort dropdown. [nsfw] mirrors the site's "Unfiltered" switch.
  Future<CrushOnPage> favorites({
    String sortKey = 'new',
    bool nsfw = true,
    required int from,
    required int to,
  }) {
    final gen = ++_auxGen;
    final fsort = sortKey == 'popular' ? 'popular' : 'new';
    final key = 'favorites|$fsort|$nsfw';
    return _aux.run(() async {
      void check() {
        if (gen != _auxGen) throw const CrushOnSuperseded();
      }

      check();
      await _aux.ensureStarted();
      final v = _aux.view;
      if (v.key != key) {
        // Only the sort changed and the star tab is still open: just use the
        // dropdown, no need to reload the profile.
        var reused = false;
        if (v.key.startsWith('favorites|') && v.key.endsWith('|$nsfw')) {
          try {
            final cur = await _aux.js(
              'return JSON.stringify(__gzCO.currentFavoritesSort());',
              timeout: 15,
            );
            if (cur is Map && cur['key'] != null) {
              await _applyFavoritesSort(_aux, fsort, check);
              reused = true;
            }
          } catch (e) {
            if (e is CrushOnSuperseded) rethrow;
            _log('favorites sort reuse failed: $e');
          }
        }
        if (!reused) {
          await _openFavoritesFresh(check);
          check();
          try {
            final r = await _aux.js(
              'return JSON.stringify(await __gzCO.applyNsfw(${nsfw ? 'true' : 'false'}));',
              timeout: 25,
            );
            _log('favorites nsfw sync -> $r');
          } catch (e) {
            _log('favorites nsfw sync failed: $e');
          }
          check();
          await _applyFavoritesSort(_aux, fsort, check);
        }
        check();
        await _aux.js('return JSON.stringify(await __gzCO.prepareFeed());');
        v.cache.clear();
        v.exhausted = false;
        v.key = key;
      }
      return _window(_aux, from, to, check, nsfwGuard: !nsfw, tags: const []);
    });
  }

  /// Opens the profile, selects the star tab and its Characters chip, and
  /// scrolls down to the list. Throws a readable error when it cannot.
  Future<void> _openFavoritesFresh(void Function() check) async {
    String lastControls = '';
    String lastReason = '';
    String lastIcons = '';
    var found = false;
    var signedOutSeen = false;
    for (final url in _favoriteUrls) {
      await _aux.navigate(url);
      check();
      final info = await _aux._tryInfo();
      final href = (info?['href'] ?? '').toString();
      if (href.contains('/auth/signin') || href.contains('/login')) {
        throw const CrushOnReaderException(
          'Sign in to CrushOn to view your favorites. Open Settings > '
          'Providers > CrushOn, sign in, wait for the site to load, tap Done.',
        );
      }
      if (info?['notFound'] == true) {
        _log('favorites: $url is a 404 page, trying the next address');
        continue;
      }
      if (info?['loggedOut'] == true && !href.contains('favorite')) {
        signedOutSeen = true;
      }
      // No shortcut on the URL: a '?tab=favorites' address can still show the
      // user's OWN characters. openFavorites() below opens the star tab and
      // confirms it by what the page shows before any card is read.
      final r = await _aux.js(
        'return JSON.stringify(await __gzCO.openFavorites());',
        timeout: 60,
      );
      check();
      if (r is Map && r['ok'] == true) {
        _log('favorites tab clicked: ${r['label']}');
        found = true;
        break;
      }
      if (r is Map && r['controls'] is List) {
        lastControls = (r['controls'] as List).take(30).join(' · ');
      }
      if (r is Map && r['reason'] != null) lastReason = r['reason'].toString();
      if (r is Map && r['icons'] is List) {
        lastIcons = (r['icons'] as List).take(20).join(' ');
      }
      _log('favorites attempt at $url -> $r');
    }
    if (!found && signedOutSeen) {
      throw const CrushOnReaderException(
        'Sign in to CrushOn to view your favorites. Open Settings > '
        'Providers > CrushOn, sign in, wait for the site to load, tap Done.',
      );
    }
    if (!found) {
      throw CrushOnReaderException(
        'Could not open the star (Favorites) tab on your CrushOn profile'
        '${lastReason.isEmpty ? '' : ' ($lastReason)'}. '
        'Icons seen: ${lastIcons.isEmpty ? 'none' : lastIcons}. '
        'Controls seen: ${lastControls.isEmpty ? 'none' : lastControls}',
      );
    }
  }

  /// Uses the profile's own "Latest / Popular" dropdown. "Latest" is what the
  /// site opens on, so a miss there is harmless; a miss on "Popular" would show
  /// the wrong order under a "Popular" label, so that one is reported.
  Future<void> _applyFavoritesSort(
    _Worker w,
    String sortKey,
    void Function() check,
  ) async {
    try {
      final r = await w.js(
        'return JSON.stringify(await __gzCO.applyFavoritesSort(${jsonEncode(sortKey)}));',
        timeout: 45,
      );
      check();
      _log('favorites sort $sortKey -> $r');
      if (r is Map && r['ok'] != true && sortKey != 'new') {
        final controls = r['controls'] is List
            ? (r['controls'] as List).take(25).join(' · ')
            : '';
        throw CrushOnReaderException(
          'Could not switch your CrushOn favorites to "$sortKey" (${r['reason']}). '
          'The site layout may have changed.'
          '${controls.isEmpty ? '' : ' Controls seen: $controls'}',
        );
      }
    } on CrushOnReaderException {
      rethrow;
    } on CrushOnSuperseded {
      rethrow;
    } catch (e) {
      _log('favorites sort failed: $e');
      if (sortKey != 'new') rethrow;
    }
  }

  // ------------------------------------------------------------- shared pump

  static bool _isNsfw(CrushOnReadItem i) {
    final r = i.raw;
    if (r == null) return false;
    return r['nsfw'] == true || r['isNsfw'] == true || r['is_nsfw'] == true;
  }

  static bool _hasTags(CrushOnReadItem i, List<String> tags) {
    final r = i.raw;
    if (r == null || r['tags'] is! List) return true; // cannot tell: keep
    String k(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final have = <String>{};
    for (final t in (r['tags'] as List)) {
      if (t is Map) {
        have.add(k('${t['name'] ?? t['label'] ?? t['tag'] ?? ''}'));
      } else {
        have.add(k('$t'));
      }
    }
    return tags.every((t) => have.contains(k(t)));
  }

  Future<CrushOnPage> _window(
    _Worker w,
    int from,
    int to,
    void Function() check, {
    required bool nsfwGuard,
    required List<String> tags,
  }) async {
    final v = w.view;
    List<CrushOnReadItem> filtered() => [
          for (final i in v.cache)
            if (!(nsfwGuard && _isNsfw(i)) && (tags.isEmpty || _hasTags(i, tags))) i,
        ];

    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (filtered().length < to &&
        !v.exhausted &&
        v.cache.length < _maxRaw &&
        DateTime.now().isBefore(deadline)) {
      check();
      final start = v.cache.length;
      final want = start + 24;
      final res = await w.js(
        'return JSON.stringify(await __gzCO.pump($start, $want, 9000));',
        timeout: 45,
      );
      check();
      if (res is! Map) break;
      final items = (res['items'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => CrushOnReadItem.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      v.cache.addAll(items);
      final total = (res['total'] as num?)?.toInt() ?? v.cache.length;
      if (res['exhausted'] == true && total <= v.cache.length) v.exhausted = true;
      if (items.isEmpty && res['exhausted'] == true) v.exhausted = true;
      if (items.isEmpty && res['exhausted'] != true) {
        // The page produced nothing and gave no end marker: avoid spinning.
        v.exhausted = true;
      }
    }

    final f = filtered();
    final slice = f.length > from ? f.sublist(from, f.length < to ? f.length : to) : <CrushOnReadItem>[];
    if (from == 0 && slice.isNotEmpty) CrushOnImageHints.updateFrom(slice);
    return CrushOnPage(
      items: slice,
      exhausted: v.exhausted && f.length <= to,
      hasMore: f.length > to || !v.exhausted,
    );
  }

  // ---------------------------------------------------------------- detail

  /// Opens a character page and returns everything the page loaded.
  ///
  /// [idOrPath] may be a bare id, `/character/<id>`, or any pasted crushon.ai
  /// link (`.../en/character/<id>/details?shared=true`). The real page lives at
  /// `/character/<id>/details`; the bare `/character/<id>` route can be the
  /// site's "404 Page Not Found" page, which used to end up as the character's
  /// description.
  Future<Map<String, dynamic>> characterPage(String idOrPath) {
    return _detail.run(() async {
      final id = crushonCharacterId(idOrPath);
      final enc = Uri.encodeComponent(id);
      final candidates = <String>[
        '/character/$enc/details',
        '/en/character/$enc/details',
        '/character/$enc',
      ];
      var opened = false;
      for (final path in candidates) {
        await _detail.navigate('$_origin$path');
        final info = await _detail._tryInfo();
        if (info?['notFound'] == true) {
          _log('character page $path is a 404 page, trying the next address');
          continue;
        }
        opened = true;
        break;
      }
      if (!opened) {
        throw const CrushOnReaderException(
          'CrushOn says this character page was not found. It may have been '
          'removed or made private.',
        );
      }
      Map<String, dynamic> data = const {};
      for (var i = 0; i < 14; i++) {
        final d = await _detail.js(
          'return JSON.stringify(__gzCO.pageData());',
          timeout: 20,
        );
        if (d is Map) {
          data = Map<String, dynamic>.from(d);
          final quiet = (data['netQuietMs'] as num?)?.toInt() ?? 0;
          final seq = (data['netSeq'] as num?)?.toInt() ?? 0;
          if (seq > 0 && quiet > 1200) break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      // The site's own description (styled HTML, pictures, tables). Best effort:
      // a failure here never blocks the import. A 404 page is never accepted.
      try {
        final info = await _detail.js(
          'return JSON.stringify(await __gzCO.captureInfo(${jsonEncode(id)}));',
          timeout: 60,
        );
        if (info is Map && info['ok'] == true) {
          _log('captureInfo ok via ${info['source']}');
          data = {...data, 'info': Map<String, dynamic>.from(info)};
        } else {
          _log('captureInfo: ${info is Map ? info['reason'] : 'no result'}');
        }
      } catch (e) {
        _log('captureInfo failed: $e');
      }
      return data;
    });
  }
}
