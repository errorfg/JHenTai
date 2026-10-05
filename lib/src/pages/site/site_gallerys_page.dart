import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/content_scheme.dart';
import 'package:jhentai/src/mixin/home_sync_mixin.dart';
import 'package:jhentai/src/model/search_config.dart';

import '../base/base_page.dart';
import '../base/base_page_logic.dart';
import '../base/base_page_state.dart';

/// The newest, or the popular, galleries of nhentai or wnacg, served by the
/// same requests as a site search with an empty keyword.
class SiteGallerysPage extends BasePage<SiteGallerysPageLogic, SiteGallerysPageState> {
  const SiteGallerysPage({
    super.key,
    required this.scheme,
    this.popular = false,
    super.showMenuButton,
    super.showTitle,
    super.name,
  }) : super(showScroll2TopButton: true, showJumpButton: false);

  final ContentScheme scheme;
  final bool popular;

  String get _tag => '${scheme.name}:${popular ? 'popular' : 'home'}';

  @override
  SiteGallerysPageLogic get logic => Get.isRegistered<SiteGallerysPageLogic>(tag: _tag)
      ? Get.find<SiteGallerysPageLogic>(tag: _tag)
      : Get.put<SiteGallerysPageLogic>(SiteGallerysPageLogic(scheme: scheme, popular: popular), tag: _tag, permanent: true);

  @override
  SiteGallerysPageState get state => logic.state;
}

class SiteGallerysPageLogic extends BasePageLogic with HomeSyncLogicMixin {
  SiteGallerysPageLogic({required ContentScheme scheme, required this.popular})
      : state = SiteGallerysPageState(scheme: scheme, popular: popular);

  final bool popular;

  /// The site's home syncs from its title; its popular page does not.
  @override
  bool get homeSyncEnabled => !popular;

  @override
  final SiteGallerysPageState state;

  @override
  bool get useSearchConfig => false;
}

class SiteGallerysPageState extends BasePageState {
  SiteGallerysPageState({required this.scheme, required bool popular}) {
    searchConfig = SearchConfig(
      searchType: popular ? SearchType.popular : SearchType.gallery,
      isNhSearch: scheme == ContentScheme.nhentai,
      isWnacgSearch: scheme == ContentScheme.wnacg,
    );
    pageStorageKey = PageStorageKey<String>('site:${scheme.name}:${popular ? 'popular' : 'home'}');
  }

  final ContentScheme scheme;

  @override
  String get route => 'site/${scheme.name}/${searchConfig.searchType.name}';
}
