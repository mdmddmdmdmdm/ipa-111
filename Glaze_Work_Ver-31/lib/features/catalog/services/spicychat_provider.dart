import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../catalog_models.dart';
import 'spicychat_session.dart';

/// Public SpicyChat catalog configuration. The application endpoint is public
/// and supplies the current Typesense collection/search key. The hostname is
/// kept separately because the application config currently exposes the key
/// but not the hosted Typesense node.
const _configUrl =
    'https://4mpanjbsf6.execute-api.us-east-1.amazonaws.com/v2/applications/spicychat';
const _typesenseHost = 'etmzpxgvnid370fyp.a1.typesense.net';
const _fallbackTypesenseKey = 'cmZDazV3YWlvR2FvQk5DOEhQdzZBN0Nzd2dzcUt4aHJwQUlpK1Z5TlU5WT1TVEhLeyJmaWx0ZXJfYnkiOiAidHlwZTohPU1FVEEiLCAiZmFjZXRfc2FtcGxlX3BlcmNlbnQiOiAxMCwgImZhY2V0X3NhbXBsZV90aHJlc2hvbGQiOiAxMDAwMCwgImZhY2V0X3N0cmF0ZWd5IjogImV4aGF1c3RpdmUifQ==';
const _collection = 'public_characters_alias';
const _apiBase = 'https://prod.nd-api.com/v2';
const _cdnBase = 'https://cdn.nd-api.com/';
const _pageSize = 24;

final Dio _spicyDio = Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    sendTimeout: const Duration(seconds: 12),
    headers: const {'Accept': 'application/json'},
  ),
);

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

String _avatarUrl(dynamic raw) {
  if (raw is Map) {
    raw = raw['url'] ?? raw['src'] ?? raw['href'];
  }
  var value = _asString(raw);
  if (value.isEmpty) return '';
  if (value.startsWith('http://') || value.startsWith('https://')) return value;
  if (value.startsWith('//')) return 'https:$value';
  if (value.startsWith('/')) return '$_cdnBase${value.substring(1)}';
  return '$_cdnBase${value.replaceFirst(RegExp(r'^/+'), '')}';
}

Map<String, dynamic> _document(dynamic hit) {
  if (hit is Map<String, dynamic>) {
    final doc = hit['document'];
    if (doc is Map<String, dynamic>) return doc;
    return hit;
  }
  return <String, dynamic>{};
}

CatalogItem _itemFromDocument(Map<String, dynamic> d) {
  final tags = _stringList(_firstValue(d, ['tags', 'tag_names', 'tagNames']));
  final name = _firstString(d, ['name', 'title', 'character_name']) ?? 'SpicyChat character';
  final id = _firstString(d, ['id', 'character_id', 'uuid', 'alias']) ?? name;
  final creator = _firstString(
    d,
    ['creator_username', 'creatorUsername', 'creator', 'username', 'author_username'],
  );
  final creatorId = _firstString(d, ['creator_id', 'creatorId', 'author_id']);
  final avatar = _avatarUrl(
    _firstValue(d, ['avatar_url', 'avatarUrl', 'avatar', 'image_url', 'image', 'thumbnail_url']),
  );
  final nsfw = tags.any((t) => t.toLowerCase() == 'nsfw') ||
      d['nsfw'] == true ||
      d['is_nsfw'] == true;
  final messages = _asInt(
    _firstValue(d, ['num_messages', 'message_count', 'messageCount', 'messages', 'num_messages_total']),
  );
  final tokens = _asInt(_firstValue(d, ['tokens', 'definition_tokens', 'token_count']));
  final description = _firstString(
    d,
    ['description', 'short_description', 'title_description', 'blurb', 'greeting'],
  );

  return CatalogItem(
    id: id,
    name: name,
    avatarUrl: avatar.isEmpty ? null : avatar,
    description: description,
    tags: tags,
    tokens: tokens,
    chatCount: _asInt(_firstValue(d, ['chat_count', 'chatCount'])),
    messageCount: messages,
    creator: creator,
    creatorId: creatorId,
    nsfw: nsfw,
    slug: _firstString(d, ['slug']),
    source: 'spicychat',
    fullPath: _firstString(d, ['url', 'path', 'full_path']) ?? '/chatbot/$id',
    sourceKind: 'spicychat',
  );
}

