import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../catalog_models.dart';
import 'crushon_description.dart';
import 'crushon_session.dart';
import 'crushon_site_reader.dart';

export 'crushon_site_reader.dart'
    show
        CrushOnDailyInfo,
        CrushOnImageHints,
        CrushOnReaderException,
        CrushOnSuperseded,
        crushOnDailyInfo;

/// CrushOn.AI catalog integration.
///
/// **How it works (v18+).** CrushOn is a Next.js single-page app. Choosing a
/// sort ("Popular", "Daily Ranking"…) never changes the URL, and the list is an
/// infinite scroll with no page numbers, so there is no URL to request and the
/// private tRPC API cannot be guessed reliably (earlier builds tried, and
/// returned wrong / empty lists). Instead [CrushOnSiteReader] opens the real
/// site in a hidden browser, clicks the real controls, scrolls the real list,
/// and reports cards in the exact order the site shows them. What you see in
/// Glaze is therefore what the site shows.

const _siteOrigin = 'https://crushon.ai';
const _pageSize = 24;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Browse / search CrushOn characters. [page] is 1-based.
Future<CatalogSearchResult> crushonSearch({
  String query = '',
  int page = 1,
  int limit = _pageSize,
  CatalogFilters filters = const CatalogFilters(),
}) async {
  await CrushOnWebSession.instance.ensureLoaded();
  final from = (page - 1) * limit;
  final to = page * limit;
  final reader = CrushOnSiteReader.instance;

  final CrushOnPage result;
  if (query.trim().isNotEmpty) {
    result = await reader.search(
      query: query.trim(),
      nsfw: filters.nsfw,
      from: from,
      to: to,
    );
  } else {
    final w = filters.window.trim();
    final date = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(w) ? w : null;
    result = await reader.browse(
      sortKey: crushonSortKey(filters.sort),
      nsfw: filters.nsfw,
      tags: filters.tagNames
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList(),
      date: date,
      from: from,
      to: to,
    );
  }
  // Daily Ranking: show the site's own position badge. When the page did not
  // print one the card is still numbered by its place in the list (the site
  // lists the ranking in order, so place N is rank N).
  final ranked = query.trim().isEmpty &&
      crushonSortKey(filters.sort) == 'daily_ranking';
  final items = <CatalogItem>[];
  for (var i = 0; i < result.items.length; i++) {
    final it = _itemFromRead(result.items[i]);
    items.add(ranked
        ? it.copyWith(
            rank: result.items[i].rank ?? (from + i + 1),
            rankNote: result.items[i].rankNote,
          )
        : it);
  }
  return CatalogSearchResult(
    characters: items,
    total: from + items.length + (result.hasMore ? 1 : 0),
    hasMore: result.hasMore,
  );
}

/// One page of the signed-in account's favorites, read from the site's own
/// Favorites section.
Future<CatalogSearchResult> crushonFavoritesPage({
  required int page,
  String sort = 'new',
  bool nsfw = true,
  int limit = _pageSize,
}) async {
  await CrushOnWebSession.instance.ensureLoaded();
  final from = (page - 1) * limit;
  final result = await CrushOnSiteReader.instance.favorites(
    sortKey: crushonFavoritesSortKey(sort),
    nsfw: nsfw,
    from: from,
    to: page * limit,
  );
  final items = result.items.map(_itemFromRead).toList();
  return CatalogSearchResult(
    characters: items,
    total: from + items.length + (result.hasMore ? 1 : 0),
    hasMore: result.hasMore,
  );
}

/// Favorites as a plain list (used by the merged All-Providers favorites).
Future<List<CatalogItem>> crushonFetchFavorites({int page = 1}) async =>
    (await crushonFavoritesPage(page: page)).characters;

/// The profile's favourites list only offers two orders: the site's "Latest"
/// (Glaze key `new`) and "Popular". Any other sort key (Trending, Daily
/// Ranking...) means "the default", which on the site is Latest.
String crushonFavoritesSortKey(String sort) =>
    crushonSortKey(sort) == 'popular' ? 'popular' : 'new';

/// Map Glaze / legacy sort strings to the canonical Glaze CrushOn sort keys.
String crushonSortKey(String sort) {
  final s = sort.toLowerCase().trim().replaceAll(RegExp(r'[\s-]+'), '_');
  switch (s) {
    case 'popular':
    case 'most_popular':
      return 'popular';
    case 'recent_hits':
    case 'recenthits':
    case 'recent':
      return 'recent_hits';
    case 'trending':
      return 'trending';
    case 'new':
    case 'newest':
    case 'latest':
      return 'new';
    case 'daily_ranking':
    case 'dailyranking':
    case 'daily':
      return 'daily_ranking';
    case 'editor_choice':
    case 'editors_choice':
    case 'editor':
    case 'editors':
      return 'editor_choice';
    case 'following':
      return 'following';
    default:
      return 'recent_hits';
  }
}

