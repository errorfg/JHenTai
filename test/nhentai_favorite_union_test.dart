import 'dart:collection';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/content_scheme.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_count.dart';
import 'package:jhentai/src/model/gallery_detail.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/pages/details/details_page_logic.dart';
import 'package:jhentai/src/pages/favorite/favorite_page_logic.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/nhentai_favorite_service.dart';
import 'package:jhentai/src/setting/scheme_setting.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

/// With an nhentai API key, the favorites page lists the account's
/// favorites in the account's order, then the favorites kept only on this
/// device; the details page counts both as favorites.

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

/// The nhentai account behind the API key.
class _NhAccount extends EHRequest {
  _NhAccount(this.pages);

  /// The account's favorites, page by page, in the account's order.
  final List<List<int>> pages;
  bool unreachable = false;
  final List<({int gid, bool favorited})> changes = [];

  @override
  bool get hasNhentaiApiKey => true;

  @override
  Future<GalleryPageInfo> requestNhFavoritePage({
    required int pageNo,
    SearchConfig? searchConfig,
  }) async {
    if (unreachable) {
      throw Exception('nhentai unreachable');
    }
    return GalleryPageInfo(
      gallerys: <Gallery>[
        for (int gid in pages[pageNo - 1]) _gallery(gid, title: 'Account $gid'),
      ],
      totalCount: GalleryCount(
        type: GalleryCountType.accurate,
        count: '${pages.expand((List<int> page) => page).length}',
      ),
      prevGid: pageNo > 1 ? '${pageNo - 1}' : null,
      nextGid: pageNo < pages.length ? '${pageNo + 1}' : null,
    );
  }

  @override
  Future<({bool favorited, int? numFavorites})> requestNhSetFavorite(
    int gid, {
    required bool favorited,
  }) async {
    changes.add((gid: gid, favorited: favorited));
    return (favorited: favorited, numFavorites: null);
  }
}

