import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/network/tachi/tachi_models.dart';
import 'package:jhentai/src/network/tachi/tachi_source.dart';
import 'package:jhentai/src/pages/favorite/favorite_page_logic.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/jm_favorite_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/tachi/tachi_favorite_service.dart';

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

class _InlineIsolateService extends IsolateService {
  @override
  Future<String> jsonEncodeAsync(Object object) async => jsonEncode(object);

  @override
  Future<dynamic> jsonDecodeAsync(String string) async => jsonDecode(string);
}

/// Favorites whose E-Hentai pages answer when the test says.
class _FavoriteLogic extends FavoritePageLogic {
  final List<Completer<GalleryPageInfo>> requests = <Completer<GalleryPageInfo>>[];

  @override
  Future<GalleryPageInfo> getGalleryPage({String? prevGid, String? nextGid, DateTime? seek}) {
    final Completer<GalleryPageInfo> answer = Completer<GalleryPageInfo>();
    requests.add(answer);
    return answer.future;
  }

  @override
  Future<List<Gallery>> postHandleNewGallerys(List<Gallery> gallerys, {bool cleanDuplicate = true}) async => gallerys;
}

Gallery _ehGallery(int gid, String favoritedTime) => Gallery(
      galleryUrl: GalleryUrl(isEH: true, gid: gid, token: 'abcdef1234'),
      title: 'E-Hentai $gid',
      category: 'Manga',
      cover: GalleryImage(url: 'https://example.test/cover.jpg'),
      pageCount: 10,
      rating: 0,
      hasRated: false,
      language: null,
      uploader: null,
      publishTime: '2026-10-01 10:00',
      isExpunged: false,
      tags: LinkedHashMap<String, List<GalleryTag>>(),
      favoritedTime: favoritedTime,
    );

/// E-Hentai favorites with the favorites kept on this device in between.
void main() {
  setUp(() {
    log = _SilentLogService();
    isolateService = _InlineIsolateService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
    localConfigService = LocalConfigService();
    jmFavoriteService = JmFavoriteService();
    tachiFavoriteService = TachiFavoriteService();
  });

  tearDown(() => appDb.close());

  test('favorites of every site kept on this device are listed once, however often they are merged', () async {
    final Gallery tachi = TachiSource().galleryOf('101', TachiManga(url: '/book', title: 'Tachiyomi book'));
    await tachiFavoriteService.addFavorite(tachi, favoriteCategoryIndex: 0, favoritedTime: DateTime.utc(2026, 10, 2));
    await jmFavoriteService.addFavorite(
      Gallery(
        galleryUrl: GalleryUrl.jm(350234),
        title: 'JM album',
        category: 'Manga',
        cover: GalleryImage(url: 'https://example.test/cover.jpg'),
        pageCount: 10,
        rating: 0,
        hasRated: false,
        language: null,
        uploader: null,
        publishTime: '2026-10-01 10:00',
        isExpunged: false,
        tags: LinkedHashMap<String, List<GalleryTag>>(),
      ),
      favoriteCategoryIndex: 0,
      favoritedTime: DateTime.utc(2026, 10, 1),
    );

    final FavoritePageLogic logic = FavoritePageLogic();
    logic.state.mixedMode = true;
    logic.state.gallerys = <Gallery>[_ehGallery(3400000, '2026-10-03 10:00')];

    // A favorite changed elsewhere, then another: each merges again.
    await logic.reloadLocalSourceFavoriteGallerys();
    await Future<void>.delayed(Duration.zero);
    await logic.reloadLocalSourceFavoriteGallerys();
    await Future<void>.delayed(Duration.zero);

    expect(logic.state.gallerys.map((Gallery g) => g.title), <String>['E-Hentai 3400000', 'Tachiyomi book', 'JM album']);
  });

  test('a page of E-Hentai favorites coming after the favorites of this device were chosen is dropped', () async {
    final Gallery tachi = TachiSource().galleryOf('101', TachiManga(url: '/book', title: 'Tachiyomi book'));
    await tachiFavoriteService.addFavorite(tachi, favoriteCategoryIndex: 0);

    final _FavoriteLogic logic = _FavoriteLogic();
    final Future<void> ehPage = logic.loadMore();
    logic.handleSwitchFavoriteSource('TACHI');
    await Future<void>.delayed(Duration.zero);
    logic.requests.single.complete(GalleryPageInfo(gallerys: <Gallery>[_ehGallery(3400000, '2026-10-03 10:00')], nextGid: '3400000'));
    await ehPage;

    expect(logic.state.gallerys.map((Gallery g) => g.title), <String>['Tachiyomi book']);
    expect(logic.state.nextGid, isNull);
  });
}
