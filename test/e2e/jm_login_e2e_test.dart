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
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_api.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/pages/setting/account/login/login_page.dart';
import 'package:jhentai/src/pages/setting/account/login/login_page_logic.dart';
import 'package:jhentai/src/pages/setting/account/setting_account_page.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/jm_setting.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

import 'support/e2e_app.dart';

/// The login page's site picker and the account page, with JM logins sent
/// to the live JM API. Enabled by test/e2e/jm_e2e.json.
void main() {
  final File config = File('test/e2e/jm_e2e.json');
  final Map<dynamic, dynamic> settings = config.existsSync()
      ? jsonDecode(config.readAsStringSync()) as Map
      : const <String, dynamic>{};
  if (settings['enabled'] != true) {
    test('JM login e2e', () {}, skip: 'test/e2e/jm_e2e.json is absent');
    return;
  }

  late JmApi api;

  setUpAll(() {
    // flutter_test answers every HTTP request with 400 unless told not to.
    HttpOverrides.global = null;
    log = SilentLogService();
    List<String> domains = <String>[];
    api = JmApi(
      dio: Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 60),
        ),
      ),
      apiDomains: () => domains,
      onApiDomainsDiscovered: (List<String> latest) => domains = latest,
      accountCookie: () => jmSetting.accountCookie,
    );
    ehRequest.jmSource = JmSource(api: api, imageDomain: () => JmApi.imageDomains.first);
  });

  setUp(() {
    appDb = AppDb.forTesting(NativeDatabase.memory());
    jmSetting.applyBeanConfig('{}');
  });

  tearDown(() async {
    Get.reset();
    await appDb.close();
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    // The page looks for a copied E-Hentai cookie on open.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async => null);
    await tester.pumpWidget(GetMaterialApp(home: page));
    await tester.pump();
  }

  /// Taps [finder] outside the fake clock, so the network round trip it
  /// starts runs in real time, and waits for [done].
  Future<void> tapAndWait(WidgetTester tester, Finder finder, bool Function() done) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 60));
      while (!done() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    expect(done(), isTrue, reason: 'timed out');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('the site picker switches between the three login forms', (WidgetTester tester) async {
    await pumpPage(tester, LoginPage());

    // Nothing is logged in: E-Hentai comes first, with its three tabs.
    expect(find.text('E-Hentai'), findsOneWidget);
    expect(find.text('passwordTab'), findsOneWidget);

    await tester.tap(find.byKey(const Key('loginSite')));
    await tester.pumpAndSettle();
    expect(find.text('nhentai'), findsWidgets);
    expect(find.text('JM'), findsWidgets);
    await tester.tap(find.text('nhentai').last);
    await tester.pumpAndSettle();
    expect(find.text('passwordTab'), findsNothing);
    expect(find.byKey(const Key('nhApiKey')), findsOneWidget);
    expect(find.text('nhentaiApiKeyHint'), findsOneWidget);

    await tester.tap(find.byKey(const Key('loginSite')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JM').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nhApiKey')), findsNothing);
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(find.text('login'), findsOneWidget);
  });

  testWidgets('a refused JM login shows the server message and keeps nobody logged in', (WidgetTester tester) async {
    String? serverMessage;
    await tester.runAsync(() async {
      try {
        await api.login('jhentai-e2e-no-such-user-7f3a', 'not-a-password');
      } on JmApiException catch (e) {
        serverMessage = e.message;
      }
    });
    expect(serverMessage, isNotEmpty);

    await pumpPage(tester, LoginPage());
    await tester.tap(find.byKey(const Key('loginSite')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JM').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'jhentai-e2e-no-such-user-7f3a');
    await tester.enterText(find.byType(TextFormField).at(1), 'not-a-password');
    final LoginPageLogic logic = Get.find<LoginPageLogic>();
    await tapAndWait(tester, find.text('login'), () => logic.state.loginState == LoadingState.error);

    expect(find.text('loginFail'), findsOneWidget);
    expect(find.text(serverMessage!), findsOneWidget);
    expect(jmSetting.hasLoggedIn, isFalse);
  });

  testWidgets(
    'a JM account logs in from the page and keeps its session',
    (WidgetTester tester) async {
      await pumpPage(tester, LoginPage());
      await tester.tap(find.byKey(const Key('loginSite')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('JM').last);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).at(0), '${settings['username']}');
      await tester.enterText(find.byType(TextFormField).at(1), '${settings['password']}');
      final LoginPageLogic logic = Get.find<LoginPageLogic>();
      await tapAndWait(tester, find.text('login'), () => logic.state.loginState != LoadingState.loading && logic.state.loginState != LoadingState.idle);

      expect(logic.state.loginState, LoadingState.success);
      expect(jmSetting.hasLoggedIn, isTrue);
      expect(jmSetting.accountCookie, contains('AVS='));
    },
    skip: '${settings['username'] ?? ''}'.isEmpty || '${settings['password'] ?? ''}'.isEmpty,
  );

  testWidgets('the account page lists the JM account and logs it out', (WidgetTester tester) async {
    await tester.runAsync(() => jmSetting.saveAccount(const JmUser(id: 7, username: 'reader'), 'AVS=session'));
    await pumpPage(tester, const SettingAccountPage());

    // E-Hentai and nhentai still have no account, so the entry stays.
    expect(find.text('login'), findsOneWidget);
    expect(find.text('JM'), findsOneWidget);
    expect(find.textContaining('reader'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(jmSetting.hasLoggedIn, isFalse);
    expect(jmSetting.accountCookie, isEmpty);
    expect(find.text('JM'), findsNothing);
  });
}
