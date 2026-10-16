import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crushon_account_provider.dart';
import '../services/crushon_session.dart';
import '../services/crushon_webview_proxy.dart';

/// Cookie name fragments that indicate a real CrushOn auth session (not just
/// Cloudflare clearance or anonymous browse cookies).
const _authCookieHints = <String>[
  'session',
  'token',
  'auth',
  'access',
  'refresh',
  'jwt',
  'uid',
  'user',
  'email',
  'sb-', // supabase-style
  'next-auth',
  '__session',
];

/// WebView login sheet for CrushOn.AI.
///
/// Opens https://crushon.ai, lets the user complete email / OAuth sign-in
/// (and any Cloudflare challenge), then harvests cookies into
/// [CrushOnWebSession] and marks [crushOnAccountProvider] connected.
class CrushOnLoginSheet extends ConsumerStatefulWidget {
  const CrushOnLoginSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const CrushOnLoginSheet(),
    );
  }

  @override
  ConsumerState<CrushOnLoginSheet> createState() => _CrushOnLoginSheetState();
}

class _CrushOnLoginSheetState extends ConsumerState<CrushOnLoginSheet> {
  InAppWebViewController? _controller;
  bool _saving = false;
  bool _sawAuthOrOAuth = false;
  String _status =
      'Sign in on CrushOn (email or Google). Cloudflare may challenge once.';

  bool _isGoogleOrOAuthHost(WebUri? url) {
    if (url == null) return false;
    final host = url.host.toLowerCase();
    return host.contains('google') ||
        host.contains('gstatic') ||
        host.contains('discord') ||
        host.contains('apple.com') ||
        host.contains('appleid');
  }

  bool _hasAuthCookies(List<Cookie> cookies) {
    for (final c in cookies) {
      final name = c.name.toLowerCase();
      final value = c.value.trim();
      if (value.isEmpty) continue;
      if (name == 'cf_clearance' || name.startsWith('__cf')) continue;
      for (final hint in _authCookieHints) {
        if (name.contains(hint)) return true;
      }
    }
    return false;
  }

  Future<List<Cookie>> _collectCookies() async {
    final cookieManager = CookieManager.instance();
    final byName = <String, Cookie>{};
    const origins = <String>[
      'https://crushon.ai',
      'https://www.crushon.ai',
      'https://chat.crushon.ai',
      'https://crushon.ai/',
      'https://crushon.ai/api',
    ];
    for (final origin in origins) {
      try {
        final list = await cookieManager.getCookies(url: WebUri(origin));
        for (final c in list) {
          byName[c.name] = c;
        }
      } catch (_) {}
    }
    final controller = _controller;
    if (controller != null) {
      try {
        final raw = await controller.evaluateJavascript(
          source: 'document.cookie || ""',
        );
        final text = '$raw'.replaceAll('"', '').trim();
        if (text.isNotEmpty) {
          for (final part in text.split(';')) {
            final eq = part.indexOf('=');
            if (eq <= 0) continue;
            final name = part.substring(0, eq).trim();
            final value = part.substring(eq + 1).trim();
            if (name.isEmpty) continue;
            byName.putIfAbsent(
              name,
              () => Cookie(name: name, value: value),
            );
          }
        }
      } catch (_) {}
    }
    return byName.values.toList();
  }

