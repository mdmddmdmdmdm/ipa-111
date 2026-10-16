import 'dart:convert';

import 'provider_chat_models.dart';

/// Pure readers for the JSON the providers (and their exports) return.
///
/// The sites do not publish their chat APIs, so these read by shape instead of
/// by one fixed schema: a list may sit at the root or under `chats`, `data`,
/// `conversations`…; a message text may be `message`, `content` or `text`; the
/// speaker may be `is_bot`, `role`, `sender`… Anything unreadable is skipped
/// rather than thrown on, and an empty result is reported by the caller.

const _listKeys = [
  'chats',
  'conversations',
  'data',
  'items',
  'results',
  'rows',
  'history',
  'chat_history',
];

const _messageKeys = [
  'chatMessages',
  'chat_messages',
  'messages',
  'history',
  'data',
  'items',
  'conversation',
  'turns',
];

/// Finds the list that holds the rows inside [json].
List<dynamic> _findList(dynamic json, List<String> keys) {
  if (json is List) return json;
  if (json is Map) {
    for (final key in keys) {
      final value = json[key];
      if (value is List) return value;
    }
    for (final key in keys) {
      final value = json[key];
      if (value is Map) {
        final nested = _findList(value, keys);
        if (nested.isNotEmpty) return nested;
      }
    }
  }
  return const [];
}

Map<String, dynamic>? _asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

String? _str(dynamic value) {
  if (value == null) return null;
  if (value is String) {
    final t = value.trim();
    return t.isEmpty ? null : t;
  }
  if (value is num || value is bool) return value.toString();
  return null;
}

String? _firstString(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final v = _str(map[key]);
    if (v != null) return v;
  }
  return null;
}

/// Milliseconds since epoch from an ISO string, seconds or milliseconds.
int? parseProviderTimestamp(dynamic value) {
  if (value == null) return null;
  if (value is num) {
    final n = value.toInt();
    if (n <= 0) return null;
    return n < 100000000000 ? n * 1000 : n;
  }
  if (value is String) {
    final asNum = num.tryParse(value);
    if (asNum != null) return parseProviderTimestamp(asNum);
    final parsed = DateTime.tryParse(value.trim().replaceFirst(' ', 'T'));
    return parsed?.millisecondsSinceEpoch;
  }
  return null;
}

String _joinUrl(String? base, String? value) {
  if (value == null || value.isEmpty) return '';
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return value;
  }
  if (base == null) return value;
  final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  if (value.startsWith('/')) return '$b$value';
  return '$b/$value';
}

/// Reads the chat list of an account into summaries.
List<ProviderChatSummary> parseProviderChatList(
  dynamic json, {
  required ProviderChatSite site,
  String? accountLabel,
  String? avatarBase,
  String Function(String characterId)? characterUrl,
}) {
  final rows = _findList(json, _listKeys);
  final out = <ProviderChatSummary>[];
  for (final row in rows) {
    final map = _asMap(row);
    if (map == null) continue;
    final chatId = _firstString(map, [
      'chat_id',
      'chatId',
      'conversation_id',
      'conversationId',
      'id',
      '_id',
    ]);
    if (chatId == null) continue;

    final character =
        _asMap(map['character']) ??
        _asMap(map['bot']) ??
        _asMap(map['chatbot']) ??
        _asMap(map['companion']) ??
        _asMap(map['persona_character']) ??
        const <String, dynamic>{};

    final characterId =
        _firstString(character, ['id', '_id', 'character_id', 'bot_id']) ??
        _firstString(map, [
          'character_id',
          'characterId',
          'bot_id',
          'chatbot_id',
          'companion_id',
        ]);
    final name =
        _firstString(character, ['name', 'chat_name', 'title']) ??
        _firstString(map, [
          'character_name',
          'characterName',
          'bot_name',
          'name',
          'title',
        ]) ??
        'Unknown character';
    final avatar =
        _firstString(character, [
          'avatar',
          'avatar_url',
          'avatarUrl',
          'image',
          'image_url',
          'avatar_path',
        ]) ??
        _firstString(map, ['avatar', 'avatar_url', 'avatarUrl', 'image']);

    final last = map['last_message'] ?? map['lastMessage'];
    final lastText = last is Map
        ? _firstString(Map<String, dynamic>.from(last), [
            'message',
            'content',
            'text',
          ])
        : _str(last);

    final count = map['message_count'] ?? map['messages_count'] ?? map['count'];

    out.add(
      ProviderChatSummary(
        site: site,
        chatId: chatId,
        characterName: name,
        characterId: characterId,
        avatarUrl: avatar == null ? null : _joinUrl(avatarBase, avatar),
        lastMessage: lastText,
        messageCount: count is num ? count.toInt() : int.tryParse('$count'),
        updatedAtMs: parseProviderTimestamp(
          map['updated_at'] ??
              map['updatedAt'] ??
              map['last_message_at'] ??
              map['lastMessageAt'] ??
              map['last_activity_at'] ??
              map['created_at'] ??
              map['createdAt'],
        ),
        accountLabel: accountLabel,
        characterUrl: characterId != null && characterUrl != null
            ? characterUrl(characterId)
            : null,
      ),
    );
  }
  out.sort((a, b) => (b.updatedAtMs ?? 0).compareTo(a.updatedAtMs ?? 0));
  return out;
}

