import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/widget/eh_alert_dialog.dart';
import 'package:jhentai/src/widget/eh_context_menu.dart';

import '../../model/gallery.dart';
import '../../model/gallery_history_model.dart';
import '../../service/history_service.dart';
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
    final ({List<GalleryHistoryModel> rows, int pageIndex}) visible = await visibleHistory(pageIndex, pageCount);
    List<Gallery> gallerys = visible.rows.map(galleryHistoryModel2Gallery).toList();

    return [
      gallerys,
      pageCount,
      pageIndex >= 1 ? pageIndex - 1 : null,
      visible.pageIndex < pageCount - 1 ? visible.pageIndex + 1 : null,
    ];
  }

  /// The history entries of page [pageIndex] that are shown: a multi-chapter
  /// JM album is one entry, so the entries earlier versions made for each of
  /// its chapters are left out. They stay stored, as deleting history does
  /// not reach other devices. A page left with nothing to show moves on to
  /// the next; [pageIndex] of the result is the last page read.
  static Future<({List<GalleryHistoryModel> rows, int pageIndex})> visibleHistory(int pageIndex, int pageCount) async {
    final Set<int> hidden = await jmReadingService.chapterGidsOfKnownAlbums();
    int index = pageIndex;
    while (true) {
      final List<GalleryHistoryModel> rows = (await historyService.getByPageIndex(index))
          .where((GalleryHistoryModel row) => !hidden.contains(row.galleryUrl.gid))
          .toList();
      if (rows.isNotEmpty || index >= pageCount - 1) {
        return (rows: rows, pageIndex: index);
      }
      index++;
    }
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
