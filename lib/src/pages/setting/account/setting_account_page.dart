import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/pages/setting/account/login/login_page_state.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/jm_setting.dart';
import 'package:jhentai/src/setting/nhentai_api_setting.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import '../../../routes/routes.dart';
import '../../../utils/route_util.dart';
import '../../../network/eh_request.dart';
import '../../../widget/eh_alert_dialog.dart';

/// Accounts of every site: one login entry, whose page picks the site, and
/// a row with logout for each site already logged in.
class SettingAccountPage extends StatelessWidget {
  const SettingAccountPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('accountSetting'.tr)),
      body: Obx(
        () {
          bool ehLoggedIn = userSetting.hasLoggedIn();
          bool nhLoggedIn = nhentaiApiSetting.apiKey.value.isNotEmpty;
          bool jmLoggedIn = jmSetting.hasLoggedIn;

          return ListView(
            padding: const EdgeInsets.only(top: 12),
            children: [
              if (!ehLoggedIn || !nhLoggedIn || !jmLoggedIn) _buildLogin().marginOnly(bottom: 12),
              if (ehLoggedIn) ...[
                _buildAccount(
                  context,
                  site: LoginSite.eh,
                  subtitle: '${'youHaveLoggedInAs'.tr}${userSetting.nickName.value ?? userSetting.userName.value!}',
                  onLogout: ehRequest.requestLogout,
                ),
                _buildCookiePage(),
              ],
              if (nhLoggedIn)
                _buildAccount(
                  context,
                  site: LoginSite.nh,
                  subtitle: '${'nhentaiApiKey'.tr} · ${'nhentaiApiKeyConfigured'.tr}',
                  onLogout: _logoutNhentai,
                ),
              if (jmLoggedIn)
                _buildAccount(
                  context,
                  site: LoginSite.jm,
                  subtitle: '${'youHaveLoggedInAs'.tr}${jmSetting.userName.value}',
                  onLogout: jmSetting.clearAccount,
                ),
            ],
          ).withListTileTheme(context);
        },
      ),
    );
  }

  Widget _buildLogin() {
    return ListTile(
      title: Text('login'.tr),
      trailing: IconButton(onPressed: () => toRoute(Routes.login), icon: const Icon(Icons.keyboard_arrow_right)),
      onTap: () => toRoute(Routes.login),
    );
  }

  Widget _buildAccount(
    BuildContext context, {
    required LoginSite site,
    required String subtitle,
    required Future<void> Function() onLogout,
  }) {
    Future<void> confirmLogout() async {
      bool? result = await Get.dialog(EHDialog(title: '${'logout'.tr} ${site.title}?'));
      if (result == true) {
        await onLogout();
      }
    }

    return ListTile(
      title: Text(site.title),
      subtitle: Text(subtitle),
      onTap: confirmLogout,
      trailing: IconButton(
        icon: const Icon(Icons.logout),
        color: UIConfig.alertColor(context),
        onPressed: confirmLogout,
      ),
    );
  }

  Widget _buildCookiePage() {
    return ListTile(
      title: Text('showCookie'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right),
      onTap: () => toRoute(Routes.cookie),
    );
  }

  /// The nhentai account is the API key, which is cloud-synced.
  Future<void> _logoutNhentai() async {
    await nhentaiApiSetting.saveApiKey('');
    if (syncSetting.enableSync.value && syncSetting.autoSync.value) {
      await syncService.syncAfterLocalChange(types: const [CloudConfigTypeEnum.nhentaiApiSetting]);
    }
  }
}
