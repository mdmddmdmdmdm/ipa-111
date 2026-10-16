import 'crushon_site_reader.dart';

/// Compatibility shim. The old in-page `fetch` proxy was replaced by
/// [CrushOnSiteReader], which drives the real site instead of guessing API
/// calls. The login sheet still calls [invalidate] after harvesting cookies so
/// the hidden browsers restart with the fresh session.
class CrushOnWebViewProxy {
  CrushOnWebViewProxy._();
  static final CrushOnWebViewProxy instance = CrushOnWebViewProxy._();

  Future<void> invalidate() => CrushOnSiteReader.instance.invalidate();

  Future<void> dispose() => CrushOnSiteReader.instance.invalidate();
}
