import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  String? _cookieHeader;
  String? _cfClearance;
  bool _loaded = false;

  String? get cookieHeader => _cookieHeader;
  String? get cfClearance => _cfClearance;
  bool get hasSession =>
      (_cookieHeader != null && _cookieHeader!.isNotEmpty) ||
      (_cfClearance != null && _cfClearance!.isNotEmpty);

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _cookieHeader = prefs.getString(_cookieKey);
      _cfClearance = prefs.getString(_cfKey);
    } catch (e) {
      debugPrint('CrushOn session load failed: $e');
    }
  }

  /// Replace the cached session from a WebView cookie dump.
  ///
  /// [cookieHeader] should be a full `Cookie:` value (`a=1; b=2`). When the
  /// dump includes `cf_clearance=…` it is also stored under [cfClearance] for
  /// convenience.
  Future<void> setFromWebView({
    required String cookieHeader,
    String? cfClearance,
  }) async {
    final cleaned = cookieHeader.trim();
    String? clearance = cfClearance?.trim();
    if ((clearance == null || clearance.isEmpty) && cleaned.isNotEmpty) {
      final match = RegExp(r'cf_clearance=([^;]+)').firstMatch(cleaned);
      if (match != null) clearance = match.group(1);
    }
    _cookieHeader = cleaned.isEmpty ? null : cleaned;
    _cfClearance = (clearance == null || clearance.isEmpty) ? null : clearance;
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
    } catch (e) {
      debugPrint('CrushOn session persist failed: $e');
    }
  }

  Future<void> clear() async {
    _cookieHeader = null;
    _cfClearance = null;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cookieKey);
      await prefs.remove(_cfKey);
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
