import 'package:get/get.dart';

import '../../model/tab_bar_icon.dart';
import '../../routes/routes.dart';
import '../../setting/style_setting.dart';
import '../../utils/route_util.dart';
import '../layout/desktop/desktop_layout_page_logic.dart';
import '../layout/mobile_v2/mobile_layout_page_v2_logic.dart';
import 'watched_page_logic.dart';

/// Shows the E-Hentai watched list from the gallery [gid] on: in the
/// layout's watched tab (on a phone the pages above it are closed first; on
/// a tablet or desktop the details stay in the right column), or, when the
/// layout has no such tab (another site is chosen), on a page of its own.
void showInWatched(int gid) {
  if (!_toWatchedTab()) {
    toRoute(Routes.watched);
  }
  Get.put<WatchedPageLogic>(WatchedPageLogic(), permanent: true).showFrom(gid);
}

bool _toWatchedTab() {
  bool isWatched(TabBarIcon icon) => icon.routeName == Routes.watched && !icon.enterNewRoute;

  if (styleSetting.isInDesktopLayout) {
    if (!Get.isRegistered<DesktopLayoutPageLogic>()) {
      return false;
    }
    final DesktopLayoutPageLogic desktop = Get.find<DesktopLayoutPageLogic>();
    final int index = desktop.state.icons.indexWhere(isWatched);
    if (index < 0) {
      return false;
    }
    desktop.handleTapTabBarButton(index);
    return true;
  }

  if (!Get.isRegistered<MobileLayoutPageV2Logic>()) {
    return false;
  }
  final MobileLayoutPageV2Logic mobile = Get.find<MobileLayoutPageV2Logic>();
  final int index = mobile.state.icons.indexWhere(isWatched);
  if (index < 0) {
    return false;
  }
  if (styleSetting.isInMobileLayout) {
    Get.until((route) => route.settings.name == Routes.home);
  } else {
    // The tablet's left column, whose first page holds the tabs.
    untilRoute(currentRoute: Routes.watched, predicate: (route) => route.settings.name == Routes.mobileLayoutV2);
  }
  mobile.handleTapTabBarButton(index);
  return true;
}
