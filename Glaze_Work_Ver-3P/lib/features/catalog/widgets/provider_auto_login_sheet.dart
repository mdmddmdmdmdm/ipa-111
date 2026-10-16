import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_sheet.dart';
import '../saved_accounts_provider.dart';
import '../third_party_providers_provider.dart';

/// Opens a provider login page. When [email] and [password] are set, fills and
/// submits the form automatically. Always listens for form submits so newly
/// typed credentials can be remembered via [onCredentialsCaptured].
Future<void> showProviderAutoLoginSheet(
  BuildContext context, {
  required String title,
  required String loginUrl,
  required ThirdPartyProvider provider,
  String? email,
  String? password,
  void Function(String email, String password)? onCredentialsCaptured,
  FutureOr<void> Function()? onLoggedIn,
  bool Function(WebUri? url)? isStillOnAuthPage,
}) {
  return showGlazeSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ProviderAutoLoginSheet(
      title: title,
      loginUrl: loginUrl,
      provider: provider,
      email: email,
      password: password,
      onCredentialsCaptured: onCredentialsCaptured,
      onLoggedIn: onLoggedIn,
      isStillOnAuthPage: isStillOnAuthPage,
    ),
  );
}

class ProviderAutoLoginSheet extends ConsumerStatefulWidget {
  final String title;
  final String loginUrl;
  final ThirdPartyProvider provider;
  final String? email;
  final String? password;
  final void Function(String email, String password)? onCredentialsCaptured;
  final FutureOr<void> Function()? onLoggedIn;
  final bool Function(WebUri? url)? isStillOnAuthPage;

  const ProviderAutoLoginSheet({
    super.key,
    required this.title,
    required this.loginUrl,
    required this.provider,
    this.email,
    this.password,
    this.onCredentialsCaptured,
    this.onLoggedIn,
    this.isStillOnAuthPage,
  });

  @override
  ConsumerState<ProviderAutoLoginSheet> createState() =>
      _ProviderAutoLoginSheetState();
}

