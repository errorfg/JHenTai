import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/service/cloud_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';

import 'jh_service.dart';
import 'log.dart';

SyncMerger syncMerger = SyncMerger();

/// 同步合并服务（独立于传输层）
/// 负责处理本地和远程配置的增量合并逻辑
class SyncMerger with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  @override
  List<JHLifeCircleBean> get initDependencies => [log];

  @override
  Future<void> doInitBean() async {}

  @override
  Future<void> doAfterBeanReady() async {}

  /// 执行增量合并
  /// [localConfigs]: 本地配置列表
  /// [remoteConfigs]: 远程配置列表
  /// [remoteFileTime]: 远程文件修改时间
  /// 返回合并后的配置和统计信息
  Future<MergeResult> merge(
    List<CloudConfig> localConfigs,
    List<CloudConfig> remoteConfigs,
    DateTime remoteFileTime,
    List<CloudConfigTypeEnum> selectedTypes,
  ) async {
    List<CloudConfig> mergedConfigs = [];
    Map<CloudConfigTypeEnum, MergeStatistics> statistics = {};

    // Extract latest local timestamp from configs with item timestamps
    DateTime? latestLocalTime = await _getLatestLocalTimestamp(localConfigs);

    for (var type in selectedTypes) {
      try {
        // Get local config for this type
        CloudConfig? localConfig = localConfigs.where((c) => c.type == type).firstOrNull;

        // Get remote config for this type
        CloudConfig? remoteConfig = remoteConfigs.where((c) => c.type == type).firstOrNull;

        CloudConfig? merged;
        MergeStatistics stats;

        if (localConfig == null && remoteConfig == null) {
          log.debug('No config for type: $type');
          continue;
        }

        if (localConfig == null) {
          // Only remote exists, import it
          log.info('Only remote config exists for $type, importing');
          await cloudConfigService.importConfig(remoteConfig!);
          merged = remoteConfig;
          stats = MergeStatistics(0, 1, 1, 1, 0);
        } else if (remoteConfig == null) {
          // Only local exists, use it (no need to import)
          log.info('Only local config exists for $type, will upload');
          merged = localConfig;
          stats = MergeStatistics(1, 0, 1, 0, 0);
        } else {
          // Both exist, merge them
          log.info('Merging configs for $type');
          var result = await mergeConfigType(type, localConfig, remoteConfig, remoteFileTime, latestLocalTime);
          merged = result.config;
          stats = result.statistics;

          // Import merged config to local
          await cloudConfigService.importConfig(merged);
        }

        if (merged != null) {
          mergedConfigs.add(merged);
          statistics[type] = stats;
        }
      } catch (e) {
        log.error('Failed to merge config type: $type', e);
      }
    }

    return MergeResult(mergedConfigs, statistics);
  }

  /// 从本地配置中提取最新的时间戳
  /// 优先使用 readIndexRecord 或 history 的 item timestamp
  Future<DateTime?> _getLatestLocalTimestamp(List<CloudConfig> localConfigs) async {
    DateTime? latestTime;

    // Check readIndexRecord
    CloudConfig? readIndexRecord = localConfigs.where((c) => c.type == CloudConfigTypeEnum.readIndexRecord).firstOrNull;
    if (readIndexRecord != null) {
      try {
        List list = await isolateService.jsonDecodeAsync(readIndexRecord.config);
        for (var item in list) {
          if (item['utime'] != null) {
            DateTime time = DateTime.parse(item['utime']);
            if (latestTime == null || time.isAfter(latestTime)) {
              latestTime = time;
            }
          }
        }
      } catch (e) {
        log.warning('Failed to parse readIndexRecord timestamps', e);
      }
    }

    // Check history
    CloudConfig? history = localConfigs.where((c) => c.type == CloudConfigTypeEnum.history).firstOrNull;
    if (history != null) {
      try {
        List list = await isolateService.jsonDecodeAsync(history.config);
        for (var item in list) {
          if (item['lastReadTime'] != null) {
            DateTime time = DateTime.parse(item['lastReadTime']);
            if (latestTime == null || time.isAfter(latestTime)) {
              latestTime = time;
            }
          }
        }
      } catch (e) {
        log.warning('Failed to parse history timestamps', e);
      }
    }

    if (latestTime != null) {
      log.info('📅 Latest local timestamp: $latestTime');
    }

    return latestTime;
  }

  /// 合并单个配置类型
  Future<MergeConfigResult> mergeConfigType(
    CloudConfigTypeEnum type,
    CloudConfig local,
    CloudConfig remote,
    DateTime remoteFileTime,
    DateTime? latestLocalTime,
  ) async {
    switch (type) {
      case CloudConfigTypeEnum.readIndexRecord:
        return await _mergeReadIndexRecord(local, remote);
      case CloudConfigTypeEnum.quickSearch:
        return await _mergeQuickSearch(local, remote, remoteFileTime, latestLocalTime);
      case CloudConfigTypeEnum.blockRules:
        return await _mergeBlockRules(local, remote, remoteFileTime, latestLocalTime);
      case CloudConfigTypeEnum.searchHistory:
        return await _mergeSearchHistory(local, remote, remoteFileTime, latestLocalTime);
      case CloudConfigTypeEnum.history:
        return await _mergeHistory(local, remote);
    }
  }

  /// Merge readIndexRecord (with item timestamp)
  Future<MergeConfigResult> _mergeReadIndexRecord(CloudConfig local, CloudConfig remote) async {
    List localList = await isolateService.jsonDecodeAsync(local.config);
    List remoteList = await isolateService.jsonDecodeAsync(remote.config);

    Map<String, dynamic> localMap = {};
    Map<String, dynamic> remoteMap = {};

    // Build maps with subConfigKey as key
    for (var item in localList) {
      localMap[item['subConfigKey']] = item;
    }
    for (var item in remoteList) {
      remoteMap[item['subConfigKey']] = item;
    }

    // Debug: Print recent 10 records
    log.info('📚 ReadIndexRecord Merge Details:');
    log.info('  Local total: ${localMap.length}, Remote total: ${remoteMap.length}');

    var localRecent = localList.take(10).toList();
    log.info('  Local recent 10 records:');
    for (var item in localRecent) {
      log.info('    gid=${item['subConfigKey']}, page=${item['value']}, utime=${item['utime']}');
    }

    var remoteRecent = remoteList.take(10).toList();
    log.info('  Remote recent 10 records:');
    for (var item in remoteRecent) {
      log.info('    gid=${item['subConfigKey']}, page=${item['value']}, utime=${item['utime']}');
    }

    Map<String, dynamic> merged = {};
    int conflicts = 0;

    // Add all local items
    merged.addAll(localMap);

    // Merge remote items
    for (var entry in remoteMap.entries) {
      if (!merged.containsKey(entry.key)) {
        // Remote only
        merged[entry.key] = entry.value;
      } else {
        // Conflict: compare timestamps
        DateTime localTime = DateTime.parse(merged[entry.key]['utime']);
        DateTime remoteTime = DateTime.parse(entry.value['utime']);
        if (remoteTime.isAfter(localTime)) {
          merged[entry.key] = entry.value;
          conflicts++;
        }
      }
    }

    String mergedJson = await isolateService.jsonEncodeAsync(merged.values.toList());

    // Debug: Print merged result
    List mergedList = await isolateService.jsonDecodeAsync(mergedJson);
    var mergedRecent = mergedList.take(10).toList();
    log.info('  Merged recent 10 records:');
    for (var item in mergedRecent) {
      log.info('    gid=${item['subConfigKey']}, page=${item['value']}, utime=${item['utime']}');
    }

    CloudConfig mergedConfig = CloudConfig(
      id: CloudConfigService.localConfigId,
      shareCode: CloudConfigService.localConfigCode,
      identificationCode: CloudConfigService.localConfigCode,
      type: CloudConfigTypeEnum.readIndexRecord,
      version: CloudConfigService.configTypeVersionMap[CloudConfigTypeEnum.readIndexRecord]!,
      config: mergedJson,
      ctime: DateTime.now(),
    );

    MergeStatistics stats = MergeStatistics(
      localMap.length,
      remoteMap.length,
      merged.length,
      merged.length - localMap.length,
      conflicts,
    );

    return MergeConfigResult(mergedConfig, stats);
  }

  /// Merge quickSearch (with file timestamp)
  Future<MergeConfigResult> _mergeQuickSearch(CloudConfig local, CloudConfig remote, DateTime remoteFileTime, DateTime? latestLocalTime) async {
    Map localMap = await isolateService.jsonDecodeAsync(local.config);
    Map remoteMap = await isolateService.jsonDecodeAsync(remote.config);

    Map<String, dynamic> merged = {};
    // Use latestLocalTime if available, otherwise fallback to comparing data size
    bool remoteIsNewer = latestLocalTime != null
        ? remoteFileTime.isAfter(latestLocalTime)
        : remoteMap.length > localMap.length;
    int conflicts = 0;

    // Add all local items
    merged.addAll(Map<String, dynamic>.from(localMap));

    // Merge remote items
    for (var entry in remoteMap.entries) {
      if (!merged.containsKey(entry.key)) {
        // Remote only
        merged[entry.key] = entry.value;
      } else {
        // Conflict: use file timestamp
        if (remoteIsNewer) {
          merged[entry.key] = entry.value;
          conflicts++;
        }
      }
    }

    String mergedJson = await isolateService.jsonEncodeAsync(merged);

    CloudConfig mergedConfig = CloudConfig(
      id: CloudConfigService.localConfigId,
      shareCode: CloudConfigService.localConfigCode,
      identificationCode: CloudConfigService.localConfigCode,
      type: CloudConfigTypeEnum.quickSearch,
      version: CloudConfigService.configTypeVersionMap[CloudConfigTypeEnum.quickSearch]!,
      config: mergedJson,
      ctime: DateTime.now(),
    );

    MergeStatistics stats = MergeStatistics(
      localMap.length,
      remoteMap.length,
      merged.length,
      merged.length - localMap.length,
      conflicts,
    );

    return MergeConfigResult(mergedConfig, stats);
  }

  /// Merge blockRules (with file timestamp)
  Future<MergeConfigResult> _mergeBlockRules(CloudConfig local, CloudConfig remote, DateTime remoteFileTime, DateTime? latestLocalTime) async {
    List localList = await isolateService.jsonDecodeAsync(local.config);
    List remoteList = await isolateService.jsonDecodeAsync(remote.config);

    Map<String, dynamic> merged = {};
    // Use latestLocalTime if available, otherwise fallback to comparing data size
    bool remoteIsNewer = latestLocalTime != null
        ? remoteFileTime.isAfter(latestLocalTime)
        : remoteList.length > localList.length;
    int conflicts = 0;

    // Helper to generate unique ID for block rule
    String getUniqueId(dynamic rule) {
      return '${rule['groupId']}_${rule['target']}_${rule['attribute']}_${rule['pattern']}_${rule['expression']}';
    }

    // Add all local rules
    for (var rule in localList) {
      merged[getUniqueId(rule)] = rule;
    }

    // Merge remote rules
    for (var rule in remoteList) {
      String id = getUniqueId(rule);
      if (!merged.containsKey(id)) {
        // Remote only
        merged[id] = rule;
      } else {
        // Conflict: use file timestamp
        if (remoteIsNewer) {
          merged[id] = rule;
          conflicts++;
        }
      }
    }

    String mergedJson = await isolateService.jsonEncodeAsync(merged.values.toList());

    CloudConfig mergedConfig = CloudConfig(
      id: CloudConfigService.localConfigId,
      shareCode: CloudConfigService.localConfigCode,
      identificationCode: CloudConfigService.localConfigCode,
      type: CloudConfigTypeEnum.blockRules,
      version: CloudConfigService.configTypeVersionMap[CloudConfigTypeEnum.blockRules]!,
      config: mergedJson,
      ctime: DateTime.now(),
    );

    MergeStatistics stats = MergeStatistics(
      localList.length,
      remoteList.length,
      merged.length,
      merged.length - localList.length,
      conflicts,
    );

    return MergeConfigResult(mergedConfig, stats);
  }

  /// Merge searchHistory (with file timestamp)
  /// Strategy: Newer overwrites older based on file timestamp
  Future<MergeConfigResult> _mergeSearchHistory(CloudConfig local, CloudConfig remote, DateTime remoteFileTime, DateTime? latestLocalTime) async {
    List localList = await isolateService.jsonDecodeAsync(local.config);
    List remoteList = await isolateService.jsonDecodeAsync(remote.config);

    log.info('🔍 SearchHistory Merge Debug:');
    log.info('  Local list length: ${localList.length}');
    log.info('  Remote list length: ${remoteList.length}');
    log.info('  Latest local timestamp: $latestLocalTime');
    log.info('  Remote file time: $remoteFileTime');

    // Use latestLocalTime if available, otherwise fallback to comparing data size
    bool remoteIsNewer = latestLocalTime != null
        ? remoteFileTime.isAfter(latestLocalTime)
        : remoteList.length > localList.length;

    // Use newer list to overwrite older list
    List finalList = remoteIsNewer ? remoteList : localList;
    int addedFromRemote = remoteIsNewer ? remoteList.length : 0;
    int conflicts = remoteIsNewer ? localList.length : 0;

    log.info('  Using ${remoteIsNewer ? "remote" : "local"} list (newer)');

    String mergedJson = await isolateService.jsonEncodeAsync(finalList);

    CloudConfig mergedConfig = CloudConfig(
      id: CloudConfigService.localConfigId,
      shareCode: CloudConfigService.localConfigCode,
      identificationCode: CloudConfigService.localConfigCode,
      type: CloudConfigTypeEnum.searchHistory,
      version: CloudConfigService.configTypeVersionMap[CloudConfigTypeEnum.searchHistory]!,
      config: mergedJson,
      ctime: DateTime.now(),
    );

    MergeStatistics stats = MergeStatistics(
      localList.length,
      remoteList.length,
      finalList.length,
      addedFromRemote,
      conflicts,
    );

    return MergeConfigResult(mergedConfig, stats);
  }

  /// Merge history (with item timestamp)
  Future<MergeConfigResult> _mergeHistory(CloudConfig local, CloudConfig remote) async {
    List localList = await isolateService.jsonDecodeAsync(local.config);
    List remoteList = await isolateService.jsonDecodeAsync(remote.config);

    Map<String, dynamic> merged = {};
    int conflicts = 0;

    // Add all local items
    for (var item in localList) {
      merged[item['gid'].toString()] = item;
    }

    // Merge remote items
    for (var item in remoteList) {
      String key = item['gid'].toString();
      if (!merged.containsKey(key)) {
        // Remote only
        merged[key] = item;
      } else {
        // Conflict: compare timestamps
        DateTime localTime = DateTime.parse(merged[key]['lastReadTime']);
        DateTime remoteTime = DateTime.parse(item['lastReadTime']);
        if (remoteTime.isAfter(localTime)) {
          merged[key] = item;
          conflicts++;
        }
      }
    }

    String mergedJson = await isolateService.jsonEncodeAsync(merged.values.toList());

    CloudConfig mergedConfig = CloudConfig(
      id: CloudConfigService.localConfigId,
      shareCode: CloudConfigService.localConfigCode,
      identificationCode: CloudConfigService.localConfigCode,
      type: CloudConfigTypeEnum.history,
      version: CloudConfigService.configTypeVersionMap[CloudConfigTypeEnum.history]!,
      config: mergedJson,
      ctime: DateTime.now(),
    );

    MergeStatistics stats = MergeStatistics(
      localList.length,
      remoteList.length,
      merged.length,
      merged.length - localList.length,
      conflicts,
    );

    return MergeConfigResult(mergedConfig, stats);
  }
}

/// 合并结果（包含多个配置类型）
class MergeResult {
  final List<CloudConfig> merged;
  final Map<CloudConfigTypeEnum, MergeStatistics> statistics;

  MergeResult(this.merged, this.statistics);
}

/// 单个配置类型的合并结果
class MergeConfigResult {
  final CloudConfig config;
  final MergeStatistics statistics;

  MergeConfigResult(this.config, this.statistics);
}

/// 合并统计信息
class MergeStatistics {
  final int localCount; // Local item count
  final int remoteCount; // Remote item count
  final int mergedCount; // Merged item count
  final int addedFromRemote; // Items added from remote
  final int conflicts; // Conflict count (resolved by timestamp)

  MergeStatistics(
    this.localCount,
    this.remoteCount,
    this.mergedCount,
    this.addedFromRemote,
    this.conflicts,
  );
}