// ---------------------------------------------------------------------------
// Tags
// ---------------------------------------------------------------------------

/// Seed vocabulary from the site's tag chips, extended at runtime with every
/// tag seen on a real card, so the filter sheet is never blank.
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

final Set<String> _discoveredTags = <String>{};

String _tagKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

Future<List<CatalogTag>> fetchCrushonTags() async {
  final byKey = <String, CatalogTag>{};
  for (final name in [..._kCrushonKnownTags, ..._discoveredTags]) {
    byKey.putIfAbsent(_tagKey(name), () => CatalogTag(name: name));
  }
  final tags = byKey.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return tags;
}

// ---------------------------------------------------------------------------
// Character detail / import
// ---------------------------------------------------------------------------

/// Fetch a single character for import by opening its real page and reading
/// everything the page loaded (its own JSON, `__NEXT_DATA__`, meta tags).
Future<DownloadedCharacter> crushonFetchCharacter(
  String id, {
  CatalogItem? card,
}) async {
  DownloadedCharacter? found;
  try {
    final page = await CrushOnSiteReader.instance.characterPage(id);
    found = _characterFromPage(page, id);
    found = _withDescriptions(found, page);
  } catch (e) {
    debugPrint('CrushOn character page read failed: $e');
    // Only a sign-in/Cloudflare style failure with no list-card data to fall
    // back on is worth surfacing; otherwise the card below is still a usable
    // import.
    if (e is CrushOnReaderException && card == null) rethrow;
  }
  return _mergeWithCard(found, id, card);
}

/// Two descriptions per CrushOn character:
///  * display: the site's styled HTML (pictures, colours, tables). Saved in the
///    creator-notes slot, which the app renders richly and never sends to the
///    model.
///  * memory: only the words (profile lines, personality, background...), saved
///    in the normal description field that goes into the prompt.
DownloadedCharacter? _withDescriptions(
  DownloadedCharacter? d,
  Map<String, dynamic> page,
) {
  final c = d?.charData;
  final info = page['info'];
  var infoHtml = info is Map ? (info['html'] ?? '').toString().trim() : '';
  var infoText = info is Map ? (info['text'] ?? '').toString().trim() : '';
  var jsonDesc = (c?.description ?? '').trim();
  // Never keep the site's "404 Page Not Found" page or its generic meta blurb
  // as a character's description.
  if (crushonLooksLikeNotFound(infoHtml) || crushonLooksLikeNotFound(infoText)) {
    infoHtml = '';
    infoText = '';
  }
  if (crushonLooksLikeNotFound(jsonDesc) || crushonIsGenericSiteBlurb(jsonDesc)) {
    jsonDesc = '';
  }

  String display = '';
  if (infoHtml.isNotEmpty) {
    display = infoHtml;
  } else if (looksLikeHtml(jsonDesc)) {
    display = jsonDesc;
  }
  if (display.isEmpty && infoText.isEmpty) return d;

  var memory = display.isNotEmpty ? crushonMemoryText(display) : '';
  if (memory.isEmpty && infoText.isNotEmpty) memory = infoText;
  final jsonPlain = jsonDesc.isEmpty ? '' : crushonPlainDescription(jsonDesc);
  if (jsonPlain.length > memory.length) memory = jsonPlain;

  final oldNotes = (c?.creatorNotes ?? '').trim();
  final notes = display.isEmpty
      ? oldNotes
      : (oldNotes.isEmpty || oldNotes == display
          ? display
          : '$display\n\n$oldNotes');

  final base = c ?? CharacterData(name: '');
  return DownloadedCharacter(
    charData: CharacterData(
      name: base.name,
      description: memory,
      personality: base.personality,
      scenario: base.scenario,
      firstMes: base.firstMes,
      mesExample: base.mesExample,
      creatorNotes: notes,
      systemPrompt: base.systemPrompt,
      postHistoryInstructions: base.postHistoryInstructions,
      alternateGreetings: base.alternateGreetings,
      tags: base.tags,
      creator: base.creator,
      creatorId: base.creatorId,
      characterBook: base.characterBook,
    ),
    avatarUrl: d?.avatarUrl,
    avatarBytes: d?.avatarBytes,
  );
}

