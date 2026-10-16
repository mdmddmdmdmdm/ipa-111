import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/character.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/services/chat_import_export.dart';
import '../../../core/state/character_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../chat/chat_actions_service.dart';
import '../catalog_models.dart';
import '../widgets/catalog_detail_launcher.dart';
import 'provider_chat_models.dart';

/// The chat as the app stores it: provider messages in order, each reply
/// carrying its alternates as swipes, so the story is exactly where it was.
List<ChatMessage> buildImportMessages(ProviderChatTranscript t) {
  final base = DateTime.now().millisecondsSinceEpoch - t.messages.length * 1000;
  final out = <ChatMessage>[];
  for (var i = 0; i < t.messages.length; i++) {
    final m = t.messages[i];
    final text = m.text.trim();
    if (text.isEmpty) continue;
    final hasSwipes = !m.isUser && m.alternates.isNotEmpty;
    out.add(
      ChatMessage(
        id: 'prov_${base}_$i',
        role: m.isUser ? 'user' : 'assistant',
        content: text,
        timestamp: m.timestampMs ?? base + i * 1000,
        personaName: m.isUser ? (t.userName ?? m.name) : null,
        swipes: hasSwipes ? [text, ...m.alternates] : const [],
        swipeId: 0,
      ),
    );
  }
  return out;
}

/// The chat as a SillyTavern-style `.jsonl`, which the app, SillyTavern and
/// most front ends can import.
String buildProviderChatJsonl(ProviderChatTranscript t, {String? userName}) {
  String date(int? ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(
      ms ?? DateTime.now().millisecondsSinceEpoch,
    );
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  final user = (userName ?? t.userName ?? 'User').trim();
  final lines = <String>[
    jsonEncode({
      'user_name': user.isEmpty ? 'User' : user,
      'character_name': t.summary.characterName,
      'create_date': date(null),
      'chat_metadata': {
        'exported_from': 'Glaze (${t.summary.site.label})',
        if (t.memory != null) 'memory': t.memory,
      },
    }),
  ];
  for (final m in t.messages) {
    lines.add(
      jsonEncode({
        'name': m.isUser ? (user.isEmpty ? 'User' : user) : t.summary.characterName,
        'is_user': m.isUser,
        'is_system': false,
        'send_date': date(m.timestampMs),
        'mes': m.text,
        if (!m.isUser && m.alternates.isNotEmpty) ...{
          'swipe_id': 0,
          'swipes': [m.text, ...m.alternates],
        },
        'extra': <String, dynamic>{},
      }),
    );
  }
  return lines.join('\n');
}

CatalogProvider? _catalogProviderFor(ProviderChatSite site) => switch (site) {
  ProviderChatSite.janitor => CatalogProvider.janitor,
  ProviderChatSite.spicychat => CatalogProvider.spicychat,
  ProviderChatSite.chub => CatalogProvider.chub,
  ProviderChatSite.crushon => CatalogProvider.crushon,
  ProviderChatSite.file => null,
};

String _norm(String s) => s.trim().toLowerCase();

/// A character already in the library that this chat belongs to. `byUrl` is a
/// sure match (the card was imported from this very page); `byName` is only a
/// likely one and is confirmed with the user.
({Character? byUrl, Character? byName}) _findLocal(
  List<Character> all,
  ProviderChatSummary s,
) {
  Character? byUrl;
  Character? byName;
  final id = s.characterId;
  for (final c in all) {
    final url = (c.extensions['catalogUrl'] ?? '').toString();
    if (id != null && id.length >= 6 && url.contains(id)) {
      byUrl ??= c;
    }
    if (_norm(c.name) == _norm(s.characterName) ||
        _norm(c.displayName ?? '') == _norm(s.characterName)) {
      byName ??= c;
    }
  }
  return (byUrl: byUrl, byName: byName);
}

/// Brings a provider chat into the app, at the exact message it stopped at,
/// with the provider's memory attached as the chat summary. Returns the chat
/// route to open, or null when the user backed out or it failed (the user has
/// already been told why).
Future<String?> importProviderChat(
  BuildContext context,
  WidgetRef ref,
  ProviderChatTranscript transcript,
) async {
  try {
    final messages = buildImportMessages(transcript);
    if (messages.isEmpty) {
      GlazeToast.show(context, 'no_results'.tr());
      return null;
    }

    final all = await ref.read(charactersProvider.future);
    if (!context.mounted) return null;
    final found = _findLocal(all, transcript.summary);

    String? charId = found.byUrl?.id;

    if (charId == null && found.byName != null) {
      final useExisting = await _confirmExisting(context, found.byName!);
      if (!context.mounted) return null;
      if (useExisting == null) return null;
      if (useExisting) charId = found.byName!.id;
    }

    if (charId == null) {
      final provider = _catalogProviderFor(transcript.summary.site);
      final remoteId = transcript.summary.characterId;
      if (provider != null && remoteId != null && remoteId.isNotEmpty) {
        // The normal character import: preview, then Import. It hands back the
        // id of the character it created.
        final item = CatalogItem(
          id: remoteId,
          name: transcript.summary.characterName,
          avatarUrl: transcript.summary.avatarUrl,
          source: transcript.summary.site.key,
          fullPath: provider == CatalogProvider.chub ? remoteId : null,
        );
        charId = await showGlazeSheet<String>(
          context: context,
          isScrollControlled: true,
          useRootNavigator: true,
          backgroundColor: Colors.transparent,
          builder: (_) => CatalogDetailLauncher(item: item, provider: provider),
        );
        if (!context.mounted) return null;
      } else {
        // An exported file carries no card: pick one from the library.
        charId = await _pickCharacter(context, all, transcript.summary);
        if (!context.mounted) return null;
      }
    }
    if (charId == null || charId.isEmpty) return null;

    final memory = transcript.memory?.trim();
    final result = await ref
        .read(chatActionsServiceProvider)
        .importChatFromResult(
          charId,
          ChatImportResult(messages: messages, userName: transcript.userName),
          summary: (memory == null || memory.isEmpty)
              ? null
              : ChatSummary(content: memory),
        );
    if (result.count == 0 || result.sessionIndex == null) {
      if (context.mounted) GlazeToast.show(context, 'no_results'.tr());
      return null;
    }
    if (context.mounted) {
      GlazeToast.show(
        context,
        (memory == null || memory.isEmpty)
            ? 'provider_chats_imported'.tr()
            : '${'provider_chats_imported'.tr()} '
                  '${'provider_chats_memory_carried'.tr()}',
      );
    }
    return '/chat/$charId?session=${result.sessionIndex}';
  } catch (e) {
    if (context.mounted) {
      GlazeErrorDialog.show(context, e, prefix: 'error_import_failed_prefix'.tr());
    }
    return null;
  }
}

Future<bool?> _confirmExisting(BuildContext context, Character existing) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(
        'provider_chats_use_existing'.tr(namedArgs: {'name': existing.name}),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('provider_chats_import_card'.tr()),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text('provider_chats_use_existing_yes'.tr()),
        ),
      ],
    ),
  );
}

