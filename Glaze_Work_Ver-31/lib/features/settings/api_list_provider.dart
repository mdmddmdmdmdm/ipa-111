import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/llm/transport/llm_protocol.dart';
import '../../core/models/api_config.dart';
import '../../core/llm/embedding_request_gate.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/shared_prefs_provider.dart';
import '../../core/utils/sync_deletion_tracker.dart';

/// SharedPreferences key holding the embedding preset the vector side runs on.
const kActiveEmbeddingConfigIdKey = 'activeEmbeddingConfigId';

/// SharedPreferences flag marking that the per-chat-preset embedding settings
/// have been carried over into embedding presets of their own. See
/// [EmbeddingPresetListNotifier.build].
const kEmbeddingPresetsSeededKey = 'embeddingPresetsSeeded';

/// `ApiConfig.mode` of a preset that belongs to the Embeddings tab. Chat and
/// embedding presets share one table but never the same list: the LLM tab,
/// Studio slots and every model picker read [apiListProvider], which excludes
/// this mode, while the Embeddings tab reads [embeddingPresetListProvider].
const kEmbeddingPresetMode = 'embedding';

/// SharedPreferences flag: the built-in API presets below were offered once.
const kDefaultApiPresetsSeededKey = 'defaultApiPresetsSeeded_v1';

/// SharedPreferences flag: the built-in presets already created on this device
/// were upgraded once to the local-server settings below.
const kDefaultApiPresetsTunedKey = 'defaultApiPresetsTuned_v1';

/// Settings every built-in (local Ollama) preset starts with. The models behind
/// them (Mistral / Gemma / Llama based roleplay finetunes) ship chat templates
/// that reject a prompt with system messages in the middle or two same-role
/// messages in a row ("roles must alternate"), so the prompt is sent in the
/// strict layout. A cold model load or a long prompt can take minutes before
/// the first token, and a sliding history window changes the prompt start every
/// turn, which defeats the server's prompt cache.
const kDefaultApiPresetPostProcessing = 'strict';
const kDefaultApiPresetFirstChunkTimeoutMs = 240000;
const kDefaultApiPresetHistoryTrimMode = 'stepped';

/// The local-server endpoint every built-in preset points at (an
/// OpenAI-compatible server such as Ollama on the home network).
const kDefaultApiPresetEndpoint = 'http://192.168.1.59:11434/v1';

/// Names of the built-in API presets, in list order. Each one uses the local
/// endpoint above; the model name is picked per preset with "Fetch models".
const kDefaultApiPresetNames = <String>[
  'Mag mell',
  'Rocia XL',
  'the drum Cydonia',
  'darkest planet',
  'Gemma unc',
  'grand horror',
  'magnum v4',
  'Rp max Arli',
];

final activeApiPresetIdProvider = StateProvider<String?>((ref) => null);

/// The embedding preset the vector side runs on — picked on the API screen's
/// Embeddings tab and stored apart from [activeApiPresetIdProvider].
///
/// Embeddings are a connection of their own: switching the chat preset must
/// never drag the vector index onto another endpoint, because every stored
/// vector is tied to the model that produced it. The single remaining link
/// between the two is the embedding preset's "Use LLM API" toggle, which
/// `resolveEmbeddingConfig` reads to borrow an LLM endpoint — the one named by
/// `ApiConfig.embeddingLlmPresetId`, or the active LLM preset when it is empty.
final activeEmbeddingPresetIdProvider = StateProvider<String?>((ref) => null);

final _activeIdInitializedProvider = Provider<bool>((ref) => false);

final activeApiConfigProvider = Provider<ApiConfig?>((ref) {
  final list = ref.watch(apiListProvider).value;
  final id = ref.watch(activeApiPresetIdProvider);
  if (list == null || list.isEmpty) return null;
  if (id == null) return list.first;
  return list.firstWhere((c) => c.id == id, orElse: () => list.first);
});

/// The preset every embedding request reads its settings from. Mirrors
/// [activeApiConfigProvider] over [embeddingPresetListProvider], so the two
/// selections move independently and over separate lists.
final activeEmbeddingConfigProvider = Provider<ApiConfig?>((ref) {
  final list = ref.watch(embeddingPresetListProvider).value;
  final id = ref.watch(activeEmbeddingPresetIdProvider);
  if (list == null || list.isEmpty) return null;
  if (id == null) return list.first;
  return list.firstWhere((c) => c.id == id, orElse: () => list.first);
});

/// The chat presets — everything the LLM tab, Studio slots and the model
/// pickers work with. Embedding presets are filtered out here and served by
/// [embeddingPresetListProvider] instead.
final apiListProvider = AsyncNotifierProvider<ApiListNotifier, List<ApiConfig>>(
  ApiListNotifier.new,
);

/// The presets of the Embeddings tab, kept in the same table under
/// `mode == 'embedding'`.
final embeddingPresetListProvider =
    AsyncNotifierProvider<EmbeddingPresetListNotifier, List<ApiConfig>>(
      EmbeddingPresetListNotifier.new,
    );

