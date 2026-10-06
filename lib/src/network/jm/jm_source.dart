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

/// What a JM album list shows; [JmSource.list] pages through it.
sealed class JmListQuery {
  const JmListQuery();
}

/// The curated list behind a home section.
class JmPromoteQuery extends JmListQuery {
  const JmPromoteQuery(this.id);

  final int id;
}

/// A category (slug, `0` for all), newest first or ranked; see
/// [JmApi.filter] for [order] and [period].
class JmFilterQuery extends JmListQuery {
  const JmFilterQuery({this.category = '0', this.order = 'mr', this.period = 'a'});

  final String category;
  final String order;
  final String period;
}

/// A weekly pick: one issue, one kind.
class JmWeekQuery extends JmListQuery {
  const JmWeekQuery({required this.issueId, required this.type});

  final String issueId;
  final String type;
}

/// A home section that lists comics, and the list its "more" opens.
typedef JmHomeSection = ({String title, List<Gallery> gallerys, JmListQuery? more});

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
  /// Album of each chapter seen, and ids known to be albums (from lists):
  /// with these a detail page requests chapter and album at once.
  final Map<int, int> _albumIdOfChapter = <int, int>{};
  final Set<int> _albumIds = <int>{};

  int? _knownAlbumOf(int chapterId) =>
      _albumIdOfChapter[chapterId] ?? (_albumIds.contains(chapterId) ? chapterId : null);

  /// [chapterId] belongs to [albumId], as recorded earlier: its details are
  /// requested together with the album's.
  void rememberAlbumOf(int chapterId, int albumId) {
    _albumIdOfChapter[chapterId] = albumId;
  }

  /// E-Hentai category of albums seen in lists; album details lack it.
  final Map<int, String> _categories = <int, String>{};

  /// Lookups that change rarely, requested once per run (key 0).
  final Map<int, Future<JmCategories>> _categoryList = <int, Future<JmCategories>>{};
  final Map<int, Future<JmWeeks>> _weeks = <int, Future<JmWeeks>>{};
  final Map<int, Future<List<String>>> _hotTags = <int, Future<List<String>>>{};

  /// Page size of each curated list, from its first page.
  final Map<int, int> _promotePageSizes = <int, int>{};

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

    return _pageOf(result, page);
  }

  GalleryPageInfo _pageOf(JmSearchResult result, int page) {
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

  /// A page of [query]; [pageToken] as returned in the previous page.
  Future<GalleryPageInfo> list(JmListQuery query, {String? pageToken}) async {
    switch (query) {
      case JmPromoteQuery(:final int id):
        final int page = (int.tryParse(pageToken ?? '') ?? 0).clamp(0, 1 << 30);
        final JmListPage result = await api.promoteList(id, page: page);
        if (page == 0) {
          _promotePageSizes[id] = result.albums.length;
        }
        final int pageSize = _promotePageSizes[id] ?? result.albums.length;
        final bool hasNext =
            result.albums.isNotEmpty && page * pageSize + result.albums.length < result.total;
        return GalleryPageInfo(
          gallerys: result.albums.map(_galleryOfSummary).toList(),
          prevGid: page > 0 ? '${page - 1}' : null,
          nextGid: hasNext ? '${page + 1}' : null,
        );
      case JmFilterQuery(:final String category, :final String order, :final String period):
        final int page = (int.tryParse(pageToken ?? '') ?? 1).clamp(1, 1 << 30);
        return _pageOf(
          await api.filter(category: category, order: order, period: period, page: page),
          page,
        );
      case JmWeekQuery(:final String issueId, :final String type):
        final JmListPage result = await api.weekFilter(issueId, type);
        return GalleryPageInfo(gallerys: result.albums.map(_galleryOfSummary).toList());
    }
  }

  /// The home sections that list comics; book and novel sections are left
  /// out. [refresh] asks the server again for the categories.
  Future<List<JmHomeSection>> home({bool refresh = false}) async {
    if (refresh) {
      _categoryList.clear();
      _hotTags.clear();
    }
    final List<JmPromoteSection> sections = await api.promote();
    final List<JmCategory> categories = (await categoryList()).categories;
    return <JmHomeSection>[
      for (final JmPromoteSection section in sections)
        if (const <String>{'promote', 'category_id', 'not_in_category_id'}.contains(section.type))
          (
            title: section.title,
            gallerys: section.albums.map(_galleryOfSummary).toList(),
            more: _moreOf(section, categories),
          ),
    ];
  }

  JmListQuery? _moreOf(JmPromoteSection section, List<JmCategory> categories) {
    switch (section.type) {
      case 'promote':
        return JmPromoteQuery(section.id);
      case 'category_id':
        final JmCategory? category = categories
            .where((JmCategory c) => '${c.id}' == section.filterValue && c.slug.isNotEmpty)
            .firstOrNull;
        return category == null ? null : JmFilterQuery(category: category.slug);
      default:
        // A section such as 禁漫漢化組 shares its name with a category.
        final JmCategory? category = categories
            .where((JmCategory c) => c.name == section.title && c.slug.isNotEmpty)
            .firstOrNull;
        return category == null ? null : JmFilterQuery(category: category.slug);
    }
  }

  /// Categories (the first, with an empty slug, is all of them) and theme
  /// tags.
  Future<JmCategories> categoryList() =>
      sharedRequest(_categoryList, 0, api.categories);

  Future<JmWeeks> weeks() => sharedRequest(_weeks, 0, api.weeks);

  Future<List<String>> hotTags() => sharedRequest(_hotTags, 0, api.hotTags);

  /// [refresh] drops the cached chapter and album first, so a manual
  /// refresh shows newly added chapters.
  Future<JmChapterBundle> bundle(int chapterId, {bool refresh = false}) async {
    if (refresh) {
      _chapters.remove(chapterId);
      _albums.remove(_albumIdOfChapter[chapterId]);
    }
    // Requested together; the album waits for the chapter only when it is
    // not known which album the chapter belongs to.
    final Future<JmChapter> chapterRequest = _chapter(chapterId);
    final Future<int> scrambleRequest = api.scrambleId(chapterId);
    final int? knownAlbum = _knownAlbumOf(chapterId);
    final Future<JmAlbum>? albumRequest = knownAlbum == null ? null : _album(knownAlbum);

    final JmChapter chapter = await chapterRequest;
    _albumIdOfChapter[chapter.id] = chapter.albumId;
    final JmAlbum album = await (knownAlbum == chapter.albumId ? albumRequest! : _album(chapter.albumId));
    for (final JmChapterRef ref in album.chapters) {
      _albumIdOfChapter[ref.id] = album.id;
    }
    return JmChapterBundle(
      album: album,
      chapter: chapter,
      scrambleId: await scrambleRequest,
    );
  }

  Future<T> detailPage<T>({
    required GalleryUrl galleryUrl,
    required int thumbnailsPageIndex,
    required HtmlParser<T> parser,
    bool useCache = true,
  }) async {
    // Comments go out with the rest when the album is known.
    final int? knownAlbum = _knownAlbumOf(galleryUrl.jmChapterId);
    final Future<List<GalleryComment>>? commentsRequest =
        parser == EHSpiderParser.detailPage2GalleryAndDetailAndApikey && knownAlbum != null
        ? _commentsOrEmpty(knownAlbum)
        : null;
    final JmChapterBundle b = await bundle(
      galleryUrl.jmChapterId,
      refresh: !useCache,
    );
    if (parser == EHSpiderParser.detailPage2GalleryAndDetailAndApikey) {
      final List<GalleryComment> comments = await (knownAlbum == b.album.id && commentsRequest != null
          ? commentsRequest
          : _commentsOrEmpty(b.album.id));
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
    _albumIds.add(summary.id);
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

  Gallery _galleryOfAlbum(JmAlbum album) {
    _albumIds.add(album.id);
    return Gallery(
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
  }

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
            content: commentContent(c.content),
            time: commentDate(c.time),
            fromMe: false,
            votedUp: false,
            votedDown: false,
            showScore: false,
          ),
        )
        .toList();
  }

  /// JM wraps comment text in styled `div`s; the comment view renders text,
  /// line breaks, links and images, so the rest is reduced to those.
  static html_dom.Element commentContent(String html) {
    final html_dom.Element target = html_dom.Element.tag('div');
    void lineBreak() {
      final html_dom.Node? last = target.nodes.lastOrNull;
      if (last != null && !(last is html_dom.Element && last.localName == 'br')) {
        target.append(html_dom.Element.tag('br'));
      }
    }

    void walk(html_dom.Node node) {
      if (node is html_dom.Text) {
        if (node.text.trim().isNotEmpty) {
          target.append(html_dom.Text(node.text));
        }
        return;
      }
      if (node is! html_dom.Element) {
        return;
      }
      switch (node.localName) {
        case 'br':
          target.append(html_dom.Element.tag('br'));
        case 'img':
          final String src = node.attributes['src'] ?? '';
          if (src.startsWith('http')) {
            target.append(html_dom.Element.tag('img')..attributes['src'] = src);
          }
        case 'a':
          target.append(
            html_dom.Element.tag('a')
              ..attributes['href'] = node.attributes['href'] ?? node.text
              ..append(html_dom.Text(node.text)),
          );
        default:
          final bool block = const <String>{'div', 'p', 'li'}.contains(node.localName);
          if (block) {
            lineBreak();
          }
          node.nodes.toList().forEach(walk);
      }
    }

    html_dom.Element.html('<div>$html</div>').nodes.toList().forEach(walk);
    while (target.nodes.isNotEmpty && target.nodes.first is html_dom.Element && (target.nodes.first as html_dom.Element).localName == 'br') {
      target.nodes.first.remove();
    }
    return target;
  }

  /// JM gives comment dates as `Sep 04, 2026`, without a time.
  static String commentDate(String raw) {
    try {
      return DateFormat('yyyy-MM-dd').format(DateFormat('MMM dd, yyyy', 'en_US').parseStrict(raw.trim()));
    } on FormatException {
      return raw;
    }
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
