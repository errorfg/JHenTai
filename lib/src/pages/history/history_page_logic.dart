import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/widget/eh_alert_dialog.dart';
import 'package:jhentai/src/widget/eh_context_menu.dart';

import '../../model/gallery.dart';
import '../../database/dao/gallery_history_dao.dart';
import '../../database/database.dart';
import '../../model/gallery_history_model.dart';
import '../../model/gallery_url.dart';
import '../../service/history_service.dart';
import '../../service/jm_history_merger.dart';
import '../../service/jm_reading_service.dart';
import '../../utils/convert_util.dart';
import '../../service/log.dart';
import '../base/old_base_page_logic.dart';
import 'history_page_state.dart';

class HistoryPageLogic extends OldBasePageLogic {
  @override
  final HistoryPageState state = HistoryPageState();

  @override
  bool get useSearchConfig => false;

  @override
  Future<List<dynamic>> getGallerysAndPageInfoByPage(int pageIndex) async {
    log.info('Get history by page index $pageIndex');

    int pageCount = await historyService.getPageCount();
    final ({List<GalleryHistoryModel> rows, List<GalleryHistoryModel> raw, int pageIndex}) visible =
        await visibleHistory(pageIndex, pageCount);
    List<Gallery> gallerys = visible.rows.map(galleryHistoryModel2Gallery).toList();
    unawaited(_mergeChapterEntries(visible.raw));

    return [
      gallerys,
      pageCount,
      pageIndex >= 1 ? pageIndex - 1 : null,
      visible.pageIndex < pageCount - 1 ? visible.pageIndex + 1 : null,
    ];
  }

  /// Entries made per chapter whose album is not known yet are looked up in
  /// the background; the list is loaded again once some have become one.
  Future<void> _mergeChapterEntries(List<GalleryHistoryModel> raw) async {
    try {
      if (await jmHistoryMerger.resolve(raw) > 0 && !isClosed) {
        await handleRefresh();
      }
    } catch (e, s) {
      log.error('Merge JM chapter entries failed', e, s);
    }
  }

  /// The history entries of page [pageIndex] as shown: a multi-chapter JM
  /// album is one entry, listed where the newest of its entries is, whether
  /// that one was made for the album or (by a version up to 8.0.36) for one
  /// of its chapters; its other entries are left out. They stay stored, as
  /// deleting history does not reach other devices. Whether an entry is the
  /// newest of its album is looked up, not carried from page to page, so
  /// pages loaded in any order (a refresh while a later page loads) list
  /// each album once and none not at all. A page left with nothing
  /// to show moves on to the next; [pageIndex] of the result is the last
  /// page read, and [raw] what was read.
  static Future<({List<GalleryHistoryModel> rows, List<GalleryHistoryModel> raw, int pageIndex})> visibleHistory(
    int pageIndex,
    int pageCount,
  ) async {
    final Map<int, int> albumOf = (await jmReadingService.knownAlbums()).albumOf;
    final Map<int, int?> newestOf = <int, int?>{};
    final List<GalleryHistoryModel> raw = <GalleryHistoryModel>[];
    int index = pageIndex;
    while (true) {
      final List<GalleryHistoryModel> page = await historyService.getByPageIndex(index);
      raw.addAll(page);
      final List<GalleryHistoryModel> rows = <GalleryHistoryModel>[];
      for (final GalleryHistoryModel row in page) {
        final int? album = row.galleryUrl.isJM ? albumOf[row.galleryUrl.jmChapterId] : null;
        if (album == null) {
          rows.add(row);
          continue;
        }
        final int? newest = newestOf.containsKey(album) ? newestOf[album] : (newestOf[album] = await _newestEntryOf(album, albumOf));
        if (newest == row.galleryUrl.gid) {
          // The album's own entry when it has one, else this chapter's.
          rows.add(row.galleryUrl.jmChapterId == album ? row : (await _albumEntry(album)) ?? row);
        }
      }
      if (rows.isNotEmpty || index >= pageCount - 1) {
        return (rows: rows, raw: raw, pageIndex: index);
      }
      index++;
    }
  }

  /// The gid of the newest history entry of album [albumId], its own or one
  /// of its chapters', in the order the history is listed: latest read
  /// first, then the larger gid.
  static Future<int?> _newestEntryOf(int albumId, Map<int, int> albumOf) async {
    final List<int> gids = <int>[
      for (final MapEntry<int, int> entry in albumOf.entries)
        if (entry.value == albumId) GalleryUrl.jm(entry.key).gid,
    ];
    final List<GalleryHistoryV2Data> entries = await GalleryHistoryDao.selectByGids(gids);
    if (entries.isEmpty) {
      return null;
    }
    entries.sort((GalleryHistoryV2Data a, GalleryHistoryV2Data b) {
      final int byTime = b.lastReadTime.compareTo(a.lastReadTime);
      return byTime != 0 ? byTime : b.gid.compareTo(a.gid);
    });
    return entries.first.gid;
  }

  /// The gids of the history entries the entry of [url] stands for: those
  /// of a multi-chapter JM album's chapters and of the album, or [url]'s
  /// alone.
  static Future<List<int>> entriesShownAs(GalleryUrl url) async {
    if (!url.isJM) {
      return <int>[url.storageGid];
    }
    final Map<int, int> albumOf = (await jmReadingService.knownAlbums()).albumOf;
    final int? album = albumOf[url.jmChapterId];
    if (album == null) {
      return <int>[url.storageGid];
    }
    return <int>[
      for (final MapEntry<int, int> entry in albumOf.entries)
        if (entry.value == album) GalleryUrl.jm(entry.key).gid,
    ];
  }

  static Future<GalleryHistoryModel?> _albumEntry(int albumId) async {
    final GalleryHistoryV2Data? stored = await GalleryHistoryDao.selectByGid(GalleryUrl.jm(albumId).gid);
    return stored == null ? null : GalleryHistoryModel.fromJson(jsonDecode(stored.jsonBody));
  }

  Future<void> handleTapDeleteButton() async {
    bool? result = await Get.dialog(EHDialog(title: 'delete'.tr + '?'));

    if (result == true) {
      await historyService.deleteAll();
      handleClearAndRefresh();
    }
  }

  @override
  void handleLongPressCard(BuildContext context, Gallery gallery, {Offset? position}) {
    showEHContextMenu(
      context,
      position: position,
      actions: [
        EHContextMenuAction(
          text: 'delete'.tr,
          color: UIConfig.alertColor(context),
          onTap: () => delete(gallery.galleryUrl),
        ),
      ],
    );
  }

  @override
  void handleSecondaryTapCard(BuildContext context, Gallery gallery, {Offset? position}) {
    handleLongPressCard(context, gallery, position: position);
  }

  /// Deletes what the entry of [url] stands for: a JM album shown as one
  /// entry goes with all its chapters' entries, which would show again
  /// otherwise.
  Future<void> delete(GalleryUrl url) async {
    await historyService.deleteGids(await entriesShownAs(url));
    state.gallerys.removeWhere((g) => g.gid == url.gid);
    updateSafely([bodyId]);
  }
}
