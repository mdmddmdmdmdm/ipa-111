import 'dart:io';
import 'package:path/path.dart' as p;
// Pinned via dependency_overrides to keep Windows builds green; see docs/BUILD_NOTES.md.
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';

import '../constants/build_channel.dart';

/// Cached Glaze data root, populated on the first [getAppDataDir] call (which
/// happens at startup via ImageStorageService.create / AppDatabase open).
/// Used by [resolveGlazeFilePath] so widgets can rebase stale absolute paths
/// without an async lookup.
String? _cachedAppDataDir;

String? get cachedAppDataDir => _cachedAppDataDir;

Future<String> getAppDataDir() async {
  if (Platform.isAndroid || Platform.isIOS) {
    final dir = await getApplicationDocumentsDirectory();
    final base = p.join(dir.path, 'Glaze');
    _cachedAppDataDir = base;
    return base;
  }
  final base = _desktopDataDir();
  _cachedAppDataDir = base;
  return base;
}

/// Resolves a stored avatar/gallery/etc. path for display.
///
/// iOS changes the app sandbox container UUID on every reinstall/OS update, so
/// absolute paths persisted by an older build (e.g.
/// `.../Application/<OLD_UUID>/Documents/Glaze/avatars/x.png`) stop existing
/// even though the files survive under the *new* container. This rebases any
/// absolute path that lives under a `Glaze` data root onto the current
/// [cachedAppDataDir]. Relative paths are joined onto the current base. When no
/// base is cached yet (very early startup) the input is returned unchanged.
String? resolveGlazeFilePath(String? path) {
  if (path == null || path.isEmpty) return path;
  // A stored path can also be a URL (`data:`, `https:`) — a catalog card whose
  // picture was never downloaded. It is not absolute, so without this it would
  // be joined onto the data root and come back as a path no file lives at.
  // [relativeGlazeFilePath], this function's inverse, has always left URLs
  // alone; this is the other half of that symmetry.
  if (_urlSchemeRegex.hasMatch(path)) return path;
  final base = _cachedAppDataDir;
  if (base == null) return path;

  if (!p.isAbsolute(path)) {
    return p.joinAll([base, ...path.split(RegExp(r'[/\\]'))]);
  }
  // Absolute: first prefer the matching file in this build channel's data
  // root. A copied/imported database can still contain paths from another
  // installed channel, whose source files may also continue to exist.
  final normalized = path.replaceAll('\\', '/');
  // Desktop channels use sibling roots. Match all of them so a copied DB can
  // move in either direction: stable <-> staging <-> nightly.
  final match = RegExp(
    r'/(?:Glaze|Glaze-staging|Glaze-nightly)/',
    caseSensitive: false,
  ).allMatches(normalized).lastOrNull;
  if (match != null) {
    final suffix = normalized.substring(match.end);
    if (suffix.isNotEmpty) {
      final rebased = p.join(base, suffix);
      if (File(rebased).existsSync()) return rebased;
    }
  }
  if (File(path).existsSync()) return path;
  return path;
}

/// [path] spelled relative to the Glaze data root when it lives inside it.
///
/// The inverse of [resolveGlazeFilePath], and the spelling every image path is
/// stored in: a relative path survives the data root moving under it — a new
/// iOS container UUID, a database copied between the desktop build channels —
/// where an absolute one silently stops pointing at a file. Paths outside the
/// data root (and anything that is already relative, or a URL) come back
/// unchanged.
String relativeGlazeFilePath(String path) {
  if (path.isEmpty) return path;
  if (_urlSchemeRegex.hasMatch(path)) return path;
  final normalized = path.replaceAll('\\', '/');
  if (!p.isAbsolute(path)) return normalized;

  final base = _cachedAppDataDir;
  if (base != null) {
    final relative = p.relative(path, from: base);
    if (!p.isAbsolute(relative) && !relative.startsWith('..')) {
      return relative.replaceAll('\\', '/');
    }
  }
  // No base cached yet (very early startup), or the file belongs to another
  // installed build channel: the data-root name still tells us where it sat,
  // and [resolveGlazeFilePath] rebases that suffix onto the current root.
  final match = RegExp(
    r'/(?:Glaze|Glaze-staging|Glaze-nightly)/',
    caseSensitive: false,
  ).allMatches(normalized).lastOrNull;
  if (match != null) {
    final suffix = normalized.substring(match.end);
    if (suffix.isNotEmpty) return suffix;
  }
  return path;
}

/// A URL scheme, which a stored image path can also be (`data:`, `https:`).
/// Two characters minimum, so a Windows drive letter is not read as one.
final RegExp _urlSchemeRegex = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]+:');

