import '../models/preset.dart';

/// Id of the preset the prompt builder uses when a chat has none selected.
const String kBuiltInPresetId = 'builtin-default';

/// The preset used when no preset is bound to the character or chat and none
/// is active.
///
/// Before this existed, a chat with no preset went through a bare fallback
/// that sent only "You are a helpful assistant." plus the character card. That
/// path had no place for the chat summary, the Memory Book, lorebooks, the
/// author's note or guided generation, so with no preset selected none of them
/// ever reached the model. This preset carries every one of those blocks (the
/// same system blocks the bundled presets have), so they all work without the
/// user having to import a preset first.
///
/// The one editable block is the short main prompt; everything else is a
/// built-in block whose content the builder fills from the character, persona,
/// summary and memory.
Preset builtInDefaultPreset() => Preset(
  id: kBuiltInPresetId,
  name: 'Built-in default',
  blocks: [
    PresetBlock(
      id: 'built_in_main',
      name: 'Main Prompt',
      role: 'system',
      content:
          "You are writing {{char}}'s side of an ongoing roleplay with "
          "{{user}}. Write {{char}}'s next reply: stay true to {{char}}'s "
          'personality and voice, keep continuity with everything that has '
          'already happened, and let {{char}} react to what {{user}} just did '
          "or said. Never write {{user}}'s dialogue, actions, thoughts or "
          'decisions; end the reply where {{user}} would naturally respond. '
          'Stay in the story with no out-of-character notes.',
    ),
    _system('worldInfoBefore', 'World Info Before'),
    _system('user_persona', 'User Persona'),
    _system('char_card', 'Character Card'),
    _system('char_personality', 'Character Personality'),
    _system('scenario', 'Scenario'),
    _system('example_dialogue', 'Dialogue Examples'),
    _system('worldInfoAfter', 'World Info After'),
    _system('memory', 'Memory Book'),
    _system('summary', 'Summary'),
    PresetBlock(
      id: 'authors_note',
      name: "Author's Note",
      role: 'system',
      content: '',
      isStatic: true,
    ),
    PresetBlock(
      id: 'guided_generation',
      name: 'Guided Generation',
      role: 'system',
      content:
          '[Generate your next reply according to these instructions: '
          '{{guidance}}]',
      isStatic: true,
    ),
    _system('chat_history', 'Chat History'),
  ],
);

PresetBlock _system(String id, String name) => PresetBlock(
  id: id,
  name: name,
  role: 'system',
  content: '',
  isStatic: true,
);
