import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/network/tachi/tachi_client.dart';
import 'package:jhentai/src/network/tachi/tachi_host.dart';
import 'package:jhentai/src/network/tachi/tachi_models.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
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
  /// app was closed meanwhile too. A source missing here may or may not be
  /// in the host as stored (see [applyToHost]).
  Map<String, String> _inHost = <String, String>{};

  /// What the host had for a source the first time this device gave it
  /// settings from elsewhere, when that differed, by source id:
  /// `{"values": {...}, "replacedAt": "..."}`. The host's could be the ones
  /// wanted (a token the source renewed itself, say); kept on the device
  /// until restored (see [restoreReplaced]) or dropped.
  Map<String, Map<String, dynamic>> _replaced = <String, Map<String, dynamic>>{};

  /// Not kept by earlier versions, which left settings synced while the
  /// host did not run out of it: nothing stored then is taken as in the host.
  @override
  Future<void> doInitBean() async {
    final String? inHost = await localConfigService.read(configKey: ConfigEnum.tachiSourceSettingInHost);
    if (inHost != null) {
      _inHost = (jsonDecode(inHost) as Map).cast<String, String>();
    }
    final String? replaced = await localConfigService.read(configKey: ConfigEnum.tachiSourceSettingReplaced);
    if (replaced != null) {
      _replaced = <String, Map<String, dynamic>>{
        for (final MapEntry<String, dynamic> e in (jsonDecode(replaced) as Map<String, dynamic>).entries) e.key: Map<String, dynamic>.from(e.value as Map),
      };
    }
    // The host may have missed settings while it did not run.
    tachiHost.addStartListener(() => unawaited(applyToHost()));
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

  Future<void> _saveReplaced() => localConfigService.write(configKey: ConfigEnum.tachiSourceSettingReplaced, value: jsonEncode(_replaced));

  /// When the host's settings of [sourceId] were replaced by settings from
  /// elsewhere, if they are kept.
  DateTime? replacedAt(String sourceId) => SyncTimeUtil.tryParse(_replaced[sourceId]?['replacedAt'] as String?);

  /// Gives the host back the settings of [sourceId] it had before they were
  /// replaced, and takes them as the source's settings, which sync then
  /// carries.
  Future<void> restoreReplaced(String sourceId) async {
    final Map<String, dynamic>? replaced = _replaced[sourceId];
    if (replaced == null) {
      return;
    }
    await tachiHost.run((TachiClient c) => c.setPreferenceStore(sourceId, Map<String, dynamic>.from(replaced['values'] as Map)));
    await capture(sourceId);
    await dropReplaced(sourceId);
  }

  Future<void> dropReplaced(String sourceId) async {
    if (_replaced.remove(sourceId) != null) {
      await _saveReplaced();
    }
  }

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

  Future<void>? _applying;
  bool _applyAgain = false;

  /// Gives the host the settings that arrived from other devices, for
  /// installed sources: after a sync, an install, and once the host starts.
  /// Nothing when the host is not running: it is not started just for this
  /// on a phone. Settings it could not take stay to be given at the next
  /// call. One at a time; asked again meanwhile, it runs once more after.
  ///
  /// A source never given or taken on this device is compared with the
  /// host first: writing replaces all the source keeps, values it wrote
  /// itself since its settings were taken included.
  Future<void> applyToHost() {
    if (_applying != null) {
      _applyAgain = true;
      return _applying!;
    }
    return _applying = () async {
      do {
        _applyAgain = false;
        await _applyToHost();
      } while (_applyAgain);
    }()
        .whenComplete(() => _applying = null);
  }

  Future<void> _applyToHost() async {
    final TachiClient? client = tachiHost.clientIfRunning;
    if (client == null || _pending.isEmpty) {
      return;
    }
    final Set<String> installed;
    try {
      installed = (await client.extensions()).expand((TachiExtension e) => e.sources).map((TachiSourceInfo s) => s.id).toSet();
    } catch (e) {
      log.error('List the extensions of the Tachiyomi host failed', e);
      return;
    }
    bool applied = false;
    for (final String id in _pending.toList()) {
      if (!installed.contains(id)) {
        continue;
      }
      try {
        final String updatedAt = sources[id]!['updatedAt'] as String;
        final Map<String, dynamic> values = Map<String, dynamic>.from(sources[id]!['values'] as Map);
        if (_inHost.containsKey(id)) {
          await client.setPreferenceStore(id, values);
        } else {
          final Map<String, dynamic> current = await client.preferenceStore(id);
          if (!const DeepCollectionEquality().equals(current, values)) {
            if (current.isNotEmpty) {
              _replaced[id] = <String, dynamic>{'values': current, 'replacedAt': SyncTimeUtil.nowIso()};
              await _saveReplaced();
            }
            await client.setPreferenceStore(id, values);
          }
        }
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
