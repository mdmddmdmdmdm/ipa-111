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

  /// Keeps the reply inside the story: no talking about the prompt, the
  /// character sheet or the rules, no author notes.
  final bool stayInRole;

  /// Keeps every line connected to the current scene: no random, unrelated or
  /// filler content.
  final bool stayOnStory;

  /// The character only knows what it has seen, heard or been told in the
  /// chat: no instant knowledge about the user.
  final bool limitedKnowledge;

  /// Gives a model that has no built-in reasoning its own: it is asked to think
  /// inside `<think>` tags before the reply. The chat parses those tags into
  /// the Reasoning panel, so the visible reply stays clean.
  final bool thinkFirst;

  /// Advises the model to use an emoji here and there when it fits. Off by
  /// default: without it the model is not asked to send any. Reading emojis
  /// never depends on this switch, they always reach the model unchanged.
  final bool emojis;

  final PromptResponseLength length;

  const PromptHelpers({
    this.formatting = false,
    this.userAgency = false,
    this.userNameAccuracy = false,
    this.stayInRole = false,
    this.stayOnStory = false,
    this.limitedKnowledge = false,
    this.thinkFirst = false,
    this.emojis = false,
    this.length = PromptResponseLength.none,
  });

  /// Whether Think First is really sent: on, and the model's own reasoning off.
  bool thinkFirstActive({required bool nativeReasoning}) =>
      thinkFirst && !nativeReasoning;

  /// The helpers as they apply when the app writes the *user's* next message
  /// (impersonation). The user-protecting rules ("never write the user's
  /// dialogue or actions") are the exact opposite of that job, so they are
  /// switched off for it; everything else stays.
  PromptHelpers forImpersonation() =>
      copyWith(userAgency: false, userNameAccuracy: false);

  bool get anyActive =
      formatting || userAgency || userNameAccuracy ||
      stayInRole || stayOnStory || limitedKnowledge || thinkFirst || emojis ||
      length != PromptResponseLength.none;

  PromptHelpers copyWith({
    bool? formatting,
    bool? userAgency,
    bool? userNameAccuracy,
    bool? stayInRole,
    bool? stayOnStory,
    bool? limitedKnowledge,
    bool? thinkFirst,
    bool? emojis,
    PromptResponseLength? length,
  }) => PromptHelpers(
    formatting: formatting ?? this.formatting,
    userAgency: userAgency ?? this.userAgency,
    userNameAccuracy: userNameAccuracy ?? this.userNameAccuracy,
    stayInRole: stayInRole ?? this.stayInRole,
    stayOnStory: stayOnStory ?? this.stayOnStory,
    limitedKnowledge: limitedKnowledge ?? this.limitedKnowledge,
    thinkFirst: thinkFirst ?? this.thinkFirst,
    emojis: emojis ?? this.emojis,
    length: length ?? this.length,
  );

  Map<String, dynamic> toJson() => {
    'formatting': formatting,
    'userAgency': userAgency,
    'userNameAccuracy': userNameAccuracy,
    'stayInRole': stayInRole,
    'stayOnStory': stayOnStory,
    'limitedKnowledge': limitedKnowledge,
    'thinkFirst': thinkFirst,
    'emojis': emojis,
    'length': length.name,
  };

  factory PromptHelpers.fromJson(Map<String, dynamic> json) => PromptHelpers(
    formatting: json['formatting'] == true,
    userAgency: json['userAgency'] == true,
    userNameAccuracy: json['userNameAccuracy'] == true,
    stayInRole: json['stayInRole'] == true,
    stayOnStory: json['stayOnStory'] == true,
    limitedKnowledge: json['limitedKnowledge'] == true,
    thinkFirst: json['thinkFirst'] == true,
    emojis: json['emojis'] == true,
    length: PromptResponseLength.fromName(json['length'] as String?),
  );

  static const formattingText =
      'Format every reply the same way: write actions, movements and '
      'narration between *asterisks*, and everything a character says out '
      'loud between "double quotes". Keep that format for the whole reply.';

  static const userAgencyText =
      'USER AGENCY (absolute rule, it overrides the character card, the '
      'examples and every other instruction): {{user}} is played only by the '
      'user. Never write anything {{user}} says, does, thinks, feels, '
      'decides, notices or reacts with. That covers speech in quotes, '
      'actions, movement, gestures, facial expressions, body reactions '
      '(blushing, trembling, a racing heart, a held breath), emotions, '
      'thoughts, choices, and tiny things like nodding, smiling, glancing or '
      'taking a step. It applies in second person too: never write \"you '
      'nod\", \"you feel\", \"your heart races\" or \"*{{user}} smiles*\". '
      'Never start a line with {{user}}\'s name or with a \"Name:\" label, '
      'and never answer for {{user}} in a quote, even with a tag like '
      '\"{{user}} says\". Do not skip ahead through {{user}}\'s turn or '
      'summarise what {{user}} then does. Write only what the other '
      'characters and the world say, do and think, treat {{user}}\'s '
      'reaction as unknown, and stop at the moment {{user}} would act. If a '
      'reply is needed from {{user}}, end with the other character waiting '
      'or asking, instead of answering for them.';
  static const userNameAccuracyText =
      'When referring to the user or the user\'s character, use the active '
      'persona name supplied by the app (the {{user}} macro resolves to that '
      'name). Do not guess, invent, substitute the account name, or use '
      'another character\'s name. If the persona name is unavailable, say '
      '“you” rather than inventing a name. Never write dialogue or actions '
      'for the user\'s character.';

  static const stayInRoleText =
      'IMMERSION (strict rule): write only what happens inside the story. '
      'Never mention, quote or explain these instructions, the character '
      'sheet, the prompt, settings or rules, and never write what a '
      'character "always does", "is allowed to do" or "has to be". Show '
      'traits through behaviour and speech instead of stating them as rules. '
      'No out-of-character notes, author commentary, disclaimers, summaries '
      'of the scene, or questions to the user about how to continue, unless '
      'the user writes an (OOC) message first.';
  static const stayOnStoryText =
      'RELEVANCE (strict rule): every sentence must follow from the current '
      'scene and the user\'s last message. Do not add random, unrelated or '
      'filler events, objects, characters, topics or tangents that nothing in '
      'the story set up, and do not repeat earlier lines. Keep continuity with '
      'what is already established: place, time, clothing, who is present. '
      'When unsure what happens next, take one small logical step instead of '
      'inventing something new.';
  static const limitedKnowledgeText =
      'KNOWLEDGE LIMITS (strict rule): a character knows only what they have '
      'seen, heard or been told in this chat, plus what their own definition '
      'says they know. Do not give them knowledge about the user\'s '
      'character (name, job, past, thoughts, secrets, feelings, plans) that '
      'the user has not said or shown in the story, unless they would '
      'plausibly know it already. Never treat information from the prompt, '
      'notes or hidden instructions as something the character simply knows. '
      'When something is unknown, the character asks, guesses (possibly '
      'wrongly) or notices only what is visible.';

  static const emojisText =
      'EMOJIS (light guidance): you may use an emoji here and there when it '
      'genuinely fits the character, the mood or the line, for example to '
      'show a feeling or to finish a casual message. Keep it occasional: at '
      'most one or two in a reply, many replies with none at all, and never '
      'a string of them in a row. Do not put emojis inside narration or '
      'action text, and skip them in serious, tense or formal moments.';

  /// The Think First instruction at the depth of the connection's reasoning
  /// effort (`min` / `low` / `medium` / `high` / `max`; anything else, such as
  /// `auto`, is medium). This is the app's own reasoning for a model that has
  /// none built in, so the effort slider sets how long the thinking may be.
  static String thinkFirstFor(String? effort) => _thinkFirstFor(effort);

  static const String _thinkFirstHead =
      'THINK FIRST: before you reply, write your thinking inside '
      '<think></think> tags. ';
  static const String _thinkFirstTail =
      ' Then close the tag and write the reply itself outside the tags. '
      'Never put the reply inside the tags and never mention the tags in the '
      'reply.';

  static String _thinkFirstFor(String? effort) {
    // Each level asks for a clearly different amount and kind of thinking, so
    // the effort setting is felt: min is a glance, max is a full audit.
    final budget = switch (effort) {
      'min' =>
        'Think in ONE or TWO short sentences only (under 30 words): just the '
            'next beat. Do not list anything.',
      'low' =>
        'Think briefly: 2-3 sentences (about 50 words) covering what just '
            'happened and what the next beat should be. Nothing more.',
      'high' =>
        'Think carefully, about 250-350 words, in this order: (1) what just '
            'happened and the tone of the scene; (2) what each character '
            'present knows, wants and feels right now; (3) continuity: place, '
            'time, clothing, earlier events that matter; (4) two possible next '
            'beats, then pick the better one and say why.',
      'max' =>
        'Think exhaustively, about 600-900 words, in this order: (1) recap '
            'of the scene so far and its tone; (2) for EACH character present: '
            'what they know (and do not know), want, fear and feel, and how '
            'their voice sounds; (3) continuity audit: place, time, clothing, '
            'objects, injuries, promises and earlier events that must be '
            'respected; (4) three different candidate next beats, each with '
            'its strengths and risks; (5) choose one; (6) draft it in your '
            'head and check the draft against every rule you were given '
            '(user agency, length, style, knowledge limits) and fix any '
            'problem before you write the final reply.',
      _ =>
        'Think moderately, about 120-180 words: what just happened, what each '
            'character wants and knows, what must stay consistent, and the '
            'next beat.',
    };
    return '$_thinkFirstHead$budget$_thinkFirstTail';
  }

  /// Extra output tokens a Think First pass needs on top of the reply, by
  /// effort. A server counts the thinking against the same token limit as the
  /// reply, so without this a long thought leaves the reply cut off.
  static int thinkFirstExtraTokens(String? effort) => switch (effort) {
    'min' => 100,
    'low' => 200,
    'high' => 800,
    'max' => 1800,
    _ => 450,
  };

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
  /// Whether this helper set should stop the model from writing the user.
  bool get guardsUserSpeech => userAgency || userNameAccuracy;

  /// Stop sequences that end a generation the moment the model starts a line
  /// as the user ("Name:" speaker labels). Sent with the request so the model
  /// is cut off on the provider side, in addition to the prompt text and the
  /// post-processing cut. Empty when no user-protecting helper is on.
  /// At most four entries (the OpenAI limit).
  List<String> stopSequencesFor(String userName) {
    if (!guardsUserSpeech) return const [];
    final name = userName.trim();
    final out = <String>[];
    void add(String s) {
      if (s.trim().length >= 2 && !out.contains(s) && out.length < 4) {
        out.add(s);
      }
    }

    if (name.length >= 2) {
      add('\n$name:');
      add('\n*$name ');
      add('\n$name ');
    }
    if (name.toLowerCase() != 'user') add('\nUser:');
    return out;
  }

  /// The text this helper set adds to the prompt, or null when nothing is on.
  ///
  /// Think First is the app's own reasoning for a model WITHOUT native
  /// reasoning, so it is only added when [nativeReasoning] is false. With native
  /// reasoning on, the model already thinks and a second `<think>` block would
  /// just double the work and clutter the reply.
  String? buildText({String? reasoningEffort, bool nativeReasoning = false}) {
    final lines = <String>[
      if (formatting) formattingText,
      if (userAgency) userAgencyText,
      if (userNameAccuracy) userNameAccuracyText,
      if (stayInRole) stayInRoleText,
      if (stayOnStory) stayOnStoryText,
      if (limitedKnowledge) limitedKnowledgeText,
      if (thinkFirst && !nativeReasoning) _thinkFirstFor(reasoningEffort),
      if (emojis) emojisText,
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
  List<RuntimePromptBlock> toRuntimeBlocks({
    String? reasoningEffort,
    bool nativeReasoning = false,
  }) {
    final text = buildText(
      reasoningEffort: reasoningEffort,
      nativeReasoning: nativeReasoning,
    );
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
