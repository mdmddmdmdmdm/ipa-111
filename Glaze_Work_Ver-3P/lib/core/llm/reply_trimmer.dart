import '../utils/emoji_text.dart';

/// Post-processing applied to a finished model reply, before it is saved.
///
/// Three independent, optional passes:
///
/// * [trimIncompleteSentences] — drops a trailing unfinished sentence (what
///   happens when the token limit cuts the reply off mid-thought) and closes
///   any `*action*` or `"dialogue"` span the cut left open.
/// * [enforceUserAgency] — cuts the reply where the model starts writing the
///   user's own character (a `Name:` speaker label, or a sentence that opens
///   with the user's name followed by an action).
/// * [capParagraphs] — a hard ceiling for the Short / Medium length helpers,
///   for models that ignore the length instruction.
///
/// All of them are pure string functions and never return an empty string for
/// a non-empty input: when a cut would remove everything, the text is returned
/// unchanged instead.
class ReplyTrimmer {
  const ReplyTrimmer._();

  static const String _terminators = '.!?\u2026\u3002\uFF01\uFF1F';
  static const String _closers = '"\'\u201D\u2019)]*_~\u00BB\u300D\u300E';

  /// Words ending in a period that do not end a sentence.
  static const Set<String> _abbreviations = {
    'mr',
    'mrs',
    'ms',
    'mx',
    'dr',
    'prof',
    'sr',
    'jr',
    'vs',
    'mt',
    'lt',
    'col',
    'gen',
    'capt',
    'sgt',
    'rev',
    'hon',
    'gov',
    'sen',
    'rep',
    'e.g',
    'i.e',
    'approx',
    'cf',
  };

  /// Words that, right after the user's name, mean the sentence is *about* the
  /// user rather than the user *doing* something.
  static const Set<String> _nonActionWords = {
    'is',
    'was',
    'were',
    'are',
    'has',
    'had',
    'should',
    'would',
    'could',
    'might',
    'can',
    'will',
    'did',
    'does',
    'may',
    'must',
  };

  static final RegExp _alnum = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final RegExp _trailingWord = RegExp(r'([A-Za-z]+(?:\.[A-Za-z]+)*)$');

  static bool _isTerminator(String ch) => _terminators.contains(ch);
  static bool _isCloser(String ch) => _closers.contains(ch);
  static bool _isSpace(String ch) =>
      ch == ' ' || ch == '\n' || ch == '\t' || ch == '\r' || ch == '\u00A0';
  static bool _isAlnum(String ch) => _alnum.hasMatch(ch);
  static bool _isLower(String ch) =>
      ch.toLowerCase() == ch && ch.toUpperCase() != ch;
  static bool _isUpper(String ch) =>
      ch.toUpperCase() == ch && ch.toLowerCase() != ch;

  // ---------------------------------------------------------------------------
  // Trim incomplete sentences
  // ---------------------------------------------------------------------------

