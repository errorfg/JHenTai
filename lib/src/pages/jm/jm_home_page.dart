import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/mixin/home_sync_mixin.dart';
import 'package:jhentai/src/mixin/scroll_to_top_logic_mixin.dart';
import 'package:jhentai/src/mixin/scroll_to_top_state_mixin.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/notification/tap_menu_button_notification.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/search_util.dart';
import 'package:jhentai/src/utils/snack_util.dart';
import 'package:jhentai/src/widget/eh_dashboard_card.dart';
import 'package:jhentai/src/widget/eh_wheel_speed_controller.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

import 'jm_list_page.dart';

/// JM's home: hot tags and the sections of the JM app's home page, each a
/// row of covers with its full list behind "see all".
class JmHomePage extends StatelessWidget {
  const JmHomePage({super.key, this.showMenuButton = false});

  final bool showMenuButton;

  JmHomePageLogic get logic => Get.put<JmHomePageLogic>(JmHomePageLogic(), permanent: true);

  JmHomePageState get state => Get.find<JmHomePageLogic>().state;

  @override
  Widget build(BuildContext context) {
    return GetBuilder<JmHomePageLogic>(
      global: false,
      init: logic,
      builder: (_) => Scaffold(
        backgroundColor: UIConfig.backGroundColor(context),
        appBar: AppBar(
          leading: showMenuButton
              ? IconButton(
                  icon: const Icon(Icons.menu, size: 20),
                  onPressed: () => TapMenuButtonNotification().dispatch(context),
                )
              : null,
          title: HomeSyncTitle(logic: logic, title: 'home'.tr),
          centerTitle: true,
        ),
        body: SafeArea(
          child: Column(
            children: [
              HomeSyncProgressBar(logic: logic),
              Expanded(child: _buildBody(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (state.sections.isEmpty) {
      return Center(
        child: LoadingStateIndicator(
          loadingState: state.loadingState,
          errorTapCallback: logic.load,
          noDataTapCallback: logic.load,
        ),
      );
    }

    return EHWheelSpeedController(
      controller: state.scrollController,
      child: CustomScrollView(
        controller: state.scrollController,
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        scrollBehavior: UIConfig.scrollBehaviourWithScrollBarWithMouse,
        slivers: [
          CupertinoSliverRefreshControl(
            refreshTriggerPullDistance: UIConfig.refreshTriggerPullDistance,
            onRefresh: () => logic.load(refresh: true),
          ),
          if (state.hotTags.isNotEmpty) _buildHotTags(),
          for (final JmHomeSection section in state.sections) ...[
            _buildSectionTitle(context, section),
            _buildShelf(section),
          ],
          const SliverPadding(padding: EdgeInsets.only(bottom: 40)),
        ],
      ),
    );
  }

  Widget _buildHotTags() {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 0),
      sliver: SliverToBoxAdapter(
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final String tag in state.hotTags)
              ActionChip(
                label: Text(tag),
                visualDensity: VisualDensity.compact,
                onPressed: () => newSearch(
                  rewriteSearchConfig: SearchConfig(keyword: tag, isJmSearch: true),
                  forceNewRoute: true,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, JmHomeSection section) {
    final JmListQuery? more = section.more;
    final String title = JmHomePageState.sectionTitle(section.title);
    return SliverPadding(
      padding: const EdgeInsets.only(left: 10, right: 10, top: 20, bottom: 8),
      sliver: SliverToBoxAdapter(
        child: Row(
          children: [
            Expanded(
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14), overflow: TextOverflow.ellipsis),
            ),
            if (more != null)
              TextButton(
                style: TextButton.styleFrom(padding: const EdgeInsets.only(left: 12), visualDensity: const VisualDensity(vertical: -4)),
                onPressed: () => toRoute(Routes.jmList, arguments: JmListPageArgument(title: title, query: more)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'seeAll'.tr,
                      style: TextStyle(color: UIConfig.dashboardPageSeeAllTextColor(context), fontSize: 12, height: 1),
                    ),
                    Icon(Icons.keyboard_arrow_right, color: UIConfig.dashboardPageArrowButtonColor(context)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildShelf(JmHomeSection section) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: UIConfig.dashboardCardSize,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          itemCount: section.gallerys.length,
          itemBuilder: (_, int index) => EHDashboardCard(gallery: section.gallerys[index]),
          separatorBuilder: (_, __) => const VerticalDivider(),
        ).enableMouseDrag(withScrollBar: false),
      ),
    );
  }
}

class JmHomePageLogic extends GetxController with Scroll2TopLogicMixin, HomeSyncLogicMixin {
  final JmHomePageState state = JmHomePageState();

  @override
  Scroll2TopStateMixin get scroll2TopState => state;

  @override
  void onInit() {
    super.onInit();
    load();
  }

  Future<void> load({bool refresh = false}) async {
    if (state.loadingState == LoadingState.loading) {
      return;
    }
    state.loadingState = LoadingState.loading;
    if (state.sections.isEmpty) {
      updateSafely();
    }

    try {
      state.sections = await ehRequest.jmSource.home(refresh: refresh);
    } catch (e) {
      log.error('Load JM home failed', e);
      snack('getGallerysFailed'.tr, e.toString(), isShort: true);
      state.loadingState = LoadingState.error;
      updateSafely();
      return;
    }

    try {
      state.hotTags = await ehRequest.jmSource.hotTags();
    } catch (e) {
      // The tags are a shortcut; the sections are the page.
      log.warning('Load JM hot tags failed', e);
    }

    state.loadingState = state.sections.isEmpty ? LoadingState.noData : LoadingState.success;
    updateSafely();
  }
}

class JmHomePageState with Scroll2TopStateMixin {
  List<JmHomeSection> sections = const <JmHomeSection>[];
  List<String> hotTags = const <String>[];
  LoadingState loadingState = LoadingState.idle;

  /// Section titles may end in a hint for the JM app, e.g.
  /// "連載更新→右滑看更多→".
  static String sectionTitle(String raw) {
    final String title = raw.split('→').first.trim();
    return title.isEmpty ? raw : title;
  }
}
