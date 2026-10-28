import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/eh_account_sync.dart';
import 'package:jhentai/src/service/jm_favorite_service.dart';
import 'package:jhentai/src/setting/jm_account_setting.dart';
import 'package:jhentai/src/service/nhentai_favorite_service.dart';
import 'package:jhentai/src/service/wnacg_favorite_service.dart';
import 'package:jhentai/src/service/quick_search_service.dart';
import 'package:jhentai/src/service/search_history_service.dart';
import 'package:jhentai/src/setting/komga_setting.dart';
import 'package:jhentai/src/setting/nhentai_api_setting.dart';
import 'package:jhentai/src/setting/eh2telegraph_setting.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

import '../database/database.dart';
import 'history_service.dart';
import 'jh_service.dart';
import 'local_block_rule_service.dart';
import 'log.dart';
import 'read_progress_service.dart';
import 'dart:async';
import 'package:jhentai/src/service/tachi/tachi_extension_service.dart';
import 'package:jhentai/src/service/tachi/tachi_favorite_service.dart';
import 'package:jhentai/src/service/tachi/tachi_source_setting_service.dart';

CloudConfigService cloudConfigService = CloudConfigService();

class CloudConfigService
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  static Map<CloudConfigTypeEnum, String> configTypeVersionMap = {
    CloudConfigTypeEnum.readIndexRecord: '1.0.0',
    CloudConfigTypeEnum.quickSearch: '1.0.0',
    CloudConfigTypeEnum.searchHistory: '1.0.0',
    CloudConfigTypeEnum.blockRules: '1.0.0',
    CloudConfigTypeEnum.history: '1.0.0',
    CloudConfigTypeEnum.syncSetting: '1.0.0',
    CloudConfigTypeEnum.nhentaiFavorite: '1.0.0',
    CloudConfigTypeEnum.wnacgFavorite: '1.0.0',
    CloudConfigTypeEnum.komgaSetting: '1.0.0',
    CloudConfigTypeEnum.nhentaiApiSetting: '1.0.0',
    CloudConfigTypeEnum.eh2telegraphSetting: '1.0.0',
    CloudConfigTypeEnum.jmFavorite: '1.0.0',
    CloudConfigTypeEnum.jmAccount: '1.0.0',
    CloudConfigTypeEnum.ehAccount: '1.0.0',
    CloudConfigTypeEnum.tachiExtensionList: '1.0.0',
    CloudConfigTypeEnum.tachiSourceSettings: '1.0.0',
    CloudConfigTypeEnum.tachiFavorite: '1.0.0',
  };

  static const int localConfigId = -1;
  static const String localConfigCode = 'local';
  static const String configFileName = 'JHenTaiConfig';

  @override
  Future<void> doInitBean() async {}

  @override
  Future<void> doAfterBeanReady() async {}

  /// [replace]: the data of the type becomes [config]'s (a history version
  /// restored); otherwise block rule groups already here are kept.
  Future<void> importConfig(CloudConfig config, {bool replace = false}) async {
    log.info('📥 Importing config: ${config.type.name}');

    switch (config.type) {
      case CloudConfigTypeEnum.readIndexRecord:
        List list = await isolateService.jsonDecodeAsync(config.config);
        List<LocalConfig> readIndexRecords = list
            .map((e) => LocalConfig.fromJson(e))
            .toList();

        /// Only write rows that are newer than the local ones: the merge was
        /// computed from a snapshot taken when the sync started, and progress
        /// updated concurrently must not be rolled back.
        int written = await localConfigService.batchWriteIfNewer(
          configKey: ConfigEnum.readIndexRecord,
          localConfigs: readIndexRecords
              .map(
                (e) => LocalConfigCompanion(
                  configKey: Value(e.configKey.key),
                  subConfigKey: Value(e.subConfigKey),
                  value: Value(e.value),
                  utime: Value(e.utime),
                ),
              )
              .toList(),
        );
        if (written > 0) {
          readProgressService.clearCacheAndRefresh();
        }
        log.info(
          '  ✅ Read index records imported ($written of ${readIndexRecords.length} rows newer than local)',
        );
        break;
      case CloudConfigTypeEnum.quickSearch:
        await localConfigService.write(
          configKey: ConfigEnum.quickSearch,
          value: config.config,
        );
        log.info('  Refreshing quick search service');
        await quickSearchService.refreshBean();
        log.info('  ✅ Quick search imported and refreshed');
        break;
      case CloudConfigTypeEnum.searchHistory:
        List historyList = await isolateService.jsonDecodeAsync(config.config);
        log.info('  Writing ${historyList.length} search history items');
        await localConfigService.write(
          configKey: ConfigEnum.searchHistory,
          value: config.config,
        );
        await searchHistoryService.refreshBean();
        log.info('  ✅ Search history imported and refreshed');
        break;
      case CloudConfigTypeEnum.blockRules:
        List list = await isolateService.jsonDecodeAsync(config.config);
        List<LocalBlockRule> blockRules = list
            .map((e) => LocalBlockRule.fromJson(e))
            .toList();
        log.info('  Processing ${blockRules.length} block rules');

        for (LocalBlockRule blockRule in blockRules) {
          blockRule.id = null;
        }

        Map<String, List<LocalBlockRule>> groups = blockRules.groupListsBy((element) => element.groupId!);
        if (replace) {
          for (String groupId in (await localBlockRuleService.getBlockRules()).map((r) => r.groupId).whereType<String>().toSet()) {
            if (!groups.containsKey(groupId)) {
              await localBlockRuleService.removeLocalBlockRulesByGroupId(groupId);
            }
          }
        }
        int imported = 0;
        for (var group in groups.entries) {
          bool exists = !replace && await localBlockRuleService.existsGroup(group.key);
          if (!exists) {
            await localBlockRuleService.replaceBlockRulesByGroup(
              group.key,
              group.value,
            );
            imported += group.value.length;
          }
        }
        log.info(
          '  ✅ Imported $imported new block rules (${blockRules.length - imported} groups already exist)',
        );

        break;
      case CloudConfigTypeEnum.history:
        List list = await isolateService.jsonDecodeAsync(config.config);
        List<GalleryHistoryV2Data> histories = list
            .map((e) => GalleryHistoryV2Data.fromJson(e))
            .toList();
        int writtenHistories = await historyService.batchRecordIfNewer(
          histories,
        );
        log.info(
          '  ✅ Gallery history imported ($writtenHistories of ${histories.length} rows newer than local)',
        );
        break;
      case CloudConfigTypeEnum.syncSetting:
        await localConfigService.write(
          configKey: ConfigEnum.syncSetting,
          value: syncSetting.withDeviceFields(config.config),
        );
        await syncSetting.refreshBean();
        log.info('  ✅ Sync setting imported and refreshed');
        break;
      case CloudConfigTypeEnum.nhentaiFavorite:
        await localConfigService.write(
          configKey: ConfigEnum.nhentaiFavorite,
          value: config.config,
        );
        await nhentaiFavoriteService.refreshBean();
        log.info('  ✅ nhentai favorites imported and refreshed');
        break;
      case CloudConfigTypeEnum.wnacgFavorite:
        await localConfigService.write(
          configKey: ConfigEnum.wnacgFavorite,
          value: config.config,
        );
        await wnacgFavoriteService.refreshBean();
        log.info('  ✅ wnacg favorites imported and refreshed');
        break;
      case CloudConfigTypeEnum.jmFavorite:
        await localConfigService.write(
          configKey: ConfigEnum.jmFavorite,
          value: config.config,
        );
        await jmFavoriteService.refreshBean();
        log.info('  ✅ JM favorites imported and refreshed');
        break;
      case CloudConfigTypeEnum.komgaSetting:
        await localConfigService.batchWrite([
          LocalConfigCompanion(
            configKey: Value(ConfigEnum.komgaSetting.key),
            subConfigKey: const Value(LocalConfigService.defaultSubConfigKey),
            value: Value(config.config),
            utime: Value(SyncTimeUtil.format(config.ctime)),
          ),
        ]);
        await komgaSetting.refreshBean();
        log.info('  ✅ Komga setting imported and refreshed');
        break;
      case CloudConfigTypeEnum.nhentaiApiSetting:
        await localConfigService.batchWrite([
          LocalConfigCompanion(
            configKey: Value(ConfigEnum.nhentaiApiSetting.key),
            subConfigKey: const Value(LocalConfigService.defaultSubConfigKey),
            value: Value(config.config),
            utime: Value(SyncTimeUtil.format(config.ctime)),
          ),
        ]);
        await nhentaiApiSetting.refreshBean();
        log.info('  ✅ nhentai API setting imported and refreshed');
        break;
      case CloudConfigTypeEnum.eh2telegraphSetting:
        await localConfigService.batchWrite([
          LocalConfigCompanion(
            configKey: Value(ConfigEnum.eh2telegraphSetting.key),
            subConfigKey: const Value(LocalConfigService.defaultSubConfigKey),
            value: Value(config.config),
            utime: Value(SyncTimeUtil.format(config.ctime)),
          ),
        ]);
        await eh2telegraphSetting.refreshBean();
        log.info('  ✅ eh2telegraph setting imported and refreshed');
        break;
      case CloudConfigTypeEnum.jmAccount:
        await localConfigService.batchWrite([
          LocalConfigCompanion(
            configKey: Value(ConfigEnum.jmAccountSetting.key),
            subConfigKey: const Value(LocalConfigService.defaultSubConfigKey),
            value: Value(config.config),
            utime: Value(SyncTimeUtil.format(config.ctime)),
          ),
        ]);
        await jmAccountSetting.refreshBean();
        log.info('  ✅ JM account imported and refreshed');
        break;
      case CloudConfigTypeEnum.ehAccount:
        await ehAccountSync.apply(config.config, SyncTimeUtil.format(config.ctime));
        log.info('  ✅ E-Hentai account imported');
        break;
      case CloudConfigTypeEnum.tachiExtensionList:
        // The repositories; which extensions are installed is each device's own.
        List<String> repos = (((jsonDecode(config.config) as Map)['repos'] as List?) ?? []).whereType<String>().toList();
        String? stored = await localConfigService.read(configKey: ConfigEnum.tachiExtensionSetting);
        Map<String, dynamic> local = stored == null ? {} : Map<String, dynamic>.from(jsonDecode(stored) as Map);
        if (const ListEquality<dynamic>().equals(local['repos'] as List?, repos)) {
          log.info('  ✅ Tachiyomi repositories unchanged');
          break;
        }
        String reposTime = (jsonDecode(config.config) as Map)['reposUpdatedAt'] as String? ?? SyncTimeUtil.format(config.ctime);
        await localConfigService.batchWrite([
          LocalConfigCompanion(
            configKey: Value(ConfigEnum.tachiExtensionSetting.key),
            subConfigKey: const Value(LocalConfigService.defaultSubConfigKey),
            value: Value(jsonEncode({...local, 'repos': repos, 'updatedAt': SyncTimeUtil.format(config.ctime), 'reposUpdatedAt': reposTime})),
            utime: Value(SyncTimeUtil.format(config.ctime)),
          ),
        ]);
        await tachiExtensionService.refreshBean();
        log.info('  ✅ Tachiyomi repositories imported');
        break;
      case CloudConfigTypeEnum.tachiSourceSettings:
        await localConfigService.batchWrite([
          LocalConfigCompanion(
            configKey: Value(ConfigEnum.tachiSourceSetting.key),
            subConfigKey: const Value(LocalConfigService.defaultSubConfigKey),
            value: Value(config.config),
            utime: Value(SyncTimeUtil.format(config.ctime)),
          ),
        ]);
        await tachiSourceSettingService.refreshBean();
        unawaited(tachiSourceSettingService.applyToHost());
        log.info('  ✅ Tachiyomi source settings imported');
        break;
      case CloudConfigTypeEnum.tachiFavorite:
        await localConfigService.write(
          configKey: ConfigEnum.tachiFavorite,
          value: config.config,
        );
        await tachiFavoriteService.refreshBean();
        log.info('  ✅ Tachiyomi favorites imported and refreshed');
        break;
    }
  }

  Future<CloudConfig?> getLocalConfig(CloudConfigTypeEnum type) async {
    String configValue;
    DateTime? localConfigTime;
    switch (type) {
      case CloudConfigTypeEnum.readIndexRecord:
        List<LocalConfig> readIndexRecords = await localConfigService
            .readWithAllSubKeys(configKey: ConfigEnum.readIndexRecord);
        if (readIndexRecords.isEmpty) {
          log.debug('  No local ${type.name} data found');
          return null;
        }
        log.debug(
          '  Found ${readIndexRecords.length} local read index records',
        );
        configValue = await isolateService.jsonEncodeAsync(readIndexRecords);
        break;
      case CloudConfigTypeEnum.quickSearch:
        String? quickSearches = await localConfigService.read(
          configKey: ConfigEnum.quickSearch,
        );
        if (quickSearches == null) {
          return null;
        }
        configValue = quickSearches;
        break;
      case CloudConfigTypeEnum.searchHistory:
        String? searchHistories = await localConfigService.read(
          configKey: ConfigEnum.searchHistory,
        );
        if (searchHistories == null) {
          return null;
        }
        configValue = searchHistories;
        break;
      case CloudConfigTypeEnum.blockRules:
        List<LocalBlockRule> blockRules = await localBlockRuleService
            .getBlockRules();
        configValue = await isolateService.jsonEncodeAsync(blockRules);
        break;
      case CloudConfigTypeEnum.history:
        List<GalleryHistoryV2Data> histories = await historyService
            .getLatest10000RawHistory();
        configValue = await isolateService.jsonEncodeAsync(histories);
        break;
      case CloudConfigTypeEnum.syncSetting:
        String? syncConfig = await localConfigService.read(
          configKey: ConfigEnum.syncSetting,
        );
        if (syncConfig == null) {
          return null;
        }
        configValue = syncConfig;
        break;
      case CloudConfigTypeEnum.nhentaiFavorite:
        String? nhentaiFavoriteConfig = await localConfigService.read(
          configKey: ConfigEnum.nhentaiFavorite,
        );
        if (nhentaiFavoriteConfig == null) {
          return null;
        }
        configValue = nhentaiFavoriteConfig;
        break;
      case CloudConfigTypeEnum.wnacgFavorite:
        String? wnacgFavoriteConfig = await localConfigService.read(
          configKey: ConfigEnum.wnacgFavorite,
        );
        if (wnacgFavoriteConfig == null) {
          return null;
        }
        configValue = wnacgFavoriteConfig;
        break;
      case CloudConfigTypeEnum.jmFavorite:
        String? jmFavoriteConfig = await localConfigService.read(
          configKey: ConfigEnum.jmFavorite,
        );
        if (jmFavoriteConfig == null) {
          return null;
        }
        configValue = jmFavoriteConfig;
        break;
      case CloudConfigTypeEnum.tachiFavorite:
        String? tachiFavoriteConfig = await localConfigService.read(
          configKey: ConfigEnum.tachiFavorite,
        );
        if (tachiFavoriteConfig == null) {
          return null;
        }
        configValue = tachiFavoriteConfig;
        break;
      case CloudConfigTypeEnum.tachiExtensionList:
      case CloudConfigTypeEnum.tachiSourceSettings:
        List<LocalConfig> tachiRecords = await localConfigService.readWithAllSubKeys(
          configKey: type == CloudConfigTypeEnum.tachiExtensionList ? ConfigEnum.tachiExtensionSetting : ConfigEnum.tachiSourceSetting,
        );
        if (tachiRecords.isEmpty) {
          return null;
        }
        configValue = tachiRecords.first.value;
        localConfigTime = SyncTimeUtil.tryParse(tachiRecords.first.utime);
        break;
      case CloudConfigTypeEnum.komgaSetting:
        List<LocalConfig> records = await localConfigService.readWithAllSubKeys(
          configKey: ConfigEnum.komgaSetting,
        );
        if (records.isEmpty) {
          return null;
        }
        configValue = records.first.value;
        localConfigTime = SyncTimeUtil.tryParse(records.first.utime);
        break;
      case CloudConfigTypeEnum.nhentaiApiSetting:
        List<LocalConfig> records = await localConfigService.readWithAllSubKeys(
          configKey: ConfigEnum.nhentaiApiSetting,
        );
        if (records.isEmpty) {
          return null;
        }
        configValue = records.first.value;
        localConfigTime = SyncTimeUtil.tryParse(records.first.utime);
        break;
      case CloudConfigTypeEnum.jmAccount:
        List<LocalConfig> records = await localConfigService.readWithAllSubKeys(
          configKey: ConfigEnum.jmAccountSetting,
        );
        if (records.isEmpty) {
          return null;
        }
        configValue = records.first.value;
        localConfigTime = SyncTimeUtil.tryParse(records.first.utime);
        break;
      case CloudConfigTypeEnum.eh2telegraphSetting:
        List<LocalConfig> records = await localConfigService.readWithAllSubKeys(
          configKey: ConfigEnum.eh2telegraphSetting,
        );
        if (records.isEmpty) {
          return null;
        }
        configValue = records.first.value;
        localConfigTime = SyncTimeUtil.tryParse(records.first.utime);
        break;
      case CloudConfigTypeEnum.ehAccount:
        EhAccountValue? account = await ehAccountSync.export();
        if (account == null) {
          return null;
        }
        configValue = account.value;
        localConfigTime = SyncTimeUtil.parse(account.time);
        break;
    }

    return CloudConfig(
      id: localConfigId,
      shareCode: localConfigCode,
      identificationCode: localConfigCode,
      type: type,
      version: CloudConfigService.configTypeVersionMap[type]!,
      config: configValue,
      ctime: localConfigTime ?? DateTime.now(),
    );
  }
}
