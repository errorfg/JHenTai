import 'dart:math';

import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/local_config_service.dart';

/// This device's id in synced data, made once and kept; both the bucket's op
/// packs and the sync server's records carry it.
Future<String> ensureSyncDeviceId() async {
  String? id = await localConfigService.read(configKey: ConfigEnum.syncDeviceId);
  if (id != null && id.isNotEmpty) {
    return id;
  }
  final Random random = Random.secure();
  const String chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  String generated = List.generate(12, (_) => chars[random.nextInt(chars.length)]).join();
  await localConfigService.write(configKey: ConfigEnum.syncDeviceId, value: generated);
  return generated;
}
