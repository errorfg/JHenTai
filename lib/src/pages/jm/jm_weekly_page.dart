import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';

import '../base/base_page.dart';
import 'jm_filter_bar.dart';
import 'jm_list_page.dart';

/// JM's weekly picks: one issue per week, split into Korean webtoons,
/// Japanese manga and others.
class JmWeeklyPage extends BasePage<JmWeeklyPageLogic, JmWeeklyPageState> {
  const JmWeeklyPage({super.key, super.showMenuButton, super.showTitle, super.name})
      : super(showScroll2TopButton: true);

  @override
  JmWeeklyPageLogic get logic => Get.put<JmWeeklyPageLogic>(JmWeeklyPageLogic(), permanent: true);

  @override
  JmWeeklyPageState get state => Get.find<JmWeeklyPageLogic>().state;

  @override
  Widget buildBody(BuildContext context) {
    return Column(
      children: [
        FutureBuilder<JmWeeks>(
          future: ehRequest.jmSource.weeks(),
          builder: (_, AsyncSnapshot<JmWeeks> snapshot) {
            final JmWeeks? weeks = snapshot.data;
            if (weeks == null || weeks.issues.isEmpty) {
              return const SizedBox(height: 44);
            }
            return GetBuilder<JmWeeklyPageLogic>(
              id: logic.appBarId,
              global: false,
              init: logic,
              builder: (_) {
                final JmWeekQuery query = state.query as JmWeekQuery? ??
                    JmWeekQuery(issueId: weeks.issues.first.id, type: weeks.types.first.id);
                // Issue names are long ("2026第259期10.02 - 09.25"): the
                // picker takes its own row.
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: DropdownButton<String>(
                        key: const Key('jmWeekIssue'),
                        value: query.issueId,
                        isExpanded: true,
                        underline: const SizedBox(),
                        items: [
                          for (final ({String id, String title}) issue in weeks.issues)
                            DropdownMenuItem<String>(value: issue.id, child: Text(issue.title)),
                        ],
                        onChanged: (String? issueId) {
                          if (issueId != null) {
                            logic.showQuery(JmWeekQuery(issueId: issueId, type: query.type));
                          }
                        },
                      ),
                    ),
                    JmChoiceRow<String>(
                      choices: [for (final ({String id, String title}) type in weeks.types) (value: type.id, label: type.title)],
                      selected: query.type,
                      onSelected: (String type) => logic.showQuery(JmWeekQuery(issueId: query.issueId, type: type)),
                    ),
                  ],
                );
              },
            );
          },
        ),
        Expanded(child: buildListBody(context)),
      ],
    );
  }
}

class JmWeeklyPageLogic extends JmQueryPageLogic {
  @override
  final JmWeeklyPageState state = JmWeeklyPageState();

  /// The newest issue, first kind.
  @override
  Future<JmListQuery> defaultQuery() async {
    final JmWeeks weeks = await ehRequest.jmSource.weeks();
    return JmWeekQuery(issueId: weeks.issues.first.id, type: weeks.types.first.id);
  }
}

class JmWeeklyPageState extends JmQueryPageState {
  JmWeeklyPageState() : super(storageKey: 'jmWeekly');

  @override
  String get route => 'jm/weekly';
}
