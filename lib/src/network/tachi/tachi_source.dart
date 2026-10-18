import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:intl/intl.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/exception/eh_site_exception.dart';
import 'package:jhentai/src/model/detail_page_info.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_detail.dart';
import 'package:jhentai/src/model/gallery_history_model.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/model/series.dart';
import 'package:jhentai/src/service/series_reading_service.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';

import 'tachi_client.dart';
import 'tachi_host.dart';
import 'tachi_models.dart';

SeriesReadingService tachiReadingService = SeriesReadingService(
  prefix: 'tachi',
  gidOf: (int chapterId) => GalleryUrl.tachiGidOffset + chapterId,
);

/// Images of Tachiyomi sources are kept as `tachi-cover://` and
/// `tachi-image://` addresses (the source and the site's URL); the host's
/// port and token change with every start, so the address it serves them at
/// is worked out when an image is shown.
class TachiImages {
  static const String _cover = 'tachi-cover';
  static const String _page = 'tachi-image';

  static String cover(String source, String? url) => url == null || url.isEmpty ? '' : Uri(scheme: _cover, host: source, queryParameters: <String, String>{'u': url}).toString();

  static String page(String source, TachiPage page) => Uri(
        scheme: _page,
        host: source,
        queryParameters: <String, String>{
          if (page.imageUrl != null) 'u': page.imageUrl!,
          if (page.url.isNotEmpty) 'p': page.url,
          'i': '${page.index}',
        },
      ).toString();

  static bool isTachi(String url) => url.startsWith('$_cover://') || url.startsWith('$_page://');

  /// Where the running host serves [url], and the key it is cached under
  /// (the same on every start).
  static ({Uri uri, String cacheKey}) resolve(TachiClient client, String url) {
    final Uri pseudo = Uri.parse(url);
    final String source = pseudo.host;
    final Map<String, String> q = pseudo.queryParameters;
    // The image cache names its files by the key: a hash, not the URL.
    String key(String text) => sha1.convert(utf8.encode(text)).toString();
    if (pseudo.scheme == _cover) {
      return (uri: client.coverUri(source, q['u']!), cacheKey: key('tachi-cover|$source|${q['u']}'));
    }
    return (
      uri: client.imageUri(source, imageUrl: q['u'], pageUrl: q['p'] ?? '', index: int.tryParse(q['i'] ?? '') ?? 0),
      cacheKey: key('tachi-image|$source|${q['u'] ?? q['p']}'),
    );
  }

  /// What the image cache fetches [url] with, from the running host: its
  /// address, [headers] with the host's token, and [cacheKey] or the key of
  /// [resolve]. The reader shows a page so, and the upscaler reads it so.
  static ({String url, Map<String, String> headers, String cacheKey}) request(
    TachiClient client,
    String url, {
    Map<String, String>? headers,
    String? cacheKey,
  }) {
    final ({Uri uri, String cacheKey}) resolved = resolve(client, url);
    return (url: resolved.uri.toString(), headers: <String, String>{...?headers, ...client.authHeaders}, cacheKey: cacheKey ?? resolved.cacheKey);
  }
}

/// A manga with its chapters in the order the source lists them (newest
/// first, as Tachiyomi sources do).
class TachiMangaEntry {
  const TachiMangaEntry({required this.source, required this.manga, required this.chapters});

  final String source;
  final TachiManga manga;
  final List<TachiChapter> chapters;

  GalleryUrl get url => GalleryUrl.tachiManga(source, manga.url);

  /// Chapters in reading order, oldest first.
  List<SeriesChapter> get readingOrder => <SeriesChapter>[
        for (final TachiChapter chapter in chapters.reversed)
          SeriesChapter(
            id: TachiSource.idOf(GalleryUrl.tachiChapter(source, manga.url, chapter.url)),
            url: GalleryUrl.tachiChapter(source, manga.url, chapter.url),
            name: chapter.name,
            date: chapter.dateUpload > 0 ? DateTime.fromMillisecondsSinceEpoch(chapter.dateUpload) : null,
          ),
      ];
}

class TachiChapterBundle implements SeriesBundle {
  TachiChapterBundle({required this.entry, required this.chapter, required this.pages});

  final TachiMangaEntry entry;
  final TachiChapter chapter;
  final List<TachiPage> pages;

  String get source => entry.source;

  @override
  int get seriesId => TachiSource.idOf(entry.url);

  @override
  GalleryUrl get seriesUrl => entry.url;

  @override
  String get seriesTitle => entry.manga.title;

  @override
  late final List<SeriesChapter> chapters = entry.readingOrder;