class SpicyChatConfig {
  final String searchKey;
  const SpicyChatConfig(this.searchKey);
}

Future<SpicyChatConfig> _loadConfig() async {
  try {
    final r = await _spicyDio.get(_configUrl);
    final data = r.data;
    if (data is Map) {
      final ts = data['typesenseConfig'];
      if (ts is Map && _asString(ts['apiKeyPublicCharacter']).isNotEmpty) {
        return SpicyChatConfig(_asString(ts['apiKeyPublicCharacter']));
      }
      if (_asString(data['typesenseSearchKey']).isNotEmpty) {
        return SpicyChatConfig(_asString(data['typesenseSearchKey']));
      }
    }
  } catch (_) {}
  return const SpicyChatConfig(_fallbackTypesenseKey);
}

String _sortFor(String sort) {
  switch (sort) {
    case 'trending':
      return '_text_match(buckets: 3):desc,num_messages_24h:desc';
    case 'popular':
      // SpicyChat's Popular feed is lifetime popularity. Trending is the
      // separate 24-hour activity feed below; using num_messages_24h for both
      // makes the two dropdown choices return essentially the same cards.
      return 'num_messages:desc';
    case 'latest':
      return 'createdAt:desc';
    default:
      return '_text_match:desc,num_messages_24h:desc';
  }
}

List<CatalogTag> _cachedSpicyChatTags = [];
bool _spicyChatTagsFetched = false;

/// Comprehensive SpicyChat tag vocabulary observed on the live site
/// (Narrow by tag panel). Used as a reliable fallback / seed so the filter
/// sheet always offers the full set even when the Typesense public key
/// samples facets or the facet request fails.
const _kSpicyChatKnownTags = <String>[
  'NSFW',
  'Female',
  'Male',
  'MalePOV',
  'Dominant',
  'FemalePOV',
  'Romantic',
  'Submissive',
  'LGBTQ+',
  'English',
  'Fantasy',
  'Gentle Dom',
  'Original Character',
  'Scenario',
  'Anime',
  'Size Difference',
  'Multiple Characters',
  'Anal',
  'Drama',
  'Mature',
  'Adventure',
  'Corruption',
  'Horror',
  'Action',
  'Friend',
  'Anthro',
  'Wholesome',
  'Sadistic',
  'MILF',
  'Furry',
  'Age Play',
  'Oral',
  'Low Quality',
  'Partner',
  'Bondage',
  'MLM',
  'Cheating',
  'Fictional Media',
  'Magic',
  'Muscle',
  'Gothic',
  'Impregnation',
  'Monster',
  'Comedy',
  'Game',
  'Married Partner',
  'Villain',
  'Yandere',
  'Chubby',
  'Roommate',
  'Masochistic',
  'Smell',
  'Futanari',
  'CNC',
  'Switch',
  'Supernatural',
  'Sci-Fi',
  'RPG',
  'Tsundere',
  'Fat',
  'Real',
  'NTR',
  'Femboy',
  'Giant',
  'Hero',
  'Slave',
  'Mind Control',
  'Feet',
  'Tomboy',
  'Non-English',
  'Lactation',
  'WLW',
  'Transformation',
  'Vore',
  'Servant',
  'Mythological',
  'Omegaverse',
  'Trans',
  'Pregnant',
  'Mystery',
  'Historical',
  'Crossdressing',
  'Non-Binary',
  'Flatulence',
  'Inflation',
  'Simulator',
  'Watersport',
  'AI Assistant',
  'Nature',
  'Inanimate',
  'Non-Human',
  'AnyPOV',
];

List<CatalogTag> getCachedSpicyChatTags() => List.unmodifiable(_cachedSpicyChatTags);

void resetSpicyChatTagCache() {
  _cachedSpicyChatTags = [];
  _spicyChatTagsFetched = false;
}

