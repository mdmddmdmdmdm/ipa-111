import '../models/character.dart';
import '../models/preset.dart';
import 'character_prompt_extras.dart';
import 'macro_engine.dart';
import 'prompt/resolved_block.dart';

/// Key inside [Character.extensions] that holds the per-field send switches.
///
/// Stored as `{ "description": false, ... }`. A field with no entry is ON, so
/// every existing character keeps sending everything. Like the Advanced
/// Definition it lives in `extensions`, so it needs no database migration and
/// round-trips through the V2 JSON/PNG exporter and importer.
const String kPromptFieldSwitchesKey = 'prompt_field_switches';

/// A character text field the chat prompt can carry.
enum CharacterPromptField {
  description(
    key: 'description',
    label: 'Description',
    blockId: 'char_card',
    macro: '{{description}}',
  ),
  personality(
    key: 'personality',
    label: 'Personality',
    blockId: 'char_personality',
    macro: '{{personality}}',
  ),
  scenario(
    key: 'scenario',
    label: 'Scenario',
    blockId: 'scenario',
    macro: '{{scenario}}',
  ),
  examples(
    key: 'examples',
    label: 'Dialogue Examples',
    blockId: 'example_dialogue',
    macro: '{{mesExamples}}',
  ),
  systemPrompt(
    key: 'system_prompt',
    label: 'System Prompt',
    blockId: kCharSystemPromptBlockId,
  ),
  advancedDefinition(
    key: 'advanced_definition',
    label: 'Advanced Definition',
    blockId: kCharAdvancedDefinitionBlockId,
  ),
  postHistory(
    key: 'post_history',
    label: 'Chat History Instruction',
    blockId: kCharPostHistoryBlockId,
  );

  final String key;
  final String label;

  /// Id of the block that carries this field in the prompt.
  final String blockId;

  /// Macro that also pulls this field into a preset block, if there is one.
  final String? macro;

  const CharacterPromptField({
    required this.key,
    required this.label,
    required this.blockId,
    this.macro,
  });

  /// The four fields a preset decides about (the other three are the
  /// character's own and are always placed by the app).
  bool get isPresetField => macro != null;
}

/// The raw (unexpanded, trimmed) text the character holds for [field].
String characterFieldText(Character character, CharacterPromptField field) {
  final String? raw = switch (field) {
    CharacterPromptField.description => character.description,
    CharacterPromptField.personality => character.personality,
    CharacterPromptField.scenario => character.scenario,
    CharacterPromptField.examples => character.mesExample,
    CharacterPromptField.systemPrompt => character.systemPrompt,
    CharacterPromptField.advancedDefinition => characterAdvancedDefinition(
      character,
    ),
    CharacterPromptField.postHistory => character.postHistoryInstructions,
  };
  return (raw ?? '').trim();
}

/// Whether [field] is switched on for [character]. Defaults to on.
bool characterFieldEnabled(Character character, CharacterPromptField field) {
  final raw = character.extensions[kPromptFieldSwitchesKey];
  if (raw is Map) return raw[field.key] != false;
  return true;
}

/// Returns [extensions] with [field] switched on or off. Every other key is
/// kept; the whole switch map is dropped again once nothing is off.
Map<String, dynamic> extensionsWithFieldSwitch(
  Map<String, dynamic>? extensions,
  CharacterPromptField field,
  bool enabled,
) {
  final next = <String, dynamic>{...?extensions};
  final raw = next[kPromptFieldSwitchesKey];
  final switches = <String, bool>{};
  if (raw is Map) {
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is String && value is bool) switches[key] = value;
    }
  }
  if (enabled) {
    switches.remove(field.key);
  } else {
    switches[field.key] = false;
  }
  if (switches.isEmpty) {
    next.remove(kPromptFieldSwitchesKey);
  } else {
    next[kPromptFieldSwitchesKey] = switches;
  }
  return next;
}

/// Order the four preset fields sit in inside the prompt.
const _cardOrder = <CharacterPromptField>[
  CharacterPromptField.description,
  CharacterPromptField.personality,
  CharacterPromptField.scenario,
  CharacterPromptField.examples,
];

const _cardBlockIds = <String>{
  'char_card',
  'char_personality',
  'scenario',
  'example_dialogue',
};

/// Applies the character's field switches to the preset-driven blocks:
///
/// * OFF removes the field's block, wherever the preset put it.
/// * ON with text puts the field in when the preset would not have sent it
///   (block disabled or missing). A field the preset already sends, through its
///   block or through a `{{macro}}` in another block, is left where it is.
///
/// Call this before [injectCharacterExtras] so the System Prompt lands before
/// the blocks added here.
void applyCharacterFieldSwitches({
  required Character character,
  required MacroContext macroContext,
  required Preset preset,
  required List<ResolvedRelativeBlock> relativeBlocks,
  required List<ResolvedDepthBlock> depthBlocks,
}) {
  final enabledPresetText = [
    for (final block in preset.blocks)
      if (block.enabled && !block.isStashed) block.content.toLowerCase(),
  ];

  bool sentByMacro(CharacterPromptField field) {
    final macro = field.macro?.toLowerCase();
    if (macro == null) return false;
    return enabledPresetText.any((text) => text.contains(macro));
  }

  bool hasBlock(CharacterPromptField field) =>
      relativeBlocks.any((b) => b.id == field.blockId) ||
      depthBlocks.any((b) => b.id == field.blockId);

  for (final field in _cardOrder) {
    if (!characterFieldEnabled(character, field)) {
      relativeBlocks.removeWhere((b) => b.id == field.blockId);
      depthBlocks.removeWhere((b) => b.id == field.blockId);
      continue;
    }
    final text = characterFieldText(character, field);
    if (text.isEmpty || hasBlock(field) || sentByMacro(field)) continue;

    final expanded = replaceMacros(text, macroContext).text.trim();
    if (expanded.isEmpty) continue;
    final block = ResolvedRelativeBlock(
      id: field.blockId,
      name: field.label,
      role: 'system',
      content: expanded,
      // External character text; counted under its own bucket, not as preset.
      contentForAccounting: '',
    );
    relativeBlocks.insert(
      _insertIndexFor(field, relativeBlocks),
      block,
    );
  }
}

