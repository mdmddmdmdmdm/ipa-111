import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/services/chat_message_formatter.dart';

void main() {
  ChatMessageFormatter makeFormatter() =>
      ChatMessageFormatter(userNames: ['Noah'], charNames: ['Lucia']);

  FormatMessageResult one(String text, {bool isUser = false}) => makeFormatter()
      .formatAll([FormatMessageInput(text: text, isUser: isUser)])
      .single;

  group('stray placeholders', () {
    test('a character reply talks about the user by default', () {
      final result = one('She glares {{obj}} down.');
      expect(result.text, '*She glares {{user}} down.*');
      expect(result.placeholders, 1);
    });

    test('a user message talks about the character by default', () {
      final result = one('I look at {{obj}} and sigh.', isUser: true);
      expect(result.text, '*I look at {{char}} and sigh.*');
    });

    test('a sentence that already names one person points at the other', () {
      expect(
        one('Lucia glares {{obj}} down.').text,
        '*Lucia glares {{user}} down.*',
      );
      expect(
        one('{{user}} waits while {{subj}} laughs.').text,
        '*{{user}} waits while {{char}} laughs.*',
      );
    });

    test('the same token reads the same way across the whole chat', () {
      final results = makeFormatter().formatAll(const [
        FormatMessageInput(text: '{{obj}} nods slowly.', isUser: false),
        FormatMessageInput(
          text: '{{user}} waits while {{obj}} laughs.',
          isUser: false,
        ),
      ]);
      expect(results[0].text, '*{{char}} nods slowly.*');
      expect(results[1].text, '*{{user}} waits while {{char}} laughs.*');
    });

    test('names, keywords, case and possessives are read outright', () {
      final result = one("{{User}} {{player}} {{Lucia}} {{user's}} hand");
      expect(result.text, "*{{user}} {{user}} {{char}} {{user}}'s hand*");
      expect(result.placeholders, 4);
    });

    test('macros the app really expands are left alone', () {
      final result = one('{{random::a::b}} {{time}}');
      expect(result.text, '*{{random::a::b}} {{time}}*');
      expect(result.placeholders, 0);
    });
  });

  group('formatting', () {
    test('wraps narration, keeps dialogue plain and straightens quotes', () {
      expect(
        one('She said “hi” and left.').text,
        '*She said* "hi" *and left.*',
      );
    });

    test('drops a think block with its content', () {
      expect(one('<think>planning</think>\nShe nods.').text, '*She nods.*');
    });

    test('keeps the content of a reply that is one single think block', () {
      expect(one('<think>just a thought</think>').text, '*just a thought*');
    });

    test('never blanks a message', () {
      const text = '<think>a</think><think>b</think>';
      expect(one(text).text, text);
    });

    test('leaves lists, headings, tables, code and HTML alone', () {
      const text =
          '# Title\n- one\n- two\n```\ncode *x*\n```\n| a | b |\n<div>hi</div>\n'
          'Plain line "said" here.';
      expect(
        one(text).text,
        '# Title\n- one\n- two\n```\ncode *x*\n```\n| a | b |\n<div>hi</div>\n'
        '*Plain line* "said" *here.*',
      );
    });

    test('keeps a line that is bold from end to end', () {
      const text = '**Thought here.**';
      final result = one(text);
      expect(result.text, text);
      expect(result.reformatted, isFalse);
    });

    test('a message that is already formatted comes back untouched', () {
      const text = '*She nods.* "Hello."';
      final result = one(text);
      expect(result.text, text);
      expect(result.placeholders, 0);
      expect(result.reformatted, isFalse);
    });

    test('stray whitespace alone is not worth a rewrite', () {
      const text = '  *She nods.* "Hello."  \n';
      expect(one(text).text, text);
    });

    test('running it twice changes nothing the second time', () {
      const text =
          '*it there,* "Guess I just grew." She gestures.\n'
          'She just glares {{obj}} down. "Something wrong?"\n\n'
          '**Do not blush.**';
      final first = one(text).text;
      final second = one(first);
      expect(second.text, first);
      expect(second.placeholders, 0);
    });
  });
}
