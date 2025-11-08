import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
import 'package:jhentai/src/service/cloud/s3_provider.dart';
import 'package:jhentai/src/service/cloud/webdav_provider.dart';
import 'package:jhentai/src/service/cloud_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/sync_merger.dart';
import 'package:jhentai/src/setting/sync_setting.dart';

import 'jh_service.dart';
import 'log.dart';

SyncService syncService = SyncService();

/// 统一同步服务（协调层）
/// 负责协调 CloudProvider 和 SyncMerger，提供统一的同步接口
class SyncService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  final Map<String, CloudProvider> _providers = {};

  @override
  List<JHLifeCircleBean> get initDependencies => [log, syncSetting, syncMerger, cloudConfigService, isolateService];

  @override
  Future<void> doInitBean() async {
    // Initialize all providers
    _initProviders();
  }

  @override
  Future<void> doAfterBeanReady() async {
    // Auto sync on app startup if enabled
    if (syncSetting.autoSync.value) {
      _performAutoSyncOnStartup();
    }
  }

  /// Initialize all cloud providers
  void _initProviders() {
    // Note: We don't initialize providers here anymore
    // Providers are created dynamically when needed to avoid startup errors with empty config
    log.info('Provider initialization skipped (using dynamic creation)');
  }

  /// Reinitialize providers (call after settings change)
  void reinitProviders() {
    _providers.clear();
    _initProviders();
  }

  /// Get current active provider
  CloudProvider? _getCurrentProvider() {
    String providerName = syncSetting.currentProvider.value;
    return _providers[providerName];
  }

  /// Perform auto sync on app startup (non-blocking, background)
  void _performAutoSyncOnStartup() async {
    try {
      log.info('========================================');
      log.info('Auto sync on startup: checking...');
      log.info('Auto sync enabled: ${syncSetting.autoSync.value}');
      log.info('Current provider: ${syncSetting.currentProvider.value}');
      log.info('S3 enabled: ${syncSetting.enableS3.value}');
      log.info('WebDAV enabled: ${syncSetting.enableWebDav.value}');
      log.info('========================================');

      // Sync all config types by default
      List<CloudConfigTypeEnum> allTypes = CloudConfigTypeEnum.values;

      // sync() will handle provider creation dynamically
      SyncResult result = await sync(types: allTypes);

      if (result.success) {
        log.info('✅ Auto sync completed successfully');
        log.info('Statistics: ${result.statistics}');
      } else {
        log.warning('❌ Auto sync failed: ${result.message}');
      }
    } catch (e) {
      log.error('💥 Auto sync on startup failed', e);
      // Don't throw, just log the error to avoid affecting app startup
    }
  }

  /// Execute sync
  /// [types]: List of config types to sync
  /// [providerName]: Optional provider name, defaults to current provider
  Future<SyncResult> sync({
    required List<CloudConfigTypeEnum> types,
    String? providerName,
  }) async {
    try {
      // Create provider dynamically with latest settings
      String provider = providerName ?? syncSetting.currentProvider.value;
      CloudProvider cloudProvider;

      if (provider == 's3') {
        cloudProvider = S3Provider(
          endpoint: syncSetting.s3Endpoint.value,
          accessKey: syncSetting.s3AccessKey.value,
          secretKey: syncSetting.s3SecretKey.value,
          bucketName: syncSetting.s3BucketName.value,
          region: syncSetting.s3Region.value,
          baseKey: syncSetting.s3BaseKey.value,
          enabled: syncSetting.enableS3.value,
          useSSL: syncSetting.s3UseSSL.value,
        );
      } else if (provider == 'webdav') {
        cloudProvider = WebDavProvider(
          serverUrl: syncSetting.webdavServerUrl.value,
          username: syncSetting.webdavUsername.value,
          password: syncSetting.webdavPassword.value,
          remotePath: syncSetting.webdavRemotePath.value,
          enabled: syncSetting.enableWebDav.value,
        );
      } else {
        return SyncResult(
          success: false,
          message: 'Unknown provider: $provider',
          statistics: {},
        );
      }

      if (!cloudProvider.isEnabled) {
        log.warning('❌ Provider ${cloudProvider.name} is not enabled. Please enable it in settings.');
        return SyncResult(
          success: false,
          message: 'Provider ${cloudProvider.name} is not enabled',
          statistics: {},
        );
      }

      log.info('🔄 Starting sync with provider: ${cloudProvider.name}');

      // 1. Get local configs
      List<CloudConfig> localConfigs = [];
      for (var type in types) {
        CloudConfig? config = await cloudConfigService.getLocalConfig(type);
        if (config != null) {
          localConfigs.add(config);
          log.info('  Local ${type.name}: ${config.config.length} bytes');
        } else {
          log.info('  Local ${type.name}: empty (skipped)');
        }
      }

      log.info('Total local configs: ${localConfigs.length}');

      // 2. Download remote config
      List<CloudConfig> remoteConfigs = [];
      CloudFile? remoteFile = await cloudProvider.getFileMetadata();
      if (remoteFile != null) {
        try {
          String data = await cloudProvider.download();
          List list = await isolateService.jsonDecodeAsync(data);
          remoteConfigs = list.map((e) => CloudConfig.fromJson(e)).toList();
          log.info('Downloaded ${remoteConfigs.length} remote configs');
          for (var config in remoteConfigs) {
            log.info('  Remote ${config.type.name}: ${config.config.length} bytes');
          }
        } catch (e) {
          log.warning('Failed to download remote config, will upload local', e);
        }
      } else {
        log.info('No remote config found (first sync), will upload local configs');
      }

      // 3. Merge configs
      var mergeResult = await syncMerger.merge(
        localConfigs,
        remoteConfigs,
        remoteFile?.modifiedTime ?? DateTime.now(),
        types,
      );

      // 4. Import merged result to local
      log.info('Importing ${mergeResult.merged.length} merged configs to local');
      for (var config in mergeResult.merged) {
        await cloudConfigService.importConfig(config);
        log.info('  Imported ${config.type.name}');
      }

      // 5. Upload merged result
      // saveHistory is determined by user settings (default: false)
      bool saveHistory = syncSetting.enableHistory.value;
      String encodedData = await isolateService.jsonEncodeAsync(mergeResult.merged);
      log.info('Uploading ${mergeResult.merged.length} configs to remote (${encodedData.length} bytes)');

      await cloudProvider.upload(
        encodedData,
        saveHistory: saveHistory,
      );
      log.info('Upload complete');

      // 6. If history is enabled and auto cleanup is on, clean up old versions
      if (saveHistory && syncSetting.autoCleanHistory.value) {
        await _cleanupOldVersions(cloudProvider);
      }

      log.info('Sync completed successfully');
      return SyncResult(
        success: true,
        message: 'Sync completed successfully',
        statistics: mergeResult.statistics,
      );
    } catch (e) {
      log.error('Sync failed', e);
      return SyncResult(
        success: false,
        message: e.toString(),
        statistics: {},
      );
    }
  }

  /// List history versions
  /// [providerName]: Optional provider name, defaults to current provider
  Future<List<CloudFile>> listHistory({String? providerName}) async {
    try {
      // Create provider dynamically with latest settings
      String provider = providerName ?? syncSetting.currentProvider.value;
      CloudProvider cloudProvider;

      if (provider == 's3') {
        cloudProvider = S3Provider(
          endpoint: syncSetting.s3Endpoint.value,
          accessKey: syncSetting.s3AccessKey.value,
          secretKey: syncSetting.s3SecretKey.value,
          bucketName: syncSetting.s3BucketName.value,
          region: syncSetting.s3Region.value,
          baseKey: syncSetting.s3BaseKey.value,
          enabled: syncSetting.enableS3.value,
          useSSL: syncSetting.s3UseSSL.value,
        );
      } else if (provider == 'webdav') {
        cloudProvider = WebDavProvider(
          serverUrl: syncSetting.webdavServerUrl.value,
          username: syncSetting.webdavUsername.value,
          password: syncSetting.webdavPassword.value,
          remotePath: syncSetting.webdavRemotePath.value,
          enabled: syncSetting.enableWebDav.value,
        );
      } else {
        log.warning('Unknown provider: $provider');
        return [];
      }

      return await cloudProvider.listVersions();
    } catch (e) {
      log.error('Failed to list history versions', e);
      return [];
    }
  }

  /// Restore from history version
  /// [version]: Version to restore (timestamp format)
  /// [syncToCloud]: Whether to sync to cloud after restore (default: true)
  /// [providerName]: Optional provider name, defaults to current provider
  Future<RestoreResult> restoreFromHistory({
    required String version,
    bool syncToCloud = true,
    String? providerName,
  }) async {
    try {
      // Create provider dynamically with latest settings
      String provider = providerName ?? syncSetting.currentProvider.value;
      CloudProvider cloudProvider;

      if (provider == 's3') {
        cloudProvider = S3Provider(
          endpoint: syncSetting.s3Endpoint.value,
          accessKey: syncSetting.s3AccessKey.value,
          secretKey: syncSetting.s3SecretKey.value,
          bucketName: syncSetting.s3BucketName.value,
          region: syncSetting.s3Region.value,
          baseKey: syncSetting.s3BaseKey.value,
          enabled: syncSetting.enableS3.value,
          useSSL: syncSetting.s3UseSSL.value,
        );
      } else if (provider == 'webdav') {
        cloudProvider = WebDavProvider(
          serverUrl: syncSetting.webdavServerUrl.value,
          username: syncSetting.webdavUsername.value,
          password: syncSetting.webdavPassword.value,
          remotePath: syncSetting.webdavRemotePath.value,
          enabled: syncSetting.enableWebDav.value,
        );
      } else {
        return RestoreResult(
          success: false,
          error: 'Unknown provider: $provider',
        );
      }

      log.info('Restoring from version: $version');

      // 1. Download specified history version
      String data = await cloudProvider.downloadVersion(version);
      List configs = await isolateService.jsonDecodeAsync(data);
      List<CloudConfig> cloudConfigs = configs.map((e) => CloudConfig.fromJson(e)).toList();

      // 2. Import to local (replace current config)
      for (var config in cloudConfigs) {
        await cloudConfigService.importConfig(config);
      }

      // 3. (Optional) Sync to cloud, making the restored version the new latest
      if (syncToCloud) {
        await cloudProvider.upload(data, saveHistory: syncSetting.enableHistory.value);
      }

      log.info('Restored from version: $version');
      return RestoreResult(success: true, version: version);
    } catch (e) {
      log.error('Failed to restore from history', e);
      return RestoreResult(success: false, error: e.toString());
    }
  }

  /// Delete a specific history version
  /// [version]: Version to delete (timestamp format)
  /// [providerName]: Optional provider name, defaults to current provider
  Future<bool> deleteHistoryVersion({
    required String version,
    String? providerName,
  }) async {
    try {
      // Create provider dynamically with latest settings
      String provider = providerName ?? syncSetting.currentProvider.value;
      CloudProvider cloudProvider;

      if (provider == 's3') {
        cloudProvider = S3Provider(
          endpoint: syncSetting.s3Endpoint.value,
          accessKey: syncSetting.s3AccessKey.value,
          secretKey: syncSetting.s3SecretKey.value,
          bucketName: syncSetting.s3BucketName.value,
          region: syncSetting.s3Region.value,
          baseKey: syncSetting.s3BaseKey.value,
          enabled: syncSetting.enableS3.value,
          useSSL: syncSetting.s3UseSSL.value,
        );
      } else if (provider == 'webdav') {
        cloudProvider = WebDavProvider(
          serverUrl: syncSetting.webdavServerUrl.value,
          username: syncSetting.webdavUsername.value,
          password: syncSetting.webdavPassword.value,
          remotePath: syncSetting.webdavRemotePath.value,
          enabled: syncSetting.enableWebDav.value,
        );
      } else {
        log.warning('Unknown provider: $provider');
        return false;
      }

      await cloudProvider.deleteVersion(version);
      log.info('Deleted version: $version');
      return true;
    } catch (e) {
      log.error('Failed to delete version', e);
      return false;
    }
  }

  /// Clear all history versions
  /// [providerName]: Optional provider name, defaults to current provider
  Future<bool> clearAllHistory({String? providerName}) async {
    try {
      // Create provider dynamically with latest settings
      String provider = providerName ?? syncSetting.currentProvider.value;
      CloudProvider cloudProvider;

      if (provider == 's3') {
        cloudProvider = S3Provider(
          endpoint: syncSetting.s3Endpoint.value,
          accessKey: syncSetting.s3AccessKey.value,
          secretKey: syncSetting.s3SecretKey.value,
          bucketName: syncSetting.s3BucketName.value,
          region: syncSetting.s3Region.value,
          baseKey: syncSetting.s3BaseKey.value,
          enabled: syncSetting.enableS3.value,
          useSSL: syncSetting.s3UseSSL.value,
        );
      } else if (provider == 'webdav') {
        cloudProvider = WebDavProvider(
          serverUrl: syncSetting.webdavServerUrl.value,
          username: syncSetting.webdavUsername.value,
          password: syncSetting.webdavPassword.value,
          remotePath: syncSetting.webdavRemotePath.value,
          enabled: syncSetting.enableWebDav.value,
        );
      } else {
        log.warning('Unknown provider: $provider');
        return false;
      }

      List<CloudFile> versions = await cloudProvider.listVersions();

      for (var version in versions) {
        await cloudProvider.deleteVersion(version.version);
      }

      log.info('Cleared all ${versions.length} history versions');
      return true;
    } catch (e) {
      log.error('Failed to clear all history', e);
      return false;
    }
  }

  /// Test connection for a specific provider
  /// [providerName]: Provider name ('s3' or 'webdav')
  Future<bool> testConnection(String providerName) async {
    try {
      log.info('Testing connection for provider: $providerName');

      // Create provider dynamically with latest settings
      // Note: Always pass enabled=true for testConnection, we just want to test the connection itself
      CloudProvider cloudProvider;

      if (providerName == 's3') {
        // Check if S3 endpoint is configured
        if (syncSetting.s3Endpoint.value.isEmpty) {
          log.warning('S3 endpoint is empty');
          return false;
        }

        log.info('Creating S3 provider with endpoint: ${syncSetting.s3Endpoint.value}, bucket: ${syncSetting.s3BucketName.value}');
        cloudProvider = S3Provider(
          endpoint: syncSetting.s3Endpoint.value,
          accessKey: syncSetting.s3AccessKey.value,
          secretKey: syncSetting.s3SecretKey.value,
          bucketName: syncSetting.s3BucketName.value,
          region: syncSetting.s3Region.value,
          baseKey: syncSetting.s3BaseKey.value,
          enabled: true, // Always test connection regardless of enabled state
          useSSL: syncSetting.s3UseSSL.value,
        );
      } else if (providerName == 'webdav') {
        // Check if WebDAV server is configured
        if (syncSetting.webdavServerUrl.value.isEmpty) {
          log.warning('WebDAV server URL is empty');
          return false;
        }

        log.info('Creating WebDAV provider with server: ${syncSetting.webdavServerUrl.value}');
        cloudProvider = WebDavProvider(
          serverUrl: syncSetting.webdavServerUrl.value,
          username: syncSetting.webdavUsername.value,
          password: syncSetting.webdavPassword.value,
          remotePath: syncSetting.webdavRemotePath.value,
          enabled: true, // Always test connection regardless of enabled state
        );
      } else {
        log.warning('Unknown provider: $providerName');
        return false;
      }

      bool result = await cloudProvider.testConnection();
      log.info('Connection test result for $providerName: $result');
      return result;
    } catch (e, stackTrace) {
      log.error('Connection test failed for $providerName', e, stackTrace);
      return false;
    }
  }

  /// Cleanup old versions exceeding the limit
  Future<void> _cleanupOldVersions(CloudProvider provider) async {
    // Check if auto cleanup is enabled
    if (!syncSetting.enableHistory.value || !syncSetting.autoCleanHistory.value) {
      return;
    }

    try {
      // List all history versions
      List<CloudFile> versions = await provider.listVersions();
      int maxVersions = syncSetting.maxHistoryVersions.value;

      log.info('Found ${versions.length} history versions, max allowed: $maxVersions');

      if (versions.length > maxVersions) {
        // Sort by version (timestamp) in descending order (newest first)
        versions.sort((a, b) => b.version.compareTo(a.version));

        // Delete versions exceeding the limit
        int deletedCount = 0;
        for (int i = maxVersions; i < versions.length; i++) {
          await provider.deleteVersion(versions[i].version);
          log.info('Deleted old version: ${versions[i].version}');
          deletedCount++;
        }

        log.info('Cleaned up $deletedCount old versions');
      }
    } catch (e) {
      log.error('Failed to cleanup old versions', e);
      // Cleanup failure does not affect main flow, just log the error
    }
  }
}

/// Sync result
class SyncResult {
  final bool success;
  final String message;
  final Map<CloudConfigTypeEnum, MergeStatistics> statistics;

  SyncResult({
    required this.success,
    required this.message,
    required this.statistics,
  });
}

/// Restore result
class RestoreResult {
  final bool success;
  final String? version;
  final String? error;

  RestoreResult({
    required this.success,
    this.version,
    this.error,
  });
}
