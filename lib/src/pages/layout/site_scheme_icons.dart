import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/content_scheme.dart';
import 'package:jhentai/src/model/tab_bar_icon.dart';
import 'package:jhentai/src/pages/jm/jm_browse_page.dart';
import 'package:jhentai/src/pages/jm/jm_home_page.dart';
import 'package:jhentai/src/pages/jm/jm_ranking_page.dart';
import 'package:jhentai/src/pages/jm/jm_weekly_page.dart';
import 'package:jhentai/src/pages/site/site_gallerys_page.dart';

/// Navigation of a site scheme other than E-Hentai: the site's own pages
/// around [search], then the [shared] entries (favorites, history,
/// downloads, settings). [mobile] pages carry the button that opens the
/// drawer.
List<TabBarIcon> siteSchemeIcons(
  ContentScheme scheme, {
  required bool mobile,
  required TabBarIcon search,
  required List<TabBarIcon> shared,
}) {
  switch (scheme) {
    case ContentScheme.nhentai:
      return [_siteHome(scheme, mobile), search, _sitePopular(scheme, mobile), ...shared];
    case ContentScheme.wnacg:
      return [_siteHome(scheme, mobile), search, ...shared];
    case ContentScheme.jm:
      return [
        TabBarIcon(
          name: TabBarIconNameEnum.home,
          routeName: '/scheme/jm/home',
          selectedIcon: const Icon(Icons.home),
          unselectedIcon: const Icon(Icons.home_outlined),
          page: () => JmHomePage(showMenuButton: mobile),
          scrollController: () => Get.find<JmHomePageLogic>().state.scrollController,
          shouldRender: false,
        ),
        TabBarIcon(
          name: TabBarIconNameEnum.browse,
          routeName: '/scheme/jm/browse',
          selectedIcon: const Icon(Icons.category),
          unselectedIcon: const Icon(Icons.category_outlined),
          page: () => JmBrowsePage(showMenuButton: mobile, showTitle: true, name: 'browse'.tr),
          scrollController: () => Get.find<JmBrowsePageLogic>().state.scrollController,
          shouldRender: false,
        ),
        TabBarIcon(
          name: TabBarIconNameEnum.ranklist,
          routeName: '/scheme/jm/ranking',
          selectedIcon: const Icon(Icons.bar_chart_rounded, shadows: [Shadow(blurRadius: 2)]),
          unselectedIcon: const Icon(Icons.bar_chart_outlined),
          page: () => JmRankingPage(showMenuButton: mobile, showTitle: true, name: 'ranklist'.tr),
          scrollController: () => Get.find<JmRankingPageLogic>().state.scrollController,
          shouldRender: false,
        ),
        TabBarIcon(
          name: TabBarIconNameEnum.weekly,
          routeName: '/scheme/jm/weekly',
          selectedIcon: const Icon(Icons.event_note),
          unselectedIcon: const Icon(Icons.event_note_outlined),
          page: () => JmWeeklyPage(showMenuButton: mobile, showTitle: true, name: 'weekly'.tr),
          scrollController: () => Get.find<JmWeeklyPageLogic>().state.scrollController,
          shouldRender: false,
        ),
        search,
        ...shared,
      ];
    default:
      throw ArgumentError.value(scheme, 'scheme', 'E-Hentai and reading sources have navigation of their own');
  }
}

TabBarIcon _siteHome(ContentScheme scheme, bool mobile) => TabBarIcon(
  name: TabBarIconNameEnum.home,
  routeName: '/scheme/${scheme.name}/home',
  selectedIcon: const Icon(Icons.home),
  unselectedIcon: const Icon(Icons.home_outlined),
  page: () => SiteGallerysPage(scheme: scheme, showMenuButton: mobile, showTitle: true, name: 'home'.tr),
  scrollController: () => SiteGallerysPage(scheme: scheme).state.scrollController,
  shouldRender: false,
);

TabBarIcon _sitePopular(ContentScheme scheme, bool mobile) => TabBarIcon(
  name: TabBarIconNameEnum.popular,
  routeName: '/scheme/${scheme.name}/popular',
  selectedIcon: const Icon(Icons.whatshot),
  unselectedIcon: const Icon(Icons.whatshot_outlined),
  page: () => SiteGallerysPage(scheme: scheme, popular: true, showMenuButton: mobile, showTitle: true, name: 'popular'.tr),
  scrollController: () => SiteGallerysPage(scheme: scheme, popular: true).state.scrollController,
  shouldRender: false,
);
