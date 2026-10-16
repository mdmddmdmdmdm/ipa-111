import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../../../core/services/file_export_service.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/sheet_view.dart';
import 'provider_chat_importer.dart';
import 'provider_chat_models.dart';
import 'provider_chats_service.dart';

/// A provider chat, read-only: the whole conversation, the provider's memory
/// of it, Export, and "Import & continue". There is no composer here — nothing
/// is ever sent to the provider from this sheet.
///
/// Pops with the chat route (`/chat/<id>?session=<n>`) after an import so the
/// caller can open the chat.
class ProviderChatViewerSheet extends ConsumerStatefulWidget {
  const ProviderChatViewerSheet({super.key, this.summary, this.preloaded})
    : assert(summary != null || preloaded != null);

  final ProviderChatSummary? summary;

  /// A chat already read (opened from an exported file).
  final ProviderChatTranscript? preloaded;

  @override
  ConsumerState<ProviderChatViewerSheet> createState() =>
      _ProviderChatViewerSheetState();
}

class _ProviderChatViewerSheetState
    extends ConsumerState<ProviderChatViewerSheet> {
  ProviderChatTranscript? _transcript;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _transcript = widget.preloaded;
    if (_transcript == null) _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final t = await ref
          .read(providerChatsServiceProvider)
          .loadTranscript(widget.summary!);
      if (!mounted) return;
      setState(() => _transcript = t);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _export() async {
    final t = _transcript;
    if (t == null || _busy) return;
    setState(() => _busy = true);
    try {
      final dir = await getTemporaryDirectory();
      final safe = t.summary.characterName.replaceAll(
        RegExp(r'[\\/:*?"<>|]'),
        '_',
      );
      final filename = '$safe - ${t.summary.site.label}.jsonl';
      final path = p.join(dir.path, filename);
      await File(path).writeAsString(buildProviderChatJsonl(t));
      final saved = await FileExportService.exportFile(
        sourcePath: path,
        filename: filename,
        subfolder: 'chats',
      );
      if (mounted && saved.isNotEmpty) {
        GlazeToast.show(context, 'Chat exported to $saved');
      }
    } catch (e) {
      if (mounted) {
        GlazeErrorDialog.show(
          context,
          e,
          prefix: 'error_export_failed_prefix'.tr(),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final t = _transcript;
    if (t == null || _busy) return;
    setState(() => _busy = true);
    try {
      final route = await importProviderChat(context, ref, t);
      if (route != null && mounted) {
        Navigator.of(context, rootNavigator: true).pop(route);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _transcript;
    final name = t?.summary.characterName ?? widget.summary?.characterName ?? '';
    return SheetView(
      startExpanded: true,
      titleWidget: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: context.cs.onSurface,
        ),
      ),
      actions: [
        if (t != null)
          SheetViewAction(
            icon: const Icon(Icons.ios_share_rounded),
            tooltip: 'provider_chats_export'.tr(),
            onPressed: _export,
          ),
      ],
      body: Builder(builder: (context) => _body(context, t)),
      floating: t == null || t.messages.isEmpty
          ? null
          : Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom + 12,
              ),
              child: FilledButton.icon(
                onPressed: _busy ? null : _import,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text('provider_chats_import'.tr()),
              ),
            ),
    );
  }

  Widget _body(BuildContext context, ProviderChatTranscript? t) {
    final top = MediaQuery.paddingOf(context).top + 12;
    final bottom = MediaQuery.paddingOf(context).bottom + 96;
    if (_error != null) {
      return ListView(
        padding: EdgeInsets.fromLTRB(16, top, 16, bottom),
        children: [
          SelectableText(
            _error!,
            style: TextStyle(color: context.cs.error, fontSize: 13),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _load, child: Text('action_retry'.tr())),
        ],
      );
    }
    if (t == null) {
      return const Center(child: GlazeSpinner());
    }
    final cs = context.cs;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, top, 16, bottom),
      children: [
        Text(
          'provider_chats_read_only'.tr(),
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
        ),
        if (t.memory != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'provider_chats_memory'.tr(
                    namedArgs: {'provider': t.summary.site.label},
                  ),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  t.memory!,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        for (final m in t.messages) _Bubble(message: m, characterName: name(t)),
      ],
    );
  }

  String name(ProviderChatTranscript t) => t.summary.characterName;
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.characterName});

  final ProviderChatMessage message;
  final String characterName;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final isUser = message.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.86,
        ),
        decoration: BoxDecoration(
          color: isUser ? cs.primary.withValues(alpha: 0.22) : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isUser ? (message.name ?? 'You') : characterName,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              message.text,
              style: TextStyle(color: cs.onSurface, fontSize: 14.5, height: 1.4),
            ),
            if (message.alternates.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '+${message.alternates.length} swipes',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
