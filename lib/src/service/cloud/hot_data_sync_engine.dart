import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

/// Incremental ("oplog") sync engine for the two hot, ever-growing data types:
/// gallery history and read progress. Instead of shipping the full data set
/// through a single shared file on every sync (O(total) transfer, last-writer-
/// wins races between devices), each device appends small op packs containing
/// only locally-changed rows, and applies other devices' packs with per-row
/// last-write-wins by timestamp.
///
/// Remote layout (relative to the provider's sync root):
///   manifest.json                 format marker + current snapshot version
///   snapshot/{ts}.json.gz         full merged state, written on compaction
///   ops/{deviceId}/{ts}.json.gz   incremental op packs, append-only
///
/// Correctness notes:
/// - Op packs are append-only and namespaced per device: concurrent syncs on
///   different devices can never overwrite each other's data.
/// - Push eligibility comes from an explicit dirty set ([PendingSyncTracker])
///   maintained by the user-originated write paths, NOT from comparing row
///   timestamps against a cursor - row timestamps are cross-device LWW data
///   and a skewed remote clock must not affect what this device uploads.
/// - Every device performs one full push of its local state (as a normal op
///   pack) before switching to incremental pushes. This makes the first-sync
///   bootstrap race benign: even if two devices bootstrap concurrently and
///   one manifest write wins, both devices' data still reaches the other
///   through their full op packs.
/// - Applying a pack or snapshot uses timestamp-guarded upserts
///   (batchRecordIfNewer / batchWriteIfNewer), so re-applying anything is
///   idempotent and stale data can never roll back newer local rows.
/// - Op pack keys are forced monotonic per device (persisted last key), so a
///   backwards clock step cannot produce a key that other devices' applied
///   cursors would skip forever.
/// - Compaction only deletes op packs older than [_opRetention] AND covered by
///   a snapshot; a device offline longer than that simply bootstraps from the
///   snapshot (which is a full state) plus surviving ops.
class HotDataSyncEngine {
  static const String manifestKey = 'manifest.json';
  static const String snapshotPrefix = 'snapshot/';
  static const String opsPrefix = 'ops/';
  static const int formatVersion = 2;

  /// Compact when the number of op packs exceeds this.
  static const int _compactionThreshold = 100;

  /// Op packs older than this and covered by a snapshot may be deleted.
  static const Duration _opRetention = Duration(days: 7);

  /// Keep this many most recent snapshots (older ones are garbage).
  static const int _snapshotsToKeep = 2;

