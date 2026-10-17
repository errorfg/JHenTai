import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/service/isolate_service.dart';

/// One synced item as the sync server holds it.
class RemoteRecord {
  final String kind;
  final String key;

  /// Null for a deletion.
  final String? value;

  /// Canonical UTC time (SyncTimeUtil).
  final String updatedAt;
  final String device;
  final bool deleted;

  const RemoteRecord({
    required this.kind,
    required this.key,
    required this.value,
    required this.updatedAt,
    required this.device,
    required this.deleted,
  });

  factory RemoteRecord.fromRow(SyncRecordData row) => RemoteRecord(
        kind: row.kind,
        key: row.key,
        value: row.deleted ? null : row.value,
        updatedAt: row.updatedAt,
        device: row.device,
        deleted: row.deleted,
      );

  factory RemoteRecord.fromJson(Map<String, dynamic> json) => RemoteRecord(
        kind: json['kind'] as String,
        key: json['key'] as String,
        value: json['value'] as String?,
        updatedAt: json['updatedAt'] as String,
        device: json['device'] as String,
        deleted: json['deleted'] == true || json['deleted'] == 1,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'key': key,
        'value': value,
        'updatedAt': updatedAt,
        'device': device,
        'deleted': deleted,
      };
}

/// Positive when the version (aTime, aDevice) wins over (bTime, bDevice):
/// the later time, and on equal times the larger device id, the same on
/// every device and on the server.
int compareVersions(String aTime, String aDevice, String bTime, String bDevice) {
  int byTime = aTime.compareTo(bTime);
  return byTime != 0 ? byTime : aDevice.compareTo(bDevice);
}

class RecordServerInfo {
  final int protocol;

  /// Changes when the server's database is a different one.
  final String database;

  const RecordServerInfo({required this.protocol, required this.database});
}

class RecordPage {
  final List<RemoteRecord> records;

  /// Cursor for the next pull.
  final int next;
  final bool more;

  const RecordPage({required this.records, required this.next, required this.more});
}

/// A sync server speaking protocol 1 (see sync_server/ in the repository).
abstract class RecordBackend {
  Future<RecordServerInfo> info();

  Future<void> push(List<RemoteRecord> records);

  /// Records written by other devices after [since].
  Future<RecordPage> pull({required int since, required String device, required int limit});
}

class RecordServerException implements Exception {
  final int? status;
  final String message;

  RecordServerException(this.status, this.message);

  @override
  String toString() => status == null ? 'Sync server: $message' : 'Sync server ($status): $message';
}

class HttpRecordBackend implements RecordBackend {
  static const int protocol = 1;

  final Dio _dio;

  HttpRecordBackend({required String url, required String token, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 60),
              receiveTimeout: const Duration(seconds: 90),
            )) {
    _dio.options
      ..baseUrl = normalizeUrl(url)
      ..headers['Authorization'] = 'Bearer $token'
      ..responseType = ResponseType.plain;
  }

  /// 'sync.example.com/' -> 'https://sync.example.com'
  static String normalizeUrl(String url) {
    String trimmed = url.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'https://$trimmed';
    }
    return trimmed;
  }

  @override
  Future<RecordServerInfo> info() async {
    Map<String, dynamic> json = await _send(() => _dio.get<String>('/v1/info'));
    RecordServerInfo info = RecordServerInfo(protocol: json['protocol'] as int, database: json['database'] as String);
    if (info.protocol != protocol) {
      throw RecordServerException(null, 'protocol ${info.protocol} is not supported (this app speaks $protocol)');
    }
    return info;
  }

  @override
  Future<void> push(List<RemoteRecord> records) async {
    String body = await isolateService.jsonEncodeAsync(records.map((r) => r.toJson()).toList());
    await _send(() => _dio.post<String>(
          '/v1/push',
          data: body,
          options: Options(contentType: Headers.jsonContentType),
        ));
  }

  @override
  Future<RecordPage> pull({required int since, required String device, required int limit}) async {
    Map<String, dynamic> json = await _send(() => _dio.get<String>(
          '/v1/pull',
          queryParameters: {'since': since, 'device': device, 'limit': limit},
        ));
    return RecordPage(
      records: (json['records'] as List).map((e) => RemoteRecord.fromJson(Map<String, dynamic>.from(e))).toList(),
      next: json['next'] as int,
      more: json['more'] as bool,
    );
  }

  Future<Map<String, dynamic>> _send(Future<Response<String>> Function() request) async {
    try {
      Response<String> response = await request();
      return Map<String, dynamic>.from(await isolateService.jsonDecodeAsync(response.data ?? '{}'));
    } on DioException catch (e) {
      Response? response = e.response;
      if (response == null) {
        throw RecordServerException(null, e.message ?? e.type.name);
      }
      String message = '${response.data}';
      try {
        message = jsonDecode('${response.data}')['error'] ?? message;
      } catch (_) {}
      throw RecordServerException(response.statusCode, message);
    }
  }
}