  Future<void> _updateStatusForUrl(WebUri? url) async {
    if (!mounted) return;

    if (_isGoogleOrOAuthHost(url) || isCrushOnAuthPath(url)) {
      _sawAuthOrOAuth = true;
      setState(() {
        _status =
            'Finish signing in. When you are back on CrushOn, tap Done to save.';
      });
      return;
    }

    if (!isCrushOnHost(url)) {
      setState(() {
        _status = 'Complete the sign-in steps, then return to CrushOn.';
      });
      return;
    }

    try {
      final cookies = await _collectCookies();
      final hasAuth = _hasAuthCookies(cookies);
      final hasCf = cookies.any((c) => c.name.toLowerCase() == 'cf_clearance');
      if (!mounted) return;
      if (hasAuth) {
        setState(() {
          _status = hasCf
              ? 'Looks signed in. Tap Done to save the session for catalog + favorites.'
              : 'Signed in, but Cloudflare clearance is missing — wait for the page to finish, then tap Done.';
        });
      } else if (hasCf && _sawAuthOrOAuth) {
        setState(() {
          _status =
              'Cloudflare cleared. Finish sign-in if needed, then tap Done.';
        });
      } else if (_sawAuthOrOAuth) {
        setState(() {
          _status =
              'If sign-in finished, tap Done. Otherwise use email or Google above.';
        });
      } else {
        setState(() {
          _status =
              'Sign in on CrushOn (email or Google). Cloudflare may challenge once.';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status =
            'Sign in on CrushOn (email or Google). Cloudflare may challenge once.';
      });
    }
  }

  /// Prefer a human-looking display name; never use bare numeric cookie values.
  String? _guessDisplayName(List<Cookie> cookies, String? title) {
    for (final c in cookies) {
      final n = c.name.toLowerCase();
      final v = c.value.trim();
      if (v.isEmpty || v.length > 80) continue;
      if (RegExp(r'^\d+$').hasMatch(v)) continue; // e.g. user_id=1
      if (n.contains('email') && v.contains('@')) return v;
      if ((n.contains('name') || n.contains('display')) &&
          !n.contains('token') &&
          !n.contains('id')) {
        return v;
      }
    }
    if (title != null &&
        title.isNotEmpty &&
        !title.toLowerCase().contains('crushon') &&
        !title.toLowerCase().contains('login') &&
        !title.toLowerCase().contains('sign in')) {
      return title;
    }
    return null;
  }

  Future<void> _harvestAndClose() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _status = 'Saving session…';
    });
    try {
      final controller = _controller;
      if (controller == null) return;

      final cookies = await _collectCookies();
      final parts = <String>[];
      for (final c in cookies) {
        if (c.value.trim().isEmpty) continue;
        parts.add('${c.name}=${c.value}');
      }
      final header = parts.join('; ');

      String? title;
      try {
        title = await controller.getTitle();
      } catch (_) {}

      final displayName = _guessDisplayName(cookies, title);

      await CrushOnWebSession.instance.setFromWebView(
        cookieHeader: header,
        userAgent: kCrushOnUserAgent,
      );
      // Drop any headless proxy so the next catalog call restarts with these
      // cookies + a fresh in-page CF session (Dio cannot replay the cookie).
      await CrushOnWebViewProxy.instance.invalidate();

      if (!CrushOnWebSession.instance.hasSession) {
        setState(() {
          _status =
              'No cookies captured yet. Wait for the page to finish loading, then try Done again.';
          _saving = false;
        });
        return;
      }

      await ref.read(crushOnAccountProvider.notifier).setConnected(
            true,
            displayName: displayName ?? 'CrushOn account',
            credential: header,
          );

      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      setState(() {
        _status = 'Could not save session: $e';
        _saving = false;
      });
    }
  }

  Future<void> _goBack() async {
    final c = _controller;
    if (c != null && await c.canGoBack()) {
      await c.goBack();
      return;
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.92;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: 'Back',
                  onPressed: _saving ? null : _goBack,
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                const Expanded(
                  child: Text(
                    'CrushOn sign-in',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: _saving ? null : _harvestAndClose,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Done'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _status,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri('https://crushon.ai'),
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                cacheEnabled: true,
                thirdPartyCookiesEnabled: true,
                sharedCookiesEnabled: true,
                useHybridComposition: true,
                userAgent: kCrushOnUserAgent,
                // Needed for shouldOverrideUrlLoading below to be called at all.
                useShouldOverrideUrlLoading: true,
                supportZoom: true,
                verticalScrollBarEnabled: true,
                horizontalScrollBarEnabled: false,
                allowsInlineMediaPlayback: true,
                mediaPlaybackRequiresUserGesture: false,
                preferredContentMode: UserPreferredContentMode.MOBILE,
                useWideViewPort: true,
                loadWithOverviewMode: true,
              ),
              onWebViewCreated: (c) => _controller = c,
              shouldOverrideUrlLoading: (controller, action) async {
                // crushon.ai's footer links to Reddit / Telegram / Instagram...
                // A stray tap must not bounce the user out to another app. Sign-in
                // providers (Google, Apple, Discord, X, Facebook) stay allowed.
                if (isCrushOnSocialPromoHost(action.request.url)) {
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
              },
              onLoadStart: (controller, url) {
                if (_isGoogleOrOAuthHost(url) || isCrushOnAuthPath(url)) {
                  _sawAuthOrOAuth = true;
                  if (mounted) {
                    setState(() {
                      _status =
                          'Finish signing in. When you are back on CrushOn, tap Done to save.';
                    });
                  }
                }
              },
              onLoadStop: (controller, url) async {
                await _updateStatusForUrl(url);
              },
            ),
          ),
        ],
      ),
    );
  }
}
