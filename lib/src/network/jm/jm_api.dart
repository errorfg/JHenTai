import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'jm_crypto.dart';
import 'jm_image.dart';
import 'jm_models.dart';

/// Client of the JM mobile API.
///
/// The domain list comes from [apiDomains] (preferred first); requests move
/// on to the next domain when one is unreachable. On first use the client
/// asks the domain servers for the current list (reported through
/// [onApiDomainsDiscovered]) and fetches the session cookies from
/// `/setting`: album requests without them may be redirected to a
/// placeholder album. A logged-in account's cookies, from [login], are
/// sent on top of those.
class JmApi {
  JmApi({
    required Dio dio,
    required this.apiDomains,
    this.onApiDomainsDiscovered,
    this.accountCookie,
    this.discoverDomains = true,
  }) : _dio = dio;

  static const List<String> builtInApiDomains = <String>[
    'www.cdnhjk.net',
    'www.cdngwc.cc',
    'www.cdngwc.net',
    'www.cdngwc.club',
  ];

  static const List<String> imageDomains = <String>[
    'cdn-msp.jmapiproxy1.cc',
    'cdn-msp.jmapiproxy2.cc',
    'cdn-msp2.jmapiproxy2.cc',
    'cdn-msp3.jmapiproxy2.cc',
    'cdn-msp.jmapinodeudzn.net',
    'cdn-msp3.jmapinodeudzn.net',
  ];

