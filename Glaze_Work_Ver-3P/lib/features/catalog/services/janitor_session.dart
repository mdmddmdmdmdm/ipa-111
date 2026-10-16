import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Pure helpers for keeping a JanitorAI account session alive across app
/// launches and Cloudflare challenges. Kept out of the WebView proxy so both
/// rules — what makes a stored session cookie survive, and when the access
/// token it carries has to be refreshed — are testable without a WebView.

/// Whether [name] is one of the Supabase session cookies JanitorAI signs in
/// with (`sb-<ref>-auth-token`, plus its `.0`, `.1`, … chunks).
///
/// These are the only cookies that must survive a Cloudflare cookie wipe: lose
/// one chunk and the session is gone, which is what "logged out again" looks
/// like to the user.
bool isJanitorAuthCookie(String name) =>
    name.startsWith('sb-') && name.contains('-auth-token');

/// How long a restored auth cookie should live, in milliseconds since epoch.
///
/// The expiry read back from the platform cannot be trusted. Android's WebView
/// returns no attributes at all unless `GET_COOKIE_INFO` is supported, and when
/// it is, a `Max-Age` is converted as `now + maxAge` **milliseconds** instead of
/// seconds — so a 400-day cookie reads back as roughly nine hours. Re-setting
/// either value downgrades a persistent login to something that dies with the
/// process (a null expiry makes it session-only), which is exactly the "have to
/// log in again after every launch" report.
///
/// So an expiry is only kept when it is plausibly a real one; anything missing
/// or suspiciously near is replaced with Supabase's own horizon.
int janitorAuthCookieExpiry(int? readBackMs, {required int nowMs}) {
  const minimumPlausible = Duration(days: 2);
  const supabaseDefault = Duration(days: 400);
  if (readBackMs != null &&
      readBackMs - nowMs >= minimumPlausible.inMilliseconds) {
    return readBackMs;
  }
  return nowMs + supabaseDefault.inMilliseconds;
}

/// The expiry stamped in a JWT's `exp` claim, or null when [jwt] carries none
/// that can be read.
DateTime? janitorTokenExpiry(String jwt) {
  final parts = jwt.split('.');
  if (parts.length != 3) return null;
  final Map<String, dynamic> payload;
  try {
    final decoded = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final parsed = jsonDecode(decoded);
    if (parsed is! Map) return null;
    payload = Map<String, dynamic>.from(parsed);
  } on Object {
    return null;
  }
  final exp = payload['exp'];
  if (exp is! num) return null;
  return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true);
}

/// Whether the access token [jwt] is spent — expired, or close enough that a
/// request made with it would arrive after it lapsed.
///
/// JanitorAI's Supabase access token lives about an hour, while the refresh
/// token stored beside it in the same cookie lives for weeks. Glaze never
/// refreshes the pair itself — the page's own Supabase client does, on load —
/// so a session that is perfectly valid still hands out a stale JWT the first
/// time the app is opened the next day. Every authenticated call then answers
/// 401 and reads as "session expired, log in again" when nothing of the sort
/// happened: the page just has to reload first.
///
/// A token with no readable `exp` is treated as usable — a request that fails
/// says more than a guess here.
bool isJanitorTokenExpired(
  String jwt, {
  Duration skew = const Duration(seconds: 60),
  DateTime? now,
}) {
  final expiry = janitorTokenExpiry(jwt);
  if (expiry == null) return false;
  final at = (now ?? DateTime.now().toUtc()).add(skew);
  return !expiry.isAfter(at);
}

/// Whether a request to [url] may be retried without the account's access
/// token after janitorai.com refused the one it carried.
///
/// Browsing JanitorAI needs no account — the feed, a card's metadata, the tag
/// list and a card's reviews all answer an anonymous reader. Glaze sends the
/// bearer token anyway, because one WebView session serves everything, so a
/// spent JWT that cannot be refreshed took the whole Discover tab down with
/// it: search and the next page of the feed both ended at "session expired
/// (401)", which names a fix ("log in again") that does not apply and offers
/// no way back. Dropping the refused token and asking again is what turns that
/// into an answer.
///
/// The list is an allowlist, not a filter on the account paths, and it covers
/// GET only. An account-bound call retried anonymously does not fail — it
/// succeeds and describes somebody else, or nobody: a block list read without
/// a session is an empty block list, which would then be written back over the
/// real one. So anything not known to be public is refused here, including the
/// capture flow's reads of chats, personas, scripts and API settings.
bool janitorReadIsPublic(String url, {String method = 'GET'}) {
  if (method.toUpperCase() != 'GET') return false;
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } on FormatException {
    return false;
  }
  final segments = uri.pathSegments;
  if (segments.length < 2 || segments.first != 'hampter') return false;
  final path = segments.skip(1).toList();
  return switch (path.first) {
    // The feed and a search (`/characters?...`), one card's metadata
    // (`/characters/{id}`), and the tag autocomplete.
    'characters' =>
      path.length <= 2 ||
          (path.length == 3 && path[1] == 'tags' && path[2] == 'suggest'),
    'tags' => path.length == 1,
    'reviews' => path.length == 2,
    _ => false,
  };
}


/// Provider-scoped cookie snapshot for switching JanitorAI accounts.
/// Only JanitorAI Supabase auth cookies are included; OAuth-provider cookies
/// and credentials are not captured.
class JanitorAccountSession {
  static const _origin = 'https://janitorai.com';

  static Future<String?> capture() async {
    try {
      final cookies = await CookieManager.instance().getCookies(url: WebUri(_origin));
      final auth = cookies.where((c) => isJanitorAuthCookie(c.name) && (c.value?.toString() ?? '').isNotEmpty)
          .map((c) => <String, dynamic>{
            'name': c.name, 'value': c.value, 'domain': c.domain,
            'path': c.path ?? '/', 'expiresDate': c.expiresDate,
            'isSecure': c.isSecure ?? true, 'isHttpOnly': c.isHttpOnly ?? false,
          }).toList();
      if (auth.isEmpty) return null;
      return jsonEncode({'version': 1, 'cookies': auth});
    } catch (_) { return null; }
  }

  static Future<bool> restore(String? raw) async {
    if (raw == null || raw.isEmpty) return false;
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return false;
      final rawCookies = data['cookies'];
      if (rawCookies is! List) return false;
      final cm = CookieManager.instance();
      final url = WebUri(_origin);
      final existing = await cm.getCookies(url: url);
      for (final c in existing.where((c) => isJanitorAuthCookie(c.name))) {
        try { await cm.deleteCookie(url: url, name: c.name, domain: c.domain, path: c.path ?? '/'); } catch (_) {}
      }
      var restored = 0;
      for (final item in rawCookies) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        final name = m['name'] as String?;
        final value = m['value'] as String?;
        if (name == null || value == null || !isJanitorAuthCookie(name)) continue;
        try {
          await cm.setCookie(url: url, name: name, value: value,
            domain: m['domain'] as String?, path: (m['path'] as String?) ?? '/',
            expiresDate: m['expiresDate'] as int?,
            isSecure: (m['isSecure'] as bool?) ?? true,
            isHttpOnly: (m['isHttpOnly'] as bool?) ?? false);
          restored++;
        } catch (_) {}
      }
      return restored > 0;
    } catch (_) { return false; }
  }
}
