import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/stream_accumulator.dart';

StreamAccumulator _acc() => StreamAccumulator(
  tagStart: '<think>',
  tagEnd: '</think>',
  hasInlineTags: true,
);

void main() {
  group('closing tag without an opening tag', () {
    test('everything before it becomes the reasoning', () {
      final a = _acc();
      a.consumeDelta('She is angry, so she should snap back.</think>"Get out."');
      expect(a.reasoning, 'She is angry, so she should snap back.');
      expect(a.text, '"Get out."');
      expect(a.splitDone, isTrue);
    });

    test('works when the tag is split across chunks', () {
      final a = _acc();
      for (final chunk in ['Plan the beat', '.</th', 'ink>', 'The reply.']) {
        a.consumeDelta(chunk);
      }
      expect(a.reasoning, 'Plan the beat.');
      expect(a.text, 'The reply.');
    });

    test('a normal think block is unchanged', () {
      final a = _acc();
      a.consumeDelta('<think>plan</think>reply');
      expect(a.reasoning, 'plan');
      expect(a.text, 'reply');
    });

    test('a reply with no tags at all stays a reply', () {
      final a = _acc();
      a.consumeDelta('Just a reply.');
      expect(a.reasoning, '');
      expect(a.text, 'Just a reply.');
    });
  });
}
