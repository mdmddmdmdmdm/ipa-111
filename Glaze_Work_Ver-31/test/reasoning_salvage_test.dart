import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/reasoning_salvage.dart';

void main() {
  test('a normal reply is never touched', () {
    final r = salvageEmptyReply(text: 'Hello.', reasoning: 'thinking');
    expect(r.salvaged, isFalse);
    expect(r.text, 'Hello.');
    expect(r.reasoning, 'thinking');
  });

  test('text after a closing think tag becomes the reply', () {
    final r = salvageEmptyReply(
      text: '',
      reasoning: '<think>plan the scene</think>\n*She smiles.* "Hi there."',
    );
    expect(r.salvaged, isTrue);
    expect(r.text, '*She smiles.* "Hi there."');
    expect(r.reasoning, 'plan the scene');
  });

  test('a Final response label splits analysis from the reply', () {
    final r = salvageEmptyReply(
      text: '',
      reasoning: 'Analysis of the scene.\nFinal response: *Claire looks up.* '
          '"Can I help you find anything?"',
    );
    expect(r.salvaged, isTrue);
    expect(r.text.startsWith('*Claire looks up.*'), isTrue);
    expect(r.reasoning, 'Analysis of the scene.');
  });

  test('roleplay written wholly in the reasoning channel is recovered', () {
    final r = salvageEmptyReply(
      text: '',
      reasoning: '*Claire glances up from the register.* "Oh, hi. Looking '
          'for something specific?"',
    );
    expect(r.salvaged, isTrue);
    expect(r.reasoning, isNull);
  });

  test('genuine thinking is left as reasoning', () {
    final r = salvageEmptyReply(
      text: '',
      reasoning: 'The user wants Claire to react. I should keep it short '
          'and "in character".',
    );
    expect(r.salvaged, isFalse);
    expect(r.text, '');
  });

  test('empty reasoning stays empty', () {
    final r = salvageEmptyReply(text: '', reasoning: null);
    expect(r.salvaged, isFalse);
  });
}
