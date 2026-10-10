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

  /// Multi-chapter JM albums already listed, from the first page on.
  final Set<int> _shownAlbums = <int>{};

  @override
  Future<List<dynamic>> getGallerysAndPageInfoByPage(int pageIndex) async {
    log.info('Get history by page index $pageIndex');

    if (pageIndex == 0) {
      _shownAlbums.clear();
    }
    int pageCount = await historyService.getPageCount();
    final ({List<GalleryHistoryModel> rows, List<GalleryHistoryModel> raw, int pageIndex}) visible =
        await visibleHistory(pageIndex, pageCount, shownAlbums: _shownAlbums);
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
  /// deleting history does not reach other devices. [shownAlbums] carries
  /// the albums listed from one page to the next. A page left with nothing
  /// to show moves on to the next; [pageIndex] of the result is the last
  /// page read, and [raw] what was read.
  static Future<({List<GalleryHistoryModel> rows, List<GalleryHistoryModel> raw, int pageIndex})> visibleHistory(
    int pageIndex,
    int pageCount, {
    Set<int>? shownAlbums,
  }) async {
    final Map<int, int> albumOf = (await jmReadingService.knownAlbums()).albumOf;
    final Set<int> shown = shownAlbums ?? <int>{};
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
        } else if (shown.add(album)) {
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
          onTap: () => delete(gallery.gid),
        ),
      ],
    );
  }

  @override
  void handleSecondaryTapCard(BuildContext context, Gallery gallery, {Offset? position}) {
    handleLongPressCard(context, gallery, position: position);
  }

  Future<void> delete(int gid) async {
    await historyService.delete(gid);
    state.gallerys.removeWhere((g) => g.gid == gid);
    updateSafely([bodyId]);
  }
}