String _tagKey(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[\s_-]+'), '');

/// SpicyChat's tag vocabulary is the Typesense `tags` facet, not JanitorAI's
/// numeric tag list. Keep the exact source spelling so the UI and exact
/// Typesense filter use the same value.
///
/// The public Typesense key often applies facet sampling, which can return only
/// a short popular subset. We always seed with the known live-site vocabulary
/// and merge any additional names the facet returns so the filter sheet matches
/// the site's "Narrow by tag" panel.
Future<List<CatalogTag>> fetchSpicyChatTags() async {
  if (_spicyChatTagsFetched) return getCachedSpicyChatTags();

  final byKey = <String, CatalogTag>{};
  for (final name in _kSpicyChatKnownTags) {
    byKey[_tagKey(name)] = CatalogTag(name: name);
  }

  try {
    final config = await _loadConfig();
    final response = await _spicyDio.get(
      'https://$_typesenseHost/collections/$_collection/documents/search',
      queryParameters: {
        'q': '*',
        'query_by': 'name',
        'per_page': 0,
        'facet_by': 'tags',
        'facet_limit': 1000,
        'facet_strategy': 'exhaustive',
        // Prefer full coverage when the key allows it.
        'max_facet_values': 1000,
      },
      options: Options(headers: {'X-TYPESENSE-API-KEY': config.searchKey}),
    );
    final data = response.data;
    final facetCounts = data is Map ? data['facet_counts'] : null;
    if (facetCounts is List) {
      for (final row in facetCounts) {
        if (row is! Map) continue;
        if (_asString(row['field_name']).toLowerCase() != 'tags') continue;
        final counts = row['counts'];
        if (counts is! List) continue;
        for (final entry in counts) {
          if (entry is! Map) continue;
          final name = _asString(entry['value']);
          if (name.isEmpty) continue;
          final key = _tagKey(name);
          // Prefer the exact casing returned by Typesense.
          byKey[key] = CatalogTag(name: name);
        }
      }
    }
  } catch (e) {
    debugPrint('SpicyChat tag facet failed (using known-tag seed): $e');
  }

  final tags = byKey.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  _cachedSpicyChatTags = tags;
  _spicyChatTagsFetched = true;
  return getCachedSpicyChatTags();
}

String _canonicalSpicyChatTag(String value) {
  final key = _tagKey(value);
  for (final tag in _cachedSpicyChatTags) {
    if (_tagKey(tag.name) == key) return tag.name;
  }
  // Also check the static seed so filters work even before the first fetch.
  for (final name in _kSpicyChatKnownTags) {
    if (_tagKey(name) == key) return name;
  }
  const aliases = <String, String>{
    'nonhuman': 'Non-Human',
    'femalepov': 'FemalePOV',
    'malepov': 'MalePOV',
    'anypov': 'AnyPOV',
    'lgbtq': 'LGBTQ+',
    'lgbtq+': 'LGBTQ+',
    'scifi': 'Sci-Fi',
    'sci-fi': 'Sci-Fi',
  };
  return aliases[key] ?? value.trim();
}

String _filterFor(CatalogFilters filters) {
  final parts = <String>[];
  if (filters.nsfw) {
    parts.add('tags:=NSFW');
  } else {
    // SpicyChat uses the NSFW tag as a discovery gate. Keeping it out of the
    // public query mirrors the site's Safe Search behaviour.
    parts.add('tags:!=NSFW');
  }
  for (final tag in filters.tagNames) {
    if (tag.trim().isNotEmpty) {
      parts.add('tags:=${_escapeFilter(_canonicalSpicyChatTag(tag))}');
    }
  }
  for (final tag in filters.excludeTagNames) {
    if (tag.trim().isNotEmpty) {
      parts.add('tags:!=${_escapeFilter(_canonicalSpicyChatTag(tag))}');
    }
  }
  return parts.join(' && ');
}

String _escapeFilter(String value) => value.replaceAll('`', '\\`');

Future<CatalogSearchResult> spicyChatSearch({
  required String query,
  required int page,
  required CatalogFilters filters,
}) async {
  final config = await _loadConfig();
  final params = <String, dynamic>{
    'q': query.trim().isEmpty ? '*' : query.trim(),
    'query_by': 'name,title,description,tags',
    'page': page,
    'per_page': _pageSize,
    'sort_by': _sortFor(filters.sort),
    'include_fields': '*',
    'facet_by': 'tags',
  };
  final filter = _filterFor(filters);
  if (filter.isNotEmpty) params['filter_by'] = filter;

  Response<dynamic> response;
  try {
    response = await _spicyDio.get(
      'https://$_typesenseHost/collections/$_collection/documents/search',
      queryParameters: params,
      options: Options(headers: {'X-TYPESENSE-API-KEY': config.searchKey}),
    );
  } catch (e) {
    // Some Typesense schema revisions have removed one searchable field. Fall
    // back to the smallest stable field instead of returning a blank catalog.
    final retry = Map<String, dynamic>.from(params)..['query_by'] = 'name';
    response = await _spicyDio.get(
      'https://$_typesenseHost/collections/$_collection/documents/search',
      queryParameters: retry,
      options: Options(headers: {'X-TYPESENSE-API-KEY': config.searchKey}),
    );
    debugPrint('SpicyChat Typesense fallback after: $e');
  }

  final data = response.data;
  if (data is! Map) throw Exception('SpicyChat returned an invalid catalog response.');
  final hits = data['hits'];
  final rawRows = hits is List
      ? hits.map(_document).where((d) => d.isNotEmpty).map(_itemFromDocument).toList()
      : <CatalogItem>[];

  // Typesense schemas have changed over time: some characters carry the NSFW
  // flag while others only carry the tag, and tag matching can be broader than
  // an exact UI chip match. Apply the shared discovery contract once more on
  // the normalized rows so selecting "Female" cannot leak "Female POV", and
  // turning NSFW on/off always reflects the character's actual NSFW state.
  final normalizedWanted = filters.tagNames
      .map(_tagKey)
      .where((t) => t.isNotEmpty)
      .toSet();
  final normalizedExcluded = filters.excludeTagNames
      .map(_tagKey)
      .where((t) => t.isNotEmpty)
      .toSet();
  final rows = rawRows.where((item) {
    if (filters.nsfw != item.nsfw) return false;
    final itemTags = item.tags.map(_tagKey).toSet();

    // Female and FemalePOV are separate SpicyChat tags. Selecting Female
    // requires the character itself to have the Female tag. A FemalePOV-only
    // bot is not a Female character; a bot carrying both remains valid.
    if (normalizedWanted.contains('female') &&
        !itemTags.contains('female')) {
      return false;
    }

    if (!normalizedWanted.every(itemTags.contains)) return false;
    if (normalizedExcluded.any(itemTags.contains)) return false;
    return true;
  }).toList();
  final found = _asInt(data['found']);
  return CatalogSearchResult(
    characters: rows,
    total: found,
    hasMore: page * _pageSize < found,
  );
}

/// Reads a SpicyChat character card.
///
/// As of late 2025 / 2026 the `prod.nd-api.com/v2/characters/{id}` endpoint
/// requires a Bearer token (returns HTTP 401 "Invalid or expired token"
/// without one). We:
/// 1. Prefer the signed-in SpicyChat WebView session token when available.
/// 2. Fall back to a Typesense partial card (name, greeting, tags, avatar)
///    so tapping a character still works for guests / expired sessions
///    instead of showing a hard 401 dialog.
Future<DownloadedCharacter> spicyChatFetchCharacter(String id) async {
  // --- 1) Authenticated detail when we have a session token ---------------
  String? token;
  try {
    token = await SpicyChatWebSession.instance.getAccessToken();
  } catch (_) {}

  if (token != null && token.isNotEmpty) {
    try {
      final r = await _spicyDio.get(
        '$_apiBase/characters/${Uri.encodeComponent(id)}',
        options: Options(
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
            'x-app-id': 'spicychat',
            'Origin': 'https://spicychat.ai',
            'Referer': 'https://spicychat.ai/',
          },
        ),
      );
      final raw = r.data;
      final data = raw is Map<String, dynamic>
          ? raw
          : (raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{});
      final nested = data['character'] is Map
          ? Map<String, dynamic>.from(data['character'] as Map)
          : data;
      return _characterFromApiMap(nested, id);
    } catch (e) {
      debugPrint('SpicyChat authenticated character fetch failed: $e');
      // Fall through to Typesense partial.
    }
  }

  // --- 2) Typesense partial (always public) -------------------------------
  try {
    final config = await _loadConfig();
    final response = await _spicyDio.get(
      'https://$_typesenseHost/collections/$_collection/documents/search',
      queryParameters: {
        'q': id,
        'query_by': 'character_id,id,name',
        'filter_by': 'character_id:=$id || id:=$id',
        'per_page': 1,
      },
      options: Options(headers: {'X-TYPESENSE-API-KEY': config.searchKey}),
    );
    final hits = response.data is Map ? (response.data['hits'] as List?) : null;
    if (hits != null && hits.isNotEmpty) {
      final doc = _document(hits.first);
      if (doc.isNotEmpty) {
        return _characterFromApiMap(doc, id);
      }
    }
  } catch (e) {
    debugPrint('SpicyChat Typesense character fallback failed: $e');
  }

  // --- 3) Last resort: bare shell so the UI can still open -----------------
  return DownloadedCharacter(
    charData: CharacterData(name: id),
    avatarUrl: null,
  );
}

