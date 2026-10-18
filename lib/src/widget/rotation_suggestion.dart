import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../service/log.dart';

/// Which way up the device is held: upright, upside down, or turned a
/// quarter with its top to the left (counterclockwise) or to the right.
enum HeldOrientation { portraitUp, portraitDown, landscapeTopLeft, landscapeTopRight }

/// The way up of a device measuring gravity as [x], [y], [z] (m/s², on
/// Android's axes, which sensors_plus gives on iOS as well: x to the right
/// of the screen, y up it, z out of it). The quarter turn nearest the
/// direction of gravity in the screen's plane, when it is within 30° of it
/// and the screen stands at least 30° up from lying flat; else null, the
/// way up is unclear.
HeldOrientation? heldOrientationOf(double x, double y, double z) {
  final double total = math.sqrt(x * x + y * y + z * z);
  final double inPlane = math.sqrt(x * x + y * y);
  if (total < 1 || inPlane < total * 0.5) {
    return null;
  }
  // 0° upright, 90° top to the left, -90° top to the right, ±180° upside down.
  final double angle = math.atan2(x, y) * 180 / math.pi;
  final int quarter = (angle / 90).round();
  if ((angle - quarter * 90).abs() > 30) {
    return null;
  }
  switch (quarter) {
    case 0:
      return HeldOrientation.portraitUp;
    case 1:
      return HeldOrientation.landscapeTopLeft;
    case -1:
      return HeldOrientation.landscapeTopRight;
    default:
      return HeldOrientation.portraitDown;
  }
}

/// The screen orientation that shows the app upright on a device held
/// [held]. Flutter's landscapeLeft is Android's SCREEN_ORIENTATION_LANDSCAPE
/// (the device turned counterclockwise) but iOS's
/// UIInterfaceOrientationLandscapeLeft (the Home button on the left: turned
/// clockwise), see the engine's PlatformChannel.java and
/// FlutterPlatformPlugin.mm.
DeviceOrientation screenOrientationFor(HeldOrientation held, {required bool ios}) {
  switch (held) {
    case HeldOrientation.portraitUp:
      return DeviceOrientation.portraitUp;
    case HeldOrientation.portraitDown:
      return DeviceOrientation.portraitDown;
    case HeldOrientation.landscapeTopLeft:
      return ios ? DeviceOrientation.landscapeRight : DeviceOrientation.landscapeLeft;
    case HeldOrientation.landscapeTopRight:
      return ios ? DeviceOrientation.landscapeLeft : DeviceOrientation.landscapeRight;
  }
}

RotationSuggester rotationSuggester = RotationSuggester();

/// Offers to turn the screen when the device is turned another way than the
/// screen shows (the system's rotation lock, or a screen orientation the app
/// chose): once the device has been held so for [settle], the offer stands
/// for [shownFor], and is not made again until the device is turned
/// another way. Upside down is not offered: iPhones do not show apps so.
class RotationSuggester {
  RotationSuggester({
    Stream<AccelerometerEvent> Function()? events,
    bool Function()? screenIsPortrait,
    bool? supported,
    this.settle = const Duration(milliseconds: 600),
    this.shownFor = const Duration(seconds: 5),
  })  : _events = events ?? (() => accelerometerEventStream(samplingPeriod: SensorInterval.normalInterval)),
        _screenIsPortrait = screenIsPortrait ?? _viewIsPortrait,
        supported = supported ?? GetPlatform.isMobile;

  final Stream<AccelerometerEvent> Function() _events;
  final bool Function() _screenIsPortrait;

  /// Phones and tablets: they have the sensor, and turn their screens.
  final bool supported;

  final Duration settle;
  final Duration shownFor;

  /// The way the device is held, while the offer to turn the screen to it
  /// stands.
  final Rxn<HeldOrientation> offer = Rxn<HeldOrientation>();

  /// The last offer, for the button while it fades out.
  HeldOrientation? lastOffer;

  StreamSubscription<AccelerometerEvent>? _subscription;
  Timer? _settleTimer;
  Timer? _hideTimer;

  /// Held so, not long enough yet to be offered.
  HeldOrientation? _candidate;

  /// Offered already (shown, or shown and gone) while the device stays so.
  HeldOrientation? _offered;

  bool get running => _subscription != null;

  static bool _viewIsPortrait() {
    final Size size = PlatformDispatcher.instance.views.first.physicalSize;
    return size.height >= size.width;
  }

  void start() {
    if (!supported || _subscription != null) {
      return;
    }
    _subscription = _events().listen(
      (AccelerometerEvent e) => onHeld(heldOrientationOf(e.x, e.y, e.z)),
      onError: (Object e) {
        log.warning('No accelerometer for rotation suggestions', e);
        stop();
      },
      cancelOnError: true,
    );
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _settleTimer?.cancel();
    _hideTimer?.cancel();
    _candidate = null;
    _offered = null;
    offer.value = null;
  }

  /// The screen is turned as offered, or the offer declined.
  void dismiss() {
    _hideTimer?.cancel();
    offer.value = null;
  }

  /// The device is found held [held] (null: unclear).
  void onHeld(HeldOrientation? held) {
    if (held == null || held == HeldOrientation.portraitDown) {
      return;
    }
    if (_shownAsHeld(held)) {
      _settleTimer?.cancel();
      _candidate = null;
      _offered = null;
      dismiss();
      return;
    }
    if (held == _candidate || held == _offered) {
      return;
    }
    _candidate = held;
    _settleTimer?.cancel();
    _settleTimer = Timer(settle, () {
      _candidate = null;
      if (_shownAsHeld(held)) {
        return;
      }
      _offered = held;
      lastOffer = held;
      offer.value = held;
      _hideTimer?.cancel();
      _hideTimer = Timer(shownFor, () => offer.value = null);
    });
  }

  bool _shownAsHeld(HeldOrientation held) => (held == HeldOrientation.portraitUp) == _screenIsPortrait();
}
