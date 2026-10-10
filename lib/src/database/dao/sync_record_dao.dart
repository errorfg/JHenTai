import 'package:drift/drift.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/extension/list_extension.dart';

class SyncRecordDao {
  static Future<List<SyncRecordData>> selectByKind(String kind) {
    return (appDb.select(appDb.syncRecord)..where((r) => r.kind.equals(kind))).get();
  }

  static Future<Map<String, SyncRecordData>> selectByKeys(String kind, Iterable<String> keys) async {
    Map<String, SyncRecordData> result = {};
    for (List<String> partition in keys.toSet().toList().partition(500)) {
      List<SyncRecordData> rows =
          await (appDb.select(appDb.syncRecord)..where((r) => r.kind.equals(kind) & r.key.isIn(partition))).get();
      for (SyncRecordData row in rows) {
        result[row.key] = row;
      }
    }
    return result;
  }

  static Future<bool> existsKind(String kind) async {
    SyncRecordData? row =
        await (appDb.select(appDb.syncRecord)..where((r) => r.kind.equals(kind))..limit(1)).getSingleOrNull();
    return row != null;
  }

  static Future<List<SyncRecordData>> selectDirty(int limit) {
    return (appDb.select(appDb.syncRecord)
          ..where((r) => r.dirty.equals(true))
          ..orderBy([(r) => OrderingTerm(expression: r.kind), (r) => OrderingTerm(expression: r.key)])
          ..limit(limit))
        .get();
  }

  static Future<Set<String>> selectApplyPendingKinds() async {
    final query = appDb.selectOnly(appDb.syncRecord, distinct: true)
      ..addColumns([appDb.syncRecord.kind])
      ..where(appDb.syncRecord.applyPending.equals(true));
    return (await query.get()).map((row) => row.read(appDb.syncRecord.kind)!).toSet();
  }

  static Future<List<SyncRecordData>> selectApplyPending(String kind) {
    return (appDb.select(appDb.syncRecord)..where((r) => r.kind.equals(kind) & r.applyPending.equals(true))).get();
  }

  /// Upserts [rows] whole. Companions keep their nulls: a data class would
  /// drop them from the update and leave the old value of a column cleared
  /// on purpose (the value of a deletion, a hash no longer valid).
  static Future<void> write(Iterable<SyncRecordData> rows) async {
    if (rows.isEmpty) {
      return;
    }
    await appDb.batch(
      (batch) => batch.insertAllOnConflictUpdate(appDb.syncRecord, rows.map((r) => r.toCompanion(false)).toList()),
    );
  }

  /// Clears [dirty] of [rows] that are still the versions given: a row
  /// changed again meanwhile stays dirty.
  static Future<void> clearDirty(List<SyncRecordData> rows) {
    return _clearFlag(rows, const SyncRecordCompanion(dirty: Value(false)));
  }

  /// Clears [applyPending] of [rows] that are still the versions given.
  static Future<void> clearApplyPending(List<SyncRecordData> rows) {
    return _clearFlag(rows, const SyncRecordCompanion(applyPending: Value(false)));
  }

  static Future<int> markAllDirty() {
    return appDb.update(appDb.syncRecord).write(const SyncRecordCompanion(dirty: Value(true)));
  }

  static Future<void> _clearFlag(List<SyncRecordData> rows, SyncRecordCompanion change) async {
    if (rows.isEmpty) {
      return;
    }
    await appDb.batch((batch) {
      for (SyncRecordData row in rows) {
        batch.update(
          appDb.syncRecord,
          change,
          where: ($SyncRecordTable r) =>
              r.kind.equals(row.kind) &
              r.key.equals(row.key) &
              r.updatedAt.equals(row.updatedAt) &
              r.device.equals(row.device),
        );
      }
    });
  }
}
