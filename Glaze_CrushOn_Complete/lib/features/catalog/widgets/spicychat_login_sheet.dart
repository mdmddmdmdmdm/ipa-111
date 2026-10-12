import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_sheet.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../saved_accounts_provider.dart';
import '../services/spicychat_provider.dart';
import '../services/spicychat_session.dart';
import '../spicychat_account_provider.dart';
import '../third_party_providers_provider.dart';

const _spicyHome = 'https://spicychat.ai/';
const _spicyLogin = 'https://spicychat.ai/login';

Future<void> openSpicyChatAccountSheet(BuildContext context, WidgetRef ref) async {
  if (!ref.read(spicyChatAccountProvider).isLoggedIn) {
    await showSpicyChatLoginSheet(context);
    return;
  }
  await GlazeBottomSheet.show<void>(
    context,
    title: 'SpicyChat account',
    items: [
      BottomSheetItem(
        label: 'View account',
        icon: Icons.open_in_browser_rounded,
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          showSpicyChatAccountViewSheet(context, ref);
        },
      ),
      BottomSheetItem(
        label: 'Sign out of SpicyChat',
        icon: Icons.logout_rounded,
        isDestructive: true,
        onTap: () async {
          Navigator.of(context, rootNavigator: true).pop();
          // Deletes the session everywhere (cookies + site storage), so the
          // next sign-in cannot pick it back up on its own. The account stays
          // in the Accounts list for a one-tap restore.
          await SpicyChatWebSession.instance.signOut();
          await ref.read(spicyChatAccountProvider.notifier).clearConnected();
        },
      ),
      BottomSheetItem(
        label: 'Cancel',
        icon: Icons.close_rounded,
        onTap: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
    ],
  );
}

/// Opens spicychat.ai in a sheet using the existing signed-in session so the
/// user can browse their profile, settings, and sign out on the site itself.
Future<void> showSpicyChatAccountViewSheet(
  BuildContext context,
  WidgetRef ref,
) {
  return showGlazeSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const SpicyChatAccountViewSheet(),
  );
}

/// Opens the sign-in sheet. Without [restore] it is a fresh sign-in that starts
/// from a wiped session. With a saved account it restores that account's saved
/// session, and if that session has expired signs in again by pressing the
/// sign-in buttons for it.
Future<void> showSpicyChatLoginSheet(
  BuildContext context, {
  SavedAccount? restore,
}) {
  return showGlazeSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => SpicyChatLoginSheet(restore: restore),
  );
}

enum _Phase {
  /// Web view created, session being cleared / restored.
  starting,

  /// First spicychat.ai load of a fresh sign-in: wipe the site's storage, then
  /// load the login page again.
  cleanLoad,

  /// First spicychat.ai load of a restore: put the saved storage back, reload.
  restoreLoad,

  /// Waiting to see whether the restored session is really signed in.
  verifying,

  /// The login page is up; waiting for the user (or the auto-press) to finish.
  login,
}

class SpicyChatLoginSheet extends ConsumerStatefulWidget {
  final SavedAccount? restore;

  const SpicyChatLoginSheet({super.key, this.restore});

  @override
  ConsumerState<SpicyChatLoginSheet> createState() => _SpicyChatLoginSheetState();
}

class _SpicyChatLoginSheetState extends ConsumerState<SpicyChatLoginSheet> {
  InAppWebViewController? _controller;
  Timer? _poll;
  Timer? _watchdog;
  DateTime _busySince = DateTime.now();
  _Phase _phase = _Phase.starting;
  bool _busy = true;
  String _status = 'Preparing a clean sign-in…';
  String? _hint;

  bool _closing = false;
  bool _probing = false;
  bool _sawAuthPage = false;
  bool _verifyStarted = false;
  bool _autoLogin = false;
  bool _autoPressed = false;
  int _hits = 0;

  String? _typedEmail;
  String? _savedEmail;
  late String _method;
  SpicyChatSessionSnapshot? _snapshot;

  bool get _isRestore => widget.restore != null;

