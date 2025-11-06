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

enum SyncDirection { upload, download, none }

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

      // Determine sync direction
      SyncDirection direction = await determineSyncDirection();

      log.info('Sync direction: $direction');

      if (direction == SyncDirection.upload) {
        // Upload local config
        List<CloudConfig> uploadConfigs = [];
        for (CloudConfigTypeEnum type in selectedTypes) {
          CloudConfig? config = await cloudConfigService.getLocalConfig(type);
          if (config != null) {
            uploadConfigs.add(config);
          }
        }

        if (uploadConfigs.isNotEmpty) {
          await uploadConfig(uploadConfigs);
          await _updateLocalMetadata();
          return SyncResult(true, 'uploadSuccess', direction);
        } else {
          throw Exception('No config to upload');
        }
      } else if (direction == SyncDirection.download) {
        // Download remote config
        List<CloudConfig> downloadedConfigs = await downloadConfig();

        // Filter configs based on selected types
        List<CloudConfig> filteredConfigs = downloadedConfigs.where((config) => selectedTypes.contains(config.type)).toList();

        // Import configs
        for (CloudConfig config in filteredConfigs) {
          await cloudConfigService.importConfig(config);
        }

        await _updateLocalMetadata();
        return SyncResult(true, 'downloadSuccess', direction);
      } else {
        // No sync needed
        return SyncResult(true, 'alreadySynced', direction);
      }
    } catch (e) {
      log.error('Manual sync failed', e);
      return SyncResult(false, e.toString(), SyncDirection.none);
    }
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

  SyncResult(this.success, this.message, this.direction);
}
