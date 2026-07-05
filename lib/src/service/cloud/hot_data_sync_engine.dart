import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
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
/// only rows changed since its last push, and applies packs from other devices
/// with per-row last-write-wins by timestamp.
///
/// Remote layout (relative to the provider's sync root):
///   manifest.json                 format marker + current snapshot version
///   snapshot/{ts}.json.gz         full merged state, written on compaction
///   ops/{deviceId}/{ts}.json.gz   incremental op packs, append-only
///
/// Correctness notes:
/// - Op packs are append-only and namespaced per device: concurrent syncs on
///   different devices can never overwrite each other's data.
/// - Applying a pack or snapshot uses timestamp-guarded upserts
///   (batchRecordIfNewer / batchWriteIfNewer), so re-applying anything is
///   idempotent and stale data can never roll back newer local rows.
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
  /// caller already downloaded it; used once to bootstrap v2 from v1 data.
  Future<HotSyncResult> sync(
    CloudProvider provider, {
    String? legacyRemoteConfigJson,
  }) async {
    String deviceId = await _ensureDeviceId();

    _Manifest? manifest = await _readManifest(provider);

    if (manifest == null) {
      log.info('🔁 Hot sync: no manifest found, bootstrapping format v2');
      return await _bootstrap(provider, deviceId, legacyRemoteConfigJson);
    }

    int applied = 0;

    // 1. Apply a newer snapshot if another device compacted since our last sync
    String appliedSnapshot = await localConfigService.read(configKey: ConfigEnum.oplogAppliedSnapshot) ?? '';
    if (manifest.snapshot != null && manifest.snapshot!.compareTo(appliedSnapshot) > 0) {
      log.info('🔁 Hot sync: applying snapshot ${manifest.snapshot}');
      List<int>? bytes = await provider.getRawObject('$snapshotPrefix${manifest.snapshot}.json.gz');
      if (bytes != null) {
        applied += await _applyPack(await _decodePack(bytes));
        await localConfigService.write(configKey: ConfigEnum.oplogAppliedSnapshot, value: manifest.snapshot!);
      } else {
        log.warning('Hot sync: snapshot ${manifest.snapshot} listed in manifest but missing');
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

    for (RemoteObjectInfo obj in pending) {
      List<int>? bytes = await provider.getRawObject(obj.key);
      if (bytes == null) {
        continue;
      }
      applied += await _applyPack(await _decodePack(bytes));
      _OpKey parsed = _OpKey.tryParse(obj.key)!;
      appliedCursors[parsed.deviceId] = parsed.ts;
    }
    if (pending.isNotEmpty) {
      await _writeAppliedCursors(appliedCursors);
    }
    log.info('🔁 Hot sync: applied ${pending.length} op packs ($applied rows)');

    // 3. Push local changes since our last push as a new op pack
    int pushed = await _pushLocalChanges(provider, deviceId);

    // 4. Compaction
    await _maybeCompact(provider, deviceId, opObjects.length + (pushed > 0 ? 1 : 0));

    return HotSyncResult(
      success: true,
      appliedRows: applied,
      pushedRows: pushed,
      appliedPacks: pending.length,
    );
  }

  /// First sync against a v1 remote (or an empty remote): import legacy hot
  /// data if present, then publish a snapshot of the full local state.
  Future<HotSyncResult> _bootstrap(CloudProvider provider, String deviceId, String? legacyRemoteConfigJson) async {
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

    /// Everything local is inside the snapshot: start push cursors from the
    /// current max timestamps so the first op pack only contains future changes.
    await _setPushCursor(_historyCursorKey, await historyService.getMaxLastReadTime() ?? '');
    await _setPushCursor(_readProgressCursorKey, await localConfigService.maxUtime(configKey: ConfigEnum.readIndexRecord) ?? '');

    return HotSyncResult(success: true, appliedRows: applied, pushedRows: 0, appliedPacks: 0, bootstrapped: true);
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

  /// Upload rows changed since the last push as one op pack.
  Future<int> _pushLocalChanges(CloudProvider provider, String deviceId) async {
    String historyCursor = await _getPushCursor(_historyCursorKey);
    String progressCursor = await _getPushCursor(_readProgressCursorKey);

    List<GalleryHistoryV2Data> pendingHistory = historyCursor.isEmpty
        ? await historyService.getAllRawHistory()
        : await historyService.getRawHistoryNewerThan(historyCursor);
    List<LocalConfig> pendingProgress = progressCursor.isEmpty
        ? await localConfigService.readWithAllSubKeys(configKey: ConfigEnum.readIndexRecord)
        : await localConfigService.readNewerThan(configKey: ConfigEnum.readIndexRecord, utimeExclusive: progressCursor);

    if (pendingHistory.isEmpty && pendingProgress.isEmpty) {
      log.info('🔁 Hot sync: nothing to push');
      return 0;
    }

    String ts = _timestampKey();
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

    /// Advance cursors to the max timestamp actually pushed (not "now"), so a
    /// row written between the query and this line is picked up next time.
    String maxHistory = pendingHistory.fold(historyCursor, (acc, h) => h.lastReadTime.compareTo(acc) > 0 ? h.lastReadTime : acc);
    String maxProgress = pendingProgress.fold(progressCursor, (acc, p) => p.utime.compareTo(acc) > 0 ? p.utime : acc);
    await _setPushCursor(_historyCursorKey, maxHistory);
    await _setPushCursor(_readProgressCursorKey, maxProgress);

    int pushed = pendingHistory.length + pendingProgress.length;
    log.info('🔁 Hot sync: pushed $pushed rows (${bytes.length} bytes gz) as $ts');
    return pushed;
  }

  /// Apply one decoded pack (op pack or snapshot) with guarded upserts.
  Future<int> _applyPack(Map<String, dynamic> pack) async {
    int applied = 0;

    List history = pack['history'] ?? [];
    if (history.isNotEmpty) {
      applied += await historyService.batchRecordIfNewer(history
          .map((e) => GalleryHistoryV2Data(
                gid: e['gid'],
                jsonBody: e['jsonBody'],
                lastReadTime: e['lastReadTime'],
              ))
          .toList());
    }

    List progress = pack['readProgress'] ?? [];
    if (progress.isNotEmpty) {
      int written = await localConfigService.batchWriteIfNewer(
        configKey: ConfigEnum.readIndexRecord,
        localConfigs: progress
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

  /// Export the full local state as a new snapshot object. Returns its ts.
  Future<String> _writeSnapshot(CloudProvider provider) async {
    List<GalleryHistoryV2Data> history = await historyService.getAllRawHistory();
    List<LocalConfig> progress = await localConfigService.readWithAllSubKeys(configKey: ConfigEnum.readIndexRecord);

    String ts = _timestampKey();
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
  Future<void> _maybeCompact(CloudProvider provider, String deviceId, int opCount) async {
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

  static const String _historyCursorKey = 'history';
  static const String _readProgressCursorKey = 'readIndexRecord';

  Future<String> _getPushCursor(String type) async {
    return await localConfigService.read(configKey: ConfigEnum.oplogPushCursor, subConfigKey: type) ?? '';
  }

  Future<void> _setPushCursor(String type, String cursor) async {
    await localConfigService.write(configKey: ConfigEnum.oplogPushCursor, subConfigKey: type, value: cursor);
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

  /// UTC timestamp usable as a lexicographically sortable object key.
  String _timestampKey() => _timestampKeyFor(DateTime.now().toUtc());

  String _timestampKeyFor(DateTime time) {
    String pad(int n, [int width = 2]) => n.toString().padLeft(width, '0');
    return '${time.year}${pad(time.month)}${pad(time.day)}${pad(time.hour)}${pad(time.minute)}${pad(time.second)}${pad(time.millisecond, 3)}';
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
