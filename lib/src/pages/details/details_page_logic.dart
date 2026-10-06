import 'dart:async';
import 'dart:collection';

import 'package:clipboard/clipboard.dart';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/database/dao/archive_dao.dart';
import 'package:jhentai/src/database/dao/gallery_dao.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/mixin/login_required_logic_mixin.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_comment.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_history_model.dart';
import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/network/eh2telegraph_client.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/network/nhentai_api_support.dart';
import 'package:jhentai/src/pages/download/download_base_page.dart';
import 'package:jhentai/src/pages/favorite/favorite_page_logic.dart';
import 'package:jhentai/src/pages/read/read_page_logic.dart';
import 'package:jhentai/src/service/jm_reading_service.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/service/super_resolution_service.dart';
import 'package:jhentai/src/setting/download_setting.dart';
import 'package:jhentai/src/setting/my_tags_setting.dart';
import 'package:jhentai/src/utils/convert_util.dart';
import 'package:jhentai/src/utils/string_uril.dart';
import 'package:jhentai/src/widget/eh_add_tag_dialog.dart';
import 'package:jhentai/src/widget/eh_alert_dialog.dart';
import 'package:jhentai/src/widget/eh_gallery_torrents_dialog.dart';
import 'package:jhentai/src/widget/eh_archive_dialog.dart';
import 'package:jhentai/src/widget/eh_favorite_dialog.dart';
import 'package:jhentai/src/widget/eh_rating_dialog.dart';
import 'package:jhentai/src/widget/eh_gallery_stat_dialog.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/archive_download_service.dart';
import 'package:jhentai/src/service/tag_translation_service.dart';
import 'package:jhentai/src/setting/favorite_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/screen_size_util.dart';
import 'package:jhentai/src/utils/snack_util.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../exception/eh_site_exception.dart';
import '../../mixin/scroll_to_top_logic_mixin.dart';
import '../../mixin/scroll_to_top_state_mixin.dart';
import '../../mixin/update_global_gallery_status_logic_mixin.dart';
import '../../model/gallery_detail.dart';
import '../../model/gallery_image.dart';
import '../../model/gallery_metadata.dart';
import '../../model/gallery_note.dart';
import '../../model/search_config.dart';
import '../../model/tag_set.dart';
import '../../service/history_service.dart';
import '../../service/gallery_download_service.dart';
import '../../service/local_block_rule_service.dart';
import '../../service/nhentai_favorite_service.dart';
import '../../service/jm_favorite_service.dart';
import '../../service/local_source_favorite_service.dart';
import '../../service/wnacg_favorite_service.dart';
import '../../setting/eh_setting.dart';
import '../../setting/preference_setting.dart';
import '../../setting/read_setting.dart';
import '../../setting/site_setting.dart';
import '../../utils/process_util.dart';
import '../../utils/route_util.dart';
import '../../utils/search_util.dart';
import '../../utils/toast_util.dart';
import '../../utils/uuid_util.dart';
import '../../widget/eh_download_dialog.dart';
import '../../widget/eh_download_hh_dialog.dart';
import '../../widget/eh_gallery_history_dialog.dart';
import '../../widget/eh_tag_bottom_sheet.dart';
import '../../widget/eh_tag_dialog.dart';
import '../../widget/jump_page_dialog.dart';
import '../../widget/re_unlock_dialog.dart';
import '../../widget/nhentai_archive_dialog.dart';
import '../../widget/nhentai_related_dialog.dart';
import '../../widget/nhentai_tag_suggestions_dialog.dart';
import 'details_page_state.dart';

class DetailsPageArgument {
  final GalleryUrl galleryUrl;

  final Gallery? gallery;

  final ({GalleryDetail galleryDetails, String apikey})? detailsPageInfo;

  /// A JM chapter picked from the chapter list opens as is; otherwise
  /// opening an album goes on to the chapter being read.
  final bool jmExactChapter;

  const DetailsPageArgument({
    required this.galleryUrl,
    this.gallery,
    this.detailsPageInfo,
    this.jmExactChapter = false,
  });

  @override
  String toString() {
    return 'DetailsPageArgument{galleryUrl: $galleryUrl, gallery: $gallery, detailsPageInfo: $detailsPageInfo}';
  }
}

