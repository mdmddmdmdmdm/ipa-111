import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/provider_chats/provider_chat_importer.dart';
import 'package:glaze_flutter/features/catalog/provider_chats/provider_chat_models.dart';
import 'package:glaze_flutter/features/catalog/provider_chats/provider_chat_parsers.dart';

void main() {
  const summary = ProviderChatSummary(
    site: ProviderChatSite.janitor,
    chatId: 'c1',
    characterName: 'Maya',
  );

  group('parseProviderChatList', () {
    test('reads a chat list, joins the avatar and sorts newest first', () {
      final rows = parseProviderChatList(
        {
          'chats': [
            {
              'id': 'old',
              'character': {'id': 'ch0', 'name': 'Old', 'avatar': 'o.png'},
              'updated_at': '2026-01-01T10:00:00Z',
            },
            {
              'id': 'c1',
              'character': {'id': 'ch1', 'name': 'Maya', 'avatar': 'a.png'},
              'updated_at': '2026-10-01T10:00:00Z',
              'last_message': 'See you soon',
              'message_count': 42,
            },
          ],
        },
        site: ProviderChatSite.janitor,
        accountLabel: 'noah',
        avatarBase: 'https://ella.janitorai.com/bot-avatars/',
        characterUrl: (id) => 'https://janitorai.com/characters/$id',
      );
      expect(rows.map((r) => r.chatId), ['c1', 'old']);
      expect(rows.first.characterName, 'Maya');
      expect(
        rows.first.avatarUrl,
        'https://ella.janitorai.com/bot-avatars/a.png',
      );
      expect(rows.first.lastMessage, 'See you soon');
      expect(rows.first.messageCount, 42);
      expect(rows.first.accountLabel, 'noah');
      expect(rows.first.characterUrl, 'https://janitorai.com/characters/ch1');
    });

    test('accepts a bare list and skips rows without an id', () {
      final rows = parseProviderChatList(
        [
          {'name': 'No id'},
          {'chat_id': 'x', 'character_name': 'Kai'},
        ],
        site: ProviderChatSite.chub,
      );
      expect(rows.length, 1);
      expect(rows.single.characterName, 'Kai');
    });
  });

  group('parseProviderTranscript', () {
    test('keeps main messages in order, with memory and greeting', () {
      final t = parseProviderTranscript(
        {
          'chatMessages': [
            {'is_bot': true, 'message': 'Hello', 'is_main': true},
            {'is_bot': false, 'message': 'Hi there'},
            {'is_bot': true, 'message': 'Another take', 'is_main': false},
            {'is_bot': true, 'message': 'How are you?'},
          ],
          'memory': 'Sam likes tea.',
          'character': {
            'first_messages': ['Opening line'],
          },
        },
        summary: summary,
      );
      expect(t.messages.map((m) => m.text), [
        'Hello',
        'Hi there',
        'How are you?',
      ]);
      expect(t.messages.map((m) => m.isUser), [false, true, false]);
      expect(t.memory, 'Sam likes tea.');
      expect(t.greetings, ['Opening line']);
    });

    test('reads role-style messages and list memories', () {
      final t = parseProviderTranscript(
        {
          'messages': [
            {'role': 'assistant', 'content': 'A'},
            {'role': 'user', 'content': 'B'},
          ],
          'memories': [
            {'content': 'one'},
            'two',
          ],
        },
        summary: summary,
      );
      expect(t.messages.length, 2);
      expect(t.messages.last.isUser, isTrue);
      expect(t.memory, '- one\n- two');
    });
  });

  group('parseProviderChatFile', () {
    test('reads SillyTavern JSONL', () {
      const jsonl =
          '{"user_name":"Sam","character_name":"Maya","chat_metadata":{}}\n'
          '{"name":"Maya","is_user":false,"mes":"Hello","send_date":"2026-10-01 10:00:00"}\n'
          '{"name":"Sam","is_user":true,"mes":"Hi"}';
      final t = parseProviderChatFile(jsonl, fileName: 'chat.jsonl');
      expect(t.summary.characterName, 'Maya');
      expect(t.userName, 'Sam');
      expect(t.messages.map((m) => m.text), ['Hello', 'Hi']);
      expect(t.messages.last.isUser, isTrue);
    });

    test('reads plain "Name: message" text', () {
      const txt = 'Maya: Hello there\nstill Maya\nSam: Hi\nMaya: Welcome';
      final t = parseProviderChatFile(txt, fileName: 'c.txt');
      expect(t.summary.characterName, 'Maya');
      expect(t.userName, 'Sam');
      expect(t.messages.length, 3);
      expect(t.messages.first.text, 'Hello there\nstill Maya');
    });

    test('an unreadable file gives no messages', () {
      expect(
        parseProviderChatFile('just some words', fileName: 'x.txt').messages,
        isEmpty,
      );
    });
  });

  group('import and export', () {
    final transcript = ProviderChatTranscript(
      summary: summary,
      userName: 'Sam',
      memory: 'Remember the lighthouse.',
      messages: const [
        ProviderChatMessage(isUser: false, text: 'Hello', alternates: ['Hey']),
        ProviderChatMessage(isUser: true, text: 'Hi', name: 'Sam'),
      ],
    );

    test('import keeps order, roles, persona name and swipes', () {
      final messages = buildImportMessages(transcript);
      expect(messages.map((m) => m.role), ['assistant', 'user']);
      expect(messages.first.swipes, ['Hello', 'Hey']);
      expect(messages.first.swipeId, 0);
      expect(messages.last.personaName, 'Sam');
    });

    test('exported JSONL reads back to the same chat', () {
      final jsonl = buildProviderChatJsonl(transcript);
      final back = parseProviderChatFile(jsonl, fileName: 'back.jsonl');
      expect(back.summary.characterName, 'Maya');
      expect(back.messages.map((m) => m.text), ['Hello', 'Hi']);
      expect(back.messages.first.alternates, ['Hey']);
    });
  });
}
