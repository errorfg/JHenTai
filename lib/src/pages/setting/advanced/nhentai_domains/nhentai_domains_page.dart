import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/eh_setting.dart';
import 'package:jhentai/src/setting/nhentai_api_setting.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/widget/eh_alert_dialog.dart';

class NhentaiDomainsPage extends StatelessWidget {
  const NhentaiDomainsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text('nhentaiDomains'.tr),
        actions: [
          IconButton(
            onPressed: () => _handleAdd(context),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: Text('nhentaiApiKey'.tr),
              subtitle: Text(
                nhentaiApiSetting.apiKey.value.isEmpty
                    ? 'nhentaiApiKeyNotConfigured'.tr
                    : 'nhentaiApiKeyConfigured'.tr,
              ),
              onTap: () => _handleApiKey(context),
            ),
            const Divider(),
            ...ehSetting.nhentaiDomains.map(
              (domain) => ListTile(
                title: Text(domain),
                onTap: () => _handleDelete(domain),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleAdd(BuildContext context) async {
    String? domain = await _showInputDialog(context);
    if (domain == null || domain.trim().isEmpty) {
      return;
    }
    ehSetting.addNhentaiDomain(domain.trim());
  }

  Future<void> _handleDelete(String domain) async {
    bool? result = await Get.dialog(EHDialog(title: '${'delete'.tr}?'));
    if (result == true) {
      ehSetting.removeNhentaiDomain(domain);
    }
  }

  Future<void> _handleApiKey(BuildContext context) async {
    final TextEditingController controller = TextEditingController(
      text: nhentaiApiSetting.apiKey.value,
    );
    try {
      final String? apiKey = await Get.dialog<String>(
        AlertDialog(
          title: Text('nhentaiApiKey'.tr),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: 'nhk_…',
              helperText: 'nhentaiApiKeyHint'.tr,
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
      if (apiKey != null) {
        await nhentaiApiSetting.saveApiKey(apiKey);
        if (syncSetting.enableSync.value && syncSetting.autoSync.value) {
          await syncService.syncAfterLocalChange(
            types: const [CloudConfigTypeEnum.nhentaiApiSetting],
          );
        }
        if (nhentaiApiSetting.apiKey.value.isNotEmpty) {
          try {
            final profile = await ehRequest.requestNhUserProfile();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'nhentaiApiKeyVerified'.trParams({
                      'username': profile.username,
                    }),
                  ),
                ),
              );
            }
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('nhentaiApiKeyValidationFailed'.tr)),
              );
            }
          }
        }
      }
    } finally {
      controller.dispose();
    }
  }

  Future<String?> _showInputDialog(BuildContext context) {
    final controller = TextEditingController();
    return Get.dialog<String>(
      AlertDialog(
        title: Text('addNhentaiDomain'.tr),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'nhentai.xxx'),
        ),
        actions: [
          TextButton(onPressed: Get.back, child: Text('cancel'.tr)),
          TextButton(
            onPressed: () => Get.back(result: controller.text),
            child: Text('OK'.tr),
          ),
        ],
        actionsPadding: const EdgeInsets.only(left: 24, right: 24, bottom: 12),
      ),
    );
  }
}