class DetailsPageLogic extends GetxController
    with
        LoginRequiredMixin,
        Scroll2TopLogicMixin,
        UpdateGlobalGalleryStatusLogicMixin {
  static const String galleryId = 'galleryId';
  static const String uploaderId = 'uploaderId';
  static const String detailsId = 'detailsId';
  static const String metadataId = 'metadataId';
  static const String languageId = 'languageId';
  static const String pageCountId = 'pageCountId';
  static const String ratingId = 'ratingId';
  static const String favoriteId = 'favoriteId';
  static const String readButtonId = 'readButtonId';
  static const String thumbnailsId = 'thumbnailsId';
  static const String thumbnailId = 'thumbnailId';
  static const String loadingStateId = 'fullPageLoadingStateId';
  static const String loadingThumbnailsStateId = 'loadingThumbnailsStateId';

  /// there may be more than one DetailsPages in route stack at same time, eg: tap a link in a comment.
  /// use this param as a 'tag' to get target [DetailsPageLogic] and [DetailsPageState].
  static final List<DetailsPageLogic> _stack = <DetailsPageLogic>[];

  static DetailsPageLogic? get current => _stack.isEmpty ? null : _stack.last;

  final DetailsPageState state = DetailsPageState();

  /// The JM album or chapter this page was opened with, until its first
  /// successful load has moved on to the chapter being read.
  int? _jmEntryId;

  @override
  Scroll2TopStateMixin get scroll2TopState => state;

  DetailsPageLogic() {
    _stack.add(this);
  }

  DetailsPageLogic.preview();

  @override
  void onInit() {
    super.onInit();

    if (Get.arguments is! DetailsPageArgument) {
      return;
    }

    DetailsPageArgument argument = Get.arguments;

    state.galleryUrl = argument.galleryUrl;
    // A JM list entry has the album's title and cover, shown until the
    // details arrive.
    state.gallery = argument.galleryUrl.isNH || argument.galleryUrl.isWN
        ? null
        : argument.gallery;
    state.galleryDetails = argument.detailsPageInfo?.galleryDetails;
    state.apikey = argument.detailsPageInfo?.apikey;
    if (argument.galleryUrl.isJM && !argument.jmExactChapter) {
      _jmEntryId = argument.galleryUrl.jmChapterId;
    }

    _syncNhFavoriteStatus();
    _syncLocalSourceFavoriteStatus();
  }

  @override
  void onReady() async {
    super.onReady();

    if (state.galleryDetails == null || state.apikey == null) {
      getDetails();
    }
  }

  @override
  void onClose() {
    super.onClose();
    _stack.remove(this);
  }

  String get mainTitleText {
    if (state.gallery?.title != null) {
      return state.gallery!.title;
    }

    if (SiteSetting.preferJapaneseTitle.isTrue) {
      return state.galleryDetails?.japaneseTitle ??
          state.galleryDetails?.rawTitle ??
          state.galleryMetadata?.japaneseTitle ??
          state.galleryMetadata?.title ??
          '';
    } else {
      return state.galleryDetails?.rawTitle ??
          state.galleryDetails?.japaneseTitle ??
          state.galleryMetadata?.title ??
          state.galleryMetadata?.japaneseTitle ??
          '';
    }
  }

  String get uploader =>
      state.galleryDetails?.uploader ??
      state.gallery?.uploader ??
      state.galleryMetadata?.uploader ??
      '';

  GalleryUrl get _effectiveGalleryUrl =>
      state.galleryDetails?.galleryUrl ?? state.galleryUrl;

  bool get hasNhentaiOfficialApi =>
      ehRequest.supportsNhentaiOfficialApi(_effectiveGalleryUrl);

  Future<void> getDetails({
    bool refreshPageImmediately = true,
    bool useCacheIfAvailable = true,
  }) async {
    if (state.loadingState == LoadingState.loading) {
      return;
    }

    state.loadingState = LoadingState.loading;
    if (refreshPageImmediately) {
      updateSafely([loadingStateId]);
    }

    log.info('Get gallery details:${state.galleryUrl.url}');

    ({GalleryDetail galleryDetails, String apikey})? detailPageInfo;
    try {
      detailPageInfo = _jmEntryId != null
          ? await _getJmEntryDetails(_jmEntryId!, useCache: useCacheIfAvailable)
          : await _getDetailsWithRedirectAndFallback(
              useCache: useCacheIfAvailable,
            );
    } on DioException catch (e) {
      log.error('Get Gallery Detail Failed', e.errorMsg, e.stackTrace);
      snack('getGalleryDetailFailed'.tr, e.errorMsg ?? '', isShort: true);
      state.loadingState = LoadingState.error;
      if (refreshPageImmediately) {
        updateSafely([loadingStateId]);
      }
      return;
    } on EHSiteException catch (e) {
      if (e.type == EHSiteExceptionType.galleryDeleted) {
        return _handleGalleryDeleted(refreshPageImmediately, e);
      }

      log.error('Get Gallery Detail Failed', e.message);
      snack('getGalleryDetailFailed'.tr, e.message, isShort: true);
      state.loadingState = LoadingState.error;
      if (refreshPageImmediately) {
        updateSafely([loadingStateId]);
      }
      return;
    } catch (e, s) {
      log.error('Get Gallery Detail Failed', e, s);
      snack('getGalleryDetailFailed'.tr, e.toString(), isShort: true);
      state.loadingState = LoadingState.error;
      if (refreshPageImmediately) {
        updateSafely([loadingStateId]);
      }
      return;
    }

    state.galleryDetails = detailPageInfo.galleryDetails;
    state.apikey = detailPageInfo.apikey;
    state.nextPageIndexToLoadThumbnails = 1;
    if (state.galleryUrl.isJM) {
      // Served from the cache the detail request just filled.
      state.jmChapterBundle = await ehRequest.jmSource.bundle(
        state.galleryUrl.jmChapterId,
      );
      // The list entry describes the album; from here on the chapter's own
      // details (its title, pages) are what the page, the reader and
      // downloads use.
      state.gallery = null;
      final JmChapterBundle bundle = state.jmChapterBundle!;
      if (bundle.isMultiChapter) {
        unawaited(
          jmReadingService.remember(
            albumId: bundle.album.id,
            pageCounts: {bundle.chapter.id: bundle.pageCount},
            chapterIds: bundle.album.chapters
                .map((JmChapterRef c) => c.id)
                .toList(),
          ),
        );
      }
    }

    _syncNhFavoriteStatus();
    _syncLocalSourceFavoriteStatus();

    await tagTranslationService.translateTagsIfNeeded(
      state.galleryDetails!.tags,
    );

    _addColor2WatchedTags(state.galleryDetails!.tags);

    state.galleryDetails!.comments = await localBlockRuleService.executeRules(
      state.galleryDetails!.comments,
    );

    state.loadingState = LoadingState.success;
    updateSafely(_judgeUpdateIds());

    SchedulerBinding.instance.scheduleTask(
      () => historyService.record(_historyModel()),
      Priority.animation,
    );
    SchedulerBinding.instance.scheduleTask(
      () => GalleryDao.updateGalleryTags(
        state.galleryDetails!.galleryUrl.gid,
        tagMap2TagString(state.galleryDetails!.tags),
      ),
      Priority.animation,
    );
    SchedulerBinding.instance.scheduleTask(
      () => ArchiveDao.updateArchiveTags(
        state.galleryDetails!.galleryUrl.gid,
        tagMap2TagString(state.galleryDetails!.tags),
      ),
      Priority.animation,
    );
  }

  Future<void> _handleGalleryDeleted(
    bool refreshPageImmediately,
    EHSiteException exception,
  ) async {
    log.trace('Gallery deleted: ${state.galleryUrl.url}, try to get metadata');

    try {
      state.galleryMetadata = await ehRequest
          .requestGalleryMetadata<GalleryMetadata>(
            gid: state.galleryUrl.gid,
            token: state.galleryUrl.token,
            parser: EHSpiderParser.galleryMetadataJson2GalleryMetadata,
          );
    } on DioException catch (e) {
      log.error('Get Gallery Metadata Failed', e.errorMsg);
      snack('getGalleryDetailFailed'.tr, e.errorMsg ?? '', isShort: true);
      state.loadingState = LoadingState.error;
      if (refreshPageImmediately) {
        updateSafely([loadingStateId]);
      }
      return;
    } on EHSiteException catch (e) {
      log.error('Get Gallery Metadata Failed', e.message);
      snack('getGalleryDetailFailed'.tr, e.message, isShort: true);
      state.loadingState = LoadingState.error;
      if (refreshPageImmediately) {
        updateSafely([loadingStateId]);
      }
      return;
    } catch (e, s) {
      log.error('Get Gallery Metadata Failed', e, s);
      snack('getGalleryDetailFailed'.tr, e.toString(), isShort: true);
      state.loadingState = LoadingState.error;
      if (refreshPageImmediately) {
        updateSafely([loadingStateId]);
      }
      return;
    }

    state.copyRighter = exception.message;
    state.nextPageIndexToLoadThumbnails = 1;

    state.loadingState = LoadingState.success;
    updateSafely(_judgeUpdateIds4MetaData());
  }

  Future<void> loadMoreThumbnails() async {
    if (state.loadingThumbnailsState == LoadingState.loading) {
      return;
    }

    /// no more thumbnails
    if (state.nextPageIndexToLoadThumbnails >=
        state.galleryDetails!.thumbnailsPageCount) {
      state.loadingThumbnailsState = LoadingState.noMore;
      updateSafely([loadingThumbnailsStateId]);
      return;
    }

    state.loadingThumbnailsState = LoadingState.loading;
    updateSafely([loadingThumbnailsStateId]);

    List<GalleryThumbnail> newThumbNails;
    try {
      newThumbNails = await ehRequest.requestDetailPage(
        galleryUrl: state.galleryUrl.url,
        thumbnailsPageIndex: state.nextPageIndexToLoadThumbnails,
        parser: EHSpiderParser.detailPage2Thumbnails,
      );
    } on DioException catch (e) {
      log.error('failToGetThumbnails'.tr, e.errorMsg);
      snack('failToGetThumbnails'.tr, e.errorMsg ?? '', isShort: true);
      state.loadingThumbnailsState = LoadingState.error;
      updateSafely([loadingThumbnailsStateId]);
      return;
    } on EHSiteException catch (e) {
      log.error('failToGetThumbnails'.tr, e.message);
      snack('failToGetThumbnails'.tr, e.message, isShort: true);
      state.loadingThumbnailsState = LoadingState.error;
      updateSafely([loadingThumbnailsStateId]);
      return;
    } catch (e, s) {
      log.error('failToGetThumbnails'.tr, e, s);
      snack('failToGetThumbnails'.tr, e.toString(), isShort: true);
      state.loadingThumbnailsState = LoadingState.error;
      updateSafely([loadingThumbnailsStateId]);
      return;
    }

    state.galleryDetails!.thumbnails.addAll(newThumbNails);
    state.nextPageIndexToLoadThumbnails++;

    state.loadingThumbnailsState = LoadingState.idle;
    updateSafely([thumbnailsId]);
  }

  Future<void> handleRefresh() async {
    return getDetails(
      refreshPageImmediately: false,
      useCacheIfAvailable: false,
    );
  }

  Future<void> handleTapDownload() async {
    GalleryDownloadedData? galleryDownloadedData = galleryDownloadService
        .gallerys
        .singleWhereOrNull((g) => g.gid == state.galleryUrl.gid);
    GalleryDownloadProgress? downloadProgress = galleryDownloadService
        .galleryDownloadInfos[state.galleryUrl.gid]
        ?.downloadProgress;

    /// new download
    if (galleryDownloadedData == null || downloadProgress == null) {
      ({String group, bool downloadOriginalImage})? result = await Get.dialog(
        EHDownloadDialog(
          title: 'chooseGroup'.tr,
          currentGroup: downloadSetting.defaultGalleryGroup.value,
          candidates: galleryDownloadService.allGroups,
          showDownloadOriginalImageCheckBox: userSetting.hasLoggedIn(),
          downloadOriginalImage: downloadSetting.downloadOriginalImageByDefault.value,
          preferredGroups: downloadSetting.preferredGalleryGroups,
        ),
      );

      if (result == null) {
        return;
      }

      if (state.gallery == null && state.galleryDetails == null) {
        return;
      }

      unawaited(downloadSetting.saveRecentGalleryGroup(result.group));

      GalleryDownloadedData galleryDownloadedData = GalleryDownloadedData(
        gid:
            state.galleryDetails?.galleryUrl.gid ??
            state.gallery!.galleryUrl.gid,
        token:
            state.galleryDetails?.galleryUrl.token ??
            state.gallery!.galleryUrl.token,
        title: mainTitleText,
        category: state.galleryDetails?.category ?? state.gallery!.category,
        pageCount: state.galleryDetails?.pageCount ?? state.gallery!.pageCount!,
        galleryUrl:
            state.galleryDetails?.galleryUrl.url ??
            state.gallery!.galleryUrl.url,
        uploader: state.galleryDetails?.uploader ?? state.gallery?.uploader,
        publishTime:
            state.galleryDetails?.publishTime ?? state.gallery!.publishTime,
        downloadStatusIndex: DownloadStatus.downloading.index,
        downloadOriginalImage: result.downloadOriginalImage,
        sortOrder: 0,
        groupName: result.group,
        insertTime: DateTime.now().toString(),
        priority: GalleryDownloadService.defaultDownloadGalleryPriority,
        tags: state.galleryDetails != null
            ? tagMap2TagString(state.galleryDetails!.tags)
            : tagMap2TagString(state.gallery!.tags),
        tagRefreshTime: DateTime.now().toString(),
      );
      galleryDownloadService.downloadGallery(galleryDownloadedData);

      updateGlobalGalleryStatus();

      toast(
        '${'beginToDownload'.tr}： ${state.galleryUrl.gid}',
        isCenter: false,
      );
      return;
    }

    if (downloadProgress.downloadStatus == DownloadStatus.paused) {
      galleryDownloadService.resumeDownloadGallery(galleryDownloadedData);
      toast('${'resume'.tr}： ${state.galleryUrl.gid}', isCenter: false);
      return;
    } else if (downloadProgress.downloadStatus == DownloadStatus.downloading) {
      galleryDownloadService.pauseDownloadGallery(galleryDownloadedData);
      toast('${'pause'.tr}： ${state.galleryUrl.gid}', isCenter: false);
    } else if (downloadProgress.downloadStatus == DownloadStatus.downloaded &&
        state.galleryDetails?.newVersionGalleryUrl == null) {
      goToReadPage();
    } else if (downloadProgress.downloadStatus == DownloadStatus.downloaded &&
        state.galleryDetails?.newVersionGalleryUrl != null) {
      galleryDownloadService.updateGallery(
        galleryDownloadedData,
        state.galleryDetails!.newVersionGalleryUrl!,
      );
      toast('${'update'.tr}： ${state.galleryUrl.gid}', isCenter: false);
    }
  }

  Future<void> handleTapFavorite({required bool useDefault}) async {
    if (state.galleryUrl.isNH) {
      return _handleTapNhentaiFavorite(useDefault: useDefault);
    }
    if (_localSourceFavoriteService != null) {
      return _handleTapLocalSourceFavorite(useDefault: useDefault);
    }

    if (!checkLogin()) {
      return;
    }

    if (state.favoriteState == LoadingState.loading) {
      return;
    }

    if (!favoriteSetting.inited) {
      favoriteSetting.fetchDataFromEH();
    }

    int? currentFavIndex =
        state.galleryDetails?.favoriteTagIndex ??
        state.gallery?.favoriteTagIndex;

    ({bool isDelete, int favIndex, String note, bool remember}) operation;
    if (useDefault && userSetting.defaultFavoriteIndex.value != null) {
      state.favoriteState = LoadingState.loading;
      updateSafely([favoriteId]);

      /// need to get current favorite note if we have favorite this gallery and we are not unfavoriting it.
      GalleryNote? galleryNote;
      if (currentFavIndex != null &&
          currentFavIndex != userSetting.defaultFavoriteIndex.value) {
        log.info('Get gallery favorite info: ${state.galleryUrl.gid}');
        try {
          galleryNote = await ehRequest.requestPopupPage<GalleryNote>(
            state.galleryUrl.gid,
            state.galleryUrl.token,
            'addfav',
            EHSpiderParser.favoritePopup2GalleryNote,
          );
        } on DioException catch (e) {
          log.error('getGalleryFavoriteInfoFailed'.tr, e.errorMsg);
          snack(
            'getGalleryFavoriteInfoFailed'.tr,
            e.errorMsg ?? '',
            isShort: true,
          );
          state.favoriteState = LoadingState.error;
          updateSafely([favoriteId]);
          return;
        } on EHSiteException catch (e) {
          log.error('getGalleryFavoriteInfoFailed'.tr, e.message);
          snack('getGalleryFavoriteInfoFailed'.tr, e.message, isShort: true);
          state.favoriteState = LoadingState.error;
          updateSafely([favoriteId]);
          return;
        } catch (e, s) {
          log.error('getGalleryFavoriteInfoFailed'.tr, e, s);
          snack('getGalleryFavoriteInfoFailed'.tr, e.toString(), isShort: true);
          state.favoriteState = LoadingState.error;
          updateSafely([favoriteId]);
          return;
        }
      }

      operation = (
        isDelete: currentFavIndex == userSetting.defaultFavoriteIndex.value,
        favIndex: userSetting.defaultFavoriteIndex.value!,
        note: galleryNote?.note ?? '',
        remember: false,
      );
    } else {
      /// we need to get current favorite note after opening the dialog if we have favorite this gallery.
      ({bool isDelete, int favIndex, String note, bool remember})? result =
          await Get.dialog(
            EHFavoriteDialog(
              selectedIndex: currentFavIndex,
              needInitNote: currentFavIndex != null,
              initNoteFuture: () => ehRequest.requestPopupPage<GalleryNote>(
                state.galleryUrl.gid,
                state.galleryUrl.token,
                'addfav',
                EHSpiderParser.favoritePopup2GalleryNote,
              ),
            ),
          );

      if (result == null) {
        return;
      }

      operation = result;
      state.favoriteState = LoadingState.loading;
      updateSafely([favoriteId]);
    }

    if (operation.remember == true) {
      userSetting.saveDefaultFavoriteIndex(operation.favIndex);
    }

    log.info('Favorite gallery: ${state.galleryUrl.gid}');

    try {
      if (operation.isDelete) {
        await ehRequest.requestRemoveFavorite(
          state.galleryUrl.gid,
          state.galleryUrl.token,
        );
        favoriteSetting.decrementFavByIndex(operation.favIndex);
        state.gallery
          ?..favoriteTagIndex = null
          ..favoriteTagName = null;
        state.galleryDetails
          ?..favoriteTagIndex = null
          ..favoriteTagName = null;
      } else {
        await ehRequest.requestAddFavorite(
          state.galleryUrl.gid,
          state.galleryUrl.token,
          operation.favIndex,
          operation.note,
        );
        favoriteSetting.incrementFavByIndex(operation.favIndex);
        favoriteSetting.decrementFavByIndex(currentFavIndex);
        state.gallery
          ?..favoriteTagIndex = operation.favIndex
          ..favoriteTagName =
              favoriteSetting.favoriteTagNames[operation.favIndex];
        state.galleryDetails
          ?..favoriteTagIndex = operation.favIndex
          ..favoriteTagName =
              favoriteSetting.favoriteTagNames[operation.favIndex];
      }
    } on DioException catch (e) {
      log.error(
        operation.isDelete
            ? 'removeFavoriteFailed'.tr
            : 'favoriteGalleryFailed'.tr,
        e.errorMsg,
      );
      snack(
        operation.isDelete
            ? 'removeFavoriteFailed'.tr
            : 'favoriteGalleryFailed'.tr,
        e.errorMsg ?? '',
        isShort: true,
      );
      state.favoriteState = LoadingState.error;
      updateSafely([favoriteId]);
      return;
    } on EHSiteException catch (e) {
      log.error(
        operation.isDelete
            ? 'removeFavoriteFailed'.tr
            : 'favoriteGalleryFailed'.tr,
        e.message,
      );
      snack(
        operation.isDelete
            ? 'removeFavoriteFailed'.tr
            : 'favoriteGalleryFailed'.tr,
        e.message,
        isShort: true,
      );
      state.favoriteState = LoadingState.error;
      updateSafely([favoriteId]);
      return;
    } catch (e, s) {
      log.error(
        operation.isDelete
            ? 'removeFavoriteFailed'.tr
            : 'favoriteGalleryFailed'.tr,
        e,
        s,
      );
      snack(
        operation.isDelete
            ? 'removeFavoriteFailed'.tr
            : 'favoriteGalleryFailed'.tr,
        e.toString(),
        isShort: true,
      );
      state.favoriteState = LoadingState.error;
      updateSafely([favoriteId]);
      return;
    }

    removeCache();

    state.favoriteState = LoadingState.idle;
    updateSafely([favoriteId]);

    updateGlobalGalleryStatus();

    toast(
      operation.isDelete
          ? 'removeFavoriteSuccess'.tr
          : 'favoriteGallerySuccess'.tr,
      isCenter: false,
    );
  }

  Future<void> _handleTapNhentaiFavorite({required bool useDefault}) async {
    if (hasNhentaiOfficialApi) {
      return _handleTapNhentaiRemoteFavorite();
    }

    if (state.favoriteState == LoadingState.loading) {
      return;
    }

    Gallery? gallerySnapshot = _getNhFavoriteGallerySnapshot();
    if (gallerySnapshot == null) {
      return;
    }

    int? currentFavIndex = nhentaiFavoriteService.getFavoriteCategoryIndex(
      state.galleryUrl.gid,
    );
    ({bool isDelete, int favIndex, String note, bool remember}) operation;

    if (useDefault && userSetting.defaultFavoriteIndex.value != null) {
      operation = (
        isDelete: currentFavIndex == userSetting.defaultFavoriteIndex.value,
        favIndex: userSetting.defaultFavoriteIndex.value!,
        note: '',
        remember: false,
      );
    } else {
      ({bool isDelete, int favIndex, String note, bool remember})? result =
          await Get.dialog(
            EHFavoriteDialog(
              selectedIndex: currentFavIndex,
              needInitNote: false,
            ),
          );
      if (result == null) {
        return;
      }
      operation = result;
    }

    if (operation.remember == true) {
      userSetting.saveDefaultFavoriteIndex(operation.favIndex);
    }

    state.favoriteState = LoadingState.loading;
    updateSafely([favoriteId]);

    try {
      if (operation.isDelete) {
        await nhentaiFavoriteService.removeFavorite(state.galleryUrl.gid);
        _applyNhFavoriteStatus(favoriteCategoryIndex: null);
      } else {
        await nhentaiFavoriteService.addFavorite(
          gallerySnapshot,
          favoriteCategoryIndex: operation.favIndex,
        );
        _applyNhFavoriteStatus(favoriteCategoryIndex: operation.favIndex);
      }
    } catch (e, s) {
      log.error(
        operation.isDelete
            ? 'removeFavoriteFailed'.tr
            : 'favoriteGalleryFailed'.tr,
        e,
        s,
      );
      snack(
        operation.isDelete
            ? 'removeFavoriteFailed'.tr
            : 'favoriteGalleryFailed'.tr,
        e.toString(),
        isShort: true,
      );
      state.favoriteState = LoadingState.error;
      updateSafely([favoriteId]);
      return;
    }

    if (Get.isRegistered<FavoritePageLogic>()) {
      await Get.find<FavoritePageLogic>().reloadNhentaiFavoriteGallerys();
    }

    state.favoriteState = LoadingState.idle;
    updateSafely([favoriteId]);

    updateGlobalGalleryStatus();

    toast(
      operation.isDelete
          ? 'removeFavoriteSuccess'.tr
          : 'favoriteGallerySuccess'.tr,
      isCenter: false,
    );
  }

  Future<void> _handleTapNhentaiRemoteFavorite() async {
    if (state.favoriteState == LoadingState.loading) {
      return;
    }

    bool wasFavorite =
        state.galleryDetails?.favoriteTagIndex != null ||
        state.gallery?.favoriteTagIndex != null;
    state.favoriteState = LoadingState.loading;
    updateSafely([favoriteId]);

    try {
      ({bool favorited, int? numFavorites}) result = await ehRequest
          .requestNhSetFavorite(state.galleryUrl.gid, favorited: !wasFavorite);
      state.gallery
        ?..favoriteTagIndex = result.favorited ? 0 : null
        ..favoriteTagName = null;
      state.galleryDetails
        ?..favoriteTagIndex = result.favorited ? 0 : null
        ..favoriteTagName = null;
      if (state.galleryDetails != null) {
        state.galleryDetails!.favoriteCount =
            result.numFavorites ??
            (state.galleryDetails!.favoriteCount + (result.favorited ? 1 : -1))
                .clamp(0, 1 << 31)
                .toInt();
      }
    } on DioException catch (e) {
      log.error('Update nhentai favorite failed', e.errorMsg);
      snack(
        wasFavorite ? 'removeFavoriteFailed'.tr : 'favoriteGalleryFailed'.tr,
        e.errorMsg ?? '',
        isShort: true,
      );
      state.favoriteState = LoadingState.error;
      updateSafely([favoriteId]);
      return;
    } catch (e, s) {
      log.error('Update nhentai favorite failed', e, s);
      snack(
        wasFavorite ? 'removeFavoriteFailed'.tr : 'favoriteGalleryFailed'.tr,
        e.toString(),
        isShort: true,
      );
      state.favoriteState = LoadingState.error;
      updateSafely([favoriteId]);
      return;
    }

    if (Get.isRegistered<FavoritePageLogic>()) {
      await Get.find<FavoritePageLogic>().reloadNhentaiFavoriteGallerys();
    }
    state.favoriteState = LoadingState.idle;
    updateSafely([favoriteId, detailsId]);
    updateGlobalGalleryStatus();
    toast(
      wasFavorite ? 'removeFavoriteSuccess'.tr : 'favoriteGallerySuccess'.tr,
      isCenter: false,
    );
  }

  Gallery? _getNhFavoriteGallerySnapshot() {
    if (state.gallery != null) {
      return state.gallery;
    }

    if (state.galleryDetails != null) {
      return state.galleryDetails!.toGallery();
    }

    return null;
  }

  void _syncNhFavoriteStatus() {
    if (!state.galleryUrl.isNH) {
      return;
    }

    if (hasNhentaiOfficialApi) {
      return;
    }

    _applyNhFavoriteStatus(
      favoriteCategoryIndex: nhentaiFavoriteService.getFavoriteCategoryIndex(
        state.galleryUrl.gid,
      ),
    );
  }

  /// Favorites of wnacg and JM galleries live on the device.
  LocalSourceFavoriteService? get _localSourceFavoriteService =>
      state.galleryUrl.isWN
      ? wnacgFavoriteService
      : state.galleryUrl.isJM
      ? jmFavoriteService
      : null;

  void _syncLocalSourceFavoriteStatus() {
    LocalSourceFavoriteService? service = _localSourceFavoriteService;
    if (service == null) {
      return;
    }

    _applyLocalFavoriteStatus(
      favoriteCategoryIndex: service.getFavoriteCategoryIndex(
        state.galleryUrl.gid,
      ),
    );
  }

  Future<void> _handleTapLocalSourceFavorite({required bool useDefault}) async {
    LocalSourceFavoriteService service = _localSourceFavoriteService!;

    if (state.favoriteState == LoadingState.loading) {
      return;
    }

    Gallery? gallerySnapshot = _getLocalFavoriteGallerySnapshot();
    if (gallerySnapshot == null) {
      return;
    }

    int? currentFavIndex = service.getFavoriteCategoryIndex(
      state.galleryUrl.gid,
    );
    ({bool isDelete, int favIndex, String note, bool remember}) operation;

    if (useDefault && userSetting.defaultFavoriteIndex.value != null) {
      operation = (
        isDelete: currentFavIndex == userSetting.defaultFavoriteIndex.value,
        favIndex: userSetting.defaultFavoriteIndex.value!,
        note: '',
        remember: false,
      );
    } else {
      ({bool isDelete, int favIndex, String note, bool remember})? result =
          await Get.dialog(
            EHFavoriteDialog(
              selectedIndex: currentFavIndex,
              needInitNote: false,
            ),
          );
      if (result == null) {
        return;
      }
      operation = result;
    }

    if (operation.remember == true) {
      userSetting.saveDefaultFavoriteIndex(operation.favIndex);
    }

    state.favoriteState = LoadingState.loading;
    updateSafely([favoriteId]);

    try {
      if (operation.isDelete) {
        await service.removeFavorite(state.galleryUrl.gid);
        _applyLocalFavoriteStatus(favoriteCategoryIndex: null);
      } else {
        await service.addFavorite(
          gallerySnapshot,
          favoriteCategoryIndex: operation.favIndex,
        );
        _applyLocalFavoriteStatus(favoriteCategoryIndex: operation.favIndex);
      }
    } catch (e, s) {
      log.error(
        operation.isDelete
            ? 'removeFavoriteFailed'.tr
            : 'favoriteGalleryFailed'.tr,
        e,
        s,
      );
      snack(
        operation.isDelete
            ? 'removeFavoriteFailed'.tr
            : 'favoriteGalleryFailed'.tr,
        e.toString(),
        isShort: true,
      );
      state.favoriteState = LoadingState.error;
      updateSafely([favoriteId]);
      return;
    }

    if (Get.isRegistered<FavoritePageLogic>()) {
      await Get.find<FavoritePageLogic>().reloadLocalSourceFavoriteGallerys();
    }

    state.favoriteState = LoadingState.idle;
    updateSafely([favoriteId]);

    updateGlobalGalleryStatus();

    toast(
      operation.isDelete
          ? 'removeFavoriteSuccess'.tr
          : 'favoriteGallerySuccess'.tr,
      isCenter: false,
    );
  }

  Gallery? _getLocalFavoriteGallerySnapshot() {
    if (state.gallery != null) {
      return state.gallery;
    }

    if (state.galleryDetails != null) {
      return state.galleryDetails!.toGallery();
    }

    return null;
  }

  void _applyLocalFavoriteStatus({required int? favoriteCategoryIndex}) {
    String? favoriteTagName;
    if (favoriteCategoryIndex != null &&
        favoriteCategoryIndex >= 0 &&
        favoriteCategoryIndex < favoriteSetting.favoriteTagNames.length) {
      favoriteTagName = favoriteSetting.favoriteTagNames[favoriteCategoryIndex];
    }

    state.gallery
      ?..favoriteTagIndex = favoriteCategoryIndex
      ..favoriteTagName = favoriteTagName;
    state.galleryDetails
      ?..favoriteTagIndex = favoriteCategoryIndex
      ..favoriteTagName = favoriteTagName;
  }

  void _applyNhFavoriteStatus({required int? favoriteCategoryIndex}) {
    String? favoriteTagName;
    if (favoriteCategoryIndex != null &&
        favoriteCategoryIndex >= 0 &&
        favoriteCategoryIndex < favoriteSetting.favoriteTagNames.length) {
      favoriteTagName = favoriteSetting.favoriteTagNames[favoriteCategoryIndex];
    }

    state.gallery
      ?..favoriteTagIndex = favoriteCategoryIndex
      ..favoriteTagName = favoriteTagName;
    state.galleryDetails
      ?..favoriteTagIndex = favoriteCategoryIndex
      ..favoriteTagName = favoriteTagName;
  }

  Future<void> handleTapRating() async {
    if (state.galleryUrl.isNH ||
        state.galleryUrl.isWN ||
        state.galleryUrl.isJM) {
      return;
    }

    if (state.apikey == null) {
      return;
    }
    if (state.galleryDetails?.rating == null && state.gallery?.rating == null) {
      return;
    }

    if (!checkLogin()) {
      return;
    }

    double? rating = await Get.dialog(
      EHRatingDialog(
        rating: state.galleryDetails?.rating ?? state.gallery!.rating,
        hasRated: state.galleryDetails?.hasRated ?? state.gallery!.hasRated,
      ),
    );

    if (rating == null) {
      return;
    }

    log.info('Rate gallery: ${state.galleryUrl.gid}, rating: $rating');

    state.ratingState = LoadingState.loading;
    updateSafely([ratingId]);

    Map<String, dynamic> ratingInfo;
    try {
      ratingInfo = await ehRequest.requestSubmitRating(
        state.galleryUrl.gid,
        state.galleryUrl.token,
        userSetting.ipbMemberId.value!,
        state.apikey!,
        (rating * 2).toInt(),
        EHSpiderParser.galleryRatingResponse2RatingInfo,
      );
    } on DioException catch (e) {
      log.error('ratingFailed'.tr, e.errorMsg);
      snack('ratingFailed'.tr, e.errorMsg ?? '');
      state.ratingState = LoadingState.error;
      updateSafely([ratingId]);
      return;
    } on EHSiteException catch (e) {
      log.error('ratingFailed'.tr, e.message);
      snack('ratingFailed'.tr, e.message);
      state.ratingState = LoadingState.error;
      updateSafely([ratingId]);
      return;
    } on FormatException catch (_) {
      /// expired apikey
      await DetailsPageLogic.current!.handleRefresh();
      return handleTapRating();
    } catch (e, s) {
      log.error('ratingFailed'.tr, e, s);
      snack('ratingFailed'.tr, e.toString());
      state.ratingState = LoadingState.error;
      updateSafely([ratingId]);
      return;
    }

    /// eg: {"rating_avg":0.93000000000000005,"rating_usr":0.5,"rating_cnt":21,"rating_cls":"ir irr"}
    state.gallery?.hasRated = true;
    state.gallery?.rating = ratingInfo['rating_usr'];
    state.galleryDetails?.hasRated = true;
    state.galleryDetails?.rating = ratingInfo['rating_usr'];
    state.galleryDetails?.realRating = ratingInfo['rating_avg'];
    state.galleryDetails?.ratingCount = ratingInfo['rating_cnt'];

    removeCache();

    state.ratingState = LoadingState.idle;
    updateSafely();

    updateGlobalGalleryStatus();

    toast('ratingSuccess'.tr, isCenter: false);
  }

  Future<void> handleTapArchive(BuildContext context) async {
    if (state.galleryUrl.isWN ||
        state.galleryUrl.isJM ||
        (state.galleryUrl.isNH && !hasNhentaiOfficialApi)) {
      return;
    }

    ArchiveStatus? archiveStatus = archiveDownloadService
        .archiveDownloadInfos[state.galleryUrl.gid]
        ?.archiveStatus;

    /// new download
    if (archiveStatus == null) {
      if (state.galleryUrl.isNH) {
        String initialGroup =
            downloadSetting.defaultArchiveGroup.value ??
            archiveDownloadService.allGroups.firstOrNull ??
            'default'.tr;
        List<String> groups = List<String>.of(archiveDownloadService.allGroups);
        if (!groups.contains(initialGroup)) {
          groups.insert(0, initialGroup);
        }
        NHentaiArchiveDialogResult? result =
            await Get.dialog<NHentaiArchiveDialogResult>(
              NHentaiArchiveDialog(
                currentGroup: initialGroup,
                candidates: groups,
              ),
            );
        if (result == null || state.galleryDetails == null) {
          return;
        }

        ArchiveDownloadedData archive = ArchiveDownloadedData(
          gid: state.galleryDetails!.galleryUrl.gid,
          token: state.galleryDetails!.galleryUrl.token,
          title: mainTitleText,
          category: state.galleryDetails!.category,
          pageCount: state.galleryDetails!.pageCount,
          galleryUrl: state.galleryDetails!.galleryUrl.url,
          uploader: state.galleryDetails!.uploader,
          size: 0,
          coverUrl: state.galleryDetails!.cover.url,
          publishTime: state.galleryDetails!.publishTime,
          archiveStatusCode: ArchiveStatus.unlocking.code,
          archivePageUrl: Uri.https(
            NHentaiApiSupport.officialHost,
            '/api/v2/galleries/${state.galleryDetails!.galleryUrl.gid}/download',
            {'format': result.format},
          ).toString(),
          isOriginal: true,
          insertTime: DateTime.now().toString(),
          sortOrder: 0,
          groupName: result.group,
          tags: tagMap2TagString(state.galleryDetails!.tags),
          tagRefreshTime: DateTime.now().toString(),
          parseSource: ArchiveParseSource.official.code,
        );
        archiveDownloadService.downloadArchive(archive);
        updateGlobalGalleryStatus();
        toast(
          '${'beginToDownloadArchive'.tr}:  ${archive.title}',
          isCenter: false,
        );
        return;
      }

      if (!userSetting.hasLoggedIn()) {
        showLoginToast();
        return;
      }

      ({bool useBot, bool isOriginal, int size, String group})? result = await Get.dialog(
        EHArchiveDialog(
          title: 'chooseArchive'.tr,
          gid: state.galleryDetails!.galleryUrl.gid,
          token: state.galleryDetails!.galleryUrl.token,
          archivePageUrl: state.galleryDetails!.archivePageUrl,
          currentGroup: downloadSetting.defaultArchiveGroup.value,
          candidates: archiveDownloadService.allGroups,
        ),
      );
      if (result == null) {
        return;
      }

      ArchiveDownloadedData archive = ArchiveDownloadedData(
        gid: state.galleryDetails!.galleryUrl.gid,
        token: state.galleryDetails!.galleryUrl.token,
        title: mainTitleText,
        category: state.galleryDetails!.category,
        pageCount: state.galleryDetails!.pageCount,
        galleryUrl: state.galleryDetails!.galleryUrl.url,
        uploader: state.galleryDetails!.uploader,
        size: result.size,
        coverUrl: state.galleryDetails!.cover.url,
        publishTime: state.galleryDetails!.publishTime,
        archiveStatusCode: ArchiveStatus.unlocking.code,
        archivePageUrl: state.galleryDetails!.archivePageUrl,
        isOriginal: result.isOriginal,
        insertTime: DateTime.now().toString(),
        sortOrder: 0,
        groupName: result.group,
        tags: state.galleryDetails != null
            ? tagMap2TagString(state.galleryDetails!.tags)
            : tagMap2TagString(state.gallery!.tags),
        tagRefreshTime: DateTime.now().toString(),
        parseSource: result.useBot
            ? ArchiveParseSource.bot.code
            : ArchiveParseSource.official.code,
      );
      archiveDownloadService.downloadArchive(archive);

      updateGlobalGalleryStatus();

      log.info('${'beginToDownloadArchive'.tr}: ${archive.title}');
      toast(
        '${'beginToDownloadArchive'.tr}:  ${archive.title}',
        isCenter: false,
      );
      return;
    }

    ArchiveDownloadedData archive = archiveDownloadService.archives.firstWhere(
      (a) => a.gid == state.galleryUrl.gid,
    );

    if (archiveStatus == ArchiveStatus.needReUnlock) {
      bool? ok = await showDialog(
        context: context,
        builder: (_) => const ReUnlockDialog(),
      );
      if (ok ?? false) {
        await archiveDownloadService.cancelArchive(archive.gid);
        await archiveDownloadService.downloadArchive(
          archive,
          resume: true,
          reParse: true,
        );
      }
      return;
    }

    if (archiveStatus == ArchiveStatus.paused) {
      return archiveDownloadService.resumeDownloadArchive(archive.gid);
    }

    if (ArchiveStatus.unlocking.code <= archiveStatus.code &&
        archiveStatus.code < ArchiveStatus.downloaded.code) {
      return archiveDownloadService.pauseDownloadArchive(archive.gid);
    }

    if (archiveStatus == ArchiveStatus.completed) {
      List<GalleryImage> images = await archiveDownloadService
          .getUnpackedImages(archive.gid);

      ReadDirection? readDirection = isWebtoonGalleryFromTagString(archive.tags) ? ReadDirection.top2bottomList : null;

      toRoute(
        Routes.read,
        arguments: ReadPageInfo(
          mode: ReadMode.archive,
          gid: archive.gid,
          token: archive.token,
          galleryTitle: archive.title,
          galleryUrl: archive.galleryUrl,
          initialIndex: await getReadIndexRecord(),
          pageCount: images.length,
          isOriginal: archive.isOriginal,
          readProgressRecordStorageKey: archive.gid.toString(),
          images: images,
          useSuperResolution: superResolutionService.get(archive.gid, SuperResolutionType.archive) != null,
          readDirection: readDirection,
        ),
      );
    }
  }

  Future<void> handleTapHH() async {
    if (state.galleryUrl.isNH ||
        state.galleryUrl.isWN ||
        state.galleryUrl.isJM) {
      return;
    }

    if (!userSetting.hasLoggedIn()) {
      showLoginToast();
      return;
    }

    String? resolution = await Get.dialog(
      EHDownloadHHDialog(archivePageUrl: state.galleryDetails!.archivePageUrl),
    );
    if (resolution == null) {
      return;
    }

    log.info('HH Download: ${state.galleryUrl.gid}, resolution: $resolution');

    String result;
    try {
      result = await ehRequest.requestHHDownload(
        url: state.galleryDetails!.archivePageUrl,
        resolution: resolution,
        parser: EHSpiderParser.downloadHHPage2Result,
      );
    } on DioException catch (e) {
      log.error('H@H download error', e.errorMsg);
      snack('failed'.tr, e.errorMsg ?? '');
      return;
    } on EHSiteException catch (e) {
      log.error('H@H download error', e.message);
      snack('failed'.tr, e.message);
      return;
    } catch (e, s) {
      log.error('H@H download error', e, s);
      snack('failed'.tr, e.toString());
      return;
    }

    toast(result, isShort: false);
  }

  void searchSimilar() {
    if ((state.galleryUrl.isJM ||
            (state.galleryUrl.isNH && hasNhentaiOfficialApi)) &&
        (state.galleryDetails?.relatedGallerys.isNotEmpty ?? false)) {
      Get.dialog(
        NHentaiRelatedDialog(
          gallerys: state.galleryDetails!.relatedGallerys,
          onTap: (gallery) {
            Get.back();
            toRoute(
              Routes.details,
              arguments: DetailsPageArgument(
                galleryUrl: gallery.galleryUrl,
                gallery: gallery,
              ),
              offAllBefore: false,
              preventDuplicates: false,
            );
          },
        ),
      );
      return;
    }

    String? keyword = _buildTitleSearchKeyword();
    if (keyword == null) {
      return;
    }

    if (state.galleryUrl.isNH) {
      newSearch(
        rewriteSearchConfig: SearchConfig(keyword: keyword, isNhSearch: true),
        forceNewRoute: true,
      );
    } else if (state.galleryUrl.isWN) {
      newSearch(
        rewriteSearchConfig: SearchConfig(
          keyword: keyword,
          isWnacgSearch: true,
        ),
        forceNewRoute: true,
      );
    } else if (state.galleryUrl.isJM) {
      newSearch(
        rewriteSearchConfig: SearchConfig(keyword: keyword, isJmSearch: true),
        forceNewRoute: true,
      );
    } else {
      newSearch(keyword: keyword, forceNewRoute: true);
    }
  }

  void searchInEhByNhTitle() {
    if (!state.galleryUrl.isNH &&
        !state.galleryUrl.isWN &&
        !state.galleryUrl.isJM) {
      return;
    }

    String? keyword = _buildTitleSearchKeyword();
    if (keyword == null) {
      return;
    }

    newSearch(keyword: keyword, forceNewRoute: true);
  }

  void searchUploader() {
    if (state.galleryDetails?.uploader == null &&
        state.gallery?.uploader == null) {
      return;
    }

    String keyword =
        'uploader:"${state.galleryDetails?.uploader ?? state.gallery!.uploader}"';
    if (state.galleryUrl.isNH) {
      newSearch(
        rewriteSearchConfig: SearchConfig(keyword: keyword, isNhSearch: true),
        forceNewRoute: true,
      );
    } else if (state.galleryUrl.isWN) {
      newSearch(
        rewriteSearchConfig: SearchConfig(
          keyword: keyword,
          isWnacgSearch: true,
        ),
        forceNewRoute: true,
      );
    } else if (state.galleryUrl.isJM) {
      newSearch(
        rewriteSearchConfig: SearchConfig(keyword: keyword, isJmSearch: true),
        forceNewRoute: true,
      );
    } else {
      newSearch(keyword: keyword, forceNewRoute: true);
    }
  }

  Future<void> handleTapTorrent() async {
    if (state.galleryUrl.isNH) {
      if (!hasNhentaiOfficialApi) {
        return;
      }
      try {
        var link = await ehRequest.requestNhDownload(
          state.galleryUrl.gid,
          format: 'torrent',
        );
        await launchUrlString(link.url, mode: LaunchMode.externalApplication);
      } on DioException catch (e) {
        log.error('Get nhentai torrent failed', e.errorMsg);
        snack('getGalleryTorrentsFailed'.tr, e.errorMsg ?? '');
      } catch (e, s) {
        log.error('Get nhentai torrent failed', e, s);
        snack('getGalleryTorrentsFailed'.tr, e.toString());
      }
      return;
    }

    if (state.galleryUrl.isWN || state.galleryUrl.isJM) {
      return;
    }

    Get.dialog(
      EHGalleryTorrentsDialog(
        gid: state.galleryUrl.gid,
        token: state.galleryUrl.token,
      ),
    );
  }

  /// 发送到 eh2telegraph 机器人：POST 同步接口，202 即成功，结果稍后由 Telegram 通知。
  /// Every source the app reads from goes to eh2telegraph: E-Hentai and
  /// nhentai by their links, wnacg and JM through its archive mode.
  Future<void> handleTapSendToTelegraph() async {
    final String galleryUrl = state.galleryUrl.url;
    try {
      final String accepted = await Eh2TelegraphClient.fromSetting().sync(
        galleryUrl,
      );
      log.info('Sent gallery to eh2telegraph: $accepted');
      snack('sendToTelegraphAccepted'.tr, accepted, isShort: true);
    } on Eh2TelegraphException catch (e) {
      log.error('Send to eh2telegraph rejected', e.message);
      snack('sendToTelegraphFailed'.tr, e.message, isShort: true);
    } on DioException catch (e) {
      log.error('Send to eh2telegraph failed', e.errorMsg);
      snack('sendToTelegraphFailed'.tr, e.errorMsg ?? '', isShort: true);
    } catch (e, s) {
      log.error('Send to eh2telegraph failed', e, s);
      snack('sendToTelegraphFailed'.tr, e.toString(), isShort: true);
    }
  }

  Future<void> handleTapStatistic() async {
    if (state.galleryUrl.isNH ||
        state.galleryUrl.isWN ||
        state.galleryUrl.isJM) {
      return;
    }

    Get.dialog(
      EHGalleryStatDialog(
        gid: state.galleryUrl.gid,
        token: state.galleryUrl.token,
      ),
    );
  }

  Future<void> handleTapJumpButton() async {
    if (state.galleryDetails == null) {
      return;
    }

    int? pageIndex = await Get.dialog(
      JumpPageDialog(
        totalPageNo: state.galleryDetails!.thumbnailsPageCount,
        currentNo: 1,
      ),
    );

    if (pageIndex != null) {
      toRoute(Routes.thumbnails, arguments: pageIndex);
    }
  }

  void handleTapHistoryButton(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => EHGalleryHistoryDialog(
        currentGalleryTitle:
            state.gallery?.title ??
            state.galleryDetails?.japaneseTitle ??
            state.galleryDetails?.rawTitle ??
            '',
        parentUrl: state.galleryDetails?.parentGalleryUrl,
        childrenGallerys: state.galleryDetails?.childrenGallerys,
      ),
    );
  }

  void onCommentVoted(GalleryComment comment, bool isVotingUp, String score) {
    comment.score = score;
    if (isVotingUp) {
      comment.votedUp = !comment.votedUp;
      comment.votedDown = false;
    } else {
      comment.votedDown = !comment.votedDown;
      comment.votedUp = false;
    }

    updateSafely([DetailsPageLogic.detailsId]);

    removeCache();
  }

  Future<void> openCommentsPage() async {
    if (!state.galleryUrl.isNH) {
      toRoute(Routes.comment, arguments: state.galleryDetails!.comments);
      return;
    }
    if (!hasNhentaiOfficialApi) {
      return;
    }

    List<GalleryComment> comments;
    try {
      comments = await ehRequest.requestNhComments(
        state.galleryUrl.gid,
        allPages: preferenceSetting.showAllComments.isTrue,
      );
      comments = await localBlockRuleService.executeRules(comments);
    } on DioException catch (e) {
      log.error('Get nhentai comments failed', e.errorMsg);
      snack('failed'.tr, e.errorMsg ?? '', isShort: true);
      return;
    } catch (e, s) {
      log.error('Get nhentai comments failed', e, s);
      snack('failed'.tr, e.toString(), isShort: true);
      return;
    }

    state.galleryDetails!.comments = comments;
    updateSafely([detailsId]);
    toRoute(Routes.comment, arguments: comments);
  }

  void showNhentaiTagSuggestions() {
    if (!hasNhentaiOfficialApi || state.galleryDetails == null) {
      return;
    }
    Get.dialog(
      NHentaiTagSuggestionsDialog(
        suggestions: state.galleryDetails!.nhentaiTagSuggestions,
        totalCount: state.galleryDetails!.nhentaiTagSuggestionCount,
      ),
    );
  }

  Future<void> shareGallery() async {
    log.info('Share gallery:${state.galleryUrl}');

    if (GetPlatform.isDesktop) {
      await FlutterClipboard.copy(state.galleryUrl.url);
      toast('hasCopiedToClipboard'.tr);
      return;
    }

    Share.share(
      state.galleryUrl.url,
      sharePositionOrigin: Rect.fromLTWH(
        0,
        0,
        fullScreenWidth,
        screenHeight * 2 / 3,
      ),
    );
  }

  Future<void> handleTapDeleteDownload(
    BuildContext context,
    int gid,
    DownloadPageGalleryType downloadPageGalleryType,
  ) async {
    bool isUpdatingDependent = galleryDownloadService.isUpdatingDependent(gid);

    bool? result = await showDialog(
      context: context,
      builder: (_) => EHDialog(
        title: 'delete'.tr + '?',
        content: isUpdatingDependent ? 'deleteUpdatingDependentHint'.tr : null,
      ),
    );

    if (result == null || !result) {
      return;
    }

    if (downloadPageGalleryType == DownloadPageGalleryType.download) {
      await galleryDownloadService.deleteGalleryByGid(gid);
    }

    if (downloadPageGalleryType == DownloadPageGalleryType.archive) {
      await archiveDownloadService.deleteArchive(gid);
    }

    updateGlobalGalleryStatus();
  }

  void showTagDialog(GalleryTag tag) {
    if (state.galleryUrl.isNH ||
        state.galleryUrl.isWN ||
        state.galleryUrl.isJM ||
        state.apikey == null) {
      return;
    }

    bool useDialog = GetPlatform.isDesktop ||
        PlatformDispatcher.instance.views.first.physicalSize.width / PlatformDispatcher.instance.views.first.devicePixelRatio >= 600;

    if (useDialog) {
      Get.dialog(EHTagDialog(
        tagData: tag.tagData,
        gid: state.galleryDetails!.galleryUrl.gid,
        token: state.galleryDetails!.galleryUrl.token,
        apikey: state.apikey!,
        voteStatus: tag.voteStatus,
        onTagVoted: (bool isVoted, bool isCancel) => onTagVoted(tag, isVoted, isCancel),
      ));
    } else {
      EHTagBottomSheet.show(
        tagData: tag.tagData,
        gid: state.galleryDetails!.galleryUrl.gid,
        token: state.galleryDetails!.galleryUrl.token,
        apikey: state.apikey!,
        voteStatus: tag.voteStatus,
        onTagVoted: (bool isVoted, bool isCancel) => onTagVoted(tag, isVoted, isCancel),
      );
    }
  }

  Future<void> toggleNhentaiBlacklistTag(GalleryTag tag) async {
    if (!hasNhentaiOfficialApi || tag.nhentaiId == null) {
      return;
    }
    bool? confirmed = await Get.dialog<bool>(
      EHDialog(
        title:
            (tag.nhentaiBlacklisted
                    ? 'nhentaiUnblacklistTag'
                    : 'nhentaiBlacklistTag')
                .tr,
      ),
    );
    if (confirmed != true) {
      return;
    }

    try {
      tag.nhentaiBlacklisted = await ehRequest.requestNhToggleBlacklistTag(
        tag.nhentaiId!,
      );
      updateSafely([detailsId]);
      toast('success'.tr);
    } on DioException catch (e) {
      log.error('Update nhentai blacklist failed', e.errorMsg);
      snack('failed'.tr, e.errorMsg ?? '', isShort: true);
    } catch (e, s) {
      log.error('Update nhentai blacklist failed', e, s);
      snack('failed'.tr, e.toString(), isShort: true);
    }
  }

  Future<void> handleAddTag(BuildContext context) async {
    if (state.galleryUrl.isNH ||
        state.galleryUrl.isWN ||
        state.galleryUrl.isJM) {
      return;
    }

    if (state.galleryDetails == null) {
      return;
    }

    if (!checkLogin()) {
      return;
    }

    String? newTag = await showDialog(
      context: context,
      builder: (_) => EHAddTagDialog(),
    );
    if (newTag == null) {
      return;
    }

    log.info('Add tag:$newTag');

    toast('${'addTag'.tr}: $newTag');

    String? errMsg;
    try {
      errMsg = await ehRequest.voteTag(
        state.galleryUrl.gid,
        state.galleryUrl.token,
        userSetting.ipbMemberId.value!,
        state.apikey!,
        newTag,
        true,
        parser: EHSpiderParser.voteTagResponse2ErrorMessage,
      );
    } on DioException catch (e) {
      log.error('addTagFailed'.tr, e.errorMsg);
      snack('addTagFailed'.tr, e.errorMsg ?? '');
      return;
    } on EHSiteException catch (e) {
      log.error('addTagFailed'.tr, e.message);
      snack('addTagFailed'.tr, e.message);
      return;
    } catch (e, s) {
      log.error('addTagFailed'.tr, e, s);
      snack('addTagFailed'.tr, e.toString());
      return;
    }

    if (!isEmptyOrNull(errMsg)) {
      snack('addTagFailed'.tr, errMsg!, isShort: true);
      return;
    } else {
      toast('addTagSuccess'.tr);
      removeCache();
    }
  }

  void onTagVoted(GalleryTag tag, bool isVoted, bool isCancel) {
    if (isCancel) {
      tag.voteStatus = EHTagVoteStatus.none;
    } else if (tag.voteStatus == EHTagVoteStatus.none) {
      tag.voteStatus = isVoted ? EHTagVoteStatus.up : EHTagVoteStatus.down;
    } else if (tag.voteStatus == EHTagVoteStatus.up) {
      tag.voteStatus = isVoted ? EHTagVoteStatus.up : EHTagVoteStatus.none;
    } else if (tag.voteStatus == EHTagVoteStatus.down) {
      tag.voteStatus = isVoted ? EHTagVoteStatus.none : EHTagVoteStatus.down;
    }

    updateSafely([detailsId]);
    removeCache();
  }

  Future<void> blockUser(GalleryComment comment) async {
    await localBlockRuleService.upsertBlockRule(
      LocalBlockRule(
        groupId: newUUID(),
        target: LocalBlockTargetEnum.comment,
        attribute: LocalBlockAttributeEnum.userName,
        pattern: LocalBlockPatternEnum.equal,
        expression: comment.username!,
      ),
    );
    if (comment.userId != null) {
      await localBlockRuleService.upsertBlockRule(
        LocalBlockRule(
          groupId: newUUID(),
          target: LocalBlockTargetEnum.comment,
          attribute: LocalBlockAttributeEnum.userId,
          pattern: LocalBlockPatternEnum.equal,
          expression: comment.userId!.toString(),
        ),
      );
    }

    state.galleryDetails!.comments = await localBlockRuleService.executeRules(
      state.galleryDetails!.comments,
    );
    updateSafely([detailsId]);
    toast('success'.tr);
  }

  Future<void> blockUploader(String uploader) async {
    await localBlockRuleService.upsertBlockRule(
      LocalBlockRule(
        groupId: newUUID(),
        target: LocalBlockTargetEnum.gallery,
        attribute: LocalBlockAttributeEnum.uploader,
        pattern: LocalBlockPatternEnum.equal,
        expression: uploader,
      ),
    );
    toast('success'.tr);
  }

  Future<void> blockTitle(String title) async {
    String expression = title.trim();
    if (expression.isEmpty) {
      return;
    }

    LocalBlockRule rule = LocalBlockRule(
      groupId: newUUID(),
      target: LocalBlockTargetEnum.gallery,
      attribute: LocalBlockAttributeEnum.title,
      pattern: LocalBlockPatternEnum.like,
      expression: expression,
    );

    try {
      ({bool success, bool inserted, String? msg}) result = await localBlockRuleService.insertBlockRuleIfAbsent(rule);
      if (!result.success) {
        snack('configureBlockRuleFailed'.tr, result.msg ?? '');
      } else if (result.inserted) {
        toast('success'.tr);
      } else {
        toast('blockRuleAlreadyExists'.tr);
      }
    } catch (e, stack) {
      log.error('Block title failed, expression:$expression', e, stack);
      snack('configureBlockRuleFailed'.tr, e.toString());
    }
  }

  Future<void> handleResetReadProgress() async {
    await readProgressService.deleteReadProgress(
      state.galleryUrl.gid.toString(),
    );
    updateSafely([readButtonId]);
    toast('success'.tr);
  }

  Future<void> blockGallery() async {
    await localBlockRuleService.upsertBlockRule(
      LocalBlockRule(
        groupId: newUUID(),
        target: LocalBlockTargetEnum.gallery,
        attribute: LocalBlockAttributeEnum.gid,
        pattern: LocalBlockPatternEnum.equal,
        expression: state.galleryUrl.gid.toString(),
      ),
    );
    toast('blockGallerySuccess'.tr);
  }

  Future<void> goToReadPage([int? forceIndex]) async {
    ReadDirection? webtoonReadDirection = _detectWebtoonReadDirection();

    // A chapter of a JM series reads on into the next chapters, downloaded
    // or not.
    JmChapterBundle? jmChapter = state.jmChapterBundle;
    if (jmChapter != null && jmChapter.isMultiChapter) {
      unawaited(
        _openReader(
          await _jmChapterSession(jmChapter, initialIndex: forceIndex),
        ),
      );
      return;
    }

    /// online
    if (galleryDownloadService
            .galleryDownloadInfos[state.galleryUrl.gid]
            ?.downloadProgress ==
        null) {
      unawaited(
        _openReader(
          ReadPageInfo(
            mode: ReadMode.online,
            gid: state.galleryUrl.gid,
            token: state.galleryUrl.token,
            galleryTitle: mainTitleText,
            galleryUrl: state.galleryUrl.url,
            initialIndex: forceIndex ?? await getReadIndexRecord(),
            readProgressRecordStorageKey: state.galleryUrl.gid.toString(),
            pageCount: state.galleryDetails?.pageCount ?? state.gallery?.pageCount ?? state.galleryMetadata!.pageCount,
            useSuperResolution: false,
            readDirection: webtoonReadDirection,
          ),
        ),
      );
      return;
    }

    /// use GalleryDownloadedData's title
    GalleryDownloadedData gallery = galleryDownloadService.gallerys.firstWhere(
      (g) => g.gid == state.galleryUrl.gid,
    );

    if (readSetting.useThirdPartyViewer.isTrue &&
        readSetting.thirdPartyViewerPath.value != null) {
      openThirdPartyViewer(
        galleryDownloadService.computeGalleryDownloadAbsolutePath(gallery),
      );
      return;
    }

    unawaited(
      _openReader(
        ReadPageInfo(
          mode: ReadMode.downloaded,
          gid: gallery.gid,
          token: gallery.token,
          galleryTitle: gallery.title,
          galleryUrl: gallery.galleryUrl,
          initialIndex: forceIndex ?? await getReadIndexRecord(),
          readProgressRecordStorageKey: state.galleryUrl.gid.toString(),
          pageCount: gallery.pageCount,
          useSuperResolution: superResolutionService.get(state.galleryUrl.gid, SuperResolutionType.gallery) != null,
          readDirection: webtoonReadDirection,
        ),
      ),
    );
  }

  /// Opens the reader. In a multi-chapter JM album the reader can close
  /// with the previous or next chapter as its result, which then opens in
  /// turn, the way Komga moves between books of a series.
  Future<void> _openReader(ReadPageInfo info) async {
    ReadPageInfo? session = info;
    while (session != null) {
      final dynamic result = await toRoute<dynamic>(
        Routes.read,
        arguments: session,
      );
      session = result is ReadPageInfo ? result : null;
      if (session != null) {
        await waitForReaderDisposed();
      }
    }

    await Future.delayed(const Duration(milliseconds: 800));
    updateSafely([readButtonId]);
    await _showJmChapterRead();
  }

  /// After reading on into later chapters, the page shows the chapter read
  /// last, with its progress.
  Future<void> _showJmChapterRead() async {
    JmChapterBundle? current = state.jmChapterBundle;
    if (current == null || !current.isMultiChapter || isClosed) {
      return;
    }
    int? last = await jmReadingService.lastOpenedChapter(current.album.id);
    if (last == null || last == current.chapter.id || isClosed) {
      return;
    }
    if (!current.album.chapters.any((JmChapterRef c) => c.id == last)) {
      return;
    }
    state.galleryUrl = GalleryUrl.jm(last);
    await getDetails(refreshPageImmediately: true);
  }

  Future<ReadPageInfo?> Function({required bool next}) _jmSiblingLoader(
    int chapterId,
  ) {
    return ({required bool next}) async {
      JmChapterBundle current = await ehRequest.jmSource.bundle(chapterId);
      int index = current.chapterIndex + (next ? 1 : -1);
      if (current.chapterIndex < 0 ||
          index < 0 ||
          index >= current.album.chapters.length) {
        return null;
      }
      return _jmChapterSession(
        await ehRequest.jmSource.bundle(current.album.chapters[index].id),
      );
    };
  }

  /// A reader session for a JM chapter: online, with the pages already
  /// downloaded read from their files, so that the next chapters can follow
  /// in the same reader (see [ReadSegment]). Opens at the chapter's progress
  /// unless [initialIndex] is given.
  Future<ReadPageInfo> _jmChapterSession(
    JmChapterBundle chapter, {
    int? initialIndex,
  }) async {
    GalleryUrl url = chapter.galleryUrl;
    List<GalleryImage?>? downloaded = galleryDownloadService
        .galleryDownloadInfos[url.gid]
        ?.images
        .map(
          (GalleryImage? image) =>
              image?.downloadStatus == DownloadStatus.downloaded ? image : null,
        )
        .toList();
    return ReadPageInfo(
      mode: ReadMode.online,
      gid: url.gid,
      token: url.token,
      galleryTitle: chapter.title,
      galleryUrl: url.url,
      initialIndex:
          initialIndex ?? await readProgressService.getReadProgress(url.gid),
      readProgressRecordStorageKey: url.gid.toString(),
      pageCount: chapter.pageCount,
      images: downloaded,
      thumbnails: JmSource.pageThumbnails(
        chapter,
        ehRequest.jmSource.imageDomain(),
      ),
      // The chapter being read, which the album then opens on.
      onShown: () => jmReadingService.remember(
        albumId: chapter.album.id,
        pageCounts: {chapter.chapter.id: chapter.pageCount},
        openedChapterId: chapter.chapter.id,
      ),
      useSuperResolution: false,
      readDirection: _detectWebtoonReadDirection(),
      loadSiblingBook: _jmSiblingLoader(chapter.chapter.id),
      siblingsAreChapters: true,
    );
  }

  void openJmChapter(JmChapterRef chapter) {
    if (chapter.id == state.galleryUrl.jmChapterId) {
      return;
    }
    toRoute(
      Routes.details,
      arguments: DetailsPageArgument(
        galleryUrl: GalleryUrl.jm(chapter.id),
        jmExactChapter: true,
      ),
      offAllBefore: false,
      preventDuplicates: false,
    );
  }

  /// Queues every chapter of the album that is not downloaded yet, in a
  /// group named after the album unless the user picks another.
  Future<void> handleDownloadAllJmChapters() async {
    JmChapterBundle? current = state.jmChapterBundle;
    if (current == null) {
      return;
    }
    JmAlbum album = current.album;

    ({String group, bool downloadOriginalImage})? result = await Get.dialog(
      EHDownloadDialog(
        title: 'downloadAllChapters'.tr,
        currentGroup: album.name,
        candidates: galleryDownloadService.allGroups,
        showDownloadOriginalImageCheckBox: false,
        downloadOriginalImage: false,
        preferredGroups: downloadSetting.preferredGalleryGroups,
      ),
    );
    if (result == null) {
      return;
    }

    List<int> pending = [
      for (int i = 0; i < album.chapters.length; i++)
        if (!galleryDownloadService.containGallery(
          GalleryUrl.jm(album.chapters[i].id).gid,
        ))
          i,
    ];
    if (pending.isEmpty) {
      toast('allChaptersDownloaded'.tr);
      return;
    }
    toast('${'beginToDownload'.tr}： ${pending.length}', isCenter: false);

    int failed = 0;
    final Map<int, int> pageCounts = {};
    for (int index in pending) {
      GalleryUrl url = GalleryUrl.jm(album.chapters[index].id);
      int pageCount;
      try {
        pageCount = await ehRequest.jmSource.chapterPageCount(url.jmChapterId);
        pageCounts[url.jmChapterId] = pageCount;
      } catch (e) {
        log.error('Get JM chapter failed: ${url.jmChapterId}', e);
        failed++;
        continue;
      }
      if (galleryDownloadService.containGallery(url.gid)) {
        continue;
      }
      await galleryDownloadService.downloadGallery(
        GalleryDownloadedData(
          gid: url.gid,
          token: url.token,
          title: JmSource.chapterTitle(album, index),
          category: state.galleryDetails?.category ?? 'Manga',
          pageCount: pageCount,
          galleryUrl: url.url,
          uploader: album.authors.firstOrNull,
          publishTime: state.galleryDetails?.publishTime ?? '',
          downloadStatusIndex: DownloadStatus.downloading.index,
          downloadOriginalImage: false,
          sortOrder: 0,
          groupName: result.group,
          insertTime: DateTime.now().toString(),
          priority: GalleryDownloadService.defaultDownloadGalleryPriority,
          tags: state.galleryDetails == null
              ? ''
              : tagMap2TagString(state.galleryDetails!.tags),
          tagRefreshTime: DateTime.now().toString(),
        ),
      );
    }

    updateGlobalGalleryStatus();
    unawaited(
      jmReadingService.remember(albumId: album.id, pageCounts: pageCounts),
    );
    if (failed > 0) {
      snack('failed'.tr, '${'downloadAllChaptersFailed'.tr}: $failed', isShort: true);
    }
  }

  ReadDirection? _detectWebtoonReadDirection() {
    if (state.galleryDetails != null) {
      if (isWebtoonGallery(state.galleryDetails!.tags)) {
        return ReadDirection.top2bottomList;
      }
      return null;
    }
    if (state.gallery != null) {
      if (isWebtoonGallery(state.gallery!.tags)) {
        return ReadDirection.top2bottomList;
      }
      return null;
    }
    if (state.galleryMetadata != null) {
      if (isWebtoonGallery(state.galleryMetadata!.tags)) {
        return ReadDirection.top2bottomList;
      }
      return null;
    }
    return null;
  }

  Future<int> getReadIndexRecord() async {
    return readProgressService.getReadProgress(state.galleryUrl.gid);
  }

  /// The history entry of this page. A multi-chapter JM album is one entry,
  /// whichever of its chapters is open: under the album's id, with the
  /// album's title and page count.
  GalleryHistoryModel _historyModel() {
    GalleryHistoryModel model = galleryDetail2GalleryHistoryModel(
      state.galleryDetails!,
    );
    JmChapterBundle? bundle = state.jmChapterBundle;
    if (bundle != null && bundle.isMultiChapter) {
      model
        ..galleryUrl = GalleryUrl.jm(bundle.album.id)
        ..title = bundle.album.name;
      if (bundle.album.totalPhotos > 0) {
        model.pageCount = bundle.album.totalPhotos;
      }
    }
    return model;
  }

  /// Details of a JM entry: an album opened from a list, the history or a
  /// link goes on to the chapter being read (see
  /// [JmReadingService.resumeChapter]). The page stays loading until that
  /// chapter is shown, and does this until it has once succeeded.
  Future<({GalleryDetail galleryDetails, String apikey})> _getJmEntryDetails(
    int entryId, {
    bool useCache = true,
  }) async {
    state.galleryUrl = GalleryUrl.jm(entryId);

    // Progress made on other devices, fetched alongside the JM requests.
    final Future<void> progressSync = syncService
        .syncReadProgress()
        .then<void>((_) {}, onError: (Object _) {});

    // The chapter last opened in the reader, requested straight away with
    // its album.
    final int? lastOpened = await jmReadingService.lastOpenedChapter(entryId);
    if (lastOpened != null && lastOpened != entryId) {
      ehRequest.jmSource.rememberAlbumOf(lastOpened, entryId);
      state.galleryUrl = GalleryUrl.jm(lastOpened);
    }

    ({GalleryDetail galleryDetails, String apikey}) details;
    try {
      details = await _getDetailsWithRedirectAndFallback(useCache: useCache);
    } catch (e) {
      if (state.galleryUrl.jmChapterId == entryId) {
        rethrow;
      }
      log.warning('JM chapter $lastOpened failed, opening album $entryId', e);
      state.galleryUrl = GalleryUrl.jm(entryId);
      details = await _getDetailsWithRedirectAndFallback(useCache: useCache);
    }

    final JmChapterBundle bundle = await ehRequest.jmSource.bundle(
      state.galleryUrl.jmChapterId,
    );
    // A chapter of its own (not the album's first) opens as is.
    if (bundle.album.id != entryId || !bundle.isMultiChapter) {
      _jmEntryId = null;
      return details;
    }

    await progressSync.timeout(const Duration(seconds: 5), onTimeout: () {});
    final List<int> chapterIds = bundle.album.chapters
        .map((JmChapterRef c) => c.id)
        .toList();
    final int target = JmReadingService.resumeChapter(
      chapterIds,
      await jmReadingService.progressOf(chapterIds),
    );
    if (target != bundle.chapter.id) {
      state.galleryUrl = GalleryUrl.jm(target);
      details = await _getDetailsWithRedirectAndFallback(useCache: useCache);
    }
    _jmEntryId = null;
    return details;
  }

  Future<({GalleryDetail galleryDetails, String apikey})>
  _getDetailsWithRedirectAndFallback({bool useCache = true}) async {
    if (state.galleryUrl.isNH ||
        state.galleryUrl.isWN ||
        state.galleryUrl.isJM) {
      return ehRequest
          .requestDetailPage<({GalleryDetail galleryDetails, String apikey})>(
            galleryUrl: state.galleryUrl.url,
            parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
            useCacheIfAvailable: useCache,
          );
    }

    final GalleryUrl? firstLink;
    final GalleryUrl secondLink;

    /// 1. if redirect is enabled, try EH site first for EX link
    /// 2. if a gallery can't be found in EH site, it may be moved into EX site
    if (!state.galleryUrl.isEH) {
      if (ehSetting.redirect2Eh.isTrue && !_galleryOnlyInExSite()) {
        firstLink = state.galleryUrl.copyWith(isEH: true);
        secondLink = state.galleryUrl;
      } else {
        firstLink = null;
        secondLink = state.galleryUrl;
      }
    } else {
      /// fallback to EX site only if user has logged in
      firstLink = userSetting.hasLoggedIn() ? state.galleryUrl : null;
      secondLink = userSetting.hasLoggedIn()
          ? state.galleryUrl.copyWith(isEH: false)
          : state.galleryUrl;
    }

    /// if we can't find gallery via firstLink, try second link
    EHSiteException? firstException;
    if (firstLink != null) {
      log.trace('Try to find gallery via firstLink: $firstLink');
      try {
        ({GalleryDetail galleryDetails, String apikey})
        detailPageInfo = await ehRequest
            .requestDetailPage<({GalleryDetail galleryDetails, String apikey})>(
              galleryUrl: firstLink.url,
              parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
              useCacheIfAvailable: useCache,
            );
        state.galleryUrl = firstLink;
        state.gallery?.galleryUrl = firstLink;
        state.galleryDetails?.galleryUrl = firstLink;
        return detailPageInfo;
      } on EHSiteException catch (e) {
        log.trace(
          'Can\'t find gallery, firstLink: $firstLink, reason: ${e.message}',
        );
        firstException = e;
      }
    }

    try {
      log.trace('Try to find gallery via secondLink: $secondLink');
      ({GalleryDetail galleryDetails, String apikey})
      detailPageInfo = await ehRequest
          .requestDetailPage<({GalleryDetail galleryDetails, String apikey})>(
            galleryUrl: secondLink.url,
            parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
            useCacheIfAvailable: useCache,
          );
      state.galleryUrl = secondLink;
      state.gallery?.galleryUrl = secondLink;
      state.galleryDetails?.galleryUrl = secondLink;
      return detailPageInfo;
    } on EHSiteException catch (e) {
      log.trace(
        'Can\'t find gallery, secondLink: $secondLink, reason: ${e.message}',
      );
      throw firstException ?? e;
    }
  }

  bool _galleryOnlyInExSite() {
    if (state.gallery == null) {
      return false;
    }

    if (state.gallery!.tags.isEmpty) {
      return false;
    }

    return state.gallery!.tags.values.any(
      (tagList) => tagList.any((tag) => tag.tagData.key == 'lolicon'),
    );
  }

  /// some field in [gallery] sometimes is null
  List<Object> _judgeUpdateIds() {
    List<Object> updateIds = [detailsId, loadingStateId, galleryId];

    if (state.gallery == null) {
      updateIds.add(galleryId);
      updateIds.add(languageId);
      updateIds.add(pageCountId);
      updateIds.add(uploaderId);
      updateIds.add(favoriteId);
      updateIds.add(ratingId);
      updateIds.add(pageCountId);
      return updateIds;
    }

    /// language is null in Minimal mode
    if (state.galleryDetails?.language != state.gallery?.language) {
      updateIds.add(languageId);
    }

    /// page count is null in favorite page
    if (state.galleryDetails?.pageCount != state.gallery?.pageCount) {
      updateIds.add(pageCountId);
    }

    /// uploader info is null in favorite page
    if (state.galleryDetails?.uploader != state.gallery?.uploader) {
      updateIds.add(uploaderId);
    }

    /// favorite info is null in ranklist page
    if (state.galleryDetails?.isFavorite != state.gallery?.isFavorite ||
        state.galleryDetails?.favoriteTagIndex !=
            state.gallery?.favoriteTagIndex ||
        state.galleryDetails?.favoriteTagName !=
            state.gallery?.favoriteTagName) {
      updateIds.add(favoriteId);
    }

    /// rating info is null in ranklist page
    if (state.galleryDetails?.hasRated != state.gallery?.hasRated ||
        state.galleryDetails?.rating != state.gallery?.rating) {
      updateIds.add(ratingId);
    }

    return updateIds;
  }

  List<Object> _judgeUpdateIds4MetaData() {
    List<Object> updateIds = [detailsId, metadataId, loadingStateId, galleryId];

    if (state.gallery == null) {
      updateIds.add(galleryId);
      updateIds.add(languageId);
      updateIds.add(pageCountId);
      updateIds.add(uploaderId);
      updateIds.add(favoriteId);
      updateIds.add(ratingId);
      updateIds.add(pageCountId);
      return updateIds;
    }

    /// language is null in Minimal mode
    if (state.galleryMetadata?.language != state.gallery?.language) {
      updateIds.add(languageId);
    }

    /// page count is null in favorite page
    if (state.galleryMetadata?.pageCount != state.gallery?.pageCount) {
      updateIds.add(pageCountId);
    }

    /// uploader info is null in favorite page
    if (state.galleryMetadata?.uploader != state.gallery?.uploader) {
      updateIds.add(uploaderId);
    }

    return updateIds;
  }

  void _addColor2WatchedTags(LinkedHashMap<String, List<GalleryTag>> fullTags) {
    for (List<GalleryTag> tags in fullTags.values) {
      for (GalleryTag tag in tags) {
        if (tag.color != null || tag.backgroundColor != null) {
          continue;
        }

        ({Color? tagSetBackGroundColor, WatchedTag tag})? tagInfo =
            myTagsSetting.getOnlineTagSetByTagData(tag.tagData);
        if (tagInfo == null) {
          continue;
        }

        Color? backGroundColor = tagInfo.tag.backgroundColor ?? tagInfo.tagSetBackGroundColor;
        bool hidden = tagInfo.tag.hidden || tagInfo.tag.weight < 0;
        tag.backgroundColor = backGroundColor ?? (hidden ? UIConfig.ehHiddenTagDefaultBackGroundColor : UIConfig.ehWatchedTagDefaultBackGroundColor);
        tag.color = backGroundColor == null
            ? const Color(0xFFF1F1F1)
            : ThemeData.estimateBrightnessForColor(backGroundColor) ==
                  Brightness.light
            ? const Color.fromRGBO(9, 9, 9, 1)
            : const Color(0xFFF1F1F1);
      }
    }
  }

  void toggleTagSelectionMode() {
    state.isTagSelectionMode = !state.isTagSelectionMode;
    if (!state.isTagSelectionMode) {
      state.selectedTags.clear();
    }
    updateSafely([detailsId]);
  }

  void toggleTagSelection(GalleryTag tag) {
    int existingIndex = state.selectedTags.indexWhere(
      (t) =>
          t.tagData.namespace == tag.tagData.namespace &&
          t.tagData.key == tag.tagData.key,
    );

    if (existingIndex != -1) {
      state.selectedTags.removeAt(existingIndex);
    } else {
      state.selectedTags.add(tag);
    }
    updateSafely([detailsId]);
  }

  void searchWithSelectedTags() {
    if (state.selectedTags.isEmpty) {
      return;
    }

    SearchConfig searchConfig = SearchConfig();
    searchConfig.tags = state.selectedTags.map((t) => t.tagData).toList();
    if (state.galleryUrl.isNH) {
      searchConfig.isNhSearch = true;
    }
    if (state.galleryUrl.isWN) {
      searchConfig.isWnacgSearch = true;
    }
    if (state.galleryUrl.isJM) {
      searchConfig.isJmSearch = true;
    }

    newSearch(rewriteSearchConfig: searchConfig, forceNewRoute: true);

    // Exit selection mode after search
    state.isTagSelectionMode = false;
    state.selectedTags.clear();
    updateSafely([detailsId]);
  }

  void removeCache() {
    ehRequest.removeCacheByGalleryUrlAndPage(state.galleryUrl.url, 0);
  }

  String? _buildTitleSearchKeyword() {
    String source = mainTitleText.trim();
    if (source.isEmpty) {
      return null;
    }

    String normalized = source
        .replaceAll(RegExp(r'\[.*?\]|\(.*?\)|{.*?}'), ' ')
        .replaceAll('"', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (normalized.isEmpty) {
      normalized = source
          .replaceAll('"', ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    if (normalized.isEmpty) {
      return null;
    }

    return 'title:"$normalized"';
  }
}
