import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog_http.dart';
import '../catalog_models.dart';

const _searchUrl = 'https://search.jannyai.com/multi-search';
const _baseUrl = 'https://jannyai.com';
const _tokenKey = 'gz_janny_token';
const _jannyImageCdn = 'https://image.jannyai.com/bot-avatars/';
const _fallbackToken = '88a6463b66e04fb07ba87ee3db06af337f492ce511d93df6e2d2968cb2ff2b30';

Future<String> _fetchSearchToken() async {
  try {
    final html = await catalogGetText('$_baseUrl/characters/search', {
      'Origin': _baseUrl,
      'Referer': '$_baseUrl/',
    });

    String? configPath;
    final configMatch = RegExp(r'client-config\.[a-zA-Z0-9_-]+\.js').firstMatch(html);
    if (configMatch != null) {
      configPath = '/_astro/${configMatch.group(0)}';
    } else {
      final spMatch = RegExp(r'SearchPage\.[a-zA-Z0-9_-]+\.js').firstMatch(html);
      if (spMatch != null) {
        final spJs = await catalogGetText('$_baseUrl/_astro/${spMatch.group(0)}', {
          'Referer': '$_baseUrl/',
        });
        final impMatch = RegExp(r'client-config\.[a-zA-Z0-9_-]+\.js').firstMatch(spJs);
        if (impMatch != null) configPath = '/_astro/${impMatch.group(0)}';
      }
    }

    if (configPath != null) {
      final configJs = await catalogGetText('$_baseUrl$configPath', {
        'Referer': '$_baseUrl/',
      });
      final tokenMatch = RegExp(r'"([a-f0-9]{64})"').firstMatch(configJs);
      if (tokenMatch != null) return tokenMatch.group(1)!;
    }

    return _fallbackToken;
  } catch (_) {
    return _fallbackToken;
  }
}

Future<String> _getSearchToken() async {
  final prefs = await SharedPreferences.getInstance();
  final cached = prefs.getString(_tokenKey);
  if (cached != null) return cached;

  final token = await _fetchSearchToken();
  await prefs.setString(_tokenKey, token);
  return token;
}

Future<void> _clearSearchToken() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_tokenKey);
}

Map<String, String> _jannyHeaders(String token) => {
      'Accept': '*/*',
      'Authorization': 'Bearer $token',
      'Origin': _baseUrl,
      'Referer': '$_baseUrl/',
      'x-meilisearch-client': 'Meilisearch instant-meilisearch (v0.19.0) ; Meilisearch JavaScript (v0.41.0)',
    };

String? _resolveJannyAvatar(String? url) {
  if (url == null) return null;
  if (url.startsWith('http')) return url;
  if (!url.contains('/')) return '$_jannyImageCdn$url';
  return url;
}

String _slugify(String text) {
  return text
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'[^\w-]+'), '')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-+'), '')
      .replaceAll(RegExp(r'-+$'), '');
}

String _stripHtml(String html) {
  return html
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&=quot;', '"')
      .replaceAll('&=#39;', "'")
      .replaceAll('&amp;', '&');
}

dynamic _decodeAstroValue(dynamic value) {
  if (value is! List) return value;
  if (value.length < 2) return value;
  final type = value[0];
  final data = value[1];
  if (type == 0) {
    if (data is Map) {
      final decoded = <String, dynamic>{};
      for (final entry in data.entries) {
        decoded[entry.key as String] = _decodeAstroValue(entry.value);
      }
      return decoded;
    }
    return data;
  } else if (type == 1 && data is List) {
    return data.map(_decodeAstroValue).toList();
  }
  return data;
}


class _JannyStats {
  final int chats;
  final int messages;
  const _JannyStats({this.chats = 0, this.messages = 0});
}

final Map<String, _JannyStats> _jannyStatsCache = {};

int _parseJannyCount(String value) {
  var text = value.trim().toLowerCase().replaceAll(',', '');
  if (text.isEmpty) return 0;
  final match = RegExp(r'^(\d+(?:\.\d+)?)([km])?$').firstMatch(text);
  if (match == null) return int.tryParse(text) ?? 0;
  final number = double.tryParse(match.group(1)!) ?? 0;
  final suffix = match.group(2);
  final multiplier = suffix == 'm' ? 1000000 : suffix == 'k' ? 1000 : 1;
  return (number * multiplier).round();
}

String _jannyVisibleText(String html) {
  return html
      .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\s+'), ' ');
}

