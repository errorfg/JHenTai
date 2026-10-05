import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
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
import 'package:jhentai/src/utils/eh_spider_parser.dart';

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
}
