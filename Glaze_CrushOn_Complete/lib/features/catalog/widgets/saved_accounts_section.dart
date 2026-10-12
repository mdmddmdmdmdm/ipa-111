import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/menu_group.dart';
import '../chub_account_provider.dart';
import '../datacat_account_provider.dart';
import '../janitor_account_provider.dart';
import '../saucepan_account_provider.dart';
import '../saved_accounts_provider.dart';
import '../services/chub_provider.dart';
import '../services/janitor_session.dart';
import '../services/janitor_webview_proxy.dart';
import '../spicychat_account_provider.dart';
import '../crushon_account_provider.dart';
import 'crushon_login_sheet.dart';
import '../services/crushon_session.dart';
import '../third_party_providers_provider.dart';
import 'chub_login_sheet.dart';
import 'datacat/datacat_account_sheet.dart';
import 'janitor_login_sheet.dart';
import 'saucepan_login_sheet.dart';
import 'provider_auto_login_sheet.dart';
import 'spicychat_login_sheet.dart';

/// Expandable "Accounts" row under a content provider. Lists every account
/// ever signed in for that source; the active one is marked. Tapping an
/// inactive entry restores it when credentials are available, otherwise opens
/// the normal sign-in flow.
class SavedAccountsSection extends ConsumerStatefulWidget {
  final ThirdPartyProvider provider;

  const SavedAccountsSection({super.key, required this.provider});

  @override
  ConsumerState<SavedAccountsSection> createState() =>
      _SavedAccountsSectionState();
}

class _SavedAccountsSectionState extends ConsumerState<SavedAccountsSection> {
  bool _expanded = false;

  String? _activeLabel() {
    switch (widget.provider) {
      case ThirdPartyProvider.chub:
        final a = ref.watch(chubAccountProvider);
        return a.isLoggedIn ? (a.userName ?? 'Chub') : null;
      case ThirdPartyProvider.janitor:
        final a = ref.watch(janitorAccountProvider);
        return a.isLoggedIn ? a.userName : null;
      case ThirdPartyProvider.spicychat:
        final a = ref.watch(spicyChatAccountProvider);
        return a.isLoggedIn ? (a.displayName ?? 'SpicyChat account') : null;
      case ThirdPartyProvider.crushon:
        final a = ref.watch(crushOnAccountProvider);
        return a.isLoggedIn ? (a.displayName ?? 'CrushOn account') : null;
      case ThirdPartyProvider.datacat:
        final a = ref.watch(datacatAccountProvider);
        return a.loggedIn ? (a.displayName ?? 'DataCat') : null;
      case ThirdPartyProvider.saucepan:
        final a = ref.watch(saucepanAccountProvider);
        return a.isLoggedIn ? (a.handle ?? 'Saucepan') : null;
      case ThirdPartyProvider.janny:
        return null;
    }
  }

  bool _isActive(SavedAccount account, String? activeLabel) {
    if (activeLabel == null) return false;
    // Match by display name (case-insensitive) — credentials may differ
    // slightly across restores.
    return account.displayName.toLowerCase() == activeLabel.toLowerCase();
  }

