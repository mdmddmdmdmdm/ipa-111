import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/services/reply_suggestions.dart';

void main() {
  group('ReplySuggestionService.parse', () {
    test('reads a JSON array, also inside a code fence', () {
      const raw = '```json\n["One.", "Two.", "Three."]\n```';
      expect(ReplySuggestionService.parse(raw), ['One.', 'Two.', 'Three.']);
    });

    test('falls back to numbered lines', () {
      const raw = '1. First idea\n2) Second idea\n- Third idea\n4. Extra';
      expect(
        ReplySuggestionService.parse(raw),
        ['First idea', 'Second idea', 'Third idea'],
      );
    });

    test('ignores thinking blocks', () {
      const raw = '<think>hmm ["no"]</think>["Real one"]';
      expect(ReplySuggestionService.parse(raw), ['Real one']);
    });
  });
}
