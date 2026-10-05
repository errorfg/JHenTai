import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_api.dart';
import 'package:jhentai/src/setting/jm_setting.dart';
import 'package:jhentai/src/utils/toast_util.dart';

/// JM API and image lines: automatic (the fastest here) or a fixed pick,
/// with how fast each line answered at the last measurement.
class JmSettingPage extends StatefulWidget {
  const JmSettingPage({super.key});

  @override
  State<JmSettingPage> createState() => _JmSettingPageState();
}

class _JmSettingPageState extends State<JmSettingPage> {
  bool _measuring = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text('jmSetting'.tr),
        actions: [
          _measuring
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  key: const Key('jmMeasureLines'),
                  tooltip: 'jmMeasureLines'.tr,
                  icon: const Icon(Icons.speed),
                  onPressed: _measure,
                ),
        ],
      ),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: [
            ListTile(title: Text('jmApiLine'.tr), subtitle: Text('jmLineAutoHint'.tr)),
            RadioGroup<String>(
              groupValue: jmSetting.preferredApiDomain.value,
              onChanged: (String? domain) => _selectApiLine(domain ?? ''),
              child: Column(
                children: [
                  RadioListTile<String>(
                    value: '',
                    title: Text('auto'.tr),
                    subtitle: Text(jmSetting.orderedApiDomains().first),
                  ),
                  // A picked line stays listed after the domain servers drop it.
                  ...{
                    ...jmSetting.apiDomains,
                    if (jmSetting.preferredApiDomain.value.isNotEmpty) jmSetting.preferredApiDomain.value,
                  }.map(
                    (String domain) => RadioListTile<String>(
                      value: domain,
                      title: Text(domain),
                      subtitle: Text(_latency(jmSetting.apiLatencies[domain])),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            ListTile(title: Text('jmImageLine'.tr)),
            RadioGroup<String>(
              groupValue: jmSetting.preferredImageDomain.value,
              onChanged: (String? domain) => jmSetting.savePreferredImageDomain(domain ?? ''),
              child: Column(
                children: [
                  RadioListTile<String>(
                    value: '',
                    title: Text('auto'.tr),
                    subtitle: Text(jmSetting.autoImageDomain),
                  ),
                  ...{
                    ...jmSetting.imageDomainChoices(),
                    if (jmSetting.preferredImageDomain.value.isNotEmpty) jmSetting.preferredImageDomain.value,
                  }.map(
                    (String domain) => RadioListTile<String>(
                      value: domain,
                      title: Text(domain),
                      subtitle: Text(_latency(jmSetting.imageLatencies[domain])),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ).withListTileTheme(context),
      ),
    );
  }

  String _latency(int? milliseconds) {
    if (milliseconds == null) {
      return 'jmLineNotMeasured'.tr;
    }
    return milliseconds < 0 ? 'jmLineFailed'.tr : '$milliseconds ms';
  }

  Future<void> _selectApiLine(String domain) async {
    await jmSetting.savePreferredApiDomain(domain);
    ehRequest.jmSource.api.resetApiDomain();
  }

  Future<void> _measure() async {
    setState(() => _measuring = true);
    try {
      final JmApi api = ehRequest.jmSource.api;
      final List<String>? latest = await api.fetchLatestApiDomains();
      if (latest != null) {
        await jmSetting.saveDiscoveredApiDomains(latest);
      }
      await api.measureAndSave(jmSetting.saveMeasurement);
      api.resetApiDomain();
      toast('success'.tr);
    } finally {
      if (mounted) {
        setState(() => _measuring = false);
      }
    }
  }
}
