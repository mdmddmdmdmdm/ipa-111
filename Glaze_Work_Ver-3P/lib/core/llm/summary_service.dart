import 'package:dio/dio.dart';

import '../db/repositories/summary_repo.dart';
import '../models/api_config.dart';
import '../models/chat_message.dart';
import 'auxiliary_timed_history.dart';
import 'aux_llm_client.dart';
import 'macro_engine.dart';
import 'tokenizer.dart';
import 'transport/llm_protocol.dart';
import 'transport/llm_capture_context.dart';

/// Prompt used when a session has no custom summarization prompt. Exposed so
/// the editor can show it as the placeholder for an empty field.
const defaultSummaryPrompt =
    'Summarize the following roleplay conversation concisely, focusing on the current situation and key events:\n\n';

/// Placeholder replaced with the formatted transcript. Substituted *after*
/// macro expansion so nothing inside the transcript is treated as a macro.
const summaryHistoryPlaceholder = '{{history}}';

/// Placeholder replaced with the summary that is being replaced. A template
/// that uses it decides where the previous summary goes; one that does not
/// gets the block below in front of the transcript.
const summaryPreviousPlaceholder = '{{previous_summary}}';

/// Heading the previous summary is handed over under when the template does
/// not place it itself. It is an instruction as much as a label: without it a
/// model reads the block as part of the transcript and summarizes the summary.
const summaryPreviousHeader =
    'Previous summary of this conversation. Build on it: carry its facts '
    'forward, correct what the transcript below contradicts, and add what is '
    'new. Do not drop established facts just because the transcript no longer '
    'mentions them.';

/// Fallback generation budget when the API config carries no `maxTokens`.
const _fallbackMaxTokens = 1024;

/// Fallback idle timeout when the API config carries no `firstChunkTimeoutMs`.
const _fallbackTimeoutMs = 60000;

/// A summary is one non-streaming call, so this is a hard limit on the whole
/// reply. A local model has to load, read the transcript and write the summary
/// before anything comes back; the chat's first-chunk timeout (60 s by default)
/// is far too short for that.
const _minSummaryTimeoutMs = 240000;

/// Temperature a summary runs at unless the connection's slot pins one.
/// Summarizing is extraction, not prose — a hot summariser invents facts.
const kSummaryDefaultTemperature = 0.3;

class SummaryService {
  final SummaryRepo _repo;
  final AuxLlmClient _llm;

  SummaryService(this._repo, {AuxLlmClient? llm})
    : _llm = llm ?? const AuxLlmClient();

  Future<String?> getSummary(String sessionId) async {
    final row = await _repo.get(sessionId);
    if (row == null || !row.enabled) return null;
    return row.content;
  }

  Future<String?> getSummaryContent(String sessionId) async {
    final row = await _repo.get(sessionId);
    return row?.content;
  }

  Future<bool> isSummaryEnabled(String sessionId) async {
    final row = await _repo.get(sessionId);
    return row?.enabled ?? true;
  }

  /// Writes only the summarization template. See [SummaryRepo.setPrompt] for
  /// why this is not [setSummary] with the same content.
  Future<void> setSummaryPrompt({
    required String sessionId,
    required String? prompt,
  }) {
    final trimmed = prompt?.trim();
    return _repo.setPrompt(
      sessionId: sessionId,
      prompt: trimmed == null || trimmed.isEmpty ? null : prompt,
    );
  }

  /// Session's custom summarization prompt, or null when it uses the built-in
  /// [defaultSummaryPrompt]. A blank stored value counts as unset.
  Future<String?> getSummaryPrompt(String sessionId) async {
    final prompt = (await _repo.get(sessionId))?.prompt;
    if (prompt == null || prompt.trim().isEmpty) return null;
    return prompt;
  }

  /// Persists a manually-edited summary. Empty content clears it. This is the
  /// same store the prompt builder reads ([getSummary]), so manual edits are
  /// injected exactly like generated ones.
  ///
  /// [prompt] is the session's summarization template; pass an empty string to
  /// fall back to [defaultSummaryPrompt], or null to leave it untouched.
  Future<void> setSummary({
    required String sessionId,
    required String content,
    required int messageCount,
    String? prompt,
  }) async {
    final trimmed = content.trim();
    await _repo.put(
      sessionId: sessionId,
      content: trimmed,
      messageCount: messageCount,
      prompt: prompt,
    );
  }

