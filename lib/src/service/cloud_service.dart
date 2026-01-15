import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/quick_search_service.dart';
import 'package:jhentai/src/service/search_history_service.dart';
import 'package:jhentai/src/setting/sync_setting.dart';

import '../database/database.dart';
import 'history_service.dart';
import 'jh_service.dart';
import 'local_block_rule_service.dart';
import 'log.dart';

CloudConfigService cloudConfigService = CloudConfigService();

class CloudConfigService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  static Map<CloudConfigTypeEnum, String> configTypeVersionMap = {
    CloudConfigTypeEnum.readIndexRecord: '1.0.0',
    CloudConfigTypeEnum.quickSearch: '1.0.0',
    CloudConfigTypeEnum.searchHistory: '1.0.0',
    CloudConfigTypeEnum.blockRules: '1.0.0',
    CloudConfigTypeEnum.history: '1.0.0',
    CloudConfigTypeEnum.syncSetting: '1.0.0',
  };

  static const int localConfigId = -1;
  static const String localConfigCode = 'local';
  static const String configFileName = 'JHenTaiConfig';

  @override
  Future<void> doInitBean() async {}

  @override
  Future<void> doAfterBeanReady() async {}

  Future<void> importConfig(CloudConfig config) async {
    log.info('📥 Importing config: ${config.type.name}');

    switch (config.type) {
      case CloudConfigTypeEnum.readIndexRecord:
        List list = await isolateService.jsonDecodeAsync(config.config);
        List<LocalConfig> readIndexRecords = list.map((e) => LocalConfig.fromJson(e)).toList();
        log.info('  Writing ${readIndexRecords.length} read index records to database');
        await localConfigService.batchWrite(readIndexRecords
            .map((e) => LocalConfigCompanion(
                  configKey: Value(e.configKey.key),
                  subConfigKey: Value(e.subConfigKey),
                  value: Value(e.value),
                  utime: Value(e.utime),
                ))
            .toList());
        log.info('  ✅ Read index records imported');
        break;
      case CloudConfigTypeEnum.quickSearch:
        await localConfigService.write(configKey: ConfigEnum.quickSearch, value: config.config);
        log.info('  Refreshing quick search service');
        await quickSearchService.refreshBean();
        log.info('  ✅ Quick search imported and refreshed');
        break;
      case CloudConfigTypeEnum.searchHistory:
        List historyList = await isolateService.jsonDecodeAsync(config.config);
        log.info('  Writing ${historyList.length} search history items');
        await localConfigService.write(configKey: ConfigEnum.searchHistory, value: config.config);
        await searchHistoryService.refreshBean();
        log.info('  ✅ Search history imported and refreshed');
        break;
      case CloudConfigTypeEnum.blockRules:
        List list = await isolateService.jsonDecodeAsync(config.config);
        List<LocalBlockRule> blockRules = list.map((e) => LocalBlockRule.fromJson(e)).toList();
        log.info('  Processing ${blockRules.length} block rules');

        for (LocalBlockRule blockRule in blockRules) {
          blockRule.id = null;
        }

        int imported = 0;
        for (var group in blockRules.groupListsBy((element) => element.groupId!).entries) {
          bool exists = await localBlockRuleService.existsGroup(group.key);
          if (!exists) {
            await localBlockRuleService.replaceBlockRulesByGroup(group.key, group.value);
            imported += group.value.length;
          }
        }
        log.info('  ✅ Imported $imported new block rules (${blockRules.length - imported} groups already exist)');

        break;
      case CloudConfigTypeEnum.history:
        List list = await isolateService.jsonDecodeAsync(config.config);
        List<GalleryHistoryV2Data> histories = list.map((e) => GalleryHistoryV2Data.fromJson(e)).toList();
        log.info('  Writing ${histories.length} gallery history records');
        await historyService.batchRecord(histories);
        log.info('  ✅ Gallery history imported');
        break;
      case CloudConfigTypeEnum.syncSetting:
        await localConfigService.write(configKey: ConfigEnum.syncSetting, value: config.config);
        await syncSetting.refreshBean();
        log.info('  ✅ Sync setting imported and refreshed');
        break;
    }
  }

  Future<CloudConfig?> getLocalConfig(CloudConfigTypeEnum type) async {
    String configValue;
    switch (type) {
      case CloudConfigTypeEnum.readIndexRecord:
        List<LocalConfig> readIndexRecords = await localConfigService.readWithAllSubKeys(configKey: ConfigEnum.readIndexRecord);
        if (readIndexRecords.isEmpty) {
          log.debug('  No local ${type.name} data found');
          return null;
        }
        log.debug('  Found ${readIndexRecords.length} local read index records');
        configValue = await isolateService.jsonEncodeAsync(readIndexRecords);
        break;
      case CloudConfigTypeEnum.quickSearch:
        String? quickSearches = await localConfigService.read(configKey: ConfigEnum.quickSearch);
        if (quickSearches == null) {
          return null;
        }
        configValue = quickSearches;
        break;
      case CloudConfigTypeEnum.searchHistory:
        String? searchHistories = await localConfigService.read(configKey: ConfigEnum.searchHistory);
        if (searchHistories == null) {
          return null;
        }
        configValue = searchHistories;
        break;
      case CloudConfigTypeEnum.blockRules:
        List<LocalBlockRule> blockRules = await localBlockRuleService.getBlockRules();
        configValue = await isolateService.jsonEncodeAsync(blockRules);
        break;
      case CloudConfigTypeEnum.history:
        List<GalleryHistoryV2Data> histories = await historyService.getLatest10000RawHistory();
        configValue = await isolateService.jsonEncodeAsync(histories);
        break;
      case CloudConfigTypeEnum.syncSetting:
        String? syncConfig = await localConfigService.read(configKey: ConfigEnum.syncSetting);
        if (syncConfig == null) {
          return null;
        }
        configValue = syncConfig;
        break;
    }

    return CloudConfig(
      id: localConfigId,
      shareCode: localConfigCode,
      identificationCode: localConfigCode,
      type: type,
      version: CloudConfigService.configTypeVersionMap[type]!,
      config: configValue,
      ctime: DateTime.now(),
    );
  }
}