/// What the API screen needs from either list to save or delete a preset. The
/// two lists are separate notifiers over the same table, so the screen picks
/// one by the tab it is on and writes through this.
abstract interface class ApiPresetWriter {
  Future<void> put(ApiConfig config);

  Future<void> remove(String id);
}

class ApiListNotifier extends AsyncNotifier<List<ApiConfig>>
    implements ApiPresetWriter {
  @override
  Future<List<ApiConfig>> build() async {
    final repo = ref.watch(apiConfigRepoProvider);
    var configs = await repo.getAll();
    var changed = await _seedDefaultPresets(configs);
    if (changed) configs = await repo.getAll();
    if (await _tuneDefaultPresets(configs)) {
      configs = await repo.getAll();
    }
    final chatConfigs = [
      for (final config in configs)
        if (config.mode != kEmbeddingPresetMode) config,
    ];
    final initialized = ref.read(_activeIdInitializedProvider);
    if (!initialized) {
      final prefs = await ref.read(sharedPreferencesProvider.future);
      final savedId = prefs.getString('activeApiConfigId');
      if (savedId != null && chatConfigs.any((c) => c.id == savedId)) {
        ref.read(activeApiPresetIdProvider.notifier).state = savedId;
      }
    }
    return chatConfigs;
  }

  /// Puts the built-in presets in the list once, on a new install and on an
  /// existing one that has not been offered them yet. A preset whose name is
  /// already in the list is left alone (so nothing is duplicated), the
  /// presets are yours to edit or delete afterwards, and a deleted one is not
  /// put back. Returns true when anything was added.
  Future<bool> _seedDefaultPresets(List<ApiConfig> existing) async {
    try {
      final prefs = await ref.read(sharedPreferencesProvider.future);
      if (prefs.getBool(kDefaultApiPresetsSeededKey) == true) return false;
      final repo = ref.read(apiConfigRepoProvider);
      final haveNames = {
        for (final c in existing)
          if (c.mode != kEmbeddingPresetMode) c.name.trim().toLowerCase(),
      };
      var added = false;
      for (final name in kDefaultApiPresetNames) {
        if (haveNames.contains(name.toLowerCase())) continue;
        final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
        await repo.put(
          ApiConfig(
            id: 'default-$slug',
            name: name,
            providerId: 'custom_chat_completion',
            protocol: LlmProtocol.customChatCompletion,
            endpoint: kDefaultApiPresetEndpoint,
            promptPostProcessing: kDefaultApiPresetPostProcessing,
            firstChunkTimeoutMs: kDefaultApiPresetFirstChunkTimeoutMs,
            historyTrimMode: kDefaultApiPresetHistoryTrimMode,
          ),
        );
        added = true;
      }
      await prefs.setBool(kDefaultApiPresetsSeededKey, true);
      return added;
    } catch (_) {
      // Left unflagged so the next launch tries again.
      return false;
    }
  }

  /// One-time upgrade of the built-in presets that were created before they
  /// carried the local-server settings. Only values still at the app default
  /// are changed, so anything the user set by hand is left alone.
  Future<bool> _tuneDefaultPresets(List<ApiConfig> existing) async {
    try {
      final prefs = await ref.read(sharedPreferencesProvider.future);
      if (prefs.getBool(kDefaultApiPresetsTunedKey) == true) return false;
      final repo = ref.read(apiConfigRepoProvider);
      var changed = false;
      for (final config in existing) {
        if (!config.id.startsWith('default-') ||
            config.mode == kEmbeddingPresetMode) {
          continue;
        }
        final next = config.copyWith(
          promptPostProcessing: config.promptPostProcessing == 'none'
              ? kDefaultApiPresetPostProcessing
              : config.promptPostProcessing,
          firstChunkTimeoutMs: config.firstChunkTimeoutMs == 60000
              ? kDefaultApiPresetFirstChunkTimeoutMs
              : config.firstChunkTimeoutMs,
          historyTrimMode: config.historyTrimMode == 'sliding'
              ? kDefaultApiPresetHistoryTrimMode
              : config.historyTrimMode,
        );
        if (next != config) {
          await repo.put(next);
          changed = true;
        }
      }
      await prefs.setBool(kDefaultApiPresetsTunedKey, true);
      return changed;
    } catch (_) {
      // Left unflagged so the next launch tries again.
      return false;
    }
  }

  @override
  Future<void> put(ApiConfig config) async {
    await ref.read(apiConfigRepoProvider).put(config);
    ref.invalidateSelf();
  }

  @override
  Future<void> remove(String id) async {
    await ref.read(apiConfigRepoProvider).delete(id);
    await SyncDeletionTracker.record('api_presets', id);
    ref.invalidateSelf();
  }
}

