import 'dart:isolate';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;

import '../db/app_db.dart';
import 'image_storage_service.dart' show resizeAvatarBytes;

/// A second copy of every avatar, kept **inside the SQLite database**.
///
/// Avatars normally live as loose files (`Glaze/avatars/<id>.png` plus a
/// thumbnail). On iOS those files can disappear or become unreachable while
/// the database row that points at them survives — the character is still
/// there but its picture shows "Couldn't load the image". The database file is
/// the one thing that provably survives, so the picture bytes are mirrored
/// into it and the files are rebuilt from there whenever they are missing.
///
/// Everything here is best-effort and never throws: a failed vault write must
/// not stop an avatar from being saved.
class AvatarVault {
  AvatarVault(this._db);

  final AppDatabase _db;
  Future<void>? _ready;

  /// Above this size the stored copy is downscaled (the on-disk file is never
  /// touched), so a library full of large cards does not bloat the database.
  static const int _kDownscaleAbove = 1500000;
  static const int _kDownscaleShortSide = 1600;

  /// Hard ceiling for one stored copy.
  static const int _kMaxStoredBytes = 6000000;

  Future<void> _ensureTable() {
    return _ready ??= _db.customStatement(
      'CREATE TABLE IF NOT EXISTS avatar_vault ('
      'owner_id TEXT PRIMARY KEY NOT NULL, '
      'bytes BLOB NOT NULL, '
      'updated_at INTEGER NOT NULL)',
    );
  }

  /// Mirrors [bytes] under [ownerId] (a character / persona id).
  Future<void> store(String ownerId, Uint8List bytes) async {
    if (ownerId.isEmpty || bytes.isEmpty) return;
    try {
      var toStore = bytes;
      if (toStore.length > _kDownscaleAbove) {
        final scaled = await Isolate.run(
          () => resizeAvatarBytes(bytes, _kDownscaleShortSide),
        );
        if (scaled != null && scaled.bytes.length < toStore.length) {
          toStore = scaled.bytes;
        }
      }
      if (toStore.length > _kMaxStoredBytes) return;
      await _ensureTable();
      await _db.customStatement(
        'INSERT OR REPLACE INTO avatar_vault (owner_id, bytes, updated_at) '
        'VALUES (?, ?, ?)',
        [ownerId, toStore, DateTime.now().millisecondsSinceEpoch ~/ 1000],
      );
    } catch (_) {
      _ready = null;
    }
  }

  /// True when a copy exists for [ownerId].
  Future<bool> has(String ownerId) async {
    try {
      await _ensureTable();
      final rows = await _db
          .customSelect(
            'SELECT 1 AS present FROM avatar_vault WHERE owner_id = ? LIMIT 1',
            variables: [Variable.withString(ownerId)],
          )
          .get();
      return rows.isNotEmpty;
    } catch (_) {
      _ready = null;
      return false;
    }
  }

  /// The stored bytes for [ownerId], or null when there are none.
  Future<Uint8List?> load(String ownerId) async {
    try {
      await _ensureTable();
      final rows = await _db
          .customSelect(
            'SELECT bytes FROM avatar_vault WHERE owner_id = ? LIMIT 1',
            variables: [Variable.withString(ownerId)],
          )
          .get();
      if (rows.isEmpty) return null;
      final value = rows.first.data['bytes'];
      if (value is Uint8List) return value.isEmpty ? null : value;
      if (value is List<int>) {
        return value.isEmpty ? null : Uint8List.fromList(value);
      }
    } catch (_) {
      _ready = null;
    }
    return null;
  }

  Future<void> remove(String ownerId) async {
    try {
      await _ensureTable();
      await _db.customStatement(
        'DELETE FROM avatar_vault WHERE owner_id = ?',
        [ownerId],
      );
    } catch (_) {
      _ready = null;
    }
  }
}
