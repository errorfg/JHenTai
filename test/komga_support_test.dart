import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/tab_bar_icon.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/pages/layout/desktop/desktop_layout_page_state.dart';
import 'package:jhentai/src/service/cloud_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sync_merger.dart';
import 'package:jhentai/src/setting/komga_setting.dart';

class _SilentLogService extends LogService {
  @override
  void trace(Object msg, [bool withStack = false]) {}
  @override
  void debug(Object msg, [bool withStack = false]) {}
  @override
  void info(Object msg, [bool withStack = false]) {}
  @override
  void warning(Object msg, [Object? error, bool withStack = false]) {}
  @override
  void error(Object msg, [Object? error, StackTrace? stackTrace]) {}
}

void main() {
  group('Komga client identity and authentication', () {
    test('normalizes the URL and builds Basic authentication', () {
      final KomgaClient client = KomgaClient(
        serverUrl: 'https://komga.example.com///',
        username: 'reader',
        password: 'secret',
        apiKey: '',
      );

      expect(client.serverUrl, 'https://komga.example.com');
      expect(client.authHeaders, {
        'Authorization': 'Basic ${base64Encode(utf8.encode('reader:secret'))}',
      });
      expect(
        client.bookPageUrl('book id', 3),
        'https://komga.example.com/api/v1/books/book%20id/pages/3?contentNegotiation=false',
      );
    });

    test(
      'API key takes priority and source-specific progress keys are stable',
      () {
        final KomgaClient first = KomgaClient(
          serverUrl: 'https://komga.example.com',
          username: 'ignored',
          password: 'ignored',
          apiKey: 'key-1',
        );
        final KomgaClient same = KomgaClient(
          serverUrl: 'https://komga.example.com/',
          username: 'ignored',
          password: 'different',
          apiKey: 'key-1',
        );
        final KomgaClient other = KomgaClient(
          serverUrl: 'https://other.example.com',
          username: 'ignored',
          password: 'ignored',
          apiKey: 'key-1',
        );

        expect(first.authHeaders, {'X-API-Key': 'key-1'});
        expect(
          first.progressRecordKey('book-1'),
          same.progressRecordKey('book-1'),
        );
        expect(
          first.progressRecordKey('book-1'),
          isNot(other.progressRecordKey('book-1')),
        );
      },
    );

    test(
      'explicit connection IDs keep progress stable across credential changes',
      () {
        final KomgaClient before = KomgaClient(
          serverUrl: 'https://komga.example.com',
          username: 'reader',
          password: 'old-password',
          apiKey: '',
          connectionId: 'connection-1',
        );
        final KomgaClient after = KomgaClient(
          serverUrl: 'https://komga.example.com',
          username: 'reader-renamed',
          password: 'new-password',
          apiKey: '',
          connectionId: 'connection-1',
        );

        expect(before.progressRecordKey('book-1'), 'komga:connection-1:book-1');
        expect(
          after.progressRecordKey('book-1'),
          before.progressRecordKey('book-1'),
        );
      },
    );
  });

  test(
    'library-wide loaders traverse pages and fall back to legacy books API',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final List<Map<String, dynamic>> seriesBodies = <Map<String, dynamic>>[];
      final List<Uri> seriesUris = <Uri>[];
      final List<Map<String, dynamic>> modernBookBodies =
          <Map<String, dynamic>>[];
      final List<Uri> modernBookUris = <Uri>[];
      final List<Uri> legacyBookUris = <Uri>[];
      int modernBookRequests = 0;
      int legacyBookRequests = 0;

      final Future<void> serving = () async {
        await for (final HttpRequest request in server) {
          final String body = await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType.json;
          expect(request.headers.value('X-API-Key'), 'fixture-key');

          if (request.method == 'POST' &&
              request.uri.path == '/api/v1/series/list') {
            seriesUris.add(request.uri);
            seriesBodies.add((jsonDecode(body) as Map).cast<String, dynamic>());
            final int page = int.parse(
              request.uri.queryParameters['page'] ?? '0',
            );
            request.response.write(
              jsonEncode(
                _pageJson(
                  page: page,
                  last: page == 1,
                  content: <Map<String, dynamic>>[_seriesJson('series-$page')],
                ),
              ),
            );
          } else if (request.method == 'POST' &&
              request.uri.path == '/api/v1/books/list') {
            modernBookRequests++;
            modernBookUris.add(request.uri);
            modernBookBodies.add(
              (jsonDecode(body) as Map).cast<String, dynamic>(),
            );
            request.response.statusCode = HttpStatus.notFound;
            request.response.write('{}');
          } else if (request.method == 'GET' &&
              request.uri.path == '/api/v1/books') {
            legacyBookRequests++;
            legacyBookUris.add(request.uri);
            final int page = int.parse(
              request.uri.queryParameters['page'] ?? '0',
            );
            request.response.write(
              jsonEncode(
                _pageJson(
                  page: page,
                  last: page == 1,
                  content: <Map<String, dynamic>>[_bookJson('book-$page')],
                ),
              ),
            );
          } else {
            request.response.statusCode = HttpStatus.notFound;
            request.response.write('{}');
          }
          await request.response.close();
        }
      }();

      try {
        final KomgaClient client = KomgaClient(
          serverUrl: 'http://${server.address.address}:${server.port}',
          username: '',
          password: '',
          apiKey: 'fixture-key',
          connectionId: 'fixture-connection',
        );

        final List<KomgaSeries> series = await client.getAllSeries(
          libraryId: 'library-1',
        );
        final List<KomgaBook> books = await client.getAllBooks(
          libraryId: 'library-1',
        );

        expect(series.map((KomgaSeries item) => item.id), <String>[
          'series-0',
          'series-1',
        ]);
        expect(books.map((KomgaBook item) => item.id), <String>[
          'book-0',
          'book-1',
        ]);
        expect(seriesBodies, hasLength(2));
        expect(seriesBodies.first['condition'], <String, dynamic>{
          'libraryId': <String, dynamic>{
            'operator': 'is',
            'value': 'library-1',
          },
        });
        expect(
          seriesUris.map((Uri uri) => uri.queryParameters['page']),
          <String>['0', '1'],
        );
        for (final Uri uri in seriesUris) {
          expect(uri.queryParameters['size'], '200');
          expect(uri.queryParameters['sort'], 'createdDate,desc');
        }
        expect(modernBookRequests, 1);
        expect(modernBookBodies, <Map<String, dynamic>>[
          <String, dynamic>{
            'condition': <String, dynamic>{
              'libraryId': <String, dynamic>{
                'operator': 'is',
                'value': 'library-1',
              },
            },
          },
        ]);
        expect(modernBookUris.single.queryParameters['page'], '0');
        expect(modernBookUris.single.queryParameters['size'], '200');
        expect(
          modernBookUris.single.queryParameters['sort'],
          'createdDate,desc',
        );
        expect(legacyBookRequests, 2);
        expect(
          legacyBookUris.map((Uri uri) => uri.queryParameters['page']),
          <String>['0', '1'],
        );
        for (final Uri uri in legacyBookUris) {
          expect(uri.queryParameters['library_id'], 'library-1');
          expect(uri.queryParameters['size'], '200');
          expect(uri.queryParameters['sort'], 'createdDate,desc');
        }
      } finally {
        await server.close(force: true);
        await serving;
      }
    },
  );

  test(
    'read-progress loader covers the account through the modern API',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final List<Map<String, dynamic>> requestBodies = <Map<String, dynamic>>[];
      final List<Uri> requestUris = <Uri>[];

      final Future<void> serving = () async {
        await for (final HttpRequest request in server) {
          final String body = await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType.json;

          if (request.method == 'POST' &&
              request.uri.path == '/api/v1/books/list') {
            requestUris.add(request.uri);
            requestBodies.add(
              (jsonDecode(body) as Map).cast<String, dynamic>(),
            );
            final int page = int.parse(
              request.uri.queryParameters['page'] ?? '0',
            );
            request.response.write(
              jsonEncode(
                _pageJson(
                  page: page,
                  last: page == 1,
                  content: <Map<String, dynamic>>[
                    _bookJson(
                      'progress-$page',
                      readProgress: _readProgressJson(page: page + 1),
                    ),
                  ],
                ),
              ),
            );
          } else {
            request.response.statusCode = HttpStatus.notFound;
            request.response.write('{}');
          }
          await request.response.close();
        }
      }();

      try {
        final KomgaClient client = KomgaClient(
          serverUrl: 'http://${server.address.address}:${server.port}',
          username: '',
          password: '',
          apiKey: 'fixture-key',
          connectionId: 'fixture-connection',
        );

        final List<KomgaBook> books = await client.getAllReadProgressBooks();

        expect(books.map((KomgaBook book) => book.id), <String>[
          'progress-0',
          'progress-1',
        ]);
        expect(books.first.readProgress?.page, 1);
        expect(books.last.readProgress?.page, 2);
        expect(requestBodies, hasLength(2));
        for (final Map<String, dynamic> body in requestBodies) {
          expect(body, <String, dynamic>{
            'condition': <String, dynamic>{
              'readStatus': <String, dynamic>{
                'operator': 'isNot',
                'value': 'UNREAD',
              },
            },
          });
        }
        expect(
          requestUris.map((Uri uri) => uri.queryParameters['page']),
          <String>['0', '1'],
        );
        for (final Uri uri in requestUris) {
          expect(uri.queryParameters['size'], '200');
        }
      } finally {
        await server.close(force: true);
        await serving;
      }
    },
  );

  test(
    'read-progress loader falls back to legacy read-status filters',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final List<Uri> modernUris = <Uri>[];
      final List<Uri> legacyUris = <Uri>[];

      final Future<void> serving = () async {
        await for (final HttpRequest request in server) {
          await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType.json;

          if (request.method == 'POST' &&
              request.uri.path == '/api/v1/books/list') {
            modernUris.add(request.uri);
            request.response.statusCode = HttpStatus.methodNotAllowed;
            request.response.write('{}');
          } else if (request.method == 'GET' &&
              request.uri.path == '/api/v1/books') {
            legacyUris.add(request.uri);
            final int page = int.parse(
              request.uri.queryParameters['page'] ?? '0',
            );
            request.response.write(
              jsonEncode(
                _pageJson(
                  page: page,
                  last: page == 1,
                  content: <Map<String, dynamic>>[
                    _bookJson(
                      'legacy-progress-$page',
                      readProgress: _readProgressJson(page: page + 3),
                    ),
                  ],
                ),
              ),
            );
          } else {
            request.response.statusCode = HttpStatus.notFound;
            request.response.write('{}');
          }
          await request.response.close();
        }
      }();

      try {
        final KomgaClient client = KomgaClient(
          serverUrl: 'http://${server.address.address}:${server.port}',
          username: 'reader',
          password: 'secret',
          apiKey: '',
          connectionId: 'fixture-connection',
        );

        final List<KomgaBook> books = await client.getAllReadProgressBooks();

        expect(modernUris, hasLength(1));
        expect(legacyUris, hasLength(2));
        expect(books.map((KomgaBook book) => book.id), <String>[
          'legacy-progress-0',
          'legacy-progress-1',
        ]);
        expect(
          legacyUris.map((Uri uri) => uri.queryParameters['page']),
          <String>['0', '1'],
        );
        for (final Uri uri in legacyUris) {
          expect(uri.queryParameters.containsKey('library_id'), false);
          expect(uri.queryParameters['size'], '200');
          expect(uri.queryParametersAll['read_status'], <String>[
            'READ',
            'IN_PROGRESS',
          ]);
        }
      } finally {
        await server.close(force: true);
        await serving;
      }
    },
  );

  group('Komga API models', () {
    test('parses detailed books, pages, and optional Komga read progress', () {
      final KomgaBook book = KomgaBook.fromJson({
        'id': 'book-1',
        'seriesId': 'series-1',
        'seriesTitle': 'Series',
        'name': '001.cbz',
        'createdDate': '2026-07-30T10:00:00Z',
        'lastModified': '2026-08-01T11:30:00Z',
        'size': '42 MiB',
        'sizeBytes': 44040192,
        'metadata': {
          'title': 'Volume 1',
          'number': '1',
          'summary': 'Book summary',
          'tags': ['Action', 'Drama'],
          'authors': [
            {'name': 'Writer', 'role': 'writer'},
          ],
        },
        'media': {
          'status': 'READY',
          'mediaType': 'application/zip',
          'mediaProfile': 'DIVINA',
          'comment': 'Ready',
          'pagesCount': 24,
        },
        'readProgress': {
          'page': 18,
          'completed': false,
          'readDate': '2026-08-01T11:20:00Z',
          'created': '2026-07-31T10:00:00Z',
          'lastModified': '2026-08-01T11:20:01Z',
        },
      });
      final KomgaBookPage page = KomgaBookPage.fromJson({
        'number': 1,
        'width': 1200,
        'height': 1800,
        'mediaType': 'image/jpeg',
      });

      expect(book.title, 'Volume 1');
      expect(book.pageCount, 24);
      expect(book.isReadable, true);
      expect(book.createdDate, DateTime.utc(2026, 7, 30, 10));
      expect(book.lastModifiedDate, DateTime.utc(2026, 8, 1, 11, 30));
      expect(book.summary, 'Book summary');
      expect(book.tags, ['Action', 'Drama']);
      expect(book.authors.single.name, 'Writer');
      expect(book.size, '42 MiB');
      expect(book.sizeBytes, 44040192);
      expect(book.mediaProfile, 'DIVINA');
      expect(book.mediaComment, 'Ready');
      expect(book.readProgress, isNotNull);
      expect(book.readProgress!.page, 18);
      expect(book.readProgress!.completed, false);
      expect(book.readProgress!.readDate, DateTime.utc(2026, 8, 1, 11, 20));
      expect(book.readProgress!.createdDate, DateTime.utc(2026, 7, 31, 10));
      expect(
        book.readProgress!.lastModifiedDate,
        DateTime.utc(2026, 8, 1, 11, 20, 1),
      );
      expect(book.readProgress!.deviceId, '');
      expect(book.readProgress!.deviceName, '');
      expect(page.number, 1);
      expect(page.width, 1200);
    });

    test(
      'parses detailed series without consuming Komga progress aggregates',
      () {
        final KomgaSeries series = KomgaSeries.fromJson({
          'id': 'series-1',
          'libraryId': 'library-1',
          'name': 'Series folder',
          'created': '2026-07-29T09:00:00Z',
          'lastModifiedDate': '2026-08-01T12:00:00Z',
          'booksCount': 3,
          'booksReadCount': 2,
          'booksInProgressCount': 1,
          'metadata': {
            'title': 'Series title',
            'summary': 'Series summary',
            'tags': ['Fantasy'],
          },
          'booksMetadata': {
            'authors': [
              {'name': 'Artist', 'role': 'penciller'},
            ],
          },
        });

        expect(series.title, 'Series title');
        expect(series.booksCount, 3);
        expect(series.createdDate, DateTime.utc(2026, 7, 29, 9));
        expect(series.lastModifiedDate, DateTime.utc(2026, 8, 1, 12));
        expect(series.summary, 'Series summary');
        expect(series.tags, ['Fantasy']);
        expect(series.authors.single.role, 'penciller');
      },
    );

    test('parses paginated responses', () {
      final KomgaPageResult<KomgaLibrary> result =
          KomgaPageResult<KomgaLibrary>.fromJson({
            'content': [
              {'id': 'library-1', 'name': 'Manga'},
            ],
            'number': 2,
            'totalPages': 4,
            'last': false,
          }, KomgaLibrary.fromJson);

      expect(result.content.single.name, 'Manga');
      expect(result.page, 2);
      expect(result.isLast, false);
    });
  });

  test('authenticated image headers remain transient', () {
    final GalleryImage image = GalleryImage(
      url: 'https://komga.example.com/page',
      headers: const {'X-API-Key': 'secret'},
    );

    expect(image.toJson().containsKey('headers'), false);
    expect(image.toJson().containsKey('cacheKey'), false);
    expect(GalleryImage.fromJson(image.toJson()).headers, null);
  });

  test('desktop menu keeps the reader source button as its bottom item', () {
    final DesktopLayoutPageState state = DesktopLayoutPageState();

    expect(state.icons.last.name, TabBarIconNameEnum.readerSource);
  });

  test('Komga credentials are represented by the synced setting payload', () {
    final KomgaSetting setting = KomgaSetting();
    setting.applyBeanConfig(
      jsonEncode({
        'serverUrl': 'https://komga.example.com',
        'username': 'reader',
        'password': 'secret',
        'apiKey': 'api-key',
      }),
    );

    final Map<String, dynamic> payload = jsonDecode(setting.toConfigString());
    expect(payload['serverUrl'], 'https://komga.example.com');
    expect(payload['password'], 'secret');
    expect(payload['apiKey'], 'api-key');
    expect(
      payload['connectionId'],
      KomgaSetting.legacyConnectionId(
        serverUrl: 'https://komga.example.com',
        username: 'reader',
        apiKey: 'api-key',
      ),
    );
    expect(CloudConfigTypeEnum.fromCode(9), CloudConfigTypeEnum.komgaSetting);
  });

  test('legacy Komga config keeps the previous progress namespace', () {
    final KomgaSetting setting = KomgaSetting();
    setting.applyBeanConfig(
      jsonEncode({
        'serverUrl': 'https://komga.example.com/',
        'username': 'reader',
        'password': 'secret',
        'apiKey': '',
      }),
    );
    final String legacyFingerprint = sha1
        .convert(utf8.encode('https://komga.example.com|reader'))
        .toString();
    final KomgaClient client = KomgaClient(
      serverUrl: setting.serverUrl.value,
      username: setting.username.value,
      password: setting.password.value,
      apiKey: setting.apiKey.value,
      connectionId: setting.connectionId.value,
    );

    expect(setting.connectionId.value, legacyFingerprint);
    expect(
      client.progressRecordKey('book-1'),
      'komga:$legacyFingerprint:book-1',
    );
  });

  test('Komga config merge uses the newest config timestamp', () async {
    CloudConfig config(String value, DateTime time) => CloudConfig(
      id: -1,
      shareCode: 'local',
      identificationCode: 'local',
      type: CloudConfigTypeEnum.komgaSetting,
      version: '1.0.0',
      config: value,
      ctime: time,
    );

    final MergeConfigResult result = await SyncMerger().mergeConfigType(
      CloudConfigTypeEnum.komgaSetting,
      config('local', DateTime.utc(2026, 8, 2, 10)),
      config('remote', DateTime.utc(2026, 8, 2, 11)),
      DateTime.utc(2026, 8, 2, 11),
      null,
    );

    expect(result.config.config, 'remote');
  });

  group('Komga cloud configuration wiring', () {
    setUp(() {
      log = _SilentLogService();
      appDb = AppDb.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await appDb.close();
    });

    test('exports and imports the full server configuration', () async {
      const String localPayload =
          '{"serverUrl":"https://local.example.com","username":"local","password":"local-pass","apiKey":"","connectionId":"local-connection"}';
      await localConfigService.write(
        configKey: ConfigEnum.komgaSetting,
        value: localPayload,
      );

      final CloudConfig? exported = await CloudConfigService().getLocalConfig(
        CloudConfigTypeEnum.komgaSetting,
      );
      expect(exported, isNotNull);
      expect(exported!.config, localPayload);
      expect(exported.type, CloudConfigTypeEnum.komgaSetting);

      const String remotePayload =
          '{"serverUrl":"https://remote.example.com","username":"","password":"","apiKey":"remote-key","connectionId":"remote-connection"}';
      await CloudConfigService().importConfig(
        CloudConfig(
          id: -1,
          shareCode: 'remote',
          identificationCode: 'remote',
          type: CloudConfigTypeEnum.komgaSetting,
          version: '1.0.0',
          config: remotePayload,
          ctime: DateTime.utc(2026, 8, 2),
        ),
      );

      expect(komgaSetting.serverUrl.value, 'https://remote.example.com');
      expect(komgaSetting.apiKey.value, 'remote-key');
      expect(komgaSetting.connectionId.value, 'remote-connection');
      expect(
        await localConfigService.read(configKey: ConfigEnum.komgaSetting),
        remotePayload,
      );
      final CloudConfig? reexported = await CloudConfigService().getLocalConfig(
        CloudConfigTypeEnum.komgaSetting,
      );
      expect(reexported, isNotNull);
      expect(reexported!.ctime, DateTime.utc(2026, 8, 2));

      final MergeConfigResult nextMerge = await SyncMerger().mergeConfigType(
        CloudConfigTypeEnum.komgaSetting,
        reexported,
        CloudConfig(
          id: -1,
          shareCode: 'remote',
          identificationCode: 'remote',
          type: CloudConfigTypeEnum.komgaSetting,
          version: '1.0.0',
          config:
              '{"serverUrl":"https://newer.example.com","username":"","password":"","apiKey":"newer-key","connectionId":"newer-connection"}',
          ctime: DateTime.utc(2026, 8, 3),
        ),
        DateTime.utc(2026, 8, 3),
        null,
      );
      expect(nextMerge.config.config, contains('newer.example.com'));
    });

    test(
      'saving credential changes on the same server preserves connection ID',
      () async {
        final KomgaSetting setting = KomgaSetting();
        setting.applyBeanConfig(
          jsonEncode({
            'serverUrl': 'https://komga.example.com',
            'username': 'old-user',
            'password': 'old-password',
            'apiKey': '',
            'connectionId': 'stable-connection',
          }),
        );

        await setting.save(
          serverUrl: 'https://komga.example.com/',
          username: 'new-user',
          password: 'new-password',
          apiKey: '',
        );

        expect(setting.connectionId.value, 'stable-connection');
        expect(
          jsonDecode(setting.toConfigString())['connectionId'],
          'stable-connection',
        );
      },
    );
  });
}