  @override
  GalleryUrl get galleryUrl => GalleryUrl.tachiChapter(source, entry.manga.url, chapter.url);

  @override
  int get chapterId => TachiSource.idOf(galleryUrl);

  @override
  int get chapterIndex => chapters.indexWhere((SeriesChapter c) => c.url.gid == galleryUrl.gid);

  @override
  bool get isMultiChapter => chapters.length > 1;

  @override
  String get title => isMultiChapter ? '${entry.manga.title} - ${chapter.name}' : entry.manga.title;

  @override
  int get pageCount => pages.length;

  @override
  int get seriesPageCount => 0;

  @override
  String? get author => entry.manga.author;

  @override
  List<GalleryThumbnail> pageThumbnails() => <GalleryThumbnail>[
        for (final TachiPage page in pages)
          GalleryThumbnail(
            href: TachiSource.pageHref(galleryUrl, page.index),
            isLarge: true,
            thumbUrl: TachiImages.page(source, page),
            thumbWidth: null,
            thumbHeight: null,
            originImageHash: 'tachi-${galleryUrl.gid}-${page.index}',
          ),
      ];
}

/// Serves the app's gallery requests (lists, details, image pages) from
/// Tachiyomi sources through the extension host, in the shapes the
/// E-Hentai parsers produce. A manga is a series; each chapter is a gallery.
class TachiSource implements SeriesSource {
  static const int thumbnailsPerPage = 40;

  final Map<int, Future<TachiMangaEntry>> _mangas = <int, Future<TachiMangaEntry>>{};
  final Map<int, Future<List<TachiPage>>> _pages = <int, Future<List<TachiPage>>>{};

  /// Manga seen in lists, by gid: details pages start from what they show.
  final Map<int, TachiManga> _listed = <int, TachiManga>{};

  @override
  SeriesReadingService get reading => tachiReadingService;

  /// The id of a manga or chapter among the progress records.
  static int idOf(GalleryUrl url) => url.gid - GalleryUrl.tachiGidOffset;

  static String pageHref(GalleryUrl chapter, int index) => Uri(
        scheme: 'tachi',
        host: 'page',
        queryParameters: <String, String>{'s': chapter.tachiSource!, 'm': chapter.tachiMangaPath!, 'c': chapter.tachiChapterPath!, 'i': '$index'},
      ).toString();

  static ({GalleryUrl chapter, int index})? parsePageHref(String href) {
    if (!href.startsWith('tachi://page')) {
      return null;
    }
    final Map<String, String> q = Uri.parse(href).queryParameters;
    final String? s = q['s'], m = q['m'], c = q['c'];
    final int? i = int.tryParse(q['i'] ?? '');
    if (s == null || m == null || c == null || i == null) {
      return null;
    }
    return (chapter: GalleryUrl.tachiChapter(s, m, c), index: i);
  }

  Future<T> _run<T>(Future<T> Function(TachiClient client) action) => tachiHost.run(action);

  /// A page of [source]'s popular or latest list, or of a search when
  /// [query] or [filters] are given; [pageToken] is the page number as text.
  Future<GalleryPageInfo> list({
    required String source,
    bool latest = false,
    String? query,
    List<TachiFilter>? filters,
    String? pageToken,
  }) async {
    final int page = (int.tryParse(pageToken ?? '') ?? 1).clamp(1, 1 << 30);
    final bool search = (query?.trim().isNotEmpty ?? false) || filters != null;
    final TachiMangasPage result = await _run(
      (TachiClient c) => search ? c.search(source, page, query?.trim() ?? '', filters: filters) : (latest ? c.latest(source, page) : c.popular(source, page)),
    );
    return GalleryPageInfo(
      gallerys: result.mangas.map((TachiManga m) => galleryOf(source, m)).toList(),
      prevGid: page > 1 ? '${page - 1}' : null,
      nextGid: result.hasNextPage ? '${page + 1}' : null,
    );
  }

  Gallery galleryOf(String source, TachiManga manga) {
    final GalleryUrl url = GalleryUrl.tachiManga(source, manga.url);
    _listed[url.gid] = manga;
    return Gallery(
      galleryUrl: url,
      title: manga.title,
      category: 'Manga',
      cover: GalleryImage(url: TachiImages.cover(source, manga.thumbnailUrl)),
      rating: 0,
      hasRated: false,
      uploader: _nonEmpty(manga.author),
      publishTime: '',
      isExpunged: false,
      tags: _tags(manga),
    );
  }

