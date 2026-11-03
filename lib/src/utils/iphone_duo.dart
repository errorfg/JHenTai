import 'package:device_info_plus/device_info_plus.dart';
import 'package:get/get.dart';

/// Whether the app runs on an iPhone Duo; read once at startup.
bool isIPhoneDuo = false;

Future<void> detectIPhoneDuo() async {
  if (GetPlatform.isIOS) {
    isIPhoneDuo = (await DeviceInfoPlugin().iosInfo).utsname.machine == 'iPhone19,4';
  }
}