  /// Removes the unfinished sentence at the end of [text].
  ///
  /// The text is cut after the last real sentence boundary: a `.`, `!`, `?`,
  /// `…` run, plus any closing quote / asterisk / bracket glued to it, followed
  /// by whitespace or the end of the text. Periods inside numbers (`3.5`),
  /// after abbreviations (`Dr.`) and initials (`J. Smith`) are not boundaries,
  /// and neither is `"Where?" she asked` — a quote followed by a lowercase
  /// dialogue tag is still the same sentence.
  ///
  /// After the cut, a `*` or `"` span that the cut left open is closed again so
  /// the message does not render half in italics.
  ///
  /// Left alone: text with no boundary at all, text that already ends on one,
  /// text that ends in a tag or code block, and a cut that would throw away
  /// nearly everything.
  static String trimIncompleteSentences(String text) {
    final t = _trimRight(text);
    if (t.isEmpty) return text;
    if (t.endsWith('>') || t.endsWith('}') || t.endsWith('```')) return text;
    // A reply that closes on an emoji ("That sounds lovely 😊") is finished:
    // the emoji is its full stop. Without this the last sentence was cut off.
    if (endsWithEmoji(t)) return text;
    if ('```'.allMatches(t).length.isOdd) return text;

    final n = t.length;
    var cut = -1;
    var i = 0;
    while (i < n) {
      if (_isTerminator(t[i])) {
        final boundaryEnd = _boundaryEnd(t, i);
        if (boundaryEnd != null) {
          cut = boundaryEnd.cut;
          i = boundaryEnd.cut;
          continue;
        }
        while (i < n && _isTerminator(t[i])) {
          i++;
        }
        continue;
      }
      i++;
    }
    if (cut < 0) return text;

    final tail = t.substring(cut);
    // Trailing emoji / decoration after the last sentence: nothing is unfinished.
    if (!_alnum.hasMatch(tail)) return text;
    final kept = t.substring(0, cut);
    // Never butcher a reply that is one long unpunctuated run.
    if (kept.length < 20 && tail.length > 3 * kept.length) return text;
    return kept + _closersFor(kept);
  }

  /// If the terminator run starting at [i] ends a sentence, returns where the
  /// run ends and where the sentence (with its closing marks) ends; else null.
  static ({int runEnd, int cut})? _boundaryEnd(String t, int i) {
    final n = t.length;
    var j = i;
    while (j < n && _isTerminator(t[j])) {
      j++;
    }
    final run = t.substring(i, j);
    var k = j;
    while (k < n && _isCloser(t[k])) {
      // A quote or asterisk glued to a following letter opens something new.
      if (k + 1 < n && _isAlnum(t[k + 1])) break;
      k++;
    }
    if (k < n && !_isSpace(t[k])) return null;

    if (run == '.') {
      final before = t.substring(0, i);
      final m = _trailingWord.firstMatch(before);
      if (m != null) {
        final word = m.group(1)!;
        if (_abbreviations.contains(word.toLowerCase())) return null;
        if (word.length == 1 && _isUpper(word)) {
          final prev = before.substring(0, before.length - word.length);
          final startsWord = prev.isEmpty || _isSpace(prev[prev.length - 1]);
          if (startsWord) {
            // An initial ("J. Smith") only when a capitalised word follows.
            final rest = _trimLeft(t.substring(k));
            if (rest.isNotEmpty && _isUpper(rest[0])) return null;
          }
        }
      }
    }

    if (k < n) {
      final rest = _trimLeft(t.substring(k));
      if (rest.isNotEmpty && _isLower(rest[0])) {
        // `"Where?" she asked` and `Well... I think` continue the sentence.
        if (k > j) return null;
        if (run.endsWith('\u2026') || run.startsWith('..')) return null;
      }
    }
    return (runEnd: j, cut: k);
  }

  /// The closing marks needed to balance `*...*`, `**...**` and `"..."` spans
  /// left open in [s], innermost first.
  static String _closersFor(String s) {
    final stack = <String>[];
    final n = s.length;

    void toggle(String token) {
      final at = stack.lastIndexOf(token);
      if (at >= 0) {
        stack.removeAt(at);
      } else {
        stack.add(token);
      }
    }

    var i = 0;
    while (i < n) {
      final c = s[i];
      if (c == '*') {
        var j = i;
        while (j < n && s[j] == '*') {
          j++;
        }
        final run = j - i;
        final prevSpace = i == 0 || _isSpace(s[i - 1]);
        final nextSpace = j >= n || _isSpace(s[j]);
        final tokens = run >= 3
            ? const ['**', '*']
            : run == 2
            ? const ['**']
            : const ['*'];
        for (final token in tokens) {
          if (stack.contains(token)) {
            if (!prevSpace) toggle(token);
          } else if (!nextSpace) {
            toggle(token);
          }
        }
        i = j;
        continue;
      }
      if (c == '"') {
        final prevSpace = i == 0 || _isSpace(s[i - 1]);
        final nextSpace = i + 1 >= n || _isSpace(s[i + 1]);
        if (stack.contains('"')) {
          if (!prevSpace || nextSpace) toggle('"');
        } else {
          toggle('"');
        }
      } else if (c == '\u201C') {
        stack.add('\u201C');
      } else if (c == '\u201D') {
        if (stack.contains('\u201C')) toggle('\u201C');
      }
      i++;
    }

    final out = StringBuffer();
    for (final token in stack.reversed) {
      out.write(token == '\u201C' ? '\u201D' : token);
    }
    return out.toString();
  }

