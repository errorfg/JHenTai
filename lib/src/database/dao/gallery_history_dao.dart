import 'package:drift/drift.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/database/table/gallery_history.dart';

class GalleryHistoryDao {
  static Future<int> selectTotalCount() {
    return appDb.galleryHistoryV2.count().getSingle();
  }

  static Future<List<GalleryHistoryV2Data>> selectAll() {
    return (appDb.select(appDb.galleryHistoryV2)
          ..orderBy([
            (tbl) => OrderingTerm(
                expression: tbl.lastReadTime, mode: OrderingMode.asc),
            (tbl) => OrderingTerm(expression: tbl.gid, mode: OrderingMode.asc),
          ]))
        .get();
  }

  static Future<List<GalleryHistoryV2Data>> selectByPageIndex(
      int pageIndex, int pageSize) {
    return (appDb.select(appDb.galleryHistoryV2)
          ..orderBy([
            (tbl) => OrderingTerm(
                expression: tbl.lastReadTime, mode: OrderingMode.desc),
            (tbl) => OrderingTerm(expression: tbl.gid, mode: OrderingMode.desc),
          ])
          ..limit(pageSize, offset: pageIndex * pageSize))
        .get();
  }

  static Future<int> replaceHistory(GalleryHistoryV2Data history) {
    return appDb.into(appDb.galleryHistoryV2).insertOnConflictUpdate(history);
  }

  static Future<GalleryHistoryV2Data?> selectByGid(int gid) async {
    List<GalleryHistoryV2Data> histories =
        await (appDb.select(appDb.galleryHistoryV2)
              ..where((tbl) => tbl.gid.equals(gid))
              ..limit(1))
            .get();
    return histories.isEmpty ? null : histories.first;
  }

  static Future<bool> existsHistory(int gid) async {
    List<GalleryHistoryV2Data> histories =
        await (appDb.select(appDb.galleryHistoryV2)
              ..where((tbl) => tbl.gid.equals(gid))
              ..limit(1))
            .get();
    return histories.isNotEmpty;
  }

  static Future<void> batchReplaceHistory(
      List<GalleryHistoryV2Data> histories) async {
    if (histories.isEmpty) {
      return;
    }

    return appDb.batch((batch) {
      return batch.insertAllOnConflictUpdate(appDb.galleryHistoryV2, histories);
    });
  }

  /// Upsert that only takes effect when the incoming row is strictly newer.
  /// The comparison runs inside SQLite (requires canonical fixed-width UTC
  /// timestamps so string comparison is chronological), which makes it atomic
  /// with respect to concurrent local writes - unlike a check-then-write in
  /// Dart, a row updated between the check and the write cannot be clobbered.
  static Future<void> batchUpsertIfNewer(
      List<GalleryHistoryV2Data> histories) async {
    if (histories.isEmpty) {
      return;
    }

    return appDb.batch((batch) {
      for (GalleryHistoryV2Data history in histories) {
        batch.insert(
          appDb.galleryHistoryV2,
          history,
          onConflict: DoUpdate<GalleryHistoryV2, GalleryHistoryV2Data>.withExcluded(
            (old, excluded) => GalleryHistoryV2Companion(
              jsonBody: Value(history.jsonBody),
              lastReadTime: Value(history.lastReadTime),
            ),
            where: (old, excluded) =>
                excluded.lastReadTime.isBiggerThan(old.lastReadTime),
          ),
        );
      }
    });
  }

  /// Rows with lastReadTime strictly greater than [lastReadTimeExclusive].
  /// Requires canonical UTC ISO8601 timestamps for string comparison to be
  /// chronological (see HistoryService migration).
  static Future<List<GalleryHistoryV2Data>> selectNewerThan(
      String lastReadTimeExclusive) {
    return (appDb.select(appDb.galleryHistoryV2)
          ..where(
              (tbl) => tbl.lastReadTime.isBiggerThanValue(lastReadTimeExclusive)))
        .get();
  }

  /// Map of gid -> lastReadTime for all rows, without loading json bodies.
  static Future<Map<int, String>> selectGidToLastReadTime() async {
    final query = appDb.selectOnly(appDb.galleryHistoryV2)
      ..addColumns(
          [appDb.galleryHistoryV2.gid, appDb.galleryHistoryV2.lastReadTime]);
    final rows = await query.get();
    return {
      for (var row in rows)
        row.read(appDb.galleryHistoryV2.gid)!:
            row.read(appDb.galleryHistoryV2.lastReadTime)!
    };
  }

  static Future<List<GalleryHistoryV2Data>> selectByGids(List<int> gids) {
    return (appDb.select(appDb.galleryHistoryV2)
          ..where((tbl) => tbl.gid.isIn(gids)))
        .get();
  }

  static Future<String?> selectMaxLastReadTime() async {
    final rows = await (appDb.select(appDb.galleryHistoryV2)
          ..orderBy([
            (tbl) => OrderingTerm(
                expression: tbl.lastReadTime, mode: OrderingMode.desc)
          ])
          ..limit(1))
        .get();
    return rows.isEmpty ? null : rows.first.lastReadTime;
  }

  static Future<int> deleteHistory(int gid) {
    return (appDb.delete(appDb.galleryHistoryV2)
          ..where((tbl) => tbl.gid.equals(gid)))
        .go();
  }

  static Future<int> deleteAllHistory() {
    return appDb.delete(appDb.galleryHistoryV2).go();
  }

  static Future<int> selectTotalCountOld() {
    return appDb.galleryHistory.count().getSingle();
  }

  static Future<List<GalleryHistoryData>> selectLargerThanLastReadTimeAndGidOld(
      String lastReadTime, int limit) {
    return (appDb.select(appDb.galleryHistory)
          ..where((tbl) => tbl.lastReadTime.isBiggerOrEqualValue(lastReadTime))
          ..orderBy([
            (tbl) => OrderingTerm(
                expression: tbl.lastReadTime, mode: OrderingMode.asc),
            (tbl) => OrderingTerm(expression: tbl.gid, mode: OrderingMode.asc),
          ])
          ..limit(limit))
        .get();
  }

  static Future<void> batchDeleteHistoryByGidOld(List<int> gids) {
    return appDb.batch((batch) {
      batch.deleteWhere(appDb.galleryHistory, (tbl) => tbl.gid.isIn(gids));
    });
  }

  static Future<int> deleteAllHistoryOld() {
    return appDb.delete(appDb.galleryHistory).go();
  }
}
