import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/setting/komga_setting.dart';
import 'package:jhentai/src/setting/network_setting.dart';

class KomgaClient {
  KomgaClient({
    required String serverUrl,
    required this.username,
    required this.password,
    required this.apiKey,
    String? connectionId,
  }) : serverUrl = _validateServerUrl(serverUrl),
       connectionId = _resolveConnectionId(
         connectionId: connectionId,
         serverUrl: serverUrl,
         username: username,
         apiKey: apiKey,
       ),
       _dio = Dio(
         BaseOptions(
           baseUrl: _validateServerUrl(serverUrl),
           connectTimeout: Duration(
             milliseconds: networkSetting.connectTimeout.value,
           ),
           receiveTimeout: Duration(
             milliseconds: networkSetting.receiveTimeout.value,
           ),
         ),
       ) {
    _dio.options.headers.addAll(authHeaders);
  }

  factory KomgaClient.fromSetting() {
    return KomgaClient(
      serverUrl: komgaSetting.serverUrl.value,
      username: komgaSetting.username.value,
      password: komgaSetting.password.value,
      apiKey: komgaSetting.apiKey.value,
      connectionId: komgaSetting.connectionId.value,
    );
  }

  static const int _allItemsPageSize = 200;

  final String serverUrl;
  final String username;
  final String password;
  final String apiKey;
  final String connectionId;
  final Dio _dio;
  bool _useLegacySeriesList = false;
  bool _useLegacyBooksList = false;

  Map<String, String> get authHeaders {
    if (apiKey.trim().isNotEmpty) {
      return {'X-API-Key': apiKey.trim()};
    }
    return {
      'Authorization':
          'Basic ${base64Encode(utf8.encode('$username:$password'))}',
    };
  }

  Map<String, String> get imageHeaders => {...authHeaders, 'Accept': 'image/*'};

  String get sourceFingerprint => connectionId;

  String progressRecordKey(String bookId) {
    return 'komga:$connectionId:$bookId';
  }

  String imageCacheKey(String url) {
    return sha1.convert(utf8.encode('$sourceFingerprint|$url')).toString();
  }

  Future<List<KomgaLibrary>> getLibraries() async {
    final Response<dynamic> response = await _dio.get('/api/v1/libraries');
    return (response.data as List<dynamic>)
        .map(
          (dynamic item) =>
              KomgaLibrary.fromJson((item as Map).cast<String, dynamic>()),
        )
        .toList();
  }

  Future<KomgaPageResult<KomgaSeries>> getSeries({
    required String libraryId,
    required int page,
    int size = 40,
    String? search,
    String sort = 'metadata.titleSort,asc',
  }) async {
    if (!_useLegacySeriesList) {
      try {
        final Response<dynamic> response = await _dio.post(
          '/api/v1/series/list',
          queryParameters: {'page': page, 'size': size, 'sort': sort},
          data: {
            'condition': {
              'libraryId': {'operator': 'is', 'value': libraryId},
            },
            if (search != null && search.trim().isNotEmpty)
              'fullTextSearch': search.trim(),
          },
        );
        return _parsePage(response.data, KomgaSeries.fromJson);
      } on DioException catch (e) {
        if (!_shouldUseLegacyListEndpoint(e)) {
          rethrow;
        }
        _useLegacySeriesList = true;
      }
    }

    final Response<dynamic> response = await _dio.get(
      '/api/v1/series',
      queryParameters: {
        'library_id': libraryId,
        'page': page,
        'size': size,
        'sort': sort,
        if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
      },
    );
    return _parsePage(response.data, KomgaSeries.fromJson);
  }

  Future<List<KomgaSeries>> getAllSeries({
    required String libraryId,
    bool descending = true,
  }) {
    return _loadAllPages<KomgaSeries>(
      (int page) => getSeries(
        libraryId: libraryId,
        page: page,
        size: _allItemsPageSize,
        sort: 'createdDate,${descending ? 'desc' : 'asc'}',
      ),
    );
  }

  Future<KomgaPageResult<KomgaBook>> getBooks({
    required String seriesId,
    required int page,
    int size = 40,
    String sort = 'metadata.numberSort,asc',
  }) async {
    if (!_useLegacyBooksList) {
      try {
        final Response<dynamic> response = await _dio.post(
          '/api/v1/books/list',
          queryParameters: {'page': page, 'size': size, 'sort': sort},
          data: {
            'condition': {
              'seriesId': {'operator': 'is', 'value': seriesId},
            },
          },
        );
        return _parsePage(response.data, KomgaBook.fromJson);
      } on DioException catch (e) {
        if (!_shouldUseLegacyListEndpoint(e)) {
          rethrow;
        }
        _useLegacyBooksList = true;
      }
    }

    final Response<dynamic> response = await _dio.get(
      '/api/v1/series/$seriesId/books',
      queryParameters: {'page': page, 'size': size, 'sort': sort},
    );
    return _parsePage(response.data, KomgaBook.fromJson);
  }