  Future<void> setSummaryEnabled({
    required String sessionId,
    required bool enabled,
  }) {
    return _repo.setEnabled(sessionId: sessionId, enabled: enabled);
  }

  Future<int> getSummaryMessageCount(String sessionId) async {
    final row = await _repo.get(sessionId);
    return row?.messageCount ?? 0;
  }

  /// Generates a summary for [history] through [apiConfig] and persists it.
  ///
  /// The call goes through [AuxLlmClient] so every protocol the app supports
  /// works here: URL shape, auth header, request body and response parsing all
  /// come from the protocol's `ChatTransport`. This used to be a hand-rolled
  /// OpenAI Chat Completions POST, which silently failed on Anthropic, Gemini
  /// and OpenRouter configs.
  ///
  /// Non-streaming (INV-S1): the transport is called with `stream: false`.
  ///
  /// [customPrompt] is persisted verbatim (as a template); [macroContext]
  /// only affects what is sent to the model.
  Future<String> generateSummary({
    required String sessionId,
    required List<ChatMessage> history,
    required ApiConfig apiConfig,
    String? customPrompt,
    MacroContext? macroContext,
    CancelToken? cancelToken,

    /// Pins the sampling temperature. Null keeps
    /// [kSummaryDefaultTemperature].
    double? temperature,
  }) async {
    // OpenRouter's transport hardcodes its base URL and ignores the config's
    // endpoint, so an empty endpoint is legitimate there.
    final endpointRequired = apiConfig.protocol != LlmProtocol.openrouter;
    if (endpointRequired && apiConfig.endpoint.isEmpty) {
      throw Exception('API endpoint not configured');
    }
    if (apiConfig.model.isEmpty) {
      throw Exception('API model not configured');
    }

    // The summary this run replaces goes into the prompt. Without it every
    // run re-derived the whole chat from the transcript alone, so anything the
    // previous summary had distilled out of messages that have since scrolled
    // past — or that the model happened to weigh differently this time — was
    // quietly dropped. Read before the write below, which overwrites it.
    final previous = await getSummaryContent(sessionId);

    // Keep the request inside the model's context. A server that gets more
    // than it can hold cuts the START of the prompt - the instructions - and
    // the model then answers with something unrelated or nothing at all. The
    // newest messages are kept; what came before lives on in the previous
    // summary, which is part of the prompt.
    final fitted = _fitHistory(
      history: history,
      apiConfig: apiConfig,
      reservedText: '${customPrompt ?? defaultSummaryPrompt}\n${previous ?? ''}',
    );

    final prompt = buildSummaryPrompt(
      history: fitted,
      template: customPrompt,
      macroContext: macroContext,
      previousSummary: previous,
    );

    final content = await _llm.callOnce(
      config: AuxApiConfig(
        endpoint: apiConfig.endpoint,
        apiKey: apiConfig.apiKey,
        model: apiConfig.model,
        protocol: apiConfig.protocol,
        useResponsesApi: apiConfig.useResponsesApi,
        // The connection's own "no temperature" flag travels with it: the
        // summary pins temperature 0.3, but a provider that rejects the
        // parameter rejects it here too.
        omitTemperature: apiConfig.omitTemperature,
        extraRequestParameters: apiConfig.extraRequestParameters,
      ),
      prompt: prompt,
      maxTokens: apiConfig.maxTokens > 0
          ? apiConfig.maxTokens
          : _fallbackMaxTokens,
      temperature: temperature ?? kSummaryDefaultTemperature,
      timeoutMs: _summaryTimeoutMs(apiConfig.firstChunkTimeoutMs),
      cancelToken: cancelToken,
      captureContext: LlmCaptureContext(
        stage: 'summary',
        sessionId: sessionId,
        logicalCallId: 'summary:$sessionId',
        relatedArtifactId: sessionId,
      ),
    );

    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      // Saving this would wipe the summary the chat already has and show an
      // empty box. Typical causes: a thinking model spent the whole output
      // budget on reasoning, or the prompt did not fit the model's context.
      throw Exception(
        'The model returned an empty summary, so the existing one was kept. '
        'If it is a thinking model, raise Max Response tokens or turn its '
        'reasoning off; also check that the model context is large enough.',
      );
    }
    await _repo.put(
      sessionId: sessionId,
      content: trimmed,
      messageCount: history.length,
      prompt: customPrompt,
    );

