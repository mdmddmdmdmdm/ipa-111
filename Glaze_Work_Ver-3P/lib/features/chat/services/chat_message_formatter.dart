/// Whole-chat cleanup behind the composer's "F" button.
///
/// Two jobs, both ported from the Auto-Format userscript this app already
/// borrowed ideas from, and neither of them needs a network call:
///
///  1. **Stray placeholders.** A model sometimes invents a macro of its own —
///     `{{obj}}`, `{{subj}}`, `{{name}}` — that nothing resolves, so it shows
///     up raw in the chat. Anything in `{{ }}` that is not `{{user}}` or
///     `{{char}}` (and is not a macro the app really understands) is turned
///     into whichever of the two it most plausibly stands for.
///  2. **Formatting.** Narration goes between `*asterisks*`, dialogue stays in
///     plain `"quotes"`, leaked `<think>` blocks and instruction tags are
///     removed, and curly quote styles are straightened.
///
/// Pure Dart on purpose: no Flutter, no providers, so it can be tested alone.
library;

/// One message as the formatter needs to see it.
class FormatMessageInput {
  final String text;

  /// True for a message the user wrote, false for a character reply.
  final bool isUser;

  const FormatMessageInput({required this.text, required this.isUser});
}

/// What the formatter made of one message.
class FormatMessageResult {
  final String text;

  /// How many `{{...}}` tokens were resolved or normalised.
  final int placeholders;

  /// True when the formatting pass changed the text beyond the placeholders.
  final bool reformatted;

  const FormatMessageResult({
    required this.text,
    this.placeholders = 0,
    this.reformatted = false,
  });
}

/// What a run over a whole chat changed — or, for a dry run, would change.
class ChatFormatReport {
  /// Messages whose text differs afterwards.
  final int messages;

  /// Placeholders resolved across the chat.
  final int placeholders;

  /// Messages the formatting pass altered.
  final int reformatted;

  /// True when nothing was done because the chat was busy (generating) or not
  /// loaded yet.
  final bool blocked;

  const ChatFormatReport({
    this.messages = 0,
    this.placeholders = 0,
    this.reformatted = 0,
    this.blocked = false,
  });
}

enum _Owner { user, char }

/// One `{{...}}` token found in a message.
class _Hit {
  final int start;
  final int end;

  /// The text to leave in place when [owner] is null and [evidence] is 0 and
  /// the token is not a stray — i.e. a macro the app understands.
  final String original;

  /// What the token is, when the token itself says so (`{{user}}`, `{{Noah}}`,
  /// `{{player}}`). Null for a stray whose owner has to be worked out.
  final _Owner? owner;

  /// True for a token that is neither `{{user}}`/`{{char}}` nor a real macro.
  final bool stray;

  /// For a stray with no owner: +1 when the surrounding sentence points at the
  /// user, -1 when it points at the character, 0 when it says nothing.
  final int evidence;

  /// Chat-wide identity of the token, so `{{obj}}` is read the same way
  /// everywhere an author uses it.
  final String key;

  /// `'s` when the token was written as a possessive, so it can be re-attached.
  final String suffix;

  const _Hit({
    required this.start,
    required this.end,
    required this.original,
    required this.owner,
    required this.stray,
    required this.evidence,
    required this.key,
    required this.suffix,
  });
}

class ChatMessageFormatter {
  /// Lower-cased names the user's persona goes by.
  final List<String> userNames;

  /// Lower-cased names the character goes by.
  final List<String> charNames;

  /// The userscript's own defaults: think-block removal, tag cleaning and the
  /// leaked-prompt trim are on; the dash and ellipsis rewrites are off.
  final bool removeThinkTags;
  final bool cleanTags;
  final bool removeSystemPrompt;
  final bool removeEmDashes;
  final bool removeEllipses;

  ChatMessageFormatter({
    required List<String> userNames,
    required List<String> charNames,
    this.removeThinkTags = true,
    this.cleanTags = true,
    this.removeSystemPrompt = true,
    this.removeEmDashes = false,
    this.removeEllipses = false,
  }) : userNames = _usableNames(userNames),
       charNames = _usableNames(charNames);