  /// Sync the hot data types through [provider].
  ///
  /// [legacyRemoteConfigJson]: raw content of the legacy latest.json if the
  /// caller already downloaded it. Used to bootstrap v2 from v1 data, and -
  /// during the transition period while not-yet-upgraded clients still write
  /// hot data into latest.json - to keep absorbing their changes.
  Future<HotSyncResult> sync(
    CloudProvider provider, {
    String? legacyRemoteConfigJson,
  }) async {
    /// Timestamp format migrations must complete before any timestamp
    /// comparison below: bean ready hooks are fired without being awaited
    await historyService.ensureMigrated();
    await localConfigService.ensureMigrated();

    String deviceId = await _ensureDeviceId();

    _Manifest? manifest = await _readManifest(provider);
    bool bootstrapped = false;
    int applied = 0;

    if (manifest == null) {
      log.info('🔁 Hot sync: no manifest found, bootstrapping format v2');
      applied += await _bootstrap(provider, legacyRemoteConfigJson);
      bootstrapped = true;
    } else {
      // 1. Apply a newer snapshot if another device compacted since our last sync
      String appliedSnapshot = await localConfigService.read(configKey: ConfigEnum.oplogAppliedSnapshot) ?? '';
      if (manifest.snapshot != null && manifest.snapshot!.compareTo(appliedSnapshot) > 0) {
        log.info('🔁 Hot sync: applying snapshot ${manifest.snapshot}');
        List<int>? bytes = await provider.getRawObject('$snapshotPrefix${manifest.snapshot}.json.gz');
        if (bytes != null) {
          applied += await _applyPacks([await _decodePack(bytes)]);
          await localConfigService.write(configKey: ConfigEnum.oplogAppliedSnapshot, value: manifest.snapshot!);
        } else {
          log.warning('Hot sync: snapshot ${manifest.snapshot} listed in manifest but missing');
        }
      }

      /// Transition period: old-version clients still write their hot data
      /// into latest.json. Absorb it with guarded upserts (cheap once those
      /// clients are upgraded and latest.json no longer carries hot types).
      if (legacyRemoteConfigJson != null) {
        try {
          applied += await _applyLegacyConfig(legacyRemoteConfigJson);
        } catch (e) {
          log.warning('Hot sync: failed to absorb legacy config data', e);
        }
      }
    }

    // 2. Apply unseen op packs from all devices
    List<RemoteObjectInfo> opObjects = await provider.listRawObjects(opsPrefix);
    Map<String, String> appliedCursors = await _readAppliedCursors();

    List<RemoteObjectInfo> pending = [];
    for (RemoteObjectInfo obj in opObjects) {
      _OpKey? parsed = _OpKey.tryParse(obj.key);
      if (parsed == null) {
        continue;
      }
      if (parsed.deviceId == deviceId) {
        continue;
      }
      String cursor = appliedCursors[parsed.deviceId] ?? '';
      if (parsed.ts.compareTo(cursor) > 0) {
        pending.add(obj);
      }
    }
    pending.sort((a, b) => a.key.compareTo(b.key));

    /// Download everything first, apply in ONE guarded write per type
    /// (guarded writes read a full-table timestamp map, so applying pack by
    /// pack would be O(packs x table size)), then advance cursors.
    List<Map<String, dynamic>> packs = [];
    for (RemoteObjectInfo obj in pending) {
      List<int>? bytes = await provider.getRawObject(obj.key);
      if (bytes == null) {
        continue;
      }
      packs.add(await _decodePack(bytes));
    }
    applied += await _applyPacks(packs);
    for (RemoteObjectInfo obj in pending) {
      _OpKey parsed = _OpKey.tryParse(obj.key)!;
      String current = appliedCursors[parsed.deviceId] ?? '';
      if (parsed.ts.compareTo(current) > 0) {
        appliedCursors[parsed.deviceId] = parsed.ts;
      }
    }
    if (pending.isNotEmpty) {
      await _writeAppliedCursors(appliedCursors);
      log.info('🔁 Hot sync: applied ${pending.length} op packs ($applied rows total)');
    }

    // 3. Push local changes as a new op pack
    int pushed = await _pushLocalChanges(provider, deviceId);

    // 4. Compaction
    await _maybeCompact(provider, opObjects.length + (pushed > 0 ? 1 : 0));

    return HotSyncResult(
      success: true,
      appliedRows: applied,
      pushedRows: pushed,
      appliedPacks: pending.length,
      bootstrapped: bootstrapped,
    );
  }

  /// First sync against a v1 remote (or an empty remote): import legacy hot
  /// data if present, then publish a snapshot of the full local state.
  ///
  /// Deliberately does NOT mark the full push as done: the caller continues
  /// with the normal push step, which uploads the full local state as an op
  /// pack once. That way, if two devices bootstrap concurrently and one
  /// manifest/snapshot write shadows the other, the shadowed device's data
  /// still propagates through its op pack.
  Future<int> _bootstrap(CloudProvider provider, String? legacyRemoteConfigJson) async {
    int applied = 0;

    if (legacyRemoteConfigJson != null) {
      try {
        applied = await _applyLegacyConfig(legacyRemoteConfigJson);
        log.info('🔁 Hot sync bootstrap: imported $applied rows from legacy config');
      } catch (e) {
        log.warning('Hot sync bootstrap: failed to parse legacy config, continuing with local data only', e);
      }
    }

    String snapshotTs = await _writeSnapshot(provider);
    await _writeManifest(provider, _Manifest(snapshot: snapshotTs));
    await localConfigService.write(configKey: ConfigEnum.oplogAppliedSnapshot, value: snapshotTs);

    return applied;
  }

