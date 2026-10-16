# CrushOn.AI integration — wiring guide (Glaze)

Copy the new files under `lib/features/catalog/` into your tree, then apply
the small edits below. After that:

```bash
dart run build_runner build --delete-conflicting-outputs   # only if you touch freezed models
flutter pub get
```

No freezed model fields were added — daily ranking date reuses
`CatalogFilters.window` as `YYYY-MM-DD`.

---

## 1. New files (copy as-is)

```
lib/features/catalog/services/crushon_provider.dart
lib/features/catalog/services/crushon_session.dart
lib/features/catalog/crushon_account_provider.dart
lib/features/catalog/widgets/crushon_login_sheet.dart
```

Optional: drop a logo at `assets/logos/providers/crushon.png` and register it
in `pubspec.yaml` if not already covered by a glob.

---

## 2. `lib/features/catalog/catalog_models.dart`

```dart
// BEFORE
enum CatalogProvider { all, janitor, janny, datacat, chub, spicychat }

// AFTER
enum CatalogProvider { all, janitor, janny, datacat, chub, spicychat, crushon }
```

---

## 3. `lib/features/catalog/third_party_providers_provider.dart`

```dart
// BEFORE
enum ThirdPartyProvider { janitor, janny, datacat, chub, spicychat, saucepan }

// AFTER
enum ThirdPartyProvider { janitor, janny, datacat, chub, spicychat, crushon, saucepan }
```

Update both extension switches:

```dart
extension ThirdPartyProviderX on ThirdPartyProvider {
  CatalogProvider? get catalogProvider => switch (this) {
    ThirdPartyProvider.janitor => CatalogProvider.janitor,
    ThirdPartyProvider.janny => CatalogProvider.janny,
    ThirdPartyProvider.datacat => CatalogProvider.datacat,
    ThirdPartyProvider.chub => CatalogProvider.chub,
    ThirdPartyProvider.spicychat => CatalogProvider.spicychat,
    ThirdPartyProvider.crushon => CatalogProvider.crushon,   // NEW
    ThirdPartyProvider.saucepan => null,
  };
}

extension CatalogProviderX on CatalogProvider {
  ThirdPartyProvider? get thirdPartyProvider => switch (this) {
    CatalogProvider.janitor => ThirdPartyProvider.janitor,
    CatalogProvider.janny => ThirdPartyProvider.janny,
    CatalogProvider.datacat => ThirdPartyProvider.datacat,
    CatalogProvider.chub => ThirdPartyProvider.chub,
    CatalogProvider.spicychat => ThirdPartyProvider.spicychat,
    CatalogProvider.crushon => ThirdPartyProvider.crushon,   // NEW
    CatalogProvider.all => null,
  };
}
```

Default disabled set (optional — leave CrushOn disabled until the user enables it):

```dart
return {
  ThirdPartyProvider.janny,
  ThirdPartyProvider.datacat,
  ThirdPartyProvider.chub,
  ThirdPartyProvider.crushon,  // opt-in by default
};
```

Also update any `displayName` / icon switch for the providers screen:

```dart
ThirdPartyProvider.crushon => 'CrushOn',
```

---

## 4. `lib/features/catalog/catalog_provider.dart`

### Imports

```dart
import 'services/crushon_provider.dart';
import 'crushon_account_provider.dart';
```

### Default sort

```dart
const providerSortDefaults = <CatalogProvider, String>{
  CatalogProvider.all: 'trending',
  CatalogProvider.janitor: 'trending',
  CatalogProvider.janny: 'newest',
  CatalogProvider.datacat: 'fresh',
  CatalogProvider.chub: 'popular',
  CatalogProvider.spicychat: 'trending',
  CatalogProvider.crushon: 'recent_hits',  // NEW — matches site default
};
```

### Favorites support

```dart
static bool supportsFavorites(CatalogProvider p) =>
    p == CatalogProvider.all ||
    p == CatalogProvider.janitor ||
    p == CatalogProvider.chub ||
    p == CatalogProvider.spicychat ||
    p == CatalogProvider.crushon;  // NEW
```

### `_fetchFromProvider` switch — add case

```dart
case CatalogProvider.crushon:
  return crushonSearch(
    query: state.query,
    page: state.page,
    limit: _pageSize,
    filters: state.filters,
  );
```

### `_fetchFavorites` switch — add case

```dart
case CatalogProvider.crushon:
  if (!_ref.read(crushOnAccountProvider).isLoggedIn) {
    throw Exception('Sign in to CrushOn to view your favorites.');
  }
  final rows = await crushonFetchFavorites(page: state.page);
  return CatalogSearchResult(
    characters: rows,
    total: rows.length,
    hasMore: rows.length >= _pageSize,
  );
```

