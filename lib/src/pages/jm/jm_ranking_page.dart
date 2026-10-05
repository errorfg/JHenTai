import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';

import '../base/base_page.dart';
import 'jm_filter_bar.dart';
import 'jm_list_page.dart';

/// JM rankings: most viewed or most liked over a day, week, month or all
/// time, overall or in one category.
class JmRankingPage extends BasePage<JmRankingPageLogic, JmRankingPageState> {
  const JmRankingPage({super.key, super.showMenuButton, super.showTitle, super.name})
      : super(showScroll2TopButton: true);

  @override
  JmRankingPageLogic get logic => Get.put<JmRankingPageLogic>(JmRankingPageLogic(), permanent: true);

  @override
  JmRankingPageState get state => Get.find<JmRankingPageLogic>().state;

  @override
  Widget buildBody(BuildContext context) {
    return Column(
      children: [
        GetBuilder<JmRankingPageLogic>(
          id: logic.appBarId,
          global: false,
          init: logic,
          builder: (_) {
            final JmFilterQuery query = state.filter;
            JmFilterQuery changed({String? category, String? order, String? period}) => JmFilterQuery(
              category: category ?? query.category,
              order: order ?? query.order,
              period: period ?? query.period,
            );
            return Column(
              children: [
                JmChoiceRow<String>(
                  choices: [
                    (value: 't', label: 'periodToday'.tr),
                    (value: 'w', label: 'periodWeek'.tr),
                    (value: 'm', label: 'periodMonth'.tr),
                    (value: 'a', label: 'allTime'.tr),
                  ],
                  selected: query.period,
                  onSelected: (String period) => logic.showQuery(changed(period: period)),
                ),
                JmChoiceRow<String>(
                  choices: jmOrders(ranking: true),
                  selected: query.order,
                  onSelected: (String order) => logic.showQuery(changed(order: order)),
                ),
                JmCategoryRow(
                  selected: query.category,
                  onSelected: (String category) => logic.showQuery(changed(category: category)),
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

class JmRankingPageLogic extends JmQueryPageLogic {
  @override
  final JmRankingPageState state = JmRankingPageState();

  @override
  Future<JmListQuery> defaultQuery() async => JmRankingPageState.defaultFilter;
}

class JmRankingPageState extends JmQueryPageState {
  JmRankingPageState() : super(storageKey: 'jmRanking');

  static const JmFilterQuery defaultFilter = JmFilterQuery(order: 'mv', period: 'w');

  JmFilterQuery get filter => query as JmFilterQuery? ?? defaultFilter;

  @override
  String get route => 'jm/ranking';
}
