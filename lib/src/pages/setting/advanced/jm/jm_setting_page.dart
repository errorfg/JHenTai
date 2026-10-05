import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_api.dart';
import 'package:jhentai/src/setting/jm_setting.dart';
import 'package:jhentai/src/utils/toast_util.dart';

/// JM API and image lines.
class JmSettingPage extends StatefulWidget {
  const JmSettingPage({super.key});

  @override
  State<JmSettingPage> createState() => _JmSettingPageState();
}

class _JmSettingPageState extends State<JmSettingPage> {
  bool _refreshing = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('jmSetting'.tr)),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: [
            ListTile(
              title: Text('jmApiLine'.tr),
              subtitle: Text('jmApiLineHint'.tr),
              trailing: _refreshing
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : IconButton(
                      tooltip: 'jmRefreshApiLines'.tr,
                      icon: const Icon(Icons.refresh),
                      onPressed: _refreshApiLines,
                    ),
            ),
            RadioGroup<String>(
              groupValue: jmSetting.preferredApiDomain.value,
              onChanged: (String? domain) => _selectApiLine(domain ?? ''),
              child: Column(
                children: [
                  RadioListTile<String>(value: '', title: Text('auto'.tr)),
                  // A picked line stays listed after the domain servers drop it.
                  ...{
                    ...jmSetting.apiDomains,
                    if (jmSetting.preferredApiDomain.value.isNotEmpty) jmSetting.preferredApiDomain.value,
                  }.map(
                    (String domain) => RadioListTile<String>(value: domain, title: Text(domain)),
                  ),
                ],
              ),
            ),
            const Divider(),
            ListTile(title: Text('jmImageLine'.tr)),
            RadioGroup<String>(
              groupValue: jmSetting.imageDomain.value,
              onChanged: (String? domain) {
                if (domain != null) {
                  jmSetting.saveImageDomain(domain);
                }
              },
              child: Column(
                children: JmApi.imageDomains
                    .map((String domain) => RadioListTile<String>(value: domain, title: Text(domain)))
                    .toList(),
              ),
            ),
          ],
        ).withListTileTheme(context),
      ),
    );
  }

  Future<void> _selectApiLine(String domain) async {
    await jmSetting.savePreferredApiDomain(domain);
    ehRequest.jmSource.api.resetApiDomain();
  }

  Future<void> _refreshApiLines() async {
    setState(() => _refreshing = true);
    try {
      List<String>? latest = await ehRequest.jmSource.api.fetchLatestApiDomains();
      if (latest == null) {
        toast('jmRefreshApiLinesFailed'.tr);
        return;
      }
      await jmSetting.saveDiscoveredApiDomains(latest);
      toast('success'.tr);
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }
}
