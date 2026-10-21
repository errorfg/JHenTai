import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart' show Value;
import 'package:jhentai/src/database/dao/gallery_history_dao.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/eh_account_sync.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/jm_favorite_service.dart';
import 'package:jhentai/src/service/local_block_rule_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/nhentai_favorite_service.dart';
import 'package:jhentai/src/service/quick_search_service.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/search_history_service.dart';
import 'package:jhentai/src/service/wnacg_favorite_service.dart';
import 'package:jhentai/src/setting/eh2telegraph_setting.dart';
import 'package:jhentai/src/setting/jm_account_setting.dart';
import 'package:jhentai/src/setting/komga_setting.dart';
import 'package:jhentai/src/setting/nhentai_api_setting.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';
import 'dart:async';
import 'package:jhentai/src/service/tachi/tachi_extension_service.dart';
import 'package:jhentai/src/service/tachi/tachi_favorite_service.dart';
import 'package:jhentai/src/service/tachi/tachi_source_setting_service.dart';

/// Translates between the app's data of one kind and records.
abstract class RecordAdapter {
  String get kind;

  /// The cloud config type the kind belongs to, for syncs of chosen types.
  CloudConfigTypeEnum get type;
}

/// A row of a kind the app keeps row by row, each row with its own time.
class RowItem {
  final String key;
  final String value;

  /// Canonical.
  final String time;

  const RowItem(this.key, this.value, this.time);
}

/// History and read progress: many rows, each with its time. Rows changed
/// here are known from the pending set the write paths keep.
abstract class RowKindAdapter extends RecordAdapter {
  /// The rows of [keys], or all rows when [keys] is null.
  Future<List<RowItem>> read(Set<String>? keys);

  Set<String> pendingKeys(PendingSyncSnapshotToken token);

  /// Writes [records] (values and deletions) into the app's data, not over
  /// a row that is newer.
  Future<void> apply(List<SyncRecordData> records);
}

/// An item as the app holds it.
class LocalItem {
  final String value;

  /// Time for the item when no earlier record of it is known to compare
  /// against, if the item carries one (a favorite's time, for instance).
  final String? firstTime;

  const LocalItem(this.value, {this.firstTime});
}

/// A kind the app keeps as one whole (a list in a config row, a few table
/// rows). Local changes are found by comparing its items with the records.
abstract class WholeKindAdapter extends RecordAdapter {
  /// The items the app holds now, in the app's order.
  Future<List<MapEntry<String, LocalItem>>> export();

  /// When the app's data of this kind last changed.
  Future<String> changeTime();

  /// Items that moved ahead in an order kept by time, with the time each
  /// must take now.
  Map<String, String> promotions(
    List<MapEntry<String, LocalItem>> items,
    Map<String, SyncRecordData> rows,
    String changeTime,
  ) =>
      const {};

  /// Makes the app's data of this kind exactly [records] (none deleted).
  Future<void> replaceAll(List<SyncRecordData> records);

  /// The kind this one took the place of, if any: a device new to this
  /// kind takes over what that kind's records hold, each item timed at its
  /// own time if it has one, else at the record's (see RecordSyncEngine).
  String? get legacyKind => null;

  /// The items a record of [legacyKind] with [value] holds.
  List<MapEntry<String, LocalItem>> legacyItems(String value) => const [];
}

