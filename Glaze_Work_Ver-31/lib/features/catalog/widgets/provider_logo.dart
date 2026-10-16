import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../catalog_models.dart';
import '../third_party_providers_provider.dart';

/// Bundled brand mark for each content source, kept in the service's own
/// colours (raster where the source only publishes one, vector where it does).
const Map<ThirdPartyProvider, String> _providerLogoAssets = {
  ThirdPartyProvider.janitor: 'assets/logos/providers/janitor.png',
  ThirdPartyProvider.janny: 'assets/logos/providers/janny.png',
  ThirdPartyProvider.datacat: 'assets/logos/providers/datacat.png',
  ThirdPartyProvider.chub: 'assets/logos/providers/chub.png',
  ThirdPartyProvider.saucepan: 'assets/logos/providers/saucepan.svg',
};

/// The source's real logo glyph, so it can stand in wherever the app used a
/// placeholder material icon.
class ProviderLogo extends StatelessWidget {
  final ThirdPartyProvider provider;
  final double size;
  final bool _allProviders;

  const ProviderLogo({super.key, required this.provider, this.size = 18}) : _allProviders = false;

  ProviderLogo.catalog({
    super.key,
    required CatalogProvider provider,
    this.size = 18,
  }) : provider = provider.thirdPartyProvider ?? ThirdPartyProvider.janitor,
       _allProviders = provider == CatalogProvider.all;

  @override
  Widget build(BuildContext context) {
    if (_allProviders) {
      return Icon(Icons.apps_rounded, size: size);
    }
    if (provider == ThirdPartyProvider.spicychat) {
      return Icon(Icons.local_fire_department_rounded, size: size);
    }
    if (provider == ThirdPartyProvider.crushon) {
      // No bundled logo yet — letter mark matches the in-app "C" style.
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Text(
            'C',
            style: TextStyle(
              fontSize: size * 0.85,
              fontWeight: FontWeight.w800,
              height: 1,
              color: const Color(0xFFE91E8C),
            ),
          ),
        ),
      );
    }
    final asset = _providerLogoAssets[provider];
    if (asset == null) {
      return SizedBox(width: size, height: size);
    }
    if (asset.endsWith('.svg')) {
      return SvgPicture.asset(asset, width: size, height: size);
    }
    // High-quality filtering: the bundled marks are 180-500 px and are drawn
    // at 18-40 logical px, where the default (low) filter looks jagged.
    return Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      isAntiAlias: true,
    );
  }
}
