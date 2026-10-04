import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/komga/komga_query.dart';
import 'package:jhentai/src/setting/komga_setting.dart';
import 'package:jhentai/src/setting/network_setting.dart';

/// The part of the Komga API that read-progress sync depends on.
abstract interface class KomgaProgressRemote {
  String get connectionId;

  String progressRecordKey(String bookId);

  Future<KomgaBook> getBook(String bookId);

  Future<List<KomgaBook>> getAllReadProgressBooks();

  Future<void> reportReadProgress(String bookId, int imageIndex);

  Future<void> deleteReadProgress(String bookId);
}

class KomgaClient implements KomgaProgressRemote {
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
  static const int defaultPageSize = 50;

  /// Offset paging needs a total order; Komga adds no tiebreaker itself.
  static const List<String> _readProgressSort = <String>[
    'readProgress.readDate,desc',
    'name,asc',
  ];

  final String serverUrl;
  final String username;
  final String password;
  final String apiKey;
  @override
  final String connectionId;
  final Dio _dio;

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

  @override
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

  Future<KomgaPageResult<KomgaSeries>> listSeries(
    KomgaQuery query, {
    required int page,
    int size = defaultPageSize,
  }) async {
    final Response<dynamic> response = await _dio.post(
      '/api/v1/series/list',
      queryParameters: _pageParams(page, size, query.toSortParams()),
      data: query.toRequestBody(),
    );
    return _parsePage(response.data, KomgaSeries.fromJson);
  }

  Future<KomgaPageResult<KomgaBook>> listBooks(
    KomgaQuery query, {
    required int page,
    int size = defaultPageSize,
  }) async {
    final Response<dynamic> response = await _dio.post(
      '/api/v1/books/list',
      queryParameters: _pageParams(page, size, query.toSortParams()),
      data: query.toRequestBody(),
    );
    return _parsePage(response.data, KomgaBook.fromJson);
  }

  Future<KomgaSeries> getSeries(String seriesId) async {
    final Response<dynamic> response = await _dio.get(
      '/api/v1/series/$seriesId',
    );
    return KomgaSeries.fromJson((response.data as Map).cast<String, dynamic>());
  }

  /// First unread book of series with at least one book read and none in
  /// progress.
  Future<KomgaPageResult<KomgaBook>> onDeckBooks({
    String? libraryId,
    int page = 0,
    int size = defaultPageSize,
  }) async {
    final Response<dynamic> response = await _dio.get(
      '/api/v1/books/ondeck',
      queryParameters: {
        'page': page,
        'size': size,
        if (libraryId != null) 'library_id': libraryId,
      },
    );
    return _parsePage(response.data, KomgaBook.fromJson);
  }

  /// Series ordered by creation ([updated] false) or last modification.
  Future<KomgaPageResult<KomgaSeries>> latestSeries({
    required bool updated,
    String? libraryId,
    int page = 0,
    int size = defaultPageSize,
  }) async {
    final Response<dynamic> response = await _dio.get(
      updated ? '/api/v1/series/updated' : '/api/v1/series/new',
      queryParameters: {
        'page': page,
        'size': size,
        'deleted': false,
        if (libraryId != null) 'library_id': libraryId,
      },
    );
    return _parsePage(response.data, KomgaSeries.fromJson);
  }

