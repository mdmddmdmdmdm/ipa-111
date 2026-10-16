import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/llm/aux_llm_client.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/persona_resolution.dart';
import '../../../core/state/shared_prefs_provider.dart';
import '../../../core/state/summary_providers.dart';
import '../../settings/api_list_provider.dart';

const _kAutoKey = 'replySuggestions.auto';
const _kApiKey = 'replySuggestions.apiConfigId';

/// Global settings of the message-ideas button: whether the ideas pop up by
/// themselves after each reply, and which saved connection writes them (an
/// empty id means the chat's own model).
class ReplySuggestionSettings {
  final bool auto;
  final String apiConfigId;

  const ReplySuggestionSettings({this.auto = false, this.apiConfigId = ''});

  ReplySuggestionSettings copyWith({bool? auto, String? apiConfigId}) =>
      ReplySuggestionSettings(
        auto: auto ?? this.auto,
        apiConfigId: apiConfigId ?? this.apiConfigId,
      );
}

class ReplySuggestionSettingsNotifier
    extends StateNotifier<ReplySuggestionSettings> {
  ReplySuggestionSettingsNotifier(this._ref)
    : super(const ReplySuggestionSettings()) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    try {
      final prefs = await _ref.read(sharedPreferencesProvider.future);
      state = ReplySuggestionSettings(
        auto: prefs.getBool(_kAutoKey) ?? false,
        apiConfigId: prefs.getString(_kApiKey) ?? '',
      );
    } catch (_) {}
  }

  Future<void> setAuto(bool value) async {
    state = state.copyWith(auto: value);
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(_kAutoKey, value);
  }

  Future<void> setApiConfigId(String id) async {
    state = state.copyWith(apiConfigId: id);
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setString(_kApiKey, id);
  }
}

final replySuggestionSettingsProvider =
    StateNotifierProvider<ReplySuggestionSettingsNotifier,
        ReplySuggestionSettings>(
      (ref) => ReplySuggestionSettingsNotifier(ref),
    );

/// Writes three possible next messages for the user.
class ReplySuggestionService {
  ReplySuggestionService(this._ref, {AuxLlmClient llm = const AuxLlmClient()})
    : _llm = llm;

  final Ref _ref;
  final AuxLlmClient _llm;

  /// How many of the newest messages the model gets to read.
  static const int _historyMessages = 14;

  Future<ApiConfig> _resolveConfig() async {
    await _ref.read(apiListProvider.future);
    final list = _ref.read(apiListProvider).value ?? const <ApiConfig>[];
    final id = _ref.read(replySuggestionSettingsProvider).apiConfigId;
    ApiConfig? config;
    if (id.isNotEmpty) {
      for (final c in list) {
        if (c.id == id) config = c;
      }
    }
    config ??= _ref.read(activeApiConfigProvider);
    if (config == null) {
      throw Exception('No chat API config found. Add one in API Settings.');
    }
    return config;
  }