int _insertIndexFor(
  CharacterPromptField field,
  List<ResolvedRelativeBlock> blocks,
) {
  final rank = _cardOrder.indexOf(field);
  int rankOf(String id) => _cardOrder.indexWhere((f) => f.blockId == id);

  // After the last card block that comes earlier in the card ...
  var after = -1;
  for (var i = 0; i < blocks.length; i++) {
    final r = rankOf(blocks[i].id);
    if (_cardBlockIds.contains(blocks[i].id) && r >= 0 && r < rank) after = i;
  }
  if (after >= 0) return after + 1;

  // ... else before the first card block that comes later ...
  final before = blocks.indexWhere((b) {
    final r = rankOf(b.id);
    return _cardBlockIds.contains(b.id) && r > rank;
  });
  if (before >= 0) return before;

  // ... else just ahead of the chat history, never silently dropped.
  final history = blocks.indexWhere((b) => b.id == 'chat_history');
  return history < 0 ? blocks.length : history;
}

/// How one field is doing in the prompt, for the editor's indicator.
enum FieldDelivery {
  /// Found in the prompt that was just built.
  sending,

  /// Switched on but the field has no text.
  empty,

  /// Switched off, so it is not sent.
  off,

  /// Switched on but missing from the built prompt.
  missing,

  /// Not built yet.
  unchecked,
}

class FieldDeliveryReport {
  final CharacterPromptField field;
  final FieldDelivery status;

  /// Short human reason, shown under the field name.
  final String detail;

  const FieldDeliveryReport(this.field, this.status, this.detail);
}

/// Reads the built prompt [messages] (their block ids and text) and reports,
/// for every field, whether it actually reached the model. This looks at the
/// real output rather than re-deriving the rules, so the indicator cannot say
/// "sending" while the prompt says otherwise.
List<FieldDeliveryReport> checkFieldDelivery({
  required Character character,
  required Iterable<({String? blockId, String content})> messages,
  required bool presetFound,
}) {
  final list = messages.toList();
  return [
    for (final field in CharacterPromptField.values)
      _reportFor(field, character, list, presetFound),
  ];
}

FieldDeliveryReport _reportFor(
  CharacterPromptField field,
  Character character,
  List<({String? blockId, String content})> messages,
  bool presetFound,
) {
  if (!characterFieldEnabled(character, field)) {
    return FieldDeliveryReport(
      field,
      FieldDelivery.off,
      'Off - not sent to the model',
    );
  }
  final text = characterFieldText(character, field);
  if (text.isEmpty) {
    return FieldDeliveryReport(
      field,
      FieldDelivery.empty,
      'On, but this field is empty',
    );
  }
  final byBlock = messages.any((m) => m.blockId == field.blockId);
  // A preset can also pull the text in through a macro in a block of its own,
  // and the built-in layout carries every card field in one message. Look for
  // the field's own words inside the built prompt instead.
  final probes = _probes(text);
  final haystack = [for (final m in messages) _squash(m.content)];
  final byText =
      probes.isNotEmpty && probes.any((p) => haystack.any((h) => h.contains(p)));
  if (byBlock || byText) {
    return FieldDeliveryReport(
      field,
      FieldDelivery.sending,
      presetFound ? 'Sending' : 'Sending (no preset - built-in layout)',
    );
  }
  if (probes.isEmpty) {
    // Nothing but macros / very short text: there is nothing to look for, so
    // do not claim the field is missing.
    return FieldDeliveryReport(
      field,
      FieldDelivery.unchecked,
      'On - could not verify (the field is only a few words or macros)',
    );
  }
  return FieldDeliveryReport(
    field,
    FieldDelivery.missing,
    'On, but not found in the prompt',
  );
}

/// Collapses runs of whitespace so a line break in the card and a space in the
/// built prompt compare equal.
String _squash(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

final RegExp _macroPattern = RegExp(
  r'\{\{[^}]*\}\}|<USER>|<BOT>|<CHAR>|<START>',
  caseSensitive: false,
);

/// Stretches of the field's text that survive macro expansion unchanged, used
/// to find the field inside a merged message. The text is cut at every macro
/// and line break; the longest pieces (up to 60 characters each) are returned,
/// longest first. A field whose lines all contain `{{user}}` / `{{char}}`
/// still has plain words between the macros, so it can be matched.
List<String> _probes(String text) {
  final pieces = <String>[];
  for (final line in text.split('\n')) {
    for (final part in line.split(_macroPattern)) {
      final t = _squash(part);
      if (t.length >= 6) pieces.add(t.length > 60 ? t.substring(0, 60) : t);
    }
  }
  pieces.sort((a, b) => b.length.compareTo(a.length));
  return pieces.take(4).toList();
}
