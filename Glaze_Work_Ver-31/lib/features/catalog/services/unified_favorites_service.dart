import '../catalog_models.dart';
import '../chub_account_provider.dart';
import 'chub_provider.dart';
import 'janitor_provider.dart';
import 'spicychat_provider.dart';
import 'crushon_provider.dart';

/// Fetches remote favorites from providers that expose an account-scoped
/// favorites feed through the integrations already used by Glaze.
///
/// Supported sources: Chub, SpicyChat, JanitorAI, and CrushOn (when signed in).
/// Janny/DataCat do not currently expose a stable favorites API here.
Future<List<CatalogItem>> fetchUnifiedRemoteFavorites({
  required ChubAccount chub,
  required bool spicyLoggedIn,
  bool janitorLoggedIn = false,
  bool crushonLoggedIn = false,
}) async {
  final out = <CatalogItem>[];

  if (chub.isLoggedIn) {
    try {
      final result = await chubFetchFavorites(apiKey: chub.apiKey);
      out.addAll(result.characters);
    } catch (_) {}
  }

  if (spicyLoggedIn) {
    try {
      // The authenticated page is an infinite-scroll feed. Ask for a few
      // progressively deeper pages and deduplicate below so a large favorites
      // library is useful without an unbounded scrape.
      for (var page = 1; page <= 4; page++) {
        final rows = await spicyChatWebFeed(path: '/favorite-bots', page: page);
        out.addAll(rows);
        if (rows.length < 24) break;
      }
    } catch (_) {}
  }

  if (janitorLoggedIn) {
    try {
      for (var page = 1; page <= 4; page++) {
        final result = await janitorSearch(
          page: page,
          favorites: true,
        );
        out.addAll(result.characters);
        if (result.characters.length < 24) break;
      }
    } catch (_) {}
  }

  if (crushonLoggedIn) {
    try {
      for (var page = 1; page <= 4; page++) {
        final rows = await crushonFetchFavorites(page: page);
        out.addAll(rows);
        if (rows.length < 24) break;
      }
    } catch (_) {}
  }

  final seen = <String>{};
  return out.where((item) => seen.add('${item.source}:${item.id}')).toList();
}