bool? _isUserFlag(Map<String, dynamic> m) {
  final isBot = m['is_bot'] ?? m['isBot'];
  if (isBot is bool) return !isBot;
  final isUser = m['is_user'] ?? m['isUser'] ?? m['from_user'];
  if (isUser is bool) return isUser;
  final role = (_str(m['role']) ??
          _str(m['sender']) ??
          _str(m['author']) ??
          _str(m['from']) ??
          _str(m['type']))
      ?.toLowerCase();
  if (role != null) {
    if (role == 'user' || role == 'human' || role == 'me') return true;
    if (role == 'assistant' ||
        role == 'bot' ||
        role == 'ai' ||
        role == 'character' ||
        role == 'model') {
      return false;
    }
  }
  return null;
}

/// Reads one chat into messages, in order, with the provider's memory text.
ProviderChatTranscript parseProviderTranscript(
  dynamic json, {
  required ProviderChatSummary summary,
}) {
  final root = _asMap(json) ?? const <String, dynamic>{};
  final rows = _findList(json, _messageKeys);

  final messages = <ProviderChatMessage>[];
  for (final row in rows) {
    final map = _asMap(row);
    if (map == null) continue;
    // Alternate generations are stored as extra rows flagged is_main:false.
    if (map['is_main'] == false) continue;
    final text = _firstString(map, ['message', 'content', 'text', 'mes', 'body']);
    if (text == null) continue;
    final isUser = _isUserFlag(map);
    if (isUser == null && map['role'] == 'system') continue;

    final alternates = <String>[];
    final swipes = map['swipes'] ?? map['alternatives'] ?? map['alternates'];
    if (swipes is List) {
      for (final s in swipes) {
        final t = s is Map
            ? _firstString(Map<String, dynamic>.from(s), [
                'message',
                'content',
                'text',
              ])
            : _str(s);
        if (t != null && t != text) alternates.add(t);
      }
    }

    messages.add(
      ProviderChatMessage(
        isUser: isUser ?? false,
        text: text,
        timestampMs: parseProviderTimestamp(
          map['created_at'] ??
              map['createdAt'] ??
              map['timestamp'] ??
              map['send_date'] ??
              map['time'],
        ),
        name: _firstString(map, ['name', 'sender_name', 'author_name']),
        alternates: alternates,
      ),
    );
  }

  // Greetings the chat object carries with its character.
  final character = _asMap(root['character']) ?? const <String, dynamic>{};
  final greetings = <String>[];
  final first = character['first_messages'] ?? character['first_message'];
  if (first is List) {
    for (final g in first) {
      final t = _str(g);
      if (t != null) greetings.add(t);
    }
  } else {
    final t = _str(first);
    if (t != null) greetings.add(t);
  }

  // The memory / summary the provider keeps for this chat.
  String? memory;
  for (final key in const [
    'memory',
    'chat_memory',
    'chatMemory',
    'memories',
    'summary',
    'chat_summary',
    'long_term_memory',
  ]) {
    final v = root[key];
    if (v is String && v.trim().isNotEmpty) {
      memory = v.trim();
      break;
    }
    if (v is List && v.isNotEmpty) {
      final parts = v
          .map((e) => e is Map
              ? _firstString(Map<String, dynamic>.from(e), [
                  'content',
                  'text',
                  'memory',
                  'summary',
                ])
              : _str(e))
          .whereType<String>()
          .toList();
      if (parts.isNotEmpty) {
        memory = parts.map((p) => '- $p').join('\n');
        break;
      }
    }
  }

  final persona = _asMap(root['persona']) ?? _asMap(root['profile']);
  final userName =
      _firstString(root, ['user_name', 'userName']) ??
      (persona == null ? null : _firstString(persona, ['name', 'user_name']));

  return ProviderChatTranscript(
    summary: summary,
    messages: messages,
    memory: memory,
    userName: userName,
    greetings: greetings,
  );
}

