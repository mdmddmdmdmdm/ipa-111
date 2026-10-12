import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../catalog_models.dart';
import 'catalog_http.dart';
import 'crushon_session.dart';

/// CrushOn.AI catalog integration.
///
/// The site is a Next.js + tRPC app behind Cloudflare. Public discovery feeds
/// live at:
///
///   GET  /api/trpc/character.getCharactersByTag
///   POST /api/trpc/character.searchInfinite
///   GET  /api/trpc/character.getSearchFilterTags
///
/// Sort keys mirror the live homepage dropdown exactly:
///   popular | recent-hits | trending | new | daily-ranking |
///   editor-choice | following
///
/// Daily Ranking accepts an optional ISO date via [CatalogFilters.window]
/// (`YYYY-MM-DD`). Empty window = today on the server.
///
/// Cloudflare often challenges bare HTTP clients. When a challenge is detected
/// the provider falls through to [CrushOnWebSession] cookies (same pattern as
/// SpicyChat). Browse still works without a signed-in account for public sorts;
/// `following` and favorites require a session.

const _apiBase = 'https://crushon.ai/api';
const _siteOrigin = 'https://crushon.ai';
const _pageSize = 24;

final Dio _crushonDio = Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 25),
    sendTimeout: const Duration(seconds: 15),
    headers: const {
      'Accept': 'application/json',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
      'Origin': _siteOrigin,
      'Referer': '$_siteOrigin/',
    },
    validateStatus: (_) => true,
  ),
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _asString(dynamic value) => value == null ? '' : value.toString().trim();