DownloadedCharacter _characterFromApiMap(Map<String, dynamic> nested, String id) {
  final tags = _stringList(_firstValue(nested, ['tags', 'tag_names']));
  final name = _firstString(nested, ['name', 'title', 'character_name']) ?? id;
  final creator = _firstString(
        nested,
        ['creator_username', 'creatorUsername', 'creator', 'username'],
      ) ??
      '';
  final creatorId = _firstString(nested, ['creator_id', 'creatorId']) ?? '';

  String field(List<String> keys) => _firstString(nested, keys) ?? '';

  final charData = CharacterData(
    name: name,
    description: field(['description', 'short_description', 'greeting', 'title']),
    personality: field(['personality', 'definition', 'persona']),
    scenario: field(['scenario']),
    firstMes: field(['first_mes', 'first_message', 'greeting']),
    mesExample: field(['mes_example', 'example_dialogues', 'example_dialogue']),
    creatorNotes: field(['creator_notes', 'creatorNotes']),
    systemPrompt: field(['system_prompt', 'systemPrompt']),
    postHistoryInstructions:
        field(['post_history_instructions', 'postHistoryInstructions']),
    alternateGreetings:
        _stringList(_firstValue(nested, ['alternate_greetings', 'alternateGreetings'])),
    tags: tags,
    creator: creator,
    creatorId: creatorId,
    characterBook:
        _firstValue(nested, ['character_book', 'characterBook', 'lorebook']),
  );

  final avatar = _avatarUrl(
    _firstValue(nested, ['avatar_url', 'avatarUrl', 'avatar', 'image_url', 'image']),
  );
  return DownloadedCharacter(
    charData: charData,
    avatarUrl: avatar.isEmpty ? null : avatar,
  );
}

