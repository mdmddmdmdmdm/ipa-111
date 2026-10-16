import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/llm/prompt/lorebook_vector_searcher.dart';
import '../../../core/llm/transport/native_reasoning_support.dart';
import '../../../core/llm/prompt_builder.dart';
import '../../../core/llm/prompt_inputs_collector.dart';
import '../../../core/llm/prompt_payload_builder.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/chat_message.dart';
import '../../extensions/services/ext_blocks_prompt_injection.dart';
import '../../extensions/services/runtime_prompt_injection_service.dart';
import '../../settings/api_list_provider.dart';
import '../../settings/prompt_helpers_provider.dart';

List<RuntimePromptBlock> mapRuntimePromptBlocks(
  Iterable<RuntimePromptInjection> blocks,
) => List.unmodifiable(
  blocks.map(
    (block) => RuntimePromptBlock(
      id: block.id,
      content: block.content,
      depth: block.depth,
      role: block.role,
    ),
  ),
);

/// Sessions whose prompt is being built for an impersonation run right now.
/// While a session is in here its Prompt Helpers drop the rules that forbid
/// writing the user (see [PromptHelpers.forImpersonation]).
final impersonationPromptSessionsProvider = StateProvider<Set<String>>(
  (ref) => const <String>{},
);

List<RuntimePromptBlock> _promptHelperBlocks(Ref ref, String sessionId) {
  final helpers = ref.read(promptHelpersProvider);
  final impersonating = ref
      .read(impersonationPromptSessionsProvider)
      .contains(sessionId);
  final config = ref.read(activeApiConfigProvider);
  return (impersonating ? helpers.forImpersonation() : helpers)
      .toRuntimeBlocks(
        reasoningEffort: config?.reasoningEffort,
        nativeReasoning: _nativeReasoningOn(config),
      );
}

final promptInputsCollectorProvider = Provider<PromptInputsCollector>((ref) {
  return PromptInputsCollector(
    ref,
    initializeApiConfigs: () async {
      await ref.read(apiListProvider.future);
      await ref.read(promptHelpersProvider.notifier).ensureLoaded();
    },
    readActiveApiConfig: () => ref.read(activeApiConfigProvider),
    injectHistory: ({required sessionId, required messages}) => ref
        .read(extBlocksPromptInjectionProvider)
        .injectIntoHistory(sessionId: sessionId, messages: messages),
    readRuntimePromptBlocks: (sessionId) => [
      ...mapRuntimePromptBlocks(
        ref.read(runtimePromptInjectionProvider.notifier).bySession(sessionId),
      ),
      ..._promptHelperBlocks(ref, sessionId),
    ],
  );
});

final promptPayloadBuilderProvider = Provider<PromptPayloadBuilder>((ref) {
  Future<void> initializeApiConfigs() async {
    await ref.read(apiListProvider.future);
    await ref.read(promptHelpersProvider.notifier).ensureLoaded();
  }

  Future<List<ChatMessage>> injectHistory({
    required String sessionId,
    required List<ChatMessage> messages,
  }) => ref
      .read(extBlocksPromptInjectionProvider)
      .injectIntoHistory(sessionId: sessionId, messages: messages);
  List<RuntimePromptBlock> readRuntimePromptBlocks(String sessionId) => [
    ...mapRuntimePromptBlocks(
      ref.read(runtimePromptInjectionProvider.notifier).bySession(sessionId),
    ),
    ..._promptHelperBlocks(ref, sessionId),
  ];

  return PromptPayloadBuilder(
    ref,
    inputsCollector: ref.watch(promptInputsCollectorProvider),
    initializeApiConfigs: initializeApiConfigs,
    readActiveApiConfig: () => ref.read(activeApiConfigProvider),
    injectHistory: injectHistory,
    readRuntimePromptBlocks: readRuntimePromptBlocks,
    onLorebookVectorSearchDiagnostic: (diagnostic) {
      ref.read(lorebookVectorSearchDiagnosticProvider.notifier).state =
          diagnostic;
    },
  );
});

final lorebookVectorSearchDiagnosticProvider =
    StateProvider<LorebookVectorSearchDiagnostic?>((ref) => null);

/// Whether the connection asks the model for its own (native) reasoning.
bool _nativeReasoningOn(ApiConfig? c) =>
    c != null &&
    c.requestReasoning &&
    !c.omitReasoning &&
    // A model the server refused native reasoning for is treated as having
    // none, so Think First can take its place.
    !NativeReasoningSupport.isUnsupported(c.endpoint, c.model);