String? _firstString(Map<String, dynamic> m, List<String> keys) {
  for (final key in keys) {
    final v = m[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return null;
}

dynamic _firstValue(Map<String, dynamic> m, List<String> keys) {
  for (final key in keys) {
    if (m.containsKey(key) && m[key] != null) return m[key];
  }
  return null;
}

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(_asString(value)) ?? 0;
}

List<String> _stringList(dynamic value) {
  if (value is List) {
    return value
        .map(_asString)
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
  }
  if (value is String) {
    return value
        .split(RegExp(r'[,|]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
  }
  return const [];
}

/// Map Glaze sort keys → CrushOn `sortTag` values used by the live site.
String crushonSortTag(String sort) {
  switch (sort) {
    case 'popular':
      return 'popular';
    case 'recent_hits':
    case 'recent-hits':
      return 'recent-hits';
    case 'trending':
      return 'trending';
    case 'new':
    case 'latest':
      return 'new';
    case 'daily_ranking':
    case 'daily-ranking':
      return 'daily-ranking';
    case 'editor_choice':
    case 'editor-choice':
      return 'editor-choice';
    case 'following':
      return 'following';
    default:
      return 'recent-hits';
  }
}

String _avatarUrl(dynamic raw) {
  if (raw is Map) {
    raw = raw['url'] ??
        raw['src'] ??
        raw['href'] ??
        raw['thumbnail'] ??
        raw['image'];
  }
  var value = _asString(raw);
  if (value.isEmpty) return '';
  if (value.startsWith('http://') || value.startsWith('https://')) return value;
  if (value.startsWith('//')) return 'https:$value';
  if (value.startsWith('/')) return '$_siteOrigin$value';
  // CrushOn CDN paths are often relative to their media host.
  if (value.contains('crushon') || value.contains('cdn')) {
    return value.startsWith('http') ? value : 'https://$value';
  }
  return '$_siteOrigin/$value';
}

CatalogItem _itemFromMap(Map<String, dynamic> d) {
  final tags = _stringList(
    _firstValue(d, ['tags', 'tagNames', 'tag_names', 'labelList']),
  );
  // Tag objects sometimes arrive as {name: "Anime"} maps.
  if (tags.isEmpty) {
    final rawTags = d['tags'];
    if (rawTags is List) {
      for (final t in rawTags) {
        if (t is Map) {
          final name = _asString(t['name'] ?? t['label'] ?? t['slug']);
          if (name.isNotEmpty) tags.add(name);
        }
      }
    }
  }

  final name = _firstString(d, ['name', 'title', 'characterName', 'displayName']) ??
      'CrushOn character';
  final id = _firstString(d, [
        'id',
        'characterId',
        'character_id',
        'uuid',
        'cid',
      ]) ??
      name;
  final creator = _firstString(d, [
    'creatorName',
    'creator',
    'author',
    'username',
    'userName',
  ]);
  final creatorId = _firstString(d, [
    'creatorId',
    'creator_id',
    'userId',
    'user_id',
    'authorId',
  ]);
  final description = _firstString(d, [
    'introduction',
    'description',
    'brief',
    'summary',
    'tagline',
    'bio',
  ]);
  final avatar = _avatarUrl(
    _firstValue(d, [
      'avatar',
      'avatarUrl',
      'avatar_url',
      'image',
      'imageUrl',
      'cover',
      'thumbnail',
      'portrait',
    ]),
  );
  final chatCount = _asInt(
    _firstValue(d, [
      'interactionCount',
      'chatCount',
      'chats',
      'messageCount',
      'messages',
      'totalMessages',
      'count',
    ]),
  );
  final nsfw = d['nsfw'] == true ||
      d['isNsfw'] == true ||
      d['unfiltered'] == true ||
      tags.any((t) {
        final lower = t.toLowerCase();
        return lower == 'nsfw' ||
            lower == 'unfiltered' ||
            lower.contains('18+');
      });

  return CatalogItem(
    id: id,
    name: name,
    avatarUrl: avatar.isEmpty ? null : avatar,
    description: description,
    tags: tags,
    chatCount: chatCount,
    messageCount: chatCount,
    creator: creator,
    creatorId: creatorId,
    nsfw: nsfw,
    slug: _firstString(d, ['slug', 'path']),
    source: 'crushon',
    sourceKind: 'crushon',
    fullPath: 'https://crushon.ai/character/$id',
  );
}

/// Unwrap tRPC batch envelope → the inner `json` payload.
dynamic _unwrapTrpc(dynamic raw, {int index = 0}) {
  if (raw is String) {
    try {
      raw = jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
  if (raw is List && raw.isNotEmpty) {
    final entry = raw[index is int && index < raw.length ? index : 0];
    if (entry is Map) {
      final result = entry['result'];
      if (result is Map) {
        final data = result['data'];
        if (data is Map && data.containsKey('json')) return data['json'];
        return data;
      }
      if (entry.containsKey('json')) return entry['json'];
    }
    return entry;
  }
  if (raw is Map) {
    final result = raw['result'];
    if (result is Map) {
      final data = result['data'];
      if (data is Map && data.containsKey('json')) return data['json'];
      return data;
    }
  }
  return raw;
}

List<Map<String, dynamic>> _extractCharacterList(dynamic payload) {
  if (payload == null) return const [];
  List? list;
  if (payload is List) {
    list = payload;
  } else if (payload is Map) {
    list = payload['items'] as List? ??
        payload['characters'] as List? ??
        payload['data'] as List? ??
        payload['list'] as List? ??
        payload['results'] as List?;
    // Some feeds nest one more level under `json`.
    if (list == null && payload['json'] is Map) {
      return _extractCharacterList(payload['json']);
    }
  }
  if (list == null) return const [];
  final out = <Map<String, dynamic>>[];
  for (final row in list) {
    if (row is Map<String, dynamic>) {
      out.add(row);
    } else if (row is Map) {
      out.add(Map<String, dynamic>.from(row));
    }
  }
  return out;
}

Map<String, String> _sessionHeaders({bool nsfw = true}) {
  final headers = <String, String>{
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    'x-nsfw': nsfw ? 'true' : 'false',
    'x-gender': '0',
    'x-language': 'en',
    'Origin': _siteOrigin,
    'Referer': '$_siteOrigin/',
  };
  final cookie = CrushOnWebSession.instance.cookieHeader;
  if (cookie != null && cookie.isNotEmpty) {
    headers['Cookie'] = cookie;
  }
  final cf = CrushOnWebSession.instance.cfClearance;
  if (cf != null && cf.isNotEmpty) {
    // Some CF setups also want the clearance echoed as a header; the cookie
    // is the primary credential.
    headers['cf-clearance'] = cf;
  }
  return headers;
}

bool _looksLikeCloudflare(Response res) {
  final body = (res.data is String) ? res.data as String : '${res.data}';
  final status = res.statusCode ?? 0;
  if (status == 403 || status == 503) return true;
  final lower = body.toLowerCase();
  return lower.contains('just a moment') ||
      lower.contains('cf-browser-verification') ||
      lower.contains('challenge-platform') ||
      lower.contains('cloudflare');
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Browse / search CrushOn characters.
///
/// [page] is 1-based. When [query] is non-empty the search endpoint is used;
/// otherwise the tag/sort feed is used (homepage behaviour).
///
/// Always hits the live CrushOn tRPC API (no local snapshot), so Daily Ranking
/// dates and "New" / "Recent Hits" feeds progress with the site.
Future<CatalogSearchResult> crushonSearch({
  String query = '',
  int page = 1,
  int limit = _pageSize,
  CatalogFilters filters = const CatalogFilters(),
}) async {
  await CrushOnWebSession.instance.ensureLoaded();

  final nsfw = filters.nsfw;
  final sortTag = crushonSortTag(filters.sort);
  final tags = filters.tagNames
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();

  // Daily ranking date: reuse filters.window as YYYY-MM-DD when present.
  // Empty / non-ISO window = today (server default).
  String? rankingDate;
  if (sortTag == 'daily-ranking') {
    final w = filters.window.trim();
    if (w.isNotEmpty &&
        w != 'all' &&
        w != 'week' &&
        w != '24h' &&
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(w)) {
      rankingDate = w;
    }
  }

  try {
    if (query.trim().isNotEmpty) {
      return await _searchInfinite(
        query: query.trim(),
        page: page,
        limit: limit,
        nsfw: nsfw,
        tags: tags,
        sortTag: sortTag == 'recent-hits' ? 'all' : sortTag,
      );
    }
    return await _getByTag(
      page: page,
      limit: limit,
      nsfw: nsfw,
      tags: tags,
      sortTag: sortTag,
      rankingDate: rankingDate,
    );
  } catch (e, st) {
    debugPrint('CrushOn search failed: $e\n$st');
    rethrow;
  }
}

Future<CatalogSearchResult> _getByTag({
  required int page,
  required int limit,
  required bool nsfw,
  required List<String> tags,
  required String sortTag,
  String? rankingDate,
}) async {
  final input = <String, dynamic>{
    'tags': tags,
    'collectionKind': '',
    'sortTag': sortTag,
    'nsfw': nsfw,
    'gender': 0,
    'count': limit,
    'locale': 'en',
    'flyingNsfw': false,
    'direction': page <= 1 ? 'forward' : 'forward',
    // Cursor-style paging: page 1 has no cursor; later pages pass offset.
    if (page > 1) 'cursor': (page - 1) * limit,
    if (page > 1) 'offset': (page - 1) * limit,
    if (rankingDate != null) 'date': rankingDate,
    if (rankingDate != null) 'rankingDate': rankingDate,
  };

  final params = {
    'batch': '1',
    'input': jsonEncode({
      '0': {'json': input},
    }),
  };

  final res = await _crushonDio.get<dynamic>(
    '$_apiBase/trpc/character.getCharactersByTag',
    queryParameters: params,
    options: Options(headers: _sessionHeaders(nsfw: nsfw)),
  );

  if (_looksLikeCloudflare(res)) {
    throw Exception(
      'CrushOn is behind a Cloudflare challenge. Open the CrushOn login sheet '
      'once so the app can capture clearance cookies, then retry.',
    );
  }
  if (res.statusCode != null && res.statusCode! >= 400) {
    throw DioException.badResponse(
      statusCode: res.statusCode ?? 0,
      requestOptions: res.requestOptions,
      response: res,
    );
  }

  final payload = _unwrapTrpc(res.data);
  final rows = _extractCharacterList(payload);
  final items = rows.map(_itemFromMap).toList();

  // Total is often absent; approximate so the UI can keep paging.
  int total = items.length;
  if (payload is Map) {
    total = _asInt(payload['total'] ?? payload['count'] ?? total);
    if (total < items.length) total = items.length;
    // If the server hints there is more, inflate total past this page.
    final hasMoreHint = payload['hasMore'] == true ||
        payload['nextCursor'] != null ||
        payload['next'] != null;
    if (hasMoreHint && total <= (page * limit)) {
      total = page * limit + 1;
    }
  }
  final hasMore = items.length >= limit || total > page * limit;

  return CatalogSearchResult(
    characters: items,
    total: total > 0 ? total : items.length,
    hasMore: hasMore,
  );
}

Future<CatalogSearchResult> _searchInfinite({
  required String query,
  required int page,
  required int limit,
  required bool nsfw,
  required List<String> tags,
  required String sortTag,
}) async {
  final cursor = (page - 1) * limit;
  final body = {
    '0': {
      'json': {
        'query': query,
        'limit': limit,
        'nsfw': nsfw,
        'gender': 0,
        'tags': tags,
        'sortTag': sortTag,
        'cursor': cursor,
        'pager': {
          'count': limit,
          'total': -1,
          'offset': cursor,
          'external': '',
        },
        'locale': 'en',
      },
    },
  };

  final res = await _crushonDio.post<dynamic>(
    '$_apiBase/trpc/character.searchInfinite?batch=1',
    data: body,
    options: Options(headers: _sessionHeaders(nsfw: nsfw)),
  );

  if (_looksLikeCloudflare(res)) {
    throw Exception(
      'CrushOn is behind a Cloudflare challenge. Open the CrushOn login sheet '
      'once so the app can capture clearance cookies, then retry.',
    );
  }
  if (res.statusCode != null && res.statusCode! >= 400) {
    throw DioException.badResponse(
      statusCode: res.statusCode ?? 0,
      requestOptions: res.requestOptions,
      response: res,
    );
  }

  final payload = _unwrapTrpc(res.data);
  final rows = _extractCharacterList(payload);
  final items = rows.map(_itemFromMap).toList();

  int total = items.length;
  if (payload is Map) {
    total = _asInt(payload['total'] ?? payload['count'] ?? total);
    if (total < items.length) total = items.length;
  }
  final hasMore = items.length >= limit;

  return CatalogSearchResult(
    characters: items,
    total: total > 0 ? total : items.length,
    hasMore: hasMore,
  );
}

// ---------------------------------------------------------------------------
// Tags
// ---------------------------------------------------------------------------

List<CatalogTag> _cachedCrushonTags = [];
bool _crushonTagsFetched = false;

/// Seed vocabulary from the live CrushOn tag chips (Characters filter panel).
/// Used when the live facet endpoint is blocked or empty so the filter sheet
/// is never blank.
const _kCrushonKnownTags = <String>[
  'Alien',
  'Angel',
  'Animal',
  'Anime',
  'Anthro',
  'Any Pov',
  'Assistant',
  'BDSM',
  'Bisexual',
  'Bondage',
  'Books',
  'Bully',
  'Caring',
  'Cartoon',
  'Cheating',
  'CNC',
  'Comedy',
  'Corruption',
  'Crossdressing',
  'Cute',
  'Dead dove',
  'Demon',
  'Detective',
  'DILF',
  'Dominant',
  'Elf',
  'Enemies to lovers',
  'Expansion',
  'Fairytale',
  'Fantasy',
  'Female Pov',
  'Femboy',
  'Femdom',
  'Feral',
  'Fetish',
  'Fictional',
  'Fluff',
  'Friend',
  'Furry',
  'Futanari',
  'Game',
  'Gay',
  'Genderless',
  'Giant',
  'Gothic',
  'Group Chat',
  'Hero',
  'Hetero',
  'Historical',
  'Horror',
  'Impregnation',
  'Kinky',
  'Kuudere',
  'Lactation',
  'Lesbian',
  'Mafia',
  'Magical',
  'Male Pov',
  'MILF',
  'Monster',
  'Monster Girl',
  'Movie',
  'Multiple',
  'Muscle',
  'Mythology',
  'Non-English',
  'Non-human',
  'NTR',
  'OC',
  'Omegaverse',
  'Philosophy',
  'Pokemon',
  'Politics',
  'Religion',
  'Robot',
  'Royalty',
  'RPG',
  'Sci-Fi',
  'Seductive',
  'Size difference',
  'Smut',
  'Step-family',
  'Story',
  'Straight',
  'Submissive',
  'Tomboy',
  'Trans Female',
  'Trans Male',
  'Tsundere',
  'Vampire',
  'Vanilla',
  'Villain',
  'Virtual Human',
  'Vore',
  'VTuber',
  'Wholesome',
  'Yandere',
];

String _tagKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

Future<List<CatalogTag>> fetchCrushonTags() async {
  if (_crushonTagsFetched && _cachedCrushonTags.isNotEmpty) {
    return _cachedCrushonTags;
  }

  final byKey = <String, CatalogTag>{};
  for (final name in _kCrushonKnownTags) {
    byKey[_tagKey(name)] = CatalogTag(name: name);
  }

  try {
    final params = {
      'batch': '1',
      'input': jsonEncode({
        '0': {
          'json': {'locale': 'en', 'nsfw': true},
        },
      }),
    };
    final res = await _crushonDio.get<dynamic>(
      '$_apiBase/trpc/character.getSearchFilterTags',
      queryParameters: params,
      options: Options(headers: _sessionHeaders(nsfw: true)),
    );
    if (!_looksLikeCloudflare(res) &&
        (res.statusCode == null || res.statusCode! < 400)) {
      final payload = _unwrapTrpc(res.data);
      void ingest(dynamic node) {
        if (node is List) {
          for (final row in node) {
            ingest(row);
          }
          return;
        }
        if (node is! Map) return;
        final name = _asString(
          node['name'] ?? node['label'] ?? node['tag'] ?? node['slug'],
        );
        if (name.isEmpty) return;
        final key = _tagKey(name);
        byKey.putIfAbsent(key, () => CatalogTag(name: name, slug: _asString(node['slug']).isEmpty ? null : _asString(node['slug'])));
        // Nested children (category → tags).
        for (final childKey in ['tags', 'children', 'items', 'list']) {
          if (node[childKey] != null) ingest(node[childKey]);
        }
      }

      ingest(payload);
    }
  } catch (e) {
    debugPrint('CrushOn tag fetch failed (using known-tag seed): $e');
  }

  final tags = byKey.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  _cachedCrushonTags = tags;
  _crushonTagsFetched = true;
  return tags;
}

// ---------------------------------------------------------------------------
// Character detail / import
// ---------------------------------------------------------------------------

/// Fetch a single character for import into the local library.
///
/// CrushOn does not expose a clean public character-card endpoint without a
/// session. We try, in order:
/// 1. `character.getCharacter` tRPC (full definition when session allows)
/// 2. Batch `character.getCharacter,character.getCharacterDetail` variants
/// 3. Public character page HTML / __NEXT_DATA__ scrape
/// 4. Search-by-id fallback for name/avatar/tags shell
Future<DownloadedCharacter> crushonFetchCharacter(String id) async {
  // Attempt 1: dedicated getCharacter procedure.
  final fromTrpc = await _tryCharacterTrpc(id, 'character.getCharacter');
  if (fromTrpc != null && _hasUsableDefinition(fromTrpc)) return fromTrpc;

  // Attempt 2: alternate procedure names seen in the wild / older builds.
  for (final proc in const [
    'character.getCharacterById',
    'character.getCharacterDetail',
    'character.queryCharacter',
  ]) {
    final alt = await _tryCharacterTrpc(id, proc);
    if (alt != null && _hasUsableDefinition(alt)) return alt;
  }

  // Prefer a partial tRPC hit over nothing if we got one.
  if (fromTrpc != null) return fromTrpc;

  // Attempt 3: public character page (Next.js __NEXT_DATA__ or meta tags).
  try {
    final pageChar = await _scrapeCharacterPage(id);
    if (pageChar != null) return pageChar;
  } catch (e) {
    debugPrint('CrushOn character page scrape failed: $e');
  }

  // Attempt 4: search-by-id fallback for public metadata.
  try {
    final result = await crushonSearch(query: id, page: 1, limit: 8);
    final match = result.characters.where((c) => c.id == id).toList();
    final item = match.isNotEmpty
        ? match.first
        : (result.characters.isNotEmpty ? result.characters.first : null);
    if (item != null) {
      return DownloadedCharacter(
        charData: CharacterData(
          name: item.name,
          description: item.description ?? '',
          tags: item.tags,
          creator: item.creator ?? '',
          creatorId: item.creatorId ?? '',
        ),
        avatarUrl: item.avatarUrl,
      );
    }
  } catch (e) {
    debugPrint('CrushOn character search fallback failed: $e');
  }

  return DownloadedCharacter(
    charData: CharacterData(name: id),
    avatarUrl: null,
  );
}

bool _hasUsableDefinition(DownloadedCharacter d) {
  final c = d.charData;
  return c.personality.isNotEmpty ||
      c.firstMes.isNotEmpty ||
      c.scenario.isNotEmpty ||
      c.description.isNotEmpty;
}

Future<DownloadedCharacter?> _tryCharacterTrpc(
  String id,
  String procedure,
) async {
  try {
    final params = {
      'batch': '1',
      'input': jsonEncode({
        '0': {
          'json': {'characterId': id, 'id': id},
        },
      }),
    };
    final res = await _crushonDio.get<dynamic>(
      '$_apiBase/trpc/$procedure',
      queryParameters: params,
      options: Options(headers: _sessionHeaders()),
    );
    if (_looksLikeCloudflare(res) ||
        (res.statusCode != null && res.statusCode! >= 400)) {
      return null;
    }
    final payload = _unwrapTrpc(res.data);
    if (payload is Map) {
      final map = Map<String, dynamic>.from(payload as Map);
      final nested = map['character'] is Map
          ? Map<String, dynamic>.from(map['character'] as Map)
          : (map['data'] is Map
              ? Map<String, dynamic>.from(map['data'] as Map)
              : map);
      return _characterFromApiMap(nested, id);
    }
  } catch (e) {
    debugPrint('CrushOn $procedure failed: $e');
  }
  return null;
}

/// Best-effort parse of the public character page for name / greeting /
/// personality when the tRPC detail route is gated.
Future<DownloadedCharacter?> _scrapeCharacterPage(String id) async {
  final res = await _crushonDio.get<dynamic>(
    '$_siteOrigin/character/$id',
    options: Options(
      headers: {
        ..._sessionHeaders(),
        'Accept': 'text/html,application/xhtml+xml',
      },
      responseType: ResponseType.plain,
    ),
  );
  if (_looksLikeCloudflare(res) ||
      (res.statusCode != null && res.statusCode! >= 400)) {
    return null;
  }
  final html = res.data is String ? res.data as String : '${res.data}';
  if (html.isEmpty) return null;

  // Prefer Next.js serialized state.
  final nextDataMatch = RegExp(
    r'<script id="__NEXT_DATA__"[^>]*>(\{.*?\})</script>',
    dotAll: true,
  ).firstMatch(html);
  if (nextDataMatch != null) {
    try {
      final root = jsonDecode(nextDataMatch.group(1)!) as Map<String, dynamic>;
      final pageProps = root['props'] is Map
          ? (root['props'] as Map)['pageProps']
          : null;
      Map<String, dynamic>? charMap;
      if (pageProps is Map) {
        for (final key in [
          'character',
          'characterDetail',
          'data',
          'card',
          'initialData',
        ]) {
          final v = pageProps[key];
          if (v is Map) {
            charMap = Map<String, dynamic>.from(v);
            break;
          }
        }
        // Sometimes nested under dehydratedState queries.
        if (charMap == null && pageProps['dehydratedState'] is Map) {
          charMap = _findCharacterInTree(pageProps['dehydratedState']);
        }
      }
      if (charMap != null) {
        return _characterFromApiMap(charMap, id);
      }
    } catch (e) {
      debugPrint('CrushOn __NEXT_DATA__ parse failed: $e');
    }
  }

  // Meta / og tags as a last HTML fallback.
  String? meta(String property) {
    final re = RegExp(
      'property=["\']$property["\'][^>]*content=["\']([^"\']+)["\']|'
      'content=["\']([^"\']+)["\'][^>]*property=["\']$property["\']',
      caseSensitive: false,
    );
    final m = re.firstMatch(html);
    return m?.group(1) ?? m?.group(2);
  }

  final title = meta('og:title') ?? meta('twitter:title');
  final desc = meta('og:description') ?? meta('twitter:description') ?? '';
  final image = meta('og:image') ?? meta('twitter:image');
  if (title == null || title.trim().isEmpty) return null;

  return DownloadedCharacter(
    charData: CharacterData(
      name: title.replaceAll(RegExp(r'\s*[|\-–].*$'), '').trim(),
      description: desc,
    ),
    avatarUrl: image == null || image.isEmpty ? null : _avatarUrl(image),
  );
}

Map<String, dynamic>? _findCharacterInTree(dynamic node, {int depth = 0}) {
  if (depth > 8 || node == null) return null;
  if (node is Map) {
    final m = Map<String, dynamic>.from(node);
    // Heuristic: maps that look like a character card.
    final hasName = m['name'] is String || m['characterName'] is String;
    final hasId = m['id'] != null || m['characterId'] != null;
    final hasBody = m.containsKey('personality') ||
        m.containsKey('greeting') ||
        m.containsKey('firstMes') ||
        m.containsKey('introduction') ||
        m.containsKey('definition');
    if (hasName && (hasId || hasBody)) return m;
    for (final v in m.values) {
      final found = _findCharacterInTree(v, depth: depth + 1);
      if (found != null) return found;
    }
  } else if (node is List) {
    for (final v in node) {
      final found = _findCharacterInTree(v, depth: depth + 1);
      if (found != null) return found;
    }
  }
  return null;
}

DownloadedCharacter _characterFromApiMap(Map<String, dynamic> d, String id) {
  var tags = _stringList(
    _firstValue(d, ['tags', 'tagNames', 'tag_names', 'labelList']),
  );
  if (tags.isEmpty) {
    final rawTags = d['tags'];
    if (rawTags is List) {
      final collected = <String>[];
      for (final t in rawTags) {
        if (t is Map) {
          final n = _asString(t['name'] ?? t['label'] ?? t['tag']);
          if (n.isNotEmpty) collected.add(n);
        } else {
          final n = _asString(t);
          if (n.isNotEmpty) collected.add(n);
        }
      }
      tags = collected;
    }
  }

  final name = _firstString(d, ['name', 'title', 'characterName']) ?? id;
  final description = _firstString(d, [
        'introduction',
        'description',
        'brief',
        'summary',
        'shortDescription',
      ]) ??
      '';
  final personality = _firstString(d, [
        'personality',
        'definition',
        'characterDefinition',
        'prompt',
        'system',
        'systemPrompt',
      ]) ??
      '';
  final scenario = _firstString(d, [
        'scenario',
        'context',
        'setting',
        'worldScenario',
      ]) ??
      '';
  final firstMes = _firstString(d, [
        'greeting',
        'firstMes',
        'first_mes',
        'firstMessage',
        'opening',
        'intro',
      ]) ??
      '';
  final mesExample = _firstString(d, [
        'exampleDialogue',
        'mesExample',
        'mes_example',
        'examples',
        'exampleMessages',
        'dialogues',
      ]) ??
      '';
  final systemPrompt = _firstString(d, [
        'systemPrompt',
        'system_prompt',
        'systemMessage',
      ]) ??
      '';
  final creatorNotes = _firstString(d, [
        'creatorNotes',
        'creator_notes',
        'notes',
        'authorNote',
      ]) ??
      '';
  final creator = _firstString(d, [
        'creatorName',
        'creator',
        'author',
        'username',
        'userName',
      ]) ??
      '';
  final creatorId = _firstString(d, ['creatorId', 'userId', 'authorId']) ?? '';
  final avatar = _avatarUrl(
    _firstValue(d, [
      'avatar',
      'avatarUrl',
      'image',
      'imageUrl',
      'cover',
      'thumbnail',
      'portrait',
    ]),
  );

  // Alternate greetings when the API returns a list.
  final alts = <String>[];
  final rawAlts = d['alternateGreetings'] ??
      d['alternate_greetings'] ??
      d['greetings'] ??
      d['extraGreetings'];
  if (rawAlts is List) {
    for (final a in rawAlts) {
      final s = _asString(a);
      if (s.isNotEmpty && s != firstMes) alts.add(s);
    }
  }

  return DownloadedCharacter(
    charData: CharacterData(
      name: name,
      description: description,
      personality: personality,
      scenario: scenario,
      firstMes: firstMes,
      mesExample: mesExample,
      systemPrompt: systemPrompt,
      creatorNotes: creatorNotes,
      alternateGreetings: alts,
      tags: tags,
      creator: creator,
      creatorId: creatorId,
    ),
    avatarUrl: avatar.isEmpty ? null : avatar,
  );
}

// ---------------------------------------------------------------------------
// Favorites (account-scoped)
// ---------------------------------------------------------------------------

/// Fetch the signed-in user's favorited characters.
///
/// Requires [CrushOnWebSession] cookies. Returns an empty list when signed out
/// rather than throwing, so the unified favorites grid can still show other
/// providers.
///
/// Tries several live endpoints because CrushOn has renamed the favorites
/// procedure across builds; the first non-empty result wins.
Future<List<CatalogItem>> crushonFetchFavorites({int page = 1}) async {
  await CrushOnWebSession.instance.ensureLoaded();
  if (!CrushOnWebSession.instance.hasSession) return const [];

  try {
    // Path A: sortTag / collectionKind on the main feed.
    for (final sortTag in const ['favorites', 'favorite', 'liked']) {
      final result = await _getByTag(
        page: page,
        limit: _pageSize,
        nsfw: true,
        tags: const [],
        sortTag: sortTag,
      );
      if (result.characters.isNotEmpty) return result.characters;
    }

    // Path B: dedicated tRPC procedures seen across builds.
    for (final procedure in const [
      'character.getFavoriteCharacters',
      'character.queryFavoriteCharacters',
      'character.getLikedCharacters',
      'character.getUserFavorites',
      'character.queryFavorites',
    ]) {
      final rows = await _tryFavoritesProcedure(procedure, page);
      if (rows.isNotEmpty) return rows;
    }

    // Path C: collectionKind on getCharactersByTag.
    try {
      final input = <String, dynamic>{
        'tags': <String>[],
        'collectionKind': 'favorites',
        'sortTag': 'recent-hits',
        'nsfw': true,
        'gender': 0,
        'count': _pageSize,
        'locale': 'en',
        'flyingNsfw': false,
        'direction': 'forward',
        if (page > 1) 'cursor': (page - 1) * _pageSize,
        if (page > 1) 'offset': (page - 1) * _pageSize,
      };
      final params = {
        'batch': '1',
        'input': jsonEncode({
          '0': {'json': input},
        }),
      };
      final res = await _crushonDio.get<dynamic>(
        '$_apiBase/trpc/character.getCharactersByTag',
        queryParameters: params,
        options: Options(headers: _sessionHeaders(nsfw: true)),
      );
      if (!_looksLikeCloudflare(res) &&
          (res.statusCode == null || res.statusCode! < 400)) {
        final payload = _unwrapTrpc(res.data);
        final items = _extractCharacterList(payload).map(_itemFromMap).toList();
        if (items.isNotEmpty) return items;
      }
    } catch (e) {
      debugPrint('CrushOn favorites collectionKind failed: $e');
    }

    return const [];
  } catch (e) {
    debugPrint('CrushOn favorites failed: $e');
    return const [];
  }
}

Future<List<CatalogItem>> _tryFavoritesProcedure(
  String procedure,
  int page,
) async {
  try {
    final params = {
      'batch': '1',
      'input': jsonEncode({
        '0': {
          'json': {
            'count': _pageSize,
            'limit': _pageSize,
            'cursor': (page - 1) * _pageSize,
            'offset': (page - 1) * _pageSize,
            'locale': 'en',
            'nsfw': true,
            'page': page,
          },
        },
      }),
    };
    final res = await _crushonDio.get<dynamic>(
      '$_apiBase/trpc/$procedure',
      queryParameters: params,
      options: Options(headers: _sessionHeaders(nsfw: true)),
    );
    if (_looksLikeCloudflare(res) ||
        (res.statusCode != null && res.statusCode! >= 400)) {
      return const [];
    }
    final payload = _unwrapTrpc(res.data);
    return _extractCharacterList(payload).map(_itemFromMap).toList();
  } catch (e) {
    debugPrint('CrushOn $procedure failed: $e');
    return const [];
  }
}
