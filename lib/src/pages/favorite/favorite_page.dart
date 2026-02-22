import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';

import '../base/base_page.dart';
import 'favorite_page_logic.dart';
import 'favorite_page_state.dart';

class FavoritePage extends BasePage {
  const FavoritePage({
    Key? key,
    bool showMenuButton = false,
    bool showTitle = false,
    String? name,
  }) : super(
          key: key,
          showMenuButton: showMenuButton,
          showJumpButton: true,
          showFilterButton: true,
          showScroll2TopButton: true,
          showTitle: showTitle,
          name: name,
        );

  @override
  FavoritePageLogic get logic => Get.put<FavoritePageLogic>(FavoritePageLogic(), permanent: true);

  @override
  FavoritePageState get state => Get.find<FavoritePageLogic>().state;

  @override
  List<Widget> buildAppBarActions() {
    return [
      if (state.gallerys.isNotEmpty && !state.showNhFavorites && !state.showWnFavorites)
        IconButton(icon: const Icon(FontAwesomeIcons.paperPlane, size: 20), onPressed: logic.handleTapJumpButton),
      if (state.gallerys.isNotEmpty)
        IconButton(icon: const Icon(Icons.sort), onPressed: logic.handleChangeSortOrder),
      if (!state.mixedMode)
        PopupMenuButton<String>(
          icon: const Icon(Icons.swap_horiz),
          onSelected: (value) => logic.handleSwitchFavoriteSource(value),
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'EH',
              enabled: state.showNhFavorites || state.showWnFavorites,
              child: Text('EH ${'favorite'.tr}'),
            ),
            PopupMenuItem(
              value: 'NH',
              enabled: !state.showNhFavorites,
              child: Text('nhentaiFavorite'.tr),
            ),
            PopupMenuItem(
              value: 'WN',
              enabled: !state.showWnFavorites,
              child: Text('wnacgFavorite'.tr),
            ),
          ],
        ),
      IconButton(icon: const Icon(Icons.filter_alt_outlined, size: 28), onPressed: logic.handleTapFilterButton),
    ];
  }
}
