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

  int initialIndex;

  int currentImageIndex;

  /// Pages of the whole reader: grows as later books are appended to a
  /// running reader (see [ReadSegment]).
  int pageCount;

  /// used for archive
  bool isOriginal;

  String readProgressRecordStorageKey;

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
    this.images,
    this.thumbnails,
    this.onShown,
    required this.useSuperResolution,
    this.reportReadProgress,
    this.loadSiblingBook,
    this.siblingsAreChapters = false,
    this.readDirection,
  }) : currentImageIndex = initialIndex;
}

/// One book of a reader that reads several in a row: [info] describes the
/// book, whose pages are [start] to [start] + [pageCount] - 1 of the reader.
class ReadSegment {
  ReadSegment({required this.info, required this.start, required this.pageCount});

  final ReadPageInfo info;
  final int start;
  final int pageCount;

  int get end => start + pageCount;

  bool contains(int index) => index >= start && index < end;
}