  // ---------------------------------------------------------------- entry

  /// Runs every message through both passes.
  ///
  /// Placeholders are read in two sweeps: first every message is scanned and
  /// the clear-cut readings are tallied per token, then each message is
  /// rewritten. That is what keeps `{{obj}}` meaning the same person across
  /// the whole chat instead of flipping from one message to the next.
  List<FormatMessageResult> formatAll(List<FormatMessageInput> inputs) {
    final scans = <List<_Hit>>[];
    final tally = <String, int>{};
    for (final input in inputs) {
      final text = _normalizeNewlines(input.text);
      final hits = _scan(text, input.isUser);
      scans.add(hits);
      for (final hit in hits) {
        if (hit.stray && hit.owner == null && hit.evidence != 0) {
          tally[hit.key] = (tally[hit.key] ?? 0) + (hit.evidence > 0 ? 1 : -1);
        }
      }
    }

    final results = <FormatMessageResult>[];
    for (var i = 0; i < inputs.length; i++) {
      final input = inputs[i];
      final text = _normalizeNewlines(input.text);
      final rewritten = _rewrite(text, scans[i], input.isUser, tally);
      final formatted = _format(rewritten.text);
      // Never blank a message: a reply that was nothing but a leaked think
      // block would otherwise be emptied.
      final finalText = formatted.trim().isEmpty ? rewritten.text : formatted;
      // Stray whitespace at the ends is not worth rewriting a message for.
      final untouched =
          rewritten.count == 0 && finalText.trim() == text.trim();
      results.add(
        FormatMessageResult(
          text: untouched ? input.text : finalText,
          placeholders: rewritten.count,
          reformatted: !untouched && finalText != rewritten.text,
        ),
      );
    }
    return results;
  }

  // ---------------------------------------------------------- placeholders

  static final RegExp _macro = RegExp(r'\{\{\s*([^{}\n]+?)\s*\}\}');
  static final RegExp _possessive = RegExp(r"^(.*?)['’]s$");
  static final RegExp _nonAlnum = RegExp(r'[^a-z0-9]+');
  static final RegExp _wordChar = RegExp(r'[\p{L}\p{N}_]', unicode: true);

  /// Macros the app really expands (see `macro_engine.dart`). They are left
  /// exactly as written.
  static const Set<String> _engineMacros = {
    'description',
    'scenario',
    'personality',
    'mesexamples',
    'trim',
    'reasoningprefix',
    'reasoningsuffix',
    'summary',
    'memory',
    'arc',
    'studio_state',
    'entity',
    'entities',
    'lorebooks',
    'guidance',
    'date',
    'time',
    'weekday',
    'isotime',
    'isodate',
    'gametime',
    'gamedate',
    'gameday',
  };

  /// Words inside a token that say it is the user.
  static const Set<String> _userWords = {
    'user',
    'you',
    'your',
    'yourself',
    'player',
    'persona',
    'username',
    'usr',
    'mc',
    'pc',
    'protagonist',
    'reader',
    'me',
    'myself',
  };

  /// Words inside a token that say it is the character.
  static const Set<String> _charWords = {
    'char',
    'character',
    'charname',
    'bot',
    'botname',
    'npc',
    'assistant',
    'ai',
    'narrator',
    'companion',
  };

  static List<String> _usableNames(List<String> names) {
    final out = <String>[];
    void add(String name) {
      final clean = name.trim().toLowerCase();
      if (clean.length >= 2 && !out.contains(clean)) out.add(clean);
    }

    for (final name in names) {
      add(name);
      final parts = name.trim().split(RegExp(r'\s+'));
      if (parts.length > 1 && parts.first.length >= 3) add(parts.first);
    }
    return out;
  }

  static String _normalizeNewlines(String text) =>
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  static bool _isEngineMacro(String body) {
    final lower = body.toLowerCase();
    return lower.contains('::') ||
        lower.startsWith('/') ||
        _engineMacros.contains(lower);
  }

  static String _squash(String value) =>
      value.toLowerCase().replaceAll(_nonAlnum, '');

