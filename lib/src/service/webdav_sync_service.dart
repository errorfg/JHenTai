import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/service/cloud_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/setting/webdav_setting.dart';
import 'package:path/path.dart' as path;
import 'package:webdav_client/webdav_client.dart' as webdav;

import '../service/jh_service.dart';
import '../service/path_service.dart';
import 'log.dart';

WebDavSyncService webDavSyncService = WebDavSyncService();

enum SyncDirection { upload, download, bidirectional, none }

class WebDavSyncService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  webdav.Client? _client;

  @override
  List<JHLifeCircleBean> get initDependencies => [pathService, log, webDavSetting];

  @override
  Future<void> doInitBean() async {}

  @override
  Future<void> doAfterBeanReady() async {
    // Auto sync on app startup if enabled
    if (webDavSetting.enableWebDav.value && webDavSetting.autoSync.value) {
      _performAutoSyncOnStartup();
    }
  }

  /// Perform auto sync on app startup (non-blocking, background)
  void _performAutoSyncOnStartup() async {
    try {
      log.info('Auto sync on startup: checking...');

      // Sync all config types by default
      List<CloudConfigTypeEnum> allTypes = CloudConfigTypeEnum.values;

      SyncResult result = await manualSync(allTypes);

      if (result.success) {
        log.info('Auto sync completed: ${result.direction.name}');
      } else {
        log.warning('Auto sync failed: ${result.message}');
      }
    } catch (e) {
      log.error('Auto sync on startup failed', e);
      // Don't throw, just log the error to avoid affecting app startup
    }
  }

  /// Initialize WebDAV client with current settings
  webdav.Client _initClient() {
    if (webDavSetting.serverUrl.value.isEmpty || webDavSetting.username.value.isEmpty) {
      throw Exception('WebDAV server URL and username are required');
    }

    return webdav.newClient(
      webDavSetting.serverUrl.value,
      user: webDavSetting.username.value,
      password: webDavSetting.password.value,
      debug: false,
    );
  }

  /// Test WebDAV connection
  Future<bool> testConnection() async {
    try {
      _client = _initClient();
      await _client!.ping();
      log.info('WebDAV connection test successful');
      return true;
    } catch (e) {
      log.error('WebDAV connection test failed', e);
      return false;
    }
  }

  /// Get remote file path
  String _getRemoteFilePath() {
    String remotePath = webDavSetting.remotePath.value;
    if (!remotePath.endsWith('/')) {
      remotePath += '/';
    }
    String fileName = '${CloudConfigService.configFileName}.json';
    return '$remotePath$fileName';
  }

  /// Get local temporary file path
  Future<String> _getLocalTempFilePath() async {
    String tempDir = pathService.tempDir.path;
    String fileName = '${CloudConfigService.configFileName}-temp.json';
    return path.join(tempDir, fileName);
  }

  /// Upload configuration to WebDAV server
  Future<void> uploadConfig(List<CloudConfig> configs) async {
    try {
      _client = _initClient();

      // Ensure remote directory exists
      String remotePath = webDavSetting.remotePath.value;
      if (!remotePath.endsWith('/')) {
        remotePath += '/';
      }

      try {
        await _client!.mkdir(remotePath);
      } catch (e) {
        // Directory might already exist, ignore error
        log.debug('Remote directory might already exist: $e');
      }

      // Encode config to JSON
      String jsonString = await isolateService.jsonEncodeAsync(configs);

      // Upload file
      String remoteFile = _getRemoteFilePath();
      await _client!.write(remoteFile, Uint8List.fromList(utf8.encode(jsonString)));

      log.info('Successfully uploaded config to WebDAV: $remoteFile');
    } catch (e) {
      log.error('Failed to upload config to WebDAV', e);
      rethrow;
    }
  }

  /// Download configuration from WebDAV server
  Future<List<CloudConfig>> downloadConfig() async {
    try {
      _client = _initClient();

      String remoteFile = _getRemoteFilePath();

      // Download file
      var bytes = await _client!.read(remoteFile);
      String jsonString = utf8.decode(bytes);

      // Parse JSON
      List list = await isolateService.jsonDecodeAsync(jsonString);
      List<CloudConfig> configs = list.map((e) => CloudConfig.fromJson(e)).toList();

      log.info('Successfully downloaded config from WebDAV: $remoteFile');
      return configs;
    } catch (e) {
      log.error('Failed to download config from WebDAV', e);
      rethrow;
    }
  }

  /// Get remote file modification time
  Future<DateTime?> getRemoteFileTime() async {
    try {
      _client = _initClient();

      String remoteFile = _getRemoteFilePath();

      // Check if file exists and get info
      List<webdav.File> files = await _client!.readDir(webDavSetting.remotePath.value);
      webdav.File? targetFile = files.firstWhere(
        (f) => f.path == remoteFile,
        orElse: () => throw Exception('Remote file not found'),
      );

      return targetFile.mTime;
    } catch (e) {
      log.error('Failed to get remote file time', e);
      return null;
    }
  }

  /// Get local config modification time
  Future<DateTime?> getLocalConfigTime() async {
    try {
      // We'll use a metadata file to track when the config was last exported
      String metadataPath = await _getLocalMetadataPath();
      File metadataFile = File(metadataPath);

      if (!metadataFile.existsSync()) {
        return null;
      }

      String content = await metadataFile.readAsString();
      Map<String, dynamic> metadata = jsonDecode(content);
      return DateTime.parse(metadata['lastExportTime']);
    } catch (e) {
      log.error('Failed to get local config time', e);
      return null;
    }
  }

  /// Update local config metadata
  Future<void> _updateLocalMetadata() async {
    try {
      String metadataPath = await _getLocalMetadataPath();
      File metadataFile = File(metadataPath);

      Map<String, dynamic> metadata = {
        'lastExportTime': DateTime.now().toIso8601String(),
      };

      await metadataFile.writeAsString(jsonEncode(metadata));
    } catch (e) {
      log.error('Failed to update local metadata', e);
    }
  }

  /// Get local metadata file path
  Future<String> _getLocalMetadataPath() async {
    String tempDir = pathService.tempDir.path;
    String fileName = '${CloudConfigService.configFileName}-metadata.json';
    return path.join(tempDir, fileName);
  }

  /// Determine sync direction based on timestamps
  Future<SyncDirection> determineSyncDirection() async {
    DateTime? localTime = await getLocalConfigTime();
    DateTime? remoteTime = await getRemoteFileTime();

    log.info('Local config time: $localTime, Remote config time: $remoteTime');

    if (remoteTime == null) {
      // No remote file, upload
      return SyncDirection.upload;
    }

    if (localTime == null) {
      // No local metadata, download
      return SyncDirection.download;
    }

    // Compare timestamps
    if (remoteTime.isAfter(localTime)) {
      return SyncDirection.download;
    } else if (localTime.isAfter(remoteTime)) {
      return SyncDirection.upload;
    } else {
      return SyncDirection.none;
    }
  }

  /// Perform manual sync based on timestamp comparison
  Future<SyncResult> manualSync(List<CloudConfigTypeEnum> selectedTypes) async {
    try {
      if (!webDavSetting.enableWebDav.value) {
        throw Exception('WebDAV is not enabled');
      }

      // Test connection first
      bool connected = await testConnection();
      if (!connected) {
        throw Exception('WebDAV connection failed');
      }

      // Use incremental sync instead of simple upload/download
      return await incrementalSync(selectedTypes);
    } catch (e) {
      log.error('Manual sync failed', e);
      return SyncResult(false, e.toString(), SyncDirection.none);
    }
  }

  /// Incremental sync with merge logic
  Future<SyncResult> incrementalSync(List<CloudConfigTypeEnum> selectedTypes) async {
    try {
      log.info('Starting incremental sync');

      // Get remote file time
      DateTime? remoteFileTime = await getRemoteFileTime();

      // Download remote configs if exists
      List<CloudConfig> remoteConfigs = [];
      if (remoteFileTime != null) {
        try {
          remoteConfigs = await downloadConfig();
        } catch (e) {
          log.warning('Failed to download remote config, will upload local', e);
        }
      }

      // Merge configs for each type
      List<CloudConfig> mergedConfigs = [];
      Map<CloudConfigTypeEnum, MergeStatistics> statistics = {};

      for (var type in selectedTypes) {
        try {
          // Get local config
          CloudConfig? localConfig = await cloudConfigService.getLocalConfig(type);

          // Get remote config
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
            // Only local exists, use it
            log.info('Only local config exists for $type, will upload');
            merged = localConfig;
            stats = MergeStatistics(1, 0, 1, 0, 0);
          } else {
            // Both exist, merge them
            log.info('Merging configs for $type');
            var result = await _mergeConfig(type, localConfig, remoteConfig, remoteFileTime!);
            merged = result.config;
            stats = result.statistics;

            // Import merged config to local
            await cloudConfigService.importConfig(merged);
          }

          mergedConfigs.add(merged);
          statistics[type] = stats;
        } catch (e) {
          log.error('Failed to merge config type: $type', e);
        }
      }

      if (mergedConfigs.isEmpty) {
        return SyncResult(true, 'No config to sync', SyncDirection.none, statistics);
      }

      // Upload merged configs
      await uploadConfig(mergedConfigs);
      await _updateLocalMetadata();

      log.info('Incremental sync completed');
      return SyncResult(true, 'Sync completed successfully', SyncDirection.bidirectional, statistics);
    } catch (e) {
      log.error('Incremental sync failed', e);
      return SyncResult(false, e.toString(), SyncDirection.none, {});
    }
  }

  /// Merge config based on type
  Future<MergeResult> _mergeConfig(
    CloudConfigTypeEnum type,
    CloudConfig local,
    CloudConfig remote,
    DateTime remoteFileTime,
  ) async {
    switch (type) {
      case CloudConfigTypeEnum.readIndexRecord:
        return await _mergeReadIndexRecord(local, remote);
      case CloudConfigTypeEnum.quickSearch:
        return await _mergeQuickSearch(local, remote, remoteFileTime);
      case CloudConfigTypeEnum.blockRules:
        return await _mergeBlockRules(local, remote, remoteFileTime);
      case CloudConfigTypeEnum.searchHistory:
        return await _mergeSearchHistory(local, remote, remoteFileTime);
      case CloudConfigTypeEnum.history:
        return await _mergeHistory(local, remote);
    }
  }

  /// Merge readIndexRecord (with item timestamp)
  Future<MergeResult> _mergeReadIndexRecord(CloudConfig local, CloudConfig remote) async {
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

    return MergeResult(mergedConfig, stats);
  }

  /// Merge quickSearch (with file timestamp)
  Future<MergeResult> _mergeQuickSearch(CloudConfig local, CloudConfig remote, DateTime remoteFileTime) async {
    Map localMap = jsonDecode(local.config);
    Map remoteMap = jsonDecode(remote.config);

    Map<String, dynamic> merged = {};
    bool remoteIsNewer = remoteFileTime.isAfter(local.ctime);
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

    CloudConfig mergedConfig = CloudConfig(
      id: CloudConfigService.localConfigId,
      shareCode: CloudConfigService.localConfigCode,
      identificationCode: CloudConfigService.localConfigCode,
      type: CloudConfigTypeEnum.quickSearch,
      version: CloudConfigService.configTypeVersionMap[CloudConfigTypeEnum.quickSearch]!,
      config: jsonEncode(merged),
      ctime: DateTime.now(),
    );

    MergeStatistics stats = MergeStatistics(
      localMap.length,
      remoteMap.length,
      merged.length,
      merged.length - localMap.length,
      conflicts,
    );

    return MergeResult(mergedConfig, stats);
  }

  /// Merge blockRules (with file timestamp)
  Future<MergeResult> _mergeBlockRules(CloudConfig local, CloudConfig remote, DateTime remoteFileTime) async {
    List localList = await isolateService.jsonDecodeAsync(local.config);
    List remoteList = await isolateService.jsonDecodeAsync(remote.config);

    Map<String, dynamic> merged = {};
    bool remoteIsNewer = remoteFileTime.isAfter(local.ctime);
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

    return MergeResult(mergedConfig, stats);
  }

  /// Merge searchHistory (with file timestamp)
  Future<MergeResult> _mergeSearchHistory(CloudConfig local, CloudConfig remote, DateTime remoteFileTime) async {
    List localList = await isolateService.jsonDecodeAsync(local.config);
    List remoteList = await isolateService.jsonDecodeAsync(remote.config);

    Map<String, dynamic> merged = {};
    bool remoteIsNewer = remoteFileTime.isAfter(local.ctime);
    int conflicts = 0;

    // Add all local items
    for (var item in localList) {
      merged[item['rawKeyword']] = item;
    }

    // Merge remote items
    for (var item in remoteList) {
      String key = item['rawKeyword'];
      if (!merged.containsKey(key)) {
        // Remote only
        merged[key] = item;
      } else {
        // Conflict: use file timestamp
        if (remoteIsNewer) {
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
      type: CloudConfigTypeEnum.searchHistory,
      version: CloudConfigService.configTypeVersionMap[CloudConfigTypeEnum.searchHistory]!,
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

    return MergeResult(mergedConfig, stats);
  }

  /// Merge history (with item timestamp)
  Future<MergeResult> _mergeHistory(CloudConfig local, CloudConfig remote) async {
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

    return MergeResult(mergedConfig, stats);
  }

  /// Export local config to file (for manual backup)
  Future<String> exportToFile(List<CloudConfigTypeEnum> selectedTypes) async {
    try {
      List<CloudConfig> exportConfigs = [];
      for (CloudConfigTypeEnum type in selectedTypes) {
        CloudConfig? config = await cloudConfigService.getLocalConfig(type);
        if (config != null) {
          exportConfigs.add(config);
        }
      }

      String fileName = '${CloudConfigService.configFileName}-${DateFormat('yyyyMMddHHmmss').format(DateTime.now())}.json';
      String filePath = path.join(pathService.tempDir.path, fileName);

      File file = File(filePath);
      await file.writeAsString(await isolateService.jsonEncodeAsync(exportConfigs));

      log.info('Exported config to: $filePath');
      return filePath;
    } catch (e) {
      log.error('Failed to export config to file', e);
      rethrow;
    }
  }
}

class SyncResult {
  final bool success;
  final String message;
  final SyncDirection direction;
  final Map<CloudConfigTypeEnum, MergeStatistics> statistics;

  SyncResult(this.success, this.message, this.direction, [this.statistics = const {}]);
}

class MergeStatistics {
  final int localCount;      // Local item count
  final int remoteCount;     // Remote item count
  final int mergedCount;     // Merged item count
  final int addedFromRemote; // Items added from remote
  final int conflicts;       // Conflict count (resolved by timestamp)

  MergeStatistics(
    this.localCount,
    this.remoteCount,
    this.mergedCount,
    this.addedFromRemote,
    this.conflicts,
  );
}

class MergeResult {
  final CloudConfig config;
  final MergeStatistics statistics;

  MergeResult(this.config, this.statistics);
}