/// Tag names only: no ids/UUIDs, no '#', no duplicates, no empty pieces.
List<String> _cleanTags(List<String> raw) {
  final seen = <String>{};
  final out = <String>[];
  for (var t in raw) {
    t = t.trim().replaceFirst(RegExp(r'^#+'), '').trim();
    if (t.isEmpty || t.length > 40) continue;
    if (RegExp(r'^\d+$').hasMatch(t)) continue;
    if (RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}$').hasMatch(t)) continue;
    if (seen.add(t.toLowerCase())) out.add(t);
  }
  return out;
}

/// The page read is often thin (or empty) because the site does not publish a
/// documented schema. The list card already has the name, picture, tags and
/// creator the user saw, so fill every gap from it instead of importing an
/// empty character titled with the raw id.
DownloadedCharacter _mergeWithCard(
  DownloadedCharacter? d,
  String id,
  CatalogItem? card,
) {
  final c = d?.charData;
  String pick(String? a, String? b) =>
      (a != null && a.trim().isNotEmpty) ? a : (b ?? '');
  final pageName = (c?.name ?? '').trim();
  final nameIsId = pageName.isEmpty || pageName == id;
  final name = nameIsId ? ((card?.name ?? '').trim().isNotEmpty ? card!.name : id) : pageName;
  final data = CharacterData(
    name: name,
    description: pick(c?.description, card?.description),
    personality: c?.personality ?? '',
    scenario: c?.scenario ?? '',
    firstMes: c?.firstMes ?? '',
    mesExample: c?.mesExample ?? '',
    creatorNotes: c?.creatorNotes ?? '',
    systemPrompt: c?.systemPrompt ?? '',
    postHistoryInstructions: c?.postHistoryInstructions ?? '',
    alternateGreetings: c?.alternateGreetings ?? const [],
    tags: () {
      final fromPage = _cleanTags(c?.tags ?? const []);
      return fromPage.isNotEmpty ? fromPage : _cleanTags(card?.tags ?? const []);
    }(),
    creator: pick(c?.creator, card?.creator),
    creatorId: pick(c?.creatorId, card?.creatorId),
    characterBook: c?.characterBook,
  );
  final avatar = (d?.avatarUrl != null && d!.avatarUrl!.isNotEmpty)
      ? d.avatarUrl
      : card?.avatarUrl;
  return DownloadedCharacter(
    charData: data,
    avatarUrl: avatar,
    avatarBytes: d?.avatarBytes,
  );
}

bool _hasUsableDefinition(DownloadedCharacter d) {
  final c = d.charData;
  return c.personality.isNotEmpty ||
      c.firstMes.isNotEmpty ||
      c.scenario.isNotEmpty ||
      c.description.isNotEmpty;
}

bool _rawMatchesId(Map<String, dynamic> m, String id) {
  for (final k in const ['id', 'characterId', 'uuid', 'slug']) {
    final v = m[k];
    if (v != null && v.toString() == id) return true;
  }
  return false;
}