  static const List<String> _domainServers = <String>[
    'https://rup4a04-c01.tos-ap-southeast-1.bytepluses.com/newsvr-2025.txt',
    'https://rup4a04-c02.tos-cn-hongkong.bytepluses.com/newsvr-2025.txt',
    'https://rup4a04-c03.tos-cn-beijing.bytepluses.com.cn/newsvr-2025.txt',
  ];

  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 9; V1938CT Build/PQ3A.190705.11211812; wv) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
      'Chrome/91.0.4472.114 Safari/537.36';

  static const int searchPageSize = 80;

  final Dio _dio;
  final List<String> Function() apiDomains;
  final void Function(List<String> domains)? onApiDomainsDiscovered;

  /// Cookie header of the logged-in account, as returned by [login]; empty
  /// when logged out.
  final String Function()? accountCookie;
  final bool discoverDomains;

  Future<void>? _ready;
  Map<String, String> _sessionCookies = <String, String>{};
  String? _workingDomain;
  final Map<int, int> _scrambleIds = <int, int>{};

  /// Headers for image requests.
  static Map<String, String> imageHeaders(String apiDomain) => <String, String>{
    'user-agent': userAgent,
    'Referer': 'https://$apiDomain/',
    'X-Requested-With': 'com.JMComic3.app',
  };

  String get currentApiDomain => _workingDomain ?? _orderedDomains().first;

  /// Forgets the domain that last worked and its session, so the next
  /// request starts again from the first of [apiDomains]; called after the
  /// user picks another line.
  void resetApiDomain() {
    _workingDomain = null;
    _ready = null;
  }

  Future<JmSearchResult> search(
    String query, {
    int page = 1,
    String order = 'mr',
  }) async {
    final dynamic data = await _getJson('/search', <String, dynamic>{
      'search_query': query,
      'page': page,
      'o': order,
      'main_tag': 0,
    });
    return JmSearchResult.fromJson(_map(data));
  }

  /// Logs in with a JM account. The returned cookie header is what
  /// [accountCookie] should give from then on.
  Future<({JmUser user, String cookie})> login(
    String username,
    String password,
  ) async {
    final ({dynamic data, Headers headers}) response = await _requestJson(
      '/login',
      const <String, dynamic>{},
      form: <String, dynamic>{'username': username, 'password': password},
    );
    final Map<String, dynamic> data = _map(response.data);
    final Map<String, String> cookies = _cookiesOf(response.headers);
    // The session is the AVS cookie; logging in again may leave it out of
    // Set-Cookie, but the response always carries it as `s`.
    final String session = '${data['s'] ?? ''}';
    if (session.isNotEmpty) {
      cookies['AVS'] = session;
    }
    return (user: JmUser.fromJson(data), cookie: _cookieHeader(cookies));
  }

  /// The newest albums of every category.
  Future<JmSearchResult> latest({int page = 1}) async {
    final dynamic data = await _getJson('/categories/filter', <String, dynamic>{
      'page': page,
      'order': '',
      'c': '0',
      'o': 'mr',
    });
    return JmSearchResult.fromJson(_map(data));
  }

  Future<JmAlbum> album(int id) async {
    final Map<String, dynamic> data = _map(
      await _getJson('/album', <String, dynamic>{'id': id}),
    );
    if (data['name'] == null) {
      throw JmApiException('Album $id not found');
    }
    return JmAlbum.fromJson(data);
  }

  Future<JmChapter> chapter(int id) async {
    final Map<String, dynamic> data = _map(
      await _getJson('/chapter', <String, dynamic>{'id': id}),
    );
    if (data['name'] == null) {
      throw JmApiException('Chapter $id not found');
    }
    return JmChapter.fromJson(data);
  }

  /// Threshold below which chapters are stored unscrambled.
  Future<int> scrambleId(int chapterId) async {
    final int? cached = _scrambleIds[chapterId];
    if (cached != null) {
      return cached;
    }
    final String html =
        await _getText('/chapter_view_template', <String, dynamic>{
          'id': chapterId,
          'mode': 'vertical',
          'page': 0,
          'app_img_shunt': 1,
          'express': 'off',
          'v': _now(),
        }, secret: JmCrypto.templateTokenSecret);
    final RegExpMatch? match = RegExp(
      r'var scramble_id = (\d+);',
    ).firstMatch(html);
    final int id = match == null
        ? JmImage.defaultScrambleId
        : int.parse(match.group(1)!);
    _scrambleIds[chapterId] = id;
    return id;
  }

  Future<List<JmComment>> comments(int albumId, {int page = 1}) async {
    final Map<String, dynamic> data = _map(
      await _getJson('/forum', <String, dynamic>{
        'mode': 'manhua',
        'aid': albumId,
        'page': page,
      }),
    );
    return (data['list'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((Map m) => JmComment.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// The current API domains according to the JM domain servers, or null
  /// when none answered.
  Future<List<String>?> fetchLatestApiDomains() {
    // The first server that answers wins; failures only count down.
    final Completer<List<String>?> result = Completer<List<String>?>();
    int pending = _domainServers.length;
    for (final String url in _domainServers) {
      _fetchDomainList(url).then(
        (List<String> domains) {
          if (!result.isCompleted) {
            result.complete(domains);
          }
        },
        onError: (Object _) {
          if (--pending == 0 && !result.isCompleted) {
            result.complete(null);
          }
        },
      );
    }
    return result.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    );
  }

  Future<List<String>> _fetchDomainList(String url) async {
    final Response<List<int>> response = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    String text = utf8.decode(
      response.data ?? const <int>[],
      allowMalformed: true,
    );
    // The file starts with a few non-ASCII bytes.
    while (text.isNotEmpty && text.codeUnitAt(0) > 127) {
      text = text.substring(1);
    }
    final Map<String, dynamic> json = _map(
      jsonDecode(
        JmCrypto.decrypt(text, '', secret: JmCrypto.domainServerSecret),
      ),
    );
    final List<String> servers = (json['Server'] as List? ?? const <dynamic>[])
        .map((dynamic s) => '$s')
        .where((String s) => s.isNotEmpty)
        .toList();
    if (servers.isEmpty) {
      throw const FormatException('No JM domains');
    }
    return servers;
  }

  /// Runs [_prepare] once; a failed attempt is retried on the next request.
  Future<void> _ensureReady() => _ready ??= () async {
    try {
      await _prepare();
    } catch (_) {
      _ready = null;
      rethrow;
    }
  }();

  Future<void> _prepare() async {
    if (discoverDomains) {
      final List<String>? latest = await fetchLatestApiDomains();
      if (latest != null) {
        onApiDomainsDiscovered?.call(latest);
      }
    }
    final ({String body, Headers headers}) response = await _send(
      '/setting',
      const <String, dynamic>{},
    );
    _sessionCookies = _cookiesOf(response.headers);
  }

  Future<dynamic> _getJson(String path, Map<String, dynamic> query) async =>
      (await _requestJson(path, query)).data;

  /// Sends a request and decrypts its `data`; [form] makes it a POST.
  Future<({dynamic data, Headers headers})> _requestJson(
    String path,
    Map<String, dynamic> query, {
    Map<String, dynamic>? form,
  }) async {
    await _ensureReady();
    final int ts = _now();
    final ({String body, Headers headers}) response = await _send(
      path,
      query,
      ts: ts,
      form: form,
    );
    final Map<String, dynamic> body = _map(jsonDecode(response.body));
    if (_int(body['code']) != 200) {
      throw JmApiException('${body['errorMsg'] ?? 'code ${body['code']}'}');
    }
    final dynamic data = body['data'];
    return (
      data: data is String && data.isNotEmpty
          ? jsonDecode(JmCrypto.decrypt(data, '$ts'))
          : data,
      headers: response.headers,
    );
  }

  Future<String> _getText(
    String path,
    Map<String, dynamic> query, {
    required String secret,
  }) async {
    await _ensureReady();
    return (await _send(path, query, secret: secret)).body;
  }

  /// Tries each API domain in turn, starting with the one that last worked.
  ///
  /// Bodies are read as bytes: the API sends `Content-Type:
  /// application/json; charset=utf-8;`, whose trailing `;` Dio's media type
  /// parser rejects.
  Future<({String body, Headers headers})> _send(
    String path,
    Map<String, dynamic> query, {
    int? ts,
    String secret = JmCrypto.tokenSecret,
    Map<String, dynamic>? form,
  }) async {
    final String cookie = _cookieHeader(<String, String>{
      ..._sessionCookies,
      ..._parseCookieHeader(accountCookie?.call() ?? ''),
    });
    Object? lastError;
    for (final String domain in _orderedDomains()) {
      final int requestTs = ts ?? _now();
      final Options options = Options(
        responseType: ResponseType.bytes,
        contentType: form == null ? null : Headers.formUrlEncodedContentType,
        headers: <String, dynamic>{
          'user-agent': userAgent,
          ...JmCrypto.tokenHeaders(requestTs, secret: secret),
          if (cookie.isNotEmpty) HttpHeaders.cookieHeader: cookie,
        },
      );
      try {
        final Response<List<int>> response = form == null
            ? await _dio.get<List<int>>(
                'https://$domain$path',
                queryParameters: query,
                options: options,
              )
            : await _dio.post<List<int>>(
                'https://$domain$path',
                queryParameters: query,
                data: form,
                options: options,
              );
        _workingDomain = domain;
        return (
          body: utf8.decode(
            response.data ?? const <int>[],
            allowMalformed: true,
          ),
          headers: response.headers,
        );
      } on DioException catch (e) {
        final int? status = e.response?.statusCode;
        // A 4xx other than 403 is about the request, not the domain; the
        // body usually says why (e.g. a refused login answers 401).
        if (status != null && status < 500 && status != 403) {
          final String? message = _errorMessageOf(e.response?.data);
          if (message != null) {
            throw JmApiException(message);
          }
          rethrow;
        }
        lastError = e;
      }
    }
    throw lastError ?? const JmApiException('No JM API domain configured');
  }

  List<String> _orderedDomains() {
    final List<String> configured = apiDomains();
    final List<String> domains = configured.isEmpty
        ? builtInApiDomains
        : configured;
    final String? working = _workingDomain;
    if (working == null || !domains.contains(working)) {
      return domains;
    }
    return <String>[working, ...domains.where((String d) => d != working)];
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static String? _errorMessageOf(dynamic body) {
    try {
      final dynamic json = jsonDecode(
        body is List<int> ? utf8.decode(body, allowMalformed: true) : '$body',
      );
      final String message = json is Map ? '${json['errorMsg'] ?? ''}' : '';
      return message.isEmpty ? null : message;
    } on FormatException {
      return null;
    }
  }

  static Map<String, String> _cookiesOf(Headers headers) =>
      _parseCookieHeader(
        (headers[HttpHeaders.setCookieHeader] ?? const <String>[])
            .map((String c) => c.split(';').first)
            .join('; '),
      );

  static Map<String, String> _parseCookieHeader(String header) =>
      <String, String>{
        for (final String pair in header.split(';'))
          if (pair.contains('='))
            pair.substring(0, pair.indexOf('=')).trim():
                pair.substring(pair.indexOf('=') + 1).trim(),
      };

  static String _cookieHeader(Map<String, String> cookies) => cookies.entries
      .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
      .join('; ');

  static int _int(dynamic value) =>
      value is int ? value : int.tryParse('${value ?? ''}') ?? 0;

  static Map<String, dynamic> _map(dynamic value) => value is Map
      ? value.cast<String, dynamic>()
      : throw const FormatException('Unexpected JM response');
}
