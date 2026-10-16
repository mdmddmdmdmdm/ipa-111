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

  /// Set once the user changes a helper. A saved value that finishes loading
  /// afterwards must not overwrite that change.
  bool _changed = false;

  @override
  PromptHelpers build() {
    _loading = _load();
    return const PromptHelpers();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (_changed || raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw);
      if (data is Map && !_changed) {
        state = PromptHelpers.fromJson(Map<String, dynamic>.from(data));
      }
    } catch (_) {}
  }

  /// Completes once the saved choice has been read. Prompt building awaits it,
  /// so the very first message after launch already sees the saved helpers.
  Future<void> ensureLoaded() => _loading ?? Future<void>.value();

  Future<void> _set(PromptHelpers next) async {
    _changed = true;
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

  Future<void> setStayInRole(bool value) =>
      _set(state.copyWith(stayInRole: value));

  Future<void> setStayOnStory(bool value) =>
      _set(state.copyWith(stayOnStory: value));

  Future<void> setLimitedKnowledge(bool value) =>
      _set(state.copyWith(limitedKnowledge: value));

  Future<void> setThinkFirst(bool value) =>
      _set(state.copyWith(thinkFirst: value));

  Future<void> setEmojis(bool value) => _set(state.copyWith(emojis: value));

  /// Short, medium and long exclude each other: turning one on turns the
  /// others off, and turning the active one off sends no length at all.
  Future<void> setLength(PromptResponseLength value) =>
      _set(state.copyWith(length: value));
}

final promptHelpersProvider =
    NotifierProvider<PromptHelpersNotifier, PromptHelpers>(
      PromptHelpersNotifier.new,
    );
