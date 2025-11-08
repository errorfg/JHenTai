import 'dart:convert';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:minio/minio.dart';

/// S3-compatible 云存储提供商实现
/// 支持 Cloudflare R2, AWS S3, MinIO 等 S3 兼容的存储服务
class S3Provider implements CloudProvider {
  final Minio _client;
  final String _endpoint;
  final String _bucketName;
  final String _baseKey; // Object key prefix (e.g., "jhentai-sync/")
  final bool _enabled;

  S3Provider({
    required String endpoint,
    required String accessKey,
    required String secretKey,
    required String bucketName,
    required String region,
    String baseKey = '',
    bool enabled = false,
    bool useSSL = true,
  })  : _endpoint = endpoint,
        _bucketName = bucketName,
        _baseKey = baseKey.isEmpty ? '' : (baseKey.endsWith('/') ? baseKey : '$baseKey/'),
        _enabled = enabled,
        _client = Minio(
          endPoint: endpoint,
          accessKey: accessKey,
          secretKey: secretKey,
          region: region,
          useSSL: useSSL,
        );

  @override
  String get name => 's3';

  @override
  bool get isEnabled => _enabled;

  @override
  Future<CloudFile> upload(String data, {bool saveHistory = false}) async {
    Uint8List bytes = Uint8List.fromList(utf8.encode(data));

    // 1. Always upload latest.json (latest version)
    String latestKey = '${_baseKey}latest.json';
    await _client.putObject(
      _bucketName,
      latestKey,
      Stream.value(bytes),
      size: bytes.length,
      metadata: {'content-type': 'application/json'},
    );

    // 2. If history is enabled, save additional timestamped file
    String? version;
    if (saveHistory) {
      version = _generateVersion();
      String versionKey = '$_baseKey$version.json';
      await _client.putObject(
        _bucketName,
        versionKey,
        Stream.value(bytes),
        size: bytes.length,
        metadata: {
          'content-type': 'application/json',
          'x-jhentai-version': version,
        },
      );
    }

    log.info('Successfully uploaded to S3: $latestKey${saveHistory ? " (with history: $version)" : ""}');

    return CloudFile(
      version: version ?? 'latest',
      modifiedTime: DateTime.now(),
      size: bytes.length,
    );
  }

  @override
  Future<String> download() async {
    // Always download latest.json
    String key = '${_baseKey}latest.json';

    var stream = await _client.getObject(_bucketName, key);
    List<int> bytes = await stream.expand((chunk) => chunk).toList();

    log.info('Successfully downloaded from S3: $key');
    return utf8.decode(bytes);
  }

  @override
  Future<String> downloadVersion(String version) async {
    // Download specific history version
    String key = '$_baseKey$version.json';

    var stream = await _client.getObject(_bucketName, key);
    List<int> bytes = await stream.expand((chunk) => chunk).toList();

    log.info('Successfully downloaded version from S3: $key');
    return utf8.decode(bytes);
  }

  @override
  Future<List<CloudFile>> listVersions() async {
    List<CloudFile> versions = [];

    // List all objects with the base key prefix
    // listObjects returns Stream<ListObjectsResult>, need to get chunks
    var chunks = await _client.listObjects(_bucketName, prefix: _baseKey).toList();

    // Regular expression to match timestamp format: yyyyMMddHHmmss.json
    final versionPattern = RegExp(r'^\d{14}\.json$');

    // Iterate through all chunks and their objects
    for (var chunk in chunks) {
      for (var obj in chunk.objects) {
        // Each object has key, lastModified, size, eTag properties
        String? objKey = obj.key;
        if (objKey != null) {
          // Extract filename from key (remove base key prefix)
          String fileName = objKey.replaceFirst(_baseKey, '');

          // Only process timestamp format files, skip latest.json
          if (versionPattern.hasMatch(fileName)) {
            String version = fileName.replaceFirst('.json', '');

            versions.add(CloudFile(
              version: version,
              modifiedTime: obj.lastModified ?? DateTime.now(),
              size: obj.size ?? 0,
              etag: obj.eTag,
            ));
          }
        }
      }
    }

    // Sort by version (timestamp) in descending order (newest first)
    versions.sort((a, b) => b.version.compareTo(a.version));

    log.info('Found ${versions.length} history versions in S3');
    return versions;
  }

  @override
  Future<void> deleteVersion(String version) async {
    String key = '$_baseKey$version.json';
    await _client.removeObject(_bucketName, key);

    log.info('Deleted version from S3: $key');
  }

  @override
  Future<CloudFile?> getFileMetadata() async {
    try {
      String key = '${_baseKey}latest.json';

      var stat = await _client.statObject(_bucketName, key);

      return CloudFile(
        version: 'latest',
        modifiedTime: stat.lastModified ?? DateTime.now(),
        size: stat.size ?? 0,
        etag: stat.etag,
      );
    } catch (e) {
      log.error('Failed to get file metadata from S3', e);
      return null;
    }
  }

  @override
  Future<bool> testConnection() async {
    try {
      // Check if bucket exists
      bool exists = await _client.bucketExists(_bucketName);
      if (!exists) {
        log.warning('S3 bucket does not exist: $_bucketName');
        return false;
      }

      log.info('S3 connection test successful');
      return true;
    } catch (e) {
      log.error('S3 connection test failed', e);
      return false;
    }
  }

  /// Generate version string in format yyyyMMddHHmmss
  String _generateVersion() {
    return DateFormat('yyyyMMddHHmmss').format(DateTime.now());
  }
}
