import 'dart:math';

import 'package:flutter/rendering.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/model/content_scheme.dart';
import 'package:jhentai/src/pages/download/download_base_page.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2_logic.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2_state.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/notification/tap_menu_button_notification.dart';
import 'package:jhentai/src/pages/search/quick_search/quick_search_page.dart';
import 'package:jhentai/src/pages/setting/setting_page.dart';
import 'package:jhentai/src/service/quick_search_service.dart';
import 'package:jhentai/src/utils/iphone_duo.dart';
import 'package:jhentai/src/widget/will_pop_interceptor.dart';

import '../../../setting/preference_setting.dart';
import '../../../widget/scheme_header.dart';
import 'notification/tap_tab_bat_button_notification.dart';

class MobileLayoutPageV2 extends StatelessWidget {
  final MobileLayoutPageV2Logic logic = Get.put(MobileLayoutPageV2Logic(), permanent: true);
  final MobileLayoutPageV2State state = Get.find<MobileLayoutPageV2Logic>().state;

  MobileLayoutPageV2({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => WillPopInterceptor(
        child: Scaffold(
          key: MobileLayoutPageV2State.scaffoldKey,
          drawerEdgeDragWidth: preferenceSetting.drawerGestureEdgeWidth.value.toDouble(),
          drawer: buildLeftDrawer(context),
          drawerEnableOpenDragGesture: preferenceSetting.enableLeftMenuDrawerGesture.isTrue,
          endDrawer: isIPhoneDuo ? buildPanel() : buildRightDrawer(),
          endDrawerEnableOpenDragGesture: isIPhoneDuo || preferenceSetting.enableQuickSearchDrawerGesture.isTrue,
          body: isIPhoneDuo ? buildBodyWithSideRail(context) : buildBody(),
          bottomNavigationBar: isIPhoneDuo || preferenceSetting.hideBottomBar.isTrue ? null : buildBottomNavigationBar(context),
        ),
      ),
    );
  }

  Widget buildLeftDrawer(BuildContext context) {
    return MobileLeftDrawer(logic: logic, state: state);
  }

  Widget buildRightDrawer() {
    return Drawer(width: 278, child: QuickSearchPage(scrollController: quickSearchService.drawerScrollController));
  }

  /// iPhone Duo: the drawer's content, on the side of the rail.
  Widget buildPanel() {
    return MobileLeftDrawer(
      logic: logic,
      state: state,
      atEnd: true,
      onBeforeSwitch: () => MobileLayoutPageV2State.scaffoldKey.currentState?.closeEndDrawer(),
    );
  }

  Widget buildBodyWithSideRail(BuildContext context) {
    return Row(
      children: [
        Expanded(child: MediaQuery.removePadding(context: context, removeRight: true, child: buildBody())),
        VerticalDivider(width: 1, color: UIConfig.layoutDividerColor(context)),
        MobileSideRail(logic: logic, state: state),
      ],
    );
  }

  Widget buildBottomNavigationBar(BuildContext context) {
    return GetBuilder<MobileLayoutPageV2Logic>(
      id: logic.bottomNavigationBarId,
      builder: (_) => Theme(
        data: Theme.of(context).copyWith(splashColor: Colors.transparent),
        child: NavigationBar(
          selectedIndex: state.selectedNavigationIndex,
          onDestinationSelected: logic.handleTapNavigationBarButton,
          destinations: [
            NavigationDestination(icon: const Icon(Icons.home), label: 'home'.tr),
            NavigationDestination(icon: const Icon(Icons.download), label: 'download'.tr),
            NavigationDestination(icon: const Icon(Icons.settings), label: 'setting'.tr),
          ],
        ),
      ),
    );
  }

  Widget buildBody() {
    return NotificationListener<TapTabBarButtonNotification>(
      child: NotificationListener<TapMenuButtonNotification>(
        child: GetBuilder<MobileLayoutPageV2Logic>(
          id: logic.bodyId,
          builder: (_) => Stack(
            children: [
              Offstage(offstage: state.selectedNavigationIndex != 0, child: buildHomeBody()),
              if (!isIPhoneDuo) Offstage(offstage: state.selectedNavigationIndex != 1, child: const DownloadPage()),
              if (!isIPhoneDuo) Offstage(offstage: state.selectedNavigationIndex != 2, child: const SettingPage()),
            ],
          ),
        ),
        onNotification: (_) {
          MobileLayoutPageV2State.scaffoldKey.currentState?.openDrawer();
          return true;
        },
      ),
      onNotification: (notification) {
        logic.handleTapTabBarButtonByRouteName(notification.routeName);
        return true;
      },
    );
  }

  /// use [shouldRender] to implement lazy load with [Offstage]
  Widget buildHomeBody() {
    return Stack(
      children: state.icons
          .where((icon) => icon.shouldRender)
          .mapIndexed(
            (index, icon) => Offstage(
              // Pages of two schemes may share a type; keep their states apart.
              key: ValueKey<String>(icon.routeName),
              offstage: state.selectedDrawerTabOrder != index,
              child: icon.page.call(),
            ),
          )
          .toList(),
    );
  }
}

/// The bar along the right edge on iPhone Duo, in place of the bottom bar: the
/// drawer's destinations, and a button for the panel that names them.
class MobileSideRail extends StatelessWidget {
  const MobileSideRail({super.key, required this.logic, required this.state});