List<RecordAdapter> defaultRecordAdapters() => [
      HistoryRecords(),
      ReadProgressRecords(),
      ConfigListRecords(
        kind: 'nhentaiFavorite',
        type: CloudConfigTypeEnum.nhentaiFavorite,
        configKey: ConfigEnum.nhentaiFavorite,
        refresh: () => nhentaiFavoriteService.refreshBean(),
      ),
      ConfigListRecords(
        kind: 'wnacgFavorite',
        type: CloudConfigTypeEnum.wnacgFavorite,
        configKey: ConfigEnum.wnacgFavorite,
        refresh: () => wnacgFavoriteService.refreshBean(),
      ),
      ConfigListRecords(
        kind: 'jmFavorite',
        type: CloudConfigTypeEnum.jmFavorite,
        configKey: ConfigEnum.jmFavorite,
        refresh: () => jmFavoriteService.refreshBean(),
      ),
      ConfigListRecords(
        kind: 'tachiFavorite',
        type: CloudConfigTypeEnum.tachiFavorite,
        configKey: ConfigEnum.tachiFavorite,
        refresh: () => tachiFavoriteService.refreshBean(),
      ),
      QuickSearchRecords(),
      SearchHistoryRecords(),
      BlockRuleRecords(),
      SingleConfigRecords(
        kind: 'syncSetting',
        type: CloudConfigTypeEnum.syncSetting,
        configKey: ConfigEnum.syncSetting,
        refresh: () => syncSetting.refreshBean(),
        keepLocal: (value) => syncSetting.withDeviceFields(value),
      ),
      SingleConfigRecords(
        kind: 'komgaSetting',
        type: CloudConfigTypeEnum.komgaSetting,
        configKey: ConfigEnum.komgaSetting,
        refresh: () => komgaSetting.refreshBean(),
      ),
      SingleConfigRecords(
        kind: 'nhentaiApiSetting',
        type: CloudConfigTypeEnum.nhentaiApiSetting,
        configKey: ConfigEnum.nhentaiApiSetting,
        refresh: () => nhentaiApiSetting.refreshBean(),
      ),
      SingleConfigRecords(
        kind: 'eh2telegraphSetting',
        type: CloudConfigTypeEnum.eh2telegraphSetting,
        configKey: ConfigEnum.eh2telegraphSetting,
        refresh: () => eh2telegraphSetting.refreshBean(),
      ),
      SingleConfigRecords(
        kind: 'jmAccount',
        type: CloudConfigTypeEnum.jmAccount,
        configKey: ConfigEnum.jmAccountSetting,
        refresh: () => jmAccountSetting.refreshBean(),
      ),
      EhAccountRecords(),
      TachiRepositoryRecords(),
      TachiSourceRecords(),
    ];

class HistoryRecords extends RowKindAdapter {
  @override
  String get kind => 'history';

  @override
  CloudConfigTypeEnum get type => CloudConfigTypeEnum.history;

  @override
  Future<List<RowItem>> read(Set<String>? keys) async {
    List<GalleryHistoryV2Data> rows;
    if (keys == null) {
      rows = await historyService.getAllRawHistory();
    } else {
      Set<int> gids = keys.map(int.tryParse).whereType<int>().toSet();
      rows = gids.isEmpty ? [] : await historyService.getRawHistoryByGids(gids);
    }
    return rows.map((h) => RowItem('${h.gid}', h.jsonBody, SyncTimeUtil.canonicalize(h.lastReadTime))).toList();
  }

  @override
  Set<String> pendingKeys(PendingSyncSnapshotToken token) => token.historyGids.map((gid) => '$gid').toSet();

  @override
  Future<void> apply(List<SyncRecordData> records) async {
    List<GalleryHistoryV2Data> upserts = [];
    for (SyncRecordData record in records) {
      int? gid = int.tryParse(record.key);
      if (gid == null) {
        continue;
      }
      if (record.deleted) {
        await GalleryHistoryDao.deleteIfNotNewer(gid, record.updatedAt);
      } else {
        upserts.add(GalleryHistoryV2Data(gid: gid, jsonBody: record.value!, lastReadTime: record.updatedAt));
      }
    }
    await historyService.batchRecordIfNewer(upserts);
  }
}

class ReadProgressRecords extends RowKindAdapter {
  @override
  String get kind => 'readProgress';

  @override
  CloudConfigTypeEnum get type => CloudConfigTypeEnum.readIndexRecord;

  @override
  Future<List<RowItem>> read(Set<String>? keys) async {
    List<LocalConfig> rows;
    if (keys == null) {
      rows = await localConfigService.readWithAllSubKeys(configKey: ConfigEnum.readIndexRecord);
    } else {
      rows = keys.isEmpty
          ? []
          : await localConfigService.readBySubKeys(configKey: ConfigEnum.readIndexRecord, subConfigKeys: keys);
    }
    return rows.map((p) => RowItem(p.subConfigKey, p.value, SyncTimeUtil.canonicalize(p.utime))).toList();
  }