_JannyStats _parseJannyStats(String html) {
  final text = _jannyVisibleText(html);

  String? afterEmoji(String emoji) {
    final match = RegExp(RegExp.escape(emoji) + r'\s*([0-9]+(?:[.,][0-9]+)?[km]?)', caseSensitive: false)
        .firstMatch(text);
    return match?.group(1);
  }

  // Janny's character pages currently expose these figures as:
  // 👁️ views, 💾 bookmarks, 🗣️ chats, 💬 messages. The Glaze card uses the
  // message figure first, then the chat figure, so preserve that meaning.
  final chats = afterEmoji('🗣️') ?? afterEmoji('🗣') ?? '0';
  final messages = afterEmoji('💬') ?? '0';
  return _JannyStats(
    chats: _parseJannyCount(chats),
    messages: _parseJannyCount(messages),
  );
}

final Dio _jannyStatsDio = Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 4),
    receiveTimeout: const Duration(seconds: 4),
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    },
  ),
);

Future<_JannyStats?> _fetchJannyStats(CatalogItem item) async {
  if (item.chatCount > 0 || item.messageCount > 0) {
    return _JannyStats(chats: item.chatCount, messages: item.messageCount);
  }
  final cached = _jannyStatsCache[item.id];
  if (cached != null) return cached;
  final slug = item.slug;
  if (slug == null || slug.isEmpty) return null;

  final urls = [
    'https://api.jannyai.com/characters/${Uri.encodeComponent(item.id)}_$slug',
    '$_baseUrl/characters/${Uri.encodeComponent(item.id)}_$slug',
  ];

  for (final url in urls) {
    try {
      final response = await _jannyStatsDio.get<String>(url);
      final html = response.data ?? '';
      if (html.isEmpty) continue;
      final stats = _parseJannyStats(html);
      if (stats.chats > 0 || stats.messages > 0) {
        _jannyStatsCache[item.id] = stats;
        return stats;
      }
    } catch (_) {
      // The listing must remain usable when Janny blocks a detail page.
    }
  }
  return null;
}

Future<List<CatalogItem>> _enrichJannyStats(List<CatalogItem> items) async {
  if (items.isEmpty) return items;
  final stats = await Future.wait(items.map(_fetchJannyStats));
  return [
    for (var i = 0; i < items.length; i++)
      if (stats[i] != null)
        items[i].copyWith(
          chatCount: stats[i]!.chats,
          messageCount: stats[i]!.messages,
        )
      else
        items[i],
  ];
}

CatalogItem _normalizeJannyHit(Map<String, dynamic> hit) {
  final isNsfw = hit['isNsfw'] as bool? ?? false;
  var slug = _slugify((hit['slug'] ?? hit['name'] ?? hit['id'] ?? '') as String);
  if (slug.isNotEmpty && !slug.startsWith('character-')) {
    slug = 'character-$slug';
  }

  int intField(List<String> keys) {
    for (final key in keys) {
      final value = hit[key];
      if (value is num) return value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value);
        if (parsed != null) return parsed;
      }
    }
    return 0;
  }

  return CatalogItem(
    id: (hit['id'] ?? '') as String,
    name: (hit['name'] ?? 'Unknown') as String,
    avatarUrl: _resolveJannyAvatar(hit['avatar'] as String?),
    description: (hit['description'] ?? '') as String,
    tags: [isNsfw ? 'NSFW' : 'SFW'],
    tokens: (hit['totalToken'] ?? 0) as int,
    // Janny has changed the public search field names over time. Prefer the
    // message/chat figure for the catalog badge, falling back to the alternate
    // spellings used by older search indexes.
    chatCount: intField(['chatCount', 'chat_count', 'chats', 'downloads']),
    messageCount: intField([
      'messageCount',
      'message_count',
      'messages',
      'publicMessageCount',
      'public_message_count',
    ]),
    creator: (hit['creatorUsername'] ?? '') as String,
    creatorId: (hit['creatorId'] ?? '') as String?,
    nsfw: isNsfw,
    slug: slug,
    source: 'janny',
  );
}

/// The multi-search body for one attempt.
///
/// Only the fields whose answers are actually read are sent. The request used
/// to also ask for `facets`, `attributesToHighlight`, `attributesToCrop` and a
/// `cropMarker`; all four land in Meilisearch's `_formatted` block or its facet
/// distribution, neither of which this file ever looks at — and each one is a
/// clause the backend can reject with a 400 the moment its index configuration
/// changes. Asking for nothing we do not read removes four ways for search to
/// die outright.
Map<String, dynamic> _jannyBody({
  required String query,
  required int page,
  required List<String> filters,
  required List<String> sort,
}) => {
      'queries': [
        {
          'indexUid': 'janny-characters',
          'q': query,
          if (filters.isNotEmpty) 'filter': filters.join(' AND '),
          'hitsPerPage': 40,
          'page': page,
          if (sort.isNotEmpty) 'sort': sort,
        }
      ],
    };

