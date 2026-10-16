import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/prompt_helpers.dart';
import 'package:glaze_flutter/core/llm/transport/native_reasoning_support.dart';

void main() {
  group('Think First follows the reasoning effort', () {
    test('each level asks for a different depth', () {
      final texts = {
        for (final e in ['min', 'low', 'medium', 'high', 'max'])
          e: PromptHelpers.thinkFirstFor(e),
      };
      expect(texts.values.toSet().length, 5);
      expect(texts['min'], contains('under 30 words'));
      expect(texts['max'], contains('600-900 words'));
      expect(
        texts['max']!.length,
        greaterThan(texts['low']!.length),
        reason: 'max must ask for more than low',
      );
    });

    test('auto is medium', () {
      expect(
        PromptHelpers.thinkFirstFor('auto'),
        PromptHelpers.thinkFirstFor('medium'),
      );
    });

    test('extra tokens grow with the effort', () {
      int t(String e) => PromptHelpers.thinkFirstExtraTokens(e);
      expect(t('min') < t('low'), isTrue);
      expect(t('low') < t('medium'), isTrue);
      expect(t('medium') < t('high'), isTrue);
      expect(t('high') < t('max'), isTrue);
    });
  });

  group('native reasoning refusal', () {
    test('recognises the Ollama message', () {
      expect(
        NativeReasoningSupport.isRefusal(
          Exception(
            'HTTP 400 - Bad Request "Mag-Mell-Reasoner-12B:latest" does not '
            'support thinking',
          ),
        ),
        isTrue,
      );
    });

    test('ignores unrelated errors', () {
      expect(
        NativeReasoningSupport.isRefusal(Exception('HTTP 500 - boom')),
        isFalse,
      );
    });

    test('remembers a refusing model per endpoint', () {
      NativeReasoningSupport.markUnsupported('http://a:11434/v1', 'm');
      expect(
        NativeReasoningSupport.isUnsupported('http://a:11434/v1', 'm'),
        isTrue,
      );
      expect(
        NativeReasoningSupport.isUnsupported('http://b:11434/v1', 'm'),
        isFalse,
      );
      NativeReasoningSupport.forget('http://a:11434/v1', 'm');
    });
  });
}
