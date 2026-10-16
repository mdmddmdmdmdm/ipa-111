import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/character_field_switches.dart';
import 'package:glaze_flutter/core/llm/fallback_prompt_builder.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';

const _card = Character(
  id: 'c1',
  name: 'Claire',
  description: 'Claire runs a vinyl shop downtown.',
  personality: 'Dry humour and endlessly patient.',
  scenario: 'The shop is closing for the night.',
  mesExample: 'Claire: Last call for the jazz bin.',
);

PresetBlock _block(String id, {bool enabled = true, String content = ''}) =>
    PresetBlock(
      id: id,
      name: id,
      role: 'system',
      content: content,
      enabled: enabled,
      isStatic: true,
    );

PromptPayload _payload(Character c, Preset? p) => PromptPayload(
  character: c,
  preset: p,
  history: const [ChatMessage(id: 'm1', role: 'user', content: 'Hello')],
  apiConfig: const ApiConfig(id: 'api'),
);

Set<String?> _ids(PromptResult r) => r.messages.map((m) => m.blockId).toSet();

String _all(PromptResult r) => r.messages.map((m) => m.content).join('\n');

Character _with(Character c, CharacterPromptField f, bool on) =>
    c.copyWith(extensions: extensionsWithFieldSwitch(c.extensions, f, on));

