import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/network/tachi/tachi_client.dart';
import 'package:jhentai/src/network/tachi/tachi_host.dart';
import 'package:jhentai/src/network/tachi/tachi_models.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/tachi/tachi_extension_service.dart';
import 'package:jhentai/src/service/tachi/tachi_source_setting_service.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/snack_util.dart';

import 'tachi_webview_page.dart';

/// The settings a Tachiyomi source declares, edited the way its Android
/// settings screen would: the source may refuse a value.
class TachiSourceSettingsPage extends StatefulWidget {
  const TachiSourceSettingsPage({super.key});

  @override
  State<TachiSourceSettingsPage> createState() => _TachiSourceSettingsPageState();
}

class _TachiSourceSettingsPageState extends State<TachiSourceSettingsPage> {
  final String sourceId = Get.arguments as String;
  List<TachiPreference>? _preferences;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final List<TachiPreference> preferences = await tachiHost.run((TachiClient c) => c.preferences(sourceId));
      if (mounted) {
        setState(() {
          _preferences = preferences;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  Future<void> _set(TachiPreference preference, Object value) async {
    try {
      final List<TachiPreference> preferences = await tachiHost.run((TachiClient c) => c.setPreference(sourceId, preference.key!, value));
      setState(() => _preferences = preferences);
      // Other devices take the source's settings with the next sync.
      await tachiSourceSettingService.capture(sourceId);
    } catch (e) {
      snack('failed'.tr, e.toString(), isShort: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<TachiPreference>? preferences = _preferences;
    return Scaffold(
      appBar: AppBar(
        title: Text(tachiExtensionService.source(sourceId)?.name ?? 'setting'.tr),
        centerTitle: true,
        actions: [
          // A login made on the site shows in settings that report it.
          if (TachiWebViewPage.supported && tachiExtensionService.source(sourceId)?.baseUrl != null)
            IconButton(
              icon: const Icon(Icons.public),
              tooltip: 'tachiOpenInWebView'.tr,
              onPressed: () async {
                await toRoute(Routes.tachiWebView, arguments: sourceId);
                if (mounted) {
                  await _load();
                }
              },
            ),
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'refresh'.tr, onPressed: _load),
        ],
      ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
          : preferences == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(children: [
                  if (tachiSourceSettingService.replacedAt(sourceId) != null) _restoreReplaced(),
                  for (final TachiPreference p in preferences.where((TachiPreference p) => p.visible)) _build(context, p),
                ]),
    );
  }

  /// The host's own settings, replaced once by settings synced from
  /// elsewhere (see [TachiSourceSettingService.restoreReplaced]).
  Widget _restoreReplaced() {
    final DateTime replacedAt = tachiSourceSettingService.replacedAt(sourceId)!;
    return ListTile(
      leading: const Icon(Icons.history),
      title: Text('tachiRestoreReplaced'.tr),
      subtitle: Text('tachiRestoreReplacedHint'.trParams(<String, String>{'time': DateFormat('yyyy-MM-dd HH:mm').format(replacedAt.toLocal())})),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'dismiss'.tr,
        onPressed: () async {
          await tachiSourceSettingService.dropReplaced(sourceId);
          setState(() {});
        },
      ),
      onTap: () async {
        try {
          await tachiSourceSettingService.restoreReplaced(sourceId);
          await _load();
        } catch (e) {
          snack('failed'.tr, e.toString(), isShort: true);
        }
      },
    );
  }

  Widget _build(BuildContext context, TachiPreference p) {
    final Widget? summary = p.summary == null || p.summary!.isEmpty ? null : Text(p.summary!);
    switch (p.type) {
      case 'category':
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(p.title, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
        );
      case 'switch':
        return SwitchListTile(
          title: Text(p.title),
          subtitle: summary,
          value: p.value as bool? ?? false,
          onChanged: p.enabled ? (bool v) => _set(p, v) : null,
        );
      case 'list':
        return ListTile(
          enabled: p.enabled,
          title: Text(p.title),
          subtitle: summary,
          onTap: () async {
            final String? value = await showDialog<String>(
              context: context,
              builder: (BuildContext context) => SimpleDialog(
                title: Text(p.dialogTitle ?? p.title),
                children: [
                  for (int i = 0; i < p.entryValues.length; i++)
                    RadioListTile<String>(
                      value: p.entryValues[i],
                      groupValue: p.value as String?,
                      title: Text(i < p.entries.length ? p.entries[i] : p.entryValues[i]),
                      onChanged: (String? v) => Navigator.of(context).pop(v),
                    ),
                ],
              ),
            );
            if (value != null && value != p.value) {
              await _set(p, value);
            }
          },
        );
      case 'multiSelect':
        return ListTile(
          enabled: p.enabled,
          title: Text(p.title),
          subtitle: summary,
          onTap: () async {
            final Set<String> chosen = ((p.value as List?) ?? const <dynamic>[]).cast<String>().toSet();
            final Set<String>? value = await showDialog<Set<String>>(
              context: context,
              builder: (BuildContext context) => StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) => AlertDialog(
                  title: Text(p.dialogTitle ?? p.title),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (int i = 0; i < p.entryValues.length; i++)
                          CheckboxListTile(
                            value: chosen.contains(p.entryValues[i]),
                            title: Text(i < p.entries.length ? p.entries[i] : p.entryValues[i]),
                            onChanged: (bool? v) => setState(() => v == true ? chosen.add(p.entryValues[i]) : chosen.remove(p.entryValues[i])),
                          ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('cancel'.tr)),
                    TextButton(onPressed: () => Navigator.of(context).pop(chosen), child: Text('OK')),
                  ],
                ),
              ),
            );
            if (value != null) {
              await _set(p, value.toList());
            }
          },
        );
      case 'text':
        return ListTile(
          enabled: p.enabled,
          title: Text(p.title),
          subtitle: summary,
          onTap: () async {
            final TextEditingController controller = TextEditingController(text: p.value as String? ?? '');
            final String? value = await showDialog<String>(
              context: context,
              builder: (BuildContext context) => AlertDialog(
                title: Text(p.dialogTitle ?? p.title),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (p.dialogMessage != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(p.dialogMessage!)),
                    TextField(controller: controller, autofocus: true, maxLines: null),
                  ],
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('cancel'.tr)),
                  TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: Text('OK')),
                ],
              ),
            );
            if (value != null && value != p.value) {
              await _set(p, value);
            }
          },
        );
      default:
        return ListTile(title: Text(p.title), subtitle: summary);
    }
  }
}
