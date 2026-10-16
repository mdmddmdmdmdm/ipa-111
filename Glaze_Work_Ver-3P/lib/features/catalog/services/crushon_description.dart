import '../../../core/utils/html_to_markdown.dart';

/// CrushOn descriptions are styled HTML pages (banners, pictures, tables,
/// glowing titles). The app keeps two versions of them:
///
///  * display description: the HTML as the site shows it (saved in the
///    character's creator-notes slot, which the app renders with pictures and
///    colours and never sends to the model);
///  * memory description: only the words that matter, saved in the normal
///    description field that goes into the prompt.
///
/// [crushonMemoryText] builds the second one from the first.
String crushonMemoryText(String html) {
  var s = html;
  s = s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  s = s.replaceAll(
    RegExp(r'<(style|script|svg|iframe|noscript)\b[^>]*>.*?</\1>',
        caseSensitive: false, dotAll: true),
    '',
  );
  s = s.replaceAll(RegExp(r'<img\b[^>]*>', caseSensitive: false), '');
  // Table cells on one line, rows and blocks on their own lines.
  s = s.replaceAll(RegExp(r'</t[dh]\s*>', caseSensitive: false), ' | ');
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(
    RegExp(r'</(p|div|li|ul|ol|h[1-6]|tr|table|section|article|blockquote|details|summary)\s*>',
        caseSensitive: false),
    '\n',
  );
  s = s.replaceAll(
    RegExp(r'<(p|div|li|h[1-6]|tr|section|article|blockquote)\b[^>]*>',
        caseSensitive: false),
    '\n',
  );
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  s = _decodeEntities(s);

  final out = <String>[];
  final seen = <String>{};
  for (var raw in s.split('\n')) {
    var line = raw.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ').trim();
    line = line.replaceAll(RegExp(r'(\s*\|\s*)+$'), '').trim();
    if (line.isEmpty) continue;
    if (!RegExp(r'[A-Za-z0-9\u00C0-\uFFFF]').hasMatch(line)) continue; // ━━━, ***, ---
    if (_isBanner(line)) continue;
    if (_isHeadingNoise(line)) continue;
    if (!seen.add(line.toLowerCase())) continue;
    out.add(line);
  }
  return out.join('\n').trim();
}

/// The best plain version of any description: HTML is reduced to its words,
/// plain text and markdown are only tidied.
String crushonPlainDescription(String text) {
  if (hasHtmlTags(text)) return crushonMemoryText(text);
  return text
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

bool looksLikeHtml(String s) => hasHtmlTags(s);

/// True for the site's own "404 Page Not Found" page (artwork + "Sorry, I can't
/// find the page..."), which must never be saved as a character description.
/// Only short documents count, so a long real description that happens to
/// mention a missing page is safe.
bool crushonLooksLikeNotFound(String s) {
  if (s.trim().isEmpty) return false;
  final raw = s.toLowerCase();
  final words = _decodeEntities(raw.replaceAll(RegExp(r'<[^>]+>'), ' '))
      .replaceAll(RegExp(r"[^a-z ]"), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (words.length > 900) return false;
  bool has(String x) => words.contains(x) || raw.contains(x);
  return has('page not found') ||
      has('could not be found') ||
      has('cant find the page') ||
      has("can't find the page");
}

/// The generic marketing text every CrushOn page carries in its meta tags
/// ("An NSFW AI private space exclusive to you and fantasy AI characters...").
/// It describes the site, not the character.
bool crushonIsGenericSiteBlurb(String s) => s
    .toLowerCase()
    .contains('private space exclusive to you and fantasy ai characters');

/// Promotional strips such as "50+ Images | Astra Yao | Frustrated Roommate | ZZZ"
/// (three or more short pipe/bullet separated pieces, no sentence).
bool _isBanner(String line) {
  final parts = line.split(RegExp(r'\s*[|•·▪◆♦★☆♥❤]+\s*'))
    ..removeWhere((e) => e.trim().isEmpty);
  if (parts.length < 3) return false;
  if (line.contains(':') || RegExp(r'[.!?]\s').hasMatch(line)) return false;
  return parts.every((p) => p.trim().length <= 28);
}

/// Pure section titles that only decorate the page.
bool _isHeadingNoise(String line) {
  final l = line.toLowerCase().replaceAll(RegExp(r'[^a-z ]'), '').trim();
  return const {
    'character profile',
    'profile',
    'info',
    'tags',
    'gallery',
    'images',
  }.contains(l);
}

String _decodeEntities(String s) {
  const named = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&hellip;': '…',
    '&mdash;': '—',
    '&ndash;': '–',
    '&rsquo;': '’',
    '&lsquo;': '‘',
    '&rdquo;': '”',
    '&ldquo;': '“',
  };
  named.forEach((k, v) => s = s.replaceAll(k, v));
  s = s.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final c = int.tryParse(m[1]!);
    return c == null ? m[0]! : String.fromCharCode(c);
  });
  s = s.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final c = int.tryParse(m[1]!, radix: 16);
    return c == null ? m[0]! : String.fromCharCode(c);
  });
  return s;
}
