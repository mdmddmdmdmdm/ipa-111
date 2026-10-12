import 'prompt/runtime_prompt_block.dart';

/// How long the model is asked to make each reply. [none] sends nothing, so
/// the preset's own length wording stays in charge.
enum PromptResponseLength {
  none,
  short,
  medium,
  long;

  static PromptResponseLength fromName(String? name) {
    for (final value in PromptResponseLength.values) {
      if (value.name == name) return value;
    }
    return PromptResponseLength.none;
  }
}

/// The optional prompt helpers: short instructions added to the end of every
/// chat prompt when switched on. Global (not per character or per API config),
/// so the API screen and the chat Tools panel always show the same values.
class PromptHelpers {
  /// Asks for `*actions*` and `"dialogue"` formatting.
  final bool formatting;

  /// Stops the model from writing the user's character.
  final bool userAgency;

  /// Explicitly anchors references to the user to the active persona name and
  /// the resolved {{user}} macro, rather than guessing or using the wrong name.
  final bool userNameAccuracy;

  final PromptResponseLength length;

  const PromptHelpers({
    this.formatting = false,
    this.userAgency = false,
    this.userNameAccuracy = false,
    this.length = PromptResponseLength.none,
  });

  bool get anyActive =>
      formatting || userAgency || userNameAccuracy ||
      length != PromptResponseLength.none;

  PromptHelpers copyWith({
    bool? formatting,
    bool? userAgency,
    bool? userNameAccuracy,
    PromptResponseLength? length,
  }) => PromptHelpers(
    formatting: formatting ?? this.formatting,
    userAgency: userAgency ?? this.userAgency,
    userNameAccuracy: userNameAccuracy ?? this.userNameAccuracy,
    length: length ?? this.length,
  );

  Map<String, dynamic> toJson() => {
    'formatting': formatting,
    'userAgency': userAgency,
    'userNameAccuracy': userNameAccuracy,
    'length': length.name,
  };

  factory PromptHelpers.fromJson(Map<String, dynamic> json) => PromptHelpers(
    formatting: json['formatting'] == true,
    userAgency: json['userAgency'] == true,
    userNameAccuracy: json['userNameAccuracy'] == true,
    length: PromptResponseLength.fromName(json['length'] as String?),
  );

  static const formattingText =
      'Format every reply the same way: write actions, movements and '
      'narration between *asterisks*, and everything a character says out '
      'loud between "double quotes". Keep that format for the whole reply.';

  static const userAgencyText =
      'USER AGENCY (strict rule): the user\'s character belongs only to the '
      'user. Never write their dialogue, actions, movements, reactions, '
      'thoughts, feelings, decisions or choices, not even small ones like '
      'nodding, smiling or taking a step. Do not start a line with their '
      'name, and never write a "Name:" speaker label for them. Describe only '
      'the other characters and the world, then stop and leave the next move '
      'to the user. End your reply at the point where the user\'s character '
      'would respond.';
  static const userNameAccuracyText =
      'When referring to the user or the user\'s character, use the active '
      'persona name supplied by the app (the {{user}} macro resolves to that '
      'name). Do not guess, invent, substitute the account name, or use '
      'another character\'s name. If the persona name is unavailable, say '
      '“you” rather than inventing a name. Never write dialogue or actions '
      'for the user\'s character.';

  static const shortText =
      'LENGTH (strict rule): keep this reply SHORT, at most 2 brief '
      'paragraphs and roughly 60-120 words in total. Cover only the single '
      'most important beat, then stop. Do not exceed this length.';
  static const mediumText =
      'LENGTH (strict rule): write a MEDIUM-length reply of 4-6 paragraphs, '
      'roughly 200-350 words in total, with meaningful detail. Do not go '
      'noticeably shorter or longer than this.';
  static const longText =
      'LENGTH (strict rule): write a LONG, detailed reply of at least 6 '
      'paragraphs and 400 words or more, with rich description of '
      'surroundings, body language, sensations and dialogue. Do not cut '
      'the reply short.';
  /// The text this helper set adds to the prompt, or null when nothing is on.
  String? buildText() {
    final lines = <String>[
      if (formatting) formattingText,
      if (userAgency) userAgencyText,
      if (userNameAccuracy) userNameAccuracyText,
      switch (length) {
        PromptResponseLength.none => '',
        PromptResponseLength.short => shortText,
        PromptResponseLength.medium => mediumText,
        PromptResponseLength.long => longText,
      },
    ].where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return null;
    return '[Response instructions]\n${lines.join('\n')}';
  }

  /// The prompt block that carries [buildText] — newest position in the
  /// prompt (depth 0), where models follow instructions best — or an empty
  /// list when no helper is on.
  List<RuntimePromptBlock> toRuntimeBlocks() {
    final text = buildText();
    if (text == null) return const [];
    return [
      RuntimePromptBlock(
        id: 'prompt_helpers',
        content: text,
        depth: 0,
        role: 'system',
      ),
    ];
  }
}
