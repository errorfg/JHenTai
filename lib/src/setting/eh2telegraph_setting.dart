import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/log.dart';

Eh2TelegraphSetting eh2telegraphSetting = Eh2TelegraphSetting();

/// eh2telegraph 机器人的内网同步接口（经 Tailscale 直连）。
class Eh2TelegraphSetting
    with JHLifeCircleBeanWithConfigStorage
    implements JHLifeCircleBean {
  /// 例如 http://100.64.0.1:8788
  final RxString endpoint = ''.obs;
  final RxString token = ''.obs;

  bool get isConfigured =>
      endpoint.value.trim().isNotEmpty && token.value.trim().isNotEmpty;

  @override
  ConfigEnum get configEnum => ConfigEnum.eh2telegraphSetting;

  @override
  void applyBeanConfig(String configString) {
    final Map<String, dynamic> map = (jsonDecode(configString) as Map)
        .cast<String, dynamic>();
    endpoint.value = map['endpoint']?.toString().trim() ?? '';
    token.value = map['token']?.toString().trim() ?? '';
  }

  @override
  String toConfigString() =>
      jsonEncode({'endpoint': endpoint.value, 'token': token.value});

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> save({required String endpoint, required String token}) async {
    this.endpoint.value = normalizeEndpoint(endpoint);
    this.token.value = token.trim();
    log.debug(
      'saveEh2TelegraphSetting:endpoint=${this.endpoint.value} tokenConfigured=${this.token.value.isNotEmpty}',
    );
    await saveBeanConfig();
  }

  /// 去掉首尾空白与结尾斜杠；缺少协议时默认 http（Tailscale 内网）。
  static String normalizeEndpoint(String raw) {
    String value = raw.trim();
    if (value.isEmpty) {
      return '';
    }
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }
}
