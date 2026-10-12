import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/prompt_helpers.dart';

void main() {
  group('PromptHelpers user-name accuracy', () {
    test('persists the new setting and remains backward compatible', () {
      const helpers = PromptHelpers(userNameAccuracy: true);
      final restored = PromptHelpers.fromJson(helpers.toJson());
      expect(restored.userNameAccuracy, isTrue);
      expect(PromptHelpers.fromJson({'formatting': true}).userNameAccuracy, isFalse);
    });

    test('adds explicit persona-name guidance only when enabled', () {
      expect(const PromptHelpers().buildText(), isNull);
      final text = const PromptHelpers(userNameAccuracy: true).buildText();
      expect(text, contains('active persona name supplied by the app'));
      expect(text, contains('{{user}}'));
      expect(text, contains('Do not guess'));
    });

    test('counts name accuracy as an active helper', () {
      expect(const PromptHelpers(userNameAccuracy: true).anyActive, isTrue);
    });
  });
}