Future<CatalogSearchResult> _jannyResult(Map<String, dynamic> data) async {
  final result = (data['results'] as List?)?.firstOrNull as Map<String, dynamic>? ?? {};
  final items = ((result['hits'] as List?) ?? [])
      .cast<Map<String, dynamic>>()
      .map(_normalizeJannyHit)
      .toList();
  final enriched = await _enrichJannyStats(items);
  return CatalogSearchResult(
    characters: enriched,
    total: (result['totalHits'] as int?) ?? 0,
  );
}

/// POSTs one search body, re-fetching the search token once if the current one
/// is refused.
///
/// The token is scraped out of Janny's own page bundle and cached; when the
/// site rotates it the cached copy starts answering 401/403, and the shipped
/// fallback is the only thing left to try.
Future<Map<String, dynamic>> _jannyMultiSearch(Map<String, dynamic> body) async {
  final token = await _getSearchToken();
  try {
    return await catalogPost(_searchUrl, body, _jannyHeaders(token));
  } on DioException catch (e) {
    final status = catalogErrorStatus(e);
    if (status != 401 && status != 403) rethrow;
    await _clearSearchToken();
    return catalogPost(_searchUrl, body, _jannyHeaders(_fallbackToken));
  }
}

Future<CatalogSearchResult> jannySearch({
  String query = '',
  int page = 1,
  CatalogFilters filters = const CatalogFilters(),
}) async {
  // Split in two on purpose. The NSFW clause is the user's own setting about
  // what they are willing to see, so it is never dropped to make a search
  // work: a degraded search that answers with what somebody asked to be
  // spared is worse than no answer. Everything else is a preference.
  final mandatory = <String>[
    if (!filters.nsfw) 'isNsfw = false',
  ];
  final minTok = filters.minTokens > 0 ? filters.minTokens : 29;
  final preferred = <String>[
    'totalToken >= $minTok',
    if (filters.maxTokens < 100000) 'totalToken <= ${filters.maxTokens}',
    ...filters.tagIds.map((id) => 'tagIds = $id'),
  ];

  const sortMap = <String, List<String>>{
    'newest': ['createdAtStamp:desc'],
    'oldest': ['createdAtStamp:asc'],
    'tokens_desc': ['totalToken:desc'],
    'tokens_asc': ['totalToken:asc'],
    'relevant': [],
  };
  final sortArr = sortMap[filters.sort] ?? sortMap['newest']!;

  // Janny's search is a Meilisearch instance whose index configuration is
  // theirs to change, and it answers a clause it no longer supports with a 400
  // naming the syntax — which is fatal where a 401 is not, because nothing
  // retried it. The report is exactly that: search stopped working outright.
  // So a rejected search is asked again more plainly, sortable and filterable
  // attributes being the two that stop being either.
  final attempts = <Map<String, dynamic>>[
    _jannyBody(
      query: query,
      page: page,
      filters: [...mandatory, ...preferred],
      sort: sortArr,
    ),
    if (sortArr.isNotEmpty)
      _jannyBody(
        query: query,
        page: page,
        filters: [...mandatory, ...preferred],
        sort: const [],
      ),
    if (preferred.isNotEmpty)
      _jannyBody(query: query, page: page, filters: mandatory, sort: const []),
  ];

  for (var i = 0; i < attempts.length; i++) {
    try {
      return await _jannyResult(await _jannyMultiSearch(attempts[i]));
    } on DioException catch (e) {
      final isLast = i == attempts.length - 1;
      if (isLast || catalogErrorStatus(e) != 400) rethrow;
    }
  }
  throw StateError('unreachable: the last attempt either returns or throws');
}

