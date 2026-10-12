import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'saved_accounts_provider.dart';
import 'third_party_providers_provider.dart';

/// SpicyChat authentication is owned by the site's WebView session. The
/// persisted flag and display name are only a convenience for the settings
/// screen; the feed service re-checks the live WebView session before using
/// account-only feeds. The session itself is saved per account (see
/// [SavedCredential.session]) so a signed-out account can be restored later.
class SpicyChatAccount {
  final bool connected;
  final bool nsfwEnabled;

  /// Email or username of the signed-in account; null when signed out.
  final String? displayName;

  const SpicyChatAccount({
    this.connected = false,
    this.nsfwEnabled = false,
    this.displayName,
  });

  bool get isLoggedIn => connected;
}

class SpicyChatAccountNotifier extends Notifier<SpicyChatAccount> {
  static const _connectedKey = 'gz_spicychat_connected';
  static const _nsfwKey = 'gz_spicychat_nsfw_enabled';
  static const _nameKey = 'gz_spicychat_display_name';

  @override
  SpicyChatAccount build() {
    _load();
    return const SpicyChatAccount();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final connected = prefs.getBool(_connectedKey) ?? false;
    state = SpicyChatAccount(
      connected: connected,
      nsfwEnabled: prefs.getBool(_nsfwKey) ?? false,
      displayName: connected ? prefs.getString(_nameKey) : null,
    );
  }

  /// Marks the web session as signed in and remembers the account under
  /// [displayName] (its email or username). [credential] is the encoded
  /// [SavedCredential] to store with it; when null the account's earlier
  /// credential is kept.
  Future<void> setConnected(
    bool value, {
    String? displayName,
    String? credential,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final given = displayName?.trim() ?? '';
    final name = given.isNotEmpty
        ? given
        : (value ? (state.displayName ?? 'SpicyChat account') : '');
    await prefs.setBool(_connectedKey, value);
    if (value) {
      await prefs.setString(_nameKey, name);
    } else {
      await prefs.remove(_nameKey);
    }
    state = SpicyChatAccount(
      connected: value,
      nsfwEnabled: state.nsfwEnabled,
      displayName: value ? name : null,
    );
    if (value) {
      await ref
          .read(savedAccountsProvider.notifier)
          .remember(
            provider: ThirdPartyProvider.spicychat,
            displayName: name,
            credential: credential,
          );
    }
  }

  Future<void> setNsfwEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_nsfwKey, value);
    state = SpicyChatAccount(
      connected: state.connected,
      nsfwEnabled: value,
      displayName: state.displayName,
    );
  }

  /// Marks the app signed out. The remembered account stays in the Accounts
  /// list. With [keepNsfw] the Show NSFW choice survives, used when one account
  /// is being swapped for another rather than signed out for good.
  Future<void> clearConnected({bool keepNsfw = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final nsfw = keepNsfw && state.nsfwEnabled;
    await prefs.setBool(_connectedKey, false);
    await prefs.setBool(_nsfwKey, nsfw);
    await prefs.remove(_nameKey);
    state = SpicyChatAccount(nsfwEnabled: nsfw);
  }
}

final spicyChatAccountProvider =
    NotifierProvider<SpicyChatAccountNotifier, SpicyChatAccount>(
      SpicyChatAccountNotifier.new,
    );