### Tag loading (wherever SpicyChat tags are merged)

```dart
// After spicyChat tags are collected:
if (enabled.contains(CatalogProvider.crushon)) {
  final crushonTags = await fetchCrushonTags();
  // merge into the shared vocabulary the same way SpicyChat tags are merged
}
```

### Character import (wherever `spicyChatFetchCharacter` is dispatched)

```dart
case CatalogProvider.crushon:
  return crushonFetchCharacter(id);
```

### Combined-mode sort mapping (optional)

```dart
CatalogProvider.crushon => switch (sort) {
  'trending' => 'trending',
  'popular' => 'popular',
  'latest' || 'new' => 'new',
  _ => 'recent_hits',
},
```

---

## 5. `lib/features/catalog/widgets/catalog_controls.dart`

In `sortOptionsForProvider`:

```dart
CatalogProvider.crushon => {
  'popular': 'Popular',
  'recent_hits': 'Recent Hits',
  'trending': 'Trending',
  'new': 'New',
  'daily_ranking': 'Daily Ranking',
  'editor_choice': "Editor's Choice",
  'following': 'Following',
},
```

(Or use `.tr()` keys if you add them to `en.json` / `ru.json`.)

**Daily Ranking date:** when `state.filters.sort == 'daily_ranking'`, show a
date chip / picker. On change:

```dart
ref.read(catalogProvider.notifier).setFilters(
  state.filters.copyWith(window: 'YYYY-MM-DD'),  // e.g. 2026-10-08
);
```

Empty / `'all'` window = today (server default).

---

## 6. `lib/features/catalog/services/unified_favorites_service.dart`

```dart
import 'crushon_provider.dart';

// In fetchUnifiedRemoteFavorites, add parameter:
//   required bool crushonLoggedIn,

if (crushonLoggedIn) {
  try {
    for (var page = 1; page <= 4; page++) {
      final rows = await crushonFetchFavorites(page: page);
      out.addAll(rows);
      if (rows.length < 24) break;
    }
  } catch (_) {}
}
```

Wire the new flag from `crushOnAccountProvider.isLoggedIn` at the call site.

---

## 7. Providers screen / logo

`third_party_providers_screen.dart` — add a CrushOn row that opens
`CrushOnLoginSheet.show(context)` when the user taps Sign in / Account.

`provider_logo.dart` — map `CatalogProvider.crushon` / `ThirdPartyProvider.crushon`
to `assets/logos/providers/crushon.png` (or a text fallback “C”).

---

## 8. Translations (`assets/translations/en.json`)

```json
"catalog_sort_crushon_popular": "Popular",
"catalog_sort_crushon_recent_hits": "Recent Hits",
"catalog_sort_crushon_trending": "Trending",
"catalog_sort_crushon_new": "New",
"catalog_sort_crushon_daily_ranking": "Daily Ranking",
"catalog_sort_crushon_editor_choice": "Editor's Choice",
"catalog_sort_crushon_following": "Following",
"catalog_provider_crushon": "CrushOn",
"catalog_crushon_sign_in": "Sign in to CrushOn",
"catalog_crushon_sign_in_nsfw": "Sign in to CrushOn for Following and favorites."
```

---

## 9. Behaviour notes

| Feature | Status in this drop |
|---------|---------------------|
| Browse sorts (Popular → Following) | Implemented |
| Tags (full site vocabulary seed + live fetch) | Implemented |
| Search | Implemented |
| Daily Ranking + date via `filters.window` | Implemented |
| Character import | Best-effort (full card needs session) |
| Favorites | Implemented (needs sign-in) |
| Sign-in WebView | Implemented |
| Continuous live access | Paginated API; no local mirror — each open hits CrushOn |
| GIF avatars | Passed through as CDN URLs (Image widgets already handle gif/webp) |
| Cloudflare | Requires one WebView open to capture `cf_clearance` |

**Following** and **favorites** need a signed-in session. Public sorts work
after CF clearance is captured (Done on the login sheet even without full auth).

---

## 10. Smoke test checklist

1. Enable CrushOn on the Providers screen.
2. Open CrushOn login sheet → pass CF → tap Done (even as guest).
3. Switch catalog provider to CrushOn.
4. Cycle sorts: Recent Hits, Popular, Trending, New, Daily Ranking.
5. For Daily Ranking, set `window` to `2026-10-08` and confirm results change.
6. Open a filter sheet — CrushOn tags should appear.
7. Sign in fully → Following + Favorites populate.
8. Tap a character → import path returns at least name/avatar.
