import 'package:get/get.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/service/komga_download_service.dart';
import 'package:jhentai/src/service/komga_progress_sync_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/read_setting.dart';

/// A book that cannot be opened, with a message for the user.
class KomgaOpenException implements Exception {
  const KomgaOpenException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Map a Komga series reading direction onto the user's read direction:
/// keep the user's layout (single page, fit width, double page, list) and
/// change only the direction. Vertical and webtoon series use the vertical
/// list. An unset direction keeps the user's choice.
ReadDirection komgaReadDirection(String komga, ReadDirection user) {
  const Map<ReadDirection, ReadDirection> toRightToLeft = {
    ReadDirection.top2bottomList: ReadDirection.right2leftSinglePage,
    ReadDirection.left2rightSinglePage: ReadDirection.right2leftSinglePage,
    ReadDirection.left2rightSinglePageFitWidth:
        ReadDirection.right2leftSinglePageFitWidth,
    ReadDirection.left2rightDoubleColumn: ReadDirection.right2leftDoubleColumn,
    ReadDirection.left2rightList: ReadDirection.right2leftList,
  };
  const Map<ReadDirection, ReadDirection> toLeftToRight = {
    ReadDirection.top2bottomList: ReadDirection.left2rightSinglePage,
    ReadDirection.right2leftSinglePage: ReadDirection.left2rightSinglePage,
    ReadDirection.right2leftSinglePageFitWidth:
        ReadDirection.left2rightSinglePageFitWidth,
    ReadDirection.right2leftDoubleColumn: ReadDirection.left2rightDoubleColumn,
    ReadDirection.right2leftList: ReadDirection.left2rightList,
  };
  return switch (komga) {
    'RIGHT_TO_LEFT' => toRightToLeft[user] ?? user,
    'LEFT_TO_RIGHT' => toLeftToRight[user] ?? user,
    'VERTICAL' || 'WEBTOON' => ReadDirection.top2bottomList,
    _ => user,
  };
}

/// Prepares reader sessions for Komga books, from the server or from a
/// download.
class KomgaReaderLauncher {
  const KomgaReaderLauncher(this.client);

  final KomgaClient client;

  /// [seriesReadingDirection] avoids a series lookup when the caller knows
  /// it; null means "look it up".
  Future<ReadPageInfo> prepare(
    KomgaBook book, {
    String? seriesReadingDirection,
  }) async {
    final KomgaDownloadedBook? downloaded = komgaDownloadService.downloaded(
      client.progressRecordKey(book.id),
    );
    if (downloaded != null) {
      return _prepareDownloaded(downloaded, seriesReadingDirection);
    }
    if (book.isTextEpub) {
      throw KomgaOpenException('komgaBookTextEpub'.tr);
    }
    if (!book.isReadable) {
      throw KomgaOpenException('komgaBookNotReady'.tr);
    }

    final List<KomgaBookPage> pages = (await client.getBookPages(book.id))
      ..sort((KomgaBookPage a, KomgaBookPage b) => a.number.compareTo(b.number));
    if (pages.isEmpty) {
      throw KomgaOpenException('komgaBookHasNoPages'.tr);
    }
    final String direction =
        seriesReadingDirection ?? await _seriesDirection(book.seriesId);
    final int start = await komgaProgressSyncService.reconcileBeforeOpen(
      client,
      book,
    );

    final List<GalleryImage> images = <GalleryImage>[
      for (int index = 0; index < pages.length; index++)
        _remoteImage(book.id, pages[index], index),
    ];
    return _session(
      book: book,
      mode: ReadMode.remote,
      images: images,
      initialIndex: start.clamp(0, images.length - 1),
      direction: direction,
    );
  }

  Future<ReadPageInfo> _prepareDownloaded(
    KomgaDownloadedBook downloaded,
    String? seriesReadingDirection,
  ) async {
    // Downloads made before the direction was recorded have none; ask the
    // server when it is reachable.
    final String direction = downloaded.readingDirection.isNotEmpty
        ? downloaded.readingDirection
        : seriesReadingDirection ??
              await _seriesDirection(downloaded.book.seriesId);
    // Reconciles with the server when it is reachable, local progress
    // otherwise.
    final int start = await komgaProgressSyncService.reconcileBeforeOpen(
      client,
      downloaded.book,
    );
    final List<GalleryImage> images = downloaded.imagePaths
        .map(
          (String path) => GalleryImage(
            url: '',
            path: path,
            downloadStatus: DownloadStatus.downloaded,
          ),
        )
        .toList();
    return _session(
      book: downloaded.book,
      mode: ReadMode.local,
      images: images,
      initialIndex: start.clamp(0, images.length - 1),
      direction: direction,
    );
  }

  ReadPageInfo _session({
    required KomgaBook book,
    required ReadMode mode,
    required List<GalleryImage> images,
    required int initialIndex,
    required String direction,
  }) {
    return ReadPageInfo(
      mode: mode,
      galleryTitle: book.title,
      initialIndex: initialIndex,
      pageCount: images.length,
      readProgressRecordStorageKey: client.progressRecordKey(book.id),
      images: images,
      useSuperResolution: false,
      reportReadProgress: (int imageIndex) =>
          komgaProgressSyncService.report(client, book, imageIndex),
      loadSiblingBook: ({required bool next}) =>
          _prepareSibling(book, next: next, direction: direction),
      readDirectionFor: direction.isEmpty
          ? null
          : (ReadDirection user) => komgaReadDirection(direction, user),
    );
  }

  GalleryImage _remoteImage(String bookId, KomgaBookPage page, int index) {
    final int number = page.number > 0 ? page.number : index + 1;
    final String url = client.bookPageUrl(
      bookId,
      number,
      mediaType: page.mediaType,
    );
    final String thumbnailUrl = client.bookPageThumbnailUrl(bookId, number);
    return GalleryImage(
      url: url,
      width: page.width?.toDouble(),
      height: page.height?.toDouble(),
      headers: client.imageHeaders,
      cacheKey: client.imageCacheKey(url),
      thumbnailUrl: thumbnailUrl,
      thumbnailCacheKey: client.imageCacheKey(thumbnailUrl),
      downloadStatus: DownloadStatus.downloaded,
    );
  }

  Future<ReadPageInfo?> _prepareSibling(
    KomgaBook book, {
    required bool next,
    required String direction,
  }) async {
    KomgaBook? sibling;
    try {
      sibling = await client.siblingBook(book.id, next: next);
    } catch (e) {
      log.warning('Komga sibling lookup failed; using downloads', e);
      sibling = _downloadedSibling(book, next: next);
    }
    if (sibling == null) {
      return null;
    }
    return prepare(sibling, seriesReadingDirection: direction);
  }

  /// The neighbouring downloaded volume of the same series.
  KomgaBook? _downloadedSibling(KomgaBook book, {required bool next}) {
    final List<KomgaBook> volumes = komgaDownloadService
        .downloadedBooks(client.connectionId)
        .map((KomgaDownloadedBook d) => d.book)
        .where((KomgaBook b) => b.seriesId == book.seriesId)
        .toList();
    final Iterable<KomgaBook> candidates = next
        ? volumes.where((KomgaBook b) => b.numberSort > book.numberSort)
        : volumes.reversed.where((KomgaBook b) => b.numberSort < book.numberSort);
    return candidates.isEmpty ? null : candidates.first;
  }

  Future<String> _seriesDirection(String seriesId) async {
    try {
      return (await client.getSeries(seriesId)).readingDirection;
    } catch (e) {
      log.warning('Komga series lookup failed; using the user direction', e);
      return '';
    }
  }
}
