import 'package:get/get.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../../service/log.dart';
import '../../setting/read_setting.dart';

/// The brightness lock of the reader's top menu (phones and tablets): locks
/// the screen at the brightness it has now, or gives the brightness back to
/// the system. The lock is the reading brightness of the settings, set to
/// what the screen has, so it holds in every reader until it is undone; the
/// reader applies and resets it as it follows that setting.
///
/// Completes with what to tell. [screenBrightness]: the brightness of the
/// screen now, 0 to 1.
Future<String> toggleReadBrightnessLock({Future<double> Function()? screenBrightness}) async {
  if (readSetting.enableCustomReadBrightness.isTrue) {
    await readSetting.saveEnableCustomReadBrightness(false);
    return 'brightnessUnlocked'.tr;
  }
  double current;
  try {
    current = await (screenBrightness ?? () => ScreenBrightness().application)();
  } catch (e) {
    log.error('Read screen brightness failed', e);
    return 'internalError'.tr;
  }
  final int percent = (current * 100).round().clamp(0, 100);
  // The level first: the lock then applies it.
  await readSetting.saveCustomBrightness(percent);
  await readSetting.saveEnableCustomReadBrightness(true);
  return 'brightnessLocked'.trParams(<String, String>{'percent': '$percent'});
}
