import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/character.dart';
import '../../../core/utils/platform_paths.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_sheet.dart';
import '../../settings/app_settings_provider.dart';
import '../catalog_models.dart';
import '../chub_account_provider.dart';
import '../services/unified_favorites_service.dart';
import '../spicychat_account_provider.dart';
import 'catalog_card_grid.dart';
import 'catalog_detail_launcher.dart';

class CombinedFavoritesGrid extends ConsumerStatefulWidget {
  final List<Character> localFavorites;
  final double topPadding;
  final double bottomPadding;

  const CombinedFavoritesGrid({
    super.key,
    required this.localFavorites,
    required this.topPadding,
    required this.bottomPadding,
  });

  @override
  ConsumerState<CombinedFavoritesGrid> createState() =>
      _CombinedFavoritesGridState();
}

enum _FavoriteSource { all, glaze, chub, spicychat }

class _CombinedFavoritesGridState extends ConsumerState<CombinedFavoritesGrid> {
  _FavoriteSource _source = _FavoriteSource.all;
  List<CatalogItem> _remote = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant CombinedFavoritesGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.localFavorites.length != widget.localFavorites.length) {
      setState(() {});
    }
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final chub = ref.read(chubAccountProvider);
    final spicy = ref.read(spicyChatAccountProvider);
    final remote = await fetchUnifiedRemoteFavorites(
      chub: chub,
      spicyLoggedIn: spicy.isLoggedIn,
      janitorLoggedIn: false, // optional; discovery favorites path is preferred
    );
    if (!mounted) return;
    setState(() {
      _remote = remote;
      _loading = false;
    });
  }

  List<CatalogItem> _localItems() => widget.localFavorites.map((c) {
        final path = c.avatarPath;
        return CatalogItem(
          id: c.id,
          name: c.displayName?.trim().isNotEmpty == true
              ? c.displayName!.trim()
              : c.name,
          avatarUrl: path == null ? null : resolveGlazeThumbnailPath(path) ?? path,
          description: c.description,
          tags: c.tags,
          tokens: c.tokenCount,
          creator: c.creator,
          nsfw: c.tags.any((t) => t.toLowerCase() == 'nsfw'),
          source: 'glaze',
          sourceKind: 'local',
        );
      }).toList();

  List<CatalogItem> get _visible {
    final local = _localItems();
    return switch (_source) {
      _FavoriteSource.all => [...local, ..._remote],
      _FavoriteSource.glaze => local,
      _FavoriteSource.chub => _remote.where((x) => x.source == 'chub').toList(),
      _FavoriteSource.spicychat =>
        _remote.where((x) => x.source == 'spicychat').toList(),
    };
  }

  bool get _hasChub => ref.watch(chubAccountProvider).isLoggedIn;
  bool get _hasSpicy => ref.watch(spicyChatAccountProvider).isLoggedIn;

  String _label(_FavoriteSource source) => switch (source) {
    _FavoriteSource.all => 'All Favorites',
    _FavoriteSource.glaze => 'Glaze',
    _FavoriteSource.chub => 'Chub',
    _FavoriteSource.spicychat => 'SpicyChat',
  };

  Future<void> _open(CatalogItem item) async {
    if (item.source == 'glaze') {
      context.go('/characters?open=${Uri.encodeQueryComponent(item.id)}');
      return;
    }
    final imported = await showGlazeSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CatalogDetailLauncher(
        item: item,
        provider: item.source == 'chub'
            ? CatalogProvider.chub
            : CatalogProvider.spicychat,
      ),
    );
    if (!mounted || imported == null || imported.isEmpty) return;
    final openCard =
        ref.read(appSettingsProvider).value?.openCardAfterImport ?? true;
    if (openCard) {
      context.go('/characters?open=${Uri.encodeQueryComponent(imported)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ChubAccount>(chubAccountProvider, (_, __) => _refresh());
    ref.listen<SpicyChatAccount>(spicyChatAccountProvider, (_, __) => _refresh());
    final items = _visible;
    final hasRemoteAccount = _hasChub || _hasSpicy;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: SizedBox(height: widget.topPadding)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Row(
                children: [
                  Text(
                    'Favorites',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: context.cs.onSurface,
                    ),
                  ),
                  const Spacer(),
                  PopupMenuButton<_FavoriteSource>(
                    initialValue: _source,
                    onSelected: (value) => setState(() => _source = value),
                    itemBuilder: (_) => [
                      for (final source in [
                        _FavoriteSource.all,
                        _FavoriteSource.glaze,
                        if (_hasChub) _FavoriteSource.chub,
                        if (_hasSpicy) _FavoriteSource.spicychat,
                      ])
                        PopupMenuItem(
                          value: source,
                          child: Row(
                            children: [
                              Icon(
                                source == _FavoriteSource.all
                                    ? Icons.apps_rounded
                                    : Icons.favorite_rounded,
                                size: 18,
                              ),
                              const SizedBox(width: 10),
                              Text(_label(source)),
                            ],
                          ),
                        ),
                    ],
                    child: Chip(
                      avatar: const Icon(Icons.favorite_rounded, size: 16),
                      label: Text(_label(_source)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!hasRemoteAccount)
            const SliverToBoxAdapter(child: SizedBox.shrink()),
          if (_loading && items.isEmpty)
            SliverFillRemaining(
              child: Center(child: GlazeSpinner(color: context.cs.primary)),
            )
          else if (items.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Text(
                  'No favorites here yet.',
                  style: TextStyle(color: context.cs.onSurfaceVariant),
                ),
              ),
            )
          else
            CatalogCardGridSliver(
              items: items,
              padding: EdgeInsets.fromLTRB(16, 0, 16, widget.bottomPadding),
              onTap: _open,
              showSourceBadge: true,
            ),
          if (_loading && items.isNotEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}
