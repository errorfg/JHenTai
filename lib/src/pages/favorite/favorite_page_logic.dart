import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_navigation/get_navigation.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/widget/eh_favorite_sort_order_dialog.dart';

import '../../utils/uuid_util.dart';

import '../../enum/config_enum.dart';
import '../../exception/eh_site_exception.dart';
import '../../model/gallery.dart';
import '../../model/search_config.dart';
import '../../service/local_config_service.dart';
import '../../service/nhentai_favorite_service.dart';
import '../../service/jm_favorite_service.dart';
import '../../service/local_source_favorite_service.dart';
import '../../service/wnacg_favorite_service.dart';
import '../../service/tag_translation_service.dart';
import '../../utils/eh_spider_parser.dart';
import '../../service/log.dart';
import '../../utils/snack_util.dart';
import '../../widget/loading_state_indicator.dart';
import '../base/base_page_logic.dart';
import 'favorite_page_state.dart';

class FavoritePageLogic extends BasePageLogic {
  @override
  bool get useSearchConfig => true;

  @override
  bool get autoLoadNeedLogin => true;

  @override
  final FavoritePageState state = FavoritePageState();

  @override
  Future<void> handleRefresh({String? updateId}) async {
    if (state.showNhFavorites) {
      if (ehRequest.hasNhentaiApiKey) {
        await super.handleRefresh(updateId: updateId);
      } else {
        await _loadNhFavorites();
      }
      return;
    }
    if (_shownLocalSourceService != null) {
      _loadLocalSourceFavorites();
      return;
    }
    await super.handleRefresh(updateId: updateId);
    if (state.mixedMode) {
      _mergeLocalFavoritesForDisplay();
    }
  }

  @override
  Future<void> loadBefore() async {
    if (state.showNhFavorites) {
      if (ehRequest.hasNhentaiApiKey) {
        await super.loadBefore();
      }
      return;
    }
    if (_shownLocalSourceService != null) return;
    await super.loadBefore();
    if (state.mixedMode) {
      _mergeLocalFavoritesForDisplay();
    }
  }

  @override
  Future<void> loadMore({bool checkLoadingState = true}) async {
    if (state.showNhFavorites) {
      if (ehRequest.hasNhentaiApiKey) {
        await super.loadMore(checkLoadingState: checkLoadingState);
      }
      return;
    }
    if (_shownLocalSourceService != null) return;
    await super.loadMore(checkLoadingState: checkLoadingState);
    if (state.mixedMode) {
      _mergeLocalFavoritesForDisplay();
    }
  }

  @override
  Future<void> jumpPage(DateTime dateTime) async {
    if (state.showNhFavorites || _shownLocalSourceService != null) return;
    await super.jumpPage(dateTime);
    if (state.mixedMode) {
      _mergeLocalFavoritesForDisplay();
    }
  }

