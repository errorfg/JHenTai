import 'dart:convert';

import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/network/tachi/tachi_client.dart';
import 'package:jhentai/src/network/tachi/tachi_host.dart';
import 'package:jhentai/src/service/jh_service.dart';
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

  /// Sources whose stored settings arrived from another device and are not
  /// in the host yet.
  final Set<String> _pending = <String>{};

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  @override
  void applyBeanConfig(String configString) {
    final Map<String, dynamic> json = jsonDecode(configString) as Map<String, dynamic>;
    final Map<String, Map<String, dynamic>> next = <String, Map<String, dynamic>>{
      for (final MapEntry<dynamic, dynamic> e in ((json['sources'] as Map?) ?? const <String, dynamic>{}).entries) e.key as String: Map<String, dynamic>.from(e.value as Map),
    };
    for (final MapEntry<String, Map<String, dynamic>> e in next.entries) {
      if (sources[e.key]?['updatedAt'] != e.value['updatedAt']) {
        _pending.add(e.key);
      }
    }
    sources = next;
  }

  @override
  String toConfigString() => jsonEncode(<String, dynamic>{'sources': sources});

  /// Takes [sourceId]'s preferences from the host.
  Future<void> capture(String sourceId) async {
    try {
      final Map<String, dynamic> values = await tachiHost.run((TachiClient c) => c.preferenceStore(sourceId));
      sources[sourceId] = <String, dynamic>{'values': values, 'updatedAt': SyncTimeUtil.nowIso()};
      _pending.remove(sourceId);
      await saveBeanConfig();
    } catch (e) {
      log.error('Read settings of Tachiyomi source $sourceId failed', e);
    }
  }

  /// Gives the host the settings that arrived from other devices, for
  /// installed sources; nothing when the host is not running.
  Future<void> applyToHost() async {
    final TachiClient? client = tachiHost.clientIfRunning;
    if (client == null) {
      return;
    }
    final Set<String> installed = tachiExtensionService.installed.expand((e) => e.sources).map((s) => s.id).toSet();
    for (final String id in _pending.toList()) {
      if (!installed.contains(id)) {
        continue;
      }
      try {
        await client.setPreferenceStore(id, Map<String, dynamic>.from(sources[id]!['values'] as Map));
        _pending.remove(id);
      } catch (e) {
        log.error('Write settings of Tachiyomi source $id failed', e);
      }
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
