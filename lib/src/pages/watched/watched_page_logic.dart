import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/pages/watched/watched_page_state.dart';

import '../../enum/config_enum.dart';
import '../../model/gallery.dart';
import '../../model/search_config.dart';
import '../../routes/routes.dart';
import '../../service/local_config_service.dart';
import '../../service/watched_progress_service.dart';
import '../../utils/route_util.dart';
import '../../utils/toast_util.dart';
import '../../widget/eh_context_menu.dart';
import '../../widget/loading_state_indicator.dart';
import '../base/base_page_logic.dart';
import 'watched_card.dart';

class WatchedPageLogic extends BasePageLogic {
  @override
  bool get useSearchConfig => true;

  @override
  bool get autoLoadNeedLogin => true;

  @override
  final WatchedPageState state = WatchedPageState();

  /// A card is seen once this much of it is on screen.
  static const double seenFraction = 0.5;

  /// The cards on screen now (at least [seenFraction]), by gid.
  final Set<int> _onScreen = <int>{};

  /// The first and last gallery of the stretch scrolled through since the
  /// list was last loaded: everything between them went past the screen,
  /// even what a fast fling gave no time to be reported.
  int? _seenFirst;
  int? _seenLast;

  /// Whether the list was scrolled by hand since it was loaded: only then
  /// is where it is kept as where it was left.
  bool _scrolledByUser = false;
  Timer? _positionTimer;

  /// Set by tests.
  Duration positionDelay = const Duration(milliseconds: 800);

  WatchedPageLogic() {
    state.scrollController.addListener(_onScroll);
  }

  @override
  void onClose() {
    state.scrollController.removeListener(_onScroll);
    _positionTimer?.cancel();
    unawaited(watchedProgressService.flush());
    super.onClose();
  }

  void _onScroll() {
    if (state.scrollController.hasClients && state.scrollController.position.userScrollDirection != ScrollDirection.idle) {
      _scrolledByUser = true;
    }
  }

  @override
  Future<void> saveSearchConfig(SearchConfig searchConfig) async {
    await localConfigService.write(
      configKey: ConfigEnum.searchConfig,
      subConfigKey: searchConfigKey,
      value: jsonEncode(searchConfig.copyWith(keyword: '', tags: [])),
    );
  }

  @override
  Widget Function(Gallery gallery, Widget card)? get cardWrapper =>
      (Gallery gallery, Widget card) => WatchedCard(gallery: gallery, onVisibilityChanged: onCardVisibilityChanged, child: card);

  /// A card came into view or went out of it.
  void onCardVisibilityChanged(Gallery gallery, double visibleFraction) {
    if (visibleFraction < seenFraction) {
      _onScreen.remove(gallery.gid);
      return;
    }
    _onScreen.add(gallery.gid);

    final List<Gallery> gallerys = state.gallerys;
    final int index = gallerys.indexWhere((Gallery g) => g.gid == gallery.gid);
    if (index < 0) {
      return;
    }
    final int first = _seenFirst == null ? -1 : gallerys.indexWhere((Gallery g) => g.gid == _seenFirst);
    final int last = _seenLast == null ? -1 : gallerys.indexWhere((Gallery g) => g.gid == _seenLast);
    if (first < 0 || last < 0) {
      watchedProgressService.markRead(gallerys, index, index);
      _seenFirst = _seenLast = gallery.gid;
    } else {
      // Each end reached anew: what lies between it and the stretch so far.
      if (index < first) {
        watchedProgressService.markRead(gallerys, index, first);
      }
      if (index > last) {
        watchedProgressService.markRead(gallerys, last, index);
      }
      _seenFirst = gallerys[min(first, index)].gid;
      _seenLast = gallerys[max(last, index)].gid;
    }

    if (_scrolledByUser) {
      _positionTimer?.cancel();
      _positionTimer = Timer(positionDelay, _keepPosition);
    }
  }

  /// The gallery at the top of the screen is where the list was left.
  void _keepPosition() {
    for (final Gallery gallery in state.gallerys) {
      if (_onScreen.contains(gallery.gid)) {
        watchedProgressService.setLastPosition(gallery);
        return;
      }
    }
  }

  void _forgetStretch() {
    _onScreen.clear();
    _seenFirst = _seenLast = null;
    _scrolledByUser = false;
    _positionTimer?.cancel();
  }

  @override
  Future<void> handleRefresh({String? updateId}) async {
    _forgetStretch();
    await super.handleRefresh(updateId: updateId);
  }

  @override
  Future<void> handleClearAndRefresh() async {
    _forgetStretch();
    await super.handleClearAndRefresh();
  }

  @override
  Future<void> jumpPage(DateTime dateTime) async {
    _forgetStretch();
    await super.jumpPage(dateTime);
  }

  @override
  Future<void> jumpToGallery(int gid) async {
    _forgetStretch();
    await super.jumpToGallery(gid);
  }

  /// Asked to list from a gallery while a load was under way.
  int? _pendingGid;

  /// Lists from the gallery [gid] on as soon as the list is free: at once,
  /// or when the load under way (the first one, when the page has only
  /// just been opened) is done.
  Future<void> showFrom(int gid) async {
    if (state.loadingState == LoadingState.loading) {
      _pendingGid = gid;
      return;
    }
    _pendingGid = null;
    await jumpToGallery(gid);
  }

  @override
  Future<void> loadMore({bool checkLoadingState = true}) async {
    await super.loadMore(checkLoadingState: checkLoadingState);
    final int? pending = _pendingGid;
    if (pending != null && state.loadingState != LoadingState.loading) {
      _pendingGid = null;
      await jumpToGallery(pending);
    }
  }

  @override
  void handleLongPressCard(BuildContext context, Gallery gallery, {Offset? position}) {
    final bool bookmarked = watchedProgressService.isBookmarked(gallery.gid);
    showEHContextMenu(
      context,
      position: position,
      actions: [
        EHContextMenuAction(
          text: bookmarked ? 'removeWatchedBookmark'.tr : 'addWatchedBookmark'.tr,
          icon: Icon(bookmarked ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined),
          onTap: () => toggleBookmark(gallery),
        ),
        EHContextMenuAction(
          text: 'watchedProgress'.tr,
          icon: const Icon(Icons.timeline),
          onTap: openProgress,
        ),
      ],
    );
  }

  @override
  void handleSecondaryTapCard(BuildContext context, Gallery gallery, {Offset? position}) {
    handleLongPressCard(context, gallery, position: position);
  }

  void toggleBookmark(Gallery gallery) {
    if (watchedProgressService.isBookmarked(gallery.gid)) {
      watchedProgressService.removeBookmark(gallery.gid);
      toast('watchedBookmarkRemoved'.tr);
    } else {
      watchedProgressService.addBookmark(gallery);
      toast('watchedBookmarkAdded'.tr);
    }
  }

  void openProgress() {
    toRoute(Routes.watchedProgress);
  }
}
