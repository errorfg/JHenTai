import 'dart:collection';

import 'package:html/dom.dart' as html_dom;
import 'package:intl/intl.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/exception/eh_site_exception.dart';
import 'package:jhentai/src/model/detail_page_info.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_comment.dart';
import 'package:jhentai/src/model/gallery_detail.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';

import 'jm_api.dart';
import 'jm_image.dart';
import 'jm_models.dart';

/// A chapter with its album and the scramble threshold for its images.
class JmChapterBundle {
  const JmChapterBundle({
    required this.album,
    required this.chapter,
    required this.scrambleId,
  });

  final JmAlbum album;
  final JmChapter chapter;
  final int scrambleId;

  int get chapterIndex => album.chapters.indexWhere(
    (JmChapterRef ref) => ref.id == chapter.id,
  );

  bool get isMultiChapter => album.chapters.length > 1;

  GalleryUrl get galleryUrl => GalleryUrl.jm(chapter.id);

  String get title => JmSource.chapterTitle(album, chapterIndex);

  int get pageCount => chapter.images.length;

  String imageUrl(String imageDomain, int index) {
    final String fileName = chapter.images[index];
    return JmImage.pageUrl(
      imageDomain: imageDomain,
      chapterId: chapter.id,
      fileName: fileName,
      strips: JmImage.stripCount(
        scrambleId: scrambleId,
        chapterId: chapter.id,
        fileName: fileName,
      ),
    );
  }
}

/// Serves the app's gallery requests (list, detail, image page) from the
/// JM API, in the shapes the E-Hentai parsers would produce.
class JmSource {
  JmSource({required this.api, required this.imageDomain});

  static const int thumbnailsPerPage = 40;

  final JmApi api;
  final String Function() imageDomain;

  /// Requests in flight or done, so concurrent callers (the downloader
  /// parses many pages of a chapter at once) share one request.
  final Map<int, Future<JmAlbum>> _albums = <int, Future<JmAlbum>>{};
  final Map<int, Future<JmChapter>> _chapters = <int, Future<JmChapter>>{};
  final Map<int, int> _albumIdOfChapter = <int, int>{};

  /// E-Hentai category of albums seen in lists; album details lack it.
  final Map<int, String> _categories = <int, String>{};