  @override
  Set<String> pendingKeys(PendingSyncSnapshotToken token) => token.progressKeys;

  @override
  Future<void> apply(List<SyncRecordData> records) async {
    int changed = await localConfigService.batchWriteIfNewer(
      configKey: ConfigEnum.readIndexRecord,
      localConfigs: records
          .where((r) => !r.deleted)
          .map((r) => LocalConfigCompanion(
                configKey: Value(ConfigEnum.readIndexRecord.key),
                subConfigKey: Value(r.key),
                value: Value(r.value!),
                utime: Value(r.updatedAt),
              ))
          .toList(),
    );
    for (SyncRecordData record in records.where((r) => r.deleted)) {
      LocalConfig? row = await localConfigService.readRecord(configKey: ConfigEnum.readIndexRecord, subConfigKey: record.key);
      if (row != null && SyncTimeUtil.canonicalize(row.utime).compareTo(record.updatedAt) <= 0) {
        await localConfigService.delete(configKey: ConfigEnum.readIndexRecord, subConfigKey: record.key);
        changed++;
      }
    }
    if (changed > 0) {
      readProgressService.clearCacheAndRefresh();
    }
  }
}

/// When the config row of [configKey] was last written; now if there is none.
Future<String> _configTime(ConfigEnum configKey) async {
  LocalConfig? row = await localConfigService.readRecord(configKey: configKey);
  return row == null ? SyncTimeUtil.nowIso() : SyncTimeUtil.canonicalize(row.utime);
}

/// A JSON list kept in one config row, one record per item: the favorites
/// of the sources whose favorites live on the device.
class ConfigListRecords extends WholeKindAdapter {
  @override
  final String kind;

  @override
  final CloudConfigTypeEnum type;

  final ConfigEnum configKey;
  final Future<void> Function() refresh;

  ConfigListRecords({required this.kind, required this.type, required this.configKey, required this.refresh});

  @override
  Future<List<MapEntry<String, LocalItem>>> export() async {
    String? raw = await localConfigService.read(configKey: configKey);
    if (raw == null) {
      return [];
    }
    dynamic list = await isolateService.jsonDecodeAsync(raw);
    if (list is! List) {
      return [];
    }

    List<MapEntry<String, LocalItem>> items = [];
    for (dynamic item in list) {
      if (item is! Map || item['gallery'] is! Map || item['gallery']['gid'] == null) {
        continue;
      }
      DateTime? favoritedTime = SyncTimeUtil.tryParse(item['favoritedTime']?.toString());
      items.add(MapEntry(
        '${item['gallery']['gid']}',
        LocalItem(jsonEncode(item), firstTime: favoritedTime == null ? null : SyncTimeUtil.format(favoritedTime)),
      ));
    }
    return items;
  }

  @override
  Future<String> changeTime() => _configTime(configKey);

  @override
  Future<void> replaceAll(List<SyncRecordData> records) async {
    List<dynamic> list = [for (SyncRecordData record in records) jsonDecode(record.value!)];
    await localConfigService.write(configKey: configKey, value: await isolateService.jsonEncodeAsync(list));
    await refresh();
  }
}

/// Quick searches by name; the position travels in the value.
class QuickSearchRecords extends WholeKindAdapter {
  @override
  String get kind => 'quickSearch';

  @override
  CloudConfigTypeEnum get type => CloudConfigTypeEnum.quickSearch;

  @override
  Future<List<MapEntry<String, LocalItem>>> export() async {
    String? raw = await localConfigService.read(configKey: ConfigEnum.quickSearch);
    if (raw == null) {
      return [];
    }
    dynamic map = jsonDecode(raw);
    if (map is! Map) {
      return [];
    }

    int order = 0;
    return [
      for (MapEntry entry in map.entries)
        MapEntry('${entry.key}', LocalItem(jsonEncode({'order': order++, 'config': entry.value}))),
    ];
  }

  @override
  Future<String> changeTime() => _configTime(ConfigEnum.quickSearch);