  Future<List<String>> suggest({
    required String charId,
    required ChatSession session,
    int count = 3,
  }) async {
    final config = await _resolveConfig();
    if (config.model.trim().isEmpty) {
      throw Exception('The connection "${config.name}" has no model picked.');
    }
    final character = _ref.read(characterByIdProvider(charId));
    final persona = _ref.read(
      effectivePersonaForChatProvider((charId: charId, sessionId: session.id)),
    );
    final charName = character?.name ?? 'Character';
    final userName = persona?.name ?? 'User';

    final visible = [
      for (final m in session.messages)
        if (!m.isHidden &&
            !m.isTyping &&
            (m.role == 'user' || m.role == 'assistant') &&
            m.content.trim().isNotEmpty)
          m,
    ];
    if (visible.isEmpty) {
      throw Exception('There is nothing to reply to yet.');
    }
    final recent = visible.length > _historyMessages
        ? visible.sublist(visible.length - _historyMessages)
        : visible;
    final transcript = StringBuffer();
    for (final m in recent) {
      final who = m.role == 'user' ? userName : charName;
      transcript.writeln('$who: ${_clip(_stripThink(m.content), 900)}');
    }

    String? summary;
    try {
      summary = await _ref.read(summaryServiceProvider).getSummary(session.id);
    } catch (_) {}

    final prompt = StringBuffer()
      ..writeln(
        'You are helping $userName write their next message in a roleplay '
        'chat with $charName.',
      );
    final desc = (character?.description ?? '').trim();
    if (desc.isNotEmpty) {
      prompt.writeln('\nAbout $charName:\n${_clip(desc, 1200)}');
    }
    final persona0 = (persona?.prompt ?? '').trim();
    if (persona0.isNotEmpty) {
      prompt.writeln('\nAbout $userName:\n${_clip(persona0, 600)}');
    }
    if (summary != null && summary.trim().isNotEmpty) {
      prompt.writeln('\nSummary of earlier events:\n${_clip(summary, 1500)}');
    }
    prompt
      ..writeln('\nThe latest part of the conversation:\n')
      ..writeln(transcript)
      ..writeln(
        'Write exactly $count different messages that $userName could send '
        'next. Rules: write as $userName in first person, never as $charName; '
        'each one is 1-3 sentences and makes sense as a direct continuation '
        'of the last message; match the style of $userName\'s earlier messages '
        '(use *asterisks* for actions only if the chat does); make the '
        '$count options go in different directions (for example one warm, '
        'one playful or curious, one that moves the story forward). Do not '
        'repeat what was already said. Answer with ONLY a JSON array of '
        '$count strings and nothing else.',
      );

    final text = await _llm.callOnce(
      config: AuxApiConfig(
        endpoint: config.endpoint,
        apiKey: config.apiKey,
        model: config.model,
        protocol: config.protocol,
        useResponsesApi: config.useResponsesApi,
        omitTemperature: config.omitTemperature,
        extraRequestParameters: config.extraRequestParameters,
      ),
      prompt: prompt.toString(),
      maxTokens: config.maxTokens > 1200 ? config.maxTokens : 1200,
      temperature: 0.9,
      timeoutMs: config.firstChunkTimeoutMs > 180000
          ? config.firstChunkTimeoutMs
          : 180000,
    );
    final parsed = parse(text, count: count);
    if (parsed.isEmpty) {
      throw Exception('The model did not return any usable ideas.');
    }
    return parsed;
  }

  /// Pulls up to [count] messages out of a model answer: a JSON array when the
  /// model followed the format, otherwise numbered / bulleted lines.
  static List<String> parse(String raw, {int count = 3}) {
    final cleaned = _stripThink(raw)
        .replaceAll(RegExp(r'```[a-zA-Z]*'), '')
        .replaceAll('```', '')
        .trim();
    final out = <String>[];

    final start = cleaned.indexOf('[');
    final end = cleaned.lastIndexOf(']');
    if (start >= 0 && end > start) {
      try {
        final decoded = jsonDecode(cleaned.substring(start, end + 1));
        if (decoded is List) {
          for (final item in decoded) {
            final s = item is String
                ? item
                : (item is Map
                      ? (item['message'] ?? item['text'] ?? '').toString()
                      : '');
            if (s.trim().isNotEmpty) out.add(s.trim());
          }
        }
      } catch (_) {}
    }
    if (out.isEmpty) {
      for (final line in cleaned.split('\n')) {
        var t = line.trim();
        t = t.replaceFirst(RegExp(r'^(?:\d+[.)]|[-*\u2022])\s+'), '');
        t = t.replaceAll(RegExp(r'^["\u201C]|["\u201D],?$'), '').trim();
        if (t.length >= 3 && t != '[' && t != ']') out.add(t);
      }
    }
    return out.take(count).toList();
  }

  static String _stripThink(String s) => s
      .replaceAll(RegExp(r'<think(ing)?>[\s\S]*?</think(ing)?>'), '')
      .trim();

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}...';
}

final replySuggestionServiceProvider = Provider<ReplySuggestionService>(
  (ref) => ReplySuggestionService(ref),
);
