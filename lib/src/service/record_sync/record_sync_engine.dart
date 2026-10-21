import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:jhentai/src/database/dao/sync_record_dao.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/cloud/sync_cancel_token.dart';
import 'package:jhentai/src/service/cloud/sync_device_id.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

import 'record_adapters.dart';
import 'record_backend.dart';

RecordSyncEngine recordSyncEngine = RecordSyncEngine();

/// Sync through a sync server, record by record.
///
/// Every synced item is a record (kind, key, value, updatedAt, device,
/// deleted); for each (kind, key) the version with the larger
/// (updatedAt, device) wins, a deletion included, so deletions travel and an
/// item added again later comes back. The sync_record table is this device's
/// copy of all records; adapters turn the app's data into records and back.
///
/// One sync: take local changes into the table, pull what other devices
/// wrote since the cursor (stored after every page), write the winning
/// records into the app's data, push the local changes. A kind taken in for
/// the first time is compared with what was pulled, so data a device shares
/// with the server (from syncing through a bucket before) is not sent again.
class RecordSyncEngine {
  RecordSyncEngine({List<RecordAdapter>? adapters}) : _adapters = adapters ?? defaultRecordAdapters();

  static const int pullLimit = 200;
  static const int pushLimit = 200;

  /// A push request stops growing past this many bytes of values.
  static const int pushBytes = 800 * 1024;

  final List<RecordAdapter> _adapters;

  Iterable<RowKindAdapter> get _rowAdapters => _adapters.whereType<RowKindAdapter>();

  Iterable<WholeKindAdapter> get _wholeAdapters => _adapters.whereType<WholeKindAdapter>();

  RecordAdapter? _adapterOf(String kind) => _adapters.firstWhereOrNull((a) => a.kind == kind);

  /// [cancel]: looked at before each step that writes.
  ///
  /// [joining]: the records hold what devices of earlier versions synced,
  /// taken over by another device (see BucketRecordBackend). Data of a kind
  /// taken in here for the first time then only adds items the records do
  /// not have, unless its items carry their own times
  /// ([WholeKindAdapter.itemTimesAreOwn]): the time of the rest is when
  /// this device last wrote the data, by a sync of an earlier version too,
  /// which says nothing of whether it is newer than the records.
  Future<RecordSyncResult> sync(
    RecordBackend backend, {
    Set<CloudConfigTypeEnum>? types,
    void Function(double progress)? onProgress,
    SyncCancelToken? cancel,
    bool joining = false,
  }) async {
    /// Timestamp format migrations must complete before any timestamp
    /// comparison below: bean ready hooks are fired without being awaited
    await historyService.ensureMigrated();
    await localConfigService.ensureMigrated();
    String device = await ensureSyncDeviceId();

    RecordServerInfo info = await backend.info();
    cancel?.throwIfCancelled();
    _State state = await _readState();
    if (state.database != info.database) {
      int marked = await SyncRecordDao.markAllDirty();
      log.info('🗄 Record sync: server database ${info.database} is new to this device, pushing all $marked records');
      state
        ..database = info.database
        ..cursor = '';
      await _writeState(state);
    }
    onProgress?.call(0.1);

    bool wanted(RecordAdapter adapter) => types == null || types.contains(adapter.type);

    // 1. Local changes of the kinds taken in before
    PendingSyncSnapshotToken token = await pendingSyncTracker.snapshotToken();
    await _takeRowChanges(device, state, token, firstTime: false);
    for (WholeKindAdapter adapter in _wholeAdapters) {
      if (state.kinds.contains(adapter.kind) && wanted(adapter)) {
        await _takeWholeChanges(adapter, device, state);
      }
    }
    onProgress?.call(0.3);

    // 2. What other devices wrote
    int pulled = 0;
    while (true) {
      RecordPage page = await backend.pull(since: state.cursor, device: device, limit: pullLimit);
      cancel?.throwIfCancelled();
      pulled += await _takeRemote(page.records);
      state.cursor = page.next;
      await _writeState(state);
      if (!page.more) {
        break;
      }
    }

    // Kinds taken in for the first time, against what the server holds
    cancel?.throwIfCancelled();
    await _takeRowChanges(device, state, token, firstTime: true);
    final Set<String> joined = {};
    for (WholeKindAdapter adapter in _wholeAdapters) {
      if (!state.kinds.contains(adapter.kind) && wanted(adapter)) {
        await _takeLegacy(adapter);
        await _takeWholeChanges(adapter, device, state, joining: joining);
        if (joining) {
          joined.add(adapter.kind);
        }
      }
    }
    await pendingSyncTracker.removePushedSnapshot(token);
    await _writeState(state);

    // Should the device go back to a bucket, its next sync there uploads
    // everything once, as rows changed meanwhile did not go through it.
    if (await localConfigService.read(configKey: ConfigEnum.oplogFullPushDone) == 'true') {
      await localConfigService.write(configKey: ConfigEnum.oplogFullPushDone, value: 'false');
    }
    onProgress?.call(0.6);

    // 3. Winning records into the app's data; kinds this version does not
    // know stay in the table until a version that knows them
    int applied = 0;
    for (String kind in await SyncRecordDao.selectApplyPendingKinds()) {
      cancel?.throwIfCancelled();
      RecordAdapter? adapter = _adapterOf(kind);
      if (adapter is RowKindAdapter) {
        applied += await _applyRows(adapter);
      } else if (adapter is WholeKindAdapter) {
        applied += await _applyWhole(adapter, device, state, joining: joined.contains(adapter.kind));
      }
    }
    await _writeState(state);
    onProgress?.call(0.75);

    // 4. Local changes out
    int pushed = 0;
    while (true) {
      List<SyncRecordData> rows = _withinBytes(await SyncRecordDao.selectDirty(pushLimit));
      if (rows.isEmpty) {
        break;
      }
      cancel?.throwIfCancelled();
      await backend.push(rows.map(RemoteRecord.fromRow).toList());
      await SyncRecordDao.clearDirty(rows);
      pushed += rows.length;
    }
    onProgress?.call(1);

    log.info('🗄 Record sync: pulled $pulled, applied $applied, pushed $pushed records');
    return RecordSyncResult(pulled: pulled, applied: applied, pushed: pushed);
  }

