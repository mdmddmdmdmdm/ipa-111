import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Native, provider-independent text formatter. It works on text copied into
/// this tool and never sends content to an external service.
class MessageFormatterSheet extends StatefulWidget {
  const MessageFormatterSheet({super.key});
  @override
  State<MessageFormatterSheet> createState() => _MessageFormatterSheetState();
}

class _MessageFormatterSheetState extends State<MessageFormatterSheet> {
  static const _prefsKey = 'message_formatter_settings_v1';
  final _input = TextEditingController();
  final _output = TextEditingController();
  bool _enabled = true;
  bool _removeThink = true;
  bool _removeTags = true;
  bool _removeSystem = true;
  bool _removeDashes = false;
  bool _removeEllipses = false;
  bool _trimGlued = false;
  String _style = 'italic';
  bool _settingsOpen = false;

  @override
  void initState() { super.initState(); _load(); }
  @override
  void dispose() { _input.dispose(); _output.dispose(); super.dispose(); }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw == null) return;
    final parts = raw.split('|');
    if (!mounted || parts.length < 8) return;
    setState(() {
      _enabled = parts[0] == '1'; _removeThink = parts[1] == '1';
      _removeTags = parts[2] == '1'; _removeSystem = parts[3] == '1';
      _removeDashes = parts[4] == '1'; _removeEllipses = parts[5] == '1';
      _trimGlued = parts[6].startsWith('1');
      if (parts.length > 7) _style = parts[7];
    });
  }
  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, [
      _enabled, _removeThink, _removeTags, _removeSystem, _removeDashes,
      _removeEllipses, _trimGlued, _style,
    ].map((v) => v is bool ? (v ? '1' : '0') : v.toString()).join('|'));
  }

  String _format(String source) {
    if (!_enabled) return source;
    var text = source;
    final whole = RegExp(r'^\s*<(think|thought|thoughts|system-instruction|instruction|response-style|execution-protocol|protocol)>([\s\S]*?)</\1>\s*$', caseSensitive: false).firstMatch(text);
    if (whole != null) {
      text = whole.group(2) ?? text;
    } else if (_removeThink) {
      text = text.replaceAll(RegExp(r'\n?\s*<(?:thought|thoughts|think)>[\s\S]*?</(?:thought|thoughts|think)>\s*\n?', caseSensitive: false), '');
      text = text.replaceAll(RegExp(r'</?system>|</?response>', caseSensitive: false), '');
    }
    if (_removeDashes) text = text.replaceAll('—', ' ').replaceAll(RegExp(r' {2,}'), ' ');
    if (_removeEllipses) text = text.replaceAll(RegExp(r'\.{3,}|…'), '.').replaceAll(RegExp(r'\.{2,}'), '.');
    if (_removeTags) text = text.replaceAll(RegExp(r'</?[a-zA-Z0-9:-]+(\s[^>]*)?>'), '');
    if (_removeSystem && text.toLowerCase().contains('theuser')) {
      final i = text.indexOf(RegExp(r'[^\s*]\*[^\s*]'));
      if (i >= 0) text = text.substring(i + 1);
    }
    if (_trimGlued) {
      final m = RegExp(r'[a-zа-яё]\.([0-9A-ZА-ЯЁ])').firstMatch(text);
      if (m != null) text = text.substring(m.start + 2);
    }
    final narr = switch (_style) { 'italic' => '*', 'bold' => '**', 'bold-italic' => '*', _ => '' };
    final dial = switch (_style) { 'bold-italic' || 'bold-plain' => '**', _ => '' };
    text = text.replaceAll(RegExp(r'[«“”„‟⹂❞❝]'), '"');
    return text.split('\n').map((line) {
      final l = line.trim();
      if (l.isEmpty || l == '---' || _style == 'none') return l;
      final clean = l.replaceAll('*', '');
      if (clean.isEmpty) return '';
      if (clean.contains('"') || clean.contains('`')) {
        return clean.split(RegExp(r'("[\s\S]*?"|`[\s\S]*?`)')).where((x) => x.trim().isNotEmpty).map((frag) {
          final q = (frag.startsWith('"') && frag.endsWith('"')) || (frag.startsWith('`') && frag.endsWith('`'));
          return q ? '$dial$frag$dial' : '$narr${frag.trim()}$narr';
        }).join(' ');
      }
      return '$narr$clean$narr';
    }).join('\n');
  }

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
    contentPadding: EdgeInsets.zero, dense: true, title: Text(label), value: value,
    onChanged: (v) { onChanged(v); _save(); },
  );

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(18, 16, 18, MediaQuery.of(context).viewInsets.bottom + 18),
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [const Expanded(child: Text('Message Formatter', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))), IconButton(onPressed: () => setState(() => _settingsOpen = !_settingsOpen), icon: const Icon(Icons.settings)),]),
        const Text('Format and clean roleplay text locally. Works independently of the API provider.'),
        const SizedBox(height: 12),
        if (_settingsOpen) ...[
          _toggle('Formatter enabled', _enabled, (v) => setState(() => _enabled = v)),
          DropdownButtonFormField<String>(value: _style, decoration: const InputDecoration(labelText: 'Narration style'), items: const [DropdownMenuItem(value:'italic',child:Text('Italic narration')) ,DropdownMenuItem(value:'bold',child:Text('Bold narration')),DropdownMenuItem(value:'bold-italic',child:Text('Italic narration, bold dialogue')),DropdownMenuItem(value:'bold-plain',child:Text('Plain narration, bold dialogue')),DropdownMenuItem(value:'none',child:Text('Plain text'))], onChanged: (v) { if (v != null) setState(() => _style = v); _save(); }),
          _toggle('Remove <think> blocks', _removeThink, (v) => setState(() => _removeThink = v)),
          _toggle('Remove other tags', _removeTags, (v) => setState(() => _removeTags = v)),
          _toggle('Remove system prompt text', _removeSystem, (v) => setState(() => _removeSystem = v)),
          _toggle('Replace em dashes', _removeDashes, (v) => setState(() => _removeDashes = v)),
          _toggle('Replace ellipses', _removeEllipses, (v) => setState(() => _removeEllipses = v)),
          _toggle('Trim glued sentence prefix', _trimGlued, (v) => setState(() => _trimGlued = v)),
          const Divider(),
        ],
        TextField(controller: _input, minLines: 5, maxLines: 9, decoration: const InputDecoration(labelText: 'Text to format', hintText: 'Paste a message here…', border: OutlineInputBorder())),
        const SizedBox(height: 10),
        FilledButton.icon(onPressed: () { _output.text = _format(_input.text); FocusScope.of(context).unfocus(); }, icon: const Icon(Icons.auto_fix_high), label: const Text('Format text')),
        const SizedBox(height: 10),
        TextField(controller: _output, minLines: 5, maxLines: 9, readOnly: true, decoration: const InputDecoration(labelText: 'Formatted result', border: OutlineInputBorder())),
        Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: () { _input.text = _output.text; _output.clear(); }, icon: const Icon(Icons.swap_vert), label: const Text('Use result as input'))),
      ])),
    ),
  );
}
