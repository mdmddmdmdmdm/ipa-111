/// Recovers a reply that the model (or its provider) put inside the reasoning
/// channel, leaving the visible message empty.
///
/// Typical causes: a provider that returns the whole answer as
/// `reasoning_content`, a closing `</think>` tag the model never wrote, or a
/// reasoning block that wraps the real reply. The app used to save an empty
/// message and show everything under "Reasoning"; this decides when the
/// reasoning text is really the roleplay reply and moves it.
///
/// It is deliberately conservative. Genuine thinking ("The user wants...",
/// "I should...") is left alone, because turning analysis into the reply would
/// be worse than an empty one the user can simply regenerate.
class SalvagedReply {
  final String text;
  final String? reasoning;
  final bool salvaged;

  const SalvagedReply(this.text, this.reasoning, {this.salvaged = false});
}

final _closingMarkers = RegExp(
  r'</think(?:ing)?\s*>|\[/think(?:ing)?\]|</reasoning\s*>|</thought\s*>',
  caseSensitive: false,
);

final _openingMarkers = RegExp(
  r'<think(?:ing)?\s*>|\[think(?:ing)?\]|<reasoning\s*>|<thought\s*>',
  caseSensitive: false,
);

final _answerLabel = RegExp(
  r'^\s*(?:\*\*)?(?:final (?:answer|response|reply|output)|response|reply|'
  r'output|roleplay response|in-character reply)(?:\*\*)?\s*[:\-]\s*',
  caseSensitive: false,
  multiLine: true,
);

final _metaOpener = RegExp(
  r'^\s*(?:okay|ok|alright|so|hmm|wait|let me|let.s|i need|i should|i.ll|'
  r'i will|i must|i.m going|first|the user|user |the player|the character|'
  r'thinking|analysis|looking at|we need|we are|this is|here.s my|plan|step|'
  r'my response|the response|the reply|the scene|the story|current)',
  caseSensitive: false,
);

final _metaPhrase = RegExp(
  r'\b(?:the user|the player|i should|i need to|i.ll write|i will write|'
  r'let me|my response|the character should|the response should|'
  r'in this scene|the instruction|the prompt|system prompt|guidelines?)\b',
  caseSensitive: false,
);

final _dialogue = RegExp('[\u201C"][^\u201C\u201D"\n]{3,}[\u201D"]');
final _action = RegExp(r'\*[^*\n]{3,}\*');

/// Returns the text and reasoning to save. Unchanged when the reply is not
/// empty, or when the reasoning does not look like a reply.
SalvagedReply salvageEmptyReply({
  required String text,
  required String? reasoning,
}) {
  final r = (reasoning ?? '').trim();
  if (text.trim().isNotEmpty || r.isEmpty) {
    return SalvagedReply(text, reasoning);
  }

  // 1) Text after the last closing reasoning tag.
  final closes = _closingMarkers.allMatches(r).toList();
  if (closes.isNotEmpty) {
    final tail = r.substring(closes.last.end).trim();
    if (tail.length >= 2) {
      final head = r
          .substring(0, closes.last.start)
          .replaceAll(_openingMarkers, '')
          .trim();
      return SalvagedReply(tail, head.isEmpty ? null : head, salvaged: true);
    }
  }

  // 2) "Final response:" style labels.
  final labels = _answerLabel.allMatches(r).toList();
  if (labels.isNotEmpty) {
    final tail = r.substring(labels.last.end).trim();
    if (tail.length >= 20) {
      final head = r.substring(0, labels.last.start).trim();
      return SalvagedReply(tail, head.isEmpty ? null : head, salvaged: true);
    }
  }

  // 3) The whole reasoning reads like the roleplay reply itself.
  if (_looksLikeReply(r)) {
    return SalvagedReply(r, null, salvaged: true);
  }

  return SalvagedReply(text, reasoning);
}

bool _looksLikeReply(String r) {
  if (_metaOpener.hasMatch(r)) return false;
  if (_metaPhrase.allMatches(r).length >= 2) return false;
  final hasRoleplayMarkup = _dialogue.hasMatch(r) || _action.hasMatch(r);
  return hasRoleplayMarkup;
}