  /// The device synced history and read progress through a bucket: their
  /// pending sets went there, so the next sync here reads them whole again.
  Future<void> forgetRowChanges() async {
    _State state = await _readState();
    int before = state.kinds.length;
    state.kinds.removeAll(_rowAdapters.map((a) => a.kind));
    if (state.kinds.length != before) {
      await _writeState(state);
    }
  }

  /// [keys] of [kind] were deleted on this device. Kept only once the device
  /// has synced that kind, or [syncOn].
  Future<void> recordDeletions(String kind, Iterable<String> keys, {required bool syncOn}) async {
    if (keys.isEmpty || (!syncOn && !await SyncRecordDao.existsKind(kind))) {
      return;
    }
    String device = await ensureSyncDeviceId();
    String now = SyncTimeUtil.nowIso();
    await appDb.transaction(() async {
      Map<String, SyncRecordData> rows = await SyncRecordDao.selectByKeys(kind, keys);
      await SyncRecordDao.write([
        for (String key in keys.toSet())
          _deletion(kind, key, rows[key] == null ? now : _later(now, rows[key]!.updatedAt), device),
      ]);
    });
  }

  /// History and read progress: the rows in the pending set, or, for kinds
  /// taken in for the first time ([firstTime]), all rows. A row goes into the
  /// table when it is newer than the record.
  Future<void> _takeRowChanges(
    String device,
    _State state,
    PendingSyncSnapshotToken token, {
    required bool firstTime,
  }) async {
    for (RowKindAdapter adapter in _rowAdapters) {
      bool whole = !state.kinds.contains(adapter.kind);
      if (whole != firstTime) {
        continue;
      }
      if (whole) {
        await _takeLegacy(adapter);
      }
      List<RowItem> items = await adapter.read(whole ? null : adapter.pendingKeys(token));
      if (whole) {
        log.info('🗄 Record sync: taking all ${items.length} ${adapter.kind} rows');
      }
      await appDb.transaction(() async {
        Map<String, SyncRecordData> rows = await SyncRecordDao.selectByKeys(adapter.kind, items.map((i) => i.key));
        List<SyncRecordData> writes = [];
        for (RowItem item in items) {
          SyncRecordData? row = rows[item.key];
          if (row == null || item.time.compareTo(row.updatedAt) > 0) {
            writes.add(SyncRecordData(
              kind: adapter.kind,
              key: item.key,
              value: item.value,
              updatedAt: item.time,
              device: device,
              deleted: false,
              dirty: true,
              applyPending: false,
            ));
          } else if (item.time.compareTo(row.updatedAt) < 0 && !row.applyPending) {
            // The record is newer than the row (a deletion, or a version
            // that did not get written): write it into the app.
            writes.add(row.copyWith(applyPending: true));
          }
        }
        await SyncRecordDao.write(writes);
      });
      state.kinds.add(adapter.kind);
    }
  }

