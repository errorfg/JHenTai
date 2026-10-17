import 'package:drift/drift.dart';

/// This device's copy of the records synced through a sync server: every
/// record it knows, including those of kinds it cannot use yet.
@TableIndex(name: 'sr_idx_dirty', columns: {#dirty})
@TableIndex(name: 'sr_idx_apply_pending', columns: {#applyPending})
class SyncRecord extends Table {
  @override
  String? get tableName => 'sync_record';

  TextColumn get kind => text()();

  TextColumn get key => text()();

  /// Null for a deletion.
  TextColumn get value => text().nullable()();

  /// Canonical UTC time (SyncTimeUtil); with [device] it orders versions.
  TextColumn get updatedAt => text()();

  TextColumn get device => text()();

  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  /// Changed on this device and not pushed yet.
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  /// Won over the local version and not written into the app's data yet.
  BoolColumn get applyPending => boolean().withDefault(const Constant(false))();

  /// Hash of the app's own form of the item when it last matched this record;
  /// null when the app does not hold it. Kinds found changed by comparing
  /// the app's data with this table use it to tell a local change.
  TextColumn get localHash => text().nullable()();

  @override
  Set<Column<Object>>? get primaryKey => {kind, key};
}
