import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_sheet.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../chub_account_provider.dart';
import '../crushon_account_provider.dart';
import '../janitor_account_provider.dart';
import '../spicychat_account_provider.dart';
import 'provider_chat_models.dart';
import 'provider_chat_parsers.dart';
import 'provider_chat_viewer_sheet.dart';
import 'provider_chats_provider.dart';
import 'provider_chats_service.dart';

/// The "Provider Characters" tab: every character the signed-in accounts have
/// chatted with, across JanitorAI, SpicyChat, Chub and CrushOn (or one site at
/// a time). A chat opens read-only; from there it can be exported or imported
/// into the app at the exact point it stopped.
class ProviderCharactersTab extends ConsumerStatefulWidget {
  const ProviderCharactersTab({
    super.key,
    required this.topPadding,
    required this.bottomPadding,
    this.query = '',
  });

  final double topPadding;
  final double bottomPadding;

  /// The header search text; filters the list by name or last message.
  final String query;

  @override
  ConsumerState<ProviderCharactersTab> createState() =>
      _ProviderCharactersTabState();
}

class _ProviderCharactersTabState extends ConsumerState<ProviderCharactersTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(providerChatsProvider);
      if (!state.loaded && !state.loading) {
        ref.read(providerChatsProvider.notifier).refresh();
      }
    });
  }

  void _refresh() => ref.read(providerChatsProvider.notifier).refresh();

  Future<void> _open(ProviderChatSummary summary) async {
    final route = await showGlazeSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ProviderChatViewerSheet(summary: summary),
    );
    if (route != null && mounted) context.go(route);
  }

  Future<void> _openFile() async {
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jsonl', 'json', 'txt'],
        withData: true,
      );
      final file = picked?.files.single;
      if (file == null) return;
      final bytes = file.bytes;
      if (bytes == null) return;
      final transcript = parseProviderChatFile(
        const Utf8Decoder(allowMalformed: true).convert(bytes),
        fileName: file.name,
      );
      if (!mounted) return;
      if (transcript.messages.isEmpty) {
        GlazeToast.show(context, 'provider_chats_file_empty'.tr());
        return;
      }
      final route = await showGlazeSheet<String>(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        backgroundColor: Colors.transparent,
        builder: (_) => ProviderChatViewerSheet(preloaded: transcript),
      );
      if (route != null && mounted) context.go(route);
    } catch (e) {
      if (mounted) GlazeErrorDialog.show(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    // A sign-in or sign-out changes which sites can be read: read again.
    ref.listen(janitorAccountProvider, (_, _) => _refresh());
    ref.listen(spicyChatAccountProvider, (_, _) => _refresh());
    ref.listen(chubAccountProvider, (_, _) => _refresh());
    ref.listen(crushOnAccountProvider, (_, _) => _refresh());

    final state = ref.watch(providerChatsProvider);
    final service = ref.read(providerChatsServiceProvider);
    final signedIn = service.signedInSites().toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    final q = widget.query.trim().toLowerCase();
    final rows = state.visible.where((c) {
      if (q.isEmpty) return true;
      return c.characterName.toLowerCase().contains(q) ||
          (c.lastMessage ?? '').toLowerCase().contains(q);
    }).toList();

    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        widget.topPadding,
        16,
        widget.bottomPadding,
      ),
      children: [
        Text(
          'provider_chats_read_only'.tr(),
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
        ),
        const SizedBox(height: 10),
        if (signedIn.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _chip(
                  label: 'provider_chats_all'.tr(),
                  selected: state.filter == null,
                  onTap: () =>
                      ref.read(providerChatsProvider.notifier).setFilter(null),
                ),
                for (final site in signedIn)
                  _chip(
                    label: _siteLabel(service, site),
                    selected: state.filter == site,
                    onTap: () => ref
                        .read(providerChatsProvider.notifier)
                        .setFilter(site),
                  ),
              ],
            ),
          ),
        Row(
          children: [
            TextButton.icon(
              onPressed: state.loading ? null : _refresh,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text('provider_chats_refresh'.tr()),
            ),
            TextButton.icon(
              onPressed: _openFile,
              icon: const Icon(Icons.file_open_outlined, size: 18),
              label: Text('provider_chats_open_file'.tr()),
            ),
          ],
        ),
        if (state.loading && state.chats.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: GlazeSpinner()),
          ),
        for (final entry in state.problems.entries)
          if (state.filter == null || state.filter == entry.key)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.errorContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                '${entry.key.label}: ${entry.value}',
                style: TextStyle(color: cs.onSurface, fontSize: 12),
              ),
            ),
        if (signedIn.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Text(
              'provider_chats_signed_out'.tr(),
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          )
        else if (state.loaded && rows.isEmpty && state.problems.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Text(
              'provider_chats_empty'.tr(),
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
        for (final chat in rows) _ChatRow(chat: chat, onTap: () => _open(chat)),
      ],
    );
  }

  String _siteLabel(ProviderChatsService service, ProviderChatSite site) {
    final account = service.accountName(site);
    return account == null || account.isEmpty
        ? site.label
        : '${site.label} · $account';
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({required this.chat, required this.onTap});

  final ProviderChatSummary chat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final avatar = chat.avatarUrl;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                ClipOval(
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: avatar == null || avatar.isEmpty
                        ? Icon(Icons.person_rounded, color: cs.onSurfaceVariant)
                        : Image.network(
                            avatar,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Icon(
                              Icons.person_rounded,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chat.characterName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                      if ((chat.lastMessage ?? '').isNotEmpty)
                        Text(
                          chat.lastMessage!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      chat.site.label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: cs.primary,
                      ),
                    ),
                    if (chat.messageCount != null)
                      Text(
                        'provider_chats_messages'.tr(
                          namedArgs: {'n': '${chat.messageCount}'},
                        ),
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
