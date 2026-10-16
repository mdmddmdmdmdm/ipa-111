import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../models/user_script.dart';
import '../services/userscript_importer.dart';
import '../services/userscript_parser.dart';
import '../user_scripts_provider.dart';
import 'script_browser_screen.dart';

/// Opens Script Management as a sheet. Used by the More menu and the chat
/// Tools drawer.
Future<void> openScriptManagementSheet(BuildContext context) {
  return showGlazeSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const ScriptManagementScreen(),
  );
}

enum _View { list, details, editor, greasy }

const _newScriptTemplate = '''// ==UserScript==
// @name         My script
// @namespace    glaze
// @version      0.1
// @description  What this script does
// @match        https://example.com/*
// @grant        none
// ==/UserScript==

(function () {
  'use strict';
  // Your code here. Anything you add to the page (buttons, panels) shows up
  // in the script browser.
})();
''';

/// Script Management: the list of userscripts, one script's details, the code
/// editor and the Greasy Fork importer, all inside one sheet.
class ScriptManagementScreen extends ConsumerStatefulWidget {
  const ScriptManagementScreen({super.key});

  @override
  ConsumerState<ScriptManagementScreen> createState() =>
      _ScriptManagementScreenState();
}

class _ScriptManagementScreenState
    extends ConsumerState<ScriptManagementScreen> {
  _View _view = _View.list;
  String? _selectedId;
  bool _busy = false;

  final _codeCtrl = TextEditingController();
  bool _editingNew = false;

  final _greasyCtrl = TextEditingController();
  List<GreasyForkResult> _results = const [];
  String? _greasyError;

  @override
  void initState() {
    super.initState();
    unawaited(_autoUpdate());
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _greasyCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ helpers

  GlazeUserScript? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    return ref.read(userScriptsProvider.notifier).byId(id);
  }

  void _toast(String text, {bool error = false}) {
    if (!mounted) return;
    GlazeToast.show(context, text, isError: error);
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await task();
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Scripts with Auto Update on are checked once when the sheet opens.
  Future<void> _autoUpdate() async {
    final notifier = ref.read(userScriptsProvider.notifier);
    await notifier.ensureLoaded();
    for (final s in ref.read(userScriptsProvider)) {
      if (!s.autoUpdate || (s.sourceUrl.isEmpty && s.updateUrl.isEmpty)) {
        continue;
      }
      try {
        final code = await UserScriptImporter.instance.newerCode(s);
        if (code == null) continue;
        final req = await UserScriptImporter.instance.fetchRequires(
          UserScriptHeader.parse(code).all('require'),
        );
        await notifier.replaceCode(s.id, code, requireCode: req);
      } catch (_) {}
    }
  }

  Future<String?> _askText({
    required String title,
    required String hint,
    String initial = '',
    int maxLines = 1,
    String confirm = 'OK',
  }) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: maxLines,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: maxLines > 1
              ? TextInputType.multiline
              : TextInputType.url,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('btn_cancel'.tr()),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: Text(confirm),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ adding

  void _showAddMenu() {
    GlazeBottomSheet.show<void>(
      context,
      title: 'scripts_add_title'.tr(),
      items: [
        BottomSheetItem(
          label: 'scripts_add_directly'.tr(),
          icon: Icons.edit_note_rounded,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _openEditor(null);
          },
        ),
        BottomSheetItem(
          label: 'scripts_import_url'.tr(),
          icon: Icons.link_rounded,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _importFromUrl();
          },
        ),
        BottomSheetItem(
          label: 'scripts_import_file'.tr(),
          icon: Icons.folder_open_rounded,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _importFromFile();
          },
        ),
        BottomSheetItem(
          label: 'scripts_import_greasyfork'.tr(),
          icon: Icons.travel_explore_rounded,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(() => _view = _View.greasy);
          },
        ),
        BottomSheetItem(
          label: 'scripts_update_all'.tr(),
          icon: Icons.system_update_alt_rounded,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _updateAll();
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

  Future<GlazeUserScript> _install(String code, {String sourceUrl = ''}) async {
    final header = UserScriptHeader.parse(code);
    final requireCode = await UserScriptImporter.instance.fetchRequires(
      header.all('require'),
    );
    return ref
        .read(userScriptsProvider.notifier)
        .addFromCode(code, sourceUrl: sourceUrl, requireCode: requireCode);
  }

  Future<void> _importFromUrl() async {
    final url = await _askText(
      title: 'scripts_import_url'.tr(),
      hint: 'https://…/script.user.js',
      confirm: 'scripts_import'.tr(),
    );
    if (url == null || url.trim().isEmpty) return;
    await _run(() async {
      var target = url.trim();
      final greasy = await UserScriptImporter.instance.greasyForkCodeUrl(target);
      if (greasy != null) target = greasy;
      final got = await UserScriptImporter.instance.downloadScript(target);
      final script = await _install(got.code, sourceUrl: got.url);
      _toast('scripts_added'.tr(namedArgs: {'name': script.name}));
    });
  }

  Future<void> _importFromFile() async {
    final picked = await FilePicker.pickFiles(
      type: Platform.isIOS ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isIOS ? null : ['js', 'txt'],
      allowMultiple: false,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    await _run(() async {
      String code;
      if (file.bytes != null) {
        code = utf8.decode(file.bytes!, allowMalformed: true);
      } else if (file.path != null) {
        code = await File(file.path!).readAsString();
      } else {
        throw Exception('The file could not be read.');
      }
      if (code.trim().isEmpty) throw Exception('The file is empty.');
      final script = await _install(code);
      _toast('scripts_added'.tr(namedArgs: {'name': script.name}));
    });
  }

  Future<void> _updateAll() async {
    await _run(() async {
      final notifier = ref.read(userScriptsProvider.notifier);
      final all = ref.read(userScriptsProvider);
      var updated = 0;
      var checked = 0;
      for (final s in all) {
        if (s.sourceUrl.isEmpty && s.updateUrl.isEmpty) continue;
        checked++;
        try {
          final code = await UserScriptImporter.instance.newerCode(s);
          if (code == null) continue;
          final req = await UserScriptImporter.instance.fetchRequires(
            UserScriptHeader.parse(code).all('require'),
          );
          await notifier.replaceCode(s.id, code, requireCode: req);
          updated++;
        } catch (_) {}
      }
      _toast(
        checked == 0
            ? 'scripts_nothing_to_update'.tr()
            : 'scripts_updated_count'.tr(
                namedArgs: {'updated': '$updated', 'checked': '$checked'},
              ),
      );
    });
  }

  // ----------------------------------------------------------------- editing

  void _openEditor(GlazeUserScript? script) {
    _editingNew = script == null;
    _selectedId = script?.id;
    _codeCtrl.text = script?.code ?? _newScriptTemplate;
    setState(() => _view = _View.editor);
  }

  Future<void> _saveEditor() async {
    final code = _codeCtrl.text;
    if (code.trim().isEmpty) {
      _toast('scripts_code_empty'.tr(), error: true);
      return;
    }
    await _run(() async {
      final notifier = ref.read(userScriptsProvider.notifier);
      final header = UserScriptHeader.parse(code);
      final requireCode = await UserScriptImporter.instance.fetchRequires(
        header.all('require'),
      );
      if (_editingNew || _selectedId == null) {
        final s = await notifier.addFromCode(code, requireCode: requireCode);
        _selectedId = s.id;
      } else {
        await notifier.replaceCode(
          _selectedId!,
          code,
          requireCode: requireCode,
        );
      }
      if (!mounted) return;
      setState(() => _view = _View.details);
      _toast('scripts_saved'.tr());
    });
  }

  void _back() {
    switch (_view) {
      case _View.editor:
        setState(
          () => _view = (_editingNew || _selectedId == null)
              ? _View.list
              : _View.details,
        );
      case _View.details:
      case _View.greasy:
        setState(() => _view = _View.list);
      case _View.list:
        break;
    }
  }

  Future<void> _editPatterns(
    GlazeUserScript script, {
    required bool whitelist,
  }) async {
    final current = whitelist ? script.whitelist : script.blacklist;
    final text = await _askText(
      title: whitelist ? 'scripts_whitelist'.tr() : 'scripts_blacklist'.tr(),
      hint: 'https://example.com/*',
      initial: current.join('\n'),
      maxLines: 6,
      confirm: 'btn_save'.tr(),
    );
    if (text == null) return;
    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final notifier = ref.read(userScriptsProvider.notifier);
    await notifier.save(
      whitelist
          ? script.copyWith(whitelist: lines)
          : script.copyWith(blacklist: lines),
    );
  }

  void _pickScope(GlazeUserScript script) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'scripts_scope'.tr(),
      items: [
        for (final entry in const {
          'default': 'scripts_scope_default',
          'main': 'scripts_scope_main',
          'all': 'scripts_scope_all',
        }.entries)
          BottomSheetItem(
            label: entry.value.tr(),
            icon: script.scope == entry.key
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              ref
                  .read(userScriptsProvider.notifier)
                  .save(script.copyWith(scope: entry.key));
            },
          ),
      ],
    );
  }

  void _showList(String title, List<String> lines) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: SelectableText(
            lines.isEmpty ? '—' : lines.join('\n'),
            style: const TextStyle(fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(GlazeUserScript script) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('scripts_delete_title'.tr()),
        content: Text(script.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('btn_cancel'.tr()),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('btn_delete'.tr()),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(userScriptsProvider.notifier).remove(script.id);
    if (!mounted) return;
    setState(() {
      _selectedId = null;
      _view = _View.list;
    });
  }

  Future<void> _updateOne(GlazeUserScript script) async {
    await _run(() async {
      final code = await UserScriptImporter.instance.newerCode(script);
      if (code == null) {
        _toast('scripts_up_to_date'.tr());
        return;
      }
      final req = await UserScriptImporter.instance.fetchRequires(
        UserScriptHeader.parse(code).all('require'),
      );
      await ref
          .read(userScriptsProvider.notifier)
          .replaceCode(script.id, code, requireCode: req);
      _toast('scripts_updated'.tr());
    });
  }

  void _openInBrowser(GlazeUserScript script) {
    showScriptBrowser(
      context,
      url: userScriptStartUrl(script),
      onlyScriptId: script.id,
    );
  }

  // ----------------------------------------------------------------- greasy

  Future<void> _searchGreasy() async {
    final q = _greasyCtrl.text.trim();
    if (q.isEmpty) return;
    await _run(() async {
      setState(() => _greasyError = null);
      final direct = await UserScriptImporter.instance.greasyForkCodeUrl(q);
      if (direct != null) {
        final got = await UserScriptImporter.instance.downloadScript(direct);
        final script = await _install(got.code, sourceUrl: got.url);
        _toast('scripts_added'.tr(namedArgs: {'name': script.name}));
        if (mounted) setState(() => _view = _View.list);
        return;
      }
      final found = await UserScriptImporter.instance.searchGreasyFork(q);
      if (!mounted) return;
      setState(() {
        _results = found;
        _greasyError = found.isEmpty ? 'scripts_no_results'.tr() : null;
      });
    });
  }

  Future<void> _installResult(GreasyForkResult r) async {
    await _run(() async {
      final got = await UserScriptImporter.instance.downloadScript(r.codeUrl);
      final script = await _install(got.code, sourceUrl: got.url);
      _toast('scripts_added'.tr(namedArgs: {'name': script.name}));
    });
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final scripts = ref.watch(userScriptsProvider);
    final running = ref.watch(runningScriptIdsProvider);
    final selected = _selectedId == null
        ? null
        : scripts.where((s) => s.id == _selectedId).firstOrNull;
    // A script deleted elsewhere leaves nothing to show on its pages.
    final view = (_view == _View.details && selected == null)
        ? _View.list
        : _view;

    final String title;
    final List<SheetViewAction> actions;
    final Widget body;
    switch (view) {
      case _View.list:
        title = 'scripts_title'.tr();
        actions = [
          SheetViewAction(
            icon: const Icon(Icons.public_rounded),
            tooltip: 'scripts_open_browser'.tr(),
            onPressed: () => showScriptBrowser(context),
          ),
          SheetViewAction(
            icon: const Icon(Icons.add_rounded),
            tooltip: 'scripts_add_title'.tr(),
            onPressed: _showAddMenu,
          ),
        ];
        body = _buildList(scripts, running);
      case _View.details:
        title = 'scripts_details'.tr();
        actions = [
          SheetViewAction(
            icon: const Icon(Icons.public_rounded),
            tooltip: 'scripts_run_in_browser'.tr(),
            onPressed: () => _openInBrowser(selected!),
          ),
        ];
        body = _buildDetails(selected!, running.contains(selected.id));
      case _View.editor:
        title = _editingNew
            ? 'scripts_add_directly'.tr()
            : 'scripts_edit_code'.tr();
        actions = [
          SheetViewAction(
            icon: const Icon(Icons.check_rounded),
            tooltip: 'btn_save'.tr(),
            onPressed: _saveEditor,
          ),
        ];
        body = _buildEditor();
      case _View.greasy:
        title = 'scripts_import_greasyfork'.tr();
        actions = const [];
        body = _buildGreasy();
    }

    return SheetView(
      titleWidget: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: context.cs.onSurface,
        ),
      ),
      showBack: view != _View.list,
      onBack: view == _View.list ? null : _back,
      innerBack: view == _View.list ? null : _back,
      canPop: view == _View.list,
      actions: actions,
      body: body,
    );
  }

  Widget _buildList(List<GlazeUserScript> scripts, Set<String> running) {
    return Builder(
      builder: (context) => ListView(
        padding: EdgeInsets.fromLTRB(
          12,
          MediaQuery.paddingOf(context).top + 12,
          12,
          MediaQuery.paddingOf(context).bottom + 24,
        ),
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (scripts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
              child: Text(
                'scripts_empty'.tr(),
                textAlign: TextAlign.center,
                style: TextStyle(color: context.cs.onSurfaceVariant),
              ),
            ),
          for (final s in scripts)
            _ScriptTile(
              script: s,
              running: running.contains(s.id),
              onTap: () => setState(() {
                _selectedId = s.id;
                _view = _View.details;
              }),
              onToggle: (v) =>
                  ref.read(userScriptsProvider.notifier).setEnabled(s.id, v),
            ),
        ],
      ),
    );
  }

  Widget _buildDetails(GlazeUserScript s, bool running) {
    final scopeLabel = switch (s.scope) {
      'main' => 'scripts_scope_main'.tr(),
      'all' => 'scripts_scope_all'.tr(),
      _ => 'scripts_scope_default'.tr(),
    };
    final notifier = ref.read(userScriptsProvider.notifier);
    return Builder(
      builder: (context) => ListView(
        padding: EdgeInsets.fromLTRB(
          0,
          MediaQuery.paddingOf(context).top + 12,
          0,
          MediaQuery.paddingOf(context).bottom + 24,
        ),
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: context.cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.code_rounded,
                    color: context.cs.primary,
                    size: 30,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.name,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: context.cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        s.author.isEmpty ? 'scripts_author_you'.tr() : s.author,
                        style: TextStyle(
                          fontSize: 13,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '${'scripts_version'.tr()}: ${s.version.isEmpty ? '—' : s.version}',
                        style: TextStyle(
                          fontSize: 13,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          _Badge(
                            text: s.enabled
                                ? 'scripts_active'.tr()
                                : 'scripts_disabled'.tr(),
                            color: s.enabled
                                ? context.cs.primary
                                : context.cs.outline,
                          ),
                          if (running)
                            _Badge(
                              text: 'scripts_running'.tr(),
                              color: Colors.green,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _openEditor(s),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text('scripts_edit_code'.tr()),
                ),
              ],
            ),
          ),
          if (s.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                s.description,
                style: TextStyle(
                  fontSize: 14,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ),
          MenuGroup(
            compact: true,
            items: [
              MenuSwitchItem(
                label: 'scripts_enabled'.tr(),
                value: s.enabled,
                onChanged: (v) => notifier.setEnabled(s.id, v),
              ),
              MenuSwitchItem(
                label: 'scripts_auto_update'.tr(),
                description: 'scripts_auto_update_desc'.tr(),
                value: s.autoUpdate,
                onChanged: (v) => notifier.save(s.copyWith(autoUpdate: v)),
              ),
              MenuSelectorItem(
                label: 'scripts_scope'.tr(),
                currentValue: scopeLabel,
                onTap: () => _pickScope(s),
              ),
              MenuItem(
                label: 'scripts_whitelist'.tr(),
                value: '${s.whitelist.length}',
                onTap: () => _editPatterns(s, whitelist: true),
              ),
              MenuItem(
                label: 'scripts_blacklist'.tr(),
                value: '${s.blacklist.length}',
                onTap: () => _editPatterns(s, whitelist: false),
              ),
              MenuItem(
                label: 'scripts_matches'.tr(),
                value: '${s.matches.length}',
                onTap: () => _showList('scripts_matches'.tr(), s.matches),
              ),
              MenuItem(
                label: 'scripts_grants'.tr(),
                value: '${s.grants.length}',
                onTap: () => _showList('scripts_grants'.tr(), s.grants),
              ),
            ],
          ),
          MenuGroup(
            compact: true,
            items: [
              MenuItem(
                icon: Icons.public_rounded,
                label: 'scripts_run_in_browser'.tr(),
                subtitle: 'scripts_run_in_browser_hint'.tr(),
                onTap: () => _openInBrowser(s),
              ),
              MenuItem(
                icon: Icons.system_update_alt_rounded,
                label: 'scripts_check_update'.tr(),
                onTap: () => _updateOne(s),
              ),
              MenuItem(
                icon: Icons.delete_outline_rounded,
                label: 'btn_delete'.tr(),
                onTap: () => _delete(s),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEditor() {
    return Builder(
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          12,
          MediaQuery.paddingOf(context).top + 12,
          12,
          MediaQuery.paddingOf(context).bottom + 12,
        ),
        child: Column(
          children: [
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: TextField(
                controller: _codeCtrl,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                autocorrect: false,
                enableSuggestions: false,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  height: 1.35,
                  color: context.cs.onSurface,
                ),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: context.cs.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGreasy() {
    return Builder(
      builder: (context) => ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + 12,
          16,
          MediaQuery.paddingOf(context).bottom + 24,
        ),
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          TextField(
            controller: _greasyCtrl,
            textInputAction: TextInputAction.search,
            autocorrect: false,
            onSubmitted: (_) => _searchGreasy(),
            decoration: InputDecoration(
              hintText: 'scripts_greasy_hint'.tr(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.search_rounded),
                onPressed: _busy ? null : _searchGreasy,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_greasyError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _greasyError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.cs.onSurfaceVariant),
              ),
            ),
          for (final r in _results)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(r.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                r.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: TextButton(
                onPressed: _busy ? null : () => _installResult(r),
                child: Text('scripts_install'.tr()),
              ),
            ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;

  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _ScriptTile extends StatelessWidget {
  final GlazeUserScript script;
  final bool running;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;

  const _ScriptTile({
    required this.script,
    required this.running,
    required this.onTap,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: context.cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              children: [
                Icon(Icons.code_rounded, color: context.cs.primary, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (running) ...[
                            _Badge(
                              text: 'scripts_running'.tr(),
                              color: Colors.green,
                            ),
                            const SizedBox(width: 6),
                          ],
                          Expanded(
                            child: Text(
                              script.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: context.cs.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (script.description.isNotEmpty)
                        Text(
                          script.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: context.cs.onSurfaceVariant,
                          ),
                        ),
                      Text(
                        '${'scripts_version'.tr()}: ${script.version.isEmpty ? '—' : script.version}',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(value: script.enabled, onChanged: onToggle),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