void main() {
  group('storage', () {
    test('every field is on by default', () {
      for (final f in CharacterPromptField.values) {
        expect(characterFieldEnabled(_card, f), isTrue);
      }
    });

    test('off is stored, on removes the entry and the whole map', () {
      final off = extensionsWithFieldSwitch(
        {'talkativeness': 0.5},
        CharacterPromptField.scenario,
        false,
      );
      expect(off['talkativeness'], 0.5);
      expect(
        (off[kPromptFieldSwitchesKey] as Map)['scenario'],
        false,
      );
      final back = extensionsWithFieldSwitch(
        off,
        CharacterPromptField.scenario,
        true,
      );
      expect(back.containsKey(kPromptFieldSwitchesKey), isFalse);
      expect(back['talkativeness'], 0.5);
    });
  });

  group('preset prompt', () {
    final blocksOff = Preset(
      id: 'p',
      name: 'P',
      blocks: [
        _block('char_card', enabled: false),
        _block('char_personality', enabled: false),
        _block('scenario', enabled: false),
        _block('example_dialogue', enabled: false),
        _block('chat_history'),
      ],
    );

    test('on sends a field even when the preset has its block off', () {
      final r = buildPrompt(_payload(_card, blocksOff));
      expect(
        _ids(r),
        containsAll(<String>[
          'char_card',
          'char_personality',
          'scenario',
          'example_dialogue',
        ]),
      );
      final text = _all(r);
      expect(text, contains('vinyl shop'));
      expect(text, contains('Dry humour'));
      expect(text, contains('closing for the night'));
      expect(text, contains('jazz bin'));
    });

    test('forced fields keep card order and sit before the history', () {
      final r = buildPrompt(_payload(_card, blocksOff));
      final order = r.messages
          .map((m) => m.blockId)
          .whereType<String>()
          .where(
            (id) => const {
              'char_card',
              'char_personality',
              'scenario',
              'example_dialogue',
            }.contains(id),
          )
          .toList();
      expect(order, [
        'char_card',
        'char_personality',
        'scenario',
        'example_dialogue',
      ]);
      expect(
        r.messages.indexWhere((m) => m.blockId == 'example_dialogue'),
        lessThan(r.messages.indexWhere((m) => m.content == 'Hello')),
      );
    });

    test('off removes the block even when the preset has it on', () {
      final presetOn = Preset(
        id: 'p',
        name: 'P',
        blocks: [
          _block('char_card'),
          _block('char_personality'),
          _block('chat_history'),
        ],
      );
      final c = _with(_card, CharacterPromptField.personality, false);
      final r = buildPrompt(_payload(c, presetOn));
      expect(_ids(r), contains('char_card'));
      expect(_ids(r), isNot(contains('char_personality')));
      expect(_all(r), isNot(contains('Dry humour')));
    });

    test('off also blanks the {{macro}} form of the field', () {
      final p = Preset(
        id: 'p',
        name: 'P',
        blocks: [
          _block('main', content: 'Persona: {{personality}} / {{scenario}}'),
          _block('chat_history'),
        ],
      );
      final c = _with(_card, CharacterPromptField.personality, false);
      final text = _all(buildPrompt(_payload(c, p)));
      expect(text, isNot(contains('Dry humour')));
      expect(text, contains('closing for the night'));
    });

    test('a field the preset already pulls in by macro is not doubled', () {
      final p = Preset(
        id: 'p',
        name: 'P',
        blocks: [
          _block('char_card', enabled: false),
          _block('main', content: 'About her: {{description}}'),
          _block('chat_history'),
        ],
      );
      final r = buildPrompt(_payload(_card, p));
      expect(_ids(r), isNot(contains('char_card')));
      expect(
        'vinyl shop'.allMatches(_all(r)).length,
        1,
      );
    });

    test('an empty field is not invented', () {
      final c = _card.copyWith(scenario: null);
      final r = buildPrompt(_payload(c, blocksOff));
      expect(_ids(r), isNot(contains('scenario')));
    });
  });

  group('fallback prompt (no preset)', () {
    test('sends everything by default and honours off', () {
      final all = _all(buildFallbackPrompt(_payload(_card, null)));
      expect(all, contains('vinyl shop'));
      expect(all, contains('jazz bin'));

      final c = _with(
        _with(_card, CharacterPromptField.examples, false),
        CharacterPromptField.description,
        false,
      );
      final text = _all(buildFallbackPrompt(_payload(c, null)));
      expect(text, isNot(contains('vinyl shop')));
      expect(text, isNot(contains('jazz bin')));
      expect(text, contains('Dry humour'));
    });
  });

  group('character own fields', () {
    test('System Prompt, Advanced Definition, History Instruction can be off',
        () {
      final c = _card.copyWith(
        systemPrompt: 'Never break character.',
        postHistoryInstructions: 'Stay in voice.',
        extensions: {'advanced_definition': 'Owns a cat named Miso.'},
      );
      final p = Preset(id: 'p', name: 'P', blocks: [_block('chat_history')]);
      final on = _all(buildPrompt(_payload(c, p)));
      expect(on, contains('Never break character.'));
      expect(on, contains('Miso'));
      expect(on, contains('Stay in voice.'));

      var off = _with(c, CharacterPromptField.systemPrompt, false);
      off = _with(off, CharacterPromptField.advancedDefinition, false);
      off = _with(off, CharacterPromptField.postHistory, false);
      final text = _all(buildPrompt(_payload(off, p)));
      expect(text, isNot(contains('Never break character.')));
      expect(text, isNot(contains('Miso')));
      expect(text, isNot(contains('Stay in voice.')));
    });
  });

  group('delivery report', () {
    test('reads the built prompt and names each outcome', () {
      final p = Preset(
        id: 'p',
        name: 'P',
        blocks: [_block('chat_history')],
      );
      final c = _with(
        _card.copyWith(scenario: null),
        CharacterPromptField.personality,
        false,
      );
      final r = buildPrompt(_payload(c, p));
      final reports = {
        for (final x in checkFieldDelivery(
          character: c,
          presetFound: true,
          messages: [
            for (final m in r.messages) (blockId: m.blockId, content: m.content),
          ],
        ))
          x.field: x.status,
      };
      expect(reports[CharacterPromptField.description], FieldDelivery.sending);
      expect(reports[CharacterPromptField.personality], FieldDelivery.off);
      expect(reports[CharacterPromptField.scenario], FieldDelivery.empty);
      expect(reports[CharacterPromptField.examples], FieldDelivery.sending);
    });

    test('reports missing when the text never reached the prompt', () {
      final reports = checkFieldDelivery(
        character: _card,
        presetFound: true,
        messages: const [(blockId: 'chat_history', content: 'Hello')],
      );
      expect(
        reports
            .firstWhere((r) => r.field == CharacterPromptField.description)
            .status,
        FieldDelivery.missing,
      );
    });
  });
}
