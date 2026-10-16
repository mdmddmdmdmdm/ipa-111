import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/character_book_converter.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../core/state/shared_prefs_provider.dart';
import '../../../core/utils/error_format.dart';
import 'catalog_models.dart';
import 'chub_account_provider.dart';
import 'services/datacat/datacat_discovery.dart';
import 'services/datacat/datacat_sort.dart';
import 'services/janitor_provider.dart';
import 'services/janitor_public_lorebook.dart';
import 'services/janny_provider.dart';
import 'services/chub_provider.dart';
import 'services/spicychat_provider.dart';
import 'services/crushon_provider.dart';
import 'crushon_account_provider.dart';
import 'services/unified_favorites_service.dart';
import 'janitor_account_provider.dart';
import 'spicychat_account_provider.dart';
import 'third_party_providers_provider.dart';

const _pageSize = 24;
const _providerKey = 'gz_catalog_provider';
// Legacy global filters key. Filters are now stored per provider under
// '${_filtersKey}_<provider>'; this bare key is only read as a one-time
// fallback so a user's existing selection survives the migration.
const _filtersKey = 'gz_catalog_filters';
const _sortKey = 'gz_catalog_sort';

String _filtersKeyFor(CatalogProvider p) => '${_filtersKey}_${p.name}';

const providerSortDefaults = <CatalogProvider, String>{
  CatalogProvider.all: 'trending',
  CatalogProvider.janitor: 'trending',
  CatalogProvider.janny: 'newest',
  CatalogProvider.datacat: 'fresh',
  CatalogProvider.chub: 'popular',
  CatalogProvider.spicychat: 'trending',
  CatalogProvider.crushon: 'recent_hits',
};

class CatalogState {
  final List<CatalogItem> results;
  final bool loading;
  final String? error;
  final int page;
  final bool hasMore;
  final String query;
  final int total;
  final CatalogProvider activeProvider;
  final CatalogFilters filters;

  /// When true, Discovery shows the signed-in account favorites feed for the
  /// active provider (or a merged feed when [activeProvider] is all).
  final bool favoritesMode;

  /// Where the next page starts, for a provider that pages by cursor rather
  /// than by page number. Reset with the results.
  final int nextOffset;

  /// True while Chub's "Timeline" recommendation feed is selected. The feed is
  /// served from its own endpoint that only reads `nsfw`/`nsfl`, so the UI hides
  /// the query and the other filters while this is set.
  bool get chubTimelineActive =>
      activeProvider == CatalogProvider.chub &&
      filters.sort == 'timeline' &&
      !favoritesMode;

  /// Providers that expose an account favorites feed in this integration.
  static bool supportsFavorites(CatalogProvider p) =>
      p == CatalogProvider.all ||
      p == CatalogProvider.janitor ||
      p == CatalogProvider.chub ||
      p == CatalogProvider.spicychat ||
      p == CatalogProvider.crushon;

  const CatalogState({
    this.results = const [],
    this.loading = false,
    this.error,
    this.page = 1,
    this.hasMore = true,
    this.query = '',
    this.total = 0,
    this.activeProvider = CatalogProvider.janitor,
    this.filters = const CatalogFilters(),
    this.favoritesMode = false,
    this.nextOffset = 0,
  });

  CatalogState copyWith({
    List<CatalogItem>? results,
    bool? loading,
    String? error,
    int? page,
    bool? hasMore,
    String? query,
    int? total,
    CatalogProvider? activeProvider,
    CatalogFilters? filters,
    bool? favoritesMode,
    int? nextOffset,
  }) {
    return CatalogState(
      results: results ?? this.results,
      loading: loading ?? this.loading,
      error: error,
      page: page ?? this.page,
      hasMore: hasMore ?? this.hasMore,
      query: query ?? this.query,
      total: total ?? this.total,
      activeProvider: activeProvider ?? this.activeProvider,
      filters: filters ?? this.filters,
      favoritesMode: favoritesMode ?? this.favoritesMode,
      nextOffset: nextOffset ?? this.nextOffset,
    );
  }
}

/// Fetches one page for [provider]. Injected in tests so the search/epoch
/// logic can be exercised without hitting the real catalog endpoints.
typedef CatalogFetcher =
    Future<CatalogSearchResult> Function(CatalogProvider provider);

class CatalogNotifier extends StateNotifier<CatalogState> {
  final Ref _ref;
  final CatalogFetcher? _fetchOverride;

