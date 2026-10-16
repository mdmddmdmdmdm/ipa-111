import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../converters/prompt_post_processing.dart';
import 'chat_transport.dart';
import 'chat_transport_request.dart';
import 'native_reasoning_support.dart';

/// [ChatTransport] decorator that applies the connection's SillyTavern-style
/// prompt post-processing before the protocol converter ever sees the prompt.
///
/// It sits at the very outside of the transport chain — outside the request
/// dump — so the diagnostics file records exactly the conversation that goes
/// on the wire, and so provider-specific rewrites that happen *inside* a
/// transport (OpenRouter's cache markers, Anthropic's `system` lift) operate
/// on the final message list rather than being flattened by a later merge.
///
/// [ChatTransportRequest.previousMessages] is processed with the same mode.
/// It is a previous request's conversation, used to hash a stable cache
/// prefix; leaving it unprocessed would compare a merged prompt against an
/// unmerged one and invalidate every breakpoint.
class PostProcessingChatTransport implements ChatTransport {
  PostProcessingChatTransport(this._inner);

  final ChatTransport _inner;

  /// The wrapped transport. Exposed so tests can assert factory routing.
  @visibleForTesting
  ChatTransport get inner => _inner;

  /// Connections (endpoint + model) that answered with a chat-template role
  /// error, and the layout level that finally worked or was last tried:
  /// 1 = strict, 2 = single. From then on they start at that level, so only the
  /// first message after a failure pays for the extra round trips.
  static final Map<String, int> _learnedLevel = <String, int>{};

  static String _key(ChatTransportRequest r) => '${r.endpoint}|${r.model}';

  /// True for the 400s some self-hosted and routed models return when their
  /// chat template insists on strict user/assistant alternation, e.g.
  /// "After the optional system message, conversation roles must alternate".
  @visibleForTesting
  static bool isRoleTemplateError(Object error) {
    final text = error.toString().toLowerCase();
    if (!text.contains('400') && !text.contains('bad request')) return false;
    return text.contains('roles must alternate') ||
        text.contains('must alternate') ||
        text.contains('after the optional system message') ||
        text.contains('system message must be at the beginning') ||
        text.contains('unable to generate parser for this template') ||
        text.contains('raise_exception') ||
        (text.contains('jinja') && text.contains('role'));
  }

  /// 0 = the mode as configured, 1 = strict, 2 = single (one user message).
  static int _levelOf(String mode) {
    if (mode == PromptPostProcessing.single) return 2;
    if (PromptPostProcessing.baseOf(mode) == PromptPostProcessing.strict) {
      return 1;
    }
    return 0;
  }

  static String _modeAtLevel(String configured, int level) => switch (level) {
    >= 2 => PromptPostProcessing.single,
    1 =>
      _levelOf(configured) >= 1 ? configured : PromptPostProcessing.strict,
    _ => configured,
  };

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) {
    // A model that already refused native reasoning is not asked again.
    if (request.requestReasoning &&
        !request.omitReasoning &&
        NativeReasoningSupport.isUnsupported(request.endpoint, request.model)) {
      request = withoutNativeReasoning(request);
    }
    final configured = PromptPostProcessing.normalize(
      request.promptPostProcessing,
    );
    final startLevel = _levelOf(configured) > (_learnedLevel[_key(request)] ?? 0)
        ? _levelOf(configured)
        : (_learnedLevel[_key(request)] ?? 0);
    return _run(
      request: request,
      configured: configured,
      level: startLevel,
      cancelToken: cancelToken,
      onUpdate: onUpdate,
      onComplete: onComplete,
      onError: onError,
    );
  }

  Future<void> _run({
    required ChatTransportRequest request,
    required String configured,
    required int level,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) {
    final mode = _modeAtLevel(configured, level);
    final attempt = mode == configured
        ? applyTo(request)
        : applyTo(_withMode(request, mode));

    var gotOutput = false;
    return _inner.stream(
      request: attempt,
      cancelToken: cancelToken,
      onUpdate: (delta, reasoning) {
        if (delta.isNotEmpty || (reasoning?.isNotEmpty ?? false)) {
          gotOutput = true;
        }
        onUpdate?.call(delta, reasoning);
      },
      onComplete: onComplete,
      onError: (error) {
        // "<model> does not support thinking": ask again without native
        // reasoning and remember it for this model.
        if (request.requestReasoning &&
            !request.omitReasoning &&
            !gotOutput &&
            !(cancelToken?.isCancelled ?? false) &&
            NativeReasoningSupport.isRefusal(error)) {
          NativeReasoningSupport.markUnsupported(request.endpoint, request.model);
          debugPrint(
            '[Reasoning] ${request.model} refused native reasoning; '
            'retrying without it',
          );
          _run(
            request: withoutNativeReasoning(request),
            configured: configured,
            level: level,
            cancelToken: cancelToken,
            onUpdate: onUpdate,
            onComplete: onComplete,
            onError: onError,
          );
          return;
        }
        if (level < 2 &&
            !gotOutput &&
            !(cancelToken?.isCancelled ?? false) &&
            isRoleTemplateError(error)) {
          final nextLevel = level + 1;
          // Level 1 is only worth trying if it differs from what just failed.
          final effectiveNext =
              (nextLevel == 1 && _levelOf(configured) >= 1) ? 2 : nextLevel;
          _learnedLevel[_key(request)] = effectiveNext;
          debugPrint(
            '[PostProcessing] role-template 400 from ${request.model}; '
            'retrying with ${effectiveNext == 2 ? 'single' : 'strict'} '
            'post-processing',
          );
          _run(
            request: request,
            configured: configured,
            level: effectiveNext,
            cancelToken: cancelToken,
            onUpdate: onUpdate,
            onComplete: onComplete,
            onError: onError,
          );
          return;
        }
        onError?.call(error);
      },
    );
  }

  /// The same request with a different post-processing mode.
  static ChatTransportRequest _withMode(
    ChatTransportRequest request,
    String mode,
  ) => request.withMessages(
    request.messages,
    previousMessages: request.previousMessages,
    promptPostProcessing: mode,
  );

  /// Pure: the request a transport should actually execute. Exposed so the
  /// prompt preview can show the same body without going through a transport.
  static ChatTransportRequest applyTo(ChatTransportRequest request) {
    final mode = PromptPostProcessing.normalize(request.promptPostProcessing);
    if (mode == PromptPostProcessing.none) return request;
    return request.withMessages(
      postProcessPrompt(
        request.messages,
        mode,
        charName: request.charName,
        userName: request.userName,
      ),
      previousMessages: request.previousMessages == null
          ? null
          : postProcessPrompt(
              request.previousMessages!,
              mode,
              charName: request.charName,
              userName: request.userName,
            ),
    );
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) => _inner.fetchModels(endpoint: endpoint, apiKey: apiKey);
}
