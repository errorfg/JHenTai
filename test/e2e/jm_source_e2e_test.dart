// Live requests to a third-party server whose response times vary widely.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/detail_page_info.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_detail.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/network/jm/jm_api.dart';
import 'package:jhentai/src/network/jm/jm_image.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/service/jm_album_tag_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';

import 'support/e2e_app.dart';

/// The JM source adapter against the live JM API: the shapes the list,
/// detail page, reader and downloader consume. Enabled by
/// test/e2e/jm_e2e.json (see jm_e2e.example.json).
void main() {
  final File config = File('test/e2e/jm_e2e.json');
  final bool enabled =
      config.existsSync() &&
      (jsonDecode(config.readAsStringSync()) as Map)['enabled'] == true;
  if (!enabled) {
    test('JM source e2e', () {}, skip: 'test/e2e/jm_e2e.json is absent');
    return;
  }

  final Dio dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );
  List<String> domains = <String>[];
  final JmApi api = JmApi(
    dio: dio,
    apiDomains: () => domains,
    onApiDomainsDiscovered: (List<String> latest) => domains = latest,
  );
  final JmSource source = JmSource(
    api: api,
    imageDomain: () => JmApi.imageDomains.first,
  );

  late Gallery first;
  late JmAlbum multiChapterAlbum;

  test('search pages map to JM galleries with page tokens', () async {
    final GalleryPageInfo page = await source.galleryPage(keyword: 'jm:MANA');
    expect(page.gallerys, isNotEmpty);
    first = page.gallerys.first;
    expect(first.galleryUrl.isJM, isTrue);
    expect(first.title, isNotEmpty);
    expect(first.cover.url, contains('/media/albums/${first.galleryUrl.jmChapterId}_3x4.jpg'));
    expect(page.prevGid, isNull);

    final GalleryPageInfo latest = await source.galleryPage();
    expect(latest.gallerys, isNotEmpty);
    expect(latest.nextGid, '2');
    final GalleryPageInfo second = await source.galleryPage(pageToken: latest.nextGid);
    expect(second.prevGid, '1');
    expect(second.gallerys.first.gid, isNot(latest.gallerys.first.gid));
  });

  test('tag search narrows to albums carrying every tag', () async {
    final GalleryPageInfo broad = await source.galleryPage(keyword: 'MANA');
    final GalleryPageInfo narrow = await source.galleryPage(
      keyword: SearchConfig(
        keyword: 'MANA',
        isJmSearch: true,
        tags: <TagData>[TagData(namespace: 'tag', key: '中文')],
      ).computeFullKeywords(),
    );
    expect(narrow.gallerys, isNotEmpty);
    expect(narrow.gallerys.length, lessThanOrEqualTo(broad.gallerys.length));
  });

  test('an album number opens that album', () async {
    final GalleryPageInfo page = await source.galleryPage(
      keyword: '${first.galleryUrl.jmChapterId}',
    );
    expect(page.gallerys.single.gid, first.gid);
    expect(page.gallerys.single.pageCount, greaterThan(0));
  });

  test('detail page carries the chapter pages, thumbnails and comments', () async {
    final ({GalleryDetail galleryDetails, String apikey}) info = await source.detailPage(
      galleryUrl: first.galleryUrl,
      thumbnailsPageIndex: 0,
      parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
    );
    final GalleryDetail detail = info.galleryDetails;
    final JmChapterBundle bundle = await source.bundle(first.galleryUrl.jmChapterId);
    expect(detail.galleryUrl.gid, first.gid);
    expect(detail.pageCount, bundle.pageCount);
    expect(detail.thumbnails.length, bundle.pageCount.clamp(0, JmSource.thumbnailsPerPage));
    expect(detail.thumbnails.first.href, 'jm://${bundle.chapter.id}/1');
    expect(detail.thumbnailsPageCount, (bundle.pageCount / JmSource.thumbnailsPerPage).ceil());
    expect(detail.tags, isNotEmpty);
    expect(detail.commentCount, greaterThanOrEqualTo(detail.comments.length));

    final DetailPageInfo range = await source.detailPage(
      galleryUrl: first.galleryUrl,
      thumbnailsPageIndex: 0,
      parser: EHSpiderParser.detailPage2RangeAndThumbnails,
    );
    expect(range.imageCount, bundle.pageCount);
    expect(range.imageNoFrom, 0);
    expect(range.thumbnails.map((GalleryThumbnail t) => t.href), detail.thumbnails.map((GalleryThumbnail t) => t.href));
  });

  test('an image page downloads and restores to an upright page', () async {
    final GalleryImage image = await source.imagePage(
      href: 'jm://${first.galleryUrl.jmChapterId}/1',
      parser: EHSpiderParser.imagePage2GalleryImage,
    );
    final int strips = JmImage.stripsOf(image.url);
    expect(strips, greaterThan(0), reason: 'new albums are scrambled');
    expect(
      await source.imagePage(
        href: 'jm://${first.galleryUrl.jmChapterId}/1',
        parser: EHSpiderParser.imagePage2GalleryUrl,
      ),
      isA<GalleryUrl>().having((GalleryUrl u) => u.gid, 'gid', first.gid),
    );

    final Response<List<int>> response = await dio.get<List<int>>(
      JmImage.requestUrl(image.url),
      options: Options(responseType: ResponseType.bytes),
    );
    final Uint8List bytes = Uint8List.fromList(response.data!);
    final img.Image stored = img.decodeImage(bytes)!;
    final img.Image restored = img.decodeJpg(await restoreJmImageInBackground(bytes, strips))!;
    expect(restored.width, stored.width);
    expect(restored.height, stored.height);
  });

  test('home sections list comics and their lists page on', () async {
    final List<JmHomeSection> sections = await source.home();
    expect(sections, isNotEmpty);
    expect(sections.every((JmHomeSection s) => s.title.isNotEmpty && s.gallerys.isNotEmpty), isTrue);
    expect(sections.expand((JmHomeSection s) => s.gallerys).every((Gallery g) => g.galleryUrl.isJM), isTrue);

    final JmHomeSection curated = sections.firstWhere((JmHomeSection s) => s.more is JmPromoteQuery);
    final GalleryPageInfo first = await source.list(curated.more!);
    expect(first.gallerys, isNotEmpty);
    expect(first.prevGid, isNull);
    expect(first.nextGid, '1');
    final GalleryPageInfo second = await source.list(curated.more!, pageToken: first.nextGid);
    expect(second.prevGid, '0');
    expect(
      second.gallerys.map((Gallery g) => g.gid).toSet().intersection(first.gallerys.map((Gallery g) => g.gid).toSet()),
      isEmpty,
    );

    // Sections of one category open that category, newest first.
    final JmHomeSection? byCategory = sections.where((JmHomeSection s) => s.more is JmFilterQuery).firstOrNull;
    if (byCategory != null) {
      expect((await source.list(byCategory.more!)).gallerys, isNotEmpty);
    }
  });

  test('categories browse and rank', () async {
    final JmCategories categories = await source.categoryList();
    expect(categories.categories.where((JmCategory c) => c.slug.isNotEmpty), isNotEmpty);
    expect(categories.blocks.expand((JmTagBlock b) => b.tags), isNotEmpty);

    final JmCategory hanman = categories.categories.firstWhere((JmCategory c) => c.slug == 'hanman');
    final GalleryPageInfo newest = await source.list(JmFilterQuery(category: hanman.slug));
    expect(newest.gallerys, isNotEmpty);
    expect(newest.nextGid, '2');

    // A weekly ranking is short and has a single page.
    final GalleryPageInfo weekly = await source.list(const JmFilterQuery(order: 'mv', period: 'w'));
    expect(weekly.gallerys, isNotEmpty);
    expect(weekly.gallerys.length, lessThanOrEqualTo(JmApi.searchPageSize));
    final GalleryPageInfo liked = await source.list(const JmFilterQuery(order: 'tf', period: 'm'));
    expect(liked.gallerys, isNotEmpty);
  });

  test('weekly picks and hot tags', () async {
    final JmWeeks weeks = await source.weeks();
    expect(weeks.issues, isNotEmpty);
    expect(weeks.issues.first.title, isNotEmpty);
    expect(weeks.types.map((({String id, String title}) t) => t.id), contains('hanman'));
    final GalleryPageInfo picks = await source.list(JmWeekQuery(issueId: weeks.issues.first.id, type: weeks.types.first.id));
    expect(picks.gallerys, isNotEmpty);
    expect(picks.nextGid, isNull);

    expect(await source.hotTags(), isNotEmpty);
    // Asked once per run.
    expect(identical(source.weeks(), source.weeks()), isTrue);
  });

  test('details of an album from a list come in one round of requests', () async {
    final Map<String, DateTime> started = <String, DateTime>{};
    final Map<String, DateTime> finished = <String, DateTime>{};
    final Dio timed = Dio(dio.options)
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
            started[options.uri.path] = DateTime.now();
            handler.next(options);
          },
          onResponse: (Response<dynamic> response, ResponseInterceptorHandler handler) {
            finished[response.requestOptions.uri.path] = DateTime.now();
            handler.next(response);
          },
        ),
      );
    final JmSource fresh = JmSource(
      api: JmApi(dio: timed, apiDomains: () => domains, discoverDomains: false),
      imageDomain: () => JmApi.imageDomains.first,
    );
    final GalleryPageInfo list = await fresh.galleryPage(keyword: 'MANA');
    started.clear();
    finished.clear();

    await fresh.detailPage(
      galleryUrl: list.gallerys.first.galleryUrl,
      thumbnailsPageIndex: 0,
      parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
    );

    const List<String> paths = <String>['/chapter', '/album', '/chapter_view_template', '/forum'];
    expect(started.keys, containsAll(paths));
    // Every request went out before any of them came back.
    final DateTime firstBack = paths.map((String p) => finished[p]!).reduce((DateTime a, DateTime b) => a.isBefore(b) ? a : b);
    for (final String path in paths) {
      expect(started[path]!.isBefore(firstBack), isTrue, reason: '$path started after a response');
    }
  });

  test('concurrent first requests for a chapter share one request each', () async {
    final Map<String, int> requests = <String, int>{};
    // Answers with data; a domain answering with a server error is retried
    // on the next one, which is a second attempt but not a second request.
    final Map<String, int> answered = <String, int>{};
    final Dio counting = Dio(dio.options)
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
            requests[options.uri.path] = (requests[options.uri.path] ?? 0) + 1;
            handler.next(options);
          },
          onResponse: (Response<dynamic> response, ResponseInterceptorHandler handler) {
            final String body = utf8.decode(response.data as List<int>, allowMalformed: true);
            final String path = response.requestOptions.uri.path;
            if (path == '/chapter_view_template' || body.trimLeft().startsWith('{')) {
              answered[path] = (answered[path] ?? 0) + 1;
            }
            handler.next(response);
          },
        ),
      );
    final JmApi fresh = JmApi(dio: counting, apiDomains: () => domains, discoverDomains: false);
    final JmSource cold = JmSource(api: fresh, imageDomain: () => JmApi.imageDomains.first);
    final int chapterId = first.galleryUrl.jmChapterId;

    // The downloader parses many pages of a chapter at once.
    await Future.wait(<Future<Object?>>[
      for (int page = 1; page <= 6; page++)
        cold.imagePage(href: 'jm://$chapterId/$page', parser: EHSpiderParser.imagePage2GalleryImage),
      cold.detailPage(
        galleryUrl: first.galleryUrl,
        thumbnailsPageIndex: 0,
        parser: EHSpiderParser.detailPage2RangeAndThumbnails,
      ),
    ]);

    expect(answered['/chapter'], 1);
    expect(answered['/album'], 1);
    expect(answered['/chapter_view_template'], 1);
    expect(answered['/setting'], 1);
    expect(requests['/chapter']! + requests['/album']! + requests['/chapter_view_template']!, lessThanOrEqualTo(3 * domains.length));
  });

  test('chapters of a multi-chapter album are galleries of their own', () async {
    // Most viewed albums are often serialised.
    final JmSearchResult result = await api.search('原神', order: 'mv');
    JmAlbum? album;
    for (final JmAlbumSummary summary in result.albums.take(40)) {
      final JmAlbum candidate = await api.album(summary.id);
      if (candidate.chapters.length > 1) {
        album = candidate;
        break;
      }
    }
    expect(album, isNotNull, reason: 'no multi-chapter album found');
    multiChapterAlbum = album!;
    final JmChapterBundle firstChapter = await source.bundle(album.id);
    expect(firstChapter.isMultiChapter, isTrue);
    expect(firstChapter.chapterIndex, 0);

    final JmChapterRef secondRef = multiChapterAlbum.chapters[1];
    final JmChapterBundle second = await source.bundle(secondRef.id);
    expect(second.chapterIndex, 1);
    expect(second.album.id, multiChapterAlbum.id);
    // A chapter leads to its album, as merging old history entries needs.
    expect((await source.albumOfChapter(secondRef.id)).id, multiChapterAlbum.id);
    expect(second.title, startsWith(multiChapterAlbum.name));
    expect(second.title, isNot(firstChapter.title));
    expect(await source.chapterPageCount(secondRef.id), second.pageCount);

    final ({GalleryDetail galleryDetails, String apikey}) info = await source.detailPage(
      galleryUrl: GalleryUrl.jm(secondRef.id),
      thumbnailsPageIndex: 0,
      parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
    );
    expect(info.galleryDetails.galleryUrl.jmChapterId, secondRef.id);
    expect(info.galleryDetails.pageCount, second.pageCount);
    expect(info.galleryDetails.rawTitle, second.title);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a list names authors only; its cards get the tags from the albums\' details, a few at a time and once', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    log = SilentLogService();
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    appDb = db;
    localConfigService = LocalConfigService();
    addTearDown(db.close);

    int inFlight = 0;
    int mostInFlight = 0;
    final List<String> albumRequests = <String>[];
    final List<int> albumMs = <int>[];
    final Dio counting = Dio(dio.options)
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
            if (options.uri.path == '/album') {
              albumRequests.add('${options.uri.queryParameters['id']}');
              options.extra['startedAt'] = DateTime.now();
              inFlight++;
              mostInFlight = mostInFlight < inFlight ? inFlight : mostInFlight;
            }
            handler.next(options);
          },
          onResponse: (Response<dynamic> response, ResponseInterceptorHandler handler) {
            if (response.requestOptions.uri.path == '/album') {
              inFlight--;
              albumMs.add(DateTime.now().difference(response.requestOptions.extra['startedAt'] as DateTime).inMilliseconds);
            }
            handler.next(response);
          },
          onError: (DioException error, ErrorInterceptorHandler handler) {
            if (error.requestOptions.uri.path == '/album') {
              inFlight--;
            }
            handler.next(error);
          },
        ),
      );
    final JmAlbumTagService tags = JmAlbumTagService();
    final JmSource listed = JmSource(
      api: JmApi(dio: counting, apiDomains: () => domains, discoverDomains: false),
      imageDomain: () => JmApi.imageDomains.first,
      onAlbum: tags.record,
      fillTags: tags.fill,
    );
    tags.loadAlbum = listed.album;

    // Every kind of list: none carries tags.
    final List<Gallery> page = (await listed.galleryPage()).gallerys;
    final List<Gallery> searched = (await listed.galleryPage(keyword: 'MANA')).gallerys;
    final List<Gallery> ranked = (await listed.list(const JmFilterQuery(category: '0', order: 'mv', period: 'w'))).gallerys;
    for (final Gallery gallery in <Gallery>[...page, ...searched, ...ranked]) {
      expect(JmAlbumTagService.lacksTags(gallery), isTrue, reason: gallery.title);
    }
    expect(albumRequests, isEmpty);

    // Twelve cards show.
    final List<Gallery> shown = page.take(12).toList();
    final Map<int, JmAlbumTags> arrived = <int, JmAlbumTags>{};
    tags.loaded.listen((({int albumId, JmAlbumTags tags}) loaded) => arrived[loaded.albumId] = loaded.tags);
    final Stopwatch watch = Stopwatch()..start();
    for (final Gallery gallery in shown) {
      tags.want(gallery.galleryUrl.jmChapterId);
    }
    while (arrived.length < shown.length && watch.elapsed < const Duration(seconds: 90)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    watch.stop();
    expect(arrived.keys.toSet(), shown.map((Gallery g) => g.galleryUrl.jmChapterId).toSet());
    expect(albumRequests.toSet().length, shown.length);
    expect(mostInFlight, lessThanOrEqualTo(JmAlbumTagService.concurrency));
    // Albums carry tags beyond their author.
    expect(arrived.values.where((JmAlbumTags t) => (t['tag'] ?? const <String>[]).isNotEmpty).length, greaterThan(shown.length ~/ 2));
    albumMs.sort();
    // ignore: avoid_print
    print('tags of ${shown.length} albums in ${watch.elapsedMilliseconds} ms; '
        'a details request: median ${albumMs[albumMs.length ~/ 2]} ms, slowest ${albumMs.last} ms; '
        'at most $mostInFlight at once');
    // ignore: avoid_print
    print('e.g. ${shown.first.title}: ${arrived[shown.first.galleryUrl.jmChapterId]}');

    // The same list again: the tags come with the page, nothing is asked.
    final int asked = albumRequests.length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final List<Gallery> again = (await listed.galleryPage()).gallerys;
    final Set<int> known = arrived.keys.toSet();
    for (final Gallery gallery in again.where((Gallery g) => known.contains(g.galleryUrl.jmChapterId))) {
      expect(JmAlbumTagService.lacksTags(gallery) && (arrived[gallery.galleryUrl.jmChapterId]!['tag'] ?? const <String>[]).isNotEmpty, isFalse,
          reason: gallery.title);
    }
    expect(again.where((Gallery g) => known.contains(g.galleryUrl.jmChapterId)), isNotEmpty);
    expect(albumRequests.length, asked);
  });
}
