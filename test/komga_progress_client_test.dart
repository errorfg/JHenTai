import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/network/komga_client.dart';

/// Minimal Komga stand-in that records requests and answers with [respond].
class _FixtureServer {
  _FixtureServer(this.respond);

  final Object? Function(HttpRequest request) respond;
  final List<HttpRequest> requests = <HttpRequest>[];
  late final HttpServer _server;
  late final Future<void> _serving;

  Future<KomgaClient> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _serving = () async {
      await for (final HttpRequest request in _server) {
        requests.add(request);
        await utf8.decoder.bind(request).join();
        final Object? body = respond(request);
        if (body is int) {
          request.response.statusCode = body;
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(body));
        }
        await request.response.close();
      }
    }();
    return KomgaClient(
      serverUrl: 'http://${_server.address.address}:${_server.port}',
      username: '',
      password: '',
      apiKey: 'fixture-key',
      connectionId: 'fixture-connection',
    );
  }

  Future<void> stop() async {
    await _server.close(force: true);
    await _serving;
  }
}

Map<String, dynamic> _book(String id, {Map<String, dynamic>? readProgress}) =>
    <String, dynamic>{
      'id': id,
      'seriesId': 'series',
      'name': id,
      'media': <String, dynamic>{'status': 'READY', 'pagesCount': 20},
      'metadata': <String, dynamic>{'title': id},
      if (readProgress != null) 'readProgress': readProgress,
    };

DioException _dioError(int status, Map<String, dynamic> headers) {
  final RequestOptions options = RequestOptions(
    path: '/api/v1/books',
    headers: headers,
  );
  return DioException(
    requestOptions: options,
    response: Response<dynamic>(requestOptions: options, statusCode: status),
    type: DioExceptionType.badResponse,
  );
}

void main() {
  test('getBook returns the book with its current read progress', () async {
    final _FixtureServer server = _FixtureServer(
      (HttpRequest request) => _book(
        'book-1',
        readProgress: <String, dynamic>{
          'page': 7,
          'completed': false,
          'readDate': '2026-10-04T05:00:00Z',
        },
      ),
    );
    final KomgaClient client = await server.start();
    try {
      final KomgaBook book = await client.getBook('book-1');

      expect(server.requests.single.method, 'GET');
      expect(server.requests.single.uri.path, '/api/v1/books/book-1');
      expect(book.readProgress!.page, 7);
      expect(book.readProgress!.readDate, DateTime.utc(2026, 10, 4, 5));
    } finally {
      await server.stop();
    }
  });

  test('deleteReadProgress marks the book unread on the server', () async {
    final _FixtureServer server = _FixtureServer(
      (HttpRequest request) => HttpStatus.noContent,
    );
    final KomgaClient client = await server.start();
    try {
      await client.deleteReadProgress('book-1');

      expect(server.requests.single.method, 'DELETE');
      expect(
        server.requests.single.uri.path,
        '/api/v1/books/book-1/read-progress',
      );
    } finally {
      await server.stop();
    }
  });

  test('the read-progress listing pages in a fixed order', () async {
    final _FixtureServer server = _FixtureServer(
      (HttpRequest request) => <String, dynamic>{
        'content': <dynamic>[_book('book-1')],
        'number': 0,
        'totalPages': 1,
        'last': true,
      },
    );
    final KomgaClient client = await server.start();
    try {
      await client.getAllReadProgressBooks();

      expect(server.requests.single.uri.queryParametersAll['sort'], <String>[
        'readProgress.readDate,desc',
        'name,asc',
      ]);
    } finally {
      await server.stop();
    }
  });

  group('friendlyError', () {
    test('a rejected API key points at the server version', () {
      expect(
        KomgaClient.friendlyError(
          _dioError(401, <String, dynamic>{'X-API-Key': 'key'}),
        ),
        'komgaApiKeyRejected'.tr,
      );
    });

    test('a rejected password keeps the existing message', () {
      expect(
        KomgaClient.friendlyError(
          _dioError(401, <String, dynamic>{'Authorization': 'Basic x'}),
        ),
        'Komga authentication failed (401)',
      );
    });
  });
}
