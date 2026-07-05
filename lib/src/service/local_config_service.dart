import 'package:drift/drift.dart';
import 'package:jhentai/src/database/dao/local_config_dao.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

import '../database/database.dart';
import 'log.dart';

class LocalConfig {
  ConfigEnum configKey;
  String subConfigKey;
  String value;
  String utime;

  LocalConfig({
    required this.configKey,
    required this.subConfigKey,
    required this.value,
    required this.utime,
  });

  Map<String, dynamic> toJson() {
    return {
      "configKey": this.configKey.key,
      "subConfigKey": this.subConfigKey,
      "value": this.value,
      "utime": this.utime,
    };
  }

  factory LocalConfig.fromJson(Map<String, dynamic> json) {
    return LocalConfig(
      configKey: ConfigEnum.from(json["configKey"]),
      subConfigKey: json["subConfigKey"],
      value: json["value"],
      utime: json["utime"],
    );
  }
}

LocalConfigService localConfigService = LocalConfigService();

class LocalConfigService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  static const String defaultSubConfigKey = '';

  @override
  Future<void> doInitBean() async {}

  Future<void>? _migrationFuture;

  @override
  Future<void> doAfterBeanReady() async {
    await ensureMigrated();
  }

  /// One-time migration: readIndexRecord utime values used to be local-time
  /// strings (and briefly variable-width ISO strings); convert them to the
  /// canonical fixed-width UTC form so that lexicographic comparison (used by
  /// sync cursors and SQL guards) equals chronological comparison.
  ///
  /// Awaitable and memoized: the sync service calls this before its first
  /// sync because bean ready hooks are fired without being awaited.
  Future<void> ensureMigrated() {
    return _migrationFuture ??= _migrateReadIndexUtimeToUtc();
  }

  Future<void> _migrateReadIndexUtimeToUtc() async {
    /// v2: also rewrites variable-width ISO strings written by early builds
    String? done = await read(configKey: ConfigEnum.migrateLocalConfigUtimeToUtc);
    if (done == '2') {
      return;
    }

    try {
      List<LocalConfig> records = await readWithAllSubKeys(configKey: ConfigEnum.readIndexRecord);
      List<LocalConfigCompanion> updates = [];
      for (LocalConfig record in records) {
        if (SyncTimeUtil.isCanonical(record.utime)) {
          continue;
        }
        DateTime? parsed = SyncTimeUtil.tryParse(record.utime);
        if (parsed == null) {
          continue;
        }
        updates.add(LocalConfigCompanion(
          configKey: Value(record.configKey.key),
          subConfigKey: Value(record.subConfigKey),
          value: Value(record.value),
          utime: Value(SyncTimeUtil.format(parsed)),
        ));
      }

      if (updates.isNotEmpty) {
        await batchWrite(updates);
        log.info('Migrated ${updates.length} readIndexRecord utime values to UTC');
      }
      await write(configKey: ConfigEnum.migrateLocalConfigUtimeToUtc, value: '2');
    } catch (e) {
      log.error('Migrate readIndexRecord utime to UTC failed', e);
    }
  }

  Future<int> write({required ConfigEnum configKey, String subConfigKey = defaultSubConfigKey, required String value}) {
    return appDb.managers.localConfig.create(
      (l) => l(configKey: configKey.key, subConfigKey: subConfigKey, value: value, utime: SyncTimeUtil.nowIso()),
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<void> batchWrite(List<LocalConfigCompanion> localConfigs) async {
    return appDb.managers.localConfig.bulkCreate(
      (l) => localConfigs
          .map((i) => l(
                configKey: i.configKey.value,
                subConfigKey: i.subConfigKey.value,
                value: i.value.value,
                utime: i.utime.value,
              ))
          .toList(),
      mode: InsertMode.insertOrReplace,
    );
  }


  /// Write [localConfigs] but only rows that are newer (by utime) than what is
  /// already stored, or absent locally. Prevents a sync merge computed from a
  /// stale snapshot from rolling back progress written concurrently.
  ///
  /// Incoming timestamps are canonicalized so that no ingest path (legacy
  /// remote data, packs pushed by not-yet-migrated devices) can reintroduce
  /// non-canonical strings. The Dart-side prefilter provides the count and
  /// avoids touching untouched rows; the final write is an atomic SQL-guarded
  /// upsert so a row written concurrently can never be clobbered.
  ///
  /// Returns the number of rows that passed the prefilter (upper bound of
  /// rows actually written).
  Future<int> batchWriteIfNewer({required ConfigEnum configKey, required List<LocalConfigCompanion> localConfigs}) async {
    if (localConfigs.isEmpty) {
      return 0;
    }

    List<LocalConfig> existing = await readWithAllSubKeys(configKey: configKey);
    Map<String, DateTime> existingUtime = {
      for (LocalConfig record in existing)
        if (SyncTimeUtil.tryParse(record.utime) != null) record.subConfigKey: SyncTimeUtil.parse(record.utime)
    };
    Map<String, String> existingValue = {for (LocalConfig record in existing) record.subConfigKey: record.value};

    List<LocalConfigCompanion> newer = [];
    for (LocalConfigCompanion companion in localConfigs) {
      String subKey = companion.subConfigKey.value;
      DateTime? incomingTime = SyncTimeUtil.tryParse(companion.utime.value);
      if (incomingTime == null) {
        continue;
      }

      LocalConfigCompanion canonical = LocalConfigCompanion(
        configKey: companion.configKey,
        subConfigKey: companion.subConfigKey,
        value: companion.value,
        utime: Value(SyncTimeUtil.format(incomingTime)),
      );

      DateTime? localTime = existingUtime[subKey];
      if (localTime == null) {
        newer.add(canonical);
        continue;
      }
      if (incomingTime.isAfter(localTime) && existingValue[subKey] != companion.value.value) {
        newer.add(canonical);
      }
    }

    if (newer.isNotEmpty) {
      await LocalConfigDao.batchUpsertIfNewer(newer);
    }
    return newer.length;
  }

  Future<String?> read({required ConfigEnum configKey, String subConfigKey = defaultSubConfigKey}) {
    return appDb.managers.localConfig
        .filter((config) => config.configKey.equals(configKey.key) & config.subConfigKey.equals(subConfigKey))
        .getSingleOrNull()
        .then((value) => value?.value);
  }

  Future<List<LocalConfig>> readWithAllSubKeys({required ConfigEnum configKey}) {
    return appDb.managers.localConfig.filter((config) => config.configKey.equals(configKey.key)).get().then((value) {
      return value
          .map((e) => LocalConfig(
                configKey: ConfigEnum.from(e.configKey),
                subConfigKey: e.subConfigKey,
                value: e.value,
                utime: e.utime,
              ))
          .toList();
    });
  }

  /// Rows of [configKey] with utime strictly greater than [utimeExclusive].
  /// Both sides must be canonical UTC ISO8601 (see migration above), which
  /// makes the string comparison chronological.
  Future<List<LocalConfig>> readNewerThan({required ConfigEnum configKey, required String utimeExclusive}) {
    return (appDb.select(appDb.localConfig)
          ..where((tbl) => tbl.configKey.equals(configKey.key) & tbl.utime.isBiggerThanValue(utimeExclusive)))
        .get()
        .then((value) => value
            .map((e) => LocalConfig(
                  configKey: ConfigEnum.from(e.configKey),
                  subConfigKey: e.subConfigKey,
                  value: e.value,
                  utime: e.utime,
                ))
            .toList());
  }

  /// Rows of [configKey] whose subConfigKey is in [subConfigKeys].
  Future<List<LocalConfig>> readBySubKeys({required ConfigEnum configKey, required Set<String> subConfigKeys}) async {
    List<LocalConfig> result = [];
    List<String> keys = subConfigKeys.toList();
    for (int i = 0; i < keys.length; i += 500) {
      List<String> chunk = keys.sublist(i, i + 500 > keys.length ? keys.length : i + 500);
      List<LocalConfigData> rows = await (appDb.select(appDb.localConfig)
            ..where((tbl) => tbl.configKey.equals(configKey.key) & tbl.subConfigKey.isIn(chunk)))
          .get();
      result.addAll(rows.map((e) => LocalConfig(
            configKey: ConfigEnum.from(e.configKey),
            subConfigKey: e.subConfigKey,
            value: e.value,
            utime: e.utime,
          )));
    }
    return result;
  }

  /// Max utime of [configKey] rows, or null when empty.
  Future<String?> maxUtime({required ConfigEnum configKey}) async {
    List<LocalConfigData> rows = await (appDb.select(appDb.localConfig)
          ..where((tbl) => tbl.configKey.equals(configKey.key))
          ..orderBy([(tbl) => OrderingTerm(expression: tbl.utime, mode: OrderingMode.desc)])
          ..limit(1))
        .get();
    return rows.isEmpty ? null : rows.first.utime;
  }

  Future<bool> delete({required ConfigEnum configKey, String subConfigKey = defaultSubConfigKey}) {
    return appDb.managers.localConfig
        .filter((config) => config.configKey.equals(configKey.key) & config.subConfigKey.equals(subConfigKey))
        .delete()
        .then((value) => value > 0);
  }
}