  /// Finds every `{{...}}` in [text] and works out what each one is.
  List<_Hit> _scan(String text, bool isUser) {
    final hits = <_Hit>[];
    for (final match in _macro.allMatches(text)) {
      final original = match.group(0)!;
      var body = match.group(1)!.trim();
      var suffix = '';
      final possessive = _possessive.firstMatch(body);
      if (possessive != null && possessive.group(1)!.trim().isNotEmpty) {
        body = possessive.group(1)!.trim();
        suffix = "'s";
      }

      if (suffix.isEmpty && _isEngineMacro(body)) {
        hits.add(
          _Hit(
            start: match.start,
            end: match.end,
            original: original,
            owner: null,
            stray: false,
            evidence: 0,
            key: '',
            suffix: '',
          ),
        );
        continue;
      }

      final lower = body.toLowerCase();
      _Owner? owner;
      if (lower == 'user') {
        owner = _Owner.user;
      } else if (lower == 'char') {
        owner = _Owner.char;
      } else {
        owner = _ownerFromTokenText(body);
      }

      var evidence = 0;
      if (owner == null) {
        evidence = _sentenceEvidence(text, match.start, match.end);
      }
      hits.add(
        _Hit(
          start: match.start,
          end: match.end,
          original: original,
          owner: owner,
          stray: true,
          evidence: evidence,
          key: '${isUser ? 'u' : 'a'}:$lower',
          suffix: suffix,
        ),
      );
    }
    return hits;
  }

  /// The owner a token names outright — by keyword (`{{player}}`,
  /// `{{char_name}}`) or by being the persona's or character's actual name.
  _Owner? _ownerFromTokenText(String body) {
    final words = body
        .toLowerCase()
        .split(_nonAlnum)
        .where((w) => w.isNotEmpty)
        .toList();
    final userWord = words.any(_userWords.contains);
    final charWord = words.any(_charWords.contains);
    if (userWord && !charWord) return _Owner.user;
    if (charWord && !userWord) return _Owner.char;
    if (userWord && charWord) return null;

    final squashed = _squash(body);
    if (squashed.isEmpty) return null;
    final isUserName = userNames.any((n) => _squash(n) == squashed);
    final isCharName = charNames.any((n) => _squash(n) == squashed);
    if (isUserName && !isCharName) return _Owner.user;
    if (isCharName && !isUserName) return _Owner.char;
    return null;
  }

  /// +1 / -1 / 0: what the sentence around a token says about who it is.
  ///
  /// A sentence rarely names the same person twice, once by name and once by
  /// placeholder. So when it already names exactly one of the two, the stray
  /// token is the other one — "Lucia glares {{obj}} down" is about the user.
  int _sentenceEvidence(String text, int start, int end) {
    var from = start;
    while (from > 0 && !_breaksSentence(text[from - 1])) {
      from--;
    }
    var to = end;
    while (to < text.length && !_breaksSentence(text[to])) {
      to++;
    }
    final sentence = text.substring(from, start) + ' ' + text.substring(end, to);
    final lower = sentence.toLowerCase();

    final userNamed = _mentions(lower, userNames, 'user');
    final charNamed = _mentions(lower, charNames, 'char');
    if (userNamed && !charNamed) return -1;
    if (charNamed && !userNamed) return 1;
    return 0;
  }

  static bool _breaksSentence(String c) =>
      c == '.' || c == '!' || c == '?' || c == '…' || c == '\n';

  static bool _mentions(String lowerSentence, List<String> names, String word) {
    if (RegExp('\\{\\{\\s*$word\\s*\\}\\}').hasMatch(lowerSentence)) {
      return true;
    }
    for (final name in names) {
      if (_hasWord(lowerSentence, name)) return true;
    }
    return false;
  }

  static bool _hasWord(String haystack, String word) {
    var from = 0;
    while (true) {
      final at = haystack.indexOf(word, from);
      if (at < 0) return false;
      final before = at == 0 ? ' ' : haystack[at - 1];
      final afterAt = at + word.length;
      final after = afterAt >= haystack.length ? ' ' : haystack[afterAt];
      if (!_wordChar.hasMatch(before) && !_wordChar.hasMatch(after)) {
        return true;
      }
      from = at + 1;
    }
  }