  /// The manga's details and chapters; [refresh] asks the site again.
  Future<TachiMangaEntry> manga(GalleryUrl url, {bool refresh = false}) {
    final GalleryUrl mangaUrl = url.tachiMangaUrl;
    if (refresh) {
      _mangas.remove(mangaUrl.gid);
    }
    return _mangas[mangaUrl.gid] ??= _loadManga(mangaUrl).catchError((Object e) {
      _mangas.remove(mangaUrl.gid);
      throw e;
    });
  }

  Future<TachiMangaEntry> _loadManga(GalleryUrl url) async {
    final String source = url.tachiSource!;
    final TachiManga known = _listed[url.gid] ?? TachiManga(url: url.tachiMangaPath!, title: '');
    final (TachiManga details, List<TachiChapter> chapters) = await _run(
      (TachiClient c) async => (await c.details(source, known), await c.chapters(source, known)),
    );
    return TachiMangaEntry(source: source, manga: details.title.isEmpty ? known : details, chapters: chapters);
  }

  Future<List<TachiPage>> pagesOf(GalleryUrl chapter, {bool refresh = false}) {
    if (refresh) {
      _pages.remove(chapter.gid);
    }
    return _pages[chapter.gid] ??= _run((TachiClient c) async {
      final TachiMangaEntry entry = await manga(chapter);
      final TachiChapter found = entry.chapters.firstWhere(
        (TachiChapter c) => c.url == chapter.tachiChapterPath,
        orElse: () => TachiChapter(url: chapter.tachiChapterPath!, name: ''),
      );
      return c.pages(chapter.tachiSource!, found);
    }).catchError((Object e) {
      _pages.remove(chapter.gid);
      throw e;
    });
  }

  @override
  Future<TachiChapterBundle> bundle(GalleryUrl chapter, {bool refresh = false}) async {
    final TachiMangaEntry entry = await manga(chapter, refresh: refresh);
    final TachiChapter found = entry.chapters.firstWhere(
      (TachiChapter c) => c.url == chapter.tachiChapterPath,
      orElse: () => throw EHSiteException(
        type: EHSiteExceptionType.galleryDeleted,
        message: 'The chapter is no longer listed by the source',
        shouldPauseAllDownloadTasks: false,
      ),
    );
    return TachiChapterBundle(entry: entry, chapter: found, pages: await pagesOf(chapter, refresh: refresh));
  }

  @override
  Future<int> chapterPageCount(GalleryUrl chapter) async => (await pagesOf(chapter)).length;

  @override
  String chapterTitle(SeriesBundle bundle, int index) {
    final TachiChapterBundle b = bundle as TachiChapterBundle;
    final SeriesChapter chapter = b.chapters[index];
    return b.isMultiChapter ? '${b.seriesTitle} - ${chapter.name}' : b.seriesTitle;
  }

  Future<T> detailPage<T>({
    required GalleryUrl galleryUrl,
    required int thumbnailsPageIndex,
    required HtmlParser<T> parser,
    bool useCache = true,
  }) async {
    final TachiChapterBundle b = await bundle(galleryUrl, refresh: !useCache);
    if (parser == EHSpiderParser.detailPage2GalleryAndDetailAndApikey) {
      return (galleryDetails: _detail(b), apikey: '') as T;
    }
    if (parser == EHSpiderParser.detailPage2Thumbnails) {
      return _thumbnails(b, thumbnailsPageIndex) as T;
    }
    if (parser == EHSpiderParser.detailPage2RangeAndThumbnails) {
      return _detailPageInfo(b, thumbnailsPageIndex) as T;
    }
    if (parser == EHSpiderParser.detailPage2Comments) {
      return const <dynamic>[] as T;
    }
    throw EHSiteException(type: EHSiteExceptionType.internalError, message: 'Unsupported Tachiyomi detail parser', shouldPauseAllDownloadTasks: false);
  }

  Future<T> imagePage<T>({required String href, required HtmlParser<T> parser}) async {
    final ({GalleryUrl chapter, int index})? target = parsePageHref(href);
    if (target == null) {
      throw EHSiteException(type: EHSiteExceptionType.internalError, message: 'Invalid Tachiyomi page', shouldPauseAllDownloadTasks: false);
    }
    if (parser == EHSpiderParser.imagePage2GalleryUrl) {
      return target.chapter as T;
    }
    final List<TachiPage> pages = await pagesOf(target.chapter);
    final TachiPage page = pages.firstWhere(
      (TachiPage p) => p.index == target.index,
      orElse: () => target.index < pages.length
          ? pages[target.index]
          : throw EHSiteException(type: EHSiteExceptionType.internalError, message: 'Invalid Tachiyomi page index', shouldPauseAllDownloadTasks: false),
    );
    final String url = TachiImages.page(target.chapter.tachiSource!, page);
    return GalleryImage(url: url, originalImageUrl: url, imageHash: 'tachi-${target.chapter.gid}-${target.index}') as T;
  }