  /// Extract the two hot types from a legacy latest.json payload and apply
  /// them with timestamp-guarded upserts.
  Future<int> _applyLegacyConfig(String legacyJson) async {
    List raw = await isolateService.jsonDecodeAsync(legacyJson);
    List<CloudConfig> configs = raw.map((e) => CloudConfig.fromJson(e)).toList();
    int applied = 0;

    for (CloudConfig config in configs) {
      if (config.type == CloudConfigTypeEnum.history) {
        List list = await isolateService.jsonDecodeAsync(config.config);
        List<GalleryHistoryV2Data> histories = list.map((e) => GalleryHistoryV2Data.fromJson(e)).toList();
        applied += await historyService.batchRecordIfNewer(histories);
      } else if (config.type == CloudConfigTypeEnum.readIndexRecord) {
        List list = await isolateService.jsonDecodeAsync(config.config);
        applied += await localConfigService.batchWriteIfNewer(
          configKey: ConfigEnum.readIndexRecord,
          localConfigs: list
              .map((e) => LocalConfigCompanion(
                    configKey: const Value('readIndexRecord'),
                    subConfigKey: Value(e['subConfigKey']),
                    value: Value(e['value']),
                    utime: Value(e['utime']),
                  ))
              .toList(),
        );
      }
    }

    if (applied > 0) {
      readProgressService.clearCacheAndRefresh();
    }
    return applied;
  }

  /// Upload locally-changed rows as one op pack. The first push after
  /// enabling format v2 uploads the full local state; afterwards only rows in
  /// the pending set travel.
  Future<int> _pushLocalChanges(CloudProvider provider, String deviceId) async {
    bool fullPushDone = await localConfigService.read(configKey: ConfigEnum.oplogFullPushDone) == 'true';

    List<GalleryHistoryV2Data> pendingHistory;
    List<LocalConfig> pendingProgress;
    Set<int> pushedHistoryGids = {};
    Set<String> pushedProgressKeys = {};

    if (!fullPushDone) {
      pendingHistory = await historyService.getAllRawHistory();
      pendingProgress = await localConfigService.readWithAllSubKeys(configKey: ConfigEnum.readIndexRecord);
      log.info('🔁 Hot sync: performing one-time full push (${pendingHistory.length} history, ${pendingProgress.length} progress)');
    } else {
      (pushedHistoryGids, pushedProgressKeys) = await pendingSyncTracker.snapshot();
      pendingHistory = pushedHistoryGids.isEmpty ? [] : await historyService.getRawHistoryByGids(pushedHistoryGids);
      pendingProgress = pushedProgressKeys.isEmpty
          ? []
          : await localConfigService.readBySubKeys(configKey: ConfigEnum.readIndexRecord, subConfigKeys: pushedProgressKeys);
    }

    if (pendingHistory.isEmpty && pendingProgress.isEmpty) {
      log.info('🔁 Hot sync: nothing to push');
      if (!fullPushDone) {
        await localConfigService.write(configKey: ConfigEnum.oplogFullPushDone, value: 'true');
      }
      return 0;
    }

    String ts = await _nextMonotonicKey();
    Map<String, dynamic> pack = {
      'formatVersion': formatVersion,
      'deviceId': deviceId,
      'createdAt': SyncTimeUtil.nowIso(),
      'history': pendingHistory
          .map((h) => {'gid': h.gid, 'jsonBody': h.jsonBody, 'lastReadTime': h.lastReadTime})
          .toList(),
      'readProgress': pendingProgress
          .map((p) => {'subConfigKey': p.subConfigKey, 'value': p.value, 'utime': p.utime})
          .toList(),
    };

    List<int> bytes = await _encodePack(pack);
    await provider.putRawObject('$opsPrefix$deviceId/$ts.json.gz', bytes);
    await localConfigService.write(configKey: ConfigEnum.oplogLastPushedKey, value: ts);

    if (!fullPushDone) {
      await localConfigService.write(configKey: ConfigEnum.oplogFullPushDone, value: 'true');
      await pendingSyncTracker.clearAll();
    } else {
      await pendingSyncTracker.removePushed(pushedHistoryGids, pushedProgressKeys);
    }

    int pushed = pendingHistory.length + pendingProgress.length;
    log.info('🔁 Hot sync: pushed $pushed rows (${bytes.length} bytes gz) as $ts');
    return pushed;
  }