  Future<void> _activate(SavedAccount account) async {
    final cred = SavedCredential.tryParse(account.credential);

    switch (widget.provider) {
      case ThirdPartyProvider.chub:
        if (cred?.hasApiKey == true) {
          await ref.read(chubAccountProvider.notifier).setApiKey(
                cred!.apiKey,
                userName: account.displayName,
              );
          resetChubTagCache();
          return;
        }
        if (cred?.hasPasswordLogin == true) {
          await showProviderAutoLoginSheet(
            context,
            title: 'Chub',
            loginUrl: 'https://chub.ai/login',
            provider: ThirdPartyProvider.chub,
            email: cred!.email ?? cred.handle,
            password: cred.password,
            onLoggedIn: () async {
              // Token is captured by the normal Chub login poll only in
              // ChubLoginSheet — open that path if key is still missing.
            },
          );
          return;
        }
        await showChubLoginSheet(context);
        break;

      case ThirdPartyProvider.saucepan:
        if (cred?.hasToken == true) {
          await ref.read(saucepanAccountProvider.notifier).setToken(cred!.token!);
          return;
        }
        if (cred?.hasPasswordLogin == true) {
          final handle = cred!.handle ?? cred.email ?? account.displayName;
          final password = cred.password!;
          try {
            await ref.read(saucepanAccountProvider.notifier).login(handle, password);
            return;
          } catch (_) {}
        }
        await openSaucepanAccountSheet(context, ref);
        break;

      case ThirdPartyProvider.janitor:
        if (cred?.hasSession == true) {
          // Restore only this account's JanitorAI auth cookies before opening
          // the site's own sign-in page. OAuth passwords are never replayed.
          // Remove the currently active JanitorAI identity first, leaving all
          // other provider sessions untouched.
          await JanitorWebViewProxy.instance.logout();
          final restored = await JanitorAccountSession.restore(cred!.session);
          if (restored) {
            await showJanitorLoginSheet(context);
            return;
          }
        }
        if (cred?.hasPasswordLogin == true) {
          await showProviderAutoLoginSheet(
            context,
            title: 'JanitorAI',
            loginUrl: 'https://janitorai.com/login',
            provider: ThirdPartyProvider.janitor,
            email: cred!.email ?? cred.handle,
            password: cred.password,
            onLoggedIn: () async {
              final name = cred.email ?? account.displayName;
              await ref.read(janitorAccountProvider.notifier).setUserName(name);
            },
          );
          return;
        }
        await openJanitorAccountSheet(context, ref);
        break;

      case ThirdPartyProvider.spicychat:
        // Older entries saved an email + password; keep replaying those.
        if (cred?.hasPasswordLogin == true && cred?.hasSession != true) {
          await showProviderAutoLoginSheet(
            context,
            title: 'SpicyChat',
            loginUrl: 'https://spicychat.ai/login',
            provider: ThirdPartyProvider.spicychat,
            email: cred!.email ?? cred.handle,
            password: cred.password,
            onLoggedIn: () async {
              await ref.read(spicyChatAccountProvider.notifier).setConnected(
                    true,
                    displayName: cred.email ?? account.displayName,
                    credential: account.credential,
                  );
            },
          );
          return;
        }
        // Everything else (SpicyChat signs in with an emailed code or
        // Google/Apple/X/Discord, so there is no password): restore the saved
        // session, or sign in again with the buttons pressed for you.
        await showSpicyChatLoginSheet(context, restore: account);
        break;

      case ThirdPartyProvider.datacat:
        await openDatacatAccountSheet(context, ref);
        break;

      case ThirdPartyProvider.crushon:
        // Cookie header is stored on the SavedAccount credential blob.
        final cookie = (cred?.session ?? account.credential)?.trim();
        if (cookie != null && cookie.isNotEmpty) {
          await CrushOnWebSession.instance.setFromWebView(cookieHeader: cookie);
          await ref.read(crushOnAccountProvider.notifier).setConnected(
                true,
                displayName: account.displayName,
                credential: cookie,
              );
          return;
        }
        await CrushOnLoginSheet.show(context);
        break;

      case ThirdPartyProvider.janny:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref
        .watch(savedAccountsProvider)
        .where((a) => a.provider == widget.provider)
        .toList();
    if (accounts.isEmpty) return const SizedBox.shrink();

    final active = _activeLabel();
    final count = accounts.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MenuItem(
          icon: Icons.manage_accounts_outlined,
          label: 'provider_accounts'.tr(),
          subtitle: count == 1
              ? accounts.first.displayName
              : 'provider_accounts_count'.tr(
                  namedArgs: {'count': '$count'},
                ),
          trailing: Icon(
            _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            color: context.cs.onSurfaceVariant,
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded)
          for (final account in accounts)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: MenuItem(
                icon: _isActive(account, active)
                    ? Icons.check_circle_rounded
                    : Icons.account_circle_outlined,
                label: account.displayName,
                subtitle: _isActive(account, active)
                    ? 'provider_account_active'.tr()
                    : 'provider_account_saved'.tr(),
                trailing: IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: context.cs.onSurfaceVariant,
                  ),
                  tooltip: 'provider_account_remove'.tr(),
                  onPressed: () => ref
                      .read(savedAccountsProvider.notifier)
                      .remove(account.id),
                ),
                onTap: _isActive(account, active)
                    ? () {}
                    : () => _activate(account),
              ),
            ),
      ],
    );
  }
}
