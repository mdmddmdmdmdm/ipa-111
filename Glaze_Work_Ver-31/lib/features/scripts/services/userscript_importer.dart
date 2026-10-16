import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/user_script.dart';
import 'userscript_parser.dart';

/// One hit from a Greasy Fork search.
class GreasyForkResult {
  final String id;
  final String name;
  final String description;
  final String codeUrl;
  final int installs;

  const GreasyForkResult({
    required this.id,
    required this.name,
    required this.description,
    required this.codeUrl,
    required this.installs,
  });
}

/// Downloads userscripts: from a URL, from Greasy Fork, and their `@require`d
/// libraries. Network failures surface as exceptions with a readable message.
class UserScriptImporter {
  UserScriptImporter._();
  static final instance = UserScriptImporter._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 40),
      responseType: ResponseType.plain,
      followRedirects: true,
      headers: const {'Accept': 'text/javascript, text/plain, */*'},
    ),
  );

  Future<String> fetchText(String url) async {
    final uri = _normalise(url);
    try {
      final res = await _dio.get<String>(uri);
      final data = res.data;
      if (data == null || data.trim().isEmpty) {
        throw Exception('The address returned nothing.');
      }
      return data;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      throw Exception(
        code != null ? 'Download failed (HTTP $code).' : 'Download failed.',
      );
    }
  }

  String _normalise(String url) {
    var u = url.trim();
    if (u.startsWith('//')) u = 'https:$u';
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }
    return u;
  }

  /// Downloads the libraries a script `@require`s so it can run offline.
  Future<Map<String, String>> fetchRequires(List<String> urls) async {
    final out = <String, String>{};
    for (final url in urls) {
      try {
        // Strip a `#sha256=...` integrity suffix.
        final clean = url.split('#').first;
        out[url] = await fetchText(clean);
      } catch (_) {
        // A library that cannot be fetched is skipped; the script may not
        // need it, and a missing one shows up in the page console.
      }
    }
    return out;
  }

  /// Downloads a script from [url] and checks it looks like a userscript.
  Future<({String code, String url})> downloadScript(String url) async {
    final normal = _normalise(url);
    final code = await fetchText(normal);
    final header = UserScriptHeader.parse(code);
    final looksLikeScript =
        !header.isEmpty ||
        normal.toLowerCase().split('?').first.endsWith('.js');
    if (!looksLikeScript) {
      throw Exception('That address is not a userscript (.user.js).');
    }
    return (code: code, url: normal);
  }

  // ------------------------------------------------------------ Greasy Fork

  static final _idInUrl = RegExp(r'greasyfork\.org/(?:[\w-]+/)?scripts/(\d+)');

  /// The install URL for a Greasy Fork script page link, or null when [text]
  /// is not one.
  Future<String?> greasyForkCodeUrl(String text) async {
    final m = _idInUrl.firstMatch(text);
    if (m == null) return null;
    final id = m.group(1)!;
    try {
      final raw = await fetchText('https://greasyfork.org/scripts/$id.json');
      final data = jsonDecode(raw);
      if (data is Map && data['code_url'] is String) {
        return data['code_url'] as String;
      }
    } catch (_) {}
    return 'https://greasyfork.org/scripts/$id/code/script.user.js';
  }

  Future<List<GreasyForkResult>> searchGreasyFork(String query) async {
    final q = Uri.encodeQueryComponent(query.trim());
    final raw = await fetchText(
      'https://greasyfork.org/en/scripts.json?q=$q&sort=daily_installs',
    );
    final data = jsonDecode(raw);
    if (data is! List) return const [];
    final out = <GreasyForkResult>[];
    for (final e in data) {
      if (e is! Map) continue;
      final codeUrl = e['code_url'];
      if (codeUrl is! String || codeUrl.isEmpty) continue;
      out.add(
        GreasyForkResult(
          id: '${e['id'] ?? ''}',
          name: '${e['name'] ?? 'Script'}',
          description: '${e['description'] ?? ''}',
          codeUrl: codeUrl,
          installs: (e['total_installs'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return out;
  }

  // ---------------------------------------------------------------- updates

  /// The newest code for [script], or null when it has no address to update
  /// from or nothing changed.
  Future<String?> newerCode(GlazeUserScript script) async {
    final url = script.updateUrl.isNotEmpty
        ? script.updateUrl
        : script.sourceUrl;
    if (url.isEmpty || url.endsWith('.meta.js')) {
      final alt = script.sourceUrl;
      if (alt.isEmpty) return null;
      final code = await fetchText(alt);
      return code.trim() == script.code.trim() ? null : code;
    }
    final code = await fetchText(url);
    return code.trim() == script.code.trim() ? null : code;
  }
}
