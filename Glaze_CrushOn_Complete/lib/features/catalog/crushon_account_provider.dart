import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'saved_accounts_provider.dart';
import 'services/crushon_session.dart';
import 'third_party_providers_provider.dart';

/// CrushOn authentication state.
///
/// The live session lives in [CrushOnWebSession] (cookies from the login
/// WebView). This notifier is the settings-screen convenience flag + display
/// name, same shape as [SpicyChatAccount].
class CrushOnAccount {
  final bool connected;
  final bool nsfwEnabled;

  /// Email or username of the signed-in account; null when signed out.
  final String? displayName;

  const CrushOnAccount({
    this.connected = false,
    this.nsfwEnabled = true,
    this.displayName,
  });

  bool get isLoggedIn => connected;
}

class CrushOnAccountNotifier extends Notifier<CrushOnAccount> {
  static const _connectedKey = 'gz_crushon_connected';
  static const _nsfwKey = 'gz_crushon_nsfw_enabled';
  static const _nameKey = 'gz_crushon_display_name';

  @override
  CrushOnAccount build() {
    _load();
    return const CrushOnAccount();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    await CrushOnWebSession.instance.ensureLoaded();
    final connected = prefs.getBool(_connectedKey) ?? false;
    // If prefs say connected but cookies were wiped, treat as signed out.
    final live = connected && CrushOnWebSession.instance.hasSession;
    state = CrushOnAccount(
      connected: live,
      nsfwEnabled: prefs.getBool(_nsfwKey) ?? true,
      displayName: live ? prefs.getString(_nameKey) : null,
    );
    if (connected && !live) {
      await prefs.setBool(_connectedKey, false);
    }
  }

  /// Marks the web session as signed in.
  Future<void> setConnected(
    bool value, {
    String? displayName,
    String? credential,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final given = displayName?.trim() ?? '';
    final name = given.isNotEmpty
        ? given
        : (value ? (state.displayName ?? 'CrushOn account') : '');
    await prefs.setBool(_connectedKey, value);
    if (value) {
      await prefs.setString(_nameKey, name);
    } else {
      await prefs.remove(_nameKey);
      await CrushOnWebSession.instance.clear();
    }
    state = CrushOnAccount(
      connected: value,
      nsfwEnabled: state.nsfwEnabled,
      displayName: value ? name : null,
    );
    if (value) {
      await ref.read(savedAccountsProvider.notifier).remember(
            provider: ThirdPartyProvider.crushon,
            displayName: name,
            credential: credential,
          );
    }
  }

  Future<void> setNsfwEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_nsfwKey, value);
    state = CrushOnAccount(
      connected: state.connected,
      nsfwEnabled: value,
      displayName: state.displayName,
    );
  }

  Future<void> clearConnected({bool keepNsfw = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final nsfw = keepNsfw && state.nsfwEnabled;
    await prefs.setBool(_connectedKey, false);
    await prefs.setBool(_nsfwKey, nsfw);
    await prefs.remove(_nameKey);
    await CrushOnWebSession.instance.clear();
    state = CrushOnAccount(nsfwEnabled: nsfw);
  }
}

final crushOnAccountProvider =
    NotifierProvider<CrushOnAccountNotifier, CrushOnAccount>(
      CrushOnAccountNotifier.new,
    );