  @override
  void initState() {
    super.initState();
    final cred = SavedCredential.tryParse(widget.restore?.credential);
    _savedEmail = cred?.email;
    final name = widget.restore?.displayName ?? '';
    if ((_savedEmail ?? '').isEmpty && name.contains('@')) _savedEmail = name;
    final method = cred?.method ?? '';
    _method = method.isEmpty ? 'email' : method;
    _snapshot = SpicyChatSessionSnapshot.tryParse(cred?.session);
    if (_isRestore) _status = 'Restoring your session…';
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _probe());
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) => _checkStuck());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _watchdog?.cancel();
    super.dispose();
  }

  /// The spinner covers the page until the login page reports it has loaded.
  /// If that report never comes (a redirect to another host, a network blip, a
  /// bot-check page), the sheet used to sit there until it was closed and
  /// opened again. After a while it now just shows whatever page there is.
  Future<void> _checkStuck() async {
    if (!_busy || _closing || !mounted) return;
    final limit = _isRestore ? 22 : 12;
    if (DateTime.now().difference(_busySince).inSeconds < limit) return;
    final c = _controller;
    if (c == null) return;
    _autoLogin = _isRestore;
    _phase = _Phase.login;
    _sawAuthPage = true;
    _setStatus(
      'Sign in to SpicyChat',
      busy: false,
      hint: 'Page was slow to load — use ↻ if the sign-in page is blank.',
    );
    try {
      final url = await c.getUrl();
      if (!isSpicyChatHost(url) || !isSpicyChatAuthPath(url)) {
        await c.loadUrl(urlRequest: URLRequest(url: WebUri(_spicyLogin)));
      }
    } catch (_) {}
  }

  /// For when the automatic detection misses a finished sign-in: if the page
  /// really holds a signed-in session, finish with it.
  Future<void> _manualDone() async {
    final c = _controller;
    if (c == null || _closing) return;
    _setStatus('Checking sign-in…', busy: true);

    // Give the page a moment to flush tokens after the last redirect.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted || _closing) return;

    final id = await SpicyChatSessionTools.readIdentity(c);
    var ok = id.hasToken || id.email != null;
    if (!ok) ok = await SpicyChatWebSession.instance.probeController(c);

    // Last resort: if we already left the auth path and the jar has SpicyChat
    // cookies, treat that as signed in (covers sites that keep tokens only in
    // httpOnly cookies).
    if (!ok) {
      try {
        final url = await c.getUrl();
        if (isSpicyChatHost(url) && !isSpicyChatAuthPath(url)) {
          final snap = await SpicyChatSessionTools.capture(c);
          if (snap != null && snap.cookies.isNotEmpty) ok = true;
        }
      } catch (_) {}
    }

    if (!mounted) return;
    if (ok) {
      await _finish(c, restoredOk: false);
    } else {
      _setStatus(
        'Sign in to SpicyChat',
        busy: false,
        hint: 'Not signed in yet — finish signing in, then press Done.',
      );
    }
  }

  void _setStatus(String text, {required bool busy, String? hint}) {
    if (!mounted) return;
    if (busy && !_busy) _busySince = DateTime.now();
    setState(() {
      _status = text;
      _busy = busy;
      _hint = hint;
    });
  }

  void _noteUrl(WebUri? url) {
    if (isSpicyChatHost(url) && isSpicyChatAuthPath(url)) _sawAuthPage = true;
  }

  /// Clears the old session before anything is shown, so nothing can sign in
  /// on its own. The app is marked signed out first: the web session is about
  /// to be replaced, and a half-finished swap must not leave it claiming to be
  /// signed in.
  Future<void> _prepare(InAppWebViewController c) async {
    final snapshot = _snapshot;
    // A fresh sign-in starts with Google wiped too, so the account picker is
    // shown. A saved account keeps whatever Google session the app has and,
    // when it saved its own Google cookies, gets exactly those back.
    final wipeGoogle = !_isRestore || (snapshot?.hasGoogle ?? false);
    try {
      await ref
          .read(spicyChatAccountProvider.notifier)
          .clearConnected(keepNsfw: true);
      await SpicyChatWebSession.instance.dispose();
      await SpicyChatSessionTools.wipeCookies(includeGoogle: wipeGoogle);
    } catch (_) {}
    if (!mounted) return;
    if (_isRestore && snapshot != null) {
      try {
        await SpicyChatSessionTools.restoreCookies(
          snapshot,
          includeGoogle: true,
        );
      } catch (_) {}
      _phase = _Phase.restoreLoad;
      await c.loadUrl(urlRequest: URLRequest(url: WebUri(_spicyHome)));
    } else {
      _autoLogin = _isRestore;
      _phase = _Phase.cleanLoad;
      await c.loadUrl(urlRequest: URLRequest(url: WebUri(_spicyLogin)));
    }
  }

  /// The saved session did not work (expired or revoked): sign in again, with
  /// the saved email filled in and the buttons pressed.
  Future<void> _fallbackToLogin() async {
    final c = _controller;
    if (c == null || _closing || _autoLogin || !mounted) return;
    _autoLogin = true;
    _setStatus('Session expired — opening sign-in…', busy: true);
    try {
      // SpicyChat only. Google's cookies stay, so "Continue with Google" opens
      // on the saved Google account and only needs a couple of taps.
      await SpicyChatSessionTools.wipeCookies();
    } catch (_) {}
    _sawAuthPage = false;
    _phase = _Phase.cleanLoad;
    await c.loadUrl(urlRequest: URLRequest(url: WebUri(_spicyLogin)));
  }

  Future<void> _verifyRestored(InAppWebViewController c) async {
    if (_verifyStarted) return;
    _verifyStarted = true;
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted || _closing) return;
      WebUri? url;
      try {
        url = await c.getUrl();
      } catch (_) {}
      if (isSpicyChatHost(url) && isSpicyChatAuthPath(url)) {
        await _fallbackToLogin();
        return;
      }
      // DOM only: the saved tokens were just written back, so a token in
      // storage proves nothing about whether the server still accepts it.
      if (isSpicyChatHost(url) &&
          await SpicyChatWebSession.instance.probeController(c)) {
        await _finish(c, restoredOk: true);
        return;
      }
    }
    await _fallbackToLogin();
  }

  Future<void> _probe() async {
    if (_closing || _probing || _phase != _Phase.login) return;
    final c = _controller;
    if (c == null) return;
    _probing = true;
    try {
      WebUri? url;
      try {
        url = await c.getUrl();
      } catch (_) {
        return;
      }
      if (!isSpicyChatHost(url)) {
        _hits = 0;
        return;
      }
      if (isSpicyChatAuthPath(url)) {
        _sawAuthPage = true;
        _hits = 0;
        return;
      }
      // Only count a sign-in that happened here: the sheet always starts on
      // the login page, so leaving it is what completes a sign-in.
      if (!_sawAuthPage) return;

      // Token / identity first — more reliable than DOM chrome.
      final id = await SpicyChatSessionTools.readIdentity(c);
      var signedIn = id.hasToken || id.email != null;
      if (!signedIn) {
        signedIn = await SpicyChatWebSession.instance.probeController(c);
      }
      if (!signedIn) {
        _hits = 0;
        return;
      }
      // Two checks in a row, so a page that is still redirecting is not
      // mistaken for a finished sign-in.
      if (++_hits < 2) return;
      await _finish(c, restoredOk: false);
    } finally {
      _probing = false;
    }
  }

  Future<void> _finish(
    InAppWebViewController c, {
    required bool restoredOk,
  }) async {
    if (_closing) return;
    _closing = true;
    _poll?.cancel();
    var identity = const SpicyChatIdentity();
    SpicyChatSessionSnapshot? snapshot;
    try {
      identity = await SpicyChatSessionTools.readIdentity(c);
    } catch (_) {}
    try {
      snapshot = await SpicyChatSessionTools.capture(c);
    } catch (_) {}

    final typed = (_typedEmail ?? '').trim();
    final String? email = restoredOk
        ? ((_savedEmail ?? '').isNotEmpty ? _savedEmail : identity.email)
        : (typed.isNotEmpty ? typed : identity.email);
    final String name;
    if (restoredOk && widget.restore != null) {
      name = widget.restore!.displayName;
    } else if ((email ?? '').isNotEmpty) {
      name = email!;
    } else {
      name = identity.name ?? widget.restore?.displayName ?? 'SpicyChat ($_method)';
    }

    final previousSession = restoredOk
        ? SavedCredential.tryParse(widget.restore?.credential)?.session
        : null;
    final sessionJson = (snapshot != null && !snapshot.isEmpty)
        ? snapshot.encode()
        : previousSession;
    final credential = SavedCredential(
      email: email,
      method: _method,
      session: sessionJson,
    ).encode();

    await ref
        .read(spicyChatAccountProvider.notifier)
        .setConnected(true, displayName: name, credential: credential);
    // Restart the headless catalog session so For You / Recent use the new
    // cookies instead of the wiped pre-login state.
    try {
      await SpicyChatWebSession.instance.dispose();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  void _scheduleAutoPress(InAppWebViewController c) {
    if (!_autoLogin || _autoPressed) return;
    for (final ms in const <int>[600, 1500, 3000, 5000]) {
      Future<void>.delayed(Duration(milliseconds: ms), () async {
        if (!mounted || _closing || _autoPressed) return;
        try {
          final raw = await c.evaluateJavascript(
            source: SpicyChatSessionTools.autoPressJs(_savedEmail, _method),
          );
          final result = '$raw'.replaceAll('"', '');
          if (result == 'email') {
            _autoPressed = true;
            _setStatus(
              'Signing in',
              busy: false,
              hint: 'Code requested — enter the code from your email.',
            );
          } else if (result == 'oauth') {
            _autoPressed = true;
            _setStatus(
              'Signing in',
              busy: false,
              hint: 'Choose your account and press Continue / Allow.',
            );
          } else if (ms == 5000) {
            // The automatic press never found its button. Point at it so the
            // user only has to tap it themselves.
            await c.evaluateJavascript(
              source: SpicyChatSessionTools.highlightJs(_method),
            );
            _setStatus(
              'Sign in to SpicyChat',
              busy: false,
              hint: _method == 'email'
                  ? 'Enter your email, then press Done once you are in.'
                  : 'Tap the highlighted button, choose your account and '
                        'press Continue.',
            );
          }
        } catch (_) {}
      });
    }
  }

  Future<void> _goBack() async {
    final c = _controller;
    if (c != null && await c.canGoBack()) await c.goBack();
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
                  onPressed: _goBack,
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Text(
                    _isRestore
                        ? 'Signing in to SpicyChat'
                        : 'Sign in to SpicyChat',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: _manualDone,
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
          if (_hint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _hint!,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                InAppWebView(
                  // No initial URL: the session is cleared or restored first
                  // (see _prepare) and only then is a page loaded, so nothing
                  // can load against a stale session and sign in on its own.
                  // Safari-like UA (no "wv") so SpicyChat renders the full
                  // mobile site headers/nav and OAuth is not blocked.
                  initialSettings: spicyChatWebViewSettings(
                    clearCache: false,
                    cacheEnabled: true,
                  ),
                  gestureRecognizers: {
                    Factory<VerticalDragGestureRecognizer>(
                      () => VerticalDragGestureRecognizer(),
                    ),
                    Factory<HorizontalDragGestureRecognizer>(
                      () => HorizontalDragGestureRecognizer(),
                    ),
                  },
                  onWebViewCreated: (controller) async {
                    _controller = controller;
                    controller.addJavaScriptHandler(
                      handlerName: 'glazeEmailSeen',
                      callback: (JavaScriptHandlerFunctionData data) {
                        if (data.args.isNotEmpty) {
                          final value = '${data.args.first}'.trim();
                          if (value.isNotEmpty) _typedEmail = value;
                        }
                        return null;
                      },
                    );
                    controller.addJavaScriptHandler(
                      handlerName: 'glazeMethodSeen',
                      callback: (JavaScriptHandlerFunctionData data) {
                        if (data.args.isNotEmpty) {
                          final value = '${data.args.first}'.trim();
                          if (value.isNotEmpty) _method = value;
                        }
                        return null;
                      },
                    );
                    await _prepare(controller);
                  },
                  onLoadStop: (controller, url) async {
                    if (!isSpicyChatHost(url)) return;
                    _noteUrl(url);
                    switch (_phase) {
                      case _Phase.starting:
                        return;
                      case _Phase.cleanLoad:
                        // First load after the cookies were deleted: clear the
                        // site's storage too, then load the login page again.
                        _phase = _Phase.starting;
                        await SpicyChatSessionTools.clearStorage(controller);
                        _sawAuthPage = false;
                        _phase = _Phase.login;
                        await controller.loadUrl(
                          urlRequest: URLRequest(url: WebUri(_spicyLogin)),
                        );
                        return;
                      case _Phase.restoreLoad:
                        _phase = _Phase.verifying;
                        final snapshot = _snapshot;
                        if (snapshot != null &&
                            (snapshot.local.isNotEmpty ||
                                snapshot.session.isNotEmpty)) {
                          await controller.evaluateJavascript(
                            source: SpicyChatSessionTools.restoreStorageJs(
                              snapshot,
                              overwrite: true,
                            ),
                          );
                          // The site read its storage before it was filled in.
                          await controller.reload();
                        } else {
                          unawaited(_verifyRestored(controller));
                        }
                        return;
                      case _Phase.verifying:
                        unawaited(_verifyRestored(controller));
                        return;
                      case _Phase.login:
                        _setStatus(
                          _autoLogin
                              ? 'Signing in'
                              : 'Sign in to SpicyChat',
                          busy: false,
                          hint: _hint,
                        );
                        try {
                          await controller.evaluateJavascript(
                            source: SpicyChatSessionTools.authHookJs,
                          );
                        } catch (_) {}
                        _scheduleAutoPress(controller);
                        unawaited(_probe());
                        return;
                    }
                  },
                  onUpdateVisitedHistory: (_, url, _) {
                    _noteUrl(url);
                    unawaited(_probe());
                  },
                ),
                if (_busy)
                  Positioned.fill(
                    child: ColoredBox(
                      color: context.cs.surface,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const GlazeSpinner(),
                            const SizedBox(height: 16),
                            Text(
                              _status,
                              style: TextStyle(
                                fontSize: 14,
                                color: context.cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// In-app browser for the signed-in SpicyChat session. Unlike the login sheet,
/// this does **not** clear cookies — it reuses the active session so the user
/// can manage their account on the site (profile, settings, sign-out, etc.).
///
/// It never closes itself or signs the app out on its own: the old version
/// judged the session from a half-loaded page two seconds in, which is why
/// "View account" kept dumping people at the sign-in screen.
class SpicyChatAccountViewSheet extends ConsumerStatefulWidget {
  const SpicyChatAccountViewSheet({super.key});

  @override
  ConsumerState<SpicyChatAccountViewSheet> createState() =>
      _SpicyChatAccountViewSheetState();
}

class _SpicyChatAccountViewSheetState
    extends ConsumerState<SpicyChatAccountViewSheet> {
  InAppWebViewController? _controller;
  Timer? _poll;
  final _openedAt = DateTime.now();
  SpicyChatSessionSnapshot? _snapshot;
  SavedAccount? _saved;
  bool _storageSeeded = false;
  bool _checking = false;
  bool _closing = false;
  bool _signedOutHint = false;
  int _misses = 0;

  @override
  void initState() {
    super.initState();
    final account = ref.read(spicyChatAccountProvider);
    final id = SavedAccountsNotifier.idFor(
      ThirdPartyProvider.spicychat,
      account.displayName ?? '',
    );
    _saved = ref
        .read(savedAccountsProvider)
        .where((a) => a.id == id)
        .firstOrNull;
    _snapshot = SpicyChatSessionSnapshot.tryParse(
      SavedCredential.tryParse(_saved?.credential)?.session,
    );
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _checkSession());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Only shows a hint, and only after the page has had time to load and has
  /// looked signed out three times in a row. It changes no state.
  Future<void> _checkSession() async {
    final c = _controller;
    if (c == null || !mounted || _checking || _signedOutHint) return;
    if (DateTime.now().difference(_openedAt) < const Duration(seconds: 10)) {
      return;
    }
    _checking = true;
    try {
      final url = await c.getUrl();
      if (!isSpicyChatHost(url)) return;
      if (await SpicyChatWebSession.instance.probeController(c)) {
        _misses = 0;
        return;
      }
      if (++_misses >= 3 && mounted) setState(() => _signedOutHint = true);
    } catch (_) {
    } finally {
      _checking = false;
    }
  }

  Future<void> _signInAgain() async {
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    final saved = _saved;
    Navigator.of(context).pop();
    await showSpicyChatLoginSheet(rootContext, restore: saved);
  }

  /// Saves the session as it is now before closing, so tokens the site
  /// refreshed while the sheet was open are what a later restore uses.
  Future<void> _close() async {
    final c = _controller;
    final saved = _saved;
    if (c != null && saved != null && !_closing) {
      _closing = true;
      final accounts = ref.read(savedAccountsProvider.notifier);
      try {
        await (() async {
          final id = await SpicyChatSessionTools.readIdentity(c);
          if (!id.hasToken) return;
          final snap = await SpicyChatSessionTools.capture(c);
          if (snap == null || snap.isEmpty) return;
          final old = SavedCredential.tryParse(saved.credential);
          await accounts.remember(
            provider: ThirdPartyProvider.spicychat,
            displayName: saved.displayName,
            credential: SavedCredential(
              email: old?.email,
              method: old?.method,
              session: snap.encode(),
            ).encode(),
          );
        })().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    if (mounted) Navigator.of(context).pop();
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
                  onPressed: _close,
                ),
                const Expanded(
                  child: Text(
                    'SpicyChat account',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
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
          if (_signedOutHint)
            Container(
              width: double.infinity,
              color: context.cs.surfaceContainerHighest,
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'SpicyChat looks signed out here.',
                      style: TextStyle(
                        fontSize: 13,
                        color: context.cs.onSurface,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _signInAgain,
                    child: const Text('Sign in again'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: 'Dismiss',
                    onPressed: () => setState(() {
                      _signedOutHint = false;
                      _misses = 0;
                    }),
                  ),
                ],
              ),
            ),
          Expanded(
            child: InAppWebView(
              // Loaded from onWebViewCreated, after the saved session has been
              // put back if the cookie jar was emptied in the meantime.
              // Same Safari UA + mobile viewport as the login sheet so the
              // signed-in site matches the real SpicyChat mobile UI.
              initialSettings: spicyChatWebViewSettings(),
              gestureRecognizers: {
                Factory<VerticalDragGestureRecognizer>(
                  () => VerticalDragGestureRecognizer(),
                ),
                Factory<HorizontalDragGestureRecognizer>(
                  () => HorizontalDragGestureRecognizer(),
                ),
              },
              onWebViewCreated: (controller) async {
                _controller = controller;
                final snapshot = _snapshot;
                if (snapshot != null) {
                  try {
                    await SpicyChatSessionTools.restoreCookies(
                      snapshot,
                      onlyIfMissing: true,
                    );
                  } catch (_) {}
                }
                await controller.loadUrl(
                  urlRequest: URLRequest(url: WebUri(_spicyHome)),
                );
              },
              onLoadStop: (controller, url) async {
                final snapshot = _snapshot;
                if (_storageSeeded || snapshot == null) return;
                if (!isSpicyChatHost(url)) return;
                _storageSeeded = true;
                try {
                  // Fills in only the keys the site is missing, and reloads
                  // only if something was actually missing.
                  final raw = await controller.evaluateJavascript(
                    source: SpicyChatSessionTools.restoreStorageJs(
                      snapshot,
                      overwrite: false,
                    ),
                  );
                  final added =
                      int.tryParse(
                        '$raw'.replaceAll('"', '').replaceFirst('added:', ''),
                      ) ??
                      0;
                  if (added > 0) await controller.reload();
                } catch (_) {}
              },
            ),
          ),
        ],
      ),
    );
  }
}
