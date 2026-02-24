import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/setting/eh_setting.dart';
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
          IconButton(onPressed: () => _handleAdd(context), icon: const Icon(Icons.add)),
        ],
      ),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: ehSetting.nhentaiDomains
              .map(
                (domain) => ListTile(
                  title: Text(domain),
                  onTap: () => _handleDelete(domain),
                ),
              )
              .toList(),
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
