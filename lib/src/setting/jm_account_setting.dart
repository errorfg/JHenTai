import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/jm_setting.dart';

JmAccountSetting jmAccountSetting = JmAccountSetting();

/// The logged-in JM account: its name and the session cookie the JM API
/// accepts. Cloud-synced as its own type, so a login on one device holds
/// on all of them.
class JmAccountSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  /// Empty when logged out.
  final RxString userName = ''.obs;
  int userId = 0;

  /// Cookie header of the account's session.
  String accountCookie = '';

  bool get hasLoggedIn => userName.value.isNotEmpty && accountCookie.isNotEmpty;

  @override
  List<JHLifeCircleBean> get initDependencies => super.initDependencies..add(jmSetting);

  @override
  ConfigEnum get configEnum => ConfigEnum.jmAccountSetting;

  @override
  void applyBeanConfig(String configString) {
    final Map<String, dynamic> map = (jsonDecode(configString) as Map).cast<String, dynamic>();
    userName.value = map['userName']?.toString() ?? '';
    userId = int.tryParse('${map['userId'] ?? ''}') ?? 0;
    accountCookie = map['accountCookie']?.toString() ?? '';
  }

  @override
  String toConfigString() => jsonEncode({
        'userName': userName.value,
        'userId': userId,
        'accountCookie': accountCookie,
      });

  /// 8.0.30 and 8.0.31 kept the account in [JmSetting]; it moves here once.
  @override
  Future<void> doInitBean() async {
    final Map<String, dynamic>? legacy = jmSetting.legacyAccount;
    if (legacy == null) {
      return;
    }
    if (!hasLoggedIn) {
      applyBeanConfig(jsonEncode(legacy));
      await saveBeanConfig();
      log.info('Moved the JM account to its own setting');
    }
    await jmSetting.dropLegacyAccount();
  }

  @override
  void doAfterBeanReady() {}

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
}
