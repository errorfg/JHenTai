import 'dart:convert';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// WebDAV 云存储提供商实现
class WebDavProvider implements CloudProvider {
  webdav.Client? _client;
  final String serverUrl;
  final String username;
  final String password;
  final String remotePath;
  final bool _enabled;

  WebDavProvider({
    required this.serverUrl,
    required this.username,
    required this.password,
    required this.remotePath,
    bool enabled = false,
  }) : _enabled = enabled;

  @override
  String get name => 'webdav';

  @override
  bool get isEnabled => _enabled;

  /// Initialize WebDAV client
  webdav.Client _initClient() {
    if (serverUrl.isEmpty || username.isEmpty) {
      throw Exception('WebDAV server URL and username are required');
    }

    return webdav.newClient(
      serverUrl,
      user: username,
      password: password,
      debug: false,
    );
  }

  /// Ensure remote directory exists
  Future<void> _ensureRemoteDirectory() async {
    _client ??= _initClient();

    String path = remotePath;
    if (!path.endsWith('/')) {
      path += '/';
    }

    try {
      await _client!.mkdir(path);
    } catch (e) {
      // Directory might already exist, ignore error
      log.debug('Remote directory might already exist: $e');
    }
  }

  @override
  Future<CloudFile> upload(String data, {bool saveHistory = false}) async {
    _client ??= _initClient();
    await _ensureRemoteDirectory();

    Uint8List bytes = Uint8List.fromList(utf8.encode(data));

    // 1. Always upload latest version: JHenTaiConfig.json
    String latestFile = '$remotePath/JHenTaiConfig.json';
    await _client!.write(latestFile, bytes);

    // 2. If history is enabled, save additional timestamped file
    String? version;
    if (saveHistory) {
      version = _generateVersion();
      String versionFile = '$remotePath/JHenTaiConfig-$version.json';
      await _client!.write(versionFile, bytes);
    }

    log.info('Successfully uploaded to WebDAV: $latestFile${saveHistory ? " (with history: $version)" : ""}');

    return CloudFile(
      version: version ?? 'latest',
      modifiedTime: DateTime.now(),
      size: bytes.length,
    );
  }

  @override
  Future<String> download() async {
    _client ??= _initClient();

    // Always download JHenTaiConfig.json
    String file = '$remotePath/JHenTaiConfig.json';
    var bytes = await _client!.read(file);

    log.info('Successfully downloaded from WebDAV: $file');
    return utf8.decode(bytes);
  }

  @override
  Future<String> downloadVersion(String version) async {
    _client ??= _initClient();

    // Download specific history version
    String file = '$remotePath/JHenTaiConfig-$version.json';
    var bytes = await _client!.read(file);

    log.info('Successfully downloaded version from WebDAV: $file');
    return utf8.decode(bytes);
  }

  @override
  Future<List<CloudFile>> listVersions() async {
    _client ??= _initClient();

    List<webdav.File> files = await _client!.readDir(remotePath);
    List<CloudFile> versions = [];

    // Regular expression to match timestamp format: JHenTaiConfig-yyyyMMddHHmmss.json
    final versionPattern = RegExp(r'^JHenTaiConfig-(\d{14})\.json$');

    for (var file in files) {
      if (file.name != null) {
        var match = versionPattern.firstMatch(file.name!);
        if (match != null) {
          String version = match.group(1)!; // Extract timestamp

          versions.add(CloudFile(
            version: version,
            modifiedTime: file.mTime ?? DateTime.now(),
            size: file.size ?? 0,
          ));
        }
      }
    }

    // Sort by version (timestamp) in descending order (newest first)
    versions.sort((a, b) => b.version.compareTo(a.version));

    log.info('Found ${versions.length} history versions in WebDAV');
    return versions;
  }

  @override
  Future<void> deleteVersion(String version) async {
    _client ??= _initClient();

    String file = '$remotePath/JHenTaiConfig-$version.json';
    await _client!.remove(file);

    log.info('Deleted version from WebDAV: $file');
  }

  @override
  Future<CloudFile?> getFileMetadata() async {
    try {
      _client ??= _initClient();

      String file = '$remotePath/JHenTaiConfig.json';

      // Read directory and find the target file
      List<webdav.File> files = await _client!.readDir(remotePath);
      webdav.File? targetFile = files.where((f) => f.path == file).firstOrNull;

      if (targetFile == null) {
        return null;
      }

      return CloudFile(
        version: 'latest',
        modifiedTime: targetFile.mTime ?? DateTime.now(),
        size: targetFile.size ?? 0,
      );
    } catch (e) {
      log.error('Failed to get file metadata from WebDAV', e);
      return null;
    }
  }

  @override
  Future<bool> testConnection() async {
    try {
      _client ??= _initClient();
      await _client!.ping();
      log.info('WebDAV connection test successful');
      return true;
    } catch (e) {
      log.error('WebDAV connection test failed', e);
      return false;
    }
  }

  /// Generate version string in format yyyyMMddHHmmss
  String _generateVersion() {
    return DateFormat('yyyyMMddHHmmss').format(DateTime.now());
  }
}