  /// A whole kind: its items compared with the records.
  ///
  /// - An item whose hash differs from the one recorded when it last matched
  ///   was changed here: a new version, timed at the kind's last change and
  ///   after the version it replaces (the change was made on top of that).
  /// - A record that matched an item the app no longer holds: deleted here.
  /// - Without such a match (the kind's first time, an item new to the
  ///   table, a record not yet written into the app), the item and the
  ///   record are compared by time, and nothing counts as deleted.
  /// [joining]: see [sync]; until the records are written into the app.
  Future<void> _takeWholeChanges(WholeKindAdapter adapter, String device, _State state, {bool joining = false}) async {
    List<MapEntry<String, LocalItem>> items = await adapter.export();
    String changeTime = await adapter.changeTime();
    bool first = !state.kinds.contains(adapter.kind);

    await appDb.transaction(() async {
      Map<String, SyncRecordData> rows = {
        for (SyncRecordData row in await SyncRecordDao.selectByKind(adapter.kind)) row.key: row,
      };
      Map<String, String> promoted = first ? const {} : adapter.promotions(items, rows, changeTime);
      List<SyncRecordData> writes = [];
      Set<String> held = {};

      for (MapEntry<String, LocalItem> entry in items) {
        String key = entry.key;
        LocalItem item = entry.value;
        held.add(key);
        String hash = _hash(item.value);
        SyncRecordData? row = rows[key];
        String? promotedTime = promoted[key];

        if (row != null && promotedTime == null) {
          if (row.localHash == hash) {
            continue;
          }
          if (!row.deleted && row.value == item.value) {
            writes.add(row.copyWith(localHash: Value(hash)));
            continue;
          }
        }

        SyncRecordData version(String time) => SyncRecordData(
              kind: adapter.kind,
              key: key,
              value: item.value,
              updatedAt: time,
              device: device,
              deleted: false,
              dirty: true,
              applyPending: false,
              localHash: hash,
            );

        if (first || row == null || row.localHash == null || row.applyPending) {
          String time = item.firstTime ?? changeTime;
          bool mayWin = !(joining && !adapter.itemTimesAreOwn);
          if (row == null || (mayWin && compareVersions(time, device, row.updatedAt, row.device) > 0)) {
            writes.add(version(time));
          } else if (!row.applyPending) {
            writes.add(row.copyWith(applyPending: true));
          }
        } else {
          writes.add(version(promotedTime ?? _later(changeTime, row.updatedAt)));
        }
      }

      if (!first) {
        for (SyncRecordData row in rows.values) {
          if (held.contains(row.key) || row.deleted || row.localHash == null) {
            continue;
          }
          if (row.applyPending) {
            // Removed here while another device changed it: the later wins.
            if (compareVersions(changeTime, device, row.updatedAt, row.device) > 0) {
              writes.add(_deletion(adapter.kind, row.key, changeTime, device));
            }
          } else {
            writes.add(_deletion(adapter.kind, row.key, _later(changeTime, row.updatedAt), device));
          }
        }
      }

      await SyncRecordDao.write(writes);
    });
    state.kinds.add(adapter.kind);
  }

  /// What the records of the kind [adapter]'s took the place of hold, as
  /// records of its kind, taken like records pulled: once, before the kind
  /// is first taken in here, so that a device new to the kind (installed
  /// again, say) gets what devices of earlier versions synced. Each keeps
  /// the device of the record it came from, so devices doing this make the
  /// same records; they are not pushed. The old records stay as they are.
  Future<void> _takeLegacy(RecordAdapter adapter) async {
    String? legacyKind = adapter.legacyKind;
    if (legacyKind == null) {
      return;
    }
    List<RemoteRecord> records = [];
    for (SyncRecordData row in await SyncRecordDao.selectByKind(legacyKind)) {
      if (row.deleted || row.value == null) {
        continue;
      }
      try {
        for (MapEntry<String, LocalItem> item in adapter.legacyItems(row.value!)) {
          records.add(RemoteRecord(
            kind: adapter.kind,
            key: item.key,
            value: item.value.value,
            updatedAt: item.value.firstTime ?? row.updatedAt,
            device: row.device,
            deleted: false,
          ));
        }
      } catch (e) {
        log.warning('Record sync: $legacyKind record of ${row.device} unreadable', e);
      }
    }
    if (records.isNotEmpty) {
      int taken = await _takeRemote(records);
      log.info('🗄 Record sync: took $taken of ${records.length} ${adapter.kind} records from $legacyKind');
    }
  }

