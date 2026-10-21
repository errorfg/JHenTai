import 'dart:async';

import '../setting/read_setting.dart';
import 'gallery_image.dart';
import 'gallery_thumbnail.dart';

enum ReadMode { downloaded, online, archive, local, remote }

extension ReadModePreloadSemantics on ReadMode {
  /// Whether this source should use the network preload settings.
  ///
  /// This only selects preload tuning. It intentionally does not determine
  /// which image builder or URL-resolution path the reader uses.
  bool get usesNetworkPreloadSettings =>
      this == ReadMode.online || this == ReadMode.remote;
}

typedef ReadProgressReporter = FutureOr<void> Function(int imageIndex);

class ReadPageInfo {
  ReadMode mode;

  /// null for local gallery
  int? gid;

  /// null for local gallery
  String? token;

  String galleryTitle;

  String? galleryUrl;

  /// The page of the book to open it on.
  final int initialIndex;

  /// Pages of the book; those of all the books in a reader are its state's.
  final int pageCount;

  /// used for archive
  bool isOriginal;

  String readProgressRecordStorageKey;

  /// Where versions up to 8.1.1 kept the progress and double pages of the
  /// book (see GalleryUrl.legacyKey), read while it has none of its own.
  final String? legacyProgressKey;

  /// used for archive, local and remote; in online mode, pages already
  /// downloaded, the others null
  List<GalleryImage?>? images;

  /// Links of the pages' image pages when known in advance (JM chapters), so
  /// no thumbnail page is requested.
  List<GalleryThumbnail?>? thumbnails;

  /// Called when this book becomes the one being read, at the start or once
  /// it is scrolled to after being appended.
  FutureOr<void> Function()? onShown;

  /// used for initialize
  bool useSuperResolution;

  /// Optional reporter that sends locally persisted progress to a remote
  /// content source. Called after each local write.
  ReadProgressReporter? reportReadProgress;

  /// Optional loader for the previous or next book of the same series;
  /// completes with null at either end of the series.
  Future<ReadPageInfo?> Function({required bool next})? loadSiblingBook;

  /// The siblings are chapters of one work rather than books of a series;
  /// only changes the reader's wording.
  bool siblingsAreChapters;

  /// Read direction applied instead of the user's setting, for example a
  /// webtoon detected from gallery tags when auto detection is enabled.
  ReadDirection? readDirection;

  ReadPageInfo({
    required this.mode,
    this.gid,
    this.token,
    required this.galleryTitle,
    this.galleryUrl,
    required this.initialIndex,
    required this.pageCount,
    this.isOriginal = false,
    required this.readProgressRecordStorageKey,
    this.legacyProgressKey,
    this.images,
    this.thumbnails,
    this.onShown,
    required this.useSuperResolution,
    this.reportReadProgress,
    this.loadSiblingBook,
    this.siblingsAreChapters = false,
    this.readDirection,
  });
}

/// One book of a reader that reads several in a row: [info] describes the
/// book, whose pages are [start] to [start] + [pageCount] - 1 of the reader.
/// [start] moves on when a book is put before the first.
class ReadSegment {
  ReadSegment({required this.info, required this.start, required this.pageCount, this.id = 0});

  final ReadPageInfo info;

  /// Unique among the books of a reader (see PageId).
  final int id;
  int start;
  final int pageCount;

  int get end => start + pageCount;

  bool contains(int index) => index >= start && index < end;
}

/// A page of a book in a reader, by the book and its number there: the same
/// page when books are put before it, unlike its index among all pages
/// (ReadPageState.pageIdAt, ReadPageState.indexOf).
typedef PageId = ({int segment, int page});

/// What looking for the book before or after those in a reader came to.
sealed class SiblingOutcome {
  const SiblingOutcome();
}

/// Put in the reader.
final class SiblingJoined extends SiblingOutcome {
  const SiblingJoined(this.segment);

  final ReadSegment segment;
}

/// It can not be shown with the books in the reader (a downloaded volume
/// after one read from the server, say): read by itself, as loaded.
final class SiblingApart extends SiblingOutcome {
  const SiblingApart(this.book);

  final ReadPageInfo book;
}

/// There is none.
final class SiblingNone extends SiblingOutcome {
  const SiblingNone();
}

/// It could not be loaded; asked for again, it is looked for again.
final class SiblingFailed extends SiblingOutcome {
  const SiblingFailed(this.error);

  final Object error;
}

/// Not looked for: it is being looked for already, or the reader closed or
/// left the layout it was looked for in meanwhile.
final class SiblingNotNow extends SiblingOutcome {
  const SiblingNotNow();
}