class EmbeddingPresetListNotifier extends AsyncNotifier<List<ApiConfig>>
    implements ApiPresetWriter {
  @override
  Future<List<ApiConfig>> build() async {
    final repo = ref.watch(apiConfigRepoProvider);
    final configs = await repo.getAll();
    var presets = [
      for (final config in configs)
        if (config.mode == kEmbeddingPresetMode) config,
    ];
    final prefs = await ref.read(sharedPreferencesProvider.future);

    final seeded = await _seedFromChatPresets(prefs, configs, presets);
    if (seeded != null) presets = [...presets, seeded];

    _restoreSelection(prefs, presets, seeded?.id);
    return presets;
  }

  /// Carries the embedding settings that used to live on a chat preset over
  /// into an embedding preset of its own — once, on the first run after the
  /// Embeddings tab got its own list.
  ///
  /// The new preset keeps pointing at the chat preset it came from
  /// ([ApiConfig.embeddingLlmPresetId]), so "use LLM API" resolves to exactly
  /// the endpoint it resolved to before the split. Nothing is seeded when
  /// there was nothing configured — a fresh install gets the tab's empty state
  /// instead of a blank preset.
  Future<ApiConfig?> _seedFromChatPresets(
    SharedPreferences prefs,
    List<ApiConfig> configs,
    List<ApiConfig> presets,
  ) async {
    if (prefs.getBool(kEmbeddingPresetsSeededKey) == true) return null;
    if (presets.isNotEmpty) {
      await prefs.setBool(kEmbeddingPresetsSeededKey, true);
      return null;
    }
    final chatConfigs = [
      for (final config in configs)
        if (config.mode != kEmbeddingPresetMode) config,
    ];
    if (chatConfigs.isEmpty) return null;
    // The preset the embedding side was last pinned to, else the chat one.
    final pinnedId =
        prefs.getString(kActiveEmbeddingConfigIdKey) ??
        prefs.getString('activeApiConfigId');
    final source = chatConfigs.firstWhere(
      (c) => c.id == pinnedId,
      orElse: () => chatConfigs.first,
    );
    if (!source.embeddingEnabled &&
        source.embeddingEndpoint.isEmpty &&
        source.embeddingModel.isEmpty) {
      await prefs.setBool(kEmbeddingPresetsSeededKey, true);
      return null;
    }

    final preset = ApiConfig(
      id: 'emb-${DateTime.now().millisecondsSinceEpoch}',
      name: source.name.isNotEmpty ? source.name : 'Embeddings',
      mode: kEmbeddingPresetMode,
      embeddingEnabled: source.embeddingEnabled,
      embeddingUseSame: source.embeddingUseSame,
      embeddingEndpoint: source.embeddingEndpoint,
      embeddingApiKey: source.embeddingApiKey,
      embeddingModel: source.embeddingModel,
      embeddingMaxChunkTokens: source.embeddingMaxChunkTokens,
      embeddingRequestsPerMinute: source.embeddingRequestsPerMinute,
      embeddingLlmPresetId: source.id,
    );
    await ref.read(apiConfigRepoProvider).put(preset);
    await prefs.setString(kActiveEmbeddingConfigIdKey, preset.id);
    await prefs.setBool(kEmbeddingPresetsSeededKey, true);
    return preset;
  }

  void _restoreSelection(
    SharedPreferences prefs,
    List<ApiConfig> presets,
    String? seededId,
  ) {
    if (presets.isEmpty) {
      ref.read(activeEmbeddingPresetIdProvider.notifier).state = null;
      return;
    }
    // A selection the user already made this session wins over the stored one:
    // the list reloads on every save, and the id is persisted asynchronously.
    final current = ref.read(activeEmbeddingPresetIdProvider);
    if (current != null && presets.any((c) => c.id == current)) return;
    final savedId = seededId ?? prefs.getString(kActiveEmbeddingConfigIdKey);
    if (savedId != null && presets.any((c) => c.id == savedId)) {
      ref.read(activeEmbeddingPresetIdProvider.notifier).state = savedId;
      return;
    }
    // A stored id pointing at a preset that is gone falls back to the first
    // one rather than leaving the tab on nothing.
    ref.read(activeEmbeddingPresetIdProvider.notifier).state = null;
  }

  @override
  Future<void> put(ApiConfig config) async {
    await ref.read(apiConfigRepoProvider).put(_asEmbeddingPreset(config));
    ref.invalidateSelf();
  }

  @override
  Future<void> remove(String id) async {
    await ref.read(apiConfigRepoProvider).delete(id);
    await SyncDeletionTracker.record('api_presets', id);
    ref.invalidateSelf();
  }

  /// Flips the vector switch in memory so the gate closes on the very next
  /// request, ahead of the debounced save.
  void setEmbeddingEnabled(String id, bool enabled) {
    // The gate is global, so only the preset the embedding side actually runs
    // on may open or close it.
    if (id == ref.read(activeEmbeddingConfigProvider)?.id) {
      EmbeddingRequestGate.setEnabled(enabled);
    }
    final presets = state.value;
    if (presets == null) return;
    state = AsyncData([
      for (final preset in presets)
        if (preset.id == id)
          preset.copyWith(embeddingEnabled: enabled)
        else
          preset,
    ]);
  }

  /// A preset saved from the Embeddings tab is an embedding preset whatever
  /// the caller passed, so it can never land in the chat list.
  ApiConfig _asEmbeddingPreset(ApiConfig config) =>
      config.mode == kEmbeddingPresetMode
      ? config
      : config.copyWith(mode: kEmbeddingPresetMode);
}