  Future<void> handleChangeSortOrder() async {
    if (state.refreshState == LoadingState.loading) {
      return;
    }

    FavoriteSortOrderDialogResult? result = await Get.dialog(
      EHFavoriteSortOrderDialog(
        init: state.favoriteSortOrder,
        initMixedMode: state.mixedMode,
      ),
    );
    if (result == null) {
      return;
    }

    state.mixedMode = result.mixedMode;

    if (state.showNhFavorites) {
      if (state.mixedMode) {
        state.showNhFavorites = false;
        state.favoriteSortOrder = result.sortOrder;
        handleRefresh();
        return;
      }
      state.favoriteSortOrder = result.sortOrder;
      _loadNhFavorites();
      return;
    }

    if (_shownLocalSourceService != null) {
      if (state.mixedMode) {
        state.showWnFavorites = false;
        state.showJmFavorites = false;
        state.favoriteSortOrder = result.sortOrder;
        handleRefresh();
        return;
      }
      state.favoriteSortOrder = result.sortOrder;
      _loadLocalSourceFavorites();
      return;
    }

    if (state.refreshState == LoadingState.loading) {
      return;
    }

    state.loadingState = LoadingState.loading;

    state.gallerys.clear();
    state.prevGid = null;
    state.nextGid = null;
    state.seek = DateTime.now();
    state.totalCount = null;
    state.favoriteSortOrder = null;

    jump2Top();

    updateSafely();

    try {
      await ehRequest.requestChangeFavoriteSortOrder(
        result.sortOrder,
        parser: EHSpiderParser.galleryPage2GalleryPageInfo,
      );
    } on DioException catch (e) {
      /// handle with domain fronting, manually load more
      if (e.response?.statusCode == 403 && e.response!.redirects.isNotEmpty) {
        return loadMore(checkLoadingState: false);
      }

      log.error('change favorite sort order fail', e.errorMsg);
      snack('failed'.tr, e.errorMsg ?? '');
      state.loadingState = LoadingState.error;
      updateSafely([loadingStateId]);
      return;
    } on EHSiteException catch (e) {
      log.error('change favorite sort order fail', e.message);
      snack('failed'.tr, e.message);
      state.loadingState = LoadingState.error;
      updateSafely([loadingStateId]);
      return;
    } catch (e) {
      log.error('change favorite sort order fail', e.toString);
      snack('failed'.tr, e.toString());
      state.loadingState = LoadingState.error;
      updateSafely([loadingStateId]);
      return;
    }

    return loadMore(checkLoadingState: false);
  }

  void handleToggleNhFavorites() {
    handleSwitchFavoriteSource(state.showNhFavorites ? 'EH' : 'NH');
  }

  void handleSwitchFavoriteSource(String source) {
    if (state.mixedMode) {
      state.mixedMode = false;
    }
    state.showNhFavorites = source == 'NH';
    state.showWnFavorites = source == 'WN';
    state.showJmFavorites = source == 'JM';
    if (state.showNhFavorites) {
      _loadNhFavorites();
    } else if (_shownLocalSourceService != null) {
      _loadLocalSourceFavorites();
    } else {
      handleRefresh();
    }
  }

  Future<void> reloadNhentaiFavoriteGallerys() async {
    if (state.showNhFavorites) {
      await _loadNhFavorites();
    } else if (state.mixedMode) {
      _mergeLocalFavoritesForDisplay();
      updateSafely();
    }
  }

  /// Reloads after a wnacg or JM favorite changed elsewhere.
  Future<void> reloadLocalSourceFavoriteGallerys() async {
    if (_shownLocalSourceService != null) {
      _loadLocalSourceFavorites();
    } else if (state.mixedMode) {
      _mergeLocalFavoritesForDisplay();
      updateSafely();
    }
  }

  Future<void> _loadNhFavorites() async {
    if (ehRequest.hasNhentaiApiKey) {
      return handleClearAndRefresh();
    }

    List<Gallery> nhFavorites = nhentaiFavoriteService.getDisplayFavorites(
      sortOrder: state.favoriteSortOrder,
      searchConfig: state.searchConfig,
    );

    await Future.wait(
      nhFavorites.map(
        (g) => tagTranslationService.translateTagsIfNeeded(g.tags),
      ),
    );

    state.gallerys = nhFavorites;
    state.prevGid = null;
    state.nextGid = null;
    state.galleryCollectionKey = Key(newUUID());

    if (nhFavorites.isEmpty) {
      state.loadingState = LoadingState.noData;
    } else {
      state.loadingState = LoadingState.noMore;
    }

    jump2Top();
    updateSafely();
  }

  @override
  Future<GalleryPageInfo> getGalleryPage({
    String? prevGid,
    String? nextGid,
    DateTime? seek,
  }) async {
    if (state.showNhFavorites && ehRequest.hasNhentaiApiKey) {
      await state.searchConfigInitCompleter.future;
      int pageNo = int.tryParse(nextGid ?? prevGid ?? '') ?? 1;
      try {
        GalleryPageInfo remotePage = await ehRequest.requestNhFavoritePage(
          pageNo: pageNo,
          searchConfig: state.searchConfig,
        );
        return nhentaiFavoriteService.mergeRemoteFavoritePage(
          remotePage: remotePage,
          includeLocalFavorites: pageNo == 1,
          sortOrder: state.favoriteSortOrder,
          searchConfig: state.searchConfig,
        );
      } catch (e) {
        if (pageNo != 1) {
          rethrow;
        }

        log.warning(
          'Load native nhentai favorites failed; keeping synced favorites visible',
          e,
        );
        return nhentaiFavoriteService.mergeRemoteFavoritePage(
          remotePage: GalleryPageInfo(gallerys: const <Gallery>[]),
          includeLocalFavorites: true,
          sortOrder: state.favoriteSortOrder,
          searchConfig: state.searchConfig,
        );
      }
    }
    return super.getGalleryPage(prevGid: prevGid, nextGid: nextGid, seek: seek);
  }