  @override
  Future<void> replaceAll(List<SyncRecordData> records) async {
    List<MapEntry<String, Map>> entries = [
      for (SyncRecordData record in records) MapEntry(record.key, jsonDecode(record.value!) as Map),
    ]..sort((a, b) {
        int byOrder = (a.value['order'] as int).compareTo(b.value['order'] as int);
        return byOrder != 0 ? byOrder : a.key.compareTo(b.key);
      });
    Map<String, dynamic> map = {for (MapEntry<String, Map> entry in entries) entry.key: entry.value['config']};
    await localConfigService.write(configKey: ConfigEnum.quickSearch, value: jsonEncode(map));
    await quickSearchService.refreshBean();
  }
}

/// Search keywords, newest first; the order is the order of the records'
/// times, so searching a keyword again only moves that one record.
class SearchHistoryRecords extends WholeKindAdapter {
  static const int maxLength = 50;

  @override
  String get kind => 'searchHistory';

  @override
  CloudConfigTypeEnum get type => CloudConfigTypeEnum.searchHistory;

  @override
  Future<List<MapEntry<String, LocalItem>>> export() async {
    String? raw = await localConfigService.read(configKey: ConfigEnum.searchHistory);
    if (raw == null) {
      return [];
    }
    dynamic list = jsonDecode(raw);
    if (list is! List) {
      return [];
    }

    DateTime time = SyncTimeUtil.parse(await changeTime());
    List<MapEntry<String, LocalItem>> items = [];
    Set<String> seen = {};
    for (dynamic item in list) {
      String? keyword = item is String ? item : (item is Map && item['rawKeyword'] is String ? item['rawKeyword'] : null);
      if (keyword == null || keyword.trim().isEmpty || !seen.add(keyword)) {
        continue;
      }
      // Older entries take earlier times, keeping the order for devices that rebuild it from times.
      items.add(MapEntry(
        keyword,
        LocalItem(jsonEncode(keyword), firstTime: SyncTimeUtil.format(time.subtract(Duration(microseconds: items.length)))),
      ));
    }
    return items;
  }

  @override
  Future<String> changeTime() => _configTime(ConfigEnum.searchHistory);

  /// From the oldest entry on, an entry whose record is not later than the
  /// entry after it was searched again and moved up. Records not yet written
  /// into the list do not count: the list has not taken their order yet.
  @override
  Map<String, String> promotions(
    List<MapEntry<String, LocalItem>> items,
    Map<String, SyncRecordData> rows,
    String changeTime,
  ) {
    Map<String, String> promoted = {};
    String? floor;
    for (MapEntry<String, LocalItem> item in items.reversed) {
      SyncRecordData? row = rows[item.key];
      if (row != null && row.applyPending) {
        continue;
      }
      String? time = row == null || row.deleted ? item.value.firstTime : row.updatedAt;
      if (row != null && !row.deleted && floor != null && time!.compareTo(floor) <= 0) {
        String candidate = item.value.firstTime!;
        time = candidate.compareTo(floor) > 0 ? candidate : _microsecondAfter(floor);
        promoted[item.key] = time;
      }
      if (time != null && (floor == null || time.compareTo(floor) > 0)) {
        floor = time;
      }
    }
    return promoted;
  }

  @override
  Future<void> replaceAll(List<SyncRecordData> records) async {
    List<String> keywords = (records.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)))
        .take(maxLength)
        .map((r) => r.key)
        .toList();
    await localConfigService.write(configKey: ConfigEnum.searchHistory, value: jsonEncode(keywords));
    await searchHistoryService.refreshBean();
  }
}

/// Block rules by group; a group is changed and removed as a whole.
class BlockRuleRecords extends WholeKindAdapter {
  @override
  String get kind => 'blockRules';

  @override
  CloudConfigTypeEnum get type => CloudConfigTypeEnum.blockRules;

  @override
  Future<List<MapEntry<String, LocalItem>>> export() async {
    Map<String, List<LocalBlockRule>> groups =
        groupBy((await localBlockRuleService.getBlockRules()).where((r) => r.groupId != null), (r) => r.groupId!);
    return [
      for (MapEntry<String, List<LocalBlockRule>> group in groups.entries)
        MapEntry(group.key, LocalItem(_encode(group.value))),
    ];
  }

