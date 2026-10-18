import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/jh_layout.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/widget/app_manager.dart';
import 'package:jhentai/src/widget/rotation_suggestion.dart';
import 'package:sensors_plus/sensors_plus.dart';

class _SilentLogService extends LogService {
  @override
  void trace(Object msg, [bool withStack = false]) {}
  @override
  void debug(Object msg, [bool withStack = false]) {}
  @override
  void info(Object msg, [bool withStack = false]) {}
  @override
  void warning(Object msg, [Object? error, bool withStack = false]) {}
  @override
  void error(Object msg, [Object? error, StackTrace? stackTrace]) {}
}

const double _g = 9.81;

/// What the accelerometer reads with the device held [held].
AccelerometerEvent _reading(HeldOrientation held) {
  switch (held) {
    case HeldOrientation.portraitUp:
      return AccelerometerEvent(0, _g, 0, DateTime.now());
    case HeldOrientation.portraitDown:
      return AccelerometerEvent(0, -_g, 0, DateTime.now());
    case HeldOrientation.landscapeTopLeft:
      return AccelerometerEvent(_g, 0, 0, DateTime.now());
    case HeldOrientation.landscapeTopRight:
      return AccelerometerEvent(-_g, 0, 0, DateTime.now());
  }
}

void main() {
  setUpAll(() => log = _SilentLogService());

  group('the way up', () {
    test('is the quarter turn nearest gravity in the screen\'s plane', () {
      expect(heldOrientationOf(0, _g, 0), HeldOrientation.portraitUp);
      expect(heldOrientationOf(_g, 0, 0), HeldOrientation.landscapeTopLeft);
      expect(heldOrientationOf(-_g, 0, 0), HeldOrientation.landscapeTopRight);
      expect(heldOrientationOf(0, -_g, 0), HeldOrientation.portraitDown);
      // Tilted 20° and leaned back 50°: still upright.
      expect(heldOrientationOf(2.1, 5.9, 7.5), HeldOrientation.portraitUp);
    });

    test('is unclear lying flat, or halfway between two turns', () {
      expect(heldOrientationOf(0, 0, _g), isNull);
      expect(heldOrientationOf(0, 3, 9.3), isNull, reason: 'under 30° up from flat');
      expect(heldOrientationOf(6.9, 6.9, 0), isNull, reason: '45°, between upright and landscape');
      expect(heldOrientationOf(0, 0, 0), isNull);
    });

    test('turns the screen the same way up on Android and iOS, whose landscapeLeft are opposite', () {
      expect(screenOrientationFor(HeldOrientation.landscapeTopLeft, ios: false), DeviceOrientation.landscapeLeft);
      expect(screenOrientationFor(HeldOrientation.landscapeTopLeft, ios: true), DeviceOrientation.landscapeRight);
      expect(screenOrientationFor(HeldOrientation.landscapeTopRight, ios: false), DeviceOrientation.landscapeRight);
      expect(screenOrientationFor(HeldOrientation.landscapeTopRight, ios: true), DeviceOrientation.landscapeLeft);
      expect(screenOrientationFor(HeldOrientation.portraitUp, ios: true), DeviceOrientation.portraitUp);
    });

    test('of an iOS screen follows UIInterfaceOrientation, whose landscapeRight has the Home button on the right', () {
      expect(heldOrientationOfInterface(1), HeldOrientation.portraitUp);
      expect(heldOrientationOfInterface(2), HeldOrientation.portraitDown);
      expect(heldOrientationOfInterface(3), HeldOrientation.landscapeTopLeft);
      expect(heldOrientationOfInterface(4), HeldOrientation.landscapeTopRight);
      expect(heldOrientationOfInterface(0), isNull);
      expect(heldOrientationOfInterface(null), isNull);
    });
  });

  group('the interface turned within the app', () {
    test('is turned against the device', () {
      // Device turned counterclockwise: the interface turns clockwise.
      expect(quarterTurnsBetween(HeldOrientation.portraitUp, HeldOrientation.landscapeTopLeft), 1);
      expect(quarterTurnsBetween(HeldOrientation.portraitUp, HeldOrientation.landscapeTopRight), 3);
      expect(quarterTurnsBetween(HeldOrientation.portraitUp, HeldOrientation.portraitDown), 2);
      expect(quarterTurnsBetween(HeldOrientation.landscapeTopLeft, HeldOrientation.portraitUp), 3);
      expect(quarterTurnsBetween(HeldOrientation.landscapeTopRight, HeldOrientation.landscapeTopRight), 0);
    });

    test('sees the window turned, and the bars and keyboard on the sides they fall on', () {
      const MediaQueryData screen = MediaQueryData(
        size: Size(800, 1200),
        padding: EdgeInsets.fromLTRB(0, 24, 0, 20),
        viewInsets: EdgeInsets.only(bottom: 300),
      );

      // Turned clockwise: the screen's top is on the interface's left.
      final MediaQueryData clockwise = turnedMediaQuery(screen, 1);
      expect(clockwise.size, const Size(1200, 800));
      expect(clockwise.orientation, Orientation.landscape);
      expect(clockwise.padding, const EdgeInsets.fromLTRB(24, 0, 20, 0));
      expect(clockwise.viewInsets, const EdgeInsets.only(right: 300));

      final MediaQueryData counterclockwise = turnedMediaQuery(screen, 3);
      expect(counterclockwise.padding, const EdgeInsets.fromLTRB(20, 0, 24, 0));
      expect(counterclockwise.viewInsets, const EdgeInsets.only(left: 300));

      final MediaQueryData upsideDown = turnedMediaQuery(screen, 2);
      expect(upsideDown.size, screen.size);
      expect(upsideDown.padding, const EdgeInsets.fromLTRB(0, 20, 0, 24));

      expect(turnedMediaQuery(screen, 0), same(screen));
    });
  });

  group('the offer to turn the screen', () {
    late StreamController<AccelerometerEvent> sensor;
    late bool screenIsPortrait;
    late RotationSuggester suggester;

    setUp(() {
      sensor = StreamController<AccelerometerEvent>.broadcast();
      screenIsPortrait = true;
      suggester = RotationSuggester(events: () => sensor.stream, screenIsPortrait: () => screenIsPortrait, supported: true);
    });

    tearDown(() {
      suggester.stop();
      sensor.close();
    });

    Future<void> hold(WidgetTester tester, HeldOrientation held, {Duration for_ = const Duration(milliseconds: 200)}) async {
      // Started in the test, so that its timers run on the test's clock.
      if (!suggester.running) {
        suggester.start();
      }
      sensor.add(_reading(held));
      await tester.pump(for_);
    }

    testWidgets('is made once the device has been held another way for a moment, and stands for 5 seconds', (WidgetTester tester) async {
      await hold(tester, HeldOrientation.portraitUp);
      expect(suggester.offer.value, isNull, reason: 'held as the screen shows');

      await hold(tester, HeldOrientation.landscapeTopLeft, for_: const Duration(milliseconds: 400));
      expect(suggester.offer.value, isNull, reason: 'not yet settled');
      await tester.pump(const Duration(milliseconds: 300));
      expect(suggester.offer.value, HeldOrientation.landscapeTopLeft);

      // Still held so: the offer stands 5 seconds, then goes, and is not
      // made again while the device stays so.
      for (int i = 0; i < 4; i++) {
        await hold(tester, HeldOrientation.landscapeTopLeft, for_: const Duration(seconds: 1));
      }
      expect(suggester.offer.value, HeldOrientation.landscapeTopLeft);
      await tester.pump(const Duration(seconds: 1));
      expect(suggester.offer.value, isNull);
      await hold(tester, HeldOrientation.landscapeTopLeft, for_: const Duration(seconds: 2));
      expect(suggester.offer.value, isNull);

      // Turned the other way: offered for that side.
      await hold(tester, HeldOrientation.landscapeTopRight, for_: const Duration(seconds: 1));
      expect(suggester.offer.value, HeldOrientation.landscapeTopRight);

      // Back upright: the offer goes at once; turned again, it is made again.
      await hold(tester, HeldOrientation.portraitUp);
      expect(suggester.offer.value, isNull);
      await hold(tester, HeldOrientation.landscapeTopLeft, for_: const Duration(seconds: 1));
      expect(suggester.offer.value, HeldOrientation.landscapeTopLeft);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('is not made for a glance, lying flat, or upside down', (WidgetTester tester) async {
      await hold(tester, HeldOrientation.landscapeTopLeft, for_: const Duration(milliseconds: 300));
      await hold(tester, HeldOrientation.portraitUp, for_: const Duration(seconds: 1));
      expect(suggester.offer.value, isNull, reason: 'turned back before it settled');

      sensor.add(AccelerometerEvent(0, 0, _g, DateTime.now()));
      await tester.pump(const Duration(seconds: 1));
      await hold(tester, HeldOrientation.portraitDown, for_: const Duration(seconds: 1));
      expect(suggester.offer.value, isNull);
    });

    testWidgets('where the interface is turned within the app, is made for each way up, upside down too', (WidgetTester tester) async {
      HeldOrientation shown = HeldOrientation.landscapeTopLeft;
      suggester = RotationSuggester(events: () => sensor.stream, shownUp: () => shown, recheck: () async {}, supported: true);

      await hold(tester, HeldOrientation.landscapeTopLeft, for_: const Duration(seconds: 1));
      expect(suggester.offer.value, isNull, reason: 'shown as held');
      await hold(tester, HeldOrientation.landscapeTopRight, for_: const Duration(seconds: 1));
      expect(suggester.offer.value, HeldOrientation.landscapeTopRight, reason: 'landscape, but the other way up');
      await hold(tester, HeldOrientation.portraitDown, for_: const Duration(seconds: 1));
      expect(suggester.offer.value, HeldOrientation.portraitDown);

      shown = HeldOrientation.portraitDown;
      await hold(tester, HeldOrientation.portraitDown);
      expect(suggester.offer.value, isNull);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('on a landscape screen, is made for upright', (WidgetTester tester) async {
      screenIsPortrait = false;
      await hold(tester, HeldOrientation.landscapeTopRight, for_: const Duration(seconds: 1));
      expect(suggester.offer.value, isNull);
      await hold(tester, HeldOrientation.portraitUp, for_: const Duration(seconds: 1));
      expect(suggester.offer.value, HeldOrientation.portraitUp);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('the rotation button', () {
    late StreamController<AccelerometerEvent> sensor;
    late List<Object?> orientationRequests;

    setUp(() {
      appDb = AppDb.forTesting(NativeDatabase.memory());
      sensor = StreamController<AccelerometerEvent>.broadcast();
      orientationRequests = <Object?>[];
      rotationSuggester = RotationSuggester(events: () => sensor.stream, screenIsPortrait: () => true, supported: true);
      styleSetting.actualLayout = LayoutMode.mobileV2;
      styleSetting.showRotationFAB.value = true;
    });

    tearDown(() async {
      await appDb.close();
      styleSetting.showRotationFAB.value = false;
      styleSetting.lockedOrientations = const <DeviceOrientation>[];
      interfaceRotation = InterfaceRotation();
      rotationSuggester.stop();
      sensor.close();
      Get.reset();
    });

    Future<void> pumpApp(WidgetTester tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientationRequests.add(call.arguments);
        }
        return null;
      });
      await tester.pumpWidget(GetMaterialApp(builder: (_, Widget? child) => AppManager(child: child!), home: const Scaffold()));
    }

    double opacity(WidgetTester tester) => tester.widget<AnimatedOpacity>(find.ancestor(of: find.byKey(const Key('rotationFAB')), matching: find.byType(AnimatedOpacity))).opacity;

    testWidgets('shows when the device is turned, and turns the screen with it when tapped', (WidgetTester tester) async {
      await pumpApp(tester);
      expect(rotationSuggester.running, isTrue);
      expect(opacity(tester), 0, reason: 'hidden until the device is turned');

      sensor.add(_reading(HeldOrientation.landscapeTopLeft));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(opacity(tester), 1);
      expect(find.byIcon(Icons.screen_lock_landscape), findsOneWidget);
      // Named on the button itself, which assistive technology and UI tests
      // find where it is, rather than on the whole screen.
      final SemanticsHandle semantics = tester.ensureSemantics();
      final Finder named = find.bySemanticsLabel('rotateToLandscape');
      expect(named, findsOneWidget);
      expect(tester.getSemantics(named).rect.size, const Size(40, 40));
      semantics.dispose();

      await tester.tap(find.byKey(const Key('rotationFAB')));
      await tester.pump(const Duration(milliseconds: 300));
      // The host here is not iOS: Android's landscapeLeft is turned counterclockwise.
      expect(orientationRequests.last, <String>['DeviceOrientation.landscapeLeft']);
      expect(styleSetting.lockedOrientations, <DeviceOrientation>[DeviceOrientation.landscapeLeft]);
      expect(opacity(tester), 0);

      // Unwanted: the sensor is let go, and the screen follows the system again.
      await tester.runAsync(() => styleSetting.saveShowRotationFAB(false));
      await tester.pump();
      expect(rotationSuggester.running, isFalse);
      expect(orientationRequests.last, <String>[]);
    });

    testWidgets('on an iPad, in the tablet layout, turns the interface within the window', (WidgetTester tester) async {
      int screen = 1;
      int queries = 0;
      interfaceRotation = InterfaceRotation(query: () async {
        queries++;
        return <Object?, Object?>{'pad': true, 'orientation': screen};
      });
      rotationSuggester = RotationSuggester(events: () => sensor.stream, supported: true);
      styleSetting.actualLayout = LayoutMode.tabletV2;

      Size? seen;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientationRequests.add(call.arguments);
        }
        return null;
      });
      await tester.pumpWidget(GetMaterialApp(
        builder: (_, Widget? child) => AppManager(child: child!),
        home: Scaffold(body: Builder(builder: (BuildContext context) {
          seen = MediaQuery.sizeOf(context);
          return const SizedBox();
        })),
      ));
      await tester.pump();
      expect(interfaceRotation.active, isTrue);
      final Size window = seen!;

      int turns() => tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns;

      Future<void> turnAndTap(HeldOrientation held) async {
        sensor.add(_reading(held));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 300));
        expect(opacity(tester), 1, reason: 'offered for $held');
        await tester.tap(find.byKey(const Key('rotationFAB')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await turnAndTap(HeldOrientation.landscapeTopLeft);
      expect(turns(), 1, reason: 'turned counterclockwise: the interface turns clockwise');
      expect(seen, window.flipped);
      expect(opacity(tester), 0);
      expect(find.byIcon(Icons.screen_lock_landscape), findsOneWidget);

      await turnAndTap(HeldOrientation.portraitUp);
      expect(turns(), 0);
      expect(seen, window);

      await turnAndTap(HeldOrientation.portraitDown);
      expect(turns(), 2);
      expect(orientationRequests, isEmpty, reason: 'the screen is not asked to turn');

      // The system turns the screen (its rotation lock let go): the
      // interface follows the screen again.
      screen = 3;
      final int before = queries;
      tester.binding.handleMetricsChanged();
      await tester.pump();
      expect(queries, greaterThan(before));
      expect(turns(), 0);

      await turnAndTap(HeldOrientation.portraitUp);
      expect(turns(), 3, reason: 'the screen shows landscape, Home button on the right');
      await tester.runAsync(() => styleSetting.saveShowRotationFAB(false));
      await tester.pump();
      expect(find.byType(RotatedBox), findsNothing);
      expect(interfaceRotation.turns.value, 0);
    });

    testWidgets('hides by itself after 5 seconds', (WidgetTester tester) async {
      await pumpApp(tester);
      sensor.add(_reading(HeldOrientation.landscapeTopRight));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(opacity(tester), 1);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 300));
      expect(opacity(tester), 0);
      expect(orientationRequests, isEmpty, reason: 'the screen was not turned');
    });
  });
}
