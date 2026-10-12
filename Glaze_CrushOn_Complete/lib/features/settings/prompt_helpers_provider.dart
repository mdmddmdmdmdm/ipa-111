import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/llm/prompt_helpers.dart';

/// The prompt helpers switched on in the app. One shared value: the API
/// settings group and the chat Tools "Prompt Helpers" panel both read and
/// write it, so changing one changes the other.
class PromptHelpersNotifier extends Notifier<PromptHelpers> {
  static const _prefKey = 'gz_prompt_helpers_v1';

  Future<void>? _loading;

  @override
  PromptHelpers build() {
    _loading = _load();
    return const PromptHelpers();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw);
      if (data is Map) {
        state = PromptHelpers.fromJson(Map<String, dynamic>.from(data));
      }
    } catch (_) {}
  }

  /// Completes once the saved choice has been read. Prompt building awaits it,
  /// so the very first message after launch already sees the saved helpers.
  Future<void> ensureLoaded() => _loading ?? Future<void>.value();

  Future<void> _set(PromptHelpers next) async {
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(next.toJson()));
    } catch (_) {}
  }

  Future<void> setFormatting(bool value) =>
      _set(state.copyWith(formatting: value));

  Future<void> setUserAgency(bool value) =>
      _set(state.copyWith(userAgency: value));

  Future<void> setUserNameAccuracy(bool value) =>
      _set(state.copyWith(userNameAccuracy: value));

  /// Short, medium and long exclude each other: turning one on turns the
  /// others off, and turning the active one off sends no length at all.
  Future<void> setLength(PromptResponseLength value) =>
      _set(state.copyWith(length: value));
}

final promptHelpersProvider =
    NotifierProvider<PromptHelpersNotifier, PromptHelpers>(
      PromptHelpersNotifier.new,
    );
