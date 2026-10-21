import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
import 'package:jhentai/src/service/cloud/hot_data_sync_engine.dart';
import 'package:jhentai/src/service/cloud/s3_provider.dart';
import 'package:jhentai/src/service/cloud/sync_cancel_token.dart';
import 'package:jhentai/src/service/cloud/webdav_provider.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/cloud/sync_device_id.dart';
import 'package:jhentai/src/service/record_sync/bucket_record_backend.dart';
import 'package:jhentai/src/service/record_sync/record_backend.dart';
import 'package:jhentai/src/service/record_sync/record_sync_engine.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';
import 'package:jhentai/src/service/cloud_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/sync_merger.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/setting/test_build.dart';
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

typedef CloudProviderFactory = CloudProvider? Function(String providerName);

typedef RecordBackendFactory = RecordBackend? Function();

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
    CloudProviderFactory? providerFactory,
    RecordBackendFactory? recordBackendFactory,
    DateTime Function()? now,
    Duration progressCooldown = const Duration(seconds: 5),
    Duration syncTimeout = const Duration(minutes: 15),
  }) : _syncRunner = executeSync,
       _providerFactory = providerFactory,
       _recordBackendFactory = recordBackendFactory,
       _now = now ?? DateTime.now,
       _readProgressSyncCooldown = progressCooldown,
       _syncTimeout = syncTimeout;

  /// Provider name of a sync server (record by record), as opposed to the
  /// buckets 's3' and 'webdav'.
  static const String serverProvider = 'server';

  final Map<String, CloudProvider> _providers = {};
  final HotDataSyncEngine _hotEngine = HotDataSyncEngine();
  final SyncRunner? _syncRunner;
  final CloudProviderFactory? _providerFactory;
  final RecordBackendFactory? _recordBackendFactory;
  final DateTime Function() _now;
  final Duration _readProgressSyncCooldown;
  Future<void>? _inFlightSync;
  bool get _syncInProgress => _inFlightSync != null;
  DateTime? _lastSyncTime;
  DateTime? _lastReadProgressSyncSuccessTime;
  _QueuedReadProgressSync? _queuedReadProgressSync;
  int _lastHistoryAutoSyncCount = 0;
  bool _historyAutoSyncInProgress = false;
  static const _minSyncInterval = Duration(seconds: 30);

  /// A sync that has not ended by then is given up: its caller is answered,
  /// and the sync stops before its next write (see [SyncCancelToken]).
  /// Later syncs wait until it has stopped, so that two never write at once;
  /// every request of a provider has a time limit, so it does stop.
  final Duration _syncTimeout;
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
    final Completer<void> done = Completer<void>();
    _inFlightSync = done.future;
    final SyncCancelToken cancel = SyncCancelToken();
    Future<SyncResult>? run;
    try {
      run =
          _syncRunner?.call(
            types: types,
            providerName: providerName,
            onProgress: onProgress,
          ) ??
          _doSync(
            types: types,
            providerName: providerName,
            onProgress: onProgress,
            cancel: cancel,
          );
      final SyncResult result = await run.timeout(
        _syncTimeout,
        onTimeout: () {
          log.error('Sync gave up after $_syncTimeout, it stops before its next write');
          cancel.cancel();
          return SyncResult(
            success: false,
            message: 'Sync timed out after ${_syncTimeout.inMinutes} minutes',
            statistics: {},
          );
        },
      );
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
      void release() {
        _inFlightSync = null;
        done.complete();
        _drainQueuedReadProgressSync();
      }

      if (cancel.isCancelled && run != null) {
        unawaited(run.then<void>((_) {}, onError: (Object _) {}).whenComplete(release));
      } else {
        release();
      }
    }
  }

  /// Upload a locally changed setting. A sync that is already running may
  /// have read local state before the change, so wait for it and sync again
  /// instead of dropping the request.
  Future<SyncResult> syncAfterLocalChange({
    required List<CloudConfigTypeEnum> types,
  }) async {
    while (_inFlightSync != null) {
      await _inFlightSync;
    }
    return sync(types: types);
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
    required SyncCancelToken cancel,
  }) async {
    void reportProgress(double progress) {
      onProgress?.call(progress.clamp(0, 1).toDouble());
    }

    try {
      reportProgress(0.03);

      String provider = providerName ?? syncSetting.currentProvider.value;
      if (!_testBuildAllows(provider)) {
        return SyncResult(success: false, message: _testBuildRefusal, statistics: {});
      }
      if (provider == serverProvider) {
        return await _doRecordSync(types: types, onProgress: reportProgress, cancel: cancel);
      }
      CloudProvider? cloudProvider = _createProvider(provider);
      if (cloudProvider == null) {
        return SyncResult(
          success: false,
          message: 'Unknown provider: $provider',
          statistics: {},
        );
      }

      log.info('🔄 Starting sync with provider: ${cloudProvider.name}');
      reportProgress(0.08);
      final BucketRecordBackend backend = BucketRecordBackend(cloudProvider, device: await ensureSyncDeviceId());
      final BucketManifest manifest = await backend.manifest();
      final bool takesLegacy = manifest.legacyDevice == null;
      if (takesLegacy) {
        cancel.throwIfCancelled();
        await _takeOverLegacyLayout(cloudProvider, cancel);
        // Rows it brought in are not in the pending sets: they go up whole.
        await recordSyncEngine.forgetRowChanges();
      }
      reportProgress(0.3);

      await recordSyncEngine.sync(
        backend,
        types: types.toSet(),
        onProgress: (double progress) => reportProgress(0.3 + progress * 0.55),
        cancel: cancel,
        joining: !takesLegacy && manifest.legacyDevice != backend.device,
      );
      if (takesLegacy) {
        await backend.markLegacyTaken();
      }
      reportProgress(0.9);

      cancel.throwIfCancelled();
      try {
        await backend.compact();
      } catch (e) {
        log.warning('Compacting the bucket records failed, tried again next time', e);
      }
      if (syncSetting.enableHistory.value && CloudConfigTypeEnum.values.every(types.contains)) {
        await _saveBackup(backend);
      }
      reportProgress(1);

      log.info('Sync completed successfully');
      return SyncResult(success: true, message: 'Sync completed successfully', statistics: {});
    } catch (e) {
      log.error('Sync failed', e);
      return SyncResult(success: false, message: e.toString(), statistics: {});
    }
  }

  /// History and read progress travel in op packs in a bucket of versions
  /// up to 8.1.1, the rest in latest.json.
  static const List<CloudConfigTypeEnum> _legacyHotTypes = [
    CloudConfigTypeEnum.history,
    CloudConfigTypeEnum.readIndexRecord,
  ];

  /// What versions up to 8.1.1 synced in the bucket, into this device's
  /// data, once, by the first device of a later version that syncs it (see
  /// [BucketRecordBackend]): the op packs of history and progress applied,
  /// and latest.json merged the way those versions merged it, every type.
  /// Nothing is written to that layout; what they write to it later is not
  /// taken. A file that is there but can not be read fails the sync.
  Future<void> _takeOverLegacyLayout(CloudProvider provider, SyncCancelToken cancel) async {
    CloudFile? remoteFile = await provider.getFileMetadata();
    String? remoteData = await provider.download();
    if (remoteData == null && remoteFile != null) {
      // The S3 provider reports every S3-level read error as a missing
      // object; metadata proves the file is there.
      throw StateError('Remote config exists but could not be downloaded');
    }
    cancel.throwIfCancelled();
    HotSyncResult hot = await _hotEngine.sync(provider, legacyRemoteConfigJson: remoteData, cancel: cancel, readOnly: true);
    log.info('Took over ${hot.appliedRows} history and progress rows of the earlier bucket layout');
    if (remoteData == null) {
      return;
    }

    CloudConfigFile remoteConfigFile = CloudConfigFile.fromJson(await isolateService.jsonDecodeAsync(remoteData));
    List<CloudConfigTypeEnum> types = CloudConfigTypeEnum.values.where((t) => !_legacyHotTypes.contains(t)).toList();
    List<CloudConfig> localConfigs = [
      for (CloudConfigTypeEnum type in types) ?await cloudConfigService.getLocalConfig(type),
    ];
    DateTime? latestLocalTime = await _computeLatestLocalActivityTime();
    cancel.throwIfCancelled();
    await syncMerger.merge(
      localConfigs,
      remoteConfigFile.configs,
      remoteFile?.modifiedTime ?? DateTime.now(),
      types,
      latestLocalTimeOverride: latestLocalTime,
    );
    log.info('Took over ${remoteConfigFile.configs.length} configs of the earlier bucket layout');
  }

  /// The settings as a history version (in the format of latest.json of
  /// earlier versions), when they changed since the last one.
  Future<void> _saveBackup(BucketRecordBackend backend) async {
    try {
      List<CloudConfig> configs = [
        for (CloudConfigTypeEnum type in CloudConfigTypeEnum.values)
          if (!_legacyHotTypes.contains(type)) ?await cloudConfigService.getLocalConfig(type),
      ];
      String data = await isolateService.jsonEncodeAsync(configs.map((c) => c.toJson()).toList());
      String hash = sha1.convert(utf8.encode(await isolateService.jsonEncodeAsync(configs.map((c) => c.config).toList()))).toString();
      if (hash == await localConfigService.read(configKey: ConfigEnum.recordBackupHash)) {
        return;
      }
      // Named by the second, after the newest there.
      DateFormat format = DateFormat('yyyyMMddHHmmss');
      DateTime time = _now().toUtc();
      List<CloudFile> versions = await backend.listBackups();
      if (versions.isNotEmpty && format.format(time).compareTo(versions.first.version) <= 0) {
        String v = versions.first.version;
        int at(int start, int end) => int.parse(v.substring(start, end));
        time = DateTime.utc(at(0, 4), at(4, 6), at(6, 8), at(8, 10), at(10, 12), at(12, 14)).add(const Duration(seconds: 1));
      }
      await backend.writeBackup(format.format(time), data);
      await localConfigService.write(configKey: ConfigEnum.recordBackupHash, value: hash);
      if (syncSetting.autoCleanHistory.value) {
        for (CloudFile version in (await backend.listBackups()).skip(syncSetting.maxHistoryVersions.value)) {
          await backend.deleteBackup(version.version);
        }
      }
    } catch (e) {
      log.error('Saving a history version failed', e);
    }
  }

  /// Sync with the sync server, record by record. Every kind's records are
  /// pulled and written; [types] limits which kinds' local changes are
  /// looked for (history and read progress always are, from their pending set).
  Future<SyncResult> _doRecordSync({
    required List<CloudConfigTypeEnum> types,
    required void Function(double progress) onProgress,
    required SyncCancelToken cancel,
  }) async {
    try {
      RecordBackend? backend = _recordBackendFactory != null ? _recordBackendFactory() : _createRecordBackend();
      if (backend == null) {
        return SyncResult(success: false, message: 'The sync server address is not set', statistics: {});
      }
      log.info('🔄 Starting sync with the sync server');
      await recordSyncEngine.sync(backend, types: types.toSet(), onProgress: onProgress, cancel: cancel);
      log.info('Sync completed successfully');
      return SyncResult(success: true, message: 'Sync completed successfully', statistics: {});
    } catch (e, stack) {
      log.error('Sync failed', e, stack);
      return SyncResult(success: false, message: e.toString(), statistics: {});
    }
  }

  RecordBackend? _createRecordBackend() {
    if (syncSetting.syncServerUrl.value.trim().isEmpty) {
      return null;
    }
    return HttpRecordBackend(url: syncSetting.syncServerUrl.value, token: syncSetting.syncServerToken.value);
  }

  /// List history versions: those of the records layout, and those earlier
  /// versions saved beside latest.json.
  /// [providerName]: Optional provider name, defaults to current provider
  Future<List<CloudFile>> listHistory({String? providerName}) async {
    try {
      String provider = providerName ?? syncSetting.currentProvider.value;
      CloudProvider? cloudProvider = _createProvider(provider);
      if (cloudProvider == null) {
        log.warning('Unknown provider: $provider');
        return [];
      }

      List<CloudFile> versions = await _backups(cloudProvider).listBackups();
      Set<String> known = versions.map((v) => v.version).toSet();
      versions.addAll((await cloudProvider.listVersions()).where((v) => !known.contains(v.version)));
      return versions..sort((a, b) => b.version.compareTo(a.version));
    } catch (e) {
      log.error('Failed to list history versions', e);
      return [];
    }
  }

  /// The history versions of the records layout; reading and writing them
  /// needs no device.
  BucketRecordBackend _backups(CloudProvider provider) => BucketRecordBackend(provider, device: '');

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
      String provider = providerName ?? syncSetting.currentProvider.value;
      CloudProvider? cloudProvider = _createProvider(provider);
      if (cloudProvider == null) {
        return RestoreResult(
          success: false,
          error: 'Unknown provider: $provider',
        );
      }

      log.info('Restoring from version: $version');

      // 1. Download specified history version
      String data = await _backups(cloudProvider).readBackup(version) ?? await cloudProvider.downloadVersion(version);
      CloudConfigFile file = CloudConfigFile.fromJson(
        await isolateService.jsonDecodeAsync(data),
      );

      // 2. Import to local (replace current config)
      for (var config in file.configs) {
        await cloudConfigService.importConfig(config);
      }

      // 3. (Optional) Sync, the restored settings taken as changed here now
      if (syncToCloud) {
        SyncResult result = await sync(types: CloudConfigTypeEnum.values);
        if (!result.success) {
          return RestoreResult(success: false, version: version, error: result.message);
        }
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
      String provider = providerName ?? syncSetting.currentProvider.value;
      CloudProvider? cloudProvider = _createProvider(provider);
      if (cloudProvider == null) {
        log.warning('Unknown provider: $provider');
        return false;
      }

      if (await _backups(cloudProvider).readBackup(version) != null) {
        await _backups(cloudProvider).deleteBackup(version);
      } else {
        await cloudProvider.deleteVersion(version);
      }
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
      String provider = providerName ?? syncSetting.currentProvider.value;
      CloudProvider? cloudProvider = _createProvider(provider);
      if (cloudProvider == null) {
        log.warning('Unknown provider: $provider');
        return false;
      }

      List<CloudFile> backups = await _backups(cloudProvider).listBackups();
      for (var version in backups) {
        await _backups(cloudProvider).deleteBackup(version.version);
      }
      List<CloudFile> versions = await cloudProvider.listVersions();
      for (var version in versions) {
        await cloudProvider.deleteVersion(version.version);
      }

      log.info('Cleared all ${backups.length + versions.length} history versions');
      return true;
    } catch (e) {
      log.error('Failed to clear all history', e);
      return false;
    }
  }

  /// Test connection for a specific provider
  /// [providerName]: Provider name ('s3', 'webdav' or 'server')
  Future<bool> testConnection(String providerName) async {
    try {
      log.info('Testing connection for provider: $providerName');
      if (!_testBuildAllows(providerName)) {
        log.warning(_testBuildRefusal);
        return false;
      }

      if (providerName == serverProvider) {
        RecordBackend? backend = _recordBackendFactory != null ? _recordBackendFactory() : _createRecordBackend();
        if (backend == null) {
          log.warning('Sync server address is empty');
          return false;
        }
        RecordServerInfo info = await backend.info();
        log.info('Connection test result for the sync server: database ${info.database}');
        return true;
      }

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

  static const String _testBuildRefusal = 'A test build syncs only with a test bucket or a test sync server';

  /// A test build syncs only with the test ones (see TestBuild).
  bool _testBuildAllows(String provider) =>
      !TestBuild.on || TestBuild.allows(provider: provider, bucket: syncSetting.s3BucketName.value, serverUrl: syncSetting.syncServerUrl.value);

  /// Create a provider from the latest settings; null for unknown names.
  CloudProvider? _createProvider(String provider) {
    if (_providerFactory != null) {
      return _providerFactory(provider);
    }
    if (provider == 's3') {
      return S3Provider(
        endpoint: syncSetting.s3Endpoint.value,
        accessKey: syncSetting.s3AccessKey.value,
        secretKey: syncSetting.s3SecretKey.value,
        bucketName: syncSetting.s3BucketName.value,
        region: syncSetting.s3Region.value,
        baseKey: syncSetting.s3BaseKey.value,
        useSSL: syncSetting.s3UseSSL.value,
      );
    }
    if (provider == 'webdav') {
      return WebDavProvider(
        serverUrl: syncSetting.webdavServerUrl.value,
        username: syncSetting.webdavUsername.value,
        password: syncSetting.webdavPassword.value,
        remotePath: syncSetting.webdavRemotePath.value,
      );
    }
    return null;
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
