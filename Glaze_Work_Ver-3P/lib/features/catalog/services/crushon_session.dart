import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Safari-like mobile UA **without** the Android WebView `wv` marker.
/// Must match the WebView login sheet exactly: Cloudflare `cf_clearance` is
/// bound to the User-Agent that solved the challenge. Dio must reuse this
/// string or every catalog request is challenged again.
const kCrushOnUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) '
    'Version/17.4 Mobile/15E148 Safari/604.1';

/// Holds Cloudflare clearance + auth cookies captured from the CrushOn
/// WebView login sheet. The catalog provider attaches these on every request
/// so tRPC calls pass the CF challenge that blocks bare HTTP clients.
///
/// Pattern mirrors [SpicyChatWebSession]: the WebView is the source of truth
/// for a live session; this class is the in-memory + prefs cache the Dio
/// client can read without touching the WebView on every page of results.
class CrushOnWebSession {
  CrushOnWebSession._();
  static final CrushOnWebSession instance = CrushOnWebSession._();

  static const _cookieKey = 'gz_crushon_cookie_header';
  static const _cfKey = 'gz_crushon_cf_clearance';
  static const _uaKey = 'gz_crushon_user_agent';

  String? _cookieHeader;
  String? _cfClearance;
  String? _userAgent;
  bool _loaded = false;

  String? get cookieHeader => _cookieHeader;
  String? get cfClearance => _cfClearance;

  /// UA that obtained the cookies / clearance. Always non-empty after load
  /// (falls back to [kCrushOnUserAgent]).
  String get userAgent =>
      (_userAgent != null && _userAgent!.isNotEmpty)
          ? _userAgent!
          : kCrushOnUserAgent;

  bool get hasSession =>
      (_cookieHeader != null && _cookieHeader!.isNotEmpty) ||
      (_cfClearance != null && _cfClearance!.isNotEmpty);

  bool get hasClearance {
    if (_cfClearance != null && _cfClearance!.isNotEmpty) return true;
    final h = _cookieHeader ?? '';
    return h.contains('cf_clearance=');
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _cookieHeader = prefs.getString(_cookieKey);
      _cfClearance = prefs.getString(_cfKey);
      _userAgent = prefs.getString(_uaKey);
    } catch (e) {
      debugPrint('CrushOn session load failed: $e');
    }
  }

  /// Replace the cached session from a WebView cookie dump.
  ///
  /// [cookieHeader] should be a full `Cookie:` value (`a=1; b=2`). When the
  /// dump includes `cf_clearance=…` it is also stored under [cfClearance] for
  /// convenience.
  ///
  /// [userAgent] must be the same string the WebView used when the cookies
  /// were set (CF clearance is UA-bound).
  Future<void> setFromWebView({
    required String cookieHeader,
    String? cfClearance,
    String? userAgent,
  }) async {
    final cleaned = cookieHeader.trim();
    String? clearance = cfClearance?.trim();
    if ((clearance == null || clearance.isEmpty) && cleaned.isNotEmpty) {
      final match = RegExp(r'cf_clearance=([^;]+)').firstMatch(cleaned);
      if (match != null) clearance = match.group(1);
    }
    _cookieHeader = cleaned.isEmpty ? null : cleaned;
    _cfClearance = (clearance == null || clearance.isEmpty) ? null : clearance;
    final ua = (userAgent ?? '').trim();
    _userAgent = ua.isEmpty ? kCrushOnUserAgent : ua;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_cookieHeader == null) {
        await prefs.remove(_cookieKey);
      } else {
        await prefs.setString(_cookieKey, _cookieHeader!);
      }
      if (_cfClearance == null) {
        await prefs.remove(_cfKey);
      } else {
        await prefs.setString(_cfKey, _cfClearance!);
      }
      await prefs.setString(_uaKey, _userAgent!);
    } catch (e) {
      debugPrint('CrushOn session persist failed: $e');
    }
  }

  Future<void> clear() async {
    _cookieHeader = null;
    _cfClearance = null;
    _userAgent = null;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cookieKey);
      await prefs.remove(_cfKey);
      await prefs.remove(_uaKey);
    } catch (_) {}
  }
}

bool isCrushOnHost(Uri? url) {
  if (url == null) return false;
  final host = url.host.toLowerCase();
  return host == 'crushon.ai' ||
      host.endsWith('.crushon.ai') ||
      host == 'www.crushon.ai' ||
      host == 'chat.crushon.ai';
}

bool isCrushOnAuthPath(Uri? url) {
  if (url == null) return false;
  final path = url.path.toLowerCase();
  return path.contains('/login') ||
      path.contains('/signup') ||
      path.contains('/register') ||
      path.contains('/signin') ||
      path.contains('/auth') ||
      path.contains('/account');
}

/// Whether the hidden CrushOn reader browser may navigate to [url].
///
/// The reader only ever needs crushon.ai (plus its image CDN and Cloudflare's
/// check). crushon.ai's sidebar/footer carries social links (Discord, Reddit,
/// X, Telegram...); a click that reaches one is a real navigation, and on iOS a
/// reddit.com link is handed to the Reddit app / Safari. Everything off-site is
/// therefore cancelled instead of followed.
bool isCrushOnReaderAllowedUrl(Uri? url) {
  if (url == null) return true;
  final scheme = url.scheme.toLowerCase();
  if (scheme == 'about' ||
      scheme == 'blob' ||
      scheme == 'data' ||
      scheme == 'javascript' ||
      scheme == 'file') {
    return true;
  }
  if (scheme != 'http' && scheme != 'https') return false; // reddit://, intent:, mailto:...
  final host = url.host.toLowerCase();
  if (host.isEmpty) return true;
  return isCrushOnHost(url) ||
      host == 'cocdn.co' ||
      host.endsWith('.cocdn.co') ||
      host == 'cloudflare.com' ||
      host.endsWith('.cloudflare.com');
}

/// Community hosts linked from crushon.ai pages that are never a sign-in
/// provider. The interactive sign-in sheet blocks them so a stray tap on a
/// footer icon does not bounce the user out to another app. (Google, Apple,
/// Discord, X and Facebook *can* be OAuth hosts and are deliberately not listed.)
bool isCrushOnSocialPromoHost(Uri? url) {
  if (url == null) return false;
  final host = url.host.toLowerCase();
  bool on(String d) => host == d || host.endsWith('.$d');
  return on('reddit.com') ||
      on('redd.it') ||
      on('t.me') ||
      on('telegram.me') ||
      on('instagram.com') ||
      on('tiktok.com') ||
      on('youtube.com') ||
      on('youtu.be') ||
      on('discord.gg');
}

/// A CrushOn character id from anything a person might paste or a card might
/// carry: a bare id/UUID, `/character/<id>`, `/en/character/<id>/details`,
/// `https://crushon.ai/en/character/<id>/details?shared=true`, ...
String crushonCharacterId(String idOrUrl) {
  final s = idOrUrl.trim();
  final m = RegExp(r'/characters?/([^/?#\s]+)', caseSensitive: false).firstMatch(s);
  if (m != null) return Uri.decodeComponent(m.group(1)!);
  return s;
}