  // ---------------------------------------------------------------------------
  // User agency
  // ---------------------------------------------------------------------------

  /// Words after "you" that mean the sentence is *about* the user's situation
  /// or is unquoted speech, not the user's action.
  static const Set<String> _secondPersonStative = {
    'are', 'were', 'was', 'have', 'has', 'had', 'will', 'would', 'can',
    'could', 'should', 'must', 'might', 'may', 'do', 'did', 'cannot', 'know',
    'knew', 'need', 'want', 'mean', 'see', 'remember', 'think', 'thought',
    'said', 'told', 'asked', 'and', 'or', 'but', 'too', 'also', 'always',
    'never',
  };

  static const String _bodyNouns =
      'heart|breath|pulse|eyes|hands?|fingers|legs|knees|cheeks?|face|'
      'stomach|chest|throat|body|voice|lips|mouth|skin|head|shoulders|ears|'
      'spine|mind|thoughts?';

  static const String _speechVerbs =
      'said|says|asked|asks|replied|replies|whispered|whispers|murmured|'
      'murmurs|muttered|mutters|shouted|shouts|answered|answers|added|adds|'
      'laughed|laughs|sighed|sighs|breathed|exclaimed|responded|responds|'
      'called|calls|snapped|snaps|stammered|stammers';

  static const Set<String> _titleWords = {
    'the', 'a', 'an', 'sir', 'lady', 'lord', 'dr', 'mr', 'mrs', 'ms', 'miss',
    'captain', 'king', 'queen', 'prince', 'princess', 'master', 'mistress',
  };