  /// Rules without their local ids, in a fixed order.
  static String _encode(List<LocalBlockRule> rules) {
    List<Map<String, dynamic>> maps = rules
        .map((r) => {
              'target': r.target.code,
              'attribute': r.attribute.code,
              'pattern': r.pattern.code,
              'expression': r.expression,
            })
        .toList()
      ..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
    return jsonEncode(maps);
  }

  @override
  Future<String> changeTime() async => SyncTimeUtil.nowIso();

  @override
  Future<void> replaceAll(List<SyncRecordData> records) async {
    Map<String, String> current = {for (MapEntry<String, LocalItem> e in await export()) e.key: e.value.value};
    Map<String, String> wanted = {for (SyncRecordData r in records) r.key: r.value!};

    for (String groupId in current.keys.where((g) => !wanted.containsKey(g))) {
      await localBlockRuleService.removeLocalBlockRulesByGroupId(groupId);
    }
    for (MapEntry<String, String> group in wanted.entries) {
      if (current[group.key] == group.value) {
        continue;
      }
      List<LocalBlockRule> rules = (jsonDecode(group.value) as List)
          .map((e) => LocalBlockRule.fromJson({...Map<String, dynamic>.from(e), 'groupId': group.key}))
          .toList();
      await localBlockRuleService.replaceBlockRulesByGroup(group.key, rules);
    }
  }
}

/// One setting kept whole in one config row.
class SingleConfigRecords extends WholeKindAdapter {
  static const String key = 'default';

  @override
  final String kind;

  @override
  final CloudConfigTypeEnum type;

  final ConfigEnum configKey;
  final Future<void> Function() refresh;

  /// The value to store for a value of another device, when part of the
  /// setting stays this device's own.
  final String Function(String value)? keepLocal;

  SingleConfigRecords({
    required this.kind,
    required this.type,
    required this.configKey,
    required this.refresh,
    this.keepLocal,
  });

  @override
  Future<List<MapEntry<String, LocalItem>>> export() async {
    LocalConfig? row = await localConfigService.readRecord(configKey: configKey);
    if (row == null) {
      return [];
    }
    return [MapEntry(key, LocalItem(row.value, firstTime: SyncTimeUtil.canonicalize(row.utime)))];
  }

  @override
  Future<String> changeTime() => _configTime(configKey);

  /// A setting removed on another device is left as it is here.
  @override
  Future<void> replaceAll(List<SyncRecordData> records) async {
    SyncRecordData? record = records.firstWhereOrNull((r) => r.key == key);
    if (record == null) {
      return;
    }
    await localConfigService.batchWrite([
      LocalConfigCompanion(
        configKey: Value(configKey.key),
        subConfigKey: const Value(LocalConfigService.defaultSubConfigKey),
        value: Value(keepLocal?.call(record.value!) ?? record.value!),
        utime: Value(record.updatedAt),
      ),
    ]);
    await refresh();
  }
}

/// Tachiyomi extension repositories (see [TachiExtensionService]), a record
/// for each: repositories added on two devices are both kept, and one
/// removed on a device is removed on the others. Which extensions are
/// installed is each device's own. Up to 8.1.1 the repositories and the
/// installed extensions were one record of kind `tachiExtensionList`.
class TachiRepositoryRecords extends WholeKindAdapter {
  @override
  String get kind => 'tachiRepository';

  @override
  CloudConfigTypeEnum get type => CloudConfigTypeEnum.tachiExtensionList;

  @override
  String get legacyKind => 'tachiExtensionList';