Future<DownloadedCharacter> jannyFetchCharacter(String characterId, String? slug) async {
  var effectiveSlug = _slugify(slug ?? 'character');
  if (!effectiveSlug.startsWith('character-')) {
    effectiveSlug = 'character-$effectiveSlug';
  }

  final html = await catalogGetText(
    '$_baseUrl/characters/${characterId}_$effectiveSlug',
    {
      'Origin': 'https://jannyai.com',
      'Referer': 'https://jannyai.com/',
      'Accept': 'text/html',
    },
  );

  var astroMatch = RegExp(r'astro-island[^>]*component-export="CharacterButtons"[^>]*props="([^"]+)"').firstMatch(html);
  astroMatch ??= RegExp(r'astro-island[^>]*props="([^"]*character[^"]*)"').firstMatch(html);

  if (astroMatch == null) {
    throw Exception('Could not parse JannyAI character page');
  }

  final propsDecoded = astroMatch
      .group(1)!
      .replaceAll('&quot;', '"')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&#39;', "'");

  final propsJson = Map<String, dynamic>.from(
    (await _parseJson(propsDecoded)) as Map,
  );
  final character = _decodeAstroValue(propsJson['character']) as Map<String, dynamic>;
  final imageUrl = _decodeAstroValue(propsJson['imageUrl']) as String?;

  String? creatorUsername;
  final creatorMatch = RegExp(r'Creator:\s*(?:</[^>]+>\s*)?<a[^>]*>@?([^<]+)</a>').firstMatch(html);
  if (creatorMatch != null) creatorUsername = creatorMatch.group(1)?.trim();

  return DownloadedCharacter(
    charData: CharacterData(
      name: (character['name'] ?? 'Unnamed') as String,
      // Janny keeps the definition in `personality` and the blurb in
      // `description`; the definition goes to the prompt body field.
      description: (character['personality'] ?? '') as String,
      personality: '',
      scenario: (character['scenario'] ?? '') as String,
      firstMes: (character['firstMessage'] ?? '') as String,
      mesExample: (character['exampleDialogs'] ?? '') as String,
      creatorNotes: _stripHtml((character['description'] ?? '') as String),
      systemPrompt: '',
      postHistoryInstructions: '',
      alternateGreetings: const [],
      tags: [],
      creator: creatorUsername ?? (character['creatorId'] ?? '') as String,
      creatorId: (character['creatorId'] ?? '') as String,
      characterBook: null,
    ),
    avatarUrl: imageUrl != null ? _resolveJannyAvatar(imageUrl) : null,
  );
}

Future<dynamic> _parseJson(String text) async {
  return _simpleJsonDecode(text);
}

dynamic _simpleJsonDecode(String s) {
  return _JsonParser(s).parseValue();
}

class _JsonParser {
  final String s;
  int i = 0;
  _JsonParser(this.s);

  dynamic parseValue() {
    _ws();
    if (i >= s.length) throw FormatException('Unexpected end');
    switch (s[i]) {
      case '{':
        return parseObject();
      case '[':
        return parseArray();
      case '"':
        return parseString();
      case 't':
        i += 4;
        return true;
      case 'f':
        i += 5;
        return false;
      case 'n':
        i += 4;
        return null;
      default:
        return parseNumber();
    }
  }

  Map<String, dynamic> parseObject() {
    i++;
    final result = <String, dynamic>{};
    _ws();
    if (i < s.length && s[i] == '}') {
      i++;
      return result;
    }
    while (i < s.length) {
      _ws();
      final key = parseString();
      _ws();
      i++;
      final value = parseValue();
      result[key] = value;
      _ws();
      if (i < s.length && s[i] == '}') {
        i++;
        break;
      }
      i++;
    }
    return result;
  }

  List<dynamic> parseArray() {
    i++;
    final result = <dynamic>[];
    _ws();
    if (i < s.length && s[i] == ']') {
      i++;
      return result;
    }
    while (i < s.length) {
      result.add(parseValue());
      _ws();
      if (i < s.length && s[i] == ']') {
        i++;
        break;
      }
      i++;
    }
    return result;
  }

  String parseString() {
    i++;
    final buf = StringBuffer();
    while (i < s.length && s[i] != '"') {
      if (s[i] == '\\' && i + 1 < s.length) {
        i++;
        switch (s[i]) {
          case 'n':
            buf.write('\n');
          case 't':
            buf.write('\t');
          case 'r':
            buf.write('\r');
          case '\\':
            buf.write('\\');
          case '"':
            buf.write('"');
          case 'u':
            final hex = s.substring(i + 1, i + 5);
            buf.write(String.fromCharCode(int.parse(hex, radix: 16)));
            i += 4;
          default:
            buf.write(s[i]);
        }
      } else {
        buf.write(s[i]);
      }
      i++;
    }
    i++;
    return buf.toString();
  }

  num parseNumber() {
    final start = i;
    if (i < s.length && s[i] == '-') i++;
    while (i < s.length && (s[i].isDigit || s[i] == '.' || s[i] == 'e' || s[i] == 'E' || s[i] == '+' || s[i] == '-')) {
      i++;
    }
    return num.parse(s.substring(start, i));
  }

  void _ws() {
    while (i < s.length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t')) {
      i++;
    }
  }
}

extension on String {
  bool get isDigit => codeUnitAt(0) >= 48 && codeUnitAt(0) <= 57;
}
