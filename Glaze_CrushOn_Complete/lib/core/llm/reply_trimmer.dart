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

  /// Cuts [text] at the first place where the model starts playing the user's
  /// character:
  ///
  /// * a line that opens with a speaker label — `Name:`, `**Name:**`,
  ///   `[Name]:`, `User:`;
  /// * a sentence outside any quote that opens with the user's name followed by
  ///   a lowercase word that is not a state verb — `Sam nods and takes her
  ///   hand.`
  ///
  /// Whatever came before the cut is kept (with open `*` / `"` spans closed).
  /// A reply that *opens* with such a line is returned unchanged, since there
  /// would be nothing left.
  static String enforceUserAgency(String text, String userName) {
    final name = userName.trim();
    if (name.length < 2) return text;
    final escaped = RegExp.escape(name);
    final isGeneric = name.toLowerCase() == 'user';
    final alt = isGeneric ? escaped : '$escaped|user';

    int? cut;

    final label = RegExp(
      '^[ \\t]*[*_\\[<(]*(?:$alt)[*_\\]>)]*[ \\t]*[:\uFF1A]',
      caseSensitive: false,
      multiLine: true,
    );
    final labelMatch = label.firstMatch(text);
    if (labelMatch != null && text.substring(0, labelMatch.start).trim().isNotEmpty) {
      cut = labelMatch.start;
    }

    if (!isGeneric) {
      final starter = RegExp("$escaped[ \\t]+([a-z][a-z']*)");
      for (final m in starter.allMatches(text)) {
        final p = m.start;
        if (cut != null && p >= cut) break;
        final next = m.group(1)!;
        if (_nonActionWords.contains(next)) continue;
        // The reply opens with the name: nothing would be left, leave it.
        if (text.substring(0, p).trim().isEmpty) break;

        var j = p;
        while (j > 0 && (text[j - 1] == '*' || text[j - 1] == '_')) {
          j--;
        }
        if (!_isSentenceStart(text, j)) continue;
        if (_insideQuote(text, j)) continue;
        cut = (cut == null || j < cut) ? j : cut;
        break;
      }
    }

    if (cut == null) return text;
    final kept = _trimRight(text.substring(0, cut));
    if (kept.isEmpty) return text;
    return kept + _closersFor(kept);
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
  }) {
    final paragraphs = text.split(RegExp(r'\n[ \t]*\n+'));
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
