/// Emoji-safe string helpers.
///
/// Dart strings are UTF-16, and one emoji is usually a *surrogate pair* (two
/// code units), often followed by a variation selector or glued to others with
/// zero-width joiners (👨‍👩‍👧, 👍🏽, ❤️). Cutting a string with `substring` at
/// an arbitrary index can slice such a sequence in half. A lone surrogate is
/// not valid text: it shows as a replacement box, and some servers
/// (llama.cpp, Ollama) answer a request that contains one with a 400.
library;

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// Replaces every unpaired surrogate in [text] with U+FFFD. Well-formed text
/// (including every valid emoji) is returned untouched, and the same instance
/// is returned when there is nothing to fix.
String stripLoneSurrogates(String text) {
  StringBuffer? out;
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    var bad = false;
    if (_isHighSurrogate(unit)) {
      if (i + 1 < units.length && _isLowSurrogate(units[i + 1])) {
        out?.writeCharCode(unit);
        out?.writeCharCode(units[i + 1]);
        i++;
        continue;
      }
      bad = true;
    } else if (_isLowSurrogate(unit)) {
      bad = true;
    }
    if (bad) {
      out ??= StringBuffer(text.substring(0, i));
      out.writeCharCode(0xFFFD);
    } else {
      out?.writeCharCode(unit);
    }
  }
  return out?.toString() ?? text;
}

/// `text.substring(0, end)` that never ends in the middle of a surrogate pair.
/// When [end] would split one, the whole emoji is dropped instead of leaving a
/// broken half behind.
String safePrefix(String text, int end) {
  if (end >= text.length) return text;
  if (end <= 0) return '';
  var cut = end;
  if (_isHighSurrogate(text.codeUnitAt(cut - 1)) &&
      _isLowSurrogate(text.codeUnitAt(cut))) {
    cut--;
  }
  return text.substring(0, cut);
}

/// Whether [rune] belongs to an emoji / pictograph / its joiners.
bool isEmojiRune(int rune) =>
    (rune >= 0x1F000 && rune <= 0x1FAFF) || // symbols, faces, flags, objects
    (rune >= 0x2600 && rune <= 0x27BF) || // misc symbols + dingbats (☀ ✨ ❤)
    (rune >= 0x2B00 && rune <= 0x2BFF) || // stars, arrows (⭐ ⬆)
    (rune >= 0x2190 && rune <= 0x21FF) || // arrows (↩ ↪)
    (rune >= 0x2300 && rune <= 0x23FF) || // watch, hourglass (⌚ ⏳)
    rune == 0x203C ||
    rune == 0x2049 ||
    rune == 0x2122 ||
    rune == 0x2139 ||
    rune == 0x00A9 ||
    rune == 0x00AE ||
    rune == 0x3030 ||
    rune == 0x303D ||
    rune == 0x3297 ||
    rune == 0x3299 ||
    rune == 0xFE0F || // emoji variation selector
    rune == 0x200D || // zero-width joiner
    (rune >= 0xE0020 && rune <= 0xE007F); // tag characters (subdivision flags)

/// Whether the last visible thing in [text] is an emoji. People (and models)
/// end a sentence with an emoji instead of a full stop: "That sounds great 😊".
bool endsWithEmoji(String text) {
  final runes = text.runes.toList();
  var i = runes.length - 1;
  while (i >= 0) {
    final r = runes[i];
    if (r == 0x20 || r == 0x0A || r == 0x0D || r == 0x09 || r == 0xA0) {
      i--;
      continue;
    }
    // Closing marks glued after the emoji, e.g. "😊*" or "😊\"".
    if (r == 0x2A || r == 0x22 || r == 0x201D || r == 0x29 || r == 0x5D) {
      i--;
      continue;
    }
    return isEmojiRune(r);
  }
  return false;
}
