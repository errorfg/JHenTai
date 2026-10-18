import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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

/// The way up of a screen showing iOS's UIInterfaceOrientation [raw]
/// (portrait 1, portraitUpsideDown 2, landscapeRight 3: the Home button on
/// the right, landscapeLeft 4); null when unknown.
HeldOrientation? heldOrientationOfInterface(int? raw) {
  switch (raw) {
    case 1:
      return HeldOrientation.portraitUp;
    case 2:
      return HeldOrientation.portraitDown;
    case 3:
      return HeldOrientation.landscapeTopLeft;
    case 4:
      return HeldOrientation.landscapeTopRight;
    default:
      return null;
  }
}

/// Clockwise quarter turns from upright of a device held [held].
int _quarterOf(HeldOrientation held) {
  switch (held) {
    case HeldOrientation.portraitUp:
      return 0;
    case HeldOrientation.landscapeTopRight:
      return 1;
    case HeldOrientation.portraitDown:
      return 2;
    case HeldOrientation.landscapeTopLeft:
      return 3;
  }
}

/// The clockwise quarter turns, on a screen shown the way up of a device
/// held [screen], that show an interface upright on the device held [held].
int quarterTurnsBetween(HeldOrientation screen, HeldOrientation held) => (_quarterOf(screen) - _quarterOf(held)) % 4;

EdgeInsets _turnedInsets(EdgeInsets e, int turns) {
  switch (turns % 4) {
    case 1:
      return EdgeInsets.fromLTRB(e.top, e.right, e.bottom, e.left);
    case 2:
      return EdgeInsets.fromLTRB(e.right, e.bottom, e.left, e.top);
    case 3:
      return EdgeInsets.fromLTRB(e.bottom, e.left, e.top, e.right);
    default:
      return e;
  }
}

/// [data] as seen by an interface turned [turns] clockwise quarter turns:
/// its size, and the insets of the system's bars, keyboard and gestures
/// on the sides they fall on.
MediaQueryData turnedMediaQuery(MediaQueryData data, int turns) {
  if (turns % 4 == 0) {
    return data;
  }
  return data.copyWith(
    size: turns.isOdd ? data.size.flipped : data.size,
    padding: _turnedInsets(data.padding, turns),
    viewPadding: _turnedInsets(data.viewPadding, turns),
    viewInsets: _turnedInsets(data.viewInsets, turns),
    systemGestureInsets: _turnedInsets(data.systemGestureInsets, turns),
  );
}

InterfaceRotation interfaceRotation = InterfaceRotation();

/// Turns the app's interface within its window where the app may not turn
/// the screen: iPadOS refuses apps that can share the screen (windows,
/// Split View) any orientation of their own ("The current windowing mode
/// does not allow for programmatic changes to interface orientation"),
/// whichever multitasking mode is chosen. The status bar stays as the
/// screen is.
class InterfaceRotation {
  InterfaceRotation({Future<Map<Object?, Object?>?> Function()? query}) : _query = query ?? _queryPlatform;

  static const MethodChannel _channel = MethodChannel('jhentai/screen_orientation');

  /// {pad: whether an iPad, orientation: its screen's UIInterfaceOrientation}
  final Future<Map<Object?, Object?>?> Function() _query;

  /// The way up the screen is shown, on an iPad; else null.
  HeldOrientation? _screen;

  /// The way up the interface is turned to, within the app.
  HeldOrientation? _target;

  /// Clockwise quarter turns of the interface within the window.
  final RxInt turns = 0.obs;

  /// Whether the interface is turned within the app, rather than the screen.
  bool get active => _screen != null;

  /// The way up the interface is shown, where it is turned within the app.
  HeldOrientation? get shown => _target ?? _screen;

  static Future<Map<Object?, Object?>?> _queryPlatform() async {
    if (!GetPlatform.isIOS) {
      return null;
    }
    try {
      return await _channel.invokeMapMethod<Object?, Object?>('get');
    } on Exception catch (e) {
      log.warning('No screen orientation', e);
      return null;
    }
  }

  /// Learns the screen's way up anew. When the system has turned the screen
  /// (following the device), the interface goes back to the screen's way up.
  Future<void> refresh() async {
    final Map<Object?, Object?>? state = await _query();
    final HeldOrientation? screen = state?['pad'] == true ? heldOrientationOfInterface(state?['orientation'] as int?) : null;
    if (screen != _screen) {
      _target = null;
    }
    _screen = screen;
    _update();
  }

  /// Shows the interface upright on the device held [held].
  Future<void> turnTo(HeldOrientation held) async {
    await refresh();
    if (_screen == null) {
      return;
    }
    _target = held == _screen ? null : held;
    _update();
  }

  /// Back to the screen's way up.
  void reset() {
    _target = null;
    _update();
  }

  /// [size] as seen by the interface, turned or not.
  Size turnedSize(Size size) => turns.value.isOdd ? size.flipped : size;

  void _update() {
    turns.value = _screen == null || _target == null ? 0 : quarterTurnsBetween(_screen!, _target!);
  }
}

RotationSuggester rotationSuggester = RotationSuggester();

/// Offers to turn the screen when the device is turned another way than the
/// screen shows (the system's rotation lock, or a screen orientation the app
/// chose): once the device has been held so for [settle], the offer stands
/// for [shownFor], and is not made again until the device is turned
/// another way. Upside down is offered only where the interface is turned
/// within the app: iPhones do not show apps so.
class RotationSuggester {
  RotationSuggester({
    Stream<AccelerometerEvent> Function()? events,
    bool Function()? screenIsPortrait,
    HeldOrientation? Function()? shownUp,
    Future<void> Function()? recheck,
    bool? supported,
    this.settle = const Duration(milliseconds: 600),
    this.shownFor = const Duration(seconds: 5),
  })  : _events = events ?? (() => accelerometerEventStream(samplingPeriod: SensorInterval.normalInterval)),
        _screenIsPortrait = screenIsPortrait ?? _viewIsPortrait,
        _shownUp = shownUp ?? (() => interfaceRotation.shown),
        _recheck = recheck ?? (() => interfaceRotation.refresh()),
        supported = supported ?? GetPlatform.isMobile;

  final Stream<AccelerometerEvent> Function() _events;
  final bool Function() _screenIsPortrait;

  /// The exact way up the interface is shown, where it is turned within the
  /// app; else null, and only whether the screen is portrait is known.
  final HeldOrientation? Function() _shownUp;

  /// Learns anew how the interface is shown, before an offer: a half turn of
  /// the screen leaves its size as it was.
  final Future<void> Function() _recheck;

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
    if (held == null || held == HeldOrientation.portraitDown && _shownUp() == null) {
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
    _settleTimer = Timer(settle, () async {
      await _recheck();
      // Turned another way meanwhile, or stopped.
      if (_candidate != held) {
        return;
      }
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

  bool _shownAsHeld(HeldOrientation held) {
    final HeldOrientation? shown = _shownUp();
    if (shown != null) {
      return shown == held;
    }
    return (held == HeldOrientation.portraitUp) == _screenIsPortrait();
  }
}