/// Reads a chat from the text of an exported file: SillyTavern-style JSONL,
/// a JSON document, or plain `Name: message` text.
ProviderChatTranscript parseProviderChatFile(
  String content, {
  required String fileName,
}) {
  final text = content.replaceFirst('\uFEFF', '').trim();
  final nameFromFile = fileName
      .replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '')
      .replaceAll(RegExp(r'[_]+'), ' ')
      .trim();
  var summary = ProviderChatSummary(
    site: ProviderChatSite.file,
    chatId: 'file:$fileName',
    characterName: nameFromFile.isEmpty ? 'Imported chat' : nameFromFile,
  );

  if (text.isEmpty) {
    return ProviderChatTranscript(summary: summary, messages: const []);
  }

  // JSONL (SillyTavern, Glaze export): one object per line.
  if (text.contains('\n') && text.trimLeft().startsWith('{')) {
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty);
    final objects = <Map<String, dynamic>>[];
    var allObjects = true;
    for (final line in lines) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map) {
          objects.add(Map<String, dynamic>.from(decoded));
        } else {
          allObjects = false;
          break;
        }
      } catch (_) {
        allObjects = false;
        break;
      }
    }
    if (allObjects && objects.isNotEmpty) {
      String? userName;
      String? characterName;
      final messages = <ProviderChatMessage>[];
      for (final obj in objects) {
        if (obj.containsKey('chat_metadata') && !obj.containsKey('mes')) {
          userName = _str(obj['user_name']);
          characterName = _str(obj['character_name']);
          continue;
        }
        final mes = _str(obj['mes']);
        if (mes == null) continue;
        if (obj['is_system'] == true && obj['is_user'] != true) continue;
        final swipes = obj['swipes'];
        messages.add(
          ProviderChatMessage(
            isUser: obj['is_user'] == true,
            text: mes,
            timestampMs: parseProviderTimestamp(obj['send_date']),
            name: _str(obj['name']),
            alternates: swipes is List
                ? swipes
                      .map((s) => _str(s))
                      .whereType<String>()
                      .where((s) => s != mes)
                      .toList()
                : const [],
          ),
        );
      }
      if (characterName != null) {
        summary = ProviderChatSummary(
          site: summary.site,
          chatId: summary.chatId,
          characterName: characterName,
        );
      }
      return ProviderChatTranscript(
        summary: summary,
        messages: messages,
        userName: userName,
      );
    }
  }

  // A single JSON document.
  if (text.startsWith('{') || text.startsWith('[')) {
    try {
      final decoded = jsonDecode(text);
      final parsed = parseProviderTranscript(decoded, summary: summary);
      if (parsed.messages.isNotEmpty) {
        final root = _asMap(decoded);
        final character = root == null ? null : _asMap(root['character']);
        final name = character == null
            ? (root == null
                  ? null
                  : _firstString(root, ['character_name', 'characterName']))
            : _firstString(character, ['name']);
        if (name == null) return parsed;
        return ProviderChatTranscript(
          summary: ProviderChatSummary(
            site: summary.site,
            chatId: summary.chatId,
            characterName: name,
          ),
          messages: parsed.messages,
          memory: parsed.memory,
          userName: parsed.userName,
          greetings: parsed.greetings,
        );
      }
    } catch (_) {}
  }

  // Plain text: "Name: message" blocks, a new block at every "Name:" line.
  final blocks = <(String, StringBuffer)>[];
  final header = RegExp(r'^\s*\**\[?([^\n:\[\]*]{1,40})\]?\**\s*:\s*(.*)$');
  for (final line in text.split('\n')) {
    final m = header.firstMatch(line);
    if (m != null) {
      blocks.add((m.group(1)!.trim(), StringBuffer(m.group(2)!)));
    } else if (blocks.isNotEmpty) {
      blocks.last.$2
        ..write('\n')
        ..write(line);
    }
  }
  if (blocks.length >= 2) {
    final names = <String>[];
    for (final b in blocks) {
      if (!names.contains(b.$1)) names.add(b.$1);
    }
    // The first speaker is the character, who opens the chat.
    final characterName = names.first;
    final messages = [
      for (final b in blocks)
        if (b.$2.toString().trim().isNotEmpty)
          ProviderChatMessage(
            isUser: b.$1 != characterName,
            text: b.$2.toString().trim(),
            name: b.$1,
          ),
    ];
    return ProviderChatTranscript(
      summary: ProviderChatSummary(
        site: summary.site,
        chatId: summary.chatId,
        characterName: characterName,
      ),
      messages: messages,
      userName: names.length > 1 ? names[1] : null,
    );
  }

  return ProviderChatTranscript(summary: summary, messages: const []);
}
