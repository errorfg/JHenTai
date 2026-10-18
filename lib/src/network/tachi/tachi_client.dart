import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'tachi_models.dart';

/// The extension host's HTTP API on the loopback interface. Every request
/// carries the token the app chose when it started the host.
class TachiClient {
  TachiClient({required this.port, required this.token, HttpClient? httpClient}) : _http = httpClient ?? HttpClient() {
    // Loopback traffic never goes through the app's proxy.
    _http
      ..findProxy = ((_) => 'DIRECT')
      ..idleTimeout = const Duration(seconds: 30);
  }

  final int port;
  final String token;
  final HttpClient _http;

  /// Extensions answer slowly at times (a site, or the interpreter on iOS);
  /// a request is abandoned after this.
  static const Duration timeout = Duration(minutes: 2);

  Map<String, String> get authHeaders => <String, String>{'Authorization': 'Bearer $token'};

  Uri _uri(String path, [Map<String, String>? query]) => Uri(scheme: 'http', host: '127.0.0.1', port: port, path: path, queryParameters: query);

  Future<dynamic> _send(String method, String path, {Object? body, Map<String, String>? query}) async {
    final HttpClientRequest request = await _http.openUrl(method, _uri(path, query));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) {
      final List<int> bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final HttpClientResponse response = await request.close().timeout(timeout);
    final String text = await utf8.decodeStream(response).timeout(timeout);
    final dynamic json = text.isEmpty ? null : jsonDecode(text);
    if (response.statusCode != 200) {
      final Map<String, dynamic> error = json is Map<String, dynamic> ? json : const <String, dynamic>{};
      throw TachiHostException(
        error['error'] as String? ?? 'HTTP ${response.statusCode}',
        kind: error['kind'] as String?,
        httpCode: (error['httpCode'] as num?)?.toInt(),
      );
    }
    return json;
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, Object?> body) async => (await _send('POST', path, body: body)) as Map<String, dynamic>;