  /// Stores the records that win over this device's versions, each to be
  /// written into the app's data.
  Future<int> _takeRemote(List<RemoteRecord> records) async {
    int taken = 0;
    await appDb.transaction(() async {
      for (MapEntry<String, List<RemoteRecord>> group in groupBy(records, (RemoteRecord r) => r.kind).entries) {
        Map<String, SyncRecordData> rows = await SyncRecordDao.selectByKeys(group.key, group.value.map((r) => r.key));
        Map<String, SyncRecordData> writes = {};
        for (RemoteRecord record in group.value) {
          SyncRecordData? row = rows[record.key];
          if (row != null && compareVersions(record.updatedAt, record.device, row.updatedAt, row.device) <= 0) {
            continue;
          }
          SyncRecordData next = SyncRecordData(
            kind: record.kind,
            key: record.key,
            value: record.deleted ? null : record.value,
            updatedAt: record.updatedAt,
            device: record.device,
            deleted: record.deleted,
            dirty: false,
            applyPending: true,
            localHash: row?.localHash,
          );
          rows[record.key] = next;
          writes[record.key] = next;
        }
        await SyncRecordDao.write(writes.values);
        taken += writes.length;
      }
    });
    return taken;
  }

  Future<int> _applyRows(RowKindAdapter adapter) async {
    List<SyncRecordData> rows = await SyncRecordDao.selectApplyPending(adapter.kind);
    await adapter.apply(rows);
    await SyncRecordDao.clearApplyPending(rows);
    return rows.length;
  }

  /// Rebuilds the app's data of the kind from its records, after taking in
  /// what changed here since step 1, and records what each item now hashes to.
  Future<int> _applyWhole(WholeKindAdapter adapter, String device, _State state, {bool joining = false}) async {
    await _takeWholeChanges(adapter, device, state, joining: joining);
    List<SyncRecordData> rows = await SyncRecordDao.selectByKind(adapter.kind);
    int pending = rows.where((r) => r.applyPending).length;
    if (pending == 0) {
      return 0;
    }

    await adapter.replaceAll(rows.where((r) => !r.deleted).toList());
    Map<String, String> hashes = {
      for (MapEntry<String, LocalItem> entry in await adapter.export()) entry.key: _hash(entry.value.value),
    };
    await SyncRecordDao.write([
      for (SyncRecordData row in rows)
        row.copyWith(applyPending: false, localHash: Value(row.deleted ? null : hashes[row.key])),
    ]);
    return pending;
  }

  List<SyncRecordData> _withinBytes(List<SyncRecordData> rows) {
    int bytes = 0;
    List<SyncRecordData> taken = [];
    for (SyncRecordData row in rows) {
      bytes += row.key.length + (row.value?.length ?? 0) + 100;
      if (taken.isNotEmpty && bytes > pushBytes) {
        break;
      }
      taken.add(row);
    }
    return taken;
  }

  SyncRecordData _deletion(String kind, String key, String time, String device) => SyncRecordData(
        kind: kind,
        key: key,
        value: null,
        updatedAt: time,
        device: device,
        deleted: true,
        dirty: true,
        applyPending: false,
      );

  /// [time], or just after [previous] when that is not earlier.
  String _later(String time, String previous) {
    if (time.compareTo(previous) > 0) {
      return time;
    }
    return SyncTimeUtil.format(SyncTimeUtil.parse(previous).add(const Duration(microseconds: 1)));
  }

  String _hash(String value) => sha1.convert(utf8.encode(value)).toString();

  Future<_State> _readState() async {
    String? raw = await localConfigService.read(configKey: ConfigEnum.recordSyncState);
    if (raw == null || raw.isEmpty) {
      return _State();
    }
    try {
      Map<String, dynamic> json = jsonDecode(raw);
      return _State(
        database: json['database'] as String?,
        // An int up to 8.1.1, of the sync server.
        cursor: '${json['cursor'] ?? ''}',
        kinds: (json['kinds'] as List? ?? []).cast<String>().toSet(),
      );
    } catch (e) {
      log.warning('Record sync: state unreadable, starting over', e);
      return _State();
    }
  }

  Future<void> _writeState(_State state) {
    return localConfigService.write(
      configKey: ConfigEnum.recordSyncState,
      value: jsonEncode({'database': state.database, 'cursor': state.cursor, 'kinds': state.kinds.toList()..sort()}),
    );
  }
}

class _State {
  String? database;

  /// Where the next pull starts, as the backend gave it; empty for the start.
  String cursor;

  /// Kinds taken into the table at least once.
  final Set<String> kinds;

  _State({this.database, this.cursor = '', Set<String>? kinds}) : kinds = kinds ?? {};
}

class RecordSyncResult {
  final int pulled;
  final int applied;
  final int pushed;

  const RecordSyncResult({required this.pulled, required this.applied, required this.pushed});
}