  Future<KomgaPageResult<KomgaBook>> getLibraryBooks({
    required String libraryId,
    required int page,
    int size = 40,
    String sort = 'createdDate,desc',
  }) async {
    if (!_useLegacyBooksList) {
      try {
        final Response<dynamic> response = await _dio.post(
          '/api/v1/books/list',
          queryParameters: {'page': page, 'size': size, 'sort': sort},
          data: {
            'condition': {
              'libraryId': {'operator': 'is', 'value': libraryId},
            },
          },
        );
        return _parsePage(response.data, KomgaBook.fromJson);
      } on DioException catch (e) {
        if (!_shouldUseLegacyListEndpoint(e)) {
          rethrow;
        }
        _useLegacyBooksList = true;
      }
    }

    final Response<dynamic> response = await _dio.get(
      '/api/v1/books',
      queryParameters: {
        'library_id': libraryId,
        'page': page,
        'size': size,
        'sort': sort,
      },
    );
    return _parsePage(response.data, KomgaBook.fromJson);
  }

  Future<List<KomgaBook>> getAllBooks({
    required String libraryId,
    bool descending = true,
  }) {
    return _loadAllPages<KomgaBook>(
      (int page) => getLibraryBooks(
        libraryId: libraryId,
        page: page,
        size: _allItemsPageSize,
        sort: 'createdDate,${descending ? 'desc' : 'asc'}',
      ),
    );
  }

  Future<List<KomgaBook>> getAllReadProgressBooks() {
    return _loadAllPages<KomgaBook>(
      (int page) => _getReadProgressBooks(page: page, size: _allItemsPageSize),
    );
  }

  Future<KomgaPageResult<KomgaBook>> _getReadProgressBooks({
    required int page,
    required int size,
  }) async {
    if (!_useLegacyBooksList) {
      try {
        final Response<dynamic> response = await _dio.post(
          '/api/v1/books/list',
          queryParameters: {'page': page, 'size': size},
          data: {
            'condition': {
              'readStatus': {'operator': 'isNot', 'value': 'UNREAD'},
            },
          },
        );
        return _parsePage(response.data, KomgaBook.fromJson);
      } on DioException catch (e) {
        if (!_shouldUseLegacyListEndpoint(e)) {
          rethrow;
        }
        _useLegacyBooksList = true;
      }
    }

    final Response<dynamic> response = await _dio.get(
      '/api/v1/books',
      queryParameters: {
        'read_status': const <String>['READ', 'IN_PROGRESS'],
        'page': page,
        'size': size,
      },
    );
    return _parsePage(response.data, KomgaBook.fromJson);
  }

  Future<List<KomgaBookPage>> getBookPages(String bookId) async {
    final Response<dynamic> response = await _dio.get(
      '/api/v1/books/$bookId/pages',
    );
    return (response.data as List<dynamic>)
        .map(
          (dynamic item) =>
              KomgaBookPage.fromJson((item as Map).cast<String, dynamic>()),
        )
        .toList();
  }

  Future<void> reportReadProgress(String bookId, int imageIndex) async {
    await _dio.patch(
      '/api/v1/books/$bookId/read-progress',
      data: {'page': imageIndex + 1},
    );
  }

  String seriesThumbnailUrl(String seriesId) {
    return '$serverUrl/api/v1/series/$seriesId/thumbnail';
  }

  String bookThumbnailUrl(String bookId) {
    return '$serverUrl/api/v1/books/$bookId/thumbnail';
  }

  String bookPageUrl(String bookId, int pageNumber) {
    final Uri uri = Uri.parse(
      '$serverUrl/api/v1/books/$bookId/pages/$pageNumber',
    );
    return uri
        .replace(queryParameters: const {'contentNegotiation': 'false'})
        .toString();
  }

  static String friendlyError(Object error) {
    if (error is FormatException) {
      return error.message;
    }
    if (error is DioException) {
      final int? statusCode = error.response?.statusCode;
      if (statusCode == 401 || statusCode == 403) {
        return 'Komga authentication failed ($statusCode)';
      }
      if (statusCode != null) {
        return 'Komga request failed (HTTP $statusCode)';
      }
      return error.message ?? error.type.name;
    }
    return error.toString();
  }

  static String _validateServerUrl(String rawUrl) {
    final String normalized = KomgaSetting.normalizeServerUrl(rawUrl);
    final Uri? uri = Uri.tryParse(normalized);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const FormatException(
        'Komga server URL must start with http:// or https://',
      );
    }
    return normalized;
  }

  static String _resolveConnectionId({
    required String? connectionId,
    required String serverUrl,
    required String username,
    required String apiKey,
  }) {
    final String configuredConnectionId = connectionId?.trim() ?? '';
    if (configuredConnectionId.isNotEmpty) {
      return configuredConnectionId;
    }
    return KomgaSetting.legacyConnectionId(
      serverUrl: serverUrl,
      username: username,
      apiKey: apiKey,
    );
  }

  static bool _shouldUseLegacyListEndpoint(DioException error) {
    return error.response?.statusCode == 404 ||
        error.response?.statusCode == 405;
  }

  static KomgaPageResult<T> _parsePage<T>(
    dynamic data,
    T Function(Map<String, dynamic>) converter,
  ) {
    return KomgaPageResult<T>.fromJson(
      (data as Map).cast<String, dynamic>(),
      converter,
    );
  }

  static Future<List<T>> _loadAllPages<T>(
    Future<KomgaPageResult<T>> Function(int page) request,
  ) async {
    final List<T> items = <T>[];
    int nextPage = 0;

    while (true) {
      final KomgaPageResult<T> result = await request(nextPage);
      items.addAll(result.content);
      if (result.isLast || result.content.isEmpty) {
        return items;
      }

      final int reportedNextPage = result.page + 1;
      nextPage = reportedNextPage > nextPage ? reportedNextPage : nextPage + 1;
    }
  }
}