    return trimmed;
  }

  static int _summaryTimeoutMs(int configured) {
    final base = configured > 0 ? configured : _fallbackTimeoutMs;
    return base < _minSummaryTimeoutMs ? _minSummaryTimeoutMs : base;
  }

  /// The newest tail of [history] that fits the connection's context together
  /// with the instructions, the previous summary and the reply budget.
  List<ChatMessage> _fitHistory({
    required List<ChatMessage> history,
    required ApiConfig apiConfig,
    required String reservedText,
  }) {
    final context = apiConfig.contextSize;
    if (context <= 0) return history;
    final reply = apiConfig.maxTokens > 0
        ? apiConfig.maxTokens
        : _fallbackMaxTokens;
    // Leave a margin: the token estimate is approximate.
    var budget =
        (context * 0.85).floor() - reply - estimateTokens(reservedText) - 200;
    if (budget < 1000) budget = 1000;

    final kept = <ChatMessage>[];
    var used = 0;
    for (var i = history.length - 1; i >= 0; i--) {
      final message = history[i];
      if (message.role != 'user' && message.role != 'assistant') {
        continue;
      }
      final cost = estimateTokens(auxiliaryTimedContent(message)) + 4;
      if (used + cost > budget && kept.isNotEmpty) break;
      used += cost;
      kept.add(message);
    }
    return kept.reversed.toList();
  }

  /// Builds the summarization prompt.
  ///
  /// Order matters: macros in [template] are expanded first (so `{{char}}`,
  /// `{{user}}`, `{{getvar::…}}` and friends work in a user-written prompt),
  /// and only then is `{{history}}` swapped for the transcript. Doing it the
  /// other way round would run the macro engine over the chat log itself and
  /// rewrite whatever `{{…}}` the roleplay happens to contain.
  ///
  /// A template without `{{history}}` gets the transcript appended, which is
  /// how the built-in prompt works.
  ///
  /// [previousSummary] is the summary this run replaces. A template places it
  /// itself with `{{previous_summary}}`; otherwise it is handed over under
  /// [summaryPreviousHeader] between the instructions and the transcript. An
  /// empty or absent one changes nothing about the prompt.
  String buildSummaryPrompt({
    required List<ChatMessage> history,
    String? template,
    MacroContext? macroContext,
    String? previousSummary,
  }) {
    var resolved = (template == null || template.trim().isEmpty)
        ? defaultSummaryPrompt
        : template;
    if (macroContext != null) {
      resolved = replaceMacros(resolved, macroContext).text;
    }
    final previous = previousSummary?.trim() ?? '';
    final placed = resolved.contains(summaryPreviousPlaceholder);
    if (placed) {
      resolved = resolved.replaceAll(summaryPreviousPlaceholder, previous);
    } else if (previous.isNotEmpty) {
      resolved = '$resolved\n\n$summaryPreviousHeader\n$previous';
    }
    final historyText = _formatHistory(history);
    if (resolved.contains(summaryHistoryPlaceholder)) {
      return resolved.replaceAll(summaryHistoryPlaceholder, historyText);
    }
    return '$resolved\n\n$historyText';
  }

  Future<void> deleteSummary(String sessionId) async {
    await _repo.deleteBySessionId(sessionId);
  }

  bool needsRegeneration(int currentMessageCount, int? savedCount) {
    if (savedCount == null || savedCount == 0) return true;
    final threshold = (savedCount * 0.3).ceil();
    return currentMessageCount - savedCount >= threshold &&
        currentMessageCount > 10;
  }

  String _formatHistory(List<ChatMessage> messages) {
    final buf = StringBuffer();
    for (final msg in messages) {
      if (msg.role == 'user' || msg.role == 'assistant') {
        final speaker = msg.role == 'user' ? 'User' : 'Character';
        // The ledger-stamped game clock travels with the transcript so the
        // summary stays time-anchored instead of teleporting across hours.
        buf.writeln('$speaker: ${auxiliaryTimedContent(msg)}');
      }
    }
    return buf.toString();
  }
}
