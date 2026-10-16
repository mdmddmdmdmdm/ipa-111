import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/list_controls.dart';
import '../catalog_models.dart';
import '../catalog_provider.dart';
import '../services/crushon_provider.dart' show crushonFavoritesSortKey;
import '../services/crushon_site_reader.dart'
    show CrushOnDailyInfo, crushOnDailyInfo;
import '../third_party_providers_provider.dart';
import 'catalog_filter_sheet.dart';
import 'datacat/datacat_sort_sheet.dart';
import 'provider_logo.dart';
import 'third_party_providers_screen.dart';

import 'package:easy_localization/easy_localization.dart';
import '../../../shared/widgets/glaze_sheet.dart';

class CatalogControls extends ConsumerWidget {
  final CatalogState state;
  final CatalogNotifier notifier;

  const CatalogControls({
    super.key,
    required this.state,
    required this.notifier,
  });

  static String providerLabel(CatalogProvider p) => switch (p) {
    CatalogProvider.all => 'All Providers',
    CatalogProvider.janitor => 'catalog_provider_janitor_label'.tr(),
    CatalogProvider.janny => 'catalog_provider_janny_label'.tr(),
    CatalogProvider.datacat => 'catalog_provider_datacat_label'.tr(),
    CatalogProvider.chub => 'catalog_provider_chub_label'.tr(),
    CatalogProvider.spicychat => 'catalog_provider_spicychat_label'.tr(),
    CatalogProvider.crushon => 'catalog_provider_crushon_label'.tr(),
  };

  static Map<String, String> sortOptionsForProvider(CatalogProvider p, {bool chubHasTags = false, bool favoritesMode = false}) {
    if (favoritesMode && p == CatalogProvider.crushon) {
      // Favorites feed only supports popular + latest (site limitation).
      return {
        'popular': 'catalog_sort_crushon_popular'.tr(),
        'new': 'catalog_sort_crushon_new'.tr(),
      };
    }
    return switch (p) {
        CatalogProvider.all => {
          'trending': 'Trending',
          'popular': 'Popular',
          'latest': 'Newest',
          'recommended': 'Recommended',
          'recent': 'Recent',
        },
        CatalogProvider.janitor => {
          'trending': 'catalog_sort_janitor_trending'.tr(),
          'trending_24h': 'catalog_sort_janitor_trending24'.tr(),
          'popular': 'catalog_sort_janitor_popular'.tr(),
          'latest': 'catalog_sort_janitor_latest'.tr(),
        },
        CatalogProvider.janny => {
          'newest': 'catalog_sort_janny_newest'.tr(),
          'oldest': 'catalog_sort_janny_oldest'.tr(),
          'tokens_desc': 'catalog_sort_janny_tokens_desc'.tr(),
          'tokens_asc': 'catalog_sort_janny_tokens_asc'.tr(),
          'relevant': 'catalog_sort_janny_relevant'.tr(),
        },
        // The five sort fields the Client API accepts. The time window is a
        // second choice in the same picker, so every field can be combined with
        // every window instead of only the four pairings the old labels named.
        CatalogProvider.datacat => datacatSortOptions(),
        CatalogProvider.chub => chubHasTags
            ? {
                'timeline': 'catalog_sort_chub_timeline'.tr(),
                'trending': 'catalog_sort_chub_trending'.tr(),
                'popular': 'catalog_sort_chub_popularity'.tr(),
                'rating_avg': 'catalog_sort_chub_ai_rating'.tr(),
                'msgs_total': 'catalog_sort_chub_msgs_total'.tr(),
                'msgs_chat': 'catalog_sort_chub_msgs_chat'.tr(),
                'user_count': 'catalog_sort_chub_chats_user'.tr(),
                'latest': 'catalog_sort_chub_latest'.tr(),
                'updated': 'catalog_sort_chub_updated'.tr(),
              }
            : {
                'timeline': 'catalog_sort_chub_timeline'.tr(),
                'popular': 'catalog_sort_chub_popular'.tr(),
                'trending_week': 'catalog_sort_chub_trending_week'.tr(),
                'recent_hits': 'catalog_sort_chub_recent_hits'.tr(),
                'trending_24h': 'catalog_sort_chub_trending_24h'.tr(),
                'latest': 'catalog_sort_chub_latest'.tr(),
                'rating': 'catalog_sort_chub_rating'.tr(),
                'updated': 'catalog_sort_chub_updated'.tr(),
              },
        CatalogProvider.spicychat => {
          'recommended': 'catalog_sort_spicychat_recommended'.tr(),
          'trending': 'catalog_sort_spicychat_trending'.tr(),
          'popular': 'catalog_sort_spicychat_popular'.tr(),
          'latest': 'catalog_sort_spicychat_latest'.tr(),
          'recent': 'catalog_sort_spicychat_recent'.tr(),
        },
        CatalogProvider.crushon => {
          'popular': 'catalog_sort_crushon_popular'.tr(),
          'recent_hits': 'catalog_sort_crushon_recent_hits'.tr(),
          'trending': 'catalog_sort_crushon_trending'.tr(),
          'new': 'catalog_sort_crushon_new'.tr(),
          'daily_ranking': 'catalog_sort_crushon_daily_ranking'.tr(),
          'editor_choice': 'catalog_sort_crushon_editor_choice'.tr(),
          'following': 'catalog_sort_crushon_following'.tr(),
        },
      };
  }