  /// Next or previous book of the same series by volume number; null at the
  /// ends of the series.
  Future<KomgaBook?> siblingBook(String bookId, {required bool next}) async {
    try {
      final Response<dynamic> response = await _dio.get(
        '/api/v1/books/$bookId/${next ? 'next' : 'previous'}',
      );
      return KomgaBook.fromJson((response.data as Map).cast<String, dynamic>());
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> markSeriesRead(String seriesId) async {
    await _dio.post('/api/v1/series/$seriesId/read-progress');
  }

  Future<void> markSeriesUnread(String seriesId) async {
    await _dio.delete('/api/v1/series/$seriesId/read-progress');
  }

  /// Values available for each filter category, limited to [libraryId].
  Future<KomgaFilterOptions> getFilterOptions({String? libraryId}) async {
    final Map<String, dynamic> scope = <String, dynamic>{
      if (libraryId != null) 'library_id': libraryId,
    };
    Future<List<String>> strings(String path) async {
      final Response<dynamic> response = await _dio.get(
        path,
        queryParameters: scope,
      );
      return (response.data as List<dynamic>).whereType<String>().toList()
        ..sort();
    }

    final Response<dynamic> authors = await _dio.get(
      '/api/v2/authors',
      queryParameters: <String, dynamic>{...scope, 'unpaged': true},
    );
    final List<String> authorNames =
        ((authors.data as Map)['content'] as List<dynamic>)
            .map((dynamic a) => (a as Map)['name'] as String? ?? '')
            .where((String name) => name.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return KomgaFilterOptions(
      authors: authorNames,
      publishers: await strings('/api/v1/publishers'),
      languages: await strings('/api/v1/languages'),
      tags: await strings('/api/v1/tags'),
      genres: await strings('/api/v1/genres'),
    );
  }

  /// Download the original book file. Requires the FILE_DOWNLOAD role.
  Future<void> downloadBookFile(
    String bookId,
    String savePath, {
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    await _dio.download(
      '/api/v1/books/$bookId/file',
      savePath,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
      options: Options(receiveTimeout: Duration.zero),
    );
  }

  @override
  Future<List<KomgaBook>> getAllReadProgressBooks() {
    return _loadAllPages<KomgaBook>(
      (int page) => _getReadProgressBooks(page: page, size: _allItemsPageSize),
    );
  }

  Future<KomgaPageResult<KomgaBook>> _getReadProgressBooks({
    required int page,
    required int size,
  }) async {
    final Response<dynamic> response = await _dio.post(
      '/api/v1/books/list',
      queryParameters: _pageParams(page, size, _readProgressSort),
      data: {
        'condition': {
          'readStatus': {'operator': 'isNot', 'value': 'UNREAD'},
        },
      },
    );
    return _parsePage(response.data, KomgaBook.fromJson);
  }

  @override
  Future<KomgaBook> getBook(String bookId) async {
    return KomgaBook.fromJson(await getBookJson(bookId));
  }

  Future<Map<String, dynamic>> getBookJson(String bookId) async {
    final Response<dynamic> response = await _dio.get('/api/v1/books/$bookId');
    return (response.data as Map).cast<String, dynamic>();
  }

  /// Save one page image as served to the reader (converted to PNG when
  /// Flutter cannot decode the original format).
  Future<void> downloadPageImage(
    String bookId,
    KomgaBookPage page,
    String savePath,
  ) async {
    await _dio.download(
      bookPageUrl(bookId, page.number, mediaType: page.mediaType),
      savePath,
      options: Options(headers: const <String, String>{'Accept': 'image/*'}),
    );
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

  @override
  Future<void> reportReadProgress(String bookId, int imageIndex) async {
    await _dio.patch(
      '/api/v1/books/$bookId/read-progress',
      data: {'page': imageIndex + 1},
    );
  }

  @override
  Future<void> deleteReadProgress(String bookId) async {
    await _dio.delete('/api/v1/books/$bookId/read-progress');
  }

  String seriesThumbnailUrl(String seriesId) {
    return '$serverUrl/api/v1/series/$seriesId/thumbnail';
  }

  String bookThumbnailUrl(String bookId) {
    return '$serverUrl/api/v1/books/$bookId/thumbnail';
  }

  /// Formats Flutter decodes on every platform; other page images are
  /// converted to PNG by the server.
  static bool isDecodableMediaType(String mediaType) =>
      _decodableMediaTypes.contains(mediaType);

  static const Set<String> _decodableMediaTypes = <String>{
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
    'image/bmp',
  };

  String bookPageUrl(String bookId, int pageNumber, {String mediaType = ''}) {
    final Uri uri = Uri.parse(
      '$serverUrl/api/v1/books/$bookId/pages/$pageNumber',
    );
    return uri
        .replace(
          queryParameters: <String, String>{
            'contentNegotiation': 'false',
            if (mediaType.isNotEmpty && !_decodableMediaTypes.contains(mediaType))
              'convert': 'png',
          },
        )
        .toString();
  }

  /// Page thumbnail, resized by Komga to 300px on the longest side.
  String bookPageThumbnailUrl(String bookId, int pageNumber) {
    return '$serverUrl/api/v1/books/$bookId/pages/$pageNumber/thumbnail';
  }

  static String friendlyError(Object error) {
    if (error is FormatException) {
      return error.message;
    }
    if (error is! DioException) {
      return 'komgaRequestError'.trParams(<String, String>{
        'detail': error.toString(),
      });
    }
    final int? statusCode = error.response?.statusCode;
    if (statusCode == 401 &&
        error.requestOptions.headers.containsKey('X-API-Key')) {
      return 'komgaApiKeyRejected'.tr;
    }
    if (statusCode == 401) {
      return 'komgaAuthFailed'.tr;
    }
    // Komga answers 403 when the account lacks a role, such as
    // FILE_DOWNLOAD for book files or PAGE_STREAMING for pages.
    if (statusCode == 403) {
      return 'komgaForbidden'.tr;
    }
    if (statusCode != null) {
      return 'komgaRequestFailed'.trParams(<String, String>{
        'code': '$statusCode',
      });
    }
    final Object? cause = error.error;
    // A failed TLS handshake is not a SocketException, so Dio reports it
    // as an unknown error.
    if (error.type == DioExceptionType.badCertificate ||
        cause is TlsException) {
      return 'komgaSecureConnectionFailed'.tr;
    }
    if (const <DioExceptionType>{
          DioExceptionType.connectionError,
          DioExceptionType.connectionTimeout,
          DioExceptionType.sendTimeout,
          DioExceptionType.receiveTimeout,
        }.contains(error.type) ||
        cause is SocketException) {
      return 'komgaConnectionFailed'.tr;
    }
    return 'komgaRequestError'.trParams(<String, String>{
      'detail': error.message ?? cause?.toString() ?? error.type.name,
    });
  }

  static String _validateServerUrl(String rawUrl) {
    final String normalized = KomgaSetting.normalizeServerUrl(rawUrl);
    final Uri? uri = Uri.tryParse(normalized);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw FormatException('invalidKomgaServerUrl'.tr);
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

  static Map<String, dynamic> _pageParams(
    int page,
    int size,
    List<String> sort,
  ) => <String, dynamic>{
    'page': page,
    'size': size,
    if (sort.isNotEmpty) 'sort': sort,
  };

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
