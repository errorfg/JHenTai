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

/// Summary returned by [ReadProgressService.importReadProgressEntries].
///
/// [total] counts valid entries after de-duplicating by key. [imported]
/// counts rows that actually survived the timestamp guard and were present in
/// storage after the write. [skipped] is therefore always `total - imported`.
/// Invalid entries are reported separately and are not included in [total].
class ReadProgressImportResult {
  const ReadProgressImportResult({
    required this.total,
    required this.imported,
    required this.skipped,
    required this.invalid,
  });

  final int total;
  final int imported;
  final int skipped;
  final int invalid;

  bool get isEmpty => total == 0;

  bool get isUpToDate => total > 0 && imported == 0;
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
      final ReadProgressEntry entry = _entryFromRecord(record)!;
      _progressCache[record.subConfigKey] = entry;
      result[record.subConfigKey] = entry;
    }
    for (final String key in uncachedKeys.difference(foundKeys)) {
      _progressCache[key] = null;
    }
    return result;
  }

  /// Import externally sourced progress using the same last-write-wins rule
  /// as cloud progress sync.
  ///
  /// Entries are de-duplicated by key first, keeping the one with the newest
  /// [ReadProgressEntry.lastReadAt]. Existing local rows with the same or a
  /// newer timestamp are never overwritten. All qualifying rows are written
  /// in one guarded batch, then only rows that are confirmed in storage are
  /// marked pending for cloud sync in one operation. Cache listeners are
  /// notified at most once.
  Future<ReadProgressImportResult> importReadProgressEntries(
    Iterable<ReadProgressEntry> entries,
  ) async {
    final Map<String, ReadProgressEntry> newestByKey =
        <String, ReadProgressEntry>{};
    int invalid = 0;

    for (final ReadProgressEntry entry in entries) {
      if (entry.key.trim().isEmpty || entry.pageIndex < 0) {
        invalid++;
        continue;
      }

      final ReadProgressEntry? existing = newestByKey[entry.key];
      if (existing == null || entry.lastReadAt.isAfter(existing.lastReadAt)) {
        newestByKey[entry.key] = entry;
      }
    }

    final int total = newestByKey.length;
    if (total == 0) {
      return ReadProgressImportResult(
        total: 0,
        imported: 0,
        skipped: 0,
        invalid: invalid,
      );
    }

    final List<LocalConfig> localRecords = await localConfigService
        .readBySubKeys(
          configKey: ConfigEnum.readIndexRecord,
          subConfigKeys: newestByKey.keys.toSet(),
        );
    final Map<String, DateTime> localTimes = <String, DateTime>{
      for (final LocalConfig record in localRecords)
        if (SyncTimeUtil.tryParse(record.utime) != null)
          record.subConfigKey: SyncTimeUtil.parse(record.utime),
    };

    final Map<String, ReadProgressEntry> eligible =
        <String, ReadProgressEntry>{};
    for (final MapEntry<String, ReadProgressEntry> candidate
        in newestByKey.entries) {
      final DateTime? localTime = localTimes[candidate.key];
      if (localTime == null || candidate.value.lastReadAt.isAfter(localTime)) {
        eligible[candidate.key] = candidate.value;
      }
    }

    if (eligible.isNotEmpty) {
      await localConfigService.batchWriteIfNewer(
        configKey: ConfigEnum.readIndexRecord,
        localConfigs: eligible.values
            .map(
              (ReadProgressEntry entry) => LocalConfigCompanion(
                configKey: drift.Value(ConfigEnum.readIndexRecord.key),
                subConfigKey: drift.Value(entry.key),
                value: drift.Value(entry.pageIndex.toString()),
                utime: drift.Value(SyncTimeUtil.format(entry.lastReadAt)),
              ),
            )
            .toList(growable: false),
      );
    }

    // Re-read after the atomic SQL guard. A concurrent local read may have
    // produced a newer row after our prefilter; that row must not be counted
    // as imported or marked here (its normal write path marks it pending).
    final List<LocalConfig> persistedRecords = eligible.isEmpty
        ? const <LocalConfig>[]
        : await localConfigService.readBySubKeys(
            configKey: ConfigEnum.readIndexRecord,
            subConfigKeys: eligible.keys.toSet(),
          );
    final Map<String, LocalConfig> persistedByKey = <String, LocalConfig>{
      for (final LocalConfig record in persistedRecords)
        record.subConfigKey: record,
    };
    final Set<String> importedKeys = <String>{};
    for (final MapEntry<String, ReadProgressEntry> candidate
        in eligible.entries) {
      final LocalConfig? persisted = persistedByKey[candidate.key];
      if (persisted != null &&
          persisted.value == candidate.value.pageIndex.toString() &&
          persisted.utime == SyncTimeUtil.format(candidate.value.lastReadAt)) {
        importedKeys.add(candidate.key);
      }
    }

    if (importedKeys.isNotEmpty) {
      await pendingSyncTracker.markProgressPendingAll(importedKeys);
      clearCacheAndRefresh();
    }

    final int imported = importedKeys.length;
    return ReadProgressImportResult(
      total: total,
      imported: imported,
      skipped: total - imported,
      invalid: invalid,
    );
  }

  /// Clear cache and notify all listeners to rebuild (e.g. after cloud sync)
  void clearCacheAndRefresh() {
    _progressCache.clear();
    update();
  }

  /// Delete read progress for a gallery and notify listeners
  Future<void> deleteReadProgress(String recordKey) async {
    await localConfigService.delete(
      configKey: ConfigEnum.readIndexRecord,
      subConfigKey: recordKey,
    );
    _progressCache[recordKey] = null;
    _notifyProgressChanged(recordKey);
  }

  /// Update read progress and notify listeners
  Future<void> updateReadProgress(String recordKey, int index) async {
    await localConfigService.write(
      configKey: ConfigEnum.readIndexRecord,
      subConfigKey: recordKey,
      value: index.toString(),
    );
    final LocalConfig? record = await localConfigService.readRecord(
      configKey: ConfigEnum.readIndexRecord,
      subConfigKey: recordKey,
    );
    _progressCache[recordKey] = _entryFromRecord(record);
    await pendingSyncTracker.markProgressPending(recordKey);
    _notifyProgressChanged(recordKey);
  }

  void _notifyProgressChanged(String recordKey) {
    // Keep the targeted notification used by per-gallery GetBuilders, while
    // also waking aggregate consumers such as the Komga browse page. GetX
    // group updates do not notify listeners registered without an id.
    updateSafely(['$readProgressUpdateId::$recordKey']);
    updateSafely();
  }

  ReadProgressEntry? _entryFromRecord(LocalConfig? record) {
    if (record == null) {
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
