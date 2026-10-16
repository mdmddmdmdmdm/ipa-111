import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/list_controls.dart';
import '../../chat/bridge/chat_webview_environment.dart';
import '../chub_account_provider.dart';
import '../services/chub_provider.dart';
import '../services/chub_session.dart';
import '../../../shared/widgets/glaze_sheet.dart';

Future<String?> _validateChubToken(String token) async {
  try {
    final response = await Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
        headers: const {'Accept': 'application/json'},
      ),
    ).get(
      'https://gateway.chub.ai/api/account',
      options: Options(headers: {'CH-API-KEY': token}),
    );
    final raw = response.data;
    final data = raw is Map<String, dynamic>
        ? raw
        : (raw is Map ? Map<String, dynamic>.from(raw) : null);
    if (data == null) return null;
    final nested = data['data'];
    final account = nested is Map
        ? Map<String, dynamic>.from(nested)
        : data;
    final name = account['user_name'] ?? account['username'] ?? account['name'];
    final value = name?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  } catch (_) {
    return null;
  }
}

/// Menu entry point for the "Chub Account" item. When a key is already stored
/// it offers a log-out sheet; otherwise it opens the login sheet.
Future<void> openChubAccountSheet(BuildContext context, WidgetRef ref) async {
  if (!ref.read(chubAccountProvider).isLoggedIn) {
    await showChubLoginSheet(context);
    return;
  }
  await GlazeBottomSheet.show<void>(
    context,
    title: 'chub_login_menu'.tr(),
    items: [
      BottomSheetItem(
        label: 'chub_auth_logout'.tr(),
        icon: Icons.logout_rounded,
        isDestructive: true,
        onTap: () async {
          Navigator.of(context, rootNavigator: true).pop();
          await ref.read(chubAccountProvider.notifier).logout();
          resetChubTagCache();
        },
      ),
      BottomSheetItem(
        label: 'btn_cancel'.tr(),
        icon: Icons.close_rounded,
        onTap: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
    ],
  );
}

/// Opens the Chub login sheet. The user can sign in through the site's own
/// WebView (which captures the key automatically) or paste a key by hand.
Future<void> showChubLoginSheet(BuildContext context) {
  return showGlazeSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const ChubLoginSheet(),
  );
}

/// Full-height sheet hosting a visible WebView on chub.ai.
///
/// Chub's API is directly reachable from Dart, so unlike JanitorAI this WebView
/// only *obtains* the key: once the site stores `URQL_TOKEN` in localStorage the
/// sheet reads it (on navigation and on a short poll, since chub.ai is a SPA)
/// and hands it to [chubAccountProvider]. From then on catalog requests carry it
/// straight from Dio. A "paste key" action switches to manual entry.
class ChubLoginSheet extends ConsumerStatefulWidget {
  const ChubLoginSheet({super.key});

  static const _loginUrl = 'https://chub.ai/login';

  @override
  ConsumerState<ChubLoginSheet> createState() => _ChubLoginSheetState();
}

class _ChubLoginSheetState extends ConsumerState<ChubLoginSheet> {
  InAppWebViewController? _controller;
  Timer? _poll;
  bool _manual = false;

