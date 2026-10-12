import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/user_script.dart';
import 'services/userscript_parser.dart';

/// Every userscript the user added, saved in app preferences.
class UserScriptsNotifier extends Notifier<List<GlazeUserScript>> {
  static const _prefKey = 'gz_user_scripts_v1';

  Future<void>? _loading;

  @override
  List<GlazeUserScript> build() {
    _loading = _load();
    return const [];
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = GlazeUserScript.decodeList(prefs.getString(_prefKey));
    } catch (_) {}
  }

  Future<void> ensureLoaded() => _loading ?? Future<void>.value();

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, GlazeUserScript.encodeList(state));
    } catch (_) {}
  }

  GlazeUserScript? byId(String id) {
    for (final s in state) {
      if (s.id == id) return s;
    }
    return null;
  }

  static String _newId() =>
      'us_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  /// Adds a script from its source. A script with the same name and namespace
  /// as an existing one replaces that one's code instead of piling up copies.
  Future<GlazeUserScript> addFromCode(
    String code, {
    String sourceUrl = '',
    Map<String, String> requireCode = const {},
  }) async {
    await ensureLoaded();
    final probe = userScriptFromCode(code, id: _newId(), sourceUrl: sourceUrl);
    final same = state
        .where((s) => s.name == probe.name && s.namespace == probe.namespace)
        .firstOrNull;
    final script = same == null
        ? probe.copyWith(requireCode: requireCode)
        : userScriptFromCode(
            code,
            id: same.id,
            sourceUrl: sourceUrl,
            previous: same,
          ).copyWith(requireCode: requireCode);
    state = same == null
        ? [...state, script]
        : [for (final s in state) s.id == same.id ? script : s];
    await _persist();
    return script;
  }

  /// Replaces the code of [id] (from the editor or an update), re-reading the
  /// header and keeping the user's switches.
  Future<void> replaceCode(
    String id,
    String code, {
    Map<String, String>? requireCode,
  }) async {
    final old = byId(id);
    if (old == null) return;
    var next = userScriptFromCode(code, id: id, previous: old);
    if (requireCode != null) next = next.copyWith(requireCode: requireCode);
    state = [for (final s in state) s.id == id ? next : s];
    await _persist();
  }

  Future<void> save(GlazeUserScript script) async {
    state = [for (final s in state) s.id == script.id ? script : s];
    await _persist();
  }

  Future<void> setEnabled(String id, bool value) async {
    final s = byId(id);
    if (s != null) await save(s.copyWith(enabled: value));
  }

  Future<void> remove(String id) async {
    state = [for (final s in state) if (s.id != id) s];
    await _persist();
    await ScriptValueStore.instance.clear(id);
  }
}

final userScriptsProvider =
    NotifierProvider<UserScriptsNotifier, List<GlazeUserScript>>(
      UserScriptsNotifier.new,
    );

/// Ids of the scripts that ran on the page the script browser is showing now.
/// Drives the "Running" badge in the script list.
final runningScriptIdsProvider = StateProvider<Set<String>>((ref) => {});

/// What `GM_setValue` / `GM_getValue` keep, per script. Values are stored as
/// the JSON text the page script produced.
class ScriptValueStore {
  ScriptValueStore._();
  static final instance = ScriptValueStore._();

  static const _prefKey = 'gz_user_script_values_v1';

  Map<String, Map<String, String>>? _cache;

  Future<Map<String, Map<String, String>>> _all() async {
    final cached = _cache;
    if (cached != null) return cached;
    final out = <String, Map<String, String>>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw != null && raw.isNotEmpty) {
        final data = jsonDecode(raw);
        if (data is Map) {
          for (final e in data.entries) {
            final inner = e.value;
            if (inner is Map) {
              out[e.key.toString()] = {
                for (final kv in inner.entries)
                  if (kv.value is String) kv.key.toString(): kv.value as String,
              };
            }
          }
        }
      }
    } catch (_) {}
    return _cache = out;
  }

  Future<void> _flush() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(_cache ?? const {}));
    } catch (_) {}
  }

  Future<Map<String, String>> valuesFor(String scriptId) async =>
      Map<String, String>.from((await _all())[scriptId] ?? const {});

  Future<void> set(String scriptId, String key, String jsonValue) async {
    final all = await _all();
    (all[scriptId] ??= {})[key] = jsonValue;
    await _flush();
  }

  Future<void> delete(String scriptId, String key) async {
    final all = await _all();
    all[scriptId]?.remove(key);
    await _flush();
  }

  Future<void> clear(String scriptId) async {
    final all = await _all();
    if (all.remove(scriptId) != null) await _flush();
  }
}