class _ProviderAutoLoginSheetState extends ConsumerState<ProviderAutoLoginSheet> {
  InAppWebViewController? _controller;
  Timer? _poll;
  bool _closing = false;
  bool _sawAuthPage = false;
  bool _filled = false;
  final _readyAt = DateTime.now().add(const Duration(seconds: 2));

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _checkDone());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  bool _onAuthRoute(WebUri? url) {
    if (widget.isStillOnAuthPage != null) {
      return widget.isStillOnAuthPage!(url);
    }
    final path = (url?.path ?? '').toLowerCase();
    return path.contains('/login') ||
        path.contains('/signup') ||
        path.contains('/register') ||
        path.contains('/signin') ||
        path.contains('/auth') ||
        path.contains('/onboarding') ||
        path.contains('/verify');
  }

  Future<void> _checkDone() async {
    if (_closing || DateTime.now().isBefore(_readyAt)) return;
    final c = _controller;
    if (c == null) return;
    WebUri? url;
    try {
      url = await c.getUrl();
    } catch (_) {
      return;
    }
    if (_onAuthRoute(url)) {
      _sawAuthPage = true;
      return;
    }
    // Only treat as success after we actually saw an auth page (avoids
    // auto-closing when a leftover session loads the homepage immediately).
    if (!_sawAuthPage) return;
    _closing = true;
    try {
      await widget.onLoggedIn?.call();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _tryFill() async {
    final email = widget.email?.trim() ?? '';
    final password = widget.password ?? '';
    if (email.isEmpty || password.isEmpty) return;
    final c = _controller;
    if (c == null) return;
    final safeEmail = jsonEncode(email);
    final safePass = jsonEncode(password);
    // Multi-step: chooser → email → Next → password → submit. Re-run safe.
    final js = '''
(function(){
  try {
    var email = $safeEmail;
    var pass = $safePass;
    if (!window.__glazeFillStep) window.__glazeFillStep = 0;

    var setVal = function(el, val){
      if (!el) return;
      el.focus();
      try {
        var native = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
        if (native && native.set) native.set.call(el, val);
      } catch (e) {}
      el.value = val;
      el.dispatchEvent(new Event('input', {bubbles:true}));
      el.dispatchEvent(new Event('change', {bubbles:true}));
    };

    var clickMatching = function(needles){
      var nodes = Array.from(document.querySelectorAll('button, a, [role=button], input[type=submit]'));
      for (var i=0;i<nodes.length;i++){
        var n = nodes[i];
        var t = ((n.innerText||n.textContent||n.value||'')+'').toLowerCase().trim();
        for (var j=0;j<needles.length;j++){
          if (t.indexOf(needles[j]) >= 0) { n.click(); return true; }
        }
      }
      return false;
    };

    var findEmail = function(){
      return Array.from(document.querySelectorAll('input')).find(function(i){
        var t=(i.type||'').toLowerCase();
        var n=(i.name||'').toLowerCase();
        var id=(i.id||'').toLowerCase();
        var p=(i.placeholder||'').toLowerCase();
        var a=(i.autocomplete||'').toLowerCase();
        if (t==='password' || t==='hidden') return false;
        return t==='email' || a.indexOf('email')>=0 || a.indexOf('username')>=0
          || n.indexOf('email')>=0 || n.indexOf('user')>=0
          || id.indexOf('email')>=0 || id.indexOf('user')>=0
          || p.indexOf('email')>=0 || p.indexOf('user')>=0;
      });
    };

    var findPass = function(){
      return Array.from(document.querySelectorAll('input')).find(function(i){
        return (i.type||'').toLowerCase()==='password';
      });
    };

    if (window.__glazeFillStep === 0) {
      clickMatching(['continue with email','sign in with email','log in with email','email','password']);
      window.__glazeFillStep = 1;
    }

    var e = findEmail();
    var p = findPass();

    if (e && !p) {
      setVal(e, email);
      window.__glazeFillStep = 2;
      if (!clickMatching(['next','continue','weiter'])) {
        if (e.form) {
          if (e.form.requestSubmit) e.form.requestSubmit();
          else e.form.submit();
        }
      }
      return 'email-next';
    }

    if (p && !e) {
      setVal(p, pass);
      window.__glazeFillStep = 3;
      if (!clickMatching(['log in','sign in','login','submit','continue','next'])) {
        if (p.form) {
          if (p.form.requestSubmit) p.form.requestSubmit();
          else p.form.submit();
        }
      }
      return 'password-submit';
    }

    if (e && p) {
      setVal(e, email);
      setVal(p, pass);
      window.__glazeFillStep = 3;
      if (!clickMatching(['log in','sign in','login','submit','continue'])) {
        var btn = document.querySelector('button[type=submit], input[type=submit]');
        if (btn) btn.click();
        else if (e.form) {
          if (e.form.requestSubmit) e.form.requestSubmit();
          else e.form.submit();
        }
      }
      return 'combined';
    }

    return 'waiting';
  } catch (err) { return 'err'; }
})()
''';
    try {
      await c.evaluateJavascript(source: js);
      // Multi-step pages need a few retries after Next navigations.
      for (final ms in <int>[700, 1600, 2800, 4200]) {
        Future.delayed(Duration(milliseconds: ms), () async {
          if (!mounted || _closing) return;
          try {
            await c.evaluateJavascript(source: js);
          } catch (_) {}
        });
      }
    } catch (_) {}
  }

  static const _captureJs = r'''
(function(){
  if (window.__glazeCredHook) return;
  window.__glazeCredHook = true;
  var grab = function(root){
    try {
      var inputs = Array.from((root||document).querySelectorAll('input'));
      var e = inputs.find(function(i){
        var t=(i.type||'').toLowerCase();
        var n=(i.name||'').toLowerCase();
        var id=(i.id||'').toLowerCase();
        return t==='email' || (t==='text' && (n.indexOf('email')>=0||n.indexOf('user')>=0||id.indexOf('email')>=0||id.indexOf('user')>=0));
      });
      var p = inputs.find(function(i){ return (i.type||'').toLowerCase()==='password'; });
      if (e && p && e.value && p.value && window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('glazeSaveCreds', e.value, p.value);
      }
    } catch (err) {}
  };
  document.addEventListener('submit', function(ev){ grab(ev.target); }, true);
  document.addEventListener('click', function(ev){
    var t = ev.target;
    if (!t) return;
    var label = ((t.innerText||t.textContent||'')+'').toLowerCase();
    if (label.indexOf('log in')>=0 || label.indexOf('sign in')>=0 || label.indexOf('login')>=0) {
      setTimeout(function(){ grab(document); }, 50);
    }
  }, true);
})();
''';

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
                  icon: const Icon(Icons.close_rounded),
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
              ],
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.loginUrl)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                thirdPartyCookiesEnabled: true,
                // Keep the persistent WebView cookie jar. Clearing it here
                // made saved-account sign-in erase Google/Apple SSO sessions
                // for unrelated providers, so the next tap often failed or
                // asked the user to start over.
                sharedCookiesEnabled: true,
                cacheEnabled: true,
                clearCache: false,
                isInspectable: false,
                useHybridComposition: true,
                supportZoom: true,
                verticalScrollBarEnabled: true,
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
                // Do not clear cookies here. Cookies are already scoped by
                // their domain, while OAuth providers (Google/Apple/etc.) need
                // their persistent SSO session to survive between taps. The
                // previous global deletion loop erased sessions for several
                // unrelated content providers and broke saved-account login.
                controller.addJavaScriptHandler(
                  handlerName: 'glazeSaveCreds',
                  callback: (JavaScriptHandlerFunctionData data) {
                    final args = data.args;
                    if (args.length < 2) return null;
                    final email = '${args[0]}'.trim();
                    final password = '${args[1]}';
                    if (email.isEmpty || password.isEmpty) return null;
                    widget.onCredentialsCaptured?.call(email, password);
                    ref.read(savedAccountsProvider.notifier).remember(
                          provider: widget.provider,
                          displayName: email,
                          credential: SavedCredential(
                            email: email,
                            password: password,
                          ).encode(),
                        );
                    return null;
                  },
                );
              },
              onLoadStop: (controller, url) async {
                if (_onAuthRoute(url)) _sawAuthPage = true;
                try {
                  await controller.evaluateJavascript(source: _captureJs);
                } catch (_) {}
                await _tryFill();
                await _checkDone();
              },
              onUpdateVisitedHistory: (_, url, __) {
                if (_onAuthRoute(url)) _sawAuthPage = true;
                _checkDone();
              },
            ),
          ),
        ],
      ),
    );
  }
}