  /// Rewrites the tokens in [text] and counts how many were changed.
  ({String text, int count}) _rewrite(
    String text,
    List<_Hit> hits,
    bool isUser,
    Map<String, int> tally,
  ) {
    if (hits.isEmpty) return (text: text, count: 0);
    final buffer = StringBuffer();
    var cursor = 0;
    var count = 0;
    for (final hit in hits) {
      buffer.write(text.substring(cursor, hit.start));
      cursor = hit.end;
      if (!hit.stray) {
        buffer.write(hit.original);
        continue;
      }
      final owner = hit.owner ?? _decide(hit, isUser, tally);
      final replacement =
          '${owner == _Owner.user ? '{{user}}' : '{{char}}'}${hit.suffix}';
      if (replacement != hit.original) count++;
      buffer.write(replacement);
    }
    buffer.write(text.substring(cursor));
    return (text: buffer.toString(), count: count);
  }

  /// Picks an owner for a stray the token itself does not name.
  ///
  /// In order: what its own sentence says; what the rest of the chat says
  /// about the same token from the same kind of author; and last the plain
  /// fallback — a character reply talks about the user, and a user message
  /// talks about the character.
  _Owner _decide(_Hit hit, bool isUser, Map<String, int> tally) {
    if (hit.evidence != 0) {
      return hit.evidence > 0 ? _Owner.user : _Owner.char;
    }
    final chatWide = tally[hit.key] ?? 0;
    if (chatWide != 0) return chatWide > 0 ? _Owner.user : _Owner.char;
    return isUser ? _Owner.char : _Owner.user;
  }

  // ------------------------------------------------------------ formatting

  static final RegExp _thoughtBlock = RegExp(
    r'\n?\s*<(thought|thoughts)>[\s\S]*?</(thought|thoughts)>\s*\n?',
    caseSensitive: false,
  );
  static final RegExp _thinkBlock = RegExp(
    r'\n?\s*<think>[\s\S]*?</think>\s*\n?',
    caseSensitive: false,
  );
  static final RegExp _thinkOpeners = RegExp(
    r'<(think|thought|thoughts)>',
    caseSensitive: false,
  );
  static final RegExp _wholeThought = RegExp(
    r'^<(think|thought|thoughts)>[\s\S]*</(think|thought|thoughts)>$',
    caseSensitive: false,
  );
  static final RegExp _thoughtWrapperStart = RegExp(
    r'^\s*<(think|thought|thoughts)>',
    caseSensitive: false,
  );
  static final RegExp _thoughtWrapperEnd = RegExp(
    r'</(think|thought|thoughts)>\s*$',
    caseSensitive: false,
  );
  static final RegExp _anyTag = RegExp(
    r'</?([a-zA-Z][a-zA-Z0-9:_-]*)(\s[^>]*)?>',
  );
  static final RegExp _quoteMarks = RegExp('[«“”„‟⹂❞❝]');
  static final RegExp _quotedSpan = RegExp(r'"[^"]*"|`[^`]*`');
  static final RegExp _boldLine = RegExp(r'^\*\*[^*]+\*\*$');
  static final RegExp _structural = RegExp(
    r'^(#{1,6}\s|>|\||[-+]\s|\*\s|\d+[.)]\s|!\[|\[[^\]]*\]\()',
  );

  /// HTML the chat view can render. Everything else in angle brackets is a
  /// leaked instruction or reasoning tag, and its tags are dropped (the text
  /// inside stays).
  static const Set<String> _htmlTags = {
    'a', 'abbr', 'b', 'big', 'blockquote', 'br', 'caption', 'center', 'cite',
    'code', 'col', 'colgroup', 'dd', 'del', 'details', 'div', 'dl', 'dt', 'em',
    'figcaption', 'figure', 'font', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr',
    'i', 'img', 'ins', 'kbd', 'li', 'mark', 'ol', 'p', 'pre', 'q', 's', 'small',
    'span', 'strike', 'strong', 'style', 'sub', 'summary', 'sup', 'table',
    'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'u', 'ul', 'video', 'audio',
    'source', 'svg', 'path', 'section', 'article', 'aside', 'header', 'footer',
    'nav', 'main', 'label', 'input', 'button', 'select', 'option', 'textarea',
    'form', 'iframe', 'script', 'canvas',
  };

