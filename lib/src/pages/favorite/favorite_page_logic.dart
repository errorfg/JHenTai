import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_navigation/get_navigation.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/widget/eh_favorite_sort_order_dialog.dart';

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
  static final DateFormat _minuteDateFormat = DateFormat('yyyy-MM-dd HH:mm');

  @override
  bool get useSearchConfig => true;

  @override
  bool get autoLoadNeedLogin => true;

  @override
  final FavoritePageState state = FavoritePageState();

  @override
  Future<void> handleRefresh({String? updateId}) async {
    await super.handleRefresh(updateId: updateId);
    _mergeNhentaiFavoritesForDisplay();
  }

  @override
  Future<void> loadBefore() async {
    await super.loadBefore();
    _mergeNhentaiFavoritesForDisplay();
  }

  @override
  Future<void> loadMore({bool checkLoadingState = true}) async {
    await super.loadMore(checkLoadingState: checkLoadingState);
    _mergeNhentaiFavoritesForDisplay();
  }

  @override
  Future<void> jumpPage(DateTime dateTime) async {
    await super.jumpPage(dateTime);
    _mergeNhentaiFavoritesForDisplay();
  }

  Future<void> handleChangeSortOrder() async {
    if (state.refreshState == LoadingState.loading) {
      return;
    }

    FavoriteSortOrder? result = await Get.dialog(
        EHFavoriteSortOrderDialog(init: state.favoriteSortOrder));
    if (result == null) {
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
      await ehRequest.requestChangeFavoriteSortOrder(result,
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

  Future<void> reloadNhentaiFavoriteGallerys() async {
    _mergeNhentaiFavoritesForDisplay();
  }

  void _mergeNhentaiFavoritesForDisplay() {
    if (state.searchConfig.searchType != SearchType.favorite) {
      return;
    }

    List<Gallery> ehFavorites =
        state.gallerys.where((gallery) => !gallery.galleryUrl.isNH).toList();
    List<Gallery> nhFavorites = nhentaiFavoriteService.getDisplayFavorites(
      sortOrder: state.favoriteSortOrder,
      searchConfig: state.searchConfig,
    );

    state.gallerys = _insertNhFavoritesByTime(
      ehFavorites: ehFavorites,
      nhFavorites: nhFavorites,
    );

    _adjustLoadingStateAfterMerge();
    updateSafely();
  }

  List<Gallery> _insertNhFavoritesByTime({
    required List<Gallery> ehFavorites,
    required List<Gallery> nhFavorites,
  }) {
    if (nhFavorites.isEmpty) {
      return ehFavorites;
    }

    List<Gallery> merged = List<Gallery>.from(ehFavorites);

    for (Gallery nhGallery in nhFavorites) {
      DateTime? nhTime = _parseGalleryTime(nhGallery.publishTime);
      int insertIndex = merged.length;

      for (int i = 0; i < merged.length; i++) {
        DateTime? currentTime = _parseGalleryTime(merged[i].publishTime);
        if (_shouldInsertBefore(
          nhTime: nhTime,
          currentTime: currentTime,
        )) {
          insertIndex = i;
          break;
        }
      }

      merged.insert(insertIndex, nhGallery);
    }

    return merged;
  }

  bool _shouldInsertBefore({
    required DateTime? nhTime,
    required DateTime? currentTime,
  }) {
    if (nhTime == null) {
      return false;
    }
    if (currentTime == null) {
      return true;
    }
    return nhTime.isAfter(currentTime);
  }

  DateTime? _parseGalleryTime(String time) {
    String normalized = time.trim();
    if (normalized.isEmpty) {
      return null;
    }

    try {
      return _minuteDateFormat.parseUtc(normalized);
    } catch (_) {}

    try {
      return DateFormat('yyyy-MM-dd HH:mm:ss').parseUtc(normalized);
    } catch (_) {}

    return DateTime.tryParse(normalized)?.toUtc();
  }

  void _adjustLoadingStateAfterMerge() {
    if (state.loadingState == LoadingState.loading ||
        state.loadingState == LoadingState.error) {
      return;
    }

    if (state.nextGid == null &&
        state.prevGid == null &&
        state.gallerys.isEmpty) {
      state.loadingState = LoadingState.noData;
      return;
    }

    if (state.nextGid == null) {
      state.loadingState = LoadingState.noMore;
      return;
    }

    state.loadingState = LoadingState.idle;
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