  /// Whether this provider can filter by token count. DataCat's API takes no
  /// token bounds, so the slider is hidden there rather than quietly ignored.
  static bool supportsTokenRange(CatalogProvider p) =>
      p != CatalogProvider.datacat && p != CatalogProvider.all;

  int _activeFilterCount() {
    final f = state.filters;
    int count = 0;
    if (f.nsfw) count++;
    // NSFL is a chub-only filter (its toggle is only shown for chub in the
    // filter sheet), so only count it for the current provider — otherwise a
    // leftover NSFL flag from chub would inflate the badge on janitor et al.
    if (state.activeProvider == CatalogProvider.chub && f.nsfl) count++;
    // Prefer unique tag selections: ids and names may both be set for the same
    // tag in All Providers mode, so count the larger of the two sets rather
    // than summing them.
    final tagCount = f.tagIds.length > f.tagNames.length
        ? f.tagIds.length
        : f.tagNames.length;
    if (tagCount > 0) count += tagCount;
    // Only counted where the filter exists — a leftover token range from
    // another provider must not badge a provider that cannot apply it.
    if (supportsTokenRange(state.activeProvider)) {
      if (f.minTokens != 29) count++;
      if (f.maxTokens != 100000) count++;
    }
    // The Chub-only refinements share the same rule as NSFL: they only apply to
    // chub, so they only count toward chub's badge.
    if (state.activeProvider == CatalogProvider.chub) {
      if (f.nsfwOnly) count++;
      if (f.requireImages) count++;
      if (f.requireLore) count++;
      if (f.requireCustomPrompt) count++;
      if (f.requireExampleDialogues) count++;
      if (f.requireAlternateGreetings) count++;
      if (f.recommendedVerified) count++;
      if (f.excludeMine) count++;
      if (f.inclusiveOr) count++;
      if (f.minAiRating > 0) count++;
      if (f.minTags > 0) count++;
    }
    return count;
  }

  /// The sort the current feed is really using. CrushOn Favorites only has the
  /// profile's Latest / Popular, so any other saved sort (Trending, Daily
  /// Ranking...) is shown, and fetched, as Latest.
  String _activeSortKey() {
    if (state.activeProvider == CatalogProvider.crushon && state.favoritesMode) {
      return crushonFavoritesSortKey(state.filters.sort);
    }
    return state.filters.sort;
  }

  String _currentSortLabel() {
    if (state.activeProvider == CatalogProvider.datacat) {
      return datacatSortOptions()[state.filters.sort] ?? state.filters.sort;
    }
    final opts = sortOptionsForProvider(
      state.activeProvider,
      chubHasTags: state.activeProvider == CatalogProvider.chub &&
          state.filters.tagNames.isNotEmpty,
      favoritesMode: state.favoritesMode,
    );
    final key = _activeSortKey();
    return opts[key] ?? key;
  }

  // Icon per sort-mode key, shared across providers since the same key
  // (e.g. 'latest', 'popular') always carries the same meaning. DataCat's own
  // fields live with its combined picker in [datacat_sort_sheet.dart].
  static const Map<String, IconData> _sortIcons = {
    'trending': Icons.trending_up_rounded,
    'trending_week': Icons.trending_up_rounded,
    'trending_24h': Icons.local_fire_department_rounded,
    'recent_hits': Icons.whatshot_rounded,
    'popular': Icons.star_rounded,
    'latest': Icons.schedule_rounded,
    'newest': Icons.schedule_rounded,
    'new': Icons.schedule_rounded,
    'oldest': Icons.history_rounded,
    'tokens_desc': Icons.arrow_downward_rounded,
    'tokens_asc': Icons.arrow_upward_rounded,
    'relevant': Icons.auto_awesome_rounded,
    'rating': Icons.thumb_up_rounded,
    'updated': Icons.update_rounded,
    'timeline': Icons.timeline_rounded,
    'recommended': Icons.auto_awesome_rounded,
    'recent': Icons.history_rounded,
    'daily_ranking': Icons.emoji_events_rounded,
    'editor_choice': Icons.verified_rounded,
    'following': Icons.people_alt_rounded,
  };