  /// Guard against re-entrant capture: once a key lands we close exactly once.
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    // chub.ai is a SPA: a successful login can store the token without a full
    // navigation, so poll alongside the navigation callbacks.
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _capture());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _capture() async {
    if (_closing || _manual) return;
    final controller = _controller;
    if (controller == null) return;

    // Chub can persist URQL_TOKEN before a new account finishes onboarding.
    // A token alone is therefore not enough to close this sheet. Keep the
    // browser open while the user is on login/signup/onboarding/auth routes.
    try {
      final current = await controller.getUrl();
      final path = (current?.path ?? '').toLowerCase();
      if (path.contains('/login') ||
          path.contains('/signup') ||
          path.contains('/register') ||
          path.contains('/onboarding') ||
          path.contains('/verify') ||
          path.contains('/auth')) {
        return;
      }
    } catch (_) {}

    final Object? raw;
    try {
      raw = await controller.evaluateJavascript(source: chubSessionProbeJs);
    } catch (_) {
      return;
    }
    final session = parseChubSessionProbe(raw);
    if (session == null || _closing || !mounted) return;

    // A token can appear before OAuth/signup is fully finished. Validate it
    // against Chub's account endpoint before closing this panel.
    final userName = await _validateChubToken(session.token);
    if (userName == null || userName.isEmpty) return;

    _closing = true;
    await ref
        .read(chubAccountProvider.notifier)
        .setApiKey(session.token, userName: userName);
    resetChubTagCache();
    if (!mounted) return;
    Navigator.of(context).pop();
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
          _Header(
            manual: _manual,
            onClose: () => Navigator.of(context).pop(),
            onManual: () => setState(() => _manual = true),
            onBack: () async {
              if (_manual) {
                setState(() => _manual = false);
                return;
              }
              final c = _controller;
              if (c != null && await c.canGoBack()) {
                await c.goBack();
              }
            },
          ),
          Expanded(
            child: _manual
                ? const SingleChildScrollView(
                    padding: EdgeInsets.only(top: 4),
                    child: _ChubKeyForm(),
                  )
                : InAppWebView(
                    initialUrlRequest: URLRequest(
                      url: WebUri(ChubLoginSheet._loginUrl),
                    ),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      domStorageEnabled: true,
                      databaseEnabled: true,
                      cacheEnabled: true,
                      thirdPartyCookiesEnabled: true,
                      sharedCookiesEnabled: true,
                      isInspectable: false,
                      useHybridComposition: true,
                      // Safari-like UA without the "wv" marker Google blocks.
                      userAgent:
                          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) '
                          'AppleWebKit/605.1.15 (KHTML, like Gecko) '
                          'Version/17.4 Mobile/15E148 Safari/604.1',
                      supportZoom: true,
                      verticalScrollBarEnabled: true,
                    ),
                    webViewEnvironment:
                        defaultTargetPlatform == TargetPlatform.windows
                        ? chatWebViewEnvironment
                        : null,
                    gestureRecognizers: {
                      Factory<VerticalDragGestureRecognizer>(
                        () => VerticalDragGestureRecognizer(),
                      ),
                      Factory<HorizontalDragGestureRecognizer>(
                        () => HorizontalDragGestureRecognizer(),
                      ),
                    },
                    onWebViewCreated: (c) => _controller = c,
                    onLoadStop: (_, _) => _capture(),
                    onUpdateVisitedHistory: (_, _, _) => _capture(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final bool manual;
  final VoidCallback onClose;
  final VoidCallback onManual;
  final VoidCallback onBack;

  const _Header({
    required this.manual,
    required this.onClose,
    required this.onManual,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: onBack,
            color: context.cs.onSurface,
            tooltip: 'Back',
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: onClose,
            color: context.cs.onSurface,
            tooltip: 'Close',
          ),
          Expanded(
            child: Text(
              'chub_auth_title'.tr(),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurface,
              ),
            ),
          ),
          if (!manual)
            GlazeActionChip(
              icon: Icons.keyboard_rounded,
              label: 'chub_login_manual'.tr(),
              tooltip: 'chub_login_manual'.tr(),
              onTap: onManual,
            ),
        ],
      ),
    );
  }
}

/// Manual Ch-Api-Key entry. Paste the key chub.ai sends in its own requests
/// (DevTools → Network → any `ro.chub.ai` request → `Ch-Api-Key` header).
class _ChubKeyForm extends ConsumerStatefulWidget {
  const _ChubKeyForm();

  @override
  ConsumerState<_ChubKeyForm> createState() => _ChubKeyFormState();
}

class _ChubKeyFormState extends ConsumerState<_ChubKeyForm> {
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _key.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'chub_key_error_empty'.tr());
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await ref.read(chubAccountProvider.notifier).setApiKey(key);
    // A different key means a different tag universe and result set.
    resetChubTagCache();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    GlazeToast.show(context, 'chub_key_saved'.tr());
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'chub_login_info_desc'.tr(),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          _field(cs, _key, 'chub_key_hint'.tr(), enabled: !_busy),
          const SizedBox(height: 16),
          GlazeActionButton(
            icon: Icons.save_rounded,
            label: 'chub_key_save'.tr(),
            tone: GlazeActionTone.primary,
            expand: true,
            busy: _busy,
            onTap: _save,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _field(
    ColorScheme cs,
    TextEditingController controller,
    String hint, {
    bool enabled = true,
  }) {
    return TextField(
      controller: controller,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      style: TextStyle(fontSize: 14, color: cs.onSurface),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
        filled: true,
        fillColor: cs.surfaceContainerHighest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
