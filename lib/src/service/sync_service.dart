import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
import 'package:jhentai/src/service/cloud/hot_data_sync_engine.dart';
import 'package:jhentai/src/service/cloud/s3_provider.dart';
import 'package:jhentai/src/service/cloud/webdav_provider.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';
import 'package:jhentai/src/service/cloud_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/sync_merger.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/widget/app_manager.dart';

import 'jh_service.dart';
import 'log.dart';

SyncService syncService = SyncService();

typedef SyncRunner =
    Future<SyncResult> Function({
      required List<CloudConfigTypeEnum> types,
      String? providerName,
      void Function(double progress)? onProgress,
    });

class _QueuedReadProgressSync {
  _QueuedReadProgressSync({required this.requireAutoSync});

  final Completer<SyncResult?> completer = Completer<SyncResult?>();
  bool requireAutoSync;

  void merge({required bool requireAutoSync}) {
    if (!requireAutoSync) {
      this.requireAutoSync = false;
    }
  }
}

/// 统一同步服务（协调层）
/// 负责协调 CloudProvider 和 SyncMerger，提供统一的同步接口
class SyncService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  SyncService({
    SyncRunner? executeSync,
    DateTime Function()? now,
    Duration progressCooldown = const Duration(seconds: 5),
  }) : _syncRunner = executeSync,
       _now = now ?? DateTime.now,
       _readProgressSyncCooldown = progressCooldown;

  final Map<String, CloudProvider> _providers = {};
  final HotDataSyncEngine _hotEngine = HotDataSyncEngine();
  final SyncRunner? _syncRunner;
  final DateTime Function() _now;
  final Duration _readProgressSyncCooldown;
  bool _syncInProgress = false;
  DateTime? _lastSyncTime;
  DateTime? _lastReadProgressSyncSuccessTime;
  _QueuedReadProgressSync? _queuedReadProgressSync;
  int _lastHistoryAutoSyncCount = 0;
  bool _historyAutoSyncInProgress = false;
  static const _minSyncInterval = Duration(seconds: 30);
  static const int _historyAutoSyncStep = 5;

  @override
  List<JHLifeCircleBean> get initDependencies => [
    log,
    syncSetting,
    syncMerger,
    cloudConfigService,
    isolateService,
  ];

  @override
  Future<void> doInitBean() async {
    // Initialize all providers
    _initProviders();
  }

  @override
  Future<void> doAfterBeanReady() async {
    // Register app lifecycle callback to listen for app resumed events
    AppManager.registerDidChangeAppLifecycleStateCallback(
      _onAppLifecycleStateChanged,
    );

    // Auto sync on app startup if enabled
    if (syncSetting.enableSync.value && syncSetting.autoSync.value) {
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

  /// Perform auto sync on app startup (non-blocking, background)
  void _performAutoSyncOnStartup() async {
    try {
      log.info('========================================');
      log.info('Auto sync on startup: checking...');
      log.info('Auto sync enabled: ${syncSetting.autoSync.value}');
      log.info('Current provider: ${syncSetting.currentProvider.value}');
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

  /// Handle app lifecycle state changes
  void _onAppLifecycleStateChanged(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(performAutoSyncOnResume());
    }
  }

  /// Perform auto sync when app resumes from background
  @visibleForTesting
  Future<void> performAutoSyncOnResume() async {
    // Check if sync is enabled
    if (!syncSetting.enableSync.value || !syncSetting.autoSync.value) {
      log.debug('Auto sync on resume: disabled');
      return;
    }

    try {
      if (_syncInProgress) {
        log.debug(
          'Auto sync on resume: sync already running; queueing read progress',
        );
        await syncReadProgress();
        return;
      }

      // Keep the expensive full-config sync on its existing 30-second
      // cadence, but still reconcile read progress on every foreground event.
      if (_lastSyncTime != null &&
          _now().difference(_lastSyncTime!) < _minSyncInterval) {
        log.debug(
          'Auto sync on resume: full sync skipped; reconciling read progress',
        );
        await syncReadProgress();
        return;
      }

      log.info('========================================');
      log.info('Auto sync on app resumed: starting...');
      log.info('Current provider: ${syncSetting.currentProvider.value}');
      log.info('========================================');

      // Sync all config types
      List<CloudConfigTypeEnum> allTypes = CloudConfigTypeEnum.values;
      SyncResult result = await sync(types: allTypes);

      if (result.success) {
        log.info('✅ Auto sync on resume completed successfully');
        log.info('Statistics: ${result.statistics}');
      } else {
        log.warning('❌ Auto sync on resume failed: ${result.message}');
      }
    } catch (e) {
      log.error('💥 Auto sync on resume failed', e);
      // Don't throw, just log the error
    }
  }

  /// Trigger auto sync when history count reaches the configured step milestone.
  /// Only syncs gallery history to reduce overhead.
  void triggerAutoSyncByHistoryCount(int totalHistoryCount) async {
    if (totalHistoryCount <= 0 ||
        totalHistoryCount % _historyAutoSyncStep != 0) {
      return;
    }

    if (_lastHistoryAutoSyncCount >= totalHistoryCount) {
      return;
    }

    if (!syncSetting.enableSync.value || !syncSetting.autoSync.value) {
      log.debug('Auto sync by history count skipped: sync disabled');
      return;
    }

    if (_historyAutoSyncInProgress) {
      log.debug('Auto sync by history count skipped: sync already in progress');
      return;
    }

    if (_lastSyncTime != null &&
        DateTime.now().difference(_lastSyncTime!) < _minSyncInterval) {
      log.debug('Auto sync by history count skipped: too soon since last sync');
      return;
    }

    _historyAutoSyncInProgress = true;
    _lastHistoryAutoSyncCount = totalHistoryCount;
    _lastSyncTime = DateTime.now();

    try {
      log.info('========================================');
      log.info('Auto sync by history count: $totalHistoryCount');
      log.info('Current provider: ${syncSetting.currentProvider.value}');
      log.info('========================================');

      SyncResult result = await sync(
        types: const [CloudConfigTypeEnum.history],
      );

      if (result.success) {
        log.info('✅ Auto sync by history count completed successfully');
      } else {
        log.warning('❌ Auto sync by history count failed: ${result.message}');
      }
    } catch (e) {
      log.error('💥 Auto sync by history count failed', e);
    } finally {
      _historyAutoSyncInProgress = false;
    }
  }

  /// Execute sync
  /// [types]: List of config types to sync
  /// [providerName]: Optional provider name, defaults to current provider
  Future<SyncResult> sync({
    required List<CloudConfigTypeEnum> types,
    String? providerName,
    void Function(double progress)? onProgress,
  }) async {
    if (_syncInProgress) {
      log.info('Sync skipped: another sync is already in progress');
      return SyncResult(
        success: false,
        message: 'Sync already in progress',
        statistics: {},
      );
    }
    _syncInProgress = true;
    try {
      final SyncResult result =
          await (_syncRunner?.call(
                types: types,
                providerName: providerName,
                onProgress: onProgress,
              ) ??
              _doSync(
                types: types,
                providerName: providerName,
                onProgress: onProgress,
              ));
      if (result.success) {
        final DateTime completedAt = _now();
        if (types.contains(CloudConfigTypeEnum.readIndexRecord)) {
          _lastReadProgressSyncSuccessTime = completedAt;
        }
        if (CloudConfigTypeEnum.values.every(types.contains)) {
          _lastSyncTime = completedAt;
        }
      }
      return result;
    } finally {
      _syncInProgress = false;
      _drainQueuedReadProgressSync();
    }
  }

  /// Reconcile read progress without letting foreground/reader-close bursts
  /// start concurrent cloud operations.
  ///
  /// Calls received while another sync is running are merged into one
  /// trailing sync. That trailing request is not discarded by the cooldown:
  /// the active sync may already have captured its local/remote snapshots.
  Future<SyncResult?> syncReadProgress({
    bool requireAutoSync = true,
    bool force = false,
  }) {
    if (!syncSetting.enableSync.value) {
      return Future<SyncResult?>.value();
    }
    if (requireAutoSync && !syncSetting.autoSync.value) {
      return Future<SyncResult?>.value();
    }

    if (_syncInProgress) {
      return _queueReadProgressSync(requireAutoSync: requireAutoSync);
    }

    final DateTime? lastSuccess = _lastReadProgressSyncSuccessTime;
    if (!force &&
        lastSuccess != null &&
        _now().difference(lastSuccess) < _readProgressSyncCooldown) {
      return Future<SyncResult?>.value();
    }

    return sync(types: const [CloudConfigTypeEnum.readIndexRecord]);
  }

  Future<SyncResult?> _queueReadProgressSync({required bool requireAutoSync}) {
    final _QueuedReadProgressSync? queued = _queuedReadProgressSync;
    if (queued != null) {
      queued.merge(requireAutoSync: requireAutoSync);
      return queued.completer.future;
    }

    final _QueuedReadProgressSync request = _QueuedReadProgressSync(
      requireAutoSync: requireAutoSync,
    );
    _queuedReadProgressSync = request;
    return request.completer.future;
  }

  void _drainQueuedReadProgressSync() {
    if (_syncInProgress) {
      return;
    }

    final _QueuedReadProgressSync? request = _queuedReadProgressSync;
    if (request == null) {
      return;
    }
    _queuedReadProgressSync = null;
    unawaited(_runQueuedReadProgressSync(request));
  }

  Future<void> _runQueuedReadProgressSync(
    _QueuedReadProgressSync request,
  ) async {
    if (!syncSetting.enableSync.value ||
        (request.requireAutoSync && !syncSetting.autoSync.value)) {
      request.completer.complete();
      return;
    }

    try {
      final SyncResult result = await sync(
        types: const [CloudConfigTypeEnum.readIndexRecord],
      );
      request.completer.complete(result);
    } catch (error, stackTrace) {
      request.completer.completeError(error, stackTrace);
    }
  }

  Future<SyncResult> _doSync({
    required List<CloudConfigTypeEnum> types,
    String? providerName,
    void Function(double progress)? onProgress,
  }) async {
    void reportProgress(double progress) {
      onProgress?.call(progress.clamp(0, 1).toDouble());
    }

    try {
      reportProgress(0.03);

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
          useSSL: syncSetting.s3UseSSL.value,
        );
      } else if (provider == 'webdav') {
        cloudProvider = WebDavProvider(
          serverUrl: syncSetting.webdavServerUrl.value,
          username: syncSetting.webdavUsername.value,
          password: syncSetting.webdavPassword.value,
          remotePath: syncSetting.webdavRemotePath.value,
        );
      } else {
        return SyncResult(
          success: false,
          message: 'Unknown provider: $provider',
          statistics: {},
        );
      }

      log.info('🔄 Starting sync with provider: ${cloudProvider.name}');
      reportProgress(0.08);

      // 1. Download remote config (shared by hot-data bootstrap and legacy merge)
      String? remoteData;
      List<CloudConfig> remoteConfigs = [];
      CloudFile? remoteFile = await cloudProvider.getFileMetadata();

      // Try to download even if metadata fetch failed
      try {
        remoteData = await cloudProvider.download();
        List list = await isolateService.jsonDecodeAsync(remoteData);
        remoteConfigs = list.map((e) => CloudConfig.fromJson(e)).toList();
        log.info('Downloaded ${remoteConfigs.length} remote configs');

        // If download succeeded but metadata failed, create a placeholder
        if (remoteFile == null && remoteConfigs.isNotEmpty) {
          log.warning(
            'Metadata fetch failed but download succeeded, using current time as fallback',
          );
          remoteFile = CloudFile(
            version: 'latest',
            modifiedTime: DateTime.now(),
            size: remoteData.length,
            etag: null,
          );
        }
      } catch (e) {
        log.info(
          'No remote config found (first sync), will upload local configs',
        );
      }
      reportProgress(0.2);

      // 2. Hot data types (history / read progress) sync incrementally through
      // the oplog engine instead of travelling inside latest.json
      const List<CloudConfigTypeEnum> hotTypes = [
        CloudConfigTypeEnum.history,
        CloudConfigTypeEnum.readIndexRecord,
      ];
      List<CloudConfigTypeEnum> effectiveTypes = types;
      HotSyncResult? hotResult;

      if (types.any(hotTypes.contains)) {
        try {
          hotResult = await _hotEngine.sync(
            cloudProvider,
            legacyRemoteConfigJson: remoteData,
          );
          effectiveTypes = types.where((t) => !hotTypes.contains(t)).toList();
        } catch (e, stack) {
          log.error(
            'Hot data sync failed, falling back to legacy full-file sync',
            e,
            stack,
          );
        }
      }
      reportProgress(0.5);

      if (effectiveTypes.isEmpty) {
        log.info('Sync completed successfully (hot data only)');
        reportProgress(1);
        return SyncResult(
          success: true,
          message: 'Sync completed successfully',
          statistics: {},
        );
      }

      // 3. Get local configs for the remaining (small) types
      List<CloudConfig> localConfigs = [];
      for (CloudConfigTypeEnum type in effectiveTypes) {
        CloudConfig? config = await cloudConfigService.getLocalConfig(type);
        if (config != null) {
          localConfigs.add(config);
          log.info('  Local ${type.name}: ${config.config.length} bytes');
        } else {
          log.info('  Local ${type.name}: empty (skipped)');
        }
      }
      reportProgress(0.6);

      // 4. Merge configs (merger handles import internally).
      // The "latest local activity" heuristic used by whole-file LWW types is
      // computed from the hot tables directly since they no longer travel here.
      DateTime? latestLocalTime = await _computeLatestLocalActivityTime();
      var mergeResult = await syncMerger.merge(
        localConfigs,
        remoteConfigs,
        remoteFile?.modifiedTime ?? DateTime.now(),
        effectiveTypes,
        latestLocalTimeOverride: latestLocalTime,
      );
      reportProgress(0.74);

      // 5. Upload merged result, unless it is identical to what the remote
      // already holds (avoids churning latest.json and its version history)
      bool saveHistory = syncSetting.enableHistory.value;
      String encodedData = await isolateService.jsonEncodeAsync(
        mergeResult.merged,
      );

      if (remoteData != null && encodedData == remoteData) {
        log.info('Merged result identical to remote, skipping upload');
      } else {
        log.info(
          'Uploading ${mergeResult.merged.length} configs to remote (${encodedData.length} bytes)',
        );
        await cloudProvider.upload(encodedData, saveHistory: saveHistory);
        log.info('Upload complete');
        reportProgress(0.92);

        // 6. If history is enabled and auto cleanup is on, clean up old versions
        if (saveHistory && syncSetting.autoCleanHistory.value) {
          await _cleanupOldVersions(cloudProvider);
        }
      }
      reportProgress(1);

      log.info(
        'Sync completed successfully'
        '${hotResult != null ? ' (hot: +${hotResult.appliedRows} applied, ${hotResult.pushedRows} pushed)' : ''}',
      );
      return SyncResult(
        success: true,
        message: 'Sync completed successfully',
        statistics: mergeResult.statistics,
      );
    } catch (e) {
      log.error('Sync failed', e);
      return SyncResult(success: false, message: e.toString(), statistics: {});
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
          useSSL: syncSetting.s3UseSSL.value,
        );
      } else if (provider == 'webdav') {
        cloudProvider = WebDavProvider(
          serverUrl: syncSetting.webdavServerUrl.value,
          username: syncSetting.webdavUsername.value,
          password: syncSetting.webdavPassword.value,
          remotePath: syncSetting.webdavRemotePath.value,
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
          useSSL: syncSetting.s3UseSSL.value,
        );
      } else if (provider == 'webdav') {
        cloudProvider = WebDavProvider(
          serverUrl: syncSetting.webdavServerUrl.value,
          username: syncSetting.webdavUsername.value,
          password: syncSetting.webdavPassword.value,
          remotePath: syncSetting.webdavRemotePath.value,
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
      List<CloudConfig> cloudConfigs = configs
          .map((e) => CloudConfig.fromJson(e))
          .toList();

      // 2. Import to local (replace current config)
      for (var config in cloudConfigs) {
        await cloudConfigService.importConfig(config);
      }

      // 3. (Optional) Sync to cloud, making the restored version the new latest
      if (syncToCloud) {
        await cloudProvider.upload(
          data,
          saveHistory: syncSetting.enableHistory.value,
        );
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
          useSSL: syncSetting.s3UseSSL.value,
        );
      } else if (provider == 'webdav') {
        cloudProvider = WebDavProvider(
          serverUrl: syncSetting.webdavServerUrl.value,
          username: syncSetting.webdavUsername.value,
          password: syncSetting.webdavPassword.value,
          remotePath: syncSetting.webdavRemotePath.value,
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
          useSSL: syncSetting.s3UseSSL.value,
        );
      } else if (provider == 'webdav') {
        cloudProvider = WebDavProvider(
          serverUrl: syncSetting.webdavServerUrl.value,
          username: syncSetting.webdavUsername.value,
          password: syncSetting.webdavPassword.value,
          remotePath: syncSetting.webdavRemotePath.value,
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

        log.info(
          'Creating S3 provider with endpoint: ${syncSetting.s3Endpoint.value}, bucket: ${syncSetting.s3BucketName.value}',
        );
        cloudProvider = S3Provider(
          endpoint: syncSetting.s3Endpoint.value,
          accessKey: syncSetting.s3AccessKey.value,
          secretKey: syncSetting.s3SecretKey.value,
          bucketName: syncSetting.s3BucketName.value,
          region: syncSetting.s3Region.value,
          baseKey: syncSetting.s3BaseKey.value,
          useSSL: syncSetting.s3UseSSL.value,
        );
      } else if (providerName == 'webdav') {
        // Check if WebDAV server is configured
        if (syncSetting.webdavServerUrl.value.isEmpty) {
          log.warning('WebDAV server URL is empty');
          return false;
        }

        log.info(
          'Creating WebDAV provider with server: ${syncSetting.webdavServerUrl.value}',
        );
        cloudProvider = WebDavProvider(
          serverUrl: syncSetting.webdavServerUrl.value,
          username: syncSetting.webdavUsername.value,
          password: syncSetting.webdavPassword.value,
          remotePath: syncSetting.webdavRemotePath.value,
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

  /// Latest local user activity, derived from the hot tables. Used by the
  /// merger to decide whole-file conflicts for small config types.
  Future<DateTime?> _computeLatestLocalActivityTime() async {
    DateTime? latest;
    String? historyTime = await historyService.getMaxLastReadTime();
    String? progressTime = await localConfigService.maxUtime(
      configKey: ConfigEnum.readIndexRecord,
    );
    for (String? value in [historyTime, progressTime]) {
      DateTime? parsed = SyncTimeUtil.tryParse(value);
      if (parsed != null && (latest == null || parsed.isAfter(latest))) {
        latest = parsed;
      }
    }
    return latest;
  }

  /// Cleanup old versions exceeding the limit
  Future<void> _cleanupOldVersions(CloudProvider provider) async {
    // Check if auto cleanup is enabled
    if (!syncSetting.enableHistory.value ||
        !syncSetting.autoCleanHistory.value) {
      return;
    }

    try {
      // List all history versions
      List<CloudFile> versions = await provider.listVersions();
      int maxVersions = syncSetting.maxHistoryVersions.value;

      log.info(
        'Found ${versions.length} history versions, max allowed: $maxVersions',
      );

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

  RestoreResult({required this.success, this.version, this.error});
}
