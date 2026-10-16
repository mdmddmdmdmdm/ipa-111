import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'third_party_providers_provider.dart';

/// One previously used account for a content provider. Survives sign-out so
/// the user can switch back without re-entering credentials.
class SavedAccount {
  final String id;
  final ThirdPartyProvider provider;
  final String displayName;

  /// Provider-specific secret: Chub API key, Saucepan bearer token, or a
  /// JSON blob of cookies/localStorage for web-session providers.
  final String? credential;

  final int lastUsedMs;

  const SavedAccount({
    required this.id,
    required this.provider,
    required this.displayName,
    this.credential,
    required this.lastUsedMs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'provider': provider.name,
        'displayName': displayName,
        'credential': credential,
        'lastUsedMs': lastUsedMs,
      };

  factory SavedAccount.fromJson(Map<String, dynamic> j) {
    final name = (j['provider'] as String?) ?? 'chub';
    final match = ThirdPartyProvider.values.where((p) => p.name == name);
    return SavedAccount(
      id: (j['id'] as String?) ?? '',
      provider: match.isEmpty ? ThirdPartyProvider.chub : match.first,
      displayName: (j['displayName'] as String?) ?? 'Account',
      credential: j['credential'] as String?,
      lastUsedMs: (j['lastUsedMs'] as int?) ?? 0,
    );
  }

  SavedAccount copyWith({
    String? displayName,
    String? credential,
    int? lastUsedMs,
  }) =>
      SavedAccount(
        id: id,
        provider: provider,
        displayName: displayName ?? this.displayName,
        credential: credential ?? this.credential,
        lastUsedMs: lastUsedMs ?? this.lastUsedMs,
      );
}

class SavedAccountsNotifier extends Notifier<List<SavedAccount>> {
  static const _prefKey = 'gz_saved_provider_accounts_v1';

  @override
  List<SavedAccount> build() {
    _load();
    return const [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => SavedAccount.fromJson(Map<String, dynamic>.from(e)))
          .where((a) => a.id.isNotEmpty)
          .toList();
      list.sort((a, b) => b.lastUsedMs.compareTo(a.lastUsedMs));
      state = list;
    } catch (_) {}
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefKey,
      jsonEncode(state.map((a) => a.toJson()).toList()),
    );
  }

  /// The id [remember] gives an account with this display name.
  static String idFor(ThirdPartyProvider provider, String displayName) =>
      '${provider.name}:${displayName.trim().toLowerCase()}';

  /// Upsert a remembered account. Call on every successful sign-in.
  Future<void> remember({
    required ThirdPartyProvider provider,
    required String displayName,
    String? credential,
    String? id,
  }) async {
    final name = displayName.trim();
    if (name.isEmpty && (credential == null || credential.isEmpty)) return;
    final accountId = id ??
        '${provider.name}:${(name.isNotEmpty ? name : credential!).toLowerCase()}';
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = [...state];
    final idx = existing.indexWhere((a) => a.id == accountId);
    final next = SavedAccount(
      id: accountId,
      provider: provider,
      displayName: name.isEmpty ? 'Account' : name,
      // A caller that has no credential this time (e.g. a plain "signed in"
      // update) must not erase the one saved earlier.
      credential: credential ?? (idx >= 0 ? existing[idx].credential : null),
      lastUsedMs: now,
    );
    if (idx >= 0) {
      existing[idx] = next;
    } else {
      existing.insert(0, next);
    }
    existing.sort((a, b) => b.lastUsedMs.compareTo(a.lastUsedMs));
    state = existing;
    await _persist();
  }

  Future<void> remove(String id) async {
    state = [for (final a in state) if (a.id != id) a];
    await _persist();
  }

  List<SavedAccount> forProvider(ThirdPartyProvider p) =>
      [for (final a in state) if (a.provider == p) a];
}

final savedAccountsProvider =
    NotifierProvider<SavedAccountsNotifier, List<SavedAccount>>(
  SavedAccountsNotifier.new,
);


/// Credential payload helpers stored in [SavedAccount.credential].
class SavedCredential {
  final String? email;
  final String? password;
  final String? apiKey;
  final String? token;
  final String? handle;

  /// How this account signs in: `email`, `google`, `api_key`, `token`, …
  final String? method;

  /// Encoded web-session snapshot (cookies + site storage) for providers that
  /// sign in without a replayable password, such as SpicyChat.
  final String? session;

  const SavedCredential({
    this.email,
    this.password,
    this.apiKey,
    this.token,
    this.handle,
    this.method,
    this.session,
  });

  bool get hasSession => session != null && session!.isNotEmpty;

  bool get hasPasswordLogin =>
      ((email != null && email!.isNotEmpty) ||
          (handle != null && handle!.isNotEmpty)) &&
      password != null &&
      password!.isNotEmpty;

  bool get hasApiKey => apiKey != null && apiKey!.isNotEmpty;
  bool get hasToken => token != null && token!.isNotEmpty;
  bool get isGoogle => (method ?? '').toLowerCase() == 'google';
  bool get isEmail =>
      (method ?? '').toLowerCase() == 'email' || hasPasswordLogin;

  String encode() => jsonEncode({
        if (email != null) 'email': email,
        if (password != null) 'password': password,
        if (apiKey != null) 'apiKey': apiKey,
        if (token != null) 'token': token,
        if (handle != null) 'handle': handle,
        if (method != null) 'method': method,
        if (session != null) 'session': session,
      });

  static SavedCredential? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final t = raw.trim();
    // Legacy: plain API key / token string (no JSON).
    if (!t.startsWith('{')) {
      return SavedCredential(apiKey: t, token: t, method: 'api_key');
    }
    try {
      final m = jsonDecode(t) as Map<String, dynamic>;
      return SavedCredential(
        email: m['email'] as String?,
        password: m['password'] as String?,
        apiKey: m['apiKey'] as String?,
        token: m['token'] as String?,
        handle: m['handle'] as String?,
        method: m['method'] as String?,
        session: m['session'] as String?,
      );
    } catch (_) {
      return SavedCredential(apiKey: t, token: t, method: 'api_key');
    }
  }
}
