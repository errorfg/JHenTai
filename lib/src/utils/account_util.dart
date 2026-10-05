import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/pages/setting/account/login/login_page_state.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/jm_setting.dart';
import 'package:jhentai/src/setting/nhentai_api_setting.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';

/// Account state and logout of each site with an account. Reads Rx values,
/// so it can be used inside `Obx`.
bool isLoggedIn(LoginSite site) => switch (site) {
  LoginSite.eh => userSetting.hasLoggedIn(),
  LoginSite.nh => nhentaiApiSetting.apiKey.value.isNotEmpty,
  LoginSite.jm => jmSetting.hasLoggedIn,
};

/// How the logged-in account is shown; null when logged out.
String? accountLabel(LoginSite site) {
  if (!isLoggedIn(site)) {
    return null;
  }
  return switch (site) {
    LoginSite.eh => '${'youHaveLoggedInAs'.tr}${userSetting.nickName.value ?? userSetting.userName.value ?? ''}',
    LoginSite.nh => '${'nhentaiApiKey'.tr} · ${'nhentaiApiKeyConfigured'.tr}',
    LoginSite.jm => '${'youHaveLoggedInAs'.tr}${jmSetting.userName.value}',
  };
}

Future<void> logout(LoginSite site) async {
  switch (site) {
    case LoginSite.eh:
      await ehRequest.requestLogout();
    case LoginSite.nh:
      // The nhentai account is the API key, which is cloud-synced.
      await nhentaiApiSetting.saveApiKey('');
      if (syncSetting.enableSync.value && syncSetting.autoSync.value) {
        await syncService.syncAfterLocalChange(types: const [CloudConfigTypeEnum.nhentaiApiSetting]);
      }
    case LoginSite.jm:
      await jmSetting.clearAccount();
  }
}
