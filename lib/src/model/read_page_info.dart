import 'dart:async';

import '../setting/read_setting.dart';
import 'gallery_image.dart';

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

  int pageCount;

  /// used for archive
  bool isOriginal;

  String readProgressRecordStorageKey;

  /// used for archive&local
  List<GalleryImage>? images;

  /// used for initialize
  bool useSuperResolution;

  /// Optional reporter that sends locally persisted progress to a remote
  /// content source. Called after each local write.
  ReadProgressReporter? reportReadProgress;

  /// Optional loader for the previous or next book of the same series;
  /// completes with null at either end of the series.
  Future<ReadPageInfo?> Function({required bool next})? loadSiblingBook;

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
    required this.useSuperResolution,
    this.reportReadProgress,
    this.loadSiblingBook,
    this.readDirection,
  }) : currentImageIndex = initialIndex;
}