  Future<Map<String, dynamic>> _config() async {
    String? raw = await localConfigService.read(configKey: ConfigEnum.tachiExtensionSetting);
    return raw == null ? {} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  static List<MapEntry<String, LocalItem>> _items(Map config) => [
        for (dynamic repo in (config['repos'] as List?) ?? [])
          if (repo is String) MapEntry(repo, LocalItem(jsonEncode(repo))),
      ];

  @override
  Future<List<MapEntry<String, LocalItem>>> export() async => _items(await _config());

  @override
  List<MapEntry<String, LocalItem>> legacyItems(String value) => _items(jsonDecode(value) as Map);

  @override
  Future<String> changeTime() => _configTime(ConfigEnum.tachiExtensionSetting);

  /// Repositories already here keep their order; new ones follow. The
  /// installed extensions stay as they are.
  @override
  Future<void> replaceAll(List<SyncRecordData> records) async {
    Map<String, dynamic> config = await _config();
    List<String> repos = [for (SyncRecordData r in records) jsonDecode(r.value!) as String];
    List<String> oldRepos = ((config['repos'] as List?) ?? []).whereType<String>().toList();
    await localConfigService.write(
      configKey: ConfigEnum.tachiExtensionSetting,
      value: jsonEncode({
        ...config,
        'repos': [
          ...oldRepos.where(repos.contains),
          ...repos.where((r) => !oldRepos.contains(r)),
        ],
        'updatedAt': SyncTimeUtil.nowIso(),
      }),
    );
    await tachiExtensionService.refreshBean();
  }
}

/// The settings of Tachiyomi sources (see [TachiSourceSettingService]), a
/// record for each source: settings of a source changed on one device do
/// not take back those of another source changed on another. Up to 8.1.1
/// all were one record of kind `tachiSourceSettings`.
class TachiSourceRecords extends WholeKindAdapter {
  @override
  String get kind => 'tachiSource';

  @override
  CloudConfigTypeEnum get type => CloudConfigTypeEnum.tachiSourceSettings;

  @override
  String get legacyKind => 'tachiSourceSettings';

  /// Each source's settings, timed at when they were changed.
  static List<MapEntry<String, LocalItem>> _items(Map config) {
    Map sources = config['sources'] as Map? ?? {};
    List<MapEntry<String, LocalItem>> items = [];
    for (MapEntry entry in sources.entries) {
      if (entry.value is! Map) {
        continue;
      }
      DateTime? time = SyncTimeUtil.tryParse(entry.value['updatedAt']?.toString());
      items.add(MapEntry(
        '${entry.key}',
        LocalItem(jsonEncode(entry.value), firstTime: time == null ? null : SyncTimeUtil.format(time)),
      ));
    }
    return items;
  }

  @override
  Future<List<MapEntry<String, LocalItem>>> export() async {
    String? raw = await localConfigService.read(configKey: ConfigEnum.tachiSourceSetting);
    return raw == null ? [] : _items(jsonDecode(raw) as Map);
  }

  @override
  List<MapEntry<String, LocalItem>> legacyItems(String value) => _items(jsonDecode(value) as Map);

  @override
  Future<String> changeTime() => _configTime(ConfigEnum.tachiSourceSetting);

  @override
  Future<void> replaceAll(List<SyncRecordData> records) async {
    await localConfigService.write(
      configKey: ConfigEnum.tachiSourceSetting,
      value: jsonEncode({
        'sources': {for (SyncRecordData r in records) r.key: jsonDecode(r.value!)},
      }),
    );
    await tachiSourceSettingService.refreshBean();
    unawaited(tachiSourceSettingService.applyToHost());
  }
}

/// The E-Hentai login (see [EhAccountSync]), one record.
class EhAccountRecords extends WholeKindAdapter {
  static const String key = 'default';

  @override
  String get kind => 'ehAccount';

  @override
  CloudConfigTypeEnum get type => CloudConfigTypeEnum.ehAccount;

  @override
  Future<List<MapEntry<String, LocalItem>>> export() async {
    EhAccountValue? account = await ehAccountSync.export();
    return account == null ? [] : [MapEntry(key, LocalItem(account.value, firstTime: account.time))];
  }

  @override
  Future<String> changeTime() async => (await ehAccountSync.export())?.time ?? SyncTimeUtil.nowIso();

  @override
  Future<void> replaceAll(List<SyncRecordData> records) async {
    SyncRecordData? record = records.firstWhereOrNull((r) => r.key == key);
    if (record != null) {
      await ehAccountSync.apply(record.value!, record.updatedAt);
    }
  }
}

String _microsecondAfter(String time) =>
    SyncTimeUtil.format(SyncTimeUtil.parse(time).add(const Duration(microseconds: 1)));
