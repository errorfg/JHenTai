import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/content_scheme.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/network/tachi/tachi_client.dart';
import 'package:jhentai/src/network/tachi/tachi_host.dart';
import 'package:jhentai/src/network/tachi/tachi_source.dart';
import 'package:jhentai/src/pages/favorite/favorite_page_logic.dart';
import 'package:jhentai/src/pages/history/history_page_logic.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/series_reading_service.dart';
import 'package:jhentai/src/service/tachi/tachi_backup_import.dart';
import 'package:jhentai/src/service/tachi/tachi_extension_service.dart';
import 'package:jhentai/src/setting/scheme_setting.dart';

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

/// Protocol Buffers as kotlinx.serialization writes a Tachiyomi backup:
/// integers and booleans as varints, strings and messages length-delimited,
/// repeated fields one per entry.
class _Proto {
  final BytesBuilder _out = BytesBuilder();

  void _varint(int v) {
    while (v >= 0x80 || v < 0) {
      _out.addByte((v & 0x7f) | 0x80);
      v = v >>> 7;
    }
    _out.addByte(v);
  }

  _Proto int64(int field, int v) {
    _varint(field << 3);
    _varint(v);
    return this;
  }

  _Proto string(int field, String v) => bytes(field, utf8.encode(v));

  _Proto message(int field, _Proto m) => bytes(field, m.done());

  _Proto bytes(int field, List<int> v) {
    _varint(field << 3 | 2);
    _varint(v.length);
    _out.add(v);
    return this;
  }

  List<int> done() => _out.toBytes();
}

const int _source = 1234567890123;
const String _pkg = 'eu.kanade.tachiyomi.extension.en.fake';

/// A chapter: Mihon's BackupChapter (url 1, name 2, read 4, lastPageRead 6,
/// sourceOrder 10; defaults left out).
_Proto _chapter(String url, {bool read = false, int lastPageRead = 0, int sourceOrder = 0}) {
  final _Proto c = _Proto().string(1, url).string(2, 'Chapter $url');
  if (read) c.int64(4, 1);
  if (lastPageRead > 0) c.int64(6, lastPageRead);
  if (sourceOrder > 0) c.int64(10, sourceOrder);
  return c;
}

/// A manga: Mihon's BackupManga (source 1, url 2, title 3, thumbnailUrl 9,
/// dateAdded 13, chapters 16, categories 17, history 104).
_Proto _manga(int source, String url, String title, {List<_Proto> chapters = const [], List<int> categories = const [], ({String url, int lastRead})? history}) {
  final _Proto m = _Proto().int64(1, source).string(2, url).string(3, title).string(9, 'https://example.test$url.jpg').int64(13, DateTime.utc(2026, 1, 2).millisecondsSinceEpoch);
  for (final _Proto c in chapters) {
    m.message(16, c);
  }
  for (final int category in categories) {
    m.int64(17, category);
  }
  if (history != null) {
    m.message(104, _Proto().string(1, history.url).int64(2, history.lastRead));
  }
  return m;
}

List<int> _gzip(_Proto backup) => gzip.encode(backup.done());

/// The extension host and a repository with one extension, which the host
/// has once it was asked to install it.
class _Servers {
  late HttpServer _server;
  bool installed = false;
  final List<String> requests = <String>[];

  int get port => _server.port;

  String get repo => 'http://127.0.0.1:$port/repo/index.min.json';

  static const Map<String, Object?> _sourceJson = <String, Object?>{'id': '$_source', 'name': 'Fake Source', 'lang': 'en', 'baseUrl': 'https://example.test'};