/// Small, resilient DOM scraper for the authenticated recommendation/history
/// pages. It deliberately uses semantic links (`/chatbot/<id>`) rather than
/// brittle CSS class names so routine SpicyChat UI restyles do not break the
/// provider.
Future<List<CatalogItem>> spicyChatWebFeed({
  required String path,
  required int page,
}) async {
  final service = SpicyChatWebSession.instance;
  if (!await service.isLoggedIn()) {
    throw Exception('Sign in to SpicyChat first to use For You or Recent.');
  }
  return service.fetchCards(path: path, page: page);
}

class SpicyChatWebSession {
  SpicyChatWebSession._();
  static final instance = SpicyChatWebSession._();

  HeadlessInAppWebView? _webView;
  InAppWebViewController? _controller;
  Completer<void>? _loadStop;
  Completer<void>? _starting;
  Future<void> _gate = Future<void>.value();

  Future<void> _ensureStarted() {
    if (_controller != null) return Future<void>.value();
    if (_starting != null) return _starting!.future;
    final c = Completer<void>();
    _starting = c;
    _start().then((_) {
      if (!c.isCompleted) c.complete();
    }).catchError((Object e, StackTrace st) {
      if (!c.isCompleted) c.completeError(e, st);
      _starting = null;
    });
    return c.future;
  }

