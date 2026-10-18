import 'dart:ui';

import 'package:blur/blur.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_windowmanager_plus/flutter_windowmanager_plus.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';

import '../config/theme_config.dart';
import '../config/ui_config.dart';
import '../routes/routes.dart';
import '../setting/security_setting.dart';
import '../setting/style_setting.dart';
import '../service/log.dart';
import '../utils/route_util.dart';
import 'rotation_suggestion.dart';

typedef DidChangePlatformBrightnessCallback = void Function();
typedef DidChangeAppLifecycleStateCallback = void Function(AppLifecycleState state);
typedef DidHaveMemoryPressureCallback = void Function();
typedef AppLaunchCallback = void Function(BuildContext context);

class AppManager extends StatefulWidget {
  static final List<DidChangePlatformBrightnessCallback> _didChangePlatformBrightnessCallbacks = [];
  static final List<DidChangeAppLifecycleStateCallback> _didChangeAppLifecycleStateCallbacks = [];
  static final List<DidHaveMemoryPressureCallback> _didHaveMemoryPressureCallbacks = [];

  static final List<AppLaunchCallback> _appLaunchCallbacks = [];

  final Widget child;

  const AppManager({Key? key, required this.child}) : super(key: key);

  @override
  State<AppManager> createState() => _AppManagerState();

  static void registerDidChangePlatformBrightnessCallback(DidChangePlatformBrightnessCallback callback) {
    _didChangePlatformBrightnessCallbacks.add(callback);
  }

  static void unRegisterDidChangePlatformBrightnessCallback(DidChangePlatformBrightnessCallback callback) {
    _didChangePlatformBrightnessCallbacks.remove(callback);
  }

  static void registerDidChangeAppLifecycleStateCallback(DidChangeAppLifecycleStateCallback callback) {
    _didChangeAppLifecycleStateCallbacks.add(callback);
  }

  static void unRegisterDidChangeAppLifecycleStateCallback(DidChangeAppLifecycleStateCallback callback) {
    _didChangeAppLifecycleStateCallbacks.remove(callback);
  }

  static void registerDidHaveMemoryPressureCallback(DidHaveMemoryPressureCallback callback) {
    _didHaveMemoryPressureCallbacks.add(callback);
  }

  static void unRegisterDidHaveMemoryPressureCallback(DidHaveMemoryPressureCallback callback) {
    _didHaveMemoryPressureCallbacks.remove(callback);
  }

  static void registerAppLaunchCallback(AppLaunchCallback callback) {
    _appLaunchCallbacks.add(callback);
  }

  static void unRegisterAppLaunchCallback(AppLaunchCallback callback) {
    _appLaunchCallbacks.remove(callback);
  }
}

class _AppManagerState extends State<AppManager> with WidgetsBindingObserver {
  late final AppLifecycleListener _listener;
  DateTime? lastInactiveTime;
  bool inBlur = false;

  late AppLifecycleState _currentState = WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;

  late final Worker _rotationSettingListener;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _listener = AppLifecycleListener(
      onInactive: _onInactive,
      onResume: _onResume,
      onStateChange: (AppLifecycleState state) {
        _currentState = state;
        _syncRotationSensor();
      },
    );

    _rotationSettingListener = ever(styleSetting.showRotationFAB, (_) => _syncRotationSensor());
    _syncRotationSensor();

    AppManager.registerAppLaunchCallback(_addSecureFlagForAndroid);
    AppManager.registerDidChangePlatformBrightnessCallback(_changeTheme);
    AppManager.registerDidHaveMemoryPressureCallback(_logMemoryPressure);

    for (var callback in AppManager._appLaunchCallbacks) {
      callback.call(context);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _listener.dispose();
    _rotationSettingListener.dispose();
    rotationSuggester.stop();
    AppManager.unRegisterAppLaunchCallback(_addSecureFlagForAndroid);
    AppManager.unRegisterDidChangePlatformBrightnessCallback(_changeTheme);
    AppManager.unRegisterDidHaveMemoryPressureCallback(_logMemoryPressure);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    for (DidChangePlatformBrightnessCallback callback in AppManager._didChangePlatformBrightnessCallbacks) {
      callback.call();
    }
    super.didChangePlatformBrightness();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    for (DidChangeAppLifecycleStateCallback callback in AppManager._didChangeAppLifecycleStateCallbacks) {
      callback.call(state);
    }
    super.didChangeAppLifecycleState(state);
  }

  @override
  void didHaveMemoryPressure() {
    if (_currentState == AppLifecycleState.resumed) {
      for (DidHaveMemoryPressureCallback callback in AppManager._didHaveMemoryPressureCallbacks) {
        callback.call();
      }
    }
    super.didHaveMemoryPressure();
  }

