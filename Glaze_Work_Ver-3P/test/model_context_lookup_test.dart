import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/model_context_lookup.dart';

void main() {
  group('contextFromModelEntry', () {
    test('reads each provider\'s field name', () {
      expect(contextFromModelEntry({'id': 'x', 'context_length': 131072}), 131072);
      expect(contextFromModelEntry({'name': 'models/g', 'inputTokenLimit': 1048576}), 1048576);
      expect(contextFromModelEntry({'id': 'c', 'max_input_tokens': 200000}), 200000);
      expect(contextFromModelEntry({'id': 'm', 'max_context_length': 128000}), 128000);
      expect(contextFromModelEntry({'id': 'q', 'context_window': 32768}), 32768);
      expect(contextFromModelEntry({'id': 'v', 'max_model_len': '8192'}), 8192);
      expect(contextFromModelEntry({'id': 'l', 'meta': {'n_ctx_train': 4096}}), 4096);
      expect(
        contextFromModelEntry({'id': 'o', 'top_provider': {'context_length': 64000}}),
        64000,
      );
    });
    test('null when nothing is reported or the value is 0', () {
      expect(contextFromModelEntry({'id': 'x'}), isNull);
      expect(contextFromModelEntry({'id': 'x', 'context_length': 0}), isNull);
    });
  });

  group('findModelEntry', () {
    final list = <Map<dynamic, dynamic>>[
      {'id': 'openai/gpt-4o', 'context_length': 128000},
      {'id': 'meta/llama-3.1-70b:free', 'context_length': 131072},
      {'name': 'models/gemini-2.5-pro', 'inputTokenLimit': 1048576},
    ];
    test('exact, :tag-less, org-less and models/ prefix', () {
      expect(findModelEntry(list, 'openai/gpt-4o'), isNotNull);
      expect(findModelEntry(list, 'meta/llama-3.1-70b'), isNotNull);
      expect(findModelEntry(list, 'gpt-4o'), isNotNull);
      expect(findModelEntry(list, 'gemini-2.5-pro'), isNotNull);
      expect(findModelEntry(list, 'nope'), isNull);
    });
  });

  group('knownModelContext', () {
    test('well-known families', () {
      expect(knownModelContext('gpt-4.1-mini'), 1047576);
      expect(knownModelContext('gpt-4o-2024-08-06'), 128000);
      expect(knownModelContext('o3-mini'), 200000);
      expect(knownModelContext('claude-3-5-sonnet'), 200000);
      expect(knownModelContext('gemini-1.5-pro-latest'), 2097152);
      expect(knownModelContext('gemini-2.5-flash'), 1048576);
      expect(knownModelContext('deepseek-chat'), 128000);
      expect(knownModelContext('meta-llama/llama-3.1-8b-instruct'), 131072);
    });
    test('unknown models return null', () {
      expect(knownModelContext('my-custom-finetune'), isNull);
    });
  });
}