/// Extensions a generated list/card thumbnail can carry, most-preferred first.
///
/// Transparent portraits are stored as PNG so their cut-out survives; opaque
/// art stays a smaller JPEG. Both are valid on disk, so path resolution checks
/// them in this order.
const List<String> kThumbnailExtensions = ['png', 'jpg', 'gif'];

/// Image extensions an avatar file may carry on disk, most likely first.
///
/// Avatars are stored as `<id>.png` regardless of the picked format, but cloud
/// sync and older builds wrote `<id>.jpg` / `.webp` / ... under the same id.
const List<String> _kAvatarSiblingExtensions = [
  'png',
  'jpg',
  'jpeg',
  'webp',
  'gif',
];

/// Resolves an avatar path **for display** and repairs it when the full-size
/// file has gone missing.
///
/// This is [resolveGlazeFilePath] plus two recoveries, so a picture never
/// silently turns into "Couldn't load the image" while its data is still on
/// disk:
///
///  1. The same id under another extension (`avatars/<id>.jpg` etc.).
///  2. The generated thumbnail (`thumbnails/<id>.png|jpg`). When that is all
///     that is left, it is copied back to `avatars/<id>.png` so every other
///     screen (detail hero, full-screen viewer, chat header) works again.
///
/// Returns the plain resolved path when nothing can be recovered, so callers
/// keep their existing error/placeholder behaviour.
String? resolveGlazeDisplayPath(String? path) {
  final resolved = resolveGlazeFilePath(path);
  if (resolved == null || resolved.isEmpty) return resolved;
  if (_urlSchemeRegex.hasMatch(resolved)) return resolved;
  try {
    final file = File(resolved);
    if (file.existsSync() && file.lengthSync() > 0) return resolved;

    final dir = p.dirname(resolved);
    final name = p.basenameWithoutExtension(resolved);

    // 1. Same id, different extension.
    for (final ext in _kAvatarSiblingExtensions) {
      final sibling = File(p.join(dir, '$name.$ext'));
      if (sibling.path != resolved &&
          sibling.existsSync() &&
          sibling.lengthSync() > 0) {
        return sibling.path;
      }
    }

    // 2. Restore from the thumbnail (only meaningful for `avatars/<id>.*`).
    if (p.basename(dir).toLowerCase() == 'avatars') {
      final root = p.dirname(dir);
      for (final ext in kThumbnailExtensions) {
        final thumb = File(p.join(root, 'thumbnails', '$name.$ext'));
        if (thumb.existsSync() && thumb.lengthSync() > 0) {
          try {
            // The avatar is expected at `<id>.png`; restore it there.
            if (!file.parent.existsSync()) {
              file.parent.createSync(recursive: true);
            }
            thumb.copySync(resolved);
            return resolved;
          } catch (_) {
            // Read-only or full disk: still show the thumbnail.
            return thumb.path;
          }
        }
      }
    }
  } catch (_) {
    // Never let a display lookup throw.
  }
  return resolved;
}

/// Returns the on-disk path to the generated list/card thumbnail for a stored
/// avatar path when one exists, otherwise the resolved full-resolution avatar
/// path (or `null` when there is no avatar).
///
/// Lists (character grid, folder cards, chat history) should prefer this over
/// [resolveGlazeFilePath] so that scrolling decodes small JPG/PNG thumbnails
/// instead of the multi-megabyte source PNGs — the latter causes visible jank
/// and delayed "pop-in" the first time each card scrolls into view.
String? resolveGlazeThumbnailPath(String? avatarPath) {
  final resolved = resolveGlazeFilePath(avatarPath);
  if (resolved == null || resolved.isEmpty) return resolved;
  final name = p.basenameWithoutExtension(resolved);
  // avatars/<id>.png -> <base>/thumbnails/<id>.png (transparent) or .jpg
  final base = p.dirname(p.dirname(resolved));
  for (final ext in kThumbnailExtensions) {
    final thumb = p.join(base, 'thumbnails', '$name.$ext');
    if (File(thumb).existsSync()) return thumb;
  }
  // No thumbnail: fall back to the full image, repairing it if it went missing.
  return resolveGlazeDisplayPath(avatarPath);
}

String _desktopDataDir() {
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA']!;
    return p.join(appData, glazeDataFolderName);
  } else if (Platform.isLinux) {
    final xdg =
        Platform.environment['XDG_DATA_HOME'] ??
        p.join(Platform.environment['HOME']!, '.local', 'share');
    return p.join(xdg, glazeDataFolderName);
  } else if (Platform.isMacOS) {
    return p.join(
      Platform.environment['HOME']!,
      'Library',
      'Application Support',
      glazeDataFolderName,
    );
  }
  throw UnsupportedError('Platform not supported yet');
}