Future<String?> _pickCharacter(
  BuildContext context,
  List<Character> all,
  ProviderChatSummary summary,
) {
  return showGlazeSheet<String>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CharacterPickerSheet(all: all, guess: summary.characterName),
  );
}

class _CharacterPickerSheet extends StatefulWidget {
  const _CharacterPickerSheet({required this.all, required this.guess});

  final List<Character> all;
  final String guess;

  @override
  State<_CharacterPickerSheet> createState() => _CharacterPickerSheetState();
}

class _CharacterPickerSheetState extends State<_CharacterPickerSheet> {
  late final TextEditingController _search = TextEditingController(
    text: widget.guess,
  );

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _norm(_search.text);
    final shown = widget.all
        .where((c) => q.isEmpty || _norm(c.name).contains(q))
        .toList();
    return SheetView(
      titleWidget: Text(
        'provider_chats_pick_character'.tr(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: context.cs.onSurface,
        ),
      ),
      body: Builder(
        builder: (context) => ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.paddingOf(context).top + 12,
            16,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: [
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'search_characters'.tr(),
                prefixIcon: const Icon(Icons.search_rounded),
              ),
            ),
            const SizedBox(height: 8),
            for (final c in shown)
              ListTile(
                title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.of(context, rootNavigator: true).pop(c.id),
              ),
          ],
        ),
      ),
    );
  }
}
