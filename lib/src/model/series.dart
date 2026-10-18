import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/service/series_reading_service.dart';

/// A chapter of a series, in reading order. Each chapter is a gallery of its
/// own ([url]): its pages, read progress and download.
class SeriesChapter {
  const SeriesChapter({required this.id, required this.url, required this.name, this.date});

  /// The chapter's id among the source's progress records
  /// ([SeriesReadingService]).
  final int id;
  final GalleryUrl url;
  final String name;

  /// When the chapter was published, for display; null when unknown.
  final DateTime? date;
}

/// A chapter with its series (a JM album, a Tachiyomi manga): what the
/// details page, the reader and downloads need of a multi-chapter source.
abstract interface class SeriesBundle {
  /// The series' id among the source's progress records.
  int get seriesId;

  /// The series as a whole, as the history and favorites keep it.
  GalleryUrl get seriesUrl;

  String get seriesTitle;

  List<SeriesChapter> get chapters;

  /// Position of [galleryUrl] in [chapters], -1 when it is not among them.
  int get chapterIndex;

  bool get isMultiChapter;

  /// The chapter open, and its id among the progress records.
  GalleryUrl get galleryUrl;

  int get chapterId;

  /// The chapter's title for the reader and downloads.
  String get title;

  int get pageCount;

  /// Pages of the whole series; 0 when unknown.
  int get seriesPageCount;

  String? get author;

  /// Links of every page of the chapter, so the reader needs no thumbnail
  /// requests.
  List<GalleryThumbnail> pageThumbnails();
}

/// A source whose galleries are chapters of series.
abstract interface class SeriesSource {
  SeriesReadingService get reading;

  /// The chapter [chapter] with its series; [refresh] asks the site again.
  Future<SeriesBundle> bundle(GalleryUrl chapter, {bool refresh = false});

  /// Pages of a chapter, for queueing its download.
  Future<int> chapterPageCount(GalleryUrl chapter);

  /// Title of chapter [index] of the series, for downloads.
  String chapterTitle(SeriesBundle bundle, int index);
}
