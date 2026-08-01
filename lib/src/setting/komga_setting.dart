import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/utils/uuid_util.dart';

KomgaSetting komgaSetting = KomgaSetting();

class KomgaSetting
    with JHLifeCircleBeanWithConfigStorage
    implements JHLifeCircleBean {
  final RxString serverUrl = ''.obs;
  final RxString username = ''.obs;
  final RxString password = ''.obs;
  final RxString apiKey = ''.obs;
  final RxString connectionId = ''.obs;
  final RxInt revision = 0.obs;

  bool get isConfigured =>
      serverUrl.value.trim().isNotEmpty &&
      (apiKey.value.trim().isNotEmpty || username.value.trim().isNotEmpty);

  @override
  ConfigEnum get configEnum => ConfigEnum.komgaSetting;

  @override
  void applyBeanConfig(String configString) {
    final Map<String, dynamic> map = jsonDecode(configString);
    final String nextServerUrl = map['serverUrl'] as String? ?? '';
    final String nextUsername = map['username'] as String? ?? '';
    final String nextPassword = map['password'] as String? ?? '';
    final String nextApiKey = map['apiKey'] as String? ?? '';
    final String configuredConnectionId = (map['connectionId'] as String? ?? '')
        .trim();
    final bool isSameServer = _isSameServer(serverUrl.value, nextServerUrl);

    serverUrl.value = nextServerUrl;
    username.value = nextUsername;
    password.value = nextPassword;
    apiKey.value = nextApiKey;
    connectionId.value = switch ((
      configuredConnectionId,
      nextServerUrl.trim().isEmpty,
    )) {
      (_, true) => '',
      (final String id, false) when id.isNotEmpty => id,
      (_, false) when isSameServer && connectionId.value.isNotEmpty =>
        connectionId.value,
      _ => legacyConnectionId(
        serverUrl: nextServerUrl,
        username: nextUsername,
        apiKey: nextApiKey,
      ),
    };
    revision.value++;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'serverUrl': serverUrl.value,
      'username': username.value,
      'password': password.value,
      'apiKey': apiKey.value,
      'connectionId': connectionId.value,
    });
  }

  Future<void> save({
    required String serverUrl,
    required String username,
    required String password,
    required String apiKey,
  }) async {
    final String normalizedServerUrl = normalizeServerUrl(serverUrl);
    final bool isSameServer = _isSameServer(
      this.serverUrl.value,
      normalizedServerUrl,
    );
    final String previousConnectionId = connectionId.value.trim();
    final String nextConnectionId = normalizedServerUrl.isEmpty
        ? ''
        : isSameServer
        ? previousConnectionId.isNotEmpty
              ? previousConnectionId
              : legacyConnectionId(
                  serverUrl: this.serverUrl.value,
                  username: this.username.value,
                  apiKey: this.apiKey.value,
                )
        : newUUID();

    this.serverUrl.value = normalizedServerUrl;
    this.username.value = username.trim();
    this.password.value = password;
    this.apiKey.value = apiKey.trim();
    connectionId.value = nextConnectionId;
    await saveBeanConfig();
    revision.value++;
  }

  static String normalizeServerUrl(String rawUrl) {
    return rawUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  }

  /// Reproduces the progress namespace used before connection IDs were stored.
  /// Existing configurations use this value so their progress keys do not move.
  static String legacyConnectionId({
    required String serverUrl,
    required String username,
    required String apiKey,
  }) {
    final String normalizedServerUrl = normalizeServerUrl(serverUrl);
    final String accountIdentity = username.trim().isNotEmpty
        ? username.trim()
        : sha1.convert(utf8.encode(apiKey)).toString();
    return sha1
        .convert(utf8.encode('$normalizedServerUrl|$accountIdentity'))
        .toString();
  }

  static bool _isSameServer(String first, String second) {
    final String normalizedFirst = normalizeServerUrl(first);
    return normalizedFirst.isNotEmpty &&
        normalizedFirst == normalizeServerUrl(second);
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}
}
