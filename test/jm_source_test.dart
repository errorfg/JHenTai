import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/network/jm/jm_api.dart';
import 'package:jhentai/src/network/jm/jm_image.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/service/cloud_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/jm_favorite_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sync_merger.dart';

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

/// Runs JSON work inline; the app's isolate is not started in tests.
class _InlineIsolateService extends IsolateService {
  @override
  Future<String> jsonEncodeAsync(Object object) async => jsonEncode(object);

  @override
  Future<dynamic> jsonDecodeAsync(String string) async => jsonDecode(string);
}

void main() {
  group('JM gallery urls', () {
    test('chapter gids are shifted out of the E-Hentai range', () {
      final GalleryUrl url = GalleryUrl.jm(1234567);
      expect(url.isJM, isTrue);
      expect(url.gid, GalleryUrl.jmGidOffset + 1234567);
      expect(url.jmChapterId, 1234567);
      expect(url.url, 'https://18comic.vip/photo/1234567');
    });

    test('album and photo pages parse to the chapter url', () {
      for (final String link in <String>[
        'https://18comic.vip/photo/1234567',
        'https://18comic.vip/album/1234567/some-title',
        'https://jmcomic.me/album/1234567',
      ]) {
        final GalleryUrl? url = GalleryUrl.tryParse(link);
        expect(url?.isJM, isTrue, reason: link);
        expect(url?.gid, GalleryUrl.jm(1234567).gid, reason: link);
      }
      expect(GalleryUrl.tryParse(GalleryUrl.jm(42).url)?.jmChapterId, 42);
    });
  });

  group('JM search keywords', () {
    test('free text is passed as typed and the source prefix dropped', () {
      expect(JmSource.normalizeKeyword('jm: MANA -蘿莉'), 'MANA -蘿莉');
      expect(JmSource.normalizeKeyword(null), '');
    });

    test('tags become required words', () {
      final SearchConfig config = SearchConfig(
        keyword: 'MANA',
        isJmSearch: true,
        tags: <TagData>[
          TagData(namespace: 'tag', key: '蘿莉'),
          TagData(namespace: 'parody', key: 'Blue Archive'),
        ],
      );
      expect(
        JmSource.normalizeKeyword(config.computeFullKeywords()),
        'MANA +蘿莉 +Blue +Archive',
      );
      expect(JmSource.normalizeKeyword('uploader:"MANA"'), '+MANA');
    });
  });

  group('JM image strips', () {
    test('strip count follows the chapter thresholds and the page hash', () {
      int strips(int chapterId, String file) => JmImage.stripCount(
        scrambleId: JmImage.defaultScrambleId,
        chapterId: chapterId,
        fileName: file,
      );

      expect(strips(220979, '00001.webp'), 0);
      expect(strips(220980, '00001.webp'), 10);
      expect(strips(268849, '00009.webp'), 10);
      // Expected values from Python's hashlib over '$chapterId$stem'.
      expect(strips(300000, '00001.webp'), 16);
      expect(strips(300000, '00002.webp'), 12);
      expect(strips(500000, '00001.webp'), 12);
      expect(strips(500000, '00007.jpg'), 6);
      expect(strips(1234567, '00010.webp'), 8);
      // GIF pages are stored as is.
      expect(strips(1234567, '00011.gif'), 0);
    });

    test('strip layout tiles the whole image, remainder in the first strip', () {
      final layout = JmImage.stripLayout(1003, 10);
      expect(layout.first, (srcY: 900, dstY: 0, height: 103));
      int nextDstY = 0;
      final Set<int> sourceRows = <int>{};
      for (final strip in layout) {
        expect(strip.dstY, nextDstY);
        nextDstY += strip.height;
        for (int y = strip.srcY; y < strip.srcY + strip.height; y++) {
          expect(sourceRows.add(y), isTrue);
        }
      }
      expect(nextDstY, 1003);
      expect(sourceRows.length, 1003);
    });

    test('the strip count rides in the fragment, never in requests', () {
      final String url = JmImage.pageUrl(
        imageDomain: 'cdn.example.test',
        chapterId: 300000,
        fileName: '00001.webp',
        strips: 16,
      );
      expect(JmImage.stripsOf(url), 16);
      expect(
        JmImage.requestUrl(url),
        'https://cdn.example.test/media/photos/300000/00001.webp',
      );
      expect(JmImage.stripsOf(JmImage.requestUrl(url)), 0);
    });
  });

  group('JM request budget', () {
    test('a failed start is not repeated on every call', () async {
      final Map<String, int> requests = <String, int>{};
      final Dio dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 2)))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
              requests[options.uri.path] = (requests[options.uri.path] ?? 0) + 1;
              handler.next(options);
            },
          ),
        );
      // Nothing listens on these ports: every connection is refused.
      final JmApi api = JmApi(
        dio: dio,
        apiDomains: () => <String>['127.0.0.1:9', '127.0.0.1:19'],
        discoverDomains: false,
      );

      for (int i = 0; i < 3; i++) {
        await expectLater(api.album(1), throwsA(anything));
      }
      // One attempt per domain for the first call; the next calls fail
      // without a request until the retry delay has passed.
      expect(requests, <String, int>{'/setting': 2});
    });
  });

  group('JM favorites', () {
    late IsolateService originalIsolateService;

    setUp(() {
      log = _SilentLogService();
      appDb = AppDb.forTesting(NativeDatabase.memory());
      originalIsolateService = isolateService;
      isolateService = _InlineIsolateService();
      jmFavoriteService.applyBeanConfig('[]');
    });

    tearDown(() async {
      isolateService = originalIsolateService;
      await appDb.close();
    });

    test('keeps JM galleries only and filters like other sources', () async {
      await jmFavoriteService.addFavorite(
        _gallery(GalleryUrl.jm(101), title: 'Blue Archive 合集'),
        favoriteCategoryIndex: 3,
      );
      await jmFavoriteService.addFavorite(
        _gallery(
          GalleryUrl(isEH: true, isWN: true, gid: 7, token: 'wnacg'),
          title: 'wnacg gallery',
        ),
        favoriteCategoryIndex: 0,
      );

      expect(jmFavoriteService.isFavorite(GalleryUrl.jm(101).gid), isTrue);
      expect(jmFavoriteService.isFavorite(7), isFalse);
      expect(
        jmFavoriteService.getFavoriteCategoryIndex(GalleryUrl.jm(101).gid),
        3,
      );

      List<Gallery> shown(String keyword) => jmFavoriteService
          .getDisplayFavorites(
            searchConfig: SearchConfig(
              searchType: SearchType.favorite,
              keyword: keyword,
            ),
          );
      expect(shown('jm:archive'), hasLength(1));
      expect(shown('合集'), hasLength(1));
      expect(shown('nothing'), isEmpty);

      final String? stored = await localConfigService.read(
        configKey: ConfigEnum.jmFavorite,
      );
      expect(jsonDecode(stored!), hasLength(1));
    });

    test('syncs as its own cloud config type, newest entry wins', () async {
      expect(CloudConfigTypeEnum.fromCode(12), CloudConfigTypeEnum.jmFavorite);
      expect(
        CloudConfigService.configTypeVersionMap[CloudConfigTypeEnum.jmFavorite],
        '1.0.0',
      );

      await jmFavoriteService.addFavorite(
        _gallery(GalleryUrl.jm(101), title: 'Local'),
        favoriteCategoryIndex: 1,
        favoritedTime: DateTime.utc(2026, 10, 1),
      );
      final CloudConfig local = (await CloudConfigService().getLocalConfig(
        CloudConfigTypeEnum.jmFavorite,
      ))!;
      expect(local.type, CloudConfigTypeEnum.jmFavorite);

      final CloudConfig remote = CloudConfig(
        id: -1,
        shareCode: 'remote',
        identificationCode: 'remote',
        type: CloudConfigTypeEnum.jmFavorite,
        version: '1.0.0',
        config: jsonEncode(<Map<String, dynamic>>[
          _entry(GalleryUrl.jm(101), 'Remote newer', DateTime.utc(2026, 10, 3), 5),
          _entry(GalleryUrl.jm(202), 'Remote only', DateTime.utc(2026, 9, 1), 0),
        ]),
        ctime: DateTime.utc(2026, 10, 3),
      );
      final MergeConfigResult merged = await SyncMerger().mergeConfigType(
        CloudConfigTypeEnum.jmFavorite,
        local,
        remote,
        DateTime.utc(2026, 10, 3),
        null,
      );
      expect(merged.config.type, CloudConfigTypeEnum.jmFavorite);

      await CloudConfigService().importConfig(merged.config);
      expect(
        jmFavoriteService.getFavoriteCategoryIndex(GalleryUrl.jm(101).gid),
        5,
      );
      expect(jmFavoriteService.isFavorite(GalleryUrl.jm(202).gid), isTrue);
      expect(
        jmFavoriteService.getDisplayFavorites().map((Gallery g) => g.title),
        <String>['Remote newer', 'Remote only'],
      );
    });
  });
}

Map<String, dynamic> _entry(
  GalleryUrl url,
  String title,
  DateTime favoritedTime,
  int categoryIndex,
) => <String, dynamic>{
  'gallery': _gallery(url, title: title).toJson(),
  'favoritedTime': favoritedTime.toIso8601String(),
  'favoriteCategoryIndex': categoryIndex,
};

Gallery _gallery(GalleryUrl url, {required String title}) => Gallery(
  galleryUrl: url,
  title: title,
  category: 'Manga',
  cover: GalleryImage(url: 'https://example.test/cover.jpg'),
  pageCount: 20,
  rating: 0,
  hasRated: false,
  language: 'Chinese',
  uploader: 'fixture',
  publishTime: '2026-09-19 10:00',
  isExpunged: false,
  tags: LinkedHashMap<String, List<GalleryTag>>(),
);
