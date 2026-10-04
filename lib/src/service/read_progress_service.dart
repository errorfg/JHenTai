import 'package:drift/drift.dart' as drift show Value;
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart' show LocalConfigCompanion;
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

import 'cloud/pending_sync_tracker.dart';

ReadProgressService readProgressService = ReadProgressService();

class ReadProgressEntry {
  const ReadProgressEntry({
    required this.key,
    required this.pageIndex,
    required this.lastReadAt,
  });

  final String key;
  final int pageIndex;
  final DateTime lastReadAt;
}

/// A raw stored progress value. An empty [value] is the unread marker: it
/// replaces deletion so that "unread" propagates through cloud sync by its
/// timestamp instead of being restored by another device's older row.
class ReadProgressRecord {
  const ReadProgressRecord({
    required this.key,
    required this.value,
    required this.utime,
  });

  final String key;
  final String value;
  final String utime;
}

class ReadProgressService extends GetxController
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  static const String readProgressUpdateId = 'readProgress';

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies..addAll([localConfigService]);

  /// A cached null means the key has no persisted progress record. Keeping
  /// that distinction is important because page index 0 is valid progress.
  final Map<String, ReadProgressEntry?> _progressCache = {};

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
  }

  @override
  Future<void> doAfterBeanReady() async {}

  /// Get read progress for a gallery with cache
  Future<int> getReadProgress(int gid) async {
    return getReadProgressByKey(gid.toString());
  }

  /// Get read progress for a namespaced reader-source record.
  Future<int> getReadProgressByKey(String recordKey) async {
    return (await getReadProgressEntryByKey(recordKey))?.pageIndex ?? 0;
  }

  /// Get the complete persisted progress record. A null result means the item
  /// has never been read; an entry with [ReadProgressEntry.pageIndex] 0 means
  /// it has been opened and is currently on its first page.
  Future<ReadProgressEntry?> getReadProgressEntryByKey(String recordKey) async {
    if (_progressCache.containsKey(recordKey)) {
      return _progressCache[recordKey];
    }

    final LocalConfig? record = await localConfigService.readRecord(
      configKey: ConfigEnum.readIndexRecord,
      subConfigKey: recordKey,
    );
    final ReadProgressEntry? entry = _entryFromRecord(record);
    _progressCache[recordKey] = entry;
    return entry;
  }

  /// Load progress for multiple record keys in one database query. Missing
  /// keys are omitted from the returned map and cached as absent.
  Future<Map<String, ReadProgressEntry>> getReadProgressEntriesByKeys(
    Set<String> recordKeys,
  ) async {
    if (recordKeys.isEmpty) {
      return {};
    }

    final Map<String, ReadProgressEntry> result = {};
    final Set<String> uncachedKeys = {};
    for (final String key in recordKeys) {
      if (_progressCache.containsKey(key)) {
        final ReadProgressEntry? cached = _progressCache[key];
        if (cached != null) {
          result[key] = cached;
        }
      } else {
        uncachedKeys.add(key);
      }
    }

    if (uncachedKeys.isEmpty) {
      return result;
    }

    final List<LocalConfig> records = await localConfigService.readBySubKeys(
      configKey: ConfigEnum.readIndexRecord,
      subConfigKeys: uncachedKeys,
    );
    final Set<String> foundKeys = {};
    for (final LocalConfig record in records) {
      foundKeys.add(record.subConfigKey);
      final ReadProgressEntry? entry = _entryFromRecord(record);
      _progressCache[record.subConfigKey] = entry;
      if (entry != null) {
        result[record.subConfigKey] = entry;
      }
    }
    for (final String key in uncachedKeys.difference(foundKeys)) {
      _progressCache[key] = null;
    }
    return result;
  }

  /// Raw stored values, unread markers included, loaded in one query.
  Future<Map<String, ReadProgressRecord>> getProgressRecords(
    Set<String> recordKeys,
  ) async {
    if (recordKeys.isEmpty) {
      return {};
    }
    final List<LocalConfig> records = await localConfigService.readBySubKeys(
      configKey: ConfigEnum.readIndexRecord,
      subConfigKeys: recordKeys,
    );
    return {
      for (final LocalConfig record in records)
        record.subConfigKey: ReadProgressRecord(
          key: record.subConfigKey,
          value: record.value,
          utime: record.utime,
        ),
    };
  }

  /// Clear cache and notify all listeners to rebuild (e.g. after cloud sync)
  void clearCacheAndRefresh() {
    _progressCache.clear();
    update();
  }

  /// Reset read progress by writing the unread marker, and notify listeners
  Future<void> deleteReadProgress(String recordKey) {
    return writeProgressValue(recordKey, '');
  }

  /// Update read progress and notify listeners
  Future<void> updateReadProgress(String recordKey, int index) {
    return writeProgressValue(recordKey, index.toString());
  }

  /// Write a page index or the unread marker ('') with the current time,
  /// mark it for cloud sync and notify listeners.
  Future<void> writeProgressValue(String recordKey, String value) async {
    await localConfigService.write(
      configKey: ConfigEnum.readIndexRecord,
      subConfigKey: recordKey,
      value: value,
    );
    final LocalConfig? record = await localConfigService.readRecord(
      configKey: ConfigEnum.readIndexRecord,
      subConfigKey: recordKey,
    );
    _progressCache[recordKey] = _entryFromRecord(record);
    await pendingSyncTracker.markProgressPending(recordKey);
    _notifyProgressChanged(recordKey);
  }

  /// Batch form of [writeProgressValue]: one write, one sync mark and one
  /// notification. Returns the stored records.
  Future<Map<String, ReadProgressRecord>> writeProgressValues(
    Map<String, String> valuesByKey,
  ) async {
    if (valuesByKey.isEmpty) {
      return {};
    }
    final String utime = SyncTimeUtil.nowIso();
    await localConfigService.batchWrite(
      valuesByKey.entries
          .map(
            (MapEntry<String, String> entry) => LocalConfigCompanion(
              configKey: drift.Value(ConfigEnum.readIndexRecord.key),
              subConfigKey: drift.Value(entry.key),
              value: drift.Value(entry.value),
              utime: drift.Value(utime),
            ),
          )
          .toList(growable: false),
    );
    await pendingSyncTracker.markProgressPendingAll(valuesByKey.keys);
    clearCacheAndRefresh();
    return {
      for (final MapEntry<String, String> entry in valuesByKey.entries)
        entry.key: ReadProgressRecord(
          key: entry.key,
          value: entry.value,
          utime: utime,
        ),
    };
  }

  void _notifyProgressChanged(String recordKey) {
    // Keep the targeted notification used by per-gallery GetBuilders, while
    // also waking aggregate consumers such as the Komga browse page. GetX
    // group updates do not notify listeners registered without an id.
    updateSafely(['$readProgressUpdateId::$recordKey']);
    updateSafely();
  }

  ReadProgressEntry? _entryFromRecord(LocalConfig? record) {
    if (record == null || record.value.isEmpty) {
      return null;
    }
    return ReadProgressEntry(
      key: record.subConfigKey,
      pageIndex: int.tryParse(record.value) ?? 0,
      lastReadAt:
          SyncTimeUtil.tryParse(record.utime) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}
