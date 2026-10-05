import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';

import '../base/base_page.dart';
import 'jm_filter_bar.dart';
import 'jm_list_page.dart';

/// JM albums by category and order; serialised comics such as Korean
/// webtoons are found here by category.
class JmBrowsePage extends BasePage<JmBrowsePageLogic, JmBrowsePageState> {
  const JmBrowsePage({super.key, super.showMenuButton, super.showTitle, super.name})
      : super(showScroll2TopButton: true);

  @override
  JmBrowsePageLogic get logic => Get.put<JmBrowsePageLogic>(JmBrowsePageLogic(), permanent: true);

  @override
  JmBrowsePageState get state => Get.find<JmBrowsePageLogic>().state;

  @override
  Widget buildBody(BuildContext context) {
    return Column(
      children: [
        GetBuilder<JmBrowsePageLogic>(
          id: logic.appBarId,
          global: false,
          init: logic,
          builder: (_) {
            final JmFilterQuery query = state.filter;
            return Column(
              children: [
                JmCategoryRow(
                  selected: query.category,
                  onSelected: (String category) => logic.showQuery(JmFilterQuery(category: category, order: query.order)),
                ),
                JmChoiceRow<String>(
                  choices: jmOrders(),
                  selected: query.order,
                  onSelected: (String order) => logic.showQuery(JmFilterQuery(category: query.category, order: order)),
                ),
              ],
            );
          },
        ),
        Expanded(child: buildListBody(context)),
      ],
    );
  }
}

class JmBrowsePageLogic extends JmQueryPageLogic {
  @override
  final JmBrowsePageState state = JmBrowsePageState();

  @override
  Future<JmListQuery> defaultQuery() async => const JmFilterQuery();
}

class JmBrowsePageState extends JmQueryPageState {
  JmBrowsePageState() : super(storageKey: 'jmBrowse');

  JmFilterQuery get filter => query as JmFilterQuery? ?? const JmFilterQuery();

  @override
  String get route => 'jm/browse';
}