  /// Apply decoded packs (op packs or snapshots) with guarded upserts:
  /// merge rows across packs per key first (max timestamp wins) so each type
  /// costs one guarded write regardless of pack count.
  Future<int> _applyPacks(List<Map<String, dynamic>> packs) async {
    if (packs.isEmpty) {
      return 0;
    }

    Map<int, Map<String, dynamic>> historyByGid = {};
    Map<String, Map<String, dynamic>> progressByKey = {};

    for (Map<String, dynamic> pack in packs) {
      for (var e in (pack['history'] as List? ?? [])) {
        int gid = e['gid'];
        var current = historyByGid[gid];
        if (current == null || _timeOrEpoch(e['lastReadTime']).isAfter(_timeOrEpoch(current['lastReadTime']))) {
          historyByGid[gid] = Map<String, dynamic>.from(e);
        }
      }
      for (var e in (pack['readProgress'] as List? ?? [])) {
        String key = e['subConfigKey'];
        var current = progressByKey[key];
        if (current == null || _timeOrEpoch(e['utime']).isAfter(_timeOrEpoch(current['utime']))) {
          progressByKey[key] = Map<String, dynamic>.from(e);
        }
      }
    }

    int applied = 0;

    if (historyByGid.isNotEmpty) {
      applied += await historyService.batchRecordIfNewer(historyByGid.values
          .map((e) => GalleryHistoryV2Data(
                gid: e['gid'],
                jsonBody: e['jsonBody'],
                lastReadTime: e['lastReadTime'],
              ))
          .toList());
    }

    if (progressByKey.isNotEmpty) {
      int written = await localConfigService.batchWriteIfNewer(
        configKey: ConfigEnum.readIndexRecord,
        localConfigs: progressByKey.values
            .map((e) => LocalConfigCompanion(
                  configKey: const Value('readIndexRecord'),
                  subConfigKey: Value(e['subConfigKey']),
                  value: Value(e['value']),
                  utime: Value(e['utime']),
                ))
            .toList(),
      );
      applied += written;
      if (written > 0) {
        readProgressService.clearCacheAndRefresh();
      }
    }

    return applied;
  }

