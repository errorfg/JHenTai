import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_navigation/get_navigation.dart';
import 'package:get/get_utils/get_utils.dart';
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
      _loadNhFavorites();
      return;
    }
    await super.handleRefresh(updateId: updateId);
    if (state.mixedMode) {
      _mergeNhFavoritesForDisplay();
    }
  }

  @override
  Future<void> loadBefore() async {
    if (state.showNhFavorites) return;
    await super.loadBefore();
    if (state.mixedMode) {
      _mergeNhFavoritesForDisplay();
    }
  }

  @override
  Future<void> loadMore({bool checkLoadingState = true}) async {
    if (state.showNhFavorites) return;
    await super.loadMore(checkLoadingState: checkLoadingState);
    if (state.mixedMode) {
      _mergeNhFavoritesForDisplay();
    }
  }

  @override
  Future<void> jumpPage(DateTime dateTime) async {
    if (state.showNhFavorites) return;
    await super.jumpPage(dateTime);
    if (state.mixedMode) {
      _mergeNhFavoritesForDisplay();
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
    ));
    if (result == null) {
      return;
    }

    state.mixedMode = result.mixedMode;

    if (state.showNhFavorites) {
      if (state.mixedMode) {
        // switching from NH-only to mixed mode: go back to EH view with mix
        state.showNhFavorites = false;
        state.favoriteSortOrder = result.sortOrder;
        handleRefresh();
        return;
      }
      state.favoriteSortOrder = result.sortOrder;
      _loadNhFavorites();
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
      await ehRequest.requestChangeFavoriteSortOrder(result.sortOrder,
          parser: EHSpiderParser.galleryPage2GalleryPageInfo);
    } on DioException catch (e) {
      /// handle with domain fronting, manually load more
      if (e.response?.statusCode == 403 && e.response!.redirects.isNotEmpty) {
        return loadMore(checkLoadingState: false);
      }

      log.error('change favorite sort order fail', e.message);
      snack('failed'.tr, e.message ?? '');
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
    if (state.mixedMode) {
      // in mixed mode, toggling switches back to separate mode
      state.mixedMode = false;
    }
    state.showNhFavorites = !state.showNhFavorites;
    if (state.showNhFavorites) {
      _loadNhFavorites();
    } else {
      handleRefresh();
    }
  }

  Future<void> reloadNhentaiFavoriteGallerys() async {
    if (state.showNhFavorites) {
      _loadNhFavorites();
    } else if (state.mixedMode) {
      _mergeNhFavoritesForDisplay();
      updateSafely();
    }
  }

  void _loadNhFavorites() {
    List<Gallery> nhFavorites = nhentaiFavoriteService.getDisplayFavorites(
      sortOrder: state.favoriteSortOrder,
      searchConfig: state.searchConfig,
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

  void _mergeNhFavoritesForDisplay() {
    // Check if EH galleries have favoritedTime
    bool ehHasFavoritedTime = state.gallerys.any((g) => g.favoritedTime != null);
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

    if (nhFavorites.isEmpty) {
      return;
    }

    // Remove any previously merged NH galleries (identified by NH URL)
    state.gallerys.removeWhere((g) => g.galleryUrl.isNH);

    // Combine and sort descending by the time matching current sort order
    bool sortByPublishTime = state.favoriteSortOrder == FavoriteSortOrder.publishedTime;
    List<Gallery> combined = [...state.gallerys, ...nhFavorites];
    combined.sort((a, b) {
      String timeA = sortByPublishTime ? a.publishTime : (a.favoritedTime ?? '');
      String timeB = sortByPublishTime ? b.publishTime : (b.favoritedTime ?? '');
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
