import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/network/jm/jm_api.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/log.dart';

JmSetting jmSetting = JmSetting();

/// JM API and image lines, and the logged-in JM account. Kept apart from
/// EHSetting, which is cleared on E-Hentai logout; stays on this device
/// (not cloud-synced).
class JmSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  /// API domains last reported by the JM domain servers.
  final RxList<String> apiDomains = <String>[...JmApi.builtInApiDomains].obs;

  /// The API line the user picked; empty means "first that works".
  final RxString preferredApiDomain = ''.obs;
  final RxString imageDomain = JmApi.imageDomains.first.obs;

  /// The logged-in account; empty when logged out.
  final RxString userName = ''.obs;
  int userId = 0;

  /// Cookie header of the account's session.
  String accountCookie = '';

  bool get hasLoggedIn => userName.value.isNotEmpty && accountCookie.isNotEmpty;

  @override
  ConfigEnum get configEnum => ConfigEnum.jmSetting;

  @override
  void applyBeanConfig(String configString) {
    final Map<String, dynamic> map = (jsonDecode(configString) as Map).cast<String, dynamic>();
    final List<String> domains = (map['apiDomains'] as List? ?? const <dynamic>[]).map((dynamic d) => '$d').where((String d) => d.isNotEmpty).toList();
    if (domains.isNotEmpty) {
      apiDomains.value = domains;
    }
    preferredApiDomain.value = map['preferredApiDomain']?.toString() ?? '';
    final String image = map['imageDomain']?.toString() ?? '';
    if (image.isNotEmpty) {
      imageDomain.value = image;
    }
    userName.value = map['userName']?.toString() ?? '';
    userId = int.tryParse('${map['userId'] ?? ''}') ?? 0;
    accountCookie = map['accountCookie']?.toString() ?? '';
  }

  @override
  String toConfigString() => jsonEncode({
        'apiDomains': apiDomains,
        'preferredApiDomain': preferredApiDomain.value,
        'imageDomain': imageDomain.value,
        'userName': userName.value,
        'userId': userId,
        'accountCookie': accountCookie,
      });

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  /// API domains to try, the user's choice first.
  List<String> orderedApiDomains() {
    final String preferred = preferredApiDomain.value;
    return <String>[
      if (preferred.isNotEmpty) preferred,
      ...apiDomains.where((String d) => d != preferred),
    ];
  }

  Future<void> saveDiscoveredApiDomains(List<String> domains) async {
    if (domains.isEmpty || listEquals(domains, apiDomains)) {
      return;
    }
    log.info('JM API domains updated: $domains');
    apiDomains.value = domains;
    await saveBeanConfig();
  }

  Future<void> savePreferredApiDomain(String domain) async {
    preferredApiDomain.value = domain;
    await saveBeanConfig();
  }

  Future<void> saveAccount(JmUser user, String cookie) async {
    log.info('JM login: ${user.username}');
    userId = user.id;
    accountCookie = cookie;
    userName.value = user.username;
    await saveBeanConfig();
  }

  Future<void> clearAccount() async {
    log.info('JM logout');
    userId = 0;
    accountCookie = '';
    userName.value = '';
    await saveBeanConfig();
  }

  Future<void> saveImageDomain(String domain) async {
    imageDomain.value = domain;
    await saveBeanConfig();
  }

  static bool listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
