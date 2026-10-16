import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_sheet.dart';

/// Opens [url] in an in-app browser sheet so the user can view their account
/// on the provider's site. Existing cookies are kept. Optional [onLoadInjectJs]
/// runs after each page load (e.g. to seed a token into localStorage).
Future<void> showProviderAccountViewSheet(
  BuildContext context, {
  required String title,
  required String url,
  String? onLoadInjectJs,
}) {
  return showGlazeSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ProviderAccountViewSheet(
      title: title,
      url: url,
      onLoadInjectJs: onLoadInjectJs,
    ),
  );
}

class ProviderAccountViewSheet extends StatefulWidget {
  final String title;
  final String url;
  final String? onLoadInjectJs;

  const ProviderAccountViewSheet({
    super.key,
    required this.title,
    required this.url,
    this.onLoadInjectJs,
  });

  @override
  State<ProviderAccountViewSheet> createState() =>
      _ProviderAccountViewSheetState();
}

class _ProviderAccountViewSheetState extends State<ProviderAccountViewSheet> {
  InAppWebViewController? _controller;
  bool _didSeedReload = false;

  Future<void> _inject() async {
    final js = widget.onLoadInjectJs;
    final c = _controller;
    if (js == null || js.isEmpty || c == null) return;
    try {
      await c.evaluateJavascript(source: js);
      // SPA pages often render the logged-out shell before localStorage is
      // seeded. One reload after the first inject makes the site pick up the
      // session (needed for Chub key-based "View account").
      if (!_didSeedReload) {
        _didSeedReload = true;
        await c.reload();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final inWindow = GlazeSheetWindowScope.of(context);
    final height = inWindow
        ? double.infinity
        : MediaQuery.of(context).size.height * 0.92;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: context.cs.surface,
        borderRadius: inWindow
            ? BorderRadius.circular(16)
            : const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: 'Back',
                  onPressed: () async {
                    final c = _controller;
                    if (c != null && await c.canGoBack()) {
                      await c.goBack();
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Refresh',
                  onPressed: () => _controller?.reload(),
                ),
              ],
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.url)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                cacheEnabled: true,
                thirdPartyCookiesEnabled: true,
                sharedCookiesEnabled: true,
                isInspectable: false,
                useHybridComposition: true,
                supportZoom: true,
                verticalScrollBarEnabled: true,
              ),
              // Claim vertical drags so the page scrolls instead of the sheet.
              gestureRecognizers: {
                Factory<VerticalDragGestureRecognizer>(
                  () => VerticalDragGestureRecognizer(),
                ),
                Factory<HorizontalDragGestureRecognizer>(
                  () => HorizontalDragGestureRecognizer(),
                ),
              },
              onWebViewCreated: (controller) => _controller = controller,
              onLoadStop: (_, __) => _inject(),
            ),
          ),
        ],
      ),
    );
  }
}