  @override
  Widget build(BuildContext context) {
    Widget child = inBlur
        ? Blur(
            blur: 100,
            blurColor: GetPlatform.isAndroid ? Colors.white : Colors.grey.shade600,
            colorOpacity: 1,
            child: widget.child,
          )
        : widget.child;

    return ScrollConfiguration(
      behavior: UIConfig.scrollBehaviourWithScrollBar,
      child: Obx(() {
        if (styleSetting.showRotationFAB.isTrue && styleSetting.isInMobileLayout) {
          return Stack(
            children: [
              child,
              Positioned(
                left: 16,
                bottom: MediaQuery.of(context).padding.bottom + 16,
                child: _buildRotationFAB(),
              ),
            ],
          );
        }
        return child;
      }),
    );
  }

  /// The device's way up is followed while the button is wanted and the app
  /// is in front.
  void _syncRotationSensor() {
    if (styleSetting.showRotationFAB.isTrue && _currentState == AppLifecycleState.resumed) {
      rotationSuggester.start();
    } else {
      rotationSuggester.stop();
    }
  }

  /// Shown for a while when the device is turned another way than the
  /// screen: tapped, the screen turns to the device's way up.
  Widget _buildRotationFAB() {
    return Obx(() {
      final HeldOrientation? offer = rotationSuggester.offer.value;
      final bool toPortrait = (offer ?? rotationSuggester.lastOffer) == HeldOrientation.portraitUp;
      return IgnorePointer(
        ignoring: offer == null,
        child: AnimatedOpacity(
          opacity: offer == null ? 0 : 1,
          duration: const Duration(milliseconds: 200),
          // Above the navigator, where there is no overlay for a tooltip.
          child: Semantics(
            label: toPortrait ? 'rotateToPortrait'.tr : 'rotateToLandscape'.tr,
            child: SizedBox(
              width: 40,
              height: 40,
              child: FloatingActionButton(
                key: const Key('rotationFAB'),
                heroTag: 'rotationFAB',
                onPressed: offer == null ? null : () => _rotateTo(offer),
                backgroundColor: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.8),
                elevation: 2,
                child: Icon(
                  toPortrait ? Icons.screen_lock_portrait : Icons.screen_lock_landscape,
                  size: 20,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  void _rotateTo(HeldOrientation held) {
    styleSetting.lockOrientation(<DeviceOrientation>[screenOrientationFor(held, ios: GetPlatform.isIOS)]);
    rotationSuggester.dismiss();
  }

  void _changeTheme() {
    if (styleSetting.themeMode.value != ThemeMode.system) {
      return;
    }
    if (PlatformDispatcher.instance.platformBrightness == Brightness.light) {
      Get.rootController.theme = ThemeConfig.theme(styleSetting.lightThemeColor.value, Brightness.light);
    } else {
      Get.rootController.darkTheme = ThemeConfig.theme(styleSetting.darkThemeColor.value, Brightness.dark);
    }

    Get.rootController.updateSafely();
  }

  void _logMemoryPressure() {
    log.warning('Memory pressure');
  }

  void _onInactive() {
    log.debug('App is hidden');

    if (securitySetting.enableAuthOnResume.isTrue) {
      lastInactiveTime ??= DateTime.now();
    }

    if ((securitySetting.enableAuthOnResume.isTrue || securitySetting.enableBlur.isTrue) && !inBlur && !isRouteAtTop(Routes.lock)) {
      setState(() => inBlur = true);
    }
  }

  void _onResume() {
    log.debug('App is shown');

    if (!inBlur) {
      return;
    }

    if (securitySetting.enableBlur.isFalse) {
      return;
    }

    if (securitySetting.enableAuthOnResume.isFalse) {
      setState(() => inBlur = false);
      return;
    }

    if ((securitySetting.enablePasswordAuth.isTrue || securitySetting.enableBiometricAuth.isTrue) &&
        DateTime.now().difference(lastInactiveTime!).inSeconds >= 3) {
      toRoute(Routes.lock);
      Future.delayed(const Duration(milliseconds: 300), () => setState(() => inBlur = false));
      lastInactiveTime = null;
    } else {
      setState(() => inBlur = false);
      return;
    }
  }

  /// for Android, blur is invalid when switch app to background(app is still clearly visible in switcher),
  /// so i choose to set FLAG_SECURE to do the same effect.
  void _addSecureFlagForAndroid(BuildContext context) {
    if (GetPlatform.isAndroid && (securitySetting.enableAuthOnResume.isTrue || securitySetting.enableBlur.isTrue)) {
      FlutterWindowManagerPlus.addFlags(FlutterWindowManagerPlus.FLAG_SECURE);
    }
  }
}
