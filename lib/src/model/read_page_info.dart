import 'dart:async';

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

  /// Optional one-way progress reporter for a remote content source.
  /// JHenTai's own read-progress storage remains the source of truth.
  ReadProgressReporter? reportReadProgress;

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
  }) : currentImageIndex = initialIndex;
}
