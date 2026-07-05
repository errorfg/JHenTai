import 'package:drift/drift.dart';
import 'package:jhentai/src/database/database.dart';

import '../table/local_config.dart' as table;

class LocalConfigDao {
  /// Upsert that only takes effect when the incoming row is strictly newer.
  /// The comparison runs inside SQLite (requires canonical fixed-width UTC
  /// timestamps so string comparison is chronological), which makes it atomic
  /// with respect to concurrent local writes - unlike a check-then-write in
  /// Dart, a row updated between the check and the write cannot be clobbered.
  static Future<void> batchUpsertIfNewer(List<LocalConfigCompanion> rows) async {
    if (rows.isEmpty) {
      return;
    }

    return appDb.batch((batch) {
      for (LocalConfigCompanion row in rows) {
        batch.insert(
          appDb.localConfig,
          row,
          onConflict: DoUpdate<table.LocalConfig, LocalConfigData>.withExcluded(
            (old, excluded) => LocalConfigCompanion(
              value: row.value,
              utime: row.utime,
            ),
            where: (old, excluded) => excluded.utime.isBiggerThan(old.utime),
          ),
        );
      }
    });
  }
}
