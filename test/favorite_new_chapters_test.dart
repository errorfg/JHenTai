import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/content_scheme.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/network/tachi/tachi_client.dart';
import 'package:jhentai/src/network/tachi/tachi_host.dart';
import 'package:jhentai/src/network/tachi/tachi_source.dart';
import 'package:jhentai/src/pages/favorite/favorite_page_logic.dart';
import 'package:jhentai/src/pages/watched/watched_card.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/jm_favorite_service.dart';
import 'package:jhentai/src/service/jm_reading_service.dart';
import 'package:jhentai/src/service/jm_update_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/tachi/tachi_favorite_service.dart';
import 'package:jhentai/src/service/tachi/tachi_update_service.dart';
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

Gallery _favorite(GalleryUrl url, String title, DateTime published) => Gallery(
      galleryUrl: url,
      title: title,
      category: 'Manga',
      cover: GalleryImage(url: ''),
      pageCount: null,
      rating: 0,
      hasRated: false,
      language: null,
      uploader: null,
      publishTime: '${published.toIso8601String().substring(0, 10)} ${published.toIso8601String().substring(11, 16)}',
      isExpunged: false,
      tags: LinkedHashMap<String, List<GalleryTag>>(),
    );

JmAlbum _album(int id, List<int> chapters, DateTime at) => JmAlbum(
      id: id,
      name: 'Album $id',
      authors: const <String>[],
      description: '',
      tags: const <String>[],
      works: const <String>[],
      actors: const <String>[],
      chapters: <JmChapterRef>[for (int i = 0; i < chapters.length; i++) JmChapterRef(id: chapters[i], name: '', sort: i + 1)],
      totalPhotos: 0,
      addTime: at,
      views: 0,
      likes: 0,
      commentCount: 0,
      related: const <JmAlbumSummary>[],
    );

JmSearchResult _page(List<(int, DateTime)> albums) => JmSearchResult(total: 10000, albums: <JmAlbumSummary>[
      for (final (int id, DateTime at) in albums)
        JmAlbumSummary(id: id, name: 'Album $id', author: '', categoryTitle: '', subCategoryTitle: '', addDate: '', updateAt: at),
    ]);

Set<int> _fadedOf(FavoritePageLogic logic) => <int>{
      for (final Gallery g in logic.state.gallerys)
        if (logic.cardWrapper?.call(g, const SizedBox()) case Opacity(opacity: final double o) when o == WatchedCard.readOpacity) g.gid,
    };

/// The favorites are shown in [order], and those of [faded] show faded.
void _expectShown(FavoritePageLogic logic, List<int> order, Set<int> faded, {String? reason}) {
  expect(logic.state.gallerys.map((Gallery g) => g.gid).toList(), order, reason: reason);
  expect(_fadedOf(logic), faded, reason: reason);
}