  static IconData sortIconForKey(String key) =>
      _sortIcons[key] ?? Icons.sort_rounded;

  IconData _currentSortIcon() {
    if (state.activeProvider == CatalogProvider.datacat) {
      return datacatSortIconFor(state.filters.sort);
    }
    return sortIconForKey(_activeSortKey());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabledProviders = ref.watch(enabledCatalogProvidersProvider);
    // The DataCat chip shows the window as its text, so resolve its label once.
    final datacatWindowLabel = state.activeProvider == CatalogProvider.datacat
        ? datacatWindowOptions()[state.filters.window] ?? state.filters.window
        : '';
    final supportsFavorites =
        CatalogState.supportsFavorites(state.activeProvider);
    // Two groups pushed to opposite edges when everything fits, and a plain
    // horizontal scroll when it does not. (The old Row used a Spacer inside an
    // unbounded scroll view, which pushed the right-hand chips off-screen where
    // they could not be reached.)
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
        GlazeDropdownChip(
          label: providerLabel(state.activeProvider),
          leading: ProviderLogo.catalog(provider: state.activeProvider),
          onTap: () => showGlazePickerSheet(
            context,
            title: 'blacklist_glossary_chip'.tr(),
            items: [
              if (enabledProviders.length > 1)
                GlazePickerItem(
                  label: providerLabel(CatalogProvider.all),
                  isActive: state.activeProvider == CatalogProvider.all,
                  value: CatalogProvider.all,
                  icon: Icons.apps_rounded,
                  // Janny has no shared engagement metric with the others and
                  // is intentionally left out of the merged feed.
                  hint: 'catalog_all_providers_excludes_janny'.tr(),
                ),
              ...enabledProviders.map(
                (p) => GlazePickerItem(
                  label: providerLabel(p),
                  isActive: p == state.activeProvider,
                  value: p,
                  iconWidget: ProviderLogo.catalog(provider: p, size: 20),
                ),
              ),
            ],
            onSelect: (v) => notifier.setProvider(v as CatalogProvider),
            headerAction: _SettingsGearButton(
              onTap: () {
                Navigator.of(context, rootNavigator: true).pop();
                openThirdPartyProvidersScreen(context);
              },
            ),
          ),
        ),
        if (supportsFavorites) ...[
          const SizedBox(width: 8),
          _FavoritesModeChip(
            active: state.favoritesMode,
            onTap: () => notifier.setFavoritesMode(!state.favoritesMode),
          ),
        ],
        ]),
        const SizedBox(width: 12),
        Row(mainAxisSize: MainAxisSize.min, children: [
        GlazeFilterIconButton(
          count: _activeFilterCount(),
          onTap: () => showGlazeSheet<void>(
            context: context,
            isScrollControlled: true,
            useRootNavigator: true,
            useSafeArea: true,
            backgroundColor: Colors.transparent,
            builder: (_) => CatalogFilterSheet(
              filters: state.filters,
              provider: state.activeProvider,
              timelineMode: state.chubTimelineActive,
              onApply: (f) => notifier.setFilters(f),
              onBlockedTagsChanged: () => notifier.search(reset: true),
            ),
          ),
        ),
        if (state.activeProvider == CatalogProvider.datacat) ...[
          const SizedBox(width: 8),
          // One chip for the whole listing order: the sort field's icon and the
          // time window's text, both edited in the same sheet.
          GlazeActionChip(
            icon: _currentSortIcon(),
            label: datacatWindowLabel,
            tooltip: '${_currentSortLabel()} · $datacatWindowLabel',
            onTap: () => showDatacatSortSheet(
              context,
              filters: state.filters,
              onSort: notifier.setSort,
              onWindow: notifier.setWindow,
            ),
          ),
        ] else ...[
          const SizedBox(width: 8),
          GlazeSortIconChip(
            icon: _currentSortIcon(),
            tooltip: _currentSortLabel(),
            onTap: () => showGlazePickerSheet(
              context,
              title: 'sort_by'.tr(),
              items: sortOptionsForProvider(
                    state.activeProvider,
                    chubHasTags: state.activeProvider == CatalogProvider.chub &&
                        state.filters.tagNames.isNotEmpty,
                    favoritesMode: state.favoritesMode,
                  ).entries
                  .map(
                    (e) => GlazePickerItem(
                      label: e.value,
                      // In CrushOn Favorites any other saved sort (Trending, Daily
                      // Ranking...) means the site's default, Latest.
                      isActive: e.key == _activeSortKey(),
                      value: e.key,
                      icon: sortIconForKey(e.key),
                    ),
                  )
                  .toList(),
              onSelect: (v) => notifier.setSort(v as String),
            ),
          ),
        ],
        // CrushOn Daily Ranking: date chip so the ranking day can be changed
        // (matches the calendar control on crushon.ai).
        if (state.activeProvider == CatalogProvider.crushon &&
            (state.filters.sort == 'daily_ranking' ||
                state.filters.sort == 'daily-ranking')) ...[
          // Shows the date the SITE is showing (read from crushon.ai itself),
          // and only appears when the site actually has a date control.
          ValueListenableBuilder<CrushOnDailyInfo>(
            valueListenable: crushOnDailyInfo,
            builder: (context, info, _) {
              if (!info.hasControl) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(left: 8),
                child: _CrushOnDailyDateChip(
                  info: info,
                  onPick: (iso) => notifier.setWindow(iso),
                ),
              );
            },
          ),
        ],
        ]),
      ],
    );

    // Horizontally scrollable so Daily Ranking date chip and extra icons
    // remain reachable on narrow phones (they were clipped off the right).
    final scrollable = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: MediaQuery.sizeOf(context).width - 32),
        child: row,
      ),
    );
    // One backdrop capture for the row instead of one per chip: these are
    // plain siblings that never overlap. See [GlassBackdropGroup].
    return GlassBackdropGroup(child: scrollable);
  }
}