Map<String, dynamic> _pageJson({
  required int page,
  required bool last,
  required List<Map<String, dynamic>> content,
}) {
  return <String, dynamic>{
    'content': content,
    'number': page,
    'totalPages': 2,
    'last': last,
  };
}

Map<String, dynamic> _seriesJson(String id) {
  return <String, dynamic>{
    'id': id,
    'libraryId': 'library-1',
    'name': '$id folder',
    'booksCount': 1,
    'created': '2026-08-01T00:00:00Z',
    'metadata': <String, dynamic>{'title': id, 'tags': <String>[]},
    'booksMetadata': <String, dynamic>{'authors': <dynamic>[]},
  };
}

Map<String, dynamic> _bookJson(
  String id, {
  Map<String, dynamic>? readProgress,
}) {
  return <String, dynamic>{
    'id': id,
    'seriesId': 'series-0',
    'seriesTitle': 'Series 0',
    'name': '$id.cbz',
    'created': '2026-08-01T00:00:00Z',
    'metadata': <String, dynamic>{
      'title': id,
      'number': '1',
      'tags': <String>[],
      'authors': <dynamic>[],
    },
    'media': <String, dynamic>{
      'status': 'READY',
      'mediaType': 'application/zip',
      'mediaProfile': 'DIVINA',
      'pagesCount': 10,
    },
    if (readProgress != null) 'readProgress': readProgress,
  };
}

Map<String, dynamic> _readProgressJson({required int page}) {
  return <String, dynamic>{
    'page': page,
    'completed': false,
    'readDate': '2026-08-01T10:00:00Z',
    'created': '2026-07-31T10:00:00Z',
    'lastModified': '2026-08-01T10:00:01Z',
    'deviceId': 'fixture-device',
    'deviceName': 'Fixture reader',
  };
}