void main() {
  late EHRequest realRequest;

  setUp(() {
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
    realRequest = ehRequest;
    Get.testMode = true;
    // On this device: newest first 101, 202, 505.
    nhentaiFavoriteService.applyBeanConfig(
      jsonEncode(<Map<String, dynamic>>[
        _favoriteEntry(_gallery(505, title: 'Device 505'), '2026-02-13T10:00:00.000Z'),
        _favoriteEntry(_gallery(101, title: 'Device 101'), '2026-08-20T10:00:00.000Z'),
        _favoriteEntry(_gallery(202, title: 'Device 202'), '2026-08-18T10:00:00.000Z'),
      ]),
    );
  });

  tearDown(() async {
    Get.reset();
    ehRequest = realRequest;
    schemeSetting.site.value = ContentScheme.ehentai;
    nhentaiFavoriteService.applyBeanConfig('[]');
    await appDb.close();
  });

  List<int> gids(List<Gallery> gallerys) => gallerys.map((Gallery g) => g.gid).toList();

  group('favorites page', () {
    Future<FavoritePageLogic> open(WidgetTester tester) async {
      schemeSetting.site.value = ContentScheme.nhentai;
      final FavoritePageLogic logic = Get.put(FavoritePageLogic(), permanent: true);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      return logic;
    }

    testWidgets('the account\'s favorites come first, in its order; this device\'s own follow its last page', (WidgetTester tester) async {
      ehRequest = _NhAccount(<List<int>>[
        <int>[303, 202],
        <int>[404],
      ]);
      final FavoritePageLogic logic = await open(tester);

      // 202 is on both: it stands where the account has it.
      expect(gids(logic.state.gallerys), <int>[303, 202]);
      expect(logic.state.gallerys[1].title, 'Account 202');
      expect(logic.state.loadingState, LoadingState.idle);

      await tester.runAsync(logic.loadMore);
      expect(gids(logic.state.gallerys), <int>[303, 202, 404, 101, 505]);
      expect(logic.state.loadingState, LoadingState.noMore);

      // Starting again from the first page lists the same.
      await tester.runAsync(logic.handleRefresh);
      expect(gids(logic.state.gallerys), <int>[303, 202]);
      await tester.runAsync(logic.loadMore);
      expect(gids(logic.state.gallerys), <int>[303, 202, 404, 101, 505]);
    });

    testWidgets('an account with a single page has this device\'s own right after it', (WidgetTester tester) async {
      ehRequest = _NhAccount(<List<int>>[
        <int>[303, 101],
      ]);
      final FavoritePageLogic logic = await open(tester);

      expect(gids(logic.state.gallerys), <int>[303, 101, 202, 505]);
      expect(logic.state.loadingState, LoadingState.noMore);
    });

    testWidgets('when the account cannot be reached, this device\'s own still show', (WidgetTester tester) async {
      ehRequest = _NhAccount(<List<int>>[
        <int>[303],
      ])..unreachable = true;
      final FavoritePageLogic logic = await open(tester);

      expect(gids(logic.state.gallerys), <int>[101, 202, 505]);
      expect(logic.state.loadingState, LoadingState.noMore);
    });
  });

  test('a page of the account comes as it is, without the favorites of this device before its last page', () {
    final GalleryPageInfo first = nhentaiFavoriteService.mergeRemoteFavoritePage(
      remotePage: GalleryPageInfo(
        gallerys: <Gallery>[_gallery(303, title: 'Account 303'), _gallery(202, title: 'Account 202')],
        totalCount: const GalleryCount(type: GalleryCountType.accurate, count: '3'),
        nextGid: '2',
      ),
    );
    expect(gids(first.gallerys), <int>[303, 202]);
    expect(first.nextGid, '2');
    // The account's total leaves out the favorites only this device has.
    expect(first.totalCount, isNull);

    final GalleryPageInfo last = nhentaiFavoriteService.mergeRemoteFavoritePage(
      remotePage: GalleryPageInfo(gallerys: <Gallery>[_gallery(404, title: 'Account 404')], prevGid: '1'),
      listedGids: const <int>{303, 202},
    );
    expect(gids(last.gallerys), <int>[404, 101, 505]);
  });

  group('details page', () {
    DetailsPageLogic open(int gid, {required bool accountHasIt}) {
      Get.routing.args = DetailsPageArgument(
        galleryUrl: _url(gid),
        detailsPageInfo: (galleryDetails: _details(gid, accountHasIt: accountHasIt), apikey: ''),
      );
      return DetailsPageLogic()..onInit();
    }

    test('a favorite kept only on this device shows as one; removing it touches only this device', () async {
      final _NhAccount account = _NhAccount(const <List<int>>[]);
      ehRequest = account;

      final DetailsPageLogic details = open(101, accountHasIt: false);
      expect(details.state.galleryDetails!.isFavorite, isTrue);

      await details.handleTapFavorite(useDefault: false);
      expect(account.changes, isEmpty);
      expect(nhentaiFavoriteService.isFavorite(101), isFalse);
      expect(details.state.galleryDetails!.isFavorite, isFalse);

      // Favoriting it again puts it on the account.
      await details.handleTapFavorite(useDefault: false);
      expect(account.changes, <({int gid, bool favorited})>[(gid: 101, favorited: true)]);
      expect(details.state.galleryDetails!.isFavorite, isTrue);

      await details.handleTapFavorite(useDefault: false);
      expect(account.changes.last, (gid: 101, favorited: false));
      expect(details.state.galleryDetails!.isFavorite, isFalse);
    });

    test('removing a favorite that the account and this device both have removes it from both', () async {
      final _NhAccount account = _NhAccount(const <List<int>>[]);
      ehRequest = account;

      final DetailsPageLogic details = open(202, accountHasIt: true);
      expect(details.state.galleryDetails!.isFavorite, isTrue);

      await details.handleTapFavorite(useDefault: false);
      expect(account.changes, <({int gid, bool favorited})>[(gid: 202, favorited: false)]);
      expect(nhentaiFavoriteService.isFavorite(202), isFalse);
      expect(details.state.galleryDetails!.isFavorite, isFalse);
    });

    test('a favorite only the account has is removed from the account', () async {
      final _NhAccount account = _NhAccount(const <List<int>>[]);
      ehRequest = account;

      final DetailsPageLogic details = open(303, accountHasIt: true);
      await details.handleTapFavorite(useDefault: false);
      expect(account.changes, <({int gid, bool favorited})>[(gid: 303, favorited: false)]);
      expect(details.state.galleryDetails!.isFavorite, isFalse);
      expect(gids(nhentaiFavoriteService.getDisplayFavorites()), <int>[101, 202, 505]);
    });
  });
}

Map<String, dynamic> _favoriteEntry(Gallery gallery, String favoritedTime) => <String, dynamic>{
  'gallery': gallery.toJson(),
  'favoritedTime': favoritedTime,
  'favoriteCategoryIndex': 2,
};

GalleryUrl _url(int gid) => GalleryUrl(
  isEH: true,
  isNH: true,
  gid: gid,
  token: 'nhentai',
  sourceHost: 'nhentai.net',
);

Gallery _gallery(int gid, {required String title}) => Gallery(
  galleryUrl: _url(gid),
  title: title,
  category: 'manga',
  cover: GalleryImage(url: 'https://example.test/cover.jpg'),
  pageCount: 20,
  rating: 0,
  hasRated: false,
  language: 'english',
  uploader: 'fixture',
  publishTime: '2026-08-19 10:00',
  isExpunged: false,
  tags: LinkedHashMap<String, List<GalleryTag>>(),
);

GalleryDetail _details(int gid, {required bool accountHasIt}) => GalleryDetail(
  galleryUrl: _url(gid),
  rawTitle: 'Gallery $gid',
  category: 'manga',
  cover: GalleryImage(url: 'https://example.test/cover.jpg'),
  pageCount: 20,
  rating: 0,
  realRating: 0,
  hasRated: false,
  ratingCount: 0,
  favoriteTagIndex: accountHasIt ? 0 : null,
  favoriteCount: 5,
  language: 'english',
  publishTime: '2026-08-19 10:00',
  isExpunged: false,
  tags: LinkedHashMap<String, List<GalleryTag>>(),
  size: '',
  torrentCount: '0',
  torrentPageUrl: '',
  archivePageUrl: '',
  comments: const [],
  thumbnails: const [],
  thumbnailsPageCount: 0,
);
