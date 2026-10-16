import '../models/character.dart';
import 'character_field_switches.dart';
import 'macro_engine.dart';
import 'prompt/resolved_block.dart';

/// Key inside [Character.extensions] that holds the "Advanced Definition".
///
/// It lives in `extensions` on purpose: that map is already stored with the
/// character, copied with it into chat sessions, and written/read untouched by
/// the SillyTavern V2 JSON/PNG exporter and importer, so the field survives a
/// round trip and old characters keep working without a database migration.
const String kAdvancedDefinitionKey = 'advanced_definition';

/// The character's Advanced Definition, or an empty string when there is none.
String characterAdvancedDefinition(Character character) {
  final value = character.extensions[kAdvancedDefinitionKey];
  return value is String ? value.trim() : '';
}

/// Returns [extensions] with the Advanced Definition set (or removed when
/// [value] is blank). Every other key is kept as it was.
Map<String, dynamic> extensionsWithAdvancedDefinition(
  Map<String, dynamic>? extensions,
  String? value,
) {
  final next = <String, dynamic>{...?extensions};
  final text = value?.trim() ?? '';
  if (text.isEmpty) {
    next.remove(kAdvancedDefinitionKey);
  } else {
    next[kAdvancedDefinitionKey] = text;
  }
  return next;
}

/// Block ids used for the character fields that sit outside the preset's own
/// character blocks.
const String kCharSystemPromptBlockId = 'char_system_prompt';
const String kCharAdvancedDefinitionBlockId = 'char_advanced_definition';
const String kCharPostHistoryBlockId = 'char_post_history';

/// The three character fields the chat prompt used to drop, with macros
/// (`{{char}}`, `{{user}}`, ...) already expanded and blank fields removed.
class CharacterPromptExtras {
  final String systemPrompt;
  final String advancedDefinition;
  final String postHistory;

  const CharacterPromptExtras({
    required this.systemPrompt,
    required this.advancedDefinition,
    required this.postHistory,
  });

  factory CharacterPromptExtras.resolve(
    Character character,
    MacroContext macroContext,
  ) {
    String expand(String? raw) {
      final text = (raw ?? '').trim();
      if (text.isEmpty) return '';
      return replaceMacros(text, macroContext).text.trim();
    }

    // A field switched off in the editor is treated as empty, so it is neither
    // sent nor counted.
    String field(CharacterPromptField f, String? raw) =>
        characterFieldEnabled(character, f) ? expand(raw) : '';

    return CharacterPromptExtras(
      systemPrompt: field(
        CharacterPromptField.systemPrompt,
        character.systemPrompt,
      ),
      advancedDefinition: field(
        CharacterPromptField.advancedDefinition,
        characterAdvancedDefinition(character),
      ),
      postHistory: field(
        CharacterPromptField.postHistory,
        character.postHistoryInstructions,
      ),
    );
  }

  bool get isEmpty =>
      systemPrompt.isEmpty && advancedDefinition.isEmpty && postHistory.isEmpty;
}

const _characterBlockIds = <String>{
  'char_card',
  'char_personality',
  'scenario',
  'example_dialogue',
};

/// Adds the character's System Prompt, Advanced Definition and Chat History
/// Instruction to a preset-driven prompt.
///
/// Placement follows the blocks the preset already has:
/// * System Prompt goes right before the first character block, so the model
///   reads the character's own instructions before the card itself.
/// * Advanced Definition goes right after the last character block, so it reads
///   as part of the card.
/// * Chat History Instruction becomes a depth-0 block, i.e. after the newest
///   chat message, which is where "post-history" instructions belong.
///
/// When the preset has no character blocks at all the first two land just
/// before the chat history instead, so the text is never silently dropped.
void injectCharacterExtras({
  required CharacterPromptExtras extras,
  required List<ResolvedRelativeBlock> relativeBlocks,
  required List<ResolvedDepthBlock> depthBlocks,
}) {
  int firstCharacterBlock() =>
      relativeBlocks.indexWhere((b) => _characterBlockIds.contains(b.id));
  int afterLastCharacterBlock() {
    final i = relativeBlocks.lastIndexWhere(
      (b) => _characterBlockIds.contains(b.id),
    );
    return i < 0 ? -1 : i + 1;
  }

  int beforeChatHistory() {
    final i = relativeBlocks.indexWhere((b) => b.id == 'chat_history');
    return i < 0 ? relativeBlocks.length : i;
  }

  if (extras.systemPrompt.isNotEmpty) {
    final at = firstCharacterBlock();
    relativeBlocks.insert(
      at < 0 ? beforeChatHistory() : at,
      ResolvedRelativeBlock(
        id: kCharSystemPromptBlockId,
        name: 'Character System Prompt',
        role: 'system',
        content: extras.systemPrompt,
        contentForAccounting: extras.systemPrompt,
      ),
    );
  }

  if (extras.advancedDefinition.isNotEmpty) {
    final at = afterLastCharacterBlock();
    relativeBlocks.insert(
      at < 0 ? beforeChatHistory() : at,
      ResolvedRelativeBlock(
        id: kCharAdvancedDefinitionBlockId,
        name: 'Advanced Definition',
        role: 'system',
        content: extras.advancedDefinition,
        // Counted under the Description bucket (see ContextCalculator), so it
        // is not counted a second time as preset text.
        contentForAccounting: '',
      ),
    );
  }

  if (extras.postHistory.isNotEmpty) {
    depthBlocks.add(
      ResolvedDepthBlock(
        id: kCharPostHistoryBlockId,
        role: 'system',
        content: extras.postHistory,
        depth: 0,
      ),
    );
  }
}
