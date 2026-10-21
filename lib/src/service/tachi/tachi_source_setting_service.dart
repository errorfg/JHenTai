import 'dart:convert';

import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/network/tachi/tachi_client.dart';
import 'package:jhentai/src/network/tachi/tachi_host.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/tachi/tachi_extension_service.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

TachiSourceSettingService tachiSourceSettingService = TachiSourceSettingService();

/// What each Tachiyomi source keeps in its preferences (its settings, and
/// state such as a login token), taken from the host after the user changes
/// a setting, so that cloud sync carries it. Sources merge one by one, the
/// later change winning.
class TachiSourceSettingService with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  @override
  ConfigEnum get configEnum => ConfigEnum.tachiSourceSetting;

  /// By source id: `{"values": {...}, "updatedAt": "..."}`.
  Map<String, Map<String, dynamic>> sources = <String, Map<String, dynamic>>{};

  /// The `updatedAt` of the settings the host has, by source id: taken
  /// from it, or given to it. Kept on the device, so that settings that
  /// arrived while the host did not run reach it once it does, after the
  /// app was closed meanwhile too.
  Map<String, String> _inHost = <String, String>{};

  @override
  Future<void> doInitBean() async {
    final String? inHost = await localConfigService.read(configKey: ConfigEnum.tachiSourceSettingInHost);
    if (inHost != null) {
      _inHost = (jsonDecode(inHost) as Map).cast<String, String>();
      return;
    }
    // Kept from this version on: what was stored before, the host had.
    final String? stored = await localConfigService.read(configKey: configEnum);
    if (stored != null) {
      applyBeanConfig(stored);
      _inHost = <String, String>{
        for (final MapEntry<String, Map<String, dynamic>> e in sources.entries)
          if (e.value['updatedAt'] is String) e.key: e.value['updatedAt'] as String,
      };
    }
    await _saveInHost();
  }

  @override
  void doAfterBeanReady() {}

  @override
  void applyBeanConfig(String configString) {
    final Map<String, dynamic> json = jsonDecode(configString) as Map<String, dynamic>;
    sources = <String, Map<String, dynamic>>{
      for (final MapEntry<dynamic, dynamic> e in ((json['sources'] as Map?) ?? const <String, dynamic>{}).entries) e.key as String: Map<String, dynamic>.from(e.value as Map),
    };
  }

  /// Sources whose stored settings the host does not have.
  Iterable<String> get _pending => sources.keys.where((String id) => sources[id]!['updatedAt'] != _inHost[id]);

  Future<void> _saveInHost() => localConfigService.write(configKey: ConfigEnum.tachiSourceSettingInHost, value: jsonEncode(_inHost));

  @override
  String toConfigString() => jsonEncode(<String, dynamic>{'sources': sources});

  /// Takes [sourceId]'s preferences from the host.
  Future<void> capture(String sourceId) async {
    try {
      final Map<String, dynamic> values = await tachiHost.run((TachiClient c) => c.preferenceStore(sourceId));
      final String now = SyncTimeUtil.nowIso();
      sources[sourceId] = <String, dynamic>{'values': values, 'updatedAt': now};
      _inHost[sourceId] = now;
      await saveBeanConfig();
      await _saveInHost();
    } catch (e) {
      log.error('Read settings of Tachiyomi source $sourceId failed', e);
    }
  }

  /// Gives the host the settings that arrived from other devices, for
  /// installed sources; nothing when the host is not running. Settings it
  /// could not take stay to be given at the next call (see
  /// [TachiExtensionService.reconcileHost]).
  Future<void> applyToHost() async {
    final TachiClient? client = tachiHost.clientIfRunning;
    if (client == null) {
      return;
    }
    final Set<String> installed = tachiExtensionService.installed.expand((e) => e.sources).map((s) => s.id).toSet();
    bool applied = false;
    for (final String id in _pending.toList()) {
      if (!installed.contains(id)) {
        continue;
      }
      try {
        final String updatedAt = sources[id]!['updatedAt'] as String;
        await client.setPreferenceStore(id, Map<String, dynamic>.from(sources[id]!['values'] as Map));
        _inHost[id] = updatedAt;
        applied = true;
      } catch (e) {
        log.error('Write settings of Tachiyomi source $id failed', e);
      }
    }
    if (applied) {
      await _saveInHost();
    }
  }

  /// [local] and [remote] configs merged source by source.
  static String merge(String local, String remote) {
    Map<String, dynamic> read(String config) => ((jsonDecode(config) as Map<String, dynamic>)['sources'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final Map<String, dynamic> a = read(local);
    final Map<String, dynamic> b = read(remote);
    final Map<String, dynamic> merged = <String, dynamic>{...a};
    for (final MapEntry<String, dynamic> e in b.entries) {
      final String? mine = (a[e.key] as Map?)?['updatedAt'] as String?;
      final String? theirs = (e.value as Map)['updatedAt'] as String?;
      if (mine == null || (theirs != null && theirs.compareTo(mine) > 0)) {
        merged[e.key] = e.value;
      }
    }
    return jsonEncode(<String, dynamic>{'sources': merged});
  }
}