  Future<bool> ping() async {
    try {
      final dynamic json = await _send('GET', '/ping').timeout(const Duration(seconds: 3));
      return json is Map && json['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> configure({required String proxy, String? userAgent}) => _post('/config', <String, Object?>{'proxy': proxy, if (userAgent != null) 'userAgent': userAgent});

  Future<List<TachiExtension>> extensions() async {
    final Map<String, dynamic> json = (await _send('GET', '/extensions')) as Map<String, dynamic>;
    return (json['extensions'] as List).map((dynamic e) => TachiExtension.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Installs the APK at [path]; the host keeps its own copy.
  Future<TachiExtension> install(String path) async => TachiExtension.fromJson(await _post('/extensions/install', <String, Object?>{'path': path}));

  Future<void> uninstall(String pkg) => _post('/extensions/uninstall', <String, Object?>{'pkg': pkg});

  Uri iconUri(String pkg) => _uri('/extensions/icon', <String, String>{'pkg': pkg});

  TachiMangasPage _page(Map<String, dynamic> json) => TachiMangasPage(
        (json['mangas'] as List).map((dynamic m) => TachiManga.fromJson(m as Map<String, dynamic>)).toList(),
        json['hasNextPage'] as bool? ?? false,
      );

  Future<TachiMangasPage> popular(String source, int page) async => _page(await _post('/source/popular', <String, Object?>{'source': source, 'page': page}));

  Future<TachiMangasPage> latest(String source, int page) async => _page(await _post('/source/latest', <String, Object?>{'source': source, 'page': page}));

  Future<TachiMangasPage> search(String source, int page, String query, {List<TachiFilter>? filters}) async => _page(
        await _post('/source/search', <String, Object?>{
          'source': source,
          'page': page,
          'query': query,
          if (filters != null) 'filters': TachiFilter.listToJson(filters),
        }),
      );

  Future<List<TachiFilter>> filters(String source) async => TachiFilter.listFromJson((await _post('/source/filters', <String, Object?>{'source': source}))['filters'] as List);

  Future<TachiManga> details(String source, TachiManga manga) async => TachiManga.fromJson(await _post('/manga/details', <String, Object?>{'source': source, 'manga': manga.toJson()}));

  Future<List<TachiChapter>> chapters(String source, TachiManga manga) async =>
      ((await _post('/manga/chapters', <String, Object?>{'source': source, 'manga': manga.toJson()}))['chapters'] as List).map((dynamic c) => TachiChapter.fromJson(c as Map<String, dynamic>)).toList();

  Future<String> webUrl(String source, TachiManga manga) async => (await _post('/manga/web-url', <String, Object?>{'source': source, 'manga': manga.toJson()}))['url'] as String;

  Future<List<TachiPage>> pages(String source, TachiChapter chapter) async =>
      ((await _post('/chapter/pages', <String, Object?>{'source': source, 'chapter': chapter.toJson()}))['pages'] as List).map((dynamic p) => TachiPage.fromJson(p as Map<String, dynamic>)).toList();

  Future<List<TachiPreference>> preferences(String source) async =>
      ((await _post('/source/preferences', <String, Object?>{'source': source}))['preferences'] as List).map((dynamic p) => TachiPreference(p as Map<String, dynamic>)).toList();

  Future<List<TachiPreference>> setPreference(String source, String key, Object value) async =>
      ((await _post('/source/preferences/set', <String, Object?>{'source': source, 'key': key, 'value': value}))['preferences'] as List).map((dynamic p) => TachiPreference(p as Map<String, dynamic>)).toList();

  /// Everything [source] keeps in its preferences, typed (see the host's
  /// PreferenceStore).
  Future<Map<String, dynamic>> preferenceStore(String source) async => (await _post('/source/preference-store', <String, Object?>{'source': source}))['values'] as Map<String, dynamic>;

  Future<void> setPreferenceStore(String source, Map<String, dynamic> values) => _post('/source/preference-store/set', <String, Object?>{'source': source, 'values': values});

  Future<void> clearCookies() => _post('/cookies/clear', const <String, Object?>{});

  /// The host's cookies for [url], each `{"url", "setCookie"}`.
  Future<List<dynamic>> cookies(String url) async => (await _post('/cookies/get', <String, Object?>{'url': url}))['cookies'] as List;

  Future<void> importCookies(List<dynamic> cookies) => _post('/cookies/import', <String, Object?>{'cookies': cookies});

  /// Where [source]'s site is and the user agent it uses.
  Future<({String url, String? userAgent})> sourceWeb(String source) async {
    final Map<String, dynamic> json = await _post('/source/web', <String, Object?>{'source': source});
    return (url: json['url'] as String, userAgent: json['userAgent'] as String?);
  }

  /// Commands for the browser engine the app lends the host (see
  /// tachi_browser.dart); waits up to [wait] for some.
  Future<List<dynamic>> browserCommands({Duration wait = const Duration(seconds: 25)}) async =>
      ((await _send('GET', '/browser/poll', query: <String, String>{'wait': '${wait.inMilliseconds}'})) as Map<String, dynamic>)['commands'] as List;

  Future<void> browserEvents(List<Object?> events) => _post('/browser/events', <String, Object?>{'events': events});

  /// A page image through the source (its headers and interceptors apply).
  Uri imageUri(String source, {String? imageUrl, String pageUrl = '', int index = 0}) => _uri('/image', <String, String>{
        'source': source,
        if (imageUrl != null) 'url': imageUrl,
        if (pageUrl.isNotEmpty) 'page': pageUrl,
        'index': '$index',
      });

  Uri coverUri(String source, String url) => _uri('/cover', <String, String>{'source': source, 'url': url});

  Future<Uint8List> bytes(Uri uri) async {
    final HttpClientRequest request = await _http.getUrl(uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final HttpClientResponse response = await request.close().timeout(timeout);
    final BytesBuilder builder = BytesBuilder(copy: false);
    await response.forEach(builder.add).timeout(timeout);
    if (response.statusCode != 200) {
      throw TachiHostException('HTTP ${response.statusCode}: ${utf8.decode(builder.takeBytes(), allowMalformed: true)}');
    }
    return builder.takeBytes();
  }

  void close() => _http.close(force: true);
}
