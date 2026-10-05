// Live requests to a third-party server whose response times vary widely.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/l18n/locale_text.dart';
import 'package:jhentai/src/model/jh_layout.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_api.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/pages/jm/jm_home_page.dart';
import 'package:jhentai/src/pages/jm/jm_list_page.dart';
import 'package:jhentai/src/pages/jm/jm_ranking_page.dart';
import 'package:jhentai/src/pages/jm/jm_weekly_page.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/widget/eh_dashboard_card.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

import 'support/e2e_app.dart';

/// The JM pages of the JM scheme, driven as a user would, against the live
/// JM API. Enabled by test/e2e/jm_e2e.json.
void main() {
  final File config = File('test/e2e/jm_e2e.json');
  final Map<dynamic, dynamic> settings = config.existsSync()
      ? jsonDecode(config.readAsStringSync()) as Map
      : const <String, dynamic>{};
  if (settings['enabled'] != true) {
    test('JM pages e2e', () {}, skip: 'test/e2e/jm_e2e.json is absent');
    return;
  }

  setUpAll(() {
    // flutter_test answers every HTTP request with 400 unless told not to.
    HttpOverrides.global = null;
    log = SilentLogService();
    List<String> domains = <String>[];
    ehRequest.jmSource = JmSource(
      api: JmApi(
        dio: Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(seconds: 60))),
        apiDomains: () => domains,
        onApiDomainsDiscovered: (List<String> latest) => domains = latest,
      ),
      imageDomain: () => JmApi.imageDomains.first,
    );
    styleSetting.actualLayout = LayoutMode.mobileV2;
  });

  setUp(() {
    appDb = AppDb.forTesting(NativeDatabase.memory());
    Get.testMode = true;
    // Gallery cards show reading progress; the app registers this at start.
    Get.put<ReadProgressService>(readProgressService, permanent: true);
  });

  tearDown(() async {
    Get.reset();
    await appDb.close();
  });

  Future<void> pumpApp(WidgetTester tester, Widget home) async {
    // Wide: the test font draws every glyph as a full square, so card
    // texts need more room than with real fonts.
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async => null);
    // Built outside the fake clock: the pages start requesting right away,
    // and real requests stall on the fake clock's timers.
    await tester.runAsync(
      () => tester.pumpWidget(
        GetMaterialApp(
          translations: LocaleText(),
          locale: const Locale('zh', 'CN'),
          home: home,
          getPages: [GetPage(name: Routes.jmList, page: JmListPage.new)],
        ),
      ),
    );
  }

  /// Taps outside the fake clock, for the same reason.
  Future<void> tapReal(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      await tester.pump();
    });
  }

  /// Lets real requests finish (they run outside the fake clock), then
  /// renders the result.
  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 90));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
    }
    expect(done(), isTrue, reason: 'timed out');
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('home shows the sections; "see all" opens the full list', (WidgetTester tester) async {
    await pumpApp(tester, const JmHomePage());
    final JmHomePageLogic home = Get.find<JmHomePageLogic>();
    await waitFor(tester, () => home.state.loadingState == LoadingState.success);

    expect(find.byType(EHDashboardCard), findsWidgets);
    final String firstTitle = JmHomePageState.sectionTitle(home.state.sections.first.title);
    expect(find.text(firstTitle), findsOneWidget);

    await tapReal(tester, find.text('查看全部').first);
    await tester.runAsync(() => tester.pump(const Duration(milliseconds: 500)));
    final JmListPageLogic list = Get.find<JmListPageLogic>(tag: (find.byType(JmListPage).evaluate().single.widget as JmListPage).tag);
    await waitFor(tester, () => list.state.gallerys.isNotEmpty);
    expect(find.text(firstTitle), findsWidgets);
  });

  testWidgets('ranking chips change the ranking', (WidgetTester tester) async {
    await pumpApp(tester, const JmRankingPage(showTitle: true, name: 'ranklist'));
    final JmRankingPageLogic ranking = Get.find<JmRankingPageLogic>();
    await waitFor(tester, () => ranking.state.gallerys.isNotEmpty && ranking.state.loadingState != LoadingState.loading);
    final List<int> weeklyViews = ranking.state.gallerys.map((g) => g.gid).toList();

    await tapReal(tester, find.text('喜欢最多'));
    await waitFor(tester, () => ranking.state.gallerys.isNotEmpty && ranking.state.loadingState != LoadingState.loading);
    expect(ranking.state.filter.order, 'tf');
    expect(ranking.state.filter.period, 'w');

    await tapReal(tester, find.text('今日'));
    await waitFor(tester, () => ranking.state.gallerys.isNotEmpty && ranking.state.loadingState != LoadingState.loading);
    expect(ranking.state.filter.period, 't');
    expect(ranking.state.gallerys.map((g) => g.gid).toList(), isNot(weeklyViews));
  });

  testWidgets('weekly picks open on the newest issue and switch kinds', (WidgetTester tester) async {
    await pumpApp(tester, const JmWeeklyPage(showTitle: true, name: 'weekly'));
    final JmWeeklyPageLogic weekly = Get.find<JmWeeklyPageLogic>();
    await waitFor(tester, () => weekly.state.gallerys.isNotEmpty);
    final JmWeekQuery first = weekly.state.query! as JmWeekQuery;
    expect(find.byKey(const Key('jmWeekIssue')), findsOneWidget);

    await tapReal(tester, find.text('日漫'));
    await waitFor(tester, () => weekly.state.gallerys.isNotEmpty && weekly.state.loadingState != LoadingState.loading);
    final JmWeekQuery second = weekly.state.query! as JmWeekQuery;
    expect(second.issueId, first.issueId);
    expect(second.type, isNot(first.type));
  });
}
