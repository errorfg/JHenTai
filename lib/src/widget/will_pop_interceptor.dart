import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/pages/home_page.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';

import '../utils/toast_util.dart';

class WillPopInterceptor extends StatefulWidget {
  final Widget child;

  const WillPopInterceptor({Key? key, required this.child}) : super(key: key);

  @override
  State<WillPopInterceptor> createState() => _WillPopInterceptorState();
}

class _WillPopInterceptorState extends State<WillPopInterceptor> with _TapAgainToExit {
  @override
  Widget build(BuildContext context) {
    return PopScope(
      child: widget.child,
      canPop: Platform.isAndroid ? false : true,
      onPopInvokedWithResult: (bool didPop, FormData? result) async {
        if (didPop) {
          return;
        }

        final bool shouldPop = await _handlePopApp();
        if (context.mounted && shouldPop) {
          SystemNavigator.pop(animated: true);
        }
      },
    );
  }

  /// system back
  Future<bool> _handlePopApp() {
    if (styleSetting.isInMobileLayout) {
      return _handleDoubleTapPopApp();
    }

    if (styleSetting.isInTabletLayout) {
      if (Get.global(rightV2).currentState?.canPop() == true) {
        popRightRoute();
        return Future.value(false);
      }
      if (Get.global(leftV2).currentState?.canPop() == true) {
        popLeftRoute();
        return Future.value(false);
      }
      return _handleDoubleTapPopApp();
    }

    if (styleSetting.isInDesktopLayout) {
      if (Get.global(right).currentState?.canPop() == true) {
        popRightRoute();
        return Future.value(false);
      }
      if (Get.global(left).currentState?.canPop() == true) {
        popLeftRoute();
        return Future.value(false);
      }
      return _handleDoubleTapPopApp();
    }

    return _handleDoubleTapPopApp();
  }
}

/// Back on the page of a scheme of its own (Komga, PDF). It stands in for
/// the home of the sites, which stays underneath it, so back never returns
/// there: [onBack] goes back inside the page first; then, on Android, a
/// second back within 800 ms leaves the app, as on the home.
class SchemePagePopScope extends StatefulWidget {
  const SchemePagePopScope({super.key, required this.child, this.onBack});

  final Widget child;

  /// Goes back inside the page; false when there is nothing to go back to.
  final bool Function()? onBack;

  @override
  State<SchemePagePopScope> createState() => _SchemePagePopScopeState();
}

class _SchemePagePopScopeState extends State<SchemePagePopScope> with _TapAgainToExit {
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop || (widget.onBack?.call() ?? false) || !Platform.isAndroid) {
          return;
        }
        if (await _handleDoubleTapPopApp() && context.mounted) {
          SystemNavigator.pop(animated: true);
        }
      },
      child: widget.child,
    );
  }
}

mixin _TapAgainToExit<T extends StatefulWidget> on State<T> {
  DateTime? _lastPopTime;

  /// double tap back button to exit app
  Future<bool> _handleDoubleTapPopApp() {
    if (_lastPopTime == null) {
      _lastPopTime = DateTime.now();
      toast('TapAgainToExit'.tr, isCenter: false);
      return Future.value(false);
    }

    if (DateTime.now().difference(_lastPopTime!).inMilliseconds <= 800) {
      return Future.value(true);
    }

    _lastPopTime = DateTime.now();
    toast('TapAgainToExit'.tr, isCenter: false);
    return Future.value(false);
  }
}
