import '../models/user_script.dart';

/// Reads the `// ==UserScript==` header of a userscript.
class UserScriptHeader {
  final Map<String, List<String>> fields;
  const UserScriptHeader(this.fields);

  String first(String key) {
    final v = fields[key];
    return v == null || v.isEmpty ? '' : v.first;
  }

  List<String> all(String key) => fields[key] ?? const [];

  bool get isEmpty => fields.isEmpty;

  /// Parses the metadata block. Returns an empty header when there is none.
  static UserScriptHeader parse(String code) {
    final start = code.indexOf('==UserScript==');
    if (start < 0) return const UserScriptHeader({});
    final end = code.indexOf('==/UserScript==', start);
    if (end < 0) return const UserScriptHeader({});
    final block = code.substring(start + '==UserScript=='.length, end);
    final fields = <String, List<String>>{};
    final line = RegExp(r'^\s*//\s*@([\w:-]+)\s*(.*?)\s*$');
    for (final raw in block.split('\n')) {
      final m = line.firstMatch(raw.replaceAll('\r', ''));
      if (m == null) continue;
      final key = m.group(1)!.toLowerCase();
      final value = m.group(2) ?? '';
      // Localised names/descriptions (`@name:de`) are ignored.
      if (key.contains(':')) continue;
      fields.putIfAbsent(key, () => []).add(value);
    }
    return UserScriptHeader(fields);
  }
}

/// Builds a [GlazeUserScript] from source code, keeping the user's choices from
/// [previous] when the code of an existing script is replaced.
GlazeUserScript userScriptFromCode(
  String code, {
  required String id,
  String sourceUrl = '',
  GlazeUserScript? previous,
}) {
  final h = UserScriptHeader.parse(code);
  final matches = [...h.all('match'), ...h.all('include')];
  final excludes = [...h.all('exclude'), ...h.all('exclude-match')];
  var runAt = h.first('run-at').toLowerCase();
  if (!const ['document-start', 'document-end', 'document-idle']
      .contains(runAt)) {
    runAt = 'document-end';
  }
  final name = h.first('name');
  return GlazeUserScript(
    id: id,
    name: name.isNotEmpty ? name : (previous?.name ?? 'Untitled script'),
    namespace: h.first('namespace'),
    author: h.first('author'),
    version: h.first('version'),
    description: h.first('description'),
    matches: matches,
    excludes: excludes,
    grants: h.all('grant'),
    requires: h.all('require'),
    requireCode: previous?.requireCode ?? const {},
    runAt: runAt,
    code: code,
    sourceUrl: sourceUrl.isNotEmpty ? sourceUrl : (previous?.sourceUrl ?? ''),
    updateUrl: h.first('updateurl').isNotEmpty
        ? h.first('updateurl')
        : (h.first('downloadurl').isNotEmpty
              ? h.first('downloadurl')
              : (previous?.updateUrl ?? '')),
    enabled: previous?.enabled ?? true,
    autoUpdate: previous?.autoUpdate ?? false,
    scope: previous?.scope ?? 'default',
    whitelist: previous?.whitelist ?? const [],
    blacklist: previous?.blacklist ?? const [],
    updatedMs: DateTime.now().millisecondsSinceEpoch,
  );
}

/// Whether [pattern] (a Tampermonkey `@match` pattern, `@include` glob or
/// `/regex/`) matches [url]. The runtime page script uses the same rules; this
/// copy only serves the screens (for example to pick a page to open).
bool userScriptPatternMatches(String pattern, String url) {
  final p = pattern.trim();
  if (p.isEmpty) return false;
  if (p == '*' || p == '<all_urls>') return true;
  try {
    if (p.length > 2 && p.startsWith('/') && p.lastIndexOf('/') > 0) {
      final last = p.lastIndexOf('/');
      return RegExp(
        p.substring(1, last),
        caseSensitive: !p.substring(last + 1).contains('i'),
      ).hasMatch(url);
    }
    String esc(String x) {
      final b = StringBuffer();
      for (final ch in x.split('')) {
        b.write(ch == '*' ? '.*' : RegExp.escape(ch));
      }
      return b.toString();
    }

    // `https://*.site.com/*` also matches `https://site.com/...`.
    final sub = RegExp(r'^([^:/]+://)\*\.(.*)$').firstMatch(p);
    final source = sub != null
        ? '^${esc(sub.group(1)!)}(?:[^/]*\\.)?${esc(sub.group(2)!)}\$'
        : '^${esc(p)}\$';
    return RegExp(source, caseSensitive: false).hasMatch(url);
  } catch (_) {
    return false;
  }
}

/// A page the script obviously targets, taken from its first `@match` line:
/// `https://*.chub.ai/*` becomes `https://chub.ai/`. Null when none is usable.
String? userScriptStartUrl(GlazeUserScript s) {
  for (final m in s.matches) {
    final match = RegExp(r'^(https?|\*)://([^/]+)(/.*)?$').firstMatch(m.trim());
    if (match == null) continue;
    var scheme = match.group(1)!;
    if (scheme == '*') scheme = 'https';
    var host = match.group(2)!;
    if (host == '*') continue;
    if (host.startsWith('*.')) host = host.substring(2);
    if (host.contains('*')) continue;
    return '$scheme://$host/';
  }
  return null;
}
