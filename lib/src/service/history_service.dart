import 'dart:convert';

import 'package:jhentai/src/database/dao/gallery_history_dao.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/extension/list_extension.dart';
import 'package:jhentai/src/model/gallery_history_model.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';
import 'jh_service.dart';
import 'log.dart';
import 'sync_service.dart';

HistoryService historyService = HistoryService();

class HistoryService
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  static const String historyUpdateId = 'historyUpdateId';

  static const int pageSize = 100;

  @override
  List<JHLifeCircleBean> get initDependencies =>
      [pathService, log, localConfigService];

  @override
  Future<void> doInitBean() async {}

  @override
  Future<void> doAfterBeanReady() async {
    await _migrateLastReadTimeToUtc();
  }

  /// One-time migration: lastReadTime used to be a local-time string; convert
  /// to canonical UTC ISO8601 so lexicographic order (used by DB sorting and
  /// sync cursors) equals chronological order.
  Future<void> _migrateLastReadTimeToUtc() async {
    String? done = await localConfigService.read(
        configKey: ConfigEnum.migrateHistoryTimeToUtc);
    if (done == 'true') {
      return;
    }

    try {
      Map<int, String> gidToTime =
          await GalleryHistoryDao.selectGidToLastReadTime();
      List<GalleryHistoryV2Data> updates = [];
      for (var entry in gidToTime.entries) {
        if (SyncTimeUtil.isCanonical(entry.value)) {
          continue;
        }
        DateTime? parsed = SyncTimeUtil.tryParse(entry.value);
        if (parsed == null) {
          continue;
        }
        GalleryHistoryV2Data? row =
            await GalleryHistoryDao.selectByGid(entry.key);
        if (row == null) {
          continue;
        }
        updates.add(GalleryHistoryV2Data(
          gid: row.gid,
          jsonBody: row.jsonBody,
          lastReadTime: parsed.toIso8601String(),
        ));
      }

      if (updates.isNotEmpty) {
        for (List<GalleryHistoryV2Data> partition in updates.partition(2000)) {
          await GalleryHistoryDao.batchReplaceHistory(partition);
        }
        log.info(
            'Migrated ${updates.length} history lastReadTime values to UTC');
      }
      await localConfigService.write(
          configKey: ConfigEnum.migrateHistoryTimeToUtc, value: 'true');
    } catch (e) {
      log.error('Migrate history lastReadTime to UTC failed', e);
    }
  }

  Future<int> getPageCount() async {
    int totalCount = await GalleryHistoryDao.selectTotalCount();
    return totalCount == 0 ? 0 : (totalCount - 1) ~/ pageSize + 1;
  }

  Future<List<GalleryHistoryModel>> getByPageIndex(int pageIndex) async {
    List<GalleryHistoryV2Data> historys =
        await GalleryHistoryDao.selectByPageIndex(pageIndex, pageSize);
    return historys
        .map<GalleryHistoryModel>(
            (h) => GalleryHistoryModel.fromJson(jsonDecode(h.jsonBody)))
        .toList();
  }

  Future<List<GalleryHistoryV2Data>> getLatest10000RawHistory() async {
    return appDb.managers.galleryHistoryV2
        .orderBy((o) => o.lastReadTime.desc() & o.gid.desc())
        .limit(10000)
        .get();
  }

  Future<List<GalleryHistoryV2Data>> getAllRawHistory() async {
    return appDb.managers.galleryHistoryV2
        .orderBy((o) => o.lastReadTime.desc() & o.gid.desc())
        .get();
  }

  /// Rows changed after [lastReadTimeExclusive] (canonical UTC ISO8601).
  Future<List<GalleryHistoryV2Data>> getRawHistoryNewerThan(
      String lastReadTimeExclusive) {
    return GalleryHistoryDao.selectNewerThan(lastReadTimeExclusive);
  }

  Future<String?> getMaxLastReadTime() {
    return GalleryHistoryDao.selectMaxLastReadTime();
  }

  Future<void> record(GalleryHistoryModel gallery) async {
    log.trace('Record history: ${gallery.galleryUrl.gid}');

    try {
      bool isNewHistory =
          !await GalleryHistoryDao.existsHistory(gallery.galleryUrl.gid);

      await GalleryHistoryDao.replaceHistory(
        GalleryHistoryV2Data(
          gid: gallery.galleryUrl.gid,
          jsonBody: jsonEncode(gallery),
          lastReadTime: SyncTimeUtil.nowIso(),
        ),
      );

      if (isNewHistory) {
        int totalCount = await GalleryHistoryDao.selectTotalCount();
        syncService.triggerAutoSyncByHistoryCount(totalCount);
      }
    } on Exception catch (e) {
      log.error('Record history failed!', e);
    }
  }

  Future<void> batchRecord(List<GalleryHistoryV2Data> gallerys) async {
    log.trace('Batch record history, size: ${gallerys.length}');

    try {
      for (List<GalleryHistoryV2Data> partition in gallerys.partition(2000)) {
        await GalleryHistoryDao.batchReplaceHistory(partition);
        await Future.delayed(const Duration(milliseconds: 200));
      }
    } on Exception catch (e) {
      log.error('Record history failed!', e);
    }
  }

  /// Write [gallerys] but only rows newer (by lastReadTime) than what is
  /// already stored, or absent locally. Prevents a sync merge computed from a
  /// stale snapshot from rolling back records written concurrently, and skips
  /// the full-table rewrite that used to happen on every sync.
  ///
  /// Returns the number of rows actually written.
  Future<int> batchRecordIfNewer(List<GalleryHistoryV2Data> gallerys) async {
    if (gallerys.isEmpty) {
      return 0;
    }

    try {
      Map<int, String> existing =
          await GalleryHistoryDao.selectGidToLastReadTime();

      List<GalleryHistoryV2Data> newer = [];
      for (GalleryHistoryV2Data incoming in gallerys) {
        String? localTime = existing[incoming.gid];
        if (localTime == null) {
          newer.add(incoming);
          continue;
        }
        DateTime? incomingTime = SyncTimeUtil.tryParse(incoming.lastReadTime);
        DateTime? existingTime = SyncTimeUtil.tryParse(localTime);
        if (incomingTime == null) {
          continue;
        }
        if (existingTime == null || incomingTime.isAfter(existingTime)) {
          newer.add(incoming);
        }
      }

      for (List<GalleryHistoryV2Data> partition in newer.partition(2000)) {
        await GalleryHistoryDao.batchReplaceHistory(partition);
      }
      return newer.length;
    } on Exception catch (e) {
      log.error('Record history failed!', e);
      return 0;
    }
  }

  Future<bool> delete(int gid) async {
    log.info('Delete history: $gid');

    return await GalleryHistoryDao.deleteHistory(gid) > 0;
  }

  Future<bool> deleteAll() async {
    log.info('Delete all historys');
    return await GalleryHistoryDao.deleteAllHistory() > 0;
  }
}
