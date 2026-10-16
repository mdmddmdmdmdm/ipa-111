import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/reply_trimmer.dart';
import 'package:glaze_flutter/core/utils/emoji_text.dart';

void main() {
  group('stripLoneSurrogates', () {
    test('leaves valid emoji untouched', () {
      const text = 'Hi 😊 👍🏽 👨‍👩‍👧 ❤️ ✨';
      expect(stripLoneSurrogates(text), text);
    });

    test('replaces a broken half with U+FFFD', () {
      final broken = 'a${String.fromCharCode(0xD83D)}b';
      expect(stripLoneSurrogates(broken), 'a\uFFFDb');
      final lowOnly = '${String.fromCharCode(0xDE0A)}x';
      expect(stripLoneSurrogates(lowOnly), '\uFFFDx');
    });
  });

  group('safePrefix', () {
    test('never cuts an emoji in half', () {
      const text = 'ab😊cd'; // 😊 occupies indices 2 and 3
      expect(safePrefix(text, 3), 'ab');
      expect(safePrefix(text, 4), 'ab😊');
      expect(safePrefix(text, 2), 'ab');
      expect(safePrefix(text, 99), text);
      expect(safePrefix(text, 0), '');
    });
  });

  group('endsWithEmoji', () {
    test('detects emoji endings and ignores plain text', () {
      expect(endsWithEmoji('That sounds great 😊'), isTrue);
      expect(endsWithEmoji('Love it ❤️  '), isTrue);
      expect(endsWithEmoji('*waves* 👋*'), isTrue);
      expect(endsWithEmoji('Just words'), isFalse);
      expect(endsWithEmoji(''), isFalse);
    });
  });

  group('ReplyTrimmer with emoji', () {
    test('keeps a last sentence that ends on an emoji', () {
      const text = 'Hello there! I am so happy to see you 😊';
      expect(ReplyTrimmer.trimIncompleteSentences(text), text);
    });

    test('still trims a genuinely unfinished sentence', () {
      expect(
        ReplyTrimmer.trimIncompleteSentences(
          'Hello there! I was just about to',
        ),
        'Hello there!',
      );
    });
  });
}
