import 'dart:convert';

/// A userscript the app can run in its script browser.
///
/// The metadata fields come from the `// ==UserScript==` header of [code];
/// [whitelist] / [blacklist] / [enabled] / [autoUpdate] / [scope] are the
/// user's own choices and survive editing the code.
class GlazeUserScript {
  final String id;
  final String name;
  final String namespace;
  final String author;
  final String version;
  final String description;

  /// `@match` and `@include` lines.
  final List<String> matches;

  /// `@exclude` and `@exclude-match` lines.
  final List<String> excludes;

  /// `@grant` lines.
  final List<String> grants;

  /// `@require` URLs, and the code downloaded for each of them.
  final List<String> requires;
  final Map<String, String> requireCode;

  /// `document-start`, `document-end` or `document-idle`.
  final String runAt;
  final String code;

  /// Where the script was imported from (for updates); empty for hand-made.
  final String sourceUrl;
  final String updateUrl;

  final bool enabled;
  final bool autoUpdate;

  /// `default` (top frame only), `main` (top frame only) or `all` (frames too).
  final String scope;
  final List<String> whitelist;
  final List<String> blacklist;
  final int updatedMs;

  const GlazeUserScript({
    required this.id,
    required this.name,
    this.namespace = '',
    this.author = '',
    this.version = '',
    this.description = '',
    this.matches = const [],
    this.excludes = const [],
    this.grants = const [],
    this.requires = const [],
    this.requireCode = const {},
    this.runAt = 'document-end',
    required this.code,
    this.sourceUrl = '',
    this.updateUrl = '',
    this.enabled = true,
    this.autoUpdate = false,
    this.scope = 'default',
    this.whitelist = const [],
    this.blacklist = const [],
    this.updatedMs = 0,
  });

  bool get allFrames => scope == 'all';

  GlazeUserScript copyWith({
    String? name,
    String? namespace,
    String? author,
    String? version,
    String? description,
    List<String>? matches,
    List<String>? excludes,
    List<String>? grants,
    List<String>? requires,
    Map<String, String>? requireCode,
    String? runAt,
    String? code,
    String? sourceUrl,
    String? updateUrl,
    bool? enabled,
    bool? autoUpdate,
    String? scope,
    List<String>? whitelist,
    List<String>? blacklist,
    int? updatedMs,
  }) => GlazeUserScript(
    id: id,
    name: name ?? this.name,
    namespace: namespace ?? this.namespace,
    author: author ?? this.author,
    version: version ?? this.version,
    description: description ?? this.description,
    matches: matches ?? this.matches,
    excludes: excludes ?? this.excludes,
    grants: grants ?? this.grants,
    requires: requires ?? this.requires,
    requireCode: requireCode ?? this.requireCode,
    runAt: runAt ?? this.runAt,
    code: code ?? this.code,
    sourceUrl: sourceUrl ?? this.sourceUrl,
    updateUrl: updateUrl ?? this.updateUrl,
    enabled: enabled ?? this.enabled,
    autoUpdate: autoUpdate ?? this.autoUpdate,
    scope: scope ?? this.scope,
    whitelist: whitelist ?? this.whitelist,
    blacklist: blacklist ?? this.blacklist,
    updatedMs: updatedMs ?? this.updatedMs,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'namespace': namespace,
    'author': author,
    'version': version,
    'description': description,
    'matches': matches,
    'excludes': excludes,
    'grants': grants,
    'requires': requires,
    'requireCode': requireCode,
    'runAt': runAt,
    'code': code,
    'sourceUrl': sourceUrl,
    'updateUrl': updateUrl,
    'enabled': enabled,
    'autoUpdate': autoUpdate,
    'scope': scope,
    'whitelist': whitelist,
    'blacklist': blacklist,
    'updatedMs': updatedMs,
  };

  static List<String> _strings(Object? v) =>
      v is List ? [for (final e in v) if (e is String) e] : const [];

  factory GlazeUserScript.fromJson(Map<String, dynamic> j) {
    final rc = j['requireCode'];
    return GlazeUserScript(
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? 'Script',
      namespace: (j['namespace'] as String?) ?? '',
      author: (j['author'] as String?) ?? '',
      version: (j['version'] as String?) ?? '',
      description: (j['description'] as String?) ?? '',
      matches: _strings(j['matches']),
      excludes: _strings(j['excludes']),
      grants: _strings(j['grants']),
      requires: _strings(j['requires']),
      requireCode: rc is Map
          ? {
              for (final e in rc.entries)
                if (e.value is String) e.key.toString(): e.value as String,
            }
          : const {},
      runAt: (j['runAt'] as String?) ?? 'document-end',
      code: (j['code'] as String?) ?? '',
      sourceUrl: (j['sourceUrl'] as String?) ?? '',
      updateUrl: (j['updateUrl'] as String?) ?? '',
      enabled: j['enabled'] != false,
      autoUpdate: j['autoUpdate'] == true,
      scope: (j['scope'] as String?) ?? 'default',
      whitelist: _strings(j['whitelist']),
      blacklist: _strings(j['blacklist']),
      updatedMs: (j['updatedMs'] as num?)?.toInt() ?? 0,
    );
  }

  static String encodeList(List<GlazeUserScript> scripts) =>
      jsonEncode([for (final s in scripts) s.toJson()]);

  static List<GlazeUserScript> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final data = jsonDecode(raw);
      if (data is! List) return const [];
      return [
        for (final e in data)
          if (e is Map) GlazeUserScript.fromJson(Map<String, dynamic>.from(e)),
      ].where((s) => s.id.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }
}