  /// Epoch of the newest search request. Every reset-search (provider switch,
  /// sort/filter change, new query) bumps it, so a fetch that belonged to a
  /// previous provider/filter set is discarded when it resolves instead of
  /// overwriting the current results. See `docs/rules/race-conditions.md`
  /// Rule 1/4.
  int _searchEpoch = 0;

  /// Provider the user picked most recently, tracked separately from
  /// [CatalogState.activeProvider] because [setProvider] awaits prefs before it
  /// applies. Null until the first explicit pick.
  CatalogProvider? _requestedProvider;

  /// True once the persisted provider/filters have been applied (or skipped
  /// because the user already picked). Until then the enabled-providers
  /// fallback below stays quiet: `state.activeProvider` is still the
  /// constructor default, so a fallback computed from it would fight the
  /// restore — [_loadSavedState] validates the restored provider itself.
  bool _savedStateApplied = false;

  /// [fetchOverride] replaces the real per-provider fetch; tests only.
  CatalogNotifier(this._ref, {this._fetchOverride})
    : super(const CatalogState()) {
    _loadSavedState();
    // If the active provider gets disabled on the content providers screen,
    // fall back to an enabled one so the catalog never shows a hidden source.
    _ref.listen<List<CatalogProvider>>(enabledCatalogProvidersProvider, (
      _,
      enabled,
    ) {
      if (!_savedStateApplied) return;
      // Empty means every provider is disabled — the catalog is hidden, so
      // leave the active provider as-is (it'll be corrected when one is
      // re-enabled).
      if (state.activeProvider != CatalogProvider.all &&
          enabled.isNotEmpty &&
          !enabled.contains(state.activeProvider)) {
        setProvider(enabled.first);
      }
    });
    // A Chub account key unlocks account-scoped results (NSFL). Reload when it
    // changes while Chub is the active source — this also covers the stored key
    // arriving from prefs after the first anonymous search.
    _ref.listen<SpicyChatAccount>(spicyChatAccountProvider, (previous, next) {
      if (previous?.connected == next.connected &&
          previous?.nsfwEnabled == next.nsfwEnabled) {
        return;
      }
      if (!_savedStateApplied || state.activeProvider != CatalogProvider.spicychat) {
        return;
      }
      unawaited(search(reset: true));
    });
    _ref.listen<ChubAccount>(chubAccountProvider, (previous, next) {
      if (previous?.apiKey == next.apiKey && previous?.nsfl == next.nsfl) {
        return;
      }
      if (!_savedStateApplied || state.activeProvider != CatalogProvider.chub) {
        return;
      }
      resetChubTagCache();
      unawaited(search(reset: true));
    });
  }

  Future<void> _loadSavedState() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    if (!mounted) return;
    // The user already picked a provider while prefs were loading — their pick
    // owns the state now, don't restore the saved one over it.
    if (_requestedProvider != null) {
      _savedStateApplied = true;
      return;
    }
    final savedProvider = prefs.getString(_providerKey) ?? 'janitor';
    var provider = CatalogProvider.values.firstWhere(
      (p) => p.name == savedProvider,
      orElse: () => CatalogProvider.janitor,
    );
    // The saved provider may have been disabled on the Third-Party providers
    // screen since it was saved — never restore a hidden source. (An empty list
    // means all are disabled and the catalog is hidden entirely.)
    final enabled = _ref.read(enabledCatalogProvidersProvider);
    if (enabled.isNotEmpty && !enabled.contains(provider)) {
      provider = enabled.first;
    }
    final savedSort =
        prefs.getString('${_sortKey}_${provider.name}') ??
        providerSortDefaults[provider]!;
    final savedFilters = _loadFilters(
      prefs,
      provider,
      allowLegacyFallback: true,
    );

