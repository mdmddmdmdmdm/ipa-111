/// The sites whose chat history the Provider Characters tab can read.
enum ProviderChatSite {
  janitor('JanitorAI', 'janitor'),
  spicychat('SpicyChat', 'spicychat'),
  chub('Chub', 'chub'),
  crushon('CrushOn', 'crushon'),

  /// A chat opened from an exported file instead of an account.
  file('Exported file', 'file');

  const ProviderChatSite(this.label, this.key);
  final String label;
  final String key;
}

/// One message of a provider chat, already reduced to what the app needs.
class ProviderChatMessage {
  const ProviderChatMessage({
    required this.isUser,
    required this.text,
    this.timestampMs,
    this.name,
    this.alternates = const [],
  });

  final bool isUser;
  final String text;
  final int? timestampMs;

  /// Speaker name when the provider sends one.
  final String? name;

  /// Other versions of this reply (swipes), when the provider keeps them.
  final List<String> alternates;
}

/// One row of the Provider Characters list: a character the signed-in account
/// has chatted with, and the chat to open.
class ProviderChatSummary {
  const ProviderChatSummary({
    required this.site,
    required this.chatId,
    required this.characterName,
    this.characterId,
    this.avatarUrl,
    this.lastMessage,
    this.messageCount,
    this.updatedAtMs,
    this.accountLabel,
    this.characterUrl,
  });

  final ProviderChatSite site;
  final String chatId;
  final String characterName;
  final String? characterId;
  final String? avatarUrl;
  final String? lastMessage;
  final int? messageCount;
  final int? updatedAtMs;

  /// Which signed-in account the chat came from (display name), if known.
  final String? accountLabel;

  /// The public page of the character, used to find or import the card.
  final String? characterUrl;

  String get key => '${site.key}:$chatId';
}

/// A whole chat, read-only.
class ProviderChatTranscript {
  const ProviderChatTranscript({
    required this.summary,
    required this.messages,
    this.memory,
    this.userName,
    this.greetings = const [],
  });

  final ProviderChatSummary summary;
  final List<ProviderChatMessage> messages;

  /// The provider's own memory / summary of the chat, carried into the app's
  /// chat summary on import so the character keeps remembering it.
  final String? memory;
  final String? userName;

  /// The character's opening messages, when the provider returns them with the
  /// chat.
  final List<String> greetings;
}

/// Raised with a message the user can read; [detail] says exactly which
/// request failed so a screenshot is enough to fix an endpoint that changed.
class ProviderChatException implements Exception {
  const ProviderChatException(this.message, {this.detail});
  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message\n$detail';
}