  final MobileLayoutPageV2Logic logic;
  final MobileLayoutPageV2State state;

  @override
  Widget build(BuildContext context) {
    final EdgeInsets padding = MediaQuery.paddingOf(context);
    final double width = max(padding.right, UIConfig.sideRailMinWidth);

    // No inset along the edge: the status bar is along the top, in the padding.
    final double reservedHeight = padding.right == 0
        ? 0
        : MediaQuery.sizeOf(context).shortestSide < 600
            ? UIConfig.sideRailReservedHeightOuterDisplay
            : UIConfig.sideRailReservedHeightInnerDisplay;

    return Material(
      key: const ValueKey<String>('mobileSideRail'),
      child: Container(
        width: width,
        color: UIConfig.backGroundColor(context),
        padding: EdgeInsets.only(
          left: UIConfig.sideRailInnerMargin,
          top: max(padding.top, reservedHeight),
          right: width - UIConfig.sideRailItemSize - UIConfig.sideRailInnerMargin,
          bottom: max(padding.bottom, UIConfig.sideRailBottomMargin),
        ),
        child: GetBuilder<MobileLayoutPageV2Logic>(
          id: logic.tabBarId,
          builder: (_) => Column(
            children: [
              SizedBox(
                key: const ValueKey<String>('sideRail:panel'),
                height: UIConfig.sideRailItemSize,
                child: Center(
                  child: IconButton(
                    icon: const Icon(Icons.menu),
                    color: UIConfig.desktopLeftTabIconColor(context),
                    onPressed: () => MobileLayoutPageV2State.scaffoldKey.currentState?.openEndDrawer(),
                  ),
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ScrollConfiguration(
                    behavior: UIConfig.scrollBehaviourWithoutScrollBarWithMouse,
                    child: ListView.builder(
                      primary: false,
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: state.icons.length,
                      itemExtent: UIConfig.sideRailItemSize,
                      itemBuilder: _buildItem,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItem(BuildContext context, int index) {
    final bool selected = state.selectedDrawerTabIndex == index;

    return Center(
      key: ValueKey<String>('sideRail:${state.icons[index].name.name}'),
      child: IconButton(
        tooltip: state.icons[index].name.name.tr,
        icon: selected ? state.icons[index].selectedIcon : state.icons[index].unselectedIcon,
        color: UIConfig.desktopLeftTabIconColor(context),
        style: selected ? IconButton.styleFrom(backgroundColor: UIConfig.mobileDrawerSelectedTileColor(context)) : null,
        onPressed: () => logic.handleTapSideRailButton(index),
      ),
    );
  }
}

class MobileLeftDrawer extends StatelessWidget {
  const MobileLeftDrawer({
    super.key,
    required this.state,
    this.currentScheme,
    this.logic,
    this.onBeforeSwitch,
    this.onDestinationSelected,
    this.showSelectedDestination = true,
    this.atEnd = false,
  }) : assert(logic != null || onDestinationSelected != null);

  final MobileLayoutPageV2State state;
  final MobileLayoutPageV2Logic? logic;

  /// The scheme on screen, for pages of their own (Komga); null for the
  /// saved site.
  final ContentScheme? currentScheme;
  final VoidCallback? onBeforeSwitch;
  final ValueChanged<int>? onDestinationSelected;
  final bool showSelectedDestination;

  /// Opens from the right edge, across the inset there.
  final bool atEnd;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      key: const ValueKey<String>('mobileLeftDrawer'),
      width: atEnd ? 278 + MediaQuery.paddingOf(context).right : 278,
      child: logic == null
          ? _buildContent(context)
          : GetBuilder<MobileLayoutPageV2Logic>(
              id: logic!.tabBarId,
              builder: (_) => _buildContent(context),
            ),
    );
  }

  Widget _buildContent(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SchemeHeader(
            current: currentScheme,
            onBeforeSwitch: onBeforeSwitch ?? () => MobileLayoutPageV2State.scaffoldKey.currentState?.closeDrawer(),
          ),
          Expanded(
            child: ScrollConfiguration(
              behavior: UIConfig.leftDrawerPhysicsBehaviour,
              child: ListView.builder(
                key: const PageStorageKey('leftDrawer'),
                controller: state.scrollController,
                itemCount: state.icons.length,
                scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
                itemBuilder: (context, index) => ListTile(
                  key: ValueKey<String>(
                    'readerMenu:${state.icons[index].name.name}',
                  ),
                  dense: true,
                  title: Text(
                    state.icons[index].name.name.tr,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  selected:
                      showSelectedDestination &&
                      state.selectedDrawerTabIndex == index,
                  selectedTileColor: UIConfig.mobileDrawerSelectedTileColor(
                    context,
                  ),
                  leading: state.icons[index].unselectedIcon,
                  shape: RoundedRectangleBorder(
                    borderRadius: atEnd
                        ? const BorderRadiusDirectional.only(
                            topStart: Radius.circular(32),
                            bottomStart: Radius.circular(32),
                          )
                        : const BorderRadiusDirectional.only(
                            topEnd: Radius.circular(32),
                            bottomEnd: Radius.circular(32),
                          ),
                  ),
                  onTap: () {
                    if (onDestinationSelected != null) {
                      onDestinationSelected!(index);
                      return;
                    }
                    logic!.handleTapTabBarButton(index);
                  },
                ).marginOnly(left: atEnd ? 8 : 0, right: atEnd ? 0 : 8, top: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