DownloadedCharacter? _characterFromPage(Map<String, dynamic> page, String id) {
  // 1) JSON the page itself fetched for this character.
  final merged = <String, dynamic>{};
  final raws = page['raws'];
  if (raws is List) {
    for (final r in raws) {
      if (r is Map) {
        final m = Map<String, dynamic>.from(r);
        if (_rawMatchesId(m, id)) merged.addAll(m);
      }
    }
  }
  // 2) Server-rendered state.
  if (merged.isEmpty && page['nextData'] is String) {
    try {
      final root = jsonDecode(page['nextData'] as String);
      final found = _findCharacterInTree(root);
      if (found != null) merged.addAll(found);
    } catch (_) {}
  }
  if (merged.isNotEmpty) {
    if (_firstString(merged, ['name', 'characterName', 'title']) == null) {
      final og = page['og'];
      if (og is Map && (og['title'] ?? '').toString().isNotEmpty) {
        merged['name'] = og['title'].toString();
      }
    }
    return _characterFromApiMap(merged, id);
  }
  // 3) Meta tags.
  final og = page['og'];
  if (og is Map) {
    final title = (og['title'] ?? '').toString();
    if (title.trim().isNotEmpty) {
      final image = (og['image'] ?? '').toString();
      return DownloadedCharacter(
        charData: CharacterData(
          name: title.replaceAll(RegExp(r'\s*[|\-–].*$'), '').trim(),
          description: crushonIsGenericSiteBlurb((og['description'] ?? '').toString())
              ? ''
              : (og['description'] ?? '').toString(),
        ),
        avatarUrl: image.isEmpty ? null : _avatarUrl(image),
      );
    }
  }
  return null;
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
  // The site's full description (often styled HTML) is the longest of these;
  // the short blurb ('introduction', 'brief'...) must not win over it.
  var description = '';
  for (final k in const [
    'description',
    'introduction',
    'brief',
    'summary',
    'shortDescription',
  ]) {
    final v = d[k];
    if (v is String && v.trim().length > description.length) {
      description = v.trim();
    }
  }
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
// Mapping
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
    final out = <String>[];
    for (final e in value) {
      if (e is Map) {
        // CrushOn tags are often {label, name, slug, description, nsfw, ...}
        final label = _asString(e['label'] ?? e['name'] ?? e['tag'] ?? e['slug']);
        if (label.isNotEmpty) out.add(label);
      } else {
        final s = _asString(e);
        if (s.isNotEmpty) out.add(s);
      }
    }
    return out.toSet().toList();
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

/// Absolute http(s) URL, untouched otherwise. The URL the site serves is the
/// URL we use: rewriting it (stripping `/thumb/`, size params…) produced dead
/// links and odd crops in earlier builds.
String _avatarUrl(dynamic raw) {
  if (raw is Map) {
    raw = raw['url'] ??
        raw['src'] ??
        raw['href'] ??
        raw['large'] ??
        raw['original'] ??
        raw['full'] ??
        raw['avatar'] ??
        raw['image'];
  }
  var value = _asString(raw);
  if (value.isEmpty) return '';
  if (value.startsWith('//')) value = 'https:$value';
  if (value.startsWith('/')) value = '$_siteOrigin$value';
  if (!(value.startsWith('http://') || value.startsWith('https://'))) {
    if (value.startsWith('data:') || value.startsWith('blob:')) return '';
    value = '$_siteOrigin/$value';
  }
  // next/image wrapper -> the original asset.
  final u = Uri.tryParse(value);
  if (u != null && u.path.contains('/_next/image')) {
    final inner = u.queryParameters['url'];
    if (inner != null && inner.isNotEmpty) {
      return _avatarUrl(inner);
    }
  }
  return value;
}

String _imageFromRaw(Map<String, dynamic> raw) {
  for (final k in const [
    'avatarUrl',
    'avatar_url',
    'avatar',
    'imageUrl',
    'image_url',
    'image',
    'coverUrl',
    'cover_url',
    'cover',
    'poster',
    'picture',
    'thumbnailUrl',
    'thumbnail_url',
    'thumbnail',
  ]) {
    final v = raw[k];
    if (v == null) continue;
    final url = _avatarUrl(v);
    if (url.isNotEmpty) return url;
  }
  return '';
}

CatalogItem _itemFromRead(CrushOnReadItem r) {
  final raw = r.raw ?? const <String, dynamic>{};
  final tags = _stringList(
    _firstValue(raw, ['tags', 'tagNames', 'tag_names', 'labelList', 'labels']),
  );
  _discoveredTags.addAll(tags);

  final name = _firstString(raw, ['name', 'characterName', 'character_name', 'title']) ??
      (r.name.isNotEmpty ? r.name : 'CrushOn character');

  final fromRaw = _imageFromRaw(raw);
  final avatar = fromRaw.isNotEmpty ? fromRaw : _avatarUrl(r.img);

  final description = _firstString(raw, [
        'introduction',
        'description',
        'brief',
        'summary',
        'shortDescription',
        'short_description',
        'blurb',
        'greeting',
      ]) ??
      '';

  final nsfw = raw['nsfw'] == true ||
      raw['isNsfw'] == true ||
      raw['is_nsfw'] == true ||
      tags.any((t) => t.toLowerCase() == 'nsfw' || t.toLowerCase() == 'smut');

  final chatCount = _asInt(_firstValue(raw, [
    'chatCount',
    'chat_count',
    'chats',
    'messageCount',
    'message_count',
    'messages',
    'interactionCount',
  ]));
  final tokens = _asInt(_firstValue(raw, ['tokens', 'tokenCount', 'token_count']));

  var path = r.href;
  final uri = Uri.tryParse(path);
  if (uri != null && uri.hasScheme) path = uri.path;
  if (path.isEmpty) path = '/character/${r.id}';

  return CatalogItem(
    id: r.id,
    name: name,
    avatarUrl: avatar.isEmpty ? null : avatar,
    description: description,
    tags: tags,
    tokens: tokens,
    chatCount: chatCount,
    messageCount: chatCount,
    creator: _firstString(raw, [
      'creatorName',
      'creator',
      'author',
      'username',
      'userName',
      'creator_username',
    ]),
    creatorId: _firstString(raw, [
      'creatorId',
      'userId',
      'authorId',
      'creator_id',
      'user_id',
    ]),
    nsfw: nsfw,
    slug: _firstString(raw, ['slug']),
    source: 'crushon',
    fullPath: path,
    sourceKind: 'crushon',
  );
}