  DateTime _timeOrEpoch(String? value) {
    return SyncTimeUtil.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  /// Export the full local state as a new snapshot object. Returns its ts.
  Future<String> _writeSnapshot(CloudProvider provider) async {
    List<GalleryHistoryV2Data> history = await historyService.getAllRawHistory();
    List<LocalConfig> progress = await localConfigService.readWithAllSubKeys(configKey: ConfigEnum.readIndexRecord);

    String ts = await _nextMonotonicKey();
    Map<String, dynamic> pack = {
      'formatVersion': formatVersion,
      'createdAt': SyncTimeUtil.nowIso(),
      'history': history.map((h) => {'gid': h.gid, 'jsonBody': h.jsonBody, 'lastReadTime': h.lastReadTime}).toList(),
      'readProgress': progress.map((p) => {'subConfigKey': p.subConfigKey, 'value': p.value, 'utime': p.utime}).toList(),
    };

    List<int> bytes = await _encodePack(pack);
    await provider.putRawObject('$snapshotPrefix$ts.json.gz', bytes);
    log.info('🔁 Hot sync: wrote snapshot $ts (${history.length} history, ${progress.length} progress, ${bytes.length} bytes gz)');
    return ts;
  }

  /// Compact when there are too many op packs: publish a fresh snapshot, then
  /// delete op packs old enough that every device can recover them from the
  /// snapshot instead.
  Future<void> _maybeCompact(CloudProvider provider, int opCount) async {
    if (opCount <= _compactionThreshold) {
      return;
    }

    try {
      log.info('🔁 Hot sync: compacting ($opCount op packs)');
      String snapshotTs = await _writeSnapshot(provider);
      await _writeManifest(provider, _Manifest(snapshot: snapshotTs));
      await localConfigService.write(configKey: ConfigEnum.oplogAppliedSnapshot, value: snapshotTs);

      String deletionHorizon = _timestampKeyFor(DateTime.now().toUtc().subtract(_opRetention));
      List<RemoteObjectInfo> opObjects = await provider.listRawObjects(opsPrefix);
      int deleted = 0;
      for (RemoteObjectInfo obj in opObjects) {
        _OpKey? parsed = _OpKey.tryParse(obj.key);
        if (parsed != null && parsed.ts.compareTo(deletionHorizon) < 0) {
          await provider.deleteRawObject(obj.key);
          deleted++;
        }
      }

      /// Garbage-collect old snapshots, keeping the most recent few
      List<RemoteObjectInfo> snapshots = await provider.listRawObjects(snapshotPrefix);
      snapshots.sort((a, b) => b.key.compareTo(a.key));
      for (RemoteObjectInfo obj in snapshots.skip(_snapshotsToKeep)) {
        await provider.deleteRawObject(obj.key);
      }

      log.info('🔁 Hot sync: compaction done, deleted $deleted op packs');
    } catch (e) {
      log.error('Hot sync compaction failed (sync itself unaffected)', e);
    }
  }

  Future<_Manifest?> _readManifest(CloudProvider provider) async {
    List<int>? bytes = await provider.getRawObject(manifestKey);
    if (bytes == null) {
      return null;
    }
    try {
      Map<String, dynamic> json = jsonDecode(utf8.decode(bytes));
      return _Manifest(snapshot: json['snapshot']);
    } catch (e) {
      log.warning('Hot sync: manifest unreadable, treating as absent', e);
      return null;
    }
  }

  Future<void> _writeManifest(CloudProvider provider, _Manifest manifest) async {
    Map<String, dynamic> json = {
      'formatVersion': formatVersion,
      'snapshot': manifest.snapshot,
      'updatedAt': SyncTimeUtil.nowIso(),
    };
    await provider.putRawObject(manifestKey, utf8.encode(jsonEncode(json)));
  }

  Future<List<int>> _encodePack(Map<String, dynamic> pack) async {
    String json = await isolateService.jsonEncodeAsync(pack);
    return gzip.encode(utf8.encode(json));
  }

  Future<Map<String, dynamic>> _decodePack(List<int> bytes) async {
    String json = utf8.decode(gzip.decode(bytes));
    return Map<String, dynamic>.from(await isolateService.jsonDecodeAsync(json));
  }

  Future<Map<String, String>> _readAppliedCursors() async {
    String? raw = await localConfigService.read(configKey: ConfigEnum.oplogAppliedOps);
    if (raw == null || raw.isEmpty) {
      return {};
    }
    try {
      return Map<String, String>.from(jsonDecode(raw));
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeAppliedCursors(Map<String, String> cursors) async {
    await localConfigService.write(configKey: ConfigEnum.oplogAppliedOps, value: jsonEncode(cursors));
  }

  Future<String> _ensureDeviceId() async {
    String? id = await localConfigService.read(configKey: ConfigEnum.syncDeviceId);
    if (id != null && id.isNotEmpty) {
      return id;
    }
    String generated = _generateDeviceId();
    await localConfigService.write(configKey: ConfigEnum.syncDeviceId, value: generated);
    return generated;
  }

  String _generateDeviceId() {
    final random = Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(12, (_) => chars[random.nextInt(chars.length)]).join();
  }

  /// Next object-key timestamp, forced strictly monotonic per device so a
  /// backwards clock step cannot generate a key that other devices' applied
  /// cursors have already passed.
  Future<String> _nextMonotonicKey() async {
    String now = _timestampKeyFor(DateTime.now().toUtc());
    String last = await localConfigService.read(configKey: ConfigEnum.oplogLastPushedKey) ?? '';
    if (last.length == now.length && now.compareTo(last) <= 0) {
      now = (BigInt.parse(last) + BigInt.one).toString().padLeft(now.length, '0');
    }
    return now;
  }

  String _timestampKeyFor(DateTime time) {
    String pad(int n, [int width = 2]) => n.toString().padLeft(width, '0');
    return '${pad(time.year, 4)}${pad(time.month)}${pad(time.day)}${pad(time.hour)}${pad(time.minute)}${pad(time.second)}${pad(time.millisecond, 3)}';
  }
}

class _Manifest {
  final String? snapshot;

  _Manifest({this.snapshot});
}

class _OpKey {
  final String deviceId;
  final String ts;

  _OpKey(this.deviceId, this.ts);

  /// Parses 'ops/{deviceId}/{ts}.json.gz'
  static _OpKey? tryParse(String key) {
    final match = RegExp(r'^ops/([^/]+)/(\d{17})\.json\.gz$').firstMatch(key);
    if (match == null) {
      return null;
    }
    return _OpKey(match.group(1)!, match.group(2)!);
  }
}

class HotSyncResult {
  final bool success;
  final int appliedRows;
  final int pushedRows;
  final int appliedPacks;
  final bool bootstrapped;

  HotSyncResult({
    required this.success,
    required this.appliedRows,
    required this.pushedRows,
    required this.appliedPacks,
    this.bootstrapped = false,
  });
}
