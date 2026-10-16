import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/api_config.dart';
import '../../settings/api_list_provider.dart';
import '../chat_provider.dart' show chatProvider;
import '../services/reply_suggestions.dart';

/// Opens the message-ideas sheet. [onUse] receives the text the user picked
/// (possibly edited) and the sheet closes.
Future<void> showReplySuggestionsSheet(
  BuildContext context, {
  required String charId,
  required void Function(String text) onUse,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _ReplySuggestionsSheet(charId: charId, onUse: onUse),
  );
}

class _ReplySuggestionsSheet extends ConsumerStatefulWidget {
  const _ReplySuggestionsSheet({required this.charId, required this.onUse});

  final String charId;
  final void Function(String text) onUse;

  @override
  ConsumerState<_ReplySuggestionsSheet> createState() =>
      _ReplySuggestionsSheetState();
}

class _ReplySuggestionsSheetState
    extends ConsumerState<_ReplySuggestionsSheet> {
  List<String> _ideas = const [];
  bool _loading = false;
  Object? _error;
  int _run = 0;

  /// Index of the idea being edited, with its own text field.
  int? _editing;
  final _editController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _generate());
  }

  @override
  void dispose() {
    _run++;
    _editController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final session = ref.read(chatProvider(widget.charId)).value?.session;
    if (session == null) return;
    final run = ++_run;
    setState(() {
      _loading = true;
      _error = null;
      _editing = null;
    });
    try {
      final ideas = await ref
          .read(replySuggestionServiceProvider)
          .suggest(charId: widget.charId, session: session);
      if (!mounted || run != _run) return;
      setState(() {
        _ideas = ideas;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || run != _run) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _use(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    Navigator.of(context).pop();
    widget.onUse(t);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(replySuggestionSettingsProvider);
    final configs = ref.watch(apiListProvider).value ?? const <ApiConfig>[];
    final selected = configs.any((c) => c.id == settings.apiConfigId)
        ? settings.apiConfigId
        : '';
    final bottom = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Message ideas',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'New ideas',
                  onPressed: _loading ? null : _generate,
                  icon: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: selected,
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Model: same as the chat'),
                      ),
                      for (final c in configs)
                        DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            'Model: ${c.model.isEmpty ? c.name : c.model}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (id) {
                      if (id == null) return;
                      ref
                          .read(replySuggestionSettingsProvider.notifier)
                          .setApiConfigId(id);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                const Text('Auto'),
                Switch.adaptive(
                  value: settings.auto,
                  onChanged: (v) => ref
                      .read(replySuggestionSettingsProvider.notifier)
                      .setAuto(v),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '$_error'.replaceFirst('Exception: ', ''),
                  style: TextStyle(color: cs.error),
                ),
              ),
            if (_loading && _ideas.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: Text('Thinking of ideas...')),
              ),
            for (var i = 0; i < _ideas.length; i++) _card(i, cs),
            if (_ideas.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Tap an idea to put it in the message box. Use the pencil '
                  'to change it first.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _card(int i, ColorScheme cs) {
    final editing = _editing == i;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: editing ? null : () => _use(_ideas[i]),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: editing
                      ? TextField(
                          controller: _editController,
                          autofocus: true,
                          minLines: 1,
                          maxLines: 6,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(_ideas[i], style: const TextStyle(height: 1.35)),
                        ),
                ),
                IconButton(
                  tooltip: editing ? 'Use this message' : 'Edit',
                  icon: Icon(
                    editing ? Icons.check_rounded : Icons.edit_outlined,
                  ),
                  onPressed: () {
                    if (editing) {
                      final text = _editController.text;
                      setState(() {
                        _ideas = [
                          for (var j = 0; j < _ideas.length; j++)
                            j == i ? text : _ideas[j],
                        ];
                        _editing = null;
                      });
                      _use(text);
                    } else {
                      _editController.text = _ideas[i];
                      setState(() => _editing = i);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