/// The extension host, as far as manga and their chapters go; chapters
/// newest first, as sources give them.
class _Host {
  late HttpServer _server;
  final Map<String, List<Map<String, Object?>>> chapters = <String, List<Map<String, Object?>>>{};
  final List<String> asked = <String>[];

  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((HttpRequest request) async {
      final Map<String, dynamic> body = jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
      final Map<String, dynamic> manga = (body['manga'] as Map).cast<String, dynamic>();
      Object? reply;
      switch (request.uri.path) {
        case '/manga/details':
          reply = <String, Object?>{'url': manga['url'], 'title': 'Manga ${manga['url']}', 'initialized': true};
        case '/manga/chapters':
          asked.add(manga['url'] as String);
          reply = <String, Object?>{'chapters': chapters[manga['url']] ?? <Object?>[]};
        default:
          request.response.statusCode = HttpStatus.notFound;
          reply = <String, Object?>{'error': 'not here'};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(reply));
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
  final DateTime now = DateTime.now().toUtc();

  setUp(() {
    log = _SilentLogService();
    HttpOverrides.global = null;
    Get.testMode = true;
    appDb = AppDb.forTesting(NativeDatabase.memory());
    readProgressService = ReadProgressService();
    pendingSyncTracker = PendingSyncTracker();
  });

  tearDown(() async {
    Get.reset();
    schemeSetting.site.value = ContentScheme.ehentai;
    await appDb.close();
  });

  testWidgets('JM favorites: a pull-down checks them; those whose newest chapter is not opened come first, the rest fade', (WidgetTester tester) async {
    await tester.runAsync(() async {
      schemeSetting.site.value = ContentScheme.jm;
      jmFavoriteService = JmFavoriteService();
      jmUpdateService = JmUpdateService();
      final List<int> pagesAsked = <int>[];
      final List<int> albumsAsked = <int>[];
      Map<int, JmAlbum> albums = <int, JmAlbum>{
        100: _album(100, <int>[100, 101, 102], now.subtract(const Duration(days: 2))),
        200: _album(200, <int>[200, 201], now.subtract(const Duration(days: 40))),
        300: _album(300, <int>[300], now.subtract(const Duration(days: 50))),
      };
      final Set<int> failing = <int>{};
      List<JmSearchResult> newest = <JmSearchResult>[];
      jmUpdateService
        ..latestPage = (int page) async {
          pagesAsked.add(page);
          return newest[page - 1];
        }
        ..albumOf = (int id) async {
          albumsAsked.add(id);
          if (failing.remove(id)) {
            throw const SocketException('connection reset');
          }
          return albums[id]!;
        };
      Future<void> favorite(int id, {required int favoritedDaysAgo, required int publishedDaysAgo}) => jmFavoriteService.addFavorite(
            _favorite(GalleryUrl.jm(id), 'Album $id', now.subtract(Duration(days: publishedDaysAgo))),
            favoriteCategoryIndex: 0,
            favoritedTime: now.subtract(Duration(days: favoritedDaysAgo)),
          );
      await favorite(100, favoritedDaysAgo: 20, publishedDaysAgo: 30);
      await favorite(200, favoritedDaysAgo: 10, publishedDaysAgo: 40);
      await favorite(300, favoritedDaysAgo: 5, publishedDaysAgo: 50);
      int gid(int albumId) => GalleryUrl.jm(albumId).gid;

      final FavoritePageLogic logic = Get.put(FavoritePageLogic(), permanent: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(logic.state.showJmFavorites, isTrue);
      _expectShown(logic, <int>[gid(300), gid(200), gid(100)], <int>{}, reason: 'nothing checked yet: as favorited, none faded');

      // Read up to the newest chapter of 200, and the one chapter of 300.
      await jmReadingService.markRead(<int>[201, 300]);
      // The first check asks for every album.
      await logic.handlePullDown();
      expect(pagesAsked, isEmpty);
      expect(albumsAsked..sort(), <int>[100, 200, 300]);
      _expectShown(logic, <int>[gid(100), gid(300), gid(200)], <int>{gid(300), gid(200)});
      expect(await jmReadingService.chaptersOf(100), <int>[100, 101, 102], reason: 'the cards show 0/3');

      await jmReadingService.markRead(<int>[102]);
      await logic.handleRefresh();
      _expectShown(logic, <int>[gid(300), gid(200), gid(100)], <int>{gid(300), gid(200), gid(100)});

      // Favorited since, not read: shown, without asking for it.
      await favorite(400, favoritedDaysAgo: 0, publishedDaysAgo: 1);
      await logic.handleRefresh();
      _expectShown(logic, <int>[gid(400), gid(300), gid(200), gid(100)], <int>{gid(300), gid(200), gid(100)});

      // Album 200 gets a chapter: back on top of the newest list. The list
      // is read down to a day before the last check, and only 200 is asked,
      // once failing.
      albums = <int, JmAlbum>{...albums, 200: _album(200, <int>[200, 201, 202], now.subtract(const Duration(hours: 1)))};
      newest = <JmSearchResult>[
        _page(<(int, DateTime)>[(999, now.subtract(const Duration(minutes: 30))), (200, now.subtract(const Duration(hours: 1)))]),
        _page(<(int, DateTime)>[(998, now.subtract(const Duration(hours: 20))), (100, now.subtract(const Duration(days: 2)))]),
      ];
      pagesAsked.clear();
      albumsAsked.clear();
      failing.add(200);
      await logic.handlePullDown();
      expect(pagesAsked, <int>[1, 2]);
      expect(albumsAsked, <int>[200]);
      expect(_fadedOf(logic), contains(gid(200)), reason: 'its new chapter not known yet');

      // Not in the list any more, but asked again as it failed.
      newest = <JmSearchResult>[_page(<(int, DateTime)>[(997, now.subtract(const Duration(days: 3)))])];
      pagesAsked.clear();
      albumsAsked.clear();
      await logic.handlePullDown();
      expect(pagesAsked, <int>[1]);
      expect(albumsAsked, <int>[200]);
      _expectShown(logic, <int>[gid(400), gid(200), gid(300), gid(100)], <int>{gid(300), gid(100)});

      // 400 opened (its chapters kept) and read to its newest.
      await jmReadingService.remember(albumId: 400, chapterIds: <int>[400, 401]);
      await jmReadingService.markRead(<int>[401]);
      await logic.handleRefresh();
      _expectShown(logic, <int>[gid(200), gid(400), gid(300), gid(100)], <int>{gid(400), gid(300), gid(100)});
    });
  });

  testWidgets('Tachiyomi favorites: a pull-down asks each manga for its chapters; those whose newest chapter is not opened come first', (WidgetTester tester) async {
    final _Host host = _Host();
    await tester.runAsync(() async {
      await host.start();
      tachiHost = _RunningHost(TachiClient(port: host.port, token: 'token'));
      schemeSetting.site.value = ContentScheme.tachiyomi;
      tachiFavoriteService = TachiFavoriteService();
      tachiUpdateService = TachiUpdateService();
      const String source = '1234';
      Map<String, Object?> chapter(String url) => <String, Object?>{'url': url, 'name': 'Chapter $url'};
      host.chapters['/a'] = <Map<String, Object?>>[chapter('/a/2'), chapter('/a/1')];
      host.chapters['/b'] = <Map<String, Object?>>[chapter('/b/1')];
      for (final (String path, int favoritedDaysAgo) in <(String, int)>[('/a', 10), ('/b', 5)]) {
        await tachiFavoriteService.addFavorite(
          _favorite(GalleryUrl.tachiManga(source, path), 'Manga $path', now.subtract(const Duration(days: 30))),
          favoriteCategoryIndex: 0,
          favoritedTime: now.subtract(Duration(days: favoritedDaysAgo)),
        );
      }
      int gid(String path) => GalleryUrl.tachiManga(source, path).gid;

      final FavoritePageLogic logic = Get.put(FavoritePageLogic(), permanent: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(logic.state.showTachiFavorites, isTrue);

      // Read up to the newest chapter of /b; /a not at all.
      await tachiReadingService.markRead(<int>[TachiSource.idOf(GalleryUrl.tachiChapter(source, '/b', '/b/1'))]);
      await logic.handlePullDown();
      expect(host.asked..sort(), <String>['/a', '/b']);
      _expectShown(logic, <int>[gid('/a'), gid('/b')], <int>{gid('/b')});

      // A chapter of /b found new: its newest not opened any more.
      host.chapters['/b'] = <Map<String, Object?>>[chapter('/b/2'), ...host.chapters['/b']!];
      await logic.handlePullDown();
      _expectShown(logic, <int>[gid('/b'), gid('/a')], <int>{});
      final List<int> order = await tachiReadingService.chaptersOf(TachiSource.idOf(GalleryUrl.tachiManga(source, '/b')));
      expect(order, hasLength(2), reason: 'the chapters kept for the cards');

      // Both read to their newest: faded, as favorited.
      await tachiReadingService.markRead(<int>[order.last, TachiSource.idOf(GalleryUrl.tachiChapter(source, '/a', '/a/2'))]);
      await logic.handleRefresh();
      _expectShown(logic, <int>[gid('/b'), gid('/a')], <int>{gid('/b'), gid('/a')});
      await host.stop();
    });
    tachiHost = TachiHost();
  });
}
