import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/pages/setting/account/login/login_page_state.dart';
import 'package:jhentai/src/utils/account_util.dart';
import '../../../routes/routes.dart';
import '../../../utils/route_util.dart';
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
          return ListView(
            padding: const EdgeInsets.only(top: 12),
            children: [
              if (LoginSite.values.any((LoginSite site) => !isLoggedIn(site))) _buildLogin().marginOnly(bottom: 12),
              for (final LoginSite site in LoginSite.values)
                if (isLoggedIn(site)) ...[
                  _buildAccount(context, site: site, subtitle: accountLabel(site)!),
                  if (site == LoginSite.eh) _buildCookiePage(),
                ],
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
  }) {
    Future<void> confirmLogout() async {
      bool? result = await Get.dialog(EHDialog(title: '${'logout'.tr} ${site.title}?'));
      if (result == true) {
        await logout(site);
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
}