  /// JM search takes MySQL boolean full-text syntax: words separated by
  /// spaces match any of them, `+word` must match, `-word` must not. Free
  /// text is passed as typed; tags (`namespace:"value$"` from tag taps and
  /// tag search) become required words, since selecting tags means all of
  /// them.
  static String normalizeKeyword(String? raw) {
    String keyword = (raw ?? '').trim();
    if (keyword.toLowerCase().startsWith('jm:')) {
      keyword = keyword.substring(3).trim();
    }
    return keyword
        .replaceAllMapped(
          RegExp(r'\b\w+:"([^"]+?)\$?"|\b\w+:(\S+)'),
          (Match m) => (m.group(1) ?? m.group(2)!)
              .split(RegExp(r'\s+'))
              .where((String word) => word.isNotEmpty)
              .map((String word) => '+$word')
              .join(' '),
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// [pageToken] is the page number as text, as other sources use.
  Future<GalleryPageInfo> galleryPage({
    String? keyword,
    String? pageToken,
  }) async {
    final int page = (int.tryParse(pageToken ?? '') ?? 1).clamp(1, 1 << 30);
    final String query = normalizeKeyword(keyword);
    final JmSearchResult result = query.isEmpty
        ? await api.latest(page: page)
        : await api.search(query, page: page);

    final int? redirect = result.redirectAlbumId;
    if (redirect != null) {
      final JmAlbum album = await _album(redirect);
      return GalleryPageInfo(gallerys: <Gallery>[_galleryOfAlbum(album)]);
    }

    final List<Gallery> gallerys = result.albums.map(_galleryOfSummary).toList();
    final int pages = (result.total / JmApi.searchPageSize).ceil();
    final bool hasNext = result.total > 0
        ? page < pages
        : gallerys.isNotEmpty;
    return GalleryPageInfo(
      gallerys: gallerys,
      prevGid: page > 1 ? '${page - 1}' : null,
      nextGid: hasNext ? '${page + 1}' : null,
    );
  }

  /// [refresh] drops the cached chapter and album first, so a manual
  /// refresh shows newly added chapters.
  Future<JmChapterBundle> bundle(int chapterId, {bool refresh = false}) async {
    if (refresh) {
      _chapters.remove(chapterId);
      _albums.remove(_albumIdOfChapter[chapterId]);
    }
    final JmChapter chapter = await _chapter(chapterId);
    _albumIdOfChapter[chapter.id] = chapter.albumId;
    final JmAlbum album = await _album(chapter.albumId);
    final int scrambleId = await api.scrambleId(chapter.id);
    return JmChapterBundle(
      album: album,
      chapter: chapter,
      scrambleId: scrambleId,
    );
  }

  Future<T> detailPage<T>({
    required GalleryUrl galleryUrl,
    required int thumbnailsPageIndex,
    required HtmlParser<T> parser,
    bool useCache = true,
  }) async {
    final JmChapterBundle b = await bundle(
      galleryUrl.jmChapterId,
      refresh: !useCache,
    );
    if (parser == EHSpiderParser.detailPage2GalleryAndDetailAndApikey) {
      final List<GalleryComment> comments = await _commentsOrEmpty(b.album.id);
      return (galleryDetails: _detail(b, comments), apikey: '') as T;
    }
    if (parser == EHSpiderParser.detailPage2Thumbnails) {
      return _thumbnails(b, thumbnailsPageIndex) as T;
    }
    if (parser == EHSpiderParser.detailPage2RangeAndThumbnails) {
      return _detailPageInfo(b, thumbnailsPageIndex) as T;
    }
    if (parser == EHSpiderParser.detailPage2Comments) {
      return (await _comments(b.album.id)) as T;
    }
    throw EHSiteException(
      type: EHSiteExceptionType.internalError,
      message: 'Unsupported JM detail parser',
      shouldPauseAllDownloadTasks: false,
    );
  }

  Future<T> imagePage<T>({
    required String href,
    required HtmlParser<T> parser,
  }) async {
    final RegExpMatch? match = RegExp(r'^jm://(\d+)/(\d+)$').firstMatch(href);
    if (match == null) {
      throw EHSiteException(
        type: EHSiteExceptionType.internalError,
        message: 'Invalid JM image url',
        shouldPauseAllDownloadTasks: false,
      );
    }
    final int chapterId = int.parse(match.group(1)!);
    final int pageNo = int.parse(match.group(2)!);
    if (parser == EHSpiderParser.imagePage2GalleryUrl) {
      return GalleryUrl.jm(chapterId) as T;
    }
    final JmChapterBundle b = await bundle(chapterId);
    if (pageNo < 1 || pageNo > b.pageCount) {
      throw EHSiteException(
        type: EHSiteExceptionType.internalError,
        message: 'Invalid JM image index',
        shouldPauseAllDownloadTasks: false,
      );
    }
    final String url = b.imageUrl(imageDomain(), pageNo - 1);
    return GalleryImage(
          url: url,
          originalImageUrl: url,
          imageHash: 'jm-$chapterId-$pageNo',
        )
        as T;
  }

  /// Pages of chapter [chapterId], without the extra request for the
  /// scramble threshold that [bundle] makes.
  Future<int> chapterPageCount(int chapterId) async =>
      (await _chapter(chapterId)).images.length;

  static String chapterTitle(JmAlbum album, int chapterIndex) {
    if (album.chapters.length <= 1 || chapterIndex < 0) {
      return album.name;
    }
    return '${album.name} - ${chapterName(album.chapters[chapterIndex])}';
  }

  /// Chapters without a name are numbered.
  static String chapterName(JmChapterRef chapter) =>
      chapter.name.trim().isEmpty ? '#${chapter.sort}' : chapter.name.trim();

  /// JM category titles mapped onto E-Hentai categories, so list cards can
  /// colour them.
  static String category(String title, String subTitle) {
    if (subTitle.toUpperCase().contains('CG')) {
      return 'Artist CG';
    }
    return switch (title) {
      '同人' => 'Doujinshi',
      '單本' || '单本' || '短篇' || '韓漫' || '韩漫' => 'Manga',
      'English Manga' || '美漫' => 'Western',
      'Cosplay' => 'Cosplay',
      _ => 'Misc',
    };
  }

  static String language(List<String> tags) {
    if (tags.any((String t) => t.contains('中文') || t.contains('漢化') || t.contains('汉化'))) {
      return 'Chinese';
    }
    if (tags.any((String t) => t.contains('日文') || t.contains('日語') || t.contains('日语'))) {
      return 'Japanese';
    }
    if (tags.any((String t) => t.contains('英文') || t.toLowerCase() == 'english')) {
      return 'English';
    }
    return 'N/A';
  }

  Future<JmAlbum> _album(int id) =>
      sharedRequest(_albums, id, () => api.album(id));

  Future<JmChapter> _chapter(int id) =>
      sharedRequest(_chapters, id, () => api.chapter(id));


  Gallery _galleryOfSummary(JmAlbumSummary summary) {
    final String category = JmSource.category(
      summary.categoryTitle,
      summary.subCategoryTitle,
    );
    _categories[summary.id] = category;
    return Gallery(
      galleryUrl: GalleryUrl.jm(summary.id),
      title: summary.name,
      category: category,
      cover: GalleryImage(
        url: JmImage.coverUrl(imageDomain: imageDomain(), albumId: summary.id),
      ),
      pageCount: null,
      rating: 0,
      hasRated: false,
      favoriteTagIndex: null,
      favoriteTagName: null,
      language: null,
      uploader: summary.author.isEmpty ? null : summary.author,
      publishTime: summary.updateAt == null ? '' : _format(summary.updateAt!),
      isExpunged: false,
      tags: summary.author.isEmpty
          ? LinkedHashMap<String, List<GalleryTag>>()
          : _tagMap(<String, List<String>>{
              'artist': <String>[summary.author],
            }),
    );
  }

  Gallery _galleryOfAlbum(JmAlbum album) => Gallery(
    galleryUrl: GalleryUrl.jm(album.id),
    title: album.name,
    category: _categories[album.id] ?? 'Manga',
    cover: GalleryImage(
      url: JmImage.coverUrl(imageDomain: imageDomain(), albumId: album.id),
    ),
    pageCount: album.totalPhotos,
    rating: 0,
    hasRated: false,
    favoriteTagIndex: null,
    favoriteTagName: null,
    language: language(album.tags),
    uploader: album.authors.isEmpty ? null : album.authors.first,
    publishTime: _format(album.addTime),
    isExpunged: false,
    tags: _albumTags(album),
  );

  GalleryDetail _detail(JmChapterBundle b, List<GalleryComment> comments) {
    final JmAlbum album = b.album;
    return GalleryDetail(
      galleryUrl: b.galleryUrl,
      rawTitle: b.title,
      japaneseTitle: null,
      category: _categories[album.id] ?? 'Manga',
      cover: GalleryImage(
        url: JmImage.coverUrl(imageDomain: imageDomain(), albumId: album.id),
      ),
      pageCount: b.pageCount,
      rating: 0,
      realRating: 0,
      hasRated: false,
      ratingCount: 0,
      favoriteTagIndex: null,
      favoriteTagName: null,
      favoriteCount: album.likes,
      language: language(album.tags),
      uploader: album.authors.isEmpty ? null : album.authors.first,
      publishTime: _format(album.addTime),
      isExpunged: false,
      tags: _albumTags(album),
      size: '${b.pageCount} pages',
      torrentCount: '0',
      torrentPageUrl: '',
      archivePageUrl: '',
      parentGalleryUrl: null,
      childrenGallerys: const [],
      comments: comments,
      commentCount: album.commentCount,
      relatedGallerys: album.related.map(_galleryOfSummary).toList(),
      thumbnails: _thumbnails(b, 0),
      thumbnailsPageCount: (b.pageCount / thumbnailsPerPage).ceil().clamp(1, 1 << 30),
    );
  }

  List<GalleryThumbnail> _thumbnails(JmChapterBundle b, int pageIndex) {
    final int start = pageIndex * thumbnailsPerPage;
    if (start < 0 || start >= b.pageCount) {
      return const <GalleryThumbnail>[];
    }
    final int end = (start + thumbnailsPerPage).clamp(0, b.pageCount);
    return <GalleryThumbnail>[
      for (int i = start; i < end; i++)
        GalleryThumbnail(
          href: 'jm://${b.chapter.id}/${i + 1}',
          isLarge: true,
          thumbUrl: b.imageUrl(imageDomain(), i),
          thumbWidth: null,
          thumbHeight: null,
          originImageHash: 'jm-${b.chapter.id}-${i + 1}',
        ),
    ];
  }

  DetailPageInfo _detailPageInfo(JmChapterBundle b, int pageIndex) {
    if (b.pageCount == 0) {
      return const DetailPageInfo(
        imageNoFrom: 0,
        imageNoTo: 0,
        imageCount: 0,
        currentPageNo: 1,
        pageCount: 1,
        thumbnails: [],
      );
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

  Future<List<GalleryComment>> _comments(int albumId) async {
    final List<JmComment> comments = await api.comments(albumId);
    return comments
        .map(
          (JmComment c) => GalleryComment(
            id: c.id,
            username: c.nickname,
            score: '',
            scoreDetails: const <String>[],
            content: html_dom.Element.html('<div>${c.content}</div>'),
            time: c.time,
            fromMe: false,
            votedUp: false,
            votedDown: false,
            showScore: false,
          ),
        )
        .toList();
  }

  /// Comments are a nicety on the detail page; their failure must not
  /// hide the gallery.
  Future<List<GalleryComment>> _commentsOrEmpty(int albumId) async {
    try {
      return await _comments(albumId);
    } catch (_) {
      return const <GalleryComment>[];
    }
  }

  LinkedHashMap<String, List<GalleryTag>> _albumTags(JmAlbum album) =>
      _tagMap(<String, List<String>>{
        'artist': album.authors,
        'parody': album.works,
        'character': album.actors,
        'tag': album.tags,
      });

  static LinkedHashMap<String, List<GalleryTag>> _tagMap(
    Map<String, List<String>> byNamespace,
  ) {
    final LinkedHashMap<String, List<GalleryTag>> tags =
        LinkedHashMap<String, List<GalleryTag>>();
    byNamespace.forEach((String namespace, List<String> values) {
      if (values.isEmpty) {
        return;
      }
      tags[namespace] = values
          .map(
            (String key) => GalleryTag(
              tagData: TagData(namespace: namespace, key: key),
            ),
          )
          .toList();
    });
    return tags;
  }

  static String _format(DateTime utc) =>
      DateFormat('yyyy-MM-dd HH:mm').format(utc.toUtc());
}