  /// The history entry of a manga as a whole.
  GalleryHistoryModel historyModelOf(TachiChapterBundle b) {
    final Gallery gallery = galleryOf(b.source, b.entry.manga);
    return GalleryHistoryModel(
      galleryUrl: gallery.galleryUrl,
      title: gallery.title,
      category: gallery.category,
      coverUrl: gallery.cover.url,
      pageCount: b.pageCount,
      rating: 0,
      language: '',
      uploader: gallery.uploader ?? '',
      publishTime: '',
      isExpunged: false,
      tags: <String>[
        for (final List<GalleryTag> tags in gallery.tags.values)
          for (final GalleryTag tag in tags) '${tag.tagData.namespace}:${tag.tagData.key}',
      ],
    );
  }

  GalleryDetail _detail(TachiChapterBundle b) {
    final TachiManga manga = b.entry.manga;
    final DateTime? date = b.chapter.dateUpload > 0 ? DateTime.fromMillisecondsSinceEpoch(b.chapter.dateUpload) : null;
    return GalleryDetail(
      galleryUrl: b.galleryUrl,
      rawTitle: b.title,
      japaneseTitle: null,
      category: 'Manga',
      cover: GalleryImage(url: TachiImages.cover(b.source, manga.thumbnailUrl)),
      pageCount: b.pageCount,
      rating: 0,
      realRating: 0,
      hasRated: false,
      ratingCount: 0,
      favoriteTagIndex: null,
      favoriteTagName: null,
      favoriteCount: 0,
      language: '',
      uploader: _nonEmpty(manga.author),
      publishTime: date == null ? '' : DateFormat('yyyy-MM-dd HH:mm').format(date),
      isExpunged: false,
      tags: _tags(manga),
      size: '${b.pageCount} pages',
      torrentCount: '0',
      torrentPageUrl: '',
      archivePageUrl: '',
      parentGalleryUrl: null,
      childrenGallerys: const [],
      comments: const [],
      commentCount: 0,
      relatedGallerys: const [],
      thumbnails: _thumbnails(b, 0),
      thumbnailsPageCount: (b.pageCount / thumbnailsPerPage).ceil().clamp(1, 1 << 30),
      description: _nonEmpty(manga.description),
    );
  }

  List<GalleryThumbnail> _thumbnails(TachiChapterBundle b, int pageIndex) {
    final List<GalleryThumbnail> all = b.pageThumbnails();
    final int start = pageIndex * thumbnailsPerPage;
    if (start < 0 || start >= all.length) {
      return const <GalleryThumbnail>[];
    }
    return all.sublist(start, (start + thumbnailsPerPage).clamp(0, all.length));
  }

  DetailPageInfo _detailPageInfo(TachiChapterBundle b, int pageIndex) {
    if (b.pageCount == 0) {
      return const DetailPageInfo(imageNoFrom: 0, imageNoTo: 0, imageCount: 0, currentPageNo: 1, pageCount: 1, thumbnails: []);
    }
    final int pageCount = (b.pageCount / thumbnailsPerPage).ceil();
    final int current = (pageIndex + 1).clamp(1, pageCount);
    final int from = (current - 1) * thumbnailsPerPage;
    final int toExclusive = (from + thumbnailsPerPage).clamp(0, b.pageCount);
    return DetailPageInfo(
      imageNoFrom: from,
      imageNoTo: toExclusive - 1,
      imageCount: b.pageCount,
      currentPageNo: current,
      pageCount: pageCount,
      thumbnails: _thumbnails(b, current - 1),
    );
  }

  static LinkedHashMap<String, List<GalleryTag>> _tags(TachiManga manga) {
    final LinkedHashMap<String, List<GalleryTag>> tags = LinkedHashMap<String, List<GalleryTag>>();
    void add(String namespace, Iterable<String> values) {
      final List<String> list = values.map((String v) => v.trim()).where((String v) => v.isNotEmpty).toSet().toList();
      if (list.isNotEmpty) {
        tags[namespace] = list.map((String key) => GalleryTag(tagData: TagData(namespace: namespace, key: key))).toList();
      }
    }

    add('artist', <String>{...?manga.author?.split(','), ...?manga.artist?.split(',')});
    add('tag', manga.genres);
    return tags;
  }

  static String? _nonEmpty(String? value) => value == null || value.trim().isEmpty ? null : value.trim();
}