  Future<void> _start() async {
    final created = Completer<void>();
    _loadStop = Completer<void>();
    final hv = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri('https://spicychat.ai/')),
      initialSettings: spicyChatWebViewSettings(),
      onWebViewCreated: (controller) {
        _controller = controller;
        if (!created.isCompleted) created.complete();
      },
      onLoadStop: (_, _) {
        final c = _loadStop;
        if (c != null && !c.isCompleted) c.complete();
      },
    );
    await hv.run();
    _webView = hv;
    await created.future;
    await _waitLoad();
  }

  Future<void> _waitLoad() async {
    final c = _loadStop;
    if (c == null || c.isCompleted) return;
    try {
      await c.future.timeout(const Duration(seconds: 25));
    } catch (_) {}
  }

  Future<T> _enqueue<T>(Future<T> Function() task) {
    final result = Completer<T>();
    _gate = _gate.then((_) async {
      try {
        result.complete(await task());
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  Future<List<CatalogItem>> fetchCards({required String path, required int page}) =>
      _enqueue(() => _fetchCardsLocked(path: path, page: page));

  Future<List<CatalogItem>> _fetchCardsLocked({required String path, required int page}) async {
    await _ensureStarted();
    final controller = _controller;
    if (controller == null) throw Exception('SpicyChat web session could not start.');

    _loadStop = Completer<void>();
    final url = path.startsWith('http') ? path : 'https://spicychat.ai$path';
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    await _waitLoad();
    await Future<void>.delayed(const Duration(milliseconds: 700));

    final result = await controller.callAsyncJavaScript(
      functionBody: '''
        const wanted = ${page * _pageSize};
        const pause = (ms) => new Promise(r => setTimeout(r, ms));
        for (let i = 0; i < Math.min(10, Math.max(2, ${page + 1})); i++) {
          window.scrollTo(0, document.body.scrollHeight);
          await pause(350);
        }
        const out = [];
        const seen = new Set();
        const links = Array.from(document.querySelectorAll('a[href*="/chatbot/"], a[href*="/character/"]'));
        for (const a of links) {
          const href = a.href || '';
          const m = href.match(/\/(?:chatbot|character)\/([^/?#]+)/i);
          if (!m || seen.has(m[1])) continue;
          const img = a.querySelector('img');
          const text = (a.innerText || a.textContent || '').replace(/\s+/g, ' ').trim();
          const heading = a.querySelector('h1,h2,h3,h4,h5,[role="heading"]');
          const name = (heading?.textContent || img?.alt || text.split(/\n|@/)[0] || '').trim();
          if (!name || name.length > 120) continue;
          seen.add(m[1]);
          out.push({
            id: m[1],
            name,
            avatar_url: img?.currentSrc || img?.src || '',
            description: text.slice(0, 700),
            href,
          });
        }
        return out;
      ''',
    );
    final raw = result?.value;
    if (raw is! List) return const [];
    final docs = <CatalogItem>[];
    for (final entry in raw) {
      if (entry is Map) {
        docs.add(_itemFromDocument(Map<String, dynamic>.from(entry)));
      }
    }
    return docs;
  }

  Future<bool> probeController(InAppWebViewController controller) async {
    try {
      // Prefer storage/token evidence — DOM chrome changes often and was the
      // main reason sign-in looked finished on the page but the app still said
      // "Not signed in yet".
      final id = await SpicyChatSessionTools.readIdentity(controller);
      if (id.hasToken || id.email != null) return true;

      final result = await controller.callAsyncJavaScript(
        functionBody: r'''
          const visible = (el) => {
            if (!el) return false;
            const s = getComputedStyle(el);
            const r = el.getBoundingClientRect();
            return s.display !== 'none' && s.visibility !== 'hidden' && r.width > 0 && r.height > 0;
          };
          // Any auth-looking token in storage is enough.
          const authKey = /(token|access|id_token|refresh|auth|session|bearer|cognito|amplify|supabase|firebase|clerk|jwt|credential)/i;
          try {
            for (const store of [localStorage, sessionStorage]) {
              for (let i = 0; i < store.length; i++) {
                const k = store.key(i) || '';
                const v = store.getItem(k) || '';
                if (authKey.test(k) && v.length > 20) return true;
                if (/^eyJ[\w-]+\.[\w-]+\.[\w-]*$/.test(v)) return true;
              }
            }
          } catch (e) {}
          const loginVisible = Array.from(document.querySelectorAll('a,button,[role=button]')).some(el =>
            visible(el) && /\b(sign in|log in|sign up|create free account|continue with)\b/i.test((el.innerText || el.textContent || '').trim())
          );
          if (loginVisible) return false;
          const avatar = Array.from(document.querySelectorAll('img,a,button,[role=button]')).some(el => {
            if (!visible(el)) return false;
            const alt = (el.getAttribute('alt') || '').toLowerCase();
            const aria = (el.getAttribute('aria-label') || '').toLowerCase();
            return alt.includes('avatar') || aria.includes('avatar') || aria.includes('profile') || aria.includes('account');
          });
          const profile = Array.from(document.querySelectorAll('a,button,[role=button]')).some(el =>
            visible(el) && /\b(profile|account|settings|my chats|for you)\b/i.test((el.innerText || el.textContent || '').trim())
          );
          // Premium / Get Premium + no login CTA is a strong signed-in signal.
          const premium = Array.from(document.querySelectorAll('a,button,[role=button]')).some(el =>
            visible(el) && /\b(get premium|premium|manage subscription)\b/i.test((el.innerText || el.textContent || '').trim())
          );
          return avatar || profile || premium;
        ''',
      ).timeout(const Duration(seconds: 8));
      return result?.value == true;
    } catch (_) {
      return false;
    }
  }

  /// Signs the web session out for good: drops the background page, deletes
  /// every SpicyChat (and Google) cookie, then clears the site's stored
  /// tokens in the background. Nothing here waits on a page load, so it can
  /// never stall the UI, and a later sign-in always starts from a clean slate.
  Future<void> signOut() async {
    await dispose();
    await SpicyChatSessionTools.wipeCookies(includeGoogle: true);
    unawaited(_wipeStorageInBackground());
  }

  Future<void> _wipeStorageInBackground() async {
    HeadlessInAppWebView? view;
    final loaded = Completer<InAppWebViewController>();
    try {
      view = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri('https://spicychat.ai/')),
        initialSettings: spicyChatWebViewSettings(),
        onLoadStop: (controller, _) {
          if (!loaded.isCompleted) loaded.complete(controller);
        },
      );
      await view.run();
      final controller = await loaded.future.timeout(
        const Duration(seconds: 15),
      );
      await SpicyChatSessionTools.clearStorage(controller);
      // The page may have written fresh cookies while it loaded.
      await SpicyChatSessionTools.wipeCookies();
    } catch (_) {
    } finally {
      try {
        await view?.dispose();
      } catch (_) {}
    }
  }

  /// Builds a JS snippet that writes the headless webview's localStorage into
  /// another webview, so "View account" can show the same signed-in session.
  Future<String?> exportLocalStorageJs() => _enqueue(() async {
    await _ensureStarted();
    final c = _controller;
    if (c == null) return null;
    try {
      final raw = await c.evaluateJavascript(
        source:
            "(function(){try{var o={};for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i);o[k]=localStorage.getItem(k);}return JSON.stringify(o);}catch(e){return null;}})()",
      );
      if (raw == null) return null;
      var text = raw.toString().trim();
      if (text.isEmpty || text == 'null') return null;
      if (text.startsWith('"') && text.endsWith('"')) {
        text = text
            .substring(1, text.length - 1)
            .replaceAll(r'\"', '"')
            .replaceAll(r'\\', r'\');
      }
      return '(function(){try{var data=$text;'
          'if(!data)return;Object.keys(data).forEach(function(k){'
          'try{localStorage.setItem(k,data[k]);}catch(e){}});'
          '}catch(e){}})();';
    } catch (_) {
      return null;
    }
  });

  Future<bool> isLoggedIn() async {
    await _ensureStarted();
    final c = _controller;
    if (c == null) return false;
    return probeController(c);
  }

  /// Bearer token from the signed-in SpicyChat page, used for character
  /// detail (and any other) nd-api calls that now require auth.
  Future<String?> getAccessToken() async {
    await _ensureStarted();
    final c = _controller;
    if (c == null) return null;
    return SpicyChatSessionTools.readAccessToken(c);
  }

  Future<void> dispose() async {
    try {
      await _webView?.dispose();
    } catch (_) {}
    _webView = null;
    _controller = null;
    _loadStop = null;
    // Without this, _ensureStarted() saw the old, already-completed start and
    // never launched a new page: after any sign-out, login checks and the
    // For You / Recent feeds failed for the rest of the app run.
    _starting = null;
  }
}
