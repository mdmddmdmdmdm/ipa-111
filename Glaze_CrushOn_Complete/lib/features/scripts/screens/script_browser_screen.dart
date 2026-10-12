import 'dart:async';
import 'dart:collection';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_sheet.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../services/userscript_runtime.dart';
import '../user_scripts_provider.dart';

/// Opens the script browser: a web view with an address bar where the enabled
/// userscripts run on the pages they match. Whatever interface a script adds to
/// the page (panels, buttons, overlays) shows up inside it, and the commands a
/// script registers are reachable from the toolbar.
///
/// With [onlyScriptId] just that script runs (for trying one out).
Future<void> showScriptBrowser(
  BuildContext context, {
  String? url,
  String? onlyScriptId,
}) {
  return showGlazeSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ScriptBrowserScreen(startUrl: url, onlyScriptId: onlyScriptId),
  );
}

class ScriptBrowserScreen extends ConsumerStatefulWidget {
  final String? startUrl;
  final String? onlyScriptId;

  const ScriptBrowserScreen({super.key, this.startUrl, this.onlyScriptId});

  @override
  ConsumerState<ScriptBrowserScreen> createState() =>
      _ScriptBrowserScreenState();
}

class _ScriptBrowserScreenState extends ConsumerState<ScriptBrowserScreen> {
  static const _defaultUrl = 'https://www.google.com/';

  InAppWebViewController? _controller;
  UnmodifiableListView<UserScript>? _scripts;
  final _urlCtrl = TextEditingController();
  final _urlFocus = FocusNode();
  final List<ScriptMenuCommand> _commands = [];
  late final ProviderContainer _container;
  int _progress = 0;
  int _errorToasts = 0;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _urlCtrl.text = widget.startUrl ?? _defaultUrl;
    unawaited(_prepareScripts());
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _urlFocus.dispose();
    // The "Running" badges describe the page in this browser only.
    final container = _container;
    Future<void>.microtask(() {
      try {
        container.read(runningScriptIdsProvider.notifier).state = <String>{};
      } catch (_) {}
    });
    super.dispose();
  }

  Future<void> _prepareScripts() async {
    await _container.read(userScriptsProvider.notifier).ensureLoaded();
    final list = _container.read(userScriptsProvider);
    final built = await UserScriptRuntime.build(
      list,
      onlyId: widget.onlyScriptId,
    );
    if (!mounted) return;
    setState(() => _scripts = built);
  }

  String _normalise(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return _defaultUrl;
    if (t.startsWith('http://') || t.startsWith('https://')) return t;
    if (!t.contains(' ') && t.contains('.')) return 'https://$t';
    return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(t)}';
  }

  Future<void> _go([String? raw]) async {
    final c = _controller;
    if (c == null) return;
    final target = _normalise(raw ?? _urlCtrl.text);
    _urlFocus.unfocus();
    await c.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
  }

  void _markRan(String id) {
    if (!mounted) return;
    final current = _container.read(runningScriptIdsProvider);
    _container.read(runningScriptIdsProvider.notifier).state = {...current, id};
  }

  void _onScriptError(String id, String message) {
    if (!mounted || _errorToasts >= 3) return;
    _errorToasts++;
    final name = _container.read(userScriptsProvider.notifier).byId(id)?.name;
    final first = message.split('\n').first;
    GlazeToast.show(
      context,
      '${name ?? 'Script'}: ${first.length > 120 ? first.substring(0, 120) : first}',
      isError: true,
    );
  }

  void _showCommands() {
    final c = _controller;
    if (c == null || _commands.isEmpty) return;
    GlazeBottomSheet.show<void>(
      context,
      title: 'scripts_commands'.tr(),
      items: [
        for (final cmd in _commands)
          BottomSheetItem(
            label: cmd.title,
            icon: Icons.play_arrow_rounded,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              UserScriptRuntime.runCommand(c, cmd);
            },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final inWindow = GlazeSheetWindowScope.of(context);
    final height = inWindow
        ? double.infinity
        : MediaQuery.of(context).size.height * 0.92;
    final running = ref.watch(runningScriptIdsProvider).length;
    final scripts = _scripts;

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
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: 'Back',
                  onPressed: () async {
                    final c = _controller;
                    if (c != null && await c.canGoBack()) await c.goBack();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    focusNode: _urlFocus,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: TextStyle(fontSize: 14, color: context.cs.onSurface),
                    onSubmitted: _go,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: context.cs.surfaceContainerHighest,
                      hintText: 'scripts_address_hint'.tr(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Reload',
                  onPressed: () => _controller?.reload(),
                ),
                IconButton(
                  icon: Badge(
                    isLabelVisible: _commands.isNotEmpty,
                    label: Text('${_commands.length}'),
                    child: const Icon(Icons.bolt_rounded),
                  ),
                  tooltip: 'scripts_commands'.tr(),
                  onPressed: _commands.isEmpty ? null : _showCommands,
                ),
              ],
            ),
          ),
          if (_progress > 0 && _progress < 100)
            LinearProgressIndicator(value: _progress / 100, minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                scripts == null
                    ? 'scripts_loading'.tr()
                    : 'scripts_running_count'.tr(
                        namedArgs: {
                          'running': '$running',
                          'total': '${scripts.length}',
                        },
                      ),
                style: TextStyle(
                  fontSize: 12,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Expanded(
            child: scripts == null
                ? const Center(child: GlazeSpinner())
                : InAppWebView(
                    initialUrlRequest: URLRequest(
                      url: WebUri(_normalise(_urlCtrl.text)),
                    ),
                    initialUserScripts: scripts,
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      domStorageEnabled: true,
                      databaseEnabled: true,
                      cacheEnabled: true,
                      thirdPartyCookiesEnabled: true,
                      sharedCookiesEnabled: true,
                      isInspectable: true,
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
                    onWebViewCreated: (controller) {
                      _controller = controller;
                      UserScriptRuntime.registerHandlers(
                        controller,
                        ScriptHostCallbacks(
                          onRan: _markRan,
                          onError: _onScriptError,
                          onMenuAdded: (cmd) {
                            if (!mounted) return;
                            setState(() => _commands.add(cmd));
                          },
                          onMenuRemoved: (scriptId, commandId) {
                            if (!mounted) return;
                            setState(
                              () => _commands.removeWhere(
                                (c) =>
                                    c.scriptId == scriptId &&
                                    c.commandId == commandId,
                              ),
                            );
                          },
                          onOpenUrl: (url) => _go(url),
                          onToast: (message) {
                            if (mounted) GlazeToast.show(context, message);
                          },
                        ),
                      );
                    },
                    onLoadStart: (controller, url) {
                      if (!mounted) return;
                      _container.read(runningScriptIdsProvider.notifier).state =
                          <String>{};
                      _errorToasts = 0;
                      setState(_commands.clear);
                    },
                    onProgressChanged: (controller, progress) {
                      if (mounted) setState(() => _progress = progress);
                    },
                    onUpdateVisitedHistory: (controller, url, isReload) {
                      if (url != null && !_urlFocus.hasFocus) {
                        _urlCtrl.text = url.toString();
                      }
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
