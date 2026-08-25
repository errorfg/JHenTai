import 'package:dio/dio.dart';
import 'package:jhentai/src/setting/eh2telegraph_setting.dart';

/// eh2telegraph 内网同步接口客户端：`GET /health`、`POST /sync {url}`。
class Eh2TelegraphClient {
  Eh2TelegraphClient({
    required String endpoint,
    required String token,
    Dio? dio,
  }) : endpoint = Eh2TelegraphSetting.normalizeEndpoint(endpoint),
       token = token.trim(),
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 15),
               responseType: ResponseType.json,
             ),
           );

  factory Eh2TelegraphClient.fromSetting() => Eh2TelegraphClient(
    endpoint: eh2telegraphSetting.endpoint.value,
    token: eh2telegraphSetting.token.value,
  );

  final String endpoint;
  final String token;
  final Dio _dio;

  Map<String, String> get _authHeaders => {'Authorization': 'Bearer $token'};

  Future<bool> health() async {
    final Response<dynamic> response = await _dio.get<dynamic>(
      '$endpoint/health',
      options: Options(validateStatus: (_) => true),
    );
    return response.statusCode == 200;
  }

  /// 返回服务端确认接受的规范化 URL；被拒绝时抛出 [Eh2TelegraphException]。
  Future<String> sync(String galleryUrl) async {
    final Response<dynamic> response = await _dio.post<dynamic>(
      '$endpoint/sync',
      data: {'url': galleryUrl},
      options: Options(
        headers: _authHeaders,
        contentType: Headers.jsonContentType,
        validateStatus: (_) => true,
      ),
    );
    final dynamic data = response.data;
    if (response.statusCode == 202 && data is Map && data['accepted'] == true) {
      return data['url']?.toString() ?? galleryUrl;
    }
    final String message = data is Map && data['error'] != null
        ? data['error'].toString()
        : 'HTTP ${response.statusCode}';
    throw Eh2TelegraphException(response.statusCode ?? 0, message);
  }
}

class Eh2TelegraphException implements Exception {
  Eh2TelegraphException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'Eh2TelegraphException($statusCode): $message';
}