  /// The ways the user's character is referred to: the full name, plus the
  /// first name of a multi-word name (replies say "Noah", the persona is
  /// "Noah Smith").
  static List<String> _nameForms(String name) {
    final forms = <String>[name];
    final parts = name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      final first = parts.first.replaceAll(
        RegExp(r'[^\p{L}\p{N}\-]', unicode: true),
        '',
      );
      if (first.length >= 3 &&
          !_titleWords.contains(first.toLowerCase()) &&
          _isUpper(first[0])) {
        forms.add(first);
      }
    }
    return forms;
  }

  static bool _insideAsterisk(String text, int pos) {
    var stars = 0;
    for (var i = 0; i < pos; i++) {
      if (text[i] == '*') stars++;
    }
    return stars.isOdd;
  }

  /// Start of the first place in [text] where the reply plays the user's
  /// character, or null:
  ///
  /// * a line that opens with a speaker label — `Name:`, `**Name:**`, `User:`;
  /// * a sentence outside any quote that opens with the user's name (or first
  ///   name) and an action — `Sam nods and takes her hand.`, or with the name's
  ///   possessive and a body part — `Sam's eyes widen.`;
  /// * second person — `You nod.`, `*You step closer.*`, `Your heart races.`;
  /// * the user's words tagged with their name — `"I'm here," Sam says.`
  static int? _firstUserViolation(String text, String name) {
    final isGeneric = name.isEmpty || name.toLowerCase() == 'user';
    final forms = isGeneric ? const <String>[] : _nameForms(name);
    final formAlt = forms.map(RegExp.escape).join('|');
    final labelAlt = isGeneric ? 'user' : '$formAlt|user';
    final usesQuotes = text.contains('"') || text.contains('\u201C');
    // No quotes and no asterisks at all: plain prose, where "You nod." is
    // narration about the user rather than a line of unquoted speech.
    final plainProse = !usesQuotes && !text.contains('*');
    final found = <int>[];

    int backOverMarks(int j) {
      while (j > 0 && (text[j - 1] == '*' || text[j - 1] == '_')) {
        j--;
      }
      return j;
    }

    final label = RegExp(
      '^[ \\t]*[*_\\[<(]*(?:$labelAlt)[*_\\]>)]*[ \\t]*[:\uFF1A]',
      caseSensitive: false,
      multiLine: true,
    );
    final labelMatch = label.firstMatch(text);
    if (labelMatch != null) found.add(labelMatch.start);

    // `pattern` finds the start of a phrase; the first hit that begins a
    // sentence outside a quote counts. [needsFormat] limits second person to
    // text that is clearly narration (the reply quotes speech, or the phrase
    // sits inside *asterisks*), so unquoted dialogue is not mistaken for it.
    void scan(RegExp pattern, {bool needsFormat = false}) {
      for (final m in pattern.allMatches(text)) {
        final next = m.groupCount >= 1 ? m.group(m.groupCount) : null;
        if (next != null &&
            (_nonActionWords.contains(next) ||
                (needsFormat && _secondPersonStative.contains(next)))) {
          continue;
        }
        final j = backOverMarks(m.start);
        if (!_isSentenceStart(text, j)) continue;
        if (_insideQuote(text, j)) continue;
        if (needsFormat &&
            !(usesQuotes || plainProse || _insideAsterisk(text, m.start))) {
          continue;
        }
        found.add(j);
        break;
      }
    }

    for (final form in forms) {
      final esc = RegExp.escape(form);
      scan(RegExp("$esc[ \\t]+([a-z][a-z']*)"));
      scan(RegExp("$esc['\u2019]s[ \\t]+(?:$_bodyNouns)[ \\t]+([a-z][a-z']*)"));
    }
    scan(RegExp("[Yy]ou[ \\t]+([a-z][a-z']*)"), needsFormat: true);
    scan(
      RegExp("[Yy]our[ \\t]+(?:$_bodyNouns)[ \\t]+([a-z][a-z']*)"),
      needsFormat: true,
    );

    if (forms.isNotEmpty) {
      final tag = RegExp(
        '["\u201D][ \\t]*,?[ \\t]*(?:$formAlt)[ \\t]+(?:$_speechVerbs)\\b',
      );
      for (final m in tag.allMatches(text)) {
        var open = -1;
        for (var i = m.start - 1; i >= 0; i--) {
          if (text[i] == '"' || text[i] == '\u201C') {
            open = i;
            break;
          }
        }
        if (open >= 0) {
          found.add(backOverMarks(open));
          break;
        }
      }
    }

    if (found.isEmpty) return null;
    found.sort();
    return found.first;
  }

  /// End of the sentence (or line) that starts at [from].
  static int _violationEnd(String text, int from) {
    final nl = text.indexOf('\n', from);
    final lineEnd = nl == -1 ? text.length : nl;
    final m = RegExp(
      '[.!?\u2026]+[*_"\u201D\u2019)\\]]*(?=\\s|\$)',
    ).firstMatch(text.substring(from, lineEnd));
    return m == null ? lineEnd : from + m.end;
  }

  /// Cuts [text] at the first place where the model starts playing the user's
  /// character (see [_firstUserViolation]).
  ///
  /// Whatever came before the cut is kept (with open `*` / `"` spans closed).
  /// When the reply *opens* with the violation, that sentence (or line) is
  /// dropped and the rest is checked again, so a reply is never left speaking
  /// for the user just because it started that way. If nothing would be left,
  /// the original text is returned.
  static String enforceUserAgency(String text, String userName) {
    final name = userName.trim();
    var work = text;
    for (var i = 0; i < 8; i++) {
      final cut = _firstUserViolation(work, name);
      if (cut == null) return work.trim().isEmpty ? text : work;
      final head = work.substring(0, cut);
      if (head.trim().isNotEmpty) {
        final kept = _trimRight(head);
        if (kept.isEmpty) return text;
        return kept + _closersFor(kept);
      }
      final end = _violationEnd(work, cut);
      if (end >= work.length) return text;
      work = work.substring(end).trimLeft();
      if (work.isEmpty) return text;
    }
    return text;
  }

  static bool _isSentenceStart(String text, int j) {
    if (j == 0) return true;
    final before = text.substring(0, j);
    if (before.endsWith('\n')) return true;
    final stripped = before.replaceFirst(RegExp(r'[ \t]+$'), '');
    // Needs real whitespace between the previous sentence and the name.
    if (stripped.length == before.length || stripped.isEmpty) return false;
    var k = stripped.length;
    while (k > 0 && _isCloser(stripped[k - 1])) {
      k--;
    }
    if (k > 0 && _isTerminator(stripped[k - 1])) return true;
    return stripped.endsWith('\n');
  }

  static bool _insideQuote(String text, int pos) {
    var open = false;
    for (var i = 0; i < pos; i++) {
      final c = text[i];
      if (c == '"') {
        open = !open;
      } else if (c == '\u201C') {
        open = true;
      } else if (c == '\u201D') {
        open = false;
      }
    }
    return open;
  }

  // ---------------------------------------------------------------------------
  // Length ceiling
  // ---------------------------------------------------------------------------

  /// Keeps at most [maxParagraphs] blank-line-separated paragraphs of [text].
  ///
  /// Only acts on replies that are both over the paragraph cap and over
  /// [minWords] words, and only when the text really is paragraphed (a single
  /// block is never cut). The cut is at a paragraph boundary, so nothing is
  /// sliced mid-sentence.
  static String capParagraphs(
    String text, {
    required int maxParagraphs,
    required int minWords,
    int? maxWords,
  }) {
    final paragraphs = text.split(RegExp(r'\n[ \t]*\n+'));
    if (paragraphs.length < 2 && maxWords != null) {
      return _capLines(text, maxWords);
    }
    if (paragraphs.length <= maxParagraphs || paragraphs.length < 2) {
      return text;
    }
    final words = text
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .length;
    if (words <= minWords) return text;
    final kept = _trimRight(paragraphs.take(maxParagraphs).join('\n\n'));
    if (kept.isEmpty) return text;
    return kept + _closersFor(kept);
  }

  /// For replies whose paragraphs are separated by single line breaks (no
  /// blank lines): keeps whole lines until adding the next one would pass
  /// [maxWords]. At least the first line is always kept, and a reply already
  /// within [maxWords] is returned unchanged.
  static String _capLines(String text, int maxWords) {
    int count(String t) =>
        t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    if (count(text) <= maxWords) return text;
    final lines = text.split('\n');
    if (lines.length < 2) return text;
    final kept = <String>[];
    var total = 0;
    for (final line in lines) {
      final n = count(line);
      if (kept.isNotEmpty && total + n > maxWords) break;
      kept.add(line);
      total += n;
    }
    final out = _trimRight(kept.join('\n'));
    if (out.isEmpty || out.length >= text.trimRight().length) return text;
    return out + _closersFor(out);
  }

  // ---------------------------------------------------------------------------

  static String _trimRight(String s) {
    var end = s.length;
    while (end > 0 && _isSpace(s[end - 1])) {
      end--;
    }
    return s.substring(0, end);
  }

  static String _trimLeft(String s) {
    var start = 0;
    while (start < s.length && _isSpace(s[start])) {
      start++;
    }
    return s.substring(start);
  }
}
