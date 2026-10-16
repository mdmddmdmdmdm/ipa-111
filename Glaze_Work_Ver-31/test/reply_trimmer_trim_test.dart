import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/reply_trimmer.dart';

void main() {
  group('ReplyTrimmer.trimIncompleteSentences', () {
    String trim(String s) => ReplyTrimmer.trimIncompleteSentences(s);

    test('drops an unfinished sentence after an open quote', () {
      expect(trim('She smiled. "Hello there, how are'), 'She smiled.');
    });

    test('keeps whole *action* and "dialogue" spans', () {
      expect(
        trim('*She walks over.* "Hi." *She sits and'),
        '*She walks over.* "Hi."',
      );
    });

    test('abbreviations and initials are not sentence ends', () {
      expect(
        trim('Dr. Smith nodded. He turned to J. Smith and'),
        'Dr. Smith nodded.',
      );
    });

    test('a quote with a dialogue tag stays in one piece', () {
      expect(
        trim('"Where are you?" she asked. Then she'),
        '"Where are you?" she asked.',
      );
    });

    test('text that already ends cleanly is unchanged', () {
      expect(trim('Fine.'), 'Fine.');
      expect(trim('*He grins.*'), '*He grins.*');
    });

    test('text with no sentence end is unchanged', () {
      expect(trim('She smiled and then she'), 'She smiled and then she');
    });
  });
}
