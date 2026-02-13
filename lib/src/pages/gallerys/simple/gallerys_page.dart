import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/pages/gallerys/simple/gallerys_page_logic.dart';
import 'package:jhentai/src/pages/gallerys/simple/gallerys_page_state.dart';
import 'package:jhentai/src/widget/eh_wheel_speed_controller.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

import '../../base/base_page.dart';

/// For desktop layout
class GallerysPage extends BasePage {
  const GallerysPage({Key? key})
      : super(
          key: key,
          showFilterButton: true,
          showScroll2TopButton: true,
          showTitle: true,
        );

  @override
  String get name => 'home'.tr;

  @override
  GallerysPageLogic get logic =>
      Get.put<GallerysPageLogic>(GallerysPageLogic(), permanent: true);

  @override
  GallerysPageState get state => Get.find<GallerysPageLogic>().state;

  @override
  AppBar? buildAppBar(BuildContext context) {
    return AppBar(
      title: GestureDetector(
        onTap: logic.handleTapHomeSync,
        child: Text(name),
      ),
      centerTitle: true,
      actions: buildAppBarActions(),
    );
  }

  Widget _buildSyncProgressBar() {
    return GetBuilder<GallerysPageLogic>(
      id: logic.syncProgressId,
      global: false,
      init: logic,
      builder: (_) {
        if (!state.syncInProgress) {
          return const SizedBox(height: 2);
        }

        return SizedBox(
          height: 2,
          child: LinearProgressIndicator(
            minHeight: 2,
            value: state.syncProgress.clamp(0.03, 1).toDouble(),
          ),
        );
      },
    );
  }

  @override
  Widget buildBody(BuildContext context) {
    return GetBuilder<GallerysPageLogic>(
      id: logic.bodyId,
      global: false,
      init: logic,
      builder: (_) =>
          state.gallerys.isEmpty && state.loadingState != LoadingState.idle
              ? buildCenterStatusIndicator()
              : NotificationListener<UserScrollNotification>(
                  onNotification: logic.onUserScroll,
                  child: EHWheelSpeedController(
                    controller: state.scrollController,
                    child: CustomScrollView(
                      key: state.pageStorageKey,
                      controller: state.scrollController,
                      physics: const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics()),
                      scrollBehavior:
                          UIConfig.scrollBehaviourWithScrollBarWithMouse,
                      slivers: <Widget>[
                        buildPullDownIndicator(),
                        SliverToBoxAdapter(child: _buildSyncProgressBar()),
                        buildGalleryCollection(context),
                        buildLoadMoreIndicator(),
                      ],
                    ),
                  ),
                ),
    );
  }
}