  static const Map<String, Object?> _extensionJson = <String, Object?>{
    'pkg': _pkg,
    'name': 'Tachiyomi: Fake',
    'versionName': '1.4.1',
    'versionCode': 1,
    'libVersion': '1.4',
    'sources': <Object?>[_sourceJson],
  };

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((HttpRequest request) async {
      requests.add('${request.method} ${request.uri.path}');
      Object? body;
      switch (request.uri.path) {
        case '/repo/index.min.json':
          body = <Object?>[
            <String, Object?>{
              'name': 'Tachiyomi: Fake',
              'pkg': _pkg,
              'apk': 'fake.apk',
              'lang': 'en',
              'code': 1,
              'version': '1.4.1',
              'nsfw': 0,
              'sources': <Object?>[<String, Object?>{'id': _source, 'name': 'Fake Source', 'lang': 'en', 'baseUrl': 'https://example.test'}],
            },
          ];
        case '/repo/apk/fake.apk':
          request.response.add(<int>[0x50, 0x4b, 3, 4]);
          await request.response.close();
          return;
        case '/extensions':
          body = <String, Object?>{'extensions': installed ? <Object?>[_extensionJson] : <Object?>[]};
        case '/extensions/install':
          installed = true;
          body = _extensionJson;
        default:
          request.response.statusCode = HttpStatus.notFound;
          body = <String, Object?>{'error': 'not here'};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

class _RunningHost extends TachiHost {
  _RunningHost(this._running);

  final TachiClient _running;

  @override
  TachiClient? get clientIfRunning => _running;

  @override
  Future<TachiClient> client() async => _running;
}

void main() {
  late _Servers servers;
  late Directory temp;

  setUp(() async {
    log = _SilentLogService();
    HttpOverrides.global = null;
    Get.testMode = true;
    appDb = AppDb.forTesting(NativeDatabase.memory());
    temp = Directory.systemTemp.createTempSync('tachi_backup_import');
    pathService.tempDir = temp;
    servers = _Servers();
    await servers.start();
    tachiHost = _RunningHost(TachiClient(port: servers.port, token: 'token'));
    schemeSetting.site.value = ContentScheme.tachiyomi;
  });

  tearDown(() async {
    Get.reset();
    tachiHost = TachiHost();
    schemeSetting.site.value = ContentScheme.ehentai;
    await servers.stop();
    await appDb.close();
    temp.deleteSync(recursive: true);
  });

  testWidgets('a Mihon and a Tachimanga backup fill the favorites, history and progress already on screen', (WidgetTester tester) async {
    await tester.runAsync(() async {
      // The favorites (on Tachiyomi) and the history were open before.
      final FavoritePageLogic favorites = Get.put(FavoritePageLogic(), permanent: true);
      final HistoryPageLogic history = Get.put(HistoryPageLogic(), permanent: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(favorites.state.showTachiFavorites, isTrue);
      expect(favorites.state.gallerys, isEmpty);

      final int lastRead = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;
      // Later Mihon: every chapter, the repository by the URL of its index,
      // the manga in the second of two categories.
      final _Proto mihon = _Proto()
        ..message(1, _manga(_source, '/mihon', 'Mihon Manga', categories: <int>[2], history: (url: '/mihon/2', lastRead: lastRead), chapters: <_Proto>[
          _chapter('/mihon/3'),
          _chapter('/mihon/2', lastPageRead: 5, sourceOrder: 1),
          _chapter('/mihon/1', read: true, sourceOrder: 2),
        ]))
        ..message(2, _Proto().string(1, 'Reading').int64(2, 1))
        ..message(2, _Proto().string(1, 'Later').int64(2, 2))
        ..message(101, _Proto().string(1, 'Fake Source').int64(2, _source))
        ..message(106, _Proto().string(1, servers.repo).string(2, 'Fake repo'));
      final TachiBackupImportResult fromMihon = await tachiBackupImport.importBytes(_gzip(mihon));

      expect(fromMihon.favorites, 1);
      expect(fromMihon.chaptersRead, 1);
      expect(fromMihon.chaptersInProgress, 1);
      expect(fromMihon.history, 1);
      expect(tachiExtensionService.repos, <String>[servers.repo], reason: 'the index URL as it is');
      expect(fromMihon.reposAdded, 1);
      expect(fromMihon.extensionsInstalled, 1);
      expect(fromMihon.missingSources, isEmpty);
      expect(fromMihon.hadRepos, isTrue);

      // Tachimanga: only the chapters read or begun, no repositories, and a
      // manga of the local source.
      final _Proto tachimanga = _Proto()
        ..message(1, _manga(_source, '/tachimanga', 'Tachimanga Manga', chapters: <_Proto>[
          _chapter('/tachimanga/50', read: true, sourceOrder: 9),
          _chapter('/tachimanga/49', read: true, sourceOrder: 10),
        ]))
        ..message(1, _manga(TachiBackupImport.localSourceId, '/local', 'Local Manga'))
        ..message(101, _Proto().string(1, 'Local source').int64(2, 0))
        ..message(101, _Proto().string(1, 'Fake Source').int64(2, _source));
      final TachiBackupImportResult fromTachimanga = await tachiBackupImport.importBytes(_gzip(tachimanga));

      expect(fromTachimanga.favorites, 1);
      expect(fromTachimanga.localSkipped, 1);
      expect(fromTachimanga.missingSources, isEmpty, reason: 'its source is installed, the local one is not wanted');
      expect(fromTachimanga.extensionsInstalled, 0);
      expect(fromTachimanga.hadRepos, isFalse);

      // On screen without a refresh: the favorites, in their categories,
      // and the history.
      final Map<String, Gallery> shown = <String, Gallery>{for (final Gallery g in favorites.state.gallerys) g.title: g};
      expect(shown.keys, unorderedEquals(<String>['Mihon Manga', 'Tachimanga Manga']));
      expect(shown['Mihon Manga']!.favoriteTagIndex, 1);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(history.state.gallerys.map((Gallery g) => g.title), <String>['Mihon Manga']);

      // Read and begun chapters.
      String chapterKey(String manga, String chapter) => '${GalleryUrl.tachiChapter('$_source', manga, chapter).gid}';
      final Map<String, ReadProgressRecord> progress = await readProgressService.getProgressRecords(<String>{
        chapterKey('/mihon', '/mihon/1'),
        chapterKey('/mihon', '/mihon/2'),
        chapterKey('/tachimanga', '/tachimanga/50'),
      });
      expect(progress[chapterKey('/mihon', '/mihon/1')]?.value, SeriesReadingService.markedReadValue);
      expect(progress[chapterKey('/mihon', '/mihon/2')]?.value, '5');
      expect(progress[chapterKey('/tachimanga', '/tachimanga/50')]?.value, SeriesReadingService.markedReadValue);

      // Mihon's chapters are the whole manga: its progress shows at once.
      final int mihonSeries = TachiSource.idOf(GalleryUrl.tachiManga('$_source', '/mihon'));
      expect((await tachiReadingService.albumProgress(mihonSeries))?.positionText, '2/3 · P6');
      // The two chapters Tachimanga kept, out of eleven or more, are not
      // taken for the whole manga, which would show it read to the end.
      final int tachimangaSeries = TachiSource.idOf(GalleryUrl.tachiManga('$_source', '/tachimanga'));
      expect(await tachiReadingService.albumProgress(tachimangaSeries), isNull);
      expect(await tachiReadingService.chaptersOf(tachimangaSeries), isEmpty);
    });
    await tester.pump(const Duration(seconds: 16));
  });
}
