import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
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

  S3Provider({
    required String endpoint,
    required String accessKey,
    required String secretKey,
    required String bucketName,
    required String region,
    String baseKey = '',
    bool useSSL = true,
    Duration timeout = const Duration(seconds: 60),
  })  : _timeout = timeout,
        _endpoint = endpoint,
        _bucketName = bucketName,
        _baseKey = baseKey.isEmpty ? '' : (baseKey.endsWith('/') ? baseKey : '$baseKey/'),
        _client = Minio(
          endPoint: endpoint,
          accessKey: accessKey,
          secretKey: secretKey,
          region: region,
          useSSL: useSSL,
        );

  @override
  String get name => 's3';

  /// The minio client has no time limits of its own, and a request merely
  /// no longer awaited goes on: a sync that stalls would keep the next one
  /// out for good, and an upload could still land after a later sync's.
  /// Each call here is ended when its time is up, its connections closed.
  /// A call waits [_timeout] at most for the service, and a transfer as long
  /// again for every [_bytesPerTimeout] it moves.
  final Duration _timeout;
  static const int _bytesPerTimeout = 2 * 1024 * 1024;

  Duration _transferTime(int bytes) => _timeout * (1 + bytes / _bytesPerTimeout);

  Future<T> _limited<T>(Duration limit, Future<T> Function() call) => _S3Call(limit).run(call);

  Future<void> _put(String key, Uint8List bytes, {Map<String, String>? metadata}) => _limited(
        _transferTime(bytes.length),
        () => _client.putObject(_bucketName, key, Stream.value(bytes), size: bytes.length, metadata: metadata),
      );

  @override
  Future<CloudFile> upload(String data, {bool saveHistory = false}) async {
    Uint8List bytes = Uint8List.fromList(utf8.encode(data));

    // 1. Always upload latest.json (latest version)
    String latestKey = '${_baseKey}latest.json';
    await _put(latestKey, bytes, metadata: {'content-type': 'application/json'});

    // 2. If history is enabled, save additional timestamped file
    String? version;
    if (saveHistory) {
      version = _generateVersion();
      String versionKey = '$_baseKey$version.json';
      await _put(versionKey, bytes, metadata: {
        'content-type': 'application/json',
        'x-jhentai-version': version,
      });
    }

    log.info('Successfully uploaded to S3: $latestKey${saveHistory ? " (with history: $version)" : ""}');

    return CloudFile(
      version: version ?? 'latest',
      modifiedTime: DateTime.now(),
      size: bytes.length,
    );
  }

  @override
  Future<String?> download() async {
    // Always download latest.json
    List<int>? bytes = await getRawObject('latest.json');
    if (bytes == null) {
      return null;
    }

    log.info('Successfully downloaded from S3: ${_baseKey}latest.json');
    return utf8.decode(bytes);
  }

  @override
  Future<String> downloadVersion(String version) async {
    // Download specific history version
    String key = '$_baseKey$version.json';

    List<int> bytes = await _get(key);

    log.info('Successfully downloaded version from S3: $key');
    return utf8.decode(bytes);
  }

  @override
  Future<List<CloudFile>> listVersions() async {
    List<CloudFile> versions = [];

    // List all objects with the base key prefix
    // listObjects returns Stream<ListObjectsResult>, need to get chunks
    var chunks = await _limited(_timeout, () => _client.listObjects(_bucketName, prefix: _baseKey).toList());

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
    await _limited(_timeout, () => _client.removeObject(_bucketName, key));

    log.info('Deleted version from S3: $key');
  }

  @override
  Future<CloudFile?> getFileMetadata() async {
    try {
      String key = '${_baseKey}latest.json';

      var stat = await _limited(_timeout, () => _client.statObject(_bucketName, key, retrieveAcls: false));

      return CloudFile(
        version: 'latest',
        modifiedTime: stat.lastModified ?? DateTime.now(),
        size: stat.size ?? 0,
        etag: stat.etag,
      );
    } on TimeoutException {
      // The service does not answer: the sync stops rather than go on.
      rethrow;
    } on MinioError catch (_) {
      // File doesn't exist (NoSuchKey) or other S3 errors
      // Don't access exception properties to avoid triggering null check issues in minio-dart
      // Most common case: file doesn't exist (first sync)
      return null;
    } catch (_) {
      // Catch any other unexpected errors
      // Don't log exception to avoid potential null check issues
      return null;
    }
  }

  @override
  Future<bool> testConnection() async {
    try {
      // Check if bucket exists
      bool exists = await _limited(_timeout, () => _client.bucketExists(_bucketName));
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

  @override
  Future<void> putRawObject(String key, List<int> bytes) =>
      _put('$_baseKey$key', bytes is Uint8List ? bytes : Uint8List.fromList(bytes));

  /// An object, its time counted from the size the service gives for it.
  Future<List<int>> _get(String fullKey) {
    _S3Call call = _S3Call(_timeout);
    return call.run(() async {
      MinioByteStream stream = await _client.getObject(_bucketName, fullKey);
      call.limit(_transferTime(stream.contentLength ?? 0));
      List<int> result = [];
      await for (List<int> chunk in stream) {
        result.addAll(chunk);
      }
      return result;
    });
  }

  @override
  Future<List<int>?> getRawObject(String key) async {
    String fullKey = '$_baseKey$key';

    try {
      return await _get(fullKey);
    } on MinioS3Error catch (e) {
      /// S3-level error: by far the most common case is NoSuchKey. Only the
      /// runtime type is safe to log - minio-dart error objects can throw on
      /// property access.
      log.debug('S3 getObject miss for $fullKey (${e.runtimeType})');
      return null;
    }
  }

  @override
  Future<List<RemoteObjectInfo>> listRawObjects(String prefix) async {
    List<RemoteObjectInfo> result = [];
    var chunks = await _limited(_timeout, () => _client.listObjects(_bucketName, prefix: '$_baseKey$prefix', recursive: true).toList());
    for (var chunk in chunks) {
      for (var obj in chunk.objects) {
        String? objKey = obj.key;
        if (objKey == null) {
          continue;
        }
        result.add(RemoteObjectInfo(
          key: objKey.replaceFirst(_baseKey, ''),
          size: obj.size ?? 0,
          modifiedTime: obj.lastModified,
        ));
      }
    }
    return result;
  }

  @override
  Future<void> deleteRawObject(String key) async {
    await _limited(_timeout, () => _client.removeObject(_bucketName, '$_baseKey$key'));
  }
}

/// The requests of one S3 call, made through clients of its own, which it
/// ends when its time is up: each request still waited for fails, and its
/// connection is closed, so nothing more of an upload is sent.
class _S3Call {
  _S3Call(Duration limit) {
    this.limit(limit);
  }

  /// Where the requests go, as outside this call (another client in tests).
  final Zone _outside = Zone.current;
  final Set<_S3CallClient> _open = {};
  Timer? _timer;
  Duration _limit = Duration.zero;
  TimeoutException? _ended;

  /// The call ends [limit] from now.
  void limit(Duration limit) {
    _limit = limit;
    _timer?.cancel();
    _timer = Timer(limit, _end);
  }

  Future<T> run<T>(Future<T> Function() call) async {
    try {
      return await http.runWithClient(call, () => _S3CallClient(this, _outside.run(http.Client.new)));
    } finally {
      _timer?.cancel();
    }
  }

  void _end() {
    _ended = TimeoutException('S3 request not done in time', _limit);
    for (_S3CallClient client in _open.toList()) {
      client._end(_ended!);
    }
  }
}

class _S3CallClient extends http.BaseClient {
  _S3CallClient(this._call, this._inner);

  final _S3Call _call;
  final http.Client _inner;
  final Completer<Never> _ending = Completer<Never>();
  StreamController<List<int>>? _body;
  StreamSubscription<List<int>>? _reading;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_call._ended != null) {
      throw _call._ended!;
    }
    _call._open.add(this);
    http.StreamedResponse response = await Future.any([_inner.send(request), _ending.future]);
    StreamController<List<int>> body = _body = StreamController<List<int>>(
      onPause: () => _reading?.pause(),
      onResume: () => _reading?.resume(),
      onCancel: () => _reading?.cancel(),
    );
    body.onListen = () => _reading = response.stream.listen(body.add, onError: body.addError, onDone: body.close);
    return http.StreamedResponse(
      body.stream,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  void _end(TimeoutException error) {
    if (!_ending.isCompleted) {
      _ending.completeError(error);
    }
    _reading?.cancel();
    StreamController<List<int>>? body = _body;
    if (body != null && !body.isClosed) {
      body
        ..addError(error)
        ..close();
    }
    close();
  }

  @override
  void close() {
    _call._open.remove(this);
    _inner.close();
  }
}