/// Gear button pinned to the provider-picker sheet header; opens the
/// content providers screen where sources can be enabled/disabled.
class _SettingsGearButton extends StatelessWidget {
  final VoidCallback onTap;

  const _SettingsGearButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(Icons.settings_outlined, size: 22, color: context.cs.primary),
      tooltip: 'third_party_providers_title'.tr(),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Oval chip next to the provider selector that toggles the account favorites
/// feed for the current provider (or the merged All Providers favorites).
class _FavoritesModeChip extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;

  const _FavoritesModeChip({required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final primary = context.cs.primary;
    return Tooltip(
      message: active ? 'Show all characters' : 'Show favorites',
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          height: 32,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: active
                  ? primary.withValues(alpha: 0.85)
                  : context.cs.surface.withValues(alpha: 0.55),
              border: Border.all(
                color: active
                    ? primary
                    : primary.withValues(alpha: 0.22),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  active ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  size: 16,
                  color: active ? Colors.white : primary,
                ),
                const SizedBox(width: 6),
                Text(
                  'Favorites',
                  style: TextStyle(
                    color: active ? Colors.white : primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Date chip for CrushOn Daily Ranking. The label is what the site itself
/// displays; the picker is bounded by the range the site reports, so it never
/// offers a day the site does not have.
class _CrushOnDailyDateChip extends StatelessWidget {
  final CrushOnDailyInfo info;
  final ValueChanged<String> onPick;

  const _CrushOnDailyDateChip({required this.info, required this.onPick});

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final primary = context.cs.primary;
    final label = info.label.trim().isEmpty ? 'Date' : info.label.trim();
    return Tooltip(
      message: 'catalog_crushon_daily_date_tooltip'.tr(),
      child: GestureDetector(
        onTap: () async {
          final now = DateTime.now();
          final shown = DateTime.tryParse(info.iso ?? '');
          var last = DateTime.tryParse(info.maxIso ?? '') ?? shown ?? now;
          var first = DateTime.tryParse(info.minIso ?? '') ??
              last.subtract(const Duration(days: 60));
          if (first.isAfter(last)) first = last;
          var initial = shown ?? last;
          if (initial.isBefore(first)) initial = first;
          if (initial.isAfter(last)) initial = last;
          final picked = await showDatePicker(
            context: context,
            initialDate: initial,
            firstDate: first,
            lastDate: last,
            helpText: 'catalog_crushon_daily_date_help'.tr(),
          );
          if (picked == null) return;
          onPick(_iso(picked));
        },
        child: SizedBox(
          height: 32,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: context.cs.surface.withValues(alpha: 0.55),
              border: Border.all(color: primary.withValues(alpha: 0.22)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.calendar_today_rounded, size: 15, color: primary),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
