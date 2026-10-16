part of '../app_db.dart';

extension _AppDatabaseUpgradeV140 on AppDatabase {
  Future<void> _upgradeV140(Migrator m, int from) async {
    if (from >= 140) return;

    // "Trim Incompl. Sentences" lived only on the in-memory model, so it fell
    // back to off every time the presets were read back from the database.
    // Existing rows keep the old behaviour (off).
    await _ensureApiConfigTrimIncompleteColumn(m);
  }

  /// Guarded like v139: a restored backup can carry the column while its
  /// user_version lags.
  Future<void> _ensureApiConfigTrimIncompleteColumn(Migrator m) async {
    final columns = await customSelect(
      "PRAGMA table_info('api_configs')",
    ).get();
    final names = columns.map((column) => column.read<String>('name')).toSet();
    if (!names.contains(apiConfigs.trimIncompleteSentences.name)) {
      await m.addColumn(apiConfigs, apiConfigs.trimIncompleteSentences);
    }
  }
}