  LocalSourceFavoriteService? get _shownLocalSourceService => state.showWnFavorites
      ? wnacgFavoriteService
      : state.showJmFavorites
          ? jmFavoriteService
          : null;

  Future<void> _loadLocalSourceFavorites() async {
    List<Gallery> favorites = _shownLocalSourceService!.getDisplayFavorites(
      sortOrder: state.favoriteSortOrder,
      searchConfig: state.searchConfig,
    );

    await Future.wait(
      favorites.map(
        (g) => tagTranslationService.translateTagsIfNeeded(g.tags),
      ),
    );

    state.gallerys = favorites;
    state.prevGid = null;
    state.nextGid = null;
    state.galleryCollectionKey = Key(newUUID());

    if (favorites.isEmpty) {
      state.loadingState = LoadingState.noData;
    } else {
      state.loadingState = LoadingState.noMore;
    }

    jump2Top();
    updateSafely();
  }

  Future<void> _mergeLocalFavoritesForDisplay() async {
    // Check if EH galleries have favoritedTime
    bool ehHasFavoritedTime = state.gallerys.any(
      (g) => g.favoritedTime != null,
    );
    if (state.gallerys.isNotEmpty && !ehHasFavoritedTime) {
      state.mixedMode = false;
      snack('mixedModeUnavailable'.tr, '');
      updateSafely();
      return;
    }

    List<Gallery> nhFavorites = nhentaiFavoriteService.getDisplayFavorites(
      sortOrder: state.favoriteSortOrder,
      searchConfig: state.searchConfig,
    );
    List<Gallery> wnFavorites = wnacgFavoriteService.getDisplayFavorites(
      sortOrder: state.favoriteSortOrder,
      searchConfig: state.searchConfig,
    );
    List<Gallery> jmFavorites = jmFavoriteService.getDisplayFavorites(
      sortOrder: state.favoriteSortOrder,
      searchConfig: state.searchConfig,
    );

    List<Gallery> localFavorites = [...nhFavorites, ...wnFavorites, ...jmFavorites];
    if (localFavorites.isEmpty) {
      return;
    }

    await Future.wait(
      localFavorites.map(
        (g) => tagTranslationService.translateTagsIfNeeded(g.tags),
      ),
    );

    // Remove any previously merged local favorites (identified by NH/WN/JM URL)
    state.gallerys.removeWhere((g) => g.galleryUrl.isNH || g.galleryUrl.isWN || g.galleryUrl.isJM);

    // Combine and sort descending by the time matching current sort order
    bool sortByPublishTime =
        state.favoriteSortOrder == FavoriteSortOrder.publishedTime;
    List<Gallery> combined = [...state.gallerys, ...localFavorites];
    combined.sort((a, b) {
      String timeA = sortByPublishTime
          ? a.publishTime
          : (a.favoritedTime ?? '');
      String timeB = sortByPublishTime
          ? b.publishTime
          : (b.favoritedTime ?? '');
      return timeB.compareTo(timeA);
    });

    state.gallerys = combined;
    state.galleryCollectionKey = Key(newUUID());
  }

  @override
  Future<void> saveSearchConfig(SearchConfig searchConfig) async {
    await localConfigService.write(
      configKey: ConfigEnum.searchConfig,
      subConfigKey: searchConfigKey,
      value: jsonEncode(searchConfig.copyWith(keyword: '', tags: [])),
    );
  }
}