  /// Narration is wrapped in one asterisk each side; dialogue is left plain.
  /// This is the userscript's "Classic" style, which is its default.
  static const String _narration = '*';

  String _format(String input) {
    var text = input;

    // A reply that is one single <think> block: keep what is inside, drop the
    // wrapper. Several blocks mean there is a real reply around them, so those
    // go with their content below.
    final trimmed = text.trim();
    final openers = _thinkOpeners.allMatches(trimmed).length;
    if (openers == 1 && _wholeThought.hasMatch(trimmed)) {
      text = text
          .replaceFirst(_thoughtWrapperStart, '')
          .replaceFirst(_thoughtWrapperEnd, '');
    } else if (removeThinkTags) {
      text = text.replaceAll(_thoughtBlock, '');
      text = text.replaceAll(_thinkBlock, '');
      text = text.replaceAll(RegExp('</think>', caseSensitive: false), '');
      text = text.replaceAll(
        RegExp('<(system|response)>|</response>', caseSensitive: false),
        '',
      );
    }

    if (removeEmDashes) {
      text = text.replaceAll('—', ' ').replaceAll(RegExp(r' {2,}'), ' ');
    }
    if (removeEllipses) {
      text = text.replaceAll(RegExp(r'\.{3,}|…'), '.');
      text = text.replaceAll(RegExp(r'\.{2,}'), '.');
    }

    if (cleanTags) {
      text = text.replaceAllMapped(_anyTag, (m) {
        final name = m.group(1)!.toLowerCase();
        return _htmlTags.contains(name) ? m.group(0)! : '';
      });
    }

    // A leaked "the user wants..." preamble in front of the real narration.
    if (removeSystemPrompt && text.toLowerCase().contains('theuser')) {
      final cut = text.indexOf(RegExp(r'[^\s*]\*[^\s*]'));
      if (cut != -1) text = text.substring(cut + 1);
    }

    final normalized = text.replaceAll(_quoteMarks, '"');
    final out = <String>[];
    var inFence = false;
    for (final raw in normalized.split('\n')) {
      final line = raw.trim();

      // Code blocks are not prose: leave every line inside them alone.
      if (line.startsWith('```')) {
        inFence = !inFence;
        out.add(line);
        continue;
      }
      if (inFence) {
        out.add(raw);
        continue;
      }

      if (line.isEmpty) {
        out.add('');
        continue;
      }
      if (line == '---') {
        out.add('---');
        continue;
      }
      if (_isStructural(line)) {
        out.add(line);
        continue;
      }

      final clean = line.replaceAll('*', '');
      // A line that is only quote marks and/or asterisks carries nothing.
      if (clean.isEmpty || RegExp(r'^"+$').hasMatch(clean)) continue;

      out.add(_wrapLine(clean));
    }
    return out.join('\n').trim();
  }

  /// Lists, headings, quotes, tables, images, links and HTML lines keep their
  /// markup; wrapping them in asterisks would break it.
  static bool _isStructural(String line) {
    // A line that is bold from end to end (an inner thought, a heading) is
    // already deliberate formatting.
    if (_boldLine.hasMatch(line)) return true;
    if (_structural.hasMatch(line)) return true;
    final tag = _anyTag.firstMatch(line);
    if (tag != null && _htmlTags.contains(tag.group(1)!.toLowerCase())) {
      return true;
    }
    return false;
  }

  /// Splits a line into quoted dialogue (kept plain) and the narration between
  /// it (each stretch wrapped in asterisks), then joins them with spaces.
  static String _wrapLine(String clean) {
    final parts = <String>[];
    var last = 0;
    void narration(String chunk) {
      final t = chunk.trim();
      if (t.isNotEmpty) parts.add('$_narration$t$_narration');
    }

    for (final m in _quotedSpan.allMatches(clean)) {
      if (m.start > last) narration(clean.substring(last, m.start));
      parts.add(m.group(0)!);
      last = m.end;
    }
    if (last < clean.length) narration(clean.substring(last));
    return parts.join(' ');
  }
}
