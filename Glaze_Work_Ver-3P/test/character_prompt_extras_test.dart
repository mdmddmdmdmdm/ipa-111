import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/character_prompt_extras.dart';
import 'package:glaze_flutter/core/llm/fallback_prompt_builder.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/prompt/prompt_payload.dart';
import 'package:glaze_flutter/core/llm/prompt/resolved_block.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/services/character_importer.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';

class _TestImageStorage extends ImageStorageService {
  _TestImageStorage()
    : super(Directory.systemTemp.createTempSync('glaze_extras_test_').path);
}

ResolvedRelativeBlock _block(String id) => ResolvedRelativeBlock(
  id: id,
  name: id,
  role: 'system',
  content: 'text of $id',
  contentForAccounting: 'text of $id',
);

MacroContext _macros() => const MacroContext(
  charName: 'Claire',
  userName: 'Sam',
  charId: 'c1',
  sessionId: '',
);

const _character = Character(
  id: 'c1',
  name: 'Claire',
  systemPrompt: '{{char}} never breaks character.',
  postHistoryInstructions: 'Stay in voice, {{user}} is watching.',
  extensions: {kAdvancedDefinitionKey: '  Claire owns a vinyl shop.  '},
);

void main() {
  group('advanced definition storage', () {
    test('reads the trimmed value and ignores non-strings', () {
      expect(characterAdvancedDefinition(_character), 'Claire owns a vinyl shop.');
      expect(
        characterAdvancedDefinition(
          const Character(
            id: 'c',
            name: 'n',
            extensions: {kAdvancedDefinitionKey: 5},
          ),
        ),
        '',
      );
    });

    test('writing keeps other extension keys and blank removes the key', () {
      final set = extensionsWithAdvancedDefinition({
        'talkativeness': 0.5,
      }, ' info ');
      expect(set, {'talkativeness': 0.5, kAdvancedDefinitionKey: 'info'});

      final cleared = extensionsWithAdvancedDefinition(set, '   ');
      expect(cleared, {'talkativeness': 0.5});
    });
  });

  group('injectCharacterExtras', () {
    test('expands macros and drops blank fields', () {
      final extras = CharacterPromptExtras.resolve(_character, _macros());
      expect(extras.systemPrompt, 'Claire never breaks character.');
      expect(extras.postHistory, 'Stay in voice, Sam is watching.');
      expect(extras.advancedDefinition, 'Claire owns a vinyl shop.');

      final empty = CharacterPromptExtras.resolve(
        const Character(id: 'c', name: 'n'),
        _macros(),
      );
      expect(empty.isEmpty, isTrue);
    });

    test('places each field relative to the preset character blocks', () {
      final blocks = [
        _block('main'),
        _block('user_persona'),
        _block('char_card'),
        _block('char_personality'),
        _block('scenario'),
        _block('chat_history'),
      ];
      final depth = <ResolvedDepthBlock>[];
      injectCharacterExtras(
        extras: CharacterPromptExtras.resolve(_character, _macros()),
        relativeBlocks: blocks,
        depthBlocks: depth,
      );

      expect(blocks.map((b) => b.id).toList(), [
        'main',
        'user_persona',
        kCharSystemPromptBlockId,
        'char_card',
        'char_personality',
        'scenario',
        kCharAdvancedDefinitionBlockId,
        'chat_history',
      ]);
      expect(depth, hasLength(1));
      expect(depth.single.id, kCharPostHistoryBlockId);
      expect(depth.single.depth, 0);
      expect(depth.single.role, 'system');
    });

    test('never drops the text when the preset has no character blocks', () {
      final blocks = [_block('main'), _block('chat_history')];
      injectCharacterExtras(
        extras: CharacterPromptExtras.resolve(_character, _macros()),
        relativeBlocks: blocks,
        depthBlocks: <ResolvedDepthBlock>[],
      );
      expect(blocks.map((b) => b.id).toList(), [
        'main',
        kCharSystemPromptBlockId,
        kCharAdvancedDefinitionBlockId,
        'chat_history',
      ]);
    });
  });

  group('fallback prompt (no preset)', () {
    PromptPayload payload(Character c) => PromptPayload(
      character: c,
      history: const [ChatMessage(id: 'm1', role: 'user', content: 'Hi')],
      apiConfig: const ApiConfig(
        id: 'api',
        contextSize: 8000,
        maxTokens: 500,
      ),
    );

    test('now carries the character card and the extra fields', () {
      final result = buildFallbackPrompt(
        payload(
          _character.copyWith(
            description: '{{char}} is a record-store clerk.',
            personality: 'blunt',
            scenario: 'Closing time.',
          ),
        ),
      );
      final system = result.messages
          .where((m) => m.role == 'system')
          .map((m) => m.content)
          .join('\n---\n');
      expect(system, contains('Claire never breaks character.'));
      expect(system, contains('Claire is a record-store clerk.'));
      expect(system, contains('Personality:\nblunt'));
      expect(system, contains('Scenario:\nClosing time.'));
      expect(system, contains('Claire owns a vinyl shop.'));
      // Post-history instructions come after the newest chat message.
      expect(result.messages.last.blockId, kCharPostHistoryBlockId);
      expect(result.messages.last.content, 'Stay in voice, Sam is watching.');
      expect(result.messages[result.messages.length - 2].content, 'Hi');
    });

    test('a character with no text adds no extra messages', () {
      final result = buildFallbackPrompt(
        payload(const Character(id: 'c', name: 'Empty')),
      );
      expect(result.messages, hasLength(2));
    });
  });

  test('advanced definition survives a V2 JSON import', () async {
    final importer = CharacterImporter(_TestImageStorage());
    final card = {
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {
        'name': 'Claire',
        'description': 'd',
        'extensions': {kAdvancedDefinitionKey: 'Owns a vinyl shop.'},
      },
    };
    final result = await importer.importFromBytes(
      Uint8List.fromList(utf8.encode(jsonEncode(card))),
      'claire.json',
    );
    expect(characterAdvancedDefinition(result.character), 'Owns a vinyl shop.');
  });
}
