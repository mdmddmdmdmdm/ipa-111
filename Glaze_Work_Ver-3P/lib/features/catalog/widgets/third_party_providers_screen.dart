import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/shell/desktop/desktop_floating_provider.dart';
import '../../../shared/shell/shell_header_provider.dart';
import '../../../shared/widgets/glaze_scaffold.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../core/platform/haptics.dart';
import '../../../shared/theme/app_colors.dart';
import '../../settings/app_settings_provider.dart';
import '../chub_account_provider.dart';
import '../catalog_models.dart';
import '../catalog_provider.dart';
import '../datacat_account_provider.dart';
import '../janitor_account_provider.dart';
import '../saucepan_account_provider.dart';
import '../spicychat_account_provider.dart';
import '../third_party_providers_provider.dart';
import 'catalog_onboarding_sheet.dart';
import 'chub_login_sheet.dart';
import 'datacat/datacat_account_sheet.dart';
import 'janitor_login_sheet.dart';
import 'janitor_source_settings.dart';
import 'provider_logo.dart';
import 'saucepan_login_sheet.dart';
import 'provider_account_view_sheet.dart';
import 'saved_accounts_section.dart';
import 'spicychat_login_sheet.dart';
import 'crushon_login_sheet.dart';
import '../crushon_account_provider.dart';

/// Opens the content providers screen: on desktop in a floating window
/// (stacked onto the Menu's when opened from there), on phones as a
/// full-screen pushed route on the root navigator, so it works identically from
/// the menu and from the catalog provider picker (which live in different shell
/// branches).
Future<void> openThirdPartyProvidersScreen(BuildContext context) async {
  if (floatOnDesktop(context, 'third-party-providers', push: true)) return;
  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => const ThirdPartyProvidersScreen()),
  );
}

/// Lists the content sources (JanitorAI, Janny, Datacat, Chub, SpicyChat, Saucepan),
/// each as a group. The four browse providers can be toggled on/off: disabling
/// one hides it from the catalog and collapses its per-provider settings.
/// Saucepan has no toggle — it is always on and only backs URL import, so its
/// account settings are always shown.
class ThirdPartyProvidersScreen extends ConsumerWidget {
  const ThirdPartyProvidersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final disabled = ref.watch(thirdPartyProvidersProvider);
    final catalogEnabled = ref.watch(catalogMasterEnabledProvider);
    final blurNsfw = ref.watch(blurNsfwImagesProvider);
    // Inside the desktop floating window the frame supplies the title bar, so
    // the space reserved for a header would be a gap.
    final topPad = DetachedShellHost.of(context)
        ? 0.0
        : MediaQuery.of(context).padding.top + 74.0;
    final bottomPad = MediaQuery.of(context).padding.bottom + 20.0;

