import 'chat_transport_request.dart';

/// Remembers which connection + model pairs refused a native reasoning
/// request, for the rest of the session.
///
/// Used by [PostProcessingChatTransport]: a request is sent without native
/// reasoning when its model is known to refuse it, and the first refusal is
/// retried once without it.
///
/// Ollama answers a request that carries `reasoning_effort` with
/// `HTTP 400 "<model>" does not support thinking` when the model's registry
/// entry does not declare the thinking capability. That is common for
/// finetunes that are named "Reasoner" and do write their reasoning, but in
/// the reply text (inside `<think>` tags) rather than through Ollama's
/// reasoning channel. Such a model works fine; it just must not be asked for
/// native reasoning.
class NativeReasoningSupport {
  const NativeReasoningSupport._();

  static final Set<String> _unsupported = <String>{};

  static String keyOf(String endpoint, String model) => '$endpoint|$model';

  static bool isUnsupported(String endpoint, String model) =>
      _unsupported.contains(keyOf(endpoint, model));

  static void markUnsupported(String endpoint, String model) =>
      _unsupported.add(keyOf(endpoint, model));

  static void forget(String endpoint, String model) =>
      _unsupported.remove(keyOf(endpoint, model));

  /// True for the server's "this model cannot think" refusal.
  static bool isRefusal(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('does not support thinking') ||
        text.contains('does not support think') ||
        text.contains('thinking is not supported') ||
        text.contains('does not support reasoning');
  }
}

/// The same request with native reasoning switched off (the reasoning the model
/// writes inline in `<think>` tags is still parsed from the reply).
ChatTransportRequest withoutNativeReasoning(ChatTransportRequest r) =>
    r.withMessages(
      r.messages,
      previousMessages: r.previousMessages,
      promptPostProcessing: r.promptPostProcessing,
      requestReasoning: false,
      omitReasoningEffort: true,
    );
