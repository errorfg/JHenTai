import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/network/eh2telegraph_client.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/eh2telegraph_setting.dart';
import 'package:jhentai/src/setting/sync_setting.dart';

/// eh2telegraph 内网同步接口的设置：服务地址与访问令牌。
class Eh2TelegraphPage extends StatelessWidget {
  const Eh2TelegraphPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('eh2telegraph'.tr)),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text('eh2telegraphEndpoint'.tr),
              subtitle: Text(
                eh2telegraphSetting.endpoint.value.isEmpty
                    ? 'eh2telegraphNotConfigured'.tr
                    : eh2telegraphSetting.endpoint.value,
              ),
              onTap: () => _edit(context, editEndpoint: true),
            ),
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: Text('eh2telegraphToken'.tr),
              subtitle: Text(
                eh2telegraphSetting.token.value.isEmpty
                    ? 'eh2telegraphNotConfigured'.tr
                    : 'eh2telegraphConfigured'.tr,
              ),
              onTap: () => _edit(context, editEndpoint: false),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.network_check_outlined),
              title: Text('eh2telegraphTestConnection'.tr),
              enabled: eh2telegraphSetting.isConfigured,
              onTap: eh2telegraphSetting.isConfigured
                  ? () => _testConnection(context)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, {required bool editEndpoint}) async {
    final TextEditingController controller = TextEditingController(
      text: editEndpoint
          ? eh2telegraphSetting.endpoint.value
          : eh2telegraphSetting.token.value,
    );
    try {
      final String? value = await Get.dialog<String>(
        AlertDialog(
          title: Text(
            editEndpoint ? 'eh2telegraphEndpoint'.tr : 'eh2telegraphToken'.tr,
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: !editEndpoint,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: editEndpoint ? TextInputType.url : TextInputType.text,
            decoration: InputDecoration(
              hintText: editEndpoint ? 'eh2telegraphEndpointHint'.tr : null,
            ),
          ),
          actions: [
            TextButton(onPressed: Get.back, child: Text('cancel'.tr)),
            TextButton(
              onPressed: () => Get.back(result: controller.text),
              child: Text('OK'.tr),
            ),
          ],
          actionsPadding: const EdgeInsets.only(
            left: 24,
            right: 24,
            bottom: 12,
          ),
        ),
      );
      if (value == null) {
        return;
      }
      await eh2telegraphSetting.save(
        endpoint: editEndpoint ? value : eh2telegraphSetting.endpoint.value,
        token: editEndpoint ? eh2telegraphSetting.token.value : value,
      );
      if (syncSetting.enableSync.value && syncSetting.autoSync.value) {
        await syncService.sync(
          types: const [CloudConfigTypeEnum.eh2telegraphSetting],
        );
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _testConnection(BuildContext context) async {
    bool ok;
    try {
      ok = await Eh2TelegraphClient.fromSetting().health();
    } catch (_) {
      ok = false;
    }
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'eh2telegraphConnectionOk'.tr
              : 'eh2telegraphConnectionFailed'.tr,
        ),
      ),
    );
  }
}
