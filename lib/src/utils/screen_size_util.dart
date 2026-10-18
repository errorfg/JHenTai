import 'dart:ui';

import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/widget/rotation_suggestion.dart';

/// The window's size as the interface sees it, turned within the app or not.
Size get uiSize => interfaceRotation.turnedSize(Get.size);

double get fullScreenWidth => uiSize.width;

double get screenWidth => styleSetting.isInMobileLayout
    ? uiSize.width
    : styleSetting.isInTabletLayout
        ? uiSize.width / 2
        : (uiSize.width - UIConfig.desktopLeftTabBarWidth) / 2;

double get screenHeight => uiSize.height;
