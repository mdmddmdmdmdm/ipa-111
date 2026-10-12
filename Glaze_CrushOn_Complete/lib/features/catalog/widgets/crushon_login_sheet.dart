import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crushon_account_provider.dart';
import '../services/crushon_session.dart';

/// WebView login sheet for CrushOn.AI.
///
/// Opens https://crushon.ai, lets the user complete email / OAuth sign-in
/// (and any Cloudflare challenge), then harvests cookies into
/// [CrushOnWebSession] and marks [crushOnAccountProvider] connected.
///
/// Same shape as the SpicyChat login sheet so it drops into the existing
/// providers screen without new UI patterns.
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
  String _status = 'Sign in on CrushOn. Cloudflare may challenge once.';

  Future<void> _harvestAndClose() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _status = 'Saving session…';
    });
    try {
      final controller = _controller;
      if (controller == null) return;

      final cookieManager = CookieManager.instance();
      final cookies = await cookieManager.getCookies(
        url: WebUri('https://crushon.ai'),
      );
      final parts = <String>[];
      String? displayName;
      for (final c in cookies) {
        parts.add('${c.name}=${c.value}');
        final n = c.name.toLowerCase();
        if (n.contains('email') || n.contains('user')) {
          displayName ??= c.value;
        }
      }
      final header = parts.join('; ');
      await CrushOnWebSession.instance.setFromWebView(cookieHeader: header);

      // Best-effort profile name from the page title / JS.
      try {
        final title = await controller.getTitle();
        if (title != null &&
            title.isNotEmpty &&
            !title.toLowerCase().contains('crushon') &&
            !title.toLowerCase().contains('login')) {
          displayName ??= title;
        }
      } catch (_) {}

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
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'CrushOn sign-in',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
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
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).maybePop(),
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
                thirdPartyCookiesEnabled: true,
                userAgent:
                    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36',
                supportZoom: true,
                preferredContentMode: UserPreferredContentMode.MOBILE,
              ),
              onWebViewCreated: (c) => _controller = c,
              shouldOverrideUrlLoading: (controller, action) async {
                final url = action.request.url;
                if (isCrushOnHost(url)) return NavigationActionPolicy.ALLOW;
                // Keep the user on CrushOn hosts for auth.
                if (url != null &&
                    (url.host.contains('google') ||
                        url.host.contains('discord') ||
                        url.host.contains('apple'))) {
                  return NavigationActionPolicy.ALLOW;
                }
                return NavigationActionPolicy.ALLOW;
              },
              onLoadStop: (controller, url) async {
                if (!mounted) return;
                if (isCrushOnHost(url) && !isCrushOnAuthPath(url)) {
                  setState(() {
                    _status =
                        'Looks signed in. Tap Done to save the session for catalog + favorites.';
                  });
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
