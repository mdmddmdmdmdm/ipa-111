import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/card_tag_chips.dart';
import '../../../shared/widgets/nsfw_blur.dart';
import '../../../core/utils/platform_paths.dart';
import '../catalog_models.dart';
import '../services/crushon_site_reader.dart' show CrushOnImageHints;
import '../third_party_providers_provider.dart';

class CatalogCard extends ConsumerStatefulWidget {
  final CatalogItem item;
  final VoidCallback onTap;
  final bool showSourceBadge;

  const CatalogCard({
    super.key,
    required this.item,
    required this.onTap,
    this.showSourceBadge = false,
  });

  @override
  ConsumerState<CatalogCard> createState() => _CatalogCardState();
}

class _CatalogCardState extends ConsumerState<CatalogCard> {
  bool _pressed = false;
  bool _hovered = false;

  CatalogItem get item => widget.item;

  @override
  Widget build(BuildContext context) {
    final scale = _pressed ? 0.96 : (_hovered ? 1.01 : 1.0);
    final dy = _hovered && !_pressed ? -4.0 : 0.0;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutBack,
          transform: Matrix4.identity()
            ..translateByDouble(0.0, dy, 0.0, 1.0)
            ..scaleByDouble(scale, scale, 1.0, 1.0),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            color: context.cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: _hovered ? 0.3 : 0.1,
                ),
                blurRadius: _hovered ? 24 : 6,
                offset: Offset(0, _hovered ? 12 : 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                AspectRatio(
                  // CrushOn: use the framing measured from the site's own
                  // cards (aspect, fit, focal point) so art is cropped the way
                  // the site crops it, not a guessed ratio.
                  aspectRatio:
                      item.source == 'crushon' ? CrushOnImageHints.aspect : 2 / 3,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRect(child: _buildImage()),
                      const _BottomFade(),
                      if (item.rank != null)
                        Positioned(
                          top: 8,
                          left: 8,
                          child: _RankBadge(
                            rank: item.rank!,
                            note: item.rankNote ?? '',
                          ),
                        ),
                      if (widget.showSourceBadge &&
                          item.source != null &&
                          item.source!.isNotEmpty)
                        Positioned(
                          // Below the rank badge when the card has one.
                          top: item.rank != null ? 36 : 8,
                          left: 8,
                          child: _SourceBadge(source: item.source!),
                        ),
                      if (item.messageCount > 0 || item.chatCount > 0)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: _MessageBadge(
                            count: item.messageCount > 0
                                ? item.messageCount
                                : item.chatCount,
                          ),
                        ),
                    ],
                  ),
                ),
                _CardInfo(item: item),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImage() {
    if (item.avatarUrl != null && item.avatarUrl!.isNotEmpty) {
      final blur =
          ref.watch(blurNsfwImagesProvider) && shouldBlurNsfwItem(item);
      final image = item.source == 'glaze'
          ? Image.file(
              File(resolveGlazeThumbnailPath(item.avatarUrl!) ?? item.avatarUrl!),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _buildPlaceholder(),
            )
          : CachedNetworkImage(
              filterQuality: FilterQuality.medium,
              imageUrl: item.avatarUrl!,
              // Referer needed for SpicyChat / CrushOn CDNs. GIF and WebP
              // avatar URLs animate when the platform decoder supports them.
              httpHeaders: item.source == 'spicychat'
                  ? const {'Referer': 'https://spicychat.ai/'}
                  : item.source == 'crushon'
                      ? const {'Referer': 'https://crushon.ai/'}
                      : null,
              fit: item.source == 'crushon' && CrushOnImageHints.contain
                  ? BoxFit.contain
                  : BoxFit.cover,
              alignment: item.source == 'crushon'
                  ? Alignment(CrushOnImageHints.alignX, CrushOnImageHints.alignY)
                  : Alignment.center,
              fadeInDuration: Duration.zero,
              fadeOutDuration: Duration.zero,
              placeholder: (_, _) => _buildPlaceholder(),
              errorWidget: (_, _, _) => _buildPlaceholder(),
            );
      return NsfwBlur(enabled: blur, child: image);
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return ColoredBox(
      color: context.cs.primary.withValues(alpha: 0.2),
      child: Center(
        child: Text(
          item.name.isNotEmpty ? item.name[0].toUpperCase() : '?',
          style: TextStyle(
            fontSize: 48,
            color: context.cs.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _BottomFade extends StatelessWidget {
  const _BottomFade();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        heightFactor: 0.5,
        widthFactor: 1.0,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                context.cs.surfaceContainerHighest,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CardInfo extends StatelessWidget {
  final CatalogItem item;

  const _CardInfo({required this.item});

  String _formatNumber(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}kk';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  String _stripHtml(String s) {
    return s.replaceAll(RegExp(r'<img[^>]*>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final desc = item.description != null && item.description!.isNotEmpty
        ? _stripHtml(item.description!)
        : '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              height: 1.2,
              color: Colors.white,
            ),
          ),
          if (item.creator != null && item.creator!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              '@${item.creator}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ),
          ],
          if (item.tokens > 0) ...[
            const SizedBox(height: 2),
            Text(
              '${_formatNumber(item.tokens)} tokens',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ],
          if (item.tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            CardTagChips(tags: item.tags),
          ],
          if (desc.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              desc,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  final String source;
  const _SourceBadge({required this.source});

  String _label() => switch (source.toLowerCase()) {
    'janitor' => 'JanitorAI',
    'janny' => 'Janny',
    'datacat' => 'DataCat',
    'chub' => 'Chub',
    'spicychat' => 'SpicyChat',
    'crushon' => 'CrushOn',
    'glaze' => 'Glaze',
    _ => source,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        _label(),
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Daily Ranking position, like the site's own badge: crown for the top 3, `#`
/// after that, then `Debut!` or the places gained (`↑3`) / lost (`↓2`).
class _RankBadge extends StatelessWidget {
  final int rank;
  final String note;

  const _RankBadge({required this.rank, required this.note});

  @override
  Widget build(BuildContext context) {
    final top3 = rank <= 3;
    final down = note.startsWith('\u2193');
    final noteColor = note.startsWith('Debut')
        ? const Color(0xFFFFE066)
        : (down ? const Color(0xFFFF8A8A) : const Color(0xFF7CF5D8));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFD81B8A).withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (top3)
            const Icon(Icons.emoji_events_rounded, size: 13, color: Colors.white)
          else
            const Text(
              '#',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white70,
              ),
            ),
          const SizedBox(width: 2),
          Text(
            '$rank',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          if (note.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(
              note,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: noteColor,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MessageBadge extends StatelessWidget {
  final int count;

  const _MessageBadge({required this.count});

  String _format(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}kk';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.mail_outline_rounded,
            size: 12,
            color: Colors.white70,
          ),
          const SizedBox(width: 4),
          Text(
            _format(count),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