    _savedStateApplied = true;
    state = state.copyWith(
      activeProvider: provider,
      filters: _migrated(provider, savedFilters.copyWith(sort: savedSort)),
    );
    await search(reset: true);
  }

  /// Loads the saved filters for [provider]. Each provider keeps its own tags,
  /// NSFL flag and token range, since the available tags/filters differ per
  /// provider. When [allowLegacyFallback] is set and no per-provider entry
  /// exists, the pre-migration global filters are used once (only for the
  /// provider that was active when they were saved).
  CatalogFilters _loadFilters(
    SharedPreferences prefs,
    CatalogProvider provider, {
    bool allowLegacyFallback = false,
  }) {
    try {
      var saved = prefs.getString(_filtersKeyFor(provider));
      if (saved == null && allowLegacyFallback) {
        saved = prefs.getString(_filtersKey);
      }
      if (saved != null) {
        final json = jsonDecode(saved) as Map<String, dynamic>;
        return CatalogFilters(
          nsfw: json['nsfw'] as bool? ?? false,
          nsfl: json['nsfl'] as bool? ?? false,
          tagIds: (json['tagIds'] as List?)?.cast<int>() ?? [],
          tagNames: (json['tagNames'] as List?)?.cast<String>() ?? [],
          minTokens: json['minTokens'] as int? ?? 29,
          maxTokens: json['maxTokens'] as int? ?? 100000,
          nsfwOnly: json['nsfwOnly'] as bool? ?? false,
          requireImages: json['requireImages'] as bool? ?? false,
          requireLore: json['requireLore'] as bool? ?? false,
          requireCustomPrompt: json['requireCustomPrompt'] as bool? ?? false,
          requireExampleDialogues:
              json['requireExampleDialogues'] as bool? ?? false,
          requireAlternateGreetings:
              json['requireAlternateGreetings'] as bool? ?? false,
          recommendedVerified: json['recommendedVerified'] as bool? ?? false,
          excludeMine: json['excludeMine'] as bool? ?? false,
          inclusiveOr: json['inclusiveOr'] as bool? ?? false,
          minAiRating: json['minAiRating'] as int? ?? 0,
          minTags: json['minTags'] as int? ?? 0,
          window: json['window'] as String? ?? 'all',
        );
      }
    } catch (_) {}
    return const CatalogFilters();
  }

  /// Rewrites a restored DataCat sort that predates the Client API.
  ///
  /// The old keys folded a sort field and a time window into one label
  /// (`score_week`); the API takes them as two parameters. Translating on
  /// restore rather than on every request means the migration happens once and
  /// the persisted value is the new shape from then on.
  CatalogFilters _migrated(CatalogProvider provider, CatalogFilters filters) =>
      provider == CatalogProvider.datacat
      ? DatacatSort.migrate(filters)
      : filters;

  Future<void> _saveState() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setString(_providerKey, state.activeProvider.name);
    await prefs.setString(
      '${_sortKey}_${state.activeProvider.name}',
      state.filters.sort,
    );
    await prefs.setString(
      _filtersKeyFor(state.activeProvider),
      jsonEncode({
        'nsfw': state.filters.nsfw,
        'nsfl': state.filters.nsfl,
        'tagIds': state.filters.tagIds,
        'tagNames': state.filters.tagNames,
        'minTokens': state.filters.minTokens,
        'maxTokens': state.filters.maxTokens,
        'nsfwOnly': state.filters.nsfwOnly,
        'requireImages': state.filters.requireImages,
        'requireLore': state.filters.requireLore,
        'requireCustomPrompt': state.filters.requireCustomPrompt,
        'requireExampleDialogues': state.filters.requireExampleDialogues,
        'requireAlternateGreetings': state.filters.requireAlternateGreetings,
        'recommendedVerified': state.filters.recommendedVerified,
        'excludeMine': state.filters.excludeMine,
        'inclusiveOr': state.filters.inclusiveOr,
        'minAiRating': state.filters.minAiRating,
        'minTags': state.filters.minTags,
        'window': state.filters.window,
      }),
    );
  }

  Future<void> setProvider(CatalogProvider provider) async {
    // Compare against the last *requested* provider, not the applied one: the
    // prefs read below is async, so on two quick picks (A → B → A) the second
    // one would otherwise bail out as "already active" and B would win.
    if (provider == (_requestedProvider ?? state.activeProvider)) return;
    _requestedProvider = provider;
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    // A newer pick superseded this one while prefs loaded.
    if (!mounted || _requestedProvider != provider) return;
    // Each provider carries its own filters (tags, NSFL, token range), so
    // restore this provider's saved selection instead of leaking the previous
    // provider's filters. Sort likewise falls back to the provider default.
    final savedSort =
        prefs.getString('${_sortKey}_${provider.name}') ??
        providerSortDefaults[provider] ??
        'trending';
    final savedFilters = _loadFilters(prefs, provider);
    final keepFavorites =
        state.favoritesMode && CatalogState.supportsFavorites(provider);
    state = state.copyWith(
      activeProvider: provider,
      filters: _migrated(provider, savedFilters.copyWith(sort: savedSort)),
      favoritesMode: keepFavorites,
    );
    unawaited(_saveState());
    unawaited(search(reset: true));
  }

  /// Toggle account favorites feed for the current provider (or merged feed
  /// when active provider is All Providers).
  void setFavoritesMode(bool enabled) {
    if (enabled == state.favoritesMode) return;
    if (enabled && !CatalogState.supportsFavorites(state.activeProvider)) {
      return;
    }
    state = state.copyWith(favoritesMode: enabled);
    search(reset: true);
  }

  void setSort(String sort) {
    var filters = state.filters.copyWith(sort: sort);
    // Timeline is a fixed recommendation feed served by its own endpoint: its
    // query and every filter but nsfw/nsfl never reach it, so switching to it
    // drops those selections instead of leaving dead controls lit.
    if (sort == 'timeline') {
      filters = _stripForTimeline(filters);
    }
    // CrushOn Daily Ranking: always start on the day the SITE opens on (its
    // latest available ranking). The app must not invent a date: today is often
    // not published yet. A specific day is only set by the date chip, which is
    // bounded by what the site reports.
    if ((sort == 'daily_ranking' || sort == 'daily-ranking') &&
        state.activeProvider == CatalogProvider.crushon) {
      filters = filters.copyWith(window: 'all');
    }
    state = state.copyWith(
      filters: filters,
      query: sort == 'timeline' ? '' : state.query,
    );
    _saveState();
    search(reset: true);
  }

  /// Changes the time window a listing is scoped to. Its own action rather
  /// than part of [setFilters] because it reads as a sort choice to the user
  /// and lives next to the sort chip, not in the filter sheet.
  void setWindow(String window) {
    if (window == state.filters.window) return;
    state = state.copyWith(filters: state.filters.copyWith(window: window));
    _saveState();
    search(reset: true);
  }

  void setFilters(CatalogFilters filters) {
    // Timeline ignores everything but nsfw/nsfl; don't let stale selections ride.
    if (state.chubTimelineActive) {
      filters = _stripForTimeline(filters);
    }
    // Chub tag pages use a different sort vocabulary. If the user just added
    // tags while on a home-only windowed trending key, flip to plain trending
    // so the request matches the site's tag-page Trending control.
    if (state.activeProvider == CatalogProvider.chub &&
        filters.tagNames.isNotEmpty) {
      const homeOnly = {'trending_week', 'trending_24h', 'recent_hits'};
      if (homeOnly.contains(filters.sort)) {
        filters = filters.copyWith(sort: 'trending');
      }
    }
    state = state.copyWith(filters: filters);
    _saveState();
    search(reset: true);
  }

  void setQuery(String query) {
    // The Timeline feed ignores free-text search; keep its query pinned empty.
    if (state.chubTimelineActive) return;
    state = state.copyWith(query: query);
  }

  /// The Timeline endpoint reads only `nsfw` and `nsfl`; every other field in
  /// [CatalogFilters] is silently dropped, so reset them instead of carrying
  /// selections the filter sheet no longer exposes.
  CatalogFilters _stripForTimeline(CatalogFilters filters) => filters.copyWith(
    tagIds: const [],
    tagNames: const [],
    excludeTagNames: const [],
    minTokens: 29,
    maxTokens: 100000,
    nsfwOnly: false,
    requireImages: false,
    requireLore: false,
    requireCustomPrompt: false,
    requireExampleDialogues: false,
    requireAlternateGreetings: false,
    recommendedVerified: false,
    excludeMine: false,
    inclusiveOr: false,
    minAiRating: 0,
    minTags: 0,
  );

  Future<void> search({bool reset = false}) async {
    // Pagination must not stack on top of an in-flight page, but a reset search
    // (provider switch, new sort/filters/query) has to win over whatever is
    // loading — otherwise switching provider while the previous one loads is a
    // no-op and the old provider's results land under the new provider's label.
    if (state.loading && !reset) return;

    final epoch = ++_searchEpoch;

    if (reset) {
      state = state.copyWith(
        page: 1,
        results: [],
        hasMore: true,
        error: null,
        nextOffset: 0,
      );
    }

    if (!state.hasMore) return;

    state = state.copyWith(loading: true, error: null);

    try {
      final provider = state.activeProvider;
      if (provider == CatalogProvider.janitor ||
          provider == CatalogProvider.janny) {
        unawaited(fetchJanitorTags().catchError((_) => <CatalogTag>[]));
      }

      final result = await (_fetchOverride ?? _fetchFromProvider)(provider);

      // A newer search superseded this one (or the notifier is gone): drop the
      // result. The newer request owns `loading` and will clear it itself.
      if (!mounted || epoch != _searchEpoch) return;

      final items = result.characters;
      state = state.copyWith(
        results: reset ? items : [...state.results, ...items],
        total: result.total,
        hasMore:
            result.hasMore ??
            (items.isNotEmpty &&
                (state.results.length + items.length) < (result.total)),
        page: state.page + 1,
        nextOffset: result.nextOffset ?? state.nextOffset + items.length,
        loading: false,
      );
    } catch (e) {
      if (!mounted || epoch != _searchEpoch) return;
      state = state.copyWith(loading: false, error: formatError(e));
    }
  }

  Future<CatalogSearchResult> _fetchFromProvider(
    CatalogProvider provider,
  ) async {
    if (state.favoritesMode) {
      return _fetchFavorites(provider);
    }
    if (provider == CatalogProvider.all) {
      return _fetchCombined();
    }
    if (provider == CatalogProvider.spicychat &&
        state.filters.nsfw &&
        !_ref.read(spicyChatAccountProvider).isLoggedIn) {
      throw Exception('Sign in to SpicyChat to enable NSFW discovery.');
    }
    switch (provider) {
      case CatalogProvider.all:
        return _fetchCombined();
      case CatalogProvider.janitor:
        return janitorSearch(
          query: state.query,
          page: state.page,
          filters: state.filters,
        );
      case CatalogProvider.janny:
        return jannySearch(
          query: state.query,
          page: state.page,
          filters: state.filters,
        );
      case CatalogProvider.datacat:
        // Browse and search are the same endpoint now — an empty query is
        // simply an unfiltered listing — so there is no second code path to
        // drift out of sync. Paged by the server's own cursor rather than by
        // multiplying the page number, because DataCat filters after paging.
        return datacatFetchCharacters(
          query: state.query,
          offset: state.nextOffset,
          limit: _pageSize,
          filters: state.filters,
        );
      case CatalogProvider.chub:
        return chubSearch(
          query: state.query,
          page: state.page,
          limit: _pageSize,
          filters: state.filters,
          apiKey: _ref.read(chubAccountProvider).apiKey,
          accountNsfl: _ref.read(chubAccountProvider).nsfl,
        );
      case CatalogProvider.spicychat:
        if (state.filters.sort == 'recommended' || state.filters.sort == 'recent') {
          final path = state.filters.sort == 'recommended' ? '/recommended-bots' : '/chats';
          var rows = await spicyChatWebFeed(path: path, page: state.page);
          // The authenticated web feed can change its card markup. If it is
          // temporarily empty, keep For You/Recent useful instead of showing a
          // misleading zero-result screen. The fallback is the same public
          // catalog with the active tag/NSFW filters applied.
          if (rows.isEmpty && state.filters.sort == 'recommended') {
            final fallback = await spicyChatSearch(
              query: state.query,
              page: state.page,
              filters: state.filters.copyWith(sort: 'trending'),
            );
            rows = fallback.characters;
          }
          return CatalogSearchResult(
            characters: rows.take(_pageSize).toList(),
            total: rows.length,
            hasMore: rows.length >= _pageSize,
          );
        }
        return spicyChatSearch(
          query: state.query,
          page: state.page,
          filters: state.filters,
        );
      case CatalogProvider.crushon:
        return crushonSearch(
          query: state.query,
          page: state.page,
          limit: _pageSize,
          filters: state.filters,
        );
    }
  }


  Future<CatalogSearchResult> _fetchFavorites(CatalogProvider provider) async {
    // First page only for account-scoped feeds that do not paginate cleanly;
    // subsequent pages return empty so the grid stops scrolling.
    if (state.page > 1 &&
        provider != CatalogProvider.janitor &&
        provider != CatalogProvider.spicychat &&
        provider != CatalogProvider.crushon) {
      return CatalogSearchResult(characters: const [], total: 0, hasMore: false);
    }

    switch (provider) {
      case CatalogProvider.all:
        final chub = _ref.read(chubAccountProvider);
        final spicy = _ref.read(spicyChatAccountProvider);
        final janitor = _ref.read(janitorAccountProvider);
        final crushon = _ref.read(crushOnAccountProvider);
        final items = await fetchUnifiedRemoteFavorites(
          chub: chub,
          spicyLoggedIn: spicy.isLoggedIn,
          janitorLoggedIn: janitor.isLoggedIn,
          crushonLoggedIn: crushon.isLoggedIn,
        );
        return CatalogSearchResult(
          characters: items,
          total: items.length,
          hasMore: false,
        );
      case CatalogProvider.janitor:
        if (!_ref.read(janitorAccountProvider).isLoggedIn) {
          throw Exception('Sign in to JanitorAI to view your favorites.');
        }
        return janitorSearch(
          query: state.query,
          page: state.page,
          filters: state.filters,
          favorites: true,
        );
      case CatalogProvider.chub:
        return chubFetchFavorites(apiKey: _ref.read(chubAccountProvider).apiKey);
      case CatalogProvider.spicychat:
        if (!_ref.read(spicyChatAccountProvider).isLoggedIn) {
          throw Exception('Sign in to SpicyChat to view your favorites.');
        }
        final rows = await spicyChatWebFeed(path: '/favorite-bots', page: state.page);
        return CatalogSearchResult(
          characters: rows,
          total: rows.length,
          hasMore: rows.length >= 24,
        );
      case CatalogProvider.crushon:
        // No local sign-in gate: the app's own flag only flips when the
        // sign-in sheet is closed with Done, and loads asynchronously. The site
        // reader checks the real session on the site and reports a sign-in
        // error itself when the hidden browser is signed out.
        // Read from the site's own Favorites section, page by page, in the order
        // picked in the sort chip (the profile only offers Latest / Popular) and
        // with the site's "Unfiltered" switch matching the NSFW filter.
        return crushonFavoritesPage(
          page: state.page,
          sort: state.filters.sort,
          nsfw: state.filters.nsfw,
        );
      case CatalogProvider.janny:
      case CatalogProvider.datacat:
        return CatalogSearchResult(characters: const [], total: 0, hasMore: false);
    }
  }

  Future<CatalogSearchResult> _fetchCombined() async {
    final enabled = _ref.read(enabledCatalogProvidersProvider);
    if (state.filters.nsfw &&
        enabled.contains(CatalogProvider.spicychat) &&
        !_ref.read(spicyChatAccountProvider).isLoggedIn) {
      throw Exception('Sign in to SpicyChat to use NSFW in the combined catalog.');
    }
    if (enabled.isEmpty) {
      return CatalogSearchResult(characters: const [], total: 0, hasMore: false);
    }

    // JannyAI has no reliable shared engagement metrics with the other
    // catalogs, so All Providers never merges it. It remains available as a
    // single-provider choice.
    final combinedEnabled = [
      for (final p in enabled)
        if (p != CatalogProvider.janny) p,
    ];

    final sort = state.filters.sort;
    final sources = switch (sort) {
      'recommended' => <CatalogProvider>[
        if (combinedEnabled.contains(CatalogProvider.spicychat)) CatalogProvider.spicychat,
        if (combinedEnabled.contains(CatalogProvider.chub) &&
            _ref.read(chubAccountProvider).isLoggedIn) CatalogProvider.chub,
      ],
      'recent' => <CatalogProvider>[
        if (combinedEnabled.contains(CatalogProvider.spicychat)) CatalogProvider.spicychat,
      ],
      _ => combinedEnabled,
    };
    if (sources.isEmpty) {
      throw Exception('Enable SpicyChat and sign in to use combined recommendations or recent chats.');
    }

    final results = await Future.wait(
      sources.map((provider) async {
        final filters = state.filters.copyWith(
          sort: _combinedSortFor(provider, sort),
          // Provider-specific refinements cannot safely be interpreted across
          // every service. Combined mode intentionally keeps only the shared
          // discovery filters.
          nsfl: false,
          nsfwOnly: false,
          requireImages: false,
          requireLore: false,
          requireCustomPrompt: false,
          requireExampleDialogues: false,
          requireAlternateGreetings: false,
          recommendedVerified: false,
          excludeMine: false,
          inclusiveOr: false,
          minAiRating: 0,
          minTags: 0,
        );
        try {
          return await _fetchProviderPage(provider, filters);
        } catch (e) {
          // One provider being unavailable should not blank the combined feed.
          // Keep the failure out of the UI and let the remaining providers win.
          debugPrint('Combined catalog: ${provider.name} failed: $e');
          return CatalogSearchResult(characters: const [], total: 0, hasMore: false);
        }
      }),
    );

    var total = 0;
    var hasMore = false;
    for (final result in results) {
      total += result.total;
      hasMore = hasMore || (result.hasMore ?? false);
    }

    // Round-robin by rank index so each provider's #1 (true newest / top
    // trending / etc.) stays near the top. Sorting tied percentiles by name
    // previously scrambled Newest so mid-alphabet cards from one source
    // buried brand-new zero-message cards from another.
    final maxLen = results.fold<int>(
      0,
      (m, r) => r.characters.length > m ? r.characters.length : m,
    );
    final interleaved = <CatalogItem>[];
    final seen = <String>{};
    for (var i = 0; i < maxLen; i++) {
      for (final result in results) {
        if (i >= result.characters.length) continue;
        final item = result.characters[i];
        if (seen.add('${item.source ?? ''}:${item.id}')) {
          interleaved.add(item);
        }
      }
    }

    return CatalogSearchResult(
      characters: interleaved,
      total: total,
      hasMore: hasMore,
    );
  }

  String _combinedSortFor(CatalogProvider provider, String sort) {
    if (sort == 'recommended' && provider == CatalogProvider.chub) return 'timeline';
    if (sort == 'recommended' || sort == 'recent') return sort;
    return switch (provider) {
      CatalogProvider.all => 'trending',
      CatalogProvider.janitor => switch (sort) {
        'popular' => 'popular',
        'latest' => 'latest',
        _ => 'trending',
      },
      CatalogProvider.janny => switch (sort) {
        'latest' => 'newest',
        'popular' => 'tokens_desc',
        _ => 'newest',
      },
      CatalogProvider.datacat => switch (sort) {
        'popular' => 'chat_count',
        'latest' => 'fresh',
        _ => 'score',
      },
      CatalogProvider.chub => switch (sort) {
        'recommended' => 'timeline',
        'popular' => 'popular',
        'latest' => 'latest',
        _ => 'trending_week',
      },
      CatalogProvider.spicychat => switch (sort) {
        'popular' => 'popular',
        'latest' => 'latest',
        _ => 'trending',
      },
      CatalogProvider.crushon => switch (sort) {
        'popular' => 'popular',
        'trending' => 'trending',
        'new' => 'new',
        'latest' => 'new',
        'daily_ranking' => 'daily_ranking',
        'editor_choice' => 'editor_choice',
        'following' => 'following',
        _ => 'recent_hits',
      },
    };
  }

  Future<CatalogSearchResult> _fetchProviderPage(
    CatalogProvider provider,
    CatalogFilters filters,
  ) async {
    switch (provider) {
      case CatalogProvider.all:
        return _fetchCombined();
      case CatalogProvider.janitor:
        return janitorSearch(query: state.query, page: state.page, filters: filters);
      case CatalogProvider.janny:
        return jannySearch(query: state.query, page: state.page, filters: filters);
      case CatalogProvider.datacat:
        return datacatFetchCharacters(
          query: state.query,
          offset: (state.page - 1) * _pageSize,
          limit: _pageSize,
          filters: filters,
        );
      case CatalogProvider.chub:
        return chubSearch(
          query: state.query,
          page: state.page,
          limit: _pageSize,
          filters: filters,
          apiKey: _ref.read(chubAccountProvider).apiKey,
          accountNsfl: _ref.read(chubAccountProvider).nsfl,
        );
      case CatalogProvider.spicychat:
        if (filters.nsfw && !_ref.read(spicyChatAccountProvider).isLoggedIn) {
          throw Exception('Sign in to SpicyChat to enable NSFW discovery.');
        }
        if (filters.sort == 'recommended') {
          final rows = await spicyChatWebFeed(path: '/recommended-bots', page: state.page);
          if (rows.isNotEmpty) {
            return CatalogSearchResult(
              characters: rows.take(_pageSize).toList(),
              total: rows.length,
              hasMore: rows.length >= _pageSize,
            );
          }
          return spicyChatSearch(
            query: state.query,
            page: state.page,
            filters: filters.copyWith(sort: 'trending'),
          );
        }
        if (filters.sort == 'recent') {
          return _spicyWebResult('/chats');
        }
        return spicyChatSearch(query: state.query, page: state.page, filters: filters);
      case CatalogProvider.crushon:
        return crushonSearch(
          query: state.query,
          page: state.page,
          limit: _pageSize,
          filters: filters,
        );
    }
  }

  Future<CatalogSearchResult> _spicyWebResult(String path) async {
    final rows = await spicyChatWebFeed(path: path, page: state.page);
    return CatalogSearchResult(
      characters: rows,
      total: rows.length,
      hasMore: rows.length >= _pageSize,
    );
  }

  Future<void> loadMore() async {
    await search(reset: false);
  }

  Future<String> importCharacter(
    DownloadedCharacter downloaded, {
    String? sourceUrl,
    bool attachLorebooks = false,
    Map<String, dynamic>? janitorMeta,
  }) async {
    final charRepo = _ref.read(characterRepoProvider);
    final imageStorage = await _ref.read(imageStorageProvider.future);
    final lorebooks = _ref.read(lorebooksProvider.notifier);

    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final charData = downloaded.charData;

    String? avatarPath;
    // A source whose image endpoint needs the same credentials as the card
    // hands the bytes over with it — they cannot be re-fetched from a bare URL
    // afterwards, so they are saved rather than re-downloaded.
    final carriedBytes = downloaded.avatarBytes;
    if (carriedBytes != null && carriedBytes.isNotEmpty) {
      try {
        avatarPath = await imageStorage.saveAvatar(
          id,
          Uint8List.fromList(carriedBytes),
        );
      } catch (_) {}
    } else if (downloaded.avatarUrl != null) {
      try {
        final bytes = await _fetchImageBytes(downloaded.avatarUrl!);
        avatarPath = await imageStorage.saveAvatar(id, bytes);
      } catch (_) {}
    }

    await charRepo.createCharacterFromCatalog(
      id: id,
      name: charData.name,
      description: charData.description,
      personality: charData.personality,
      scenario: charData.scenario,
      firstMes: charData.firstMes,
      mesExample: charData.mesExample,
      creatorNotes: charData.creatorNotes,
      systemPrompt: charData.systemPrompt,
      postHistoryInstructions: charData.postHistoryInstructions,
      alternateGreetings: charData.alternateGreetings,
      tags: charData.tags,
      creator: charData.creator,
      creatorId: charData.creatorId,
      avatarPath: avatarPath,
      sourceUrl: sourceUrl,
    );

    if (charData.characterBook is Map) {
      final book = Map<String, dynamic>.from(charData.characterBook as Map);
      final lorebook = convertCharacterBook(book, id);
      debugPrint(
        '[character_import] catalog saving_lorebook id=${lorebook.id} '
        'name=${lorebook.name} entries=${lorebook.entries.length} '
        'character=$id',
      );
      await lorebooks.put(lorebook);
    } else {
      debugPrint(
        '[character_import] catalog no_lorebook character=$id '
        'book_type=${charData.characterBook.runtimeType}',
      );
    }

    // When the user opted to import the character *with* its attached lorebooks,
    // download the character's public (JSON) lorebooks and save them scoped to
    // the new character. Private/closed and advanced (JS) lorebooks can't be
    // pulled whole — those still go through the Lorebooks tab's Extract/Build
    // flow. A lorebook failure never blocks the character import.
    if (attachLorebooks && janitorMeta != null) {
      try {
        final books = await fetchPublicLorebooks(janitorMeta);
        for (final book in books) {
          if (!book.accessible || book.entryCount == 0) continue;
          final lorebook = book.toLorebook(characterId: id);
          debugPrint(
            '[character_import] catalog saving_attached_lorebook '
            'id=${lorebook.id} name=${lorebook.name} '
            'entries=${lorebook.entries.length} character=$id',
          );
          await lorebooks.put(lorebook);
        }
      } catch (e) {
        debugPrint(
          '[character_import] attach_lorebooks_failed character=$id error=$e',
        );
      }
    }

    return id;
  }

  Future<Uint8List> _fetchImageBytes(String url) async {
    final dio = Dio();
    final res = await dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(res.data ?? []);
  }

  void resetFilters() {
    final defaultSort =
        providerSortDefaults[state.activeProvider] ?? 'trending';
    state = state.copyWith(filters: CatalogFilters(sort: defaultSort));
    _saveState();
    search(reset: true);
  }
}

class _CombinedRank {
  final CatalogItem item;
  final double score;
  const _CombinedRank(this.item, this.score);
}

final catalogProvider = StateNotifierProvider<CatalogNotifier, CatalogState>((
  ref,
) {
  return CatalogNotifier(ref);
});