    return GlazeScaffold(
      title: 'third_party_providers_title'.tr(),
      showBackground: true,
      extendBodyBehindHeader: true,
      // Pushed as a raw MaterialPageRoute, so pop this route directly. Using
      // maybePop() here would be blocked by GlazeScaffold's PopScope
      // (canPop == false on non-iOS) and recurse back into onBack → crash.
      onBack: () => Navigator.of(context).pop(),
      body: ListView(
        padding: EdgeInsets.fromLTRB(0, topPad + 8, 0, bottomPad),
        children: [
          // Master switch: turning the catalog off hides the Discover tab
          // entirely, leaving only "My Characters".
          MenuGroup(
            header: 'third_party_catalog_title'.tr(),
            headerIcon: Icons.public_rounded,
            description: 'third_party_catalog_desc'.tr(),
            headerTrailing: _GroupSwitch(
              value: catalogEnabled,
              onChanged: (v) =>
                  ref.read(catalogMasterEnabledProvider.notifier).setEnabled(v),
            ),
            items: [
              MenuItem(
                icon: Icons.school_outlined,
                label: 'catalog_onboarding_replay'.tr(),
                subtitle: 'catalog_onboarding_replay_hint'.tr(),
                onTap: () => replayCatalogOnboarding(context),
              ),
              // One switch for every source: a display choice only, it covers
              // the main image and the images in the bio of an adult row and
              // never removes a character from the results.
              MenuSwitchItem(
                label: 'catalog_blur_nsfw'.tr(),
                description: 'catalog_blur_nsfw_desc'.tr(),
                value: blurNsfw,
                onChanged: (v) =>
                    ref.read(blurNsfwImagesProvider.notifier).setBlurring(v),
              ),
            ],
          ),
          for (final p in ThirdPartyProvider.values)
            _providerGroup(context, ref, p, enabled: !disabled.contains(p)),
        ],
      ),
    );
  }

  Widget _providerGroup(
    BuildContext context,
    WidgetRef ref,
    ThirdPartyProvider p, {
    required bool enabled,
  }) {
    // Saucepan is always on: it is not a browse source, so it has no
    // enable/disable switch and its account settings are always visible.
    final toggleable = p != ThirdPartyProvider.saucepan;
    return MenuGroup(
      header: _label(p),
      headerIconWidget: ProviderLogo(provider: p),
      description: _description(p),
      headerTrailing: toggleable
          ? _GroupSwitch(
              value: enabled,
              onChanged: (v) => ref
                  .read(thirdPartyProvidersProvider.notifier)
                  .setEnabled(p, v),
            )
          : null,
      items: [
        // Per-provider settings are only shown while the group is enabled.
        if (enabled || !toggleable) ..._settingsFor(context, ref, p),
      ],
    );
  }

  List<Widget> _settingsFor(
    BuildContext context,
    WidgetRef ref,
    ThirdPartyProvider p,
  ) {
    switch (p) {
      case ThirdPartyProvider.janitor:
        final account = ref.watch(janitorAccountProvider);
        final settings = ref.watch(appSettingsProvider).value;
        return [
          MenuItem(
            icon: Icons.person_outline_rounded,
            label: 'janitor_login_menu'.tr(),
            subtitle: account.isLoggedIn
                ? 'janitor_login_menu_logged_in'.tr(
                    namedArgs: {'name': account.userName!},
                  )
                : 'janitor_login_menu_logged_out'.tr(),
            onTap: () => openJanitorAccountSheet(context, ref),
          ),
          if (account.isLoggedIn)
            MenuItem(
              icon: Icons.open_in_browser_rounded,
              label: 'provider_view_account'.tr(),
              subtitle: 'provider_view_account_hint'.tr(),
              onTap: () => showProviderAccountViewSheet(
                context,
                title: 'JanitorAI',
                url: 'https://janitorai.com/',
              ),
            ),
          SavedAccountsSection(provider: ThirdPartyProvider.janitor),
          if (settings != null)
            ...janitorSourceMenuItems(context, ref, settings),
        ];
      case ThirdPartyProvider.saucepan:
        final account = ref.watch(saucepanAccountProvider);
        return [
          MenuItem(
            icon: Icons.ramen_dining_outlined,
            label: 'Saucepan account',
            subtitle: account.isLoggedIn
                ? (account.handle != null
                      ? 'Logged in as ${account.handle}'
                      : 'Logged in')
                : 'Log in for local companion extraction',
            onTap: () => openSaucepanAccountSheet(context, ref),
          ),
          if (account.isLoggedIn)
            MenuItem(
              icon: Icons.open_in_browser_rounded,
              label: 'provider_view_account'.tr(),
              subtitle: 'provider_view_account_hint'.tr(),
              onTap: () => showProviderAccountViewSheet(
                context,
                title: 'Saucepan',
                url: 'https://saucepan.ai/',
              ),
            ),
          SavedAccountsSection(provider: ThirdPartyProvider.saucepan),
        ];
      case ThirdPartyProvider.chub:
        final chub = ref.watch(chubAccountProvider);
        return [
          MenuItem(
            icon: Icons.key_outlined,
            label: 'chub_login_menu'.tr(),
            subtitle: chub.isLoggedIn
                ? 'chub_login_menu_logged_in'.tr()
                : 'chub_login_menu_logged_out'.tr(),
            onTap: () => openChubAccountSheet(context, ref),
          ),
          if (chub.isLoggedIn)
            MenuItem(
              icon: Icons.open_in_browser_rounded,
              label: 'provider_view_account'.tr(),
              subtitle: 'provider_view_account_hint'.tr(),
              onTap: () {
                // Key-based login never sets browser cookies. Seed the same
                // localStorage keys chub.ai itself uses so the site treats
                // the user as signed in when View account opens.
                final key = chub.apiKey ?? '';
                final name = chub.userName ?? '';
                final safeKey =
                    key.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
                final safeName =
                    name.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
                final js = "(function(){try{"
                    "localStorage.setItem('URQL_TOKEN','$safeKey');"
                    "localStorage.setItem('urql_token','$safeKey');"
                    "if('$safeName'){localStorage.setItem('USERNAME','$safeName');"
                    "localStorage.setItem('USER_NAME','$safeName');}"
                    "}catch(e){}})();";
                showProviderAccountViewSheet(
                  context,
                  title: 'Chub',
                  url: name.isNotEmpty
                      ? 'https://chub.ai/users/${Uri.encodeComponent(name)}'
                      : 'https://chub.ai/',
                  onLoadInjectJs: js,
                );
              },
            ),
          SavedAccountsSection(provider: ThirdPartyProvider.chub),
          // Account-level NSFL opt-in, mirroring chub.ai's own `no_nsfl`
          // profile flag: the site only ever serves NSFL to a signed-in
          // account, and this is the persistent "I want it" that the
          // per-search toggle in the filter sheet then narrows.
          MenuSwitchItem(
            label: 'catalog_filter_nsfl'.tr(),
            description: 'chub_nsfl_account_hint'.tr(),
            value: chub.nsfl,
            onChanged: (v) {
              if (v && !chub.isLoggedIn) {
                // NSFL is account-scoped on chub.ai — sign in first.
                openChubAccountSheet(context, ref);
                return;
              }
              ref.read(chubAccountProvider.notifier).setNsfl(v);
            },
          ),
        ];
      case ThirdPartyProvider.datacat:
        // Linking is only needed to post kudos and comments; browsing and
        // importing work without it, so the row says what it unlocks rather
        // than presenting itself as a prerequisite.
        final datacat = ref.watch(datacatAccountProvider);
        return [
          MenuItem(
            icon: Icons.person_outline_rounded,
            label: 'datacat_account_menu'.tr(),
            subtitle: datacat.linked
                ? (datacat.displayName != null
                      ? 'datacat_account_linked_as'.tr(
                          namedArgs: {'name': datacat.displayName!},
                        )
                      : 'datacat_account_linked'.tr())
                : 'datacat_account_not_linked'.tr(),
            onTap: () => openDatacatAccountSheet(context, ref),
          ),
          if (datacat.loggedIn)
            MenuItem(
              icon: Icons.open_in_browser_rounded,
              label: 'provider_view_account'.tr(),
              subtitle: 'provider_view_account_hint'.tr(),
              onTap: () => showProviderAccountViewSheet(
                context,
                title: 'Datacat',
                url: 'https://datacat.run/',
              ),
            ),
          SavedAccountsSection(provider: ThirdPartyProvider.datacat),
        ];
      case ThirdPartyProvider.spicychat:
        final account = ref.watch(spicyChatAccountProvider);
        return [
          MenuItem(
            icon: Icons.person_outline_rounded,
            label: 'SpicyChat account',
            subtitle: account.isLoggedIn
                ? 'Signed in as ${account.displayName ?? 'SpicyChat account'}'
                : 'Sign in for For You recommendations and Recent chats',
            onTap: () => openSpicyChatAccountSheet(context, ref),
          ),
          if (account.isLoggedIn)
            MenuItem(
              icon: Icons.open_in_browser_rounded,
              label: 'provider_view_account'.tr(),
              subtitle: 'provider_view_account_hint'.tr(),
              // Session-aware viewer keeps SpicyChat cookies/localStorage and
              // allows the page to scroll.
              onTap: () => showSpicyChatAccountViewSheet(context, ref),
            ),
          SavedAccountsSection(provider: ThirdPartyProvider.spicychat),
          MenuSwitchItem(
            label: 'Show NSFW',
            description: account.isLoggedIn
                ? 'Allows the SpicyChat catalog to request NSFW characters. SpicyChat account/age settings still apply.'
                : 'Sign in to SpicyChat first to enable NSFW discovery.',
            value: account.nsfwEnabled,
            onChanged: (v) async {
              if (v && !account.isLoggedIn) {
                await openSpicyChatAccountSheet(context, ref);
                if (!ref.read(spicyChatAccountProvider).isLoggedIn) return;
              }
              await ref.read(spicyChatAccountProvider.notifier).setNsfwEnabled(v);
              final catalog = ref.read(catalogProvider.notifier);
              final current = ref.read(catalogProvider);
              if (current.activeProvider == CatalogProvider.spicychat) {
                catalog.setFilters(current.filters.copyWith(nsfw: v));
              }
            },
          ),
        ];
      case ThirdPartyProvider.crushon:
        final account = ref.watch(crushOnAccountProvider);
        return [
          MenuItem(
            icon: Icons.person_outline_rounded,
            label: 'CrushOn account',
            subtitle: account.isLoggedIn
                ? 'Signed in as ${account.displayName ?? 'CrushOn account'}'
                : 'Sign in for Following, favorites, and full character import',
            onTap: () => CrushOnLoginSheet.show(context),
          ),
          if (account.isLoggedIn)
            MenuItem(
              icon: Icons.logout_rounded,
              label: 'Sign out',
              subtitle: 'Clears the saved CrushOn session cookies',
              onTap: () async {
                await ref.read(crushOnAccountProvider.notifier).clearConnected();
              },
            ),
          SavedAccountsSection(provider: ThirdPartyProvider.crushon),
          MenuSwitchItem(
            label: 'Show NSFW',
            description: account.isLoggedIn
                ? 'Allows the CrushOn catalog to request unfiltered characters.'
                : 'Sign in to CrushOn first for the best NSFW discovery experience.',
            value: account.nsfwEnabled,
            onChanged: (v) async {
              if (v && !account.isLoggedIn) {
                await CrushOnLoginSheet.show(context);
                if (!ref.read(crushOnAccountProvider).isLoggedIn) return;
              }
              await ref.read(crushOnAccountProvider.notifier).setNsfwEnabled(v);
              final catalog = ref.read(catalogProvider.notifier);
              final current = ref.read(catalogProvider);
              if (current.activeProvider == CatalogProvider.crushon) {
                catalog.setFilters(current.filters.copyWith(nsfw: v));
              }
            },
          ),
        ];
      case ThirdPartyProvider.janny:
        // No dedicated settings — the group is just an enable/disable toggle.
        return const [];
    }
  }

  String _label(ThirdPartyProvider p) => switch (p) {
    ThirdPartyProvider.janitor => 'JanitorAI',
    ThirdPartyProvider.janny => 'Janny',
    ThirdPartyProvider.datacat => 'Datacat',
    ThirdPartyProvider.chub => 'Chub',
    ThirdPartyProvider.spicychat => 'SpicyChat',
    ThirdPartyProvider.crushon => 'CrushOn',
    ThirdPartyProvider.saucepan => 'Saucepan',
  };

  String _description(ThirdPartyProvider p) => switch (p) {
    ThirdPartyProvider.janitor => 'third_party_janitor_desc'.tr(),
    ThirdPartyProvider.janny => 'third_party_janny_desc'.tr(),
    ThirdPartyProvider.datacat => 'third_party_datacat_desc'.tr(),
    ThirdPartyProvider.chub => 'third_party_chub_desc'.tr(),
    ThirdPartyProvider.spicychat => 'Browse SpicyChat characters, recommendations, recent chats, and search.',
    ThirdPartyProvider.crushon => 'Browse CrushOn characters with site sorts, tags, Daily Ranking, and favorites.',
    ThirdPartyProvider.saucepan => 'third_party_saucepan_desc'.tr(),
  };
}

/// Compact switch used in a [MenuGroup] header to enable/disable the group.
class _GroupSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _GroupSwitch({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: value,
      onChanged: (v) {
        Haptics.selectionClick();
        onChanged(v);
      },
      activeThumbColor: context.cs.primary,
      activeTrackColor: context.cs.primary.withValues(alpha: 0.5),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : context.cs.outlineVariant,
      ),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
