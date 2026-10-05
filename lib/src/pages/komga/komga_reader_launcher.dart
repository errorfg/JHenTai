import 'package:get/get.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/service/komga_download_service.dart';
import 'package:jhentai/src/service/komga_progress_sync_service.dart';
import 'package:jhentai/src/service/log.dart';

/// A book that cannot be opened, with a message for the user.
class KomgaOpenException implements Exception {
  const KomgaOpenException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Prepares reader sessions for Komga books, from the server or from a
/// download.
class KomgaReaderLauncher {
  const KomgaReaderLauncher(this.client);

  final KomgaClient client;

  Future<ReadPageInfo> prepare(KomgaBook book) async {
    final KomgaDownloadedBook? downloaded = komgaDownloadService.downloaded(
      client.progressRecordKey(book.id),
    );
    if (downloaded != null) {
      return _prepareDownloaded(downloaded);
    }
    if (book.isTextEpub) {
      throw KomgaOpenException('komgaBookTextEpub'.tr);
    }
    if (!book.isReadable) {
      throw KomgaOpenException('komgaBookNotReady'.tr);
    }

    final List<KomgaBookPage> pages = (await client.getBookPages(book.id))
      ..sort(
        (KomgaBookPage a, KomgaBookPage b) => a.number.compareTo(b.number),
      );
    if (pages.isEmpty) {
      throw KomgaOpenException('komgaBookHasNoPages'.tr);
    }
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
    );
  }

  Future<ReadPageInfo> _prepareDownloaded(
    KomgaDownloadedBook downloaded,
  ) async {
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
    );
  }

  ReadPageInfo _session({
    required KomgaBook book,
    required ReadMode mode,
    required List<GalleryImage> images,
    required int initialIndex,
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
          _prepareSibling(book, next: next),
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
    return prepare(sibling);
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
        : volumes.reversed.where(
            (KomgaBook b) => b.numberSort < book.numberSort,
          );
    return candidates.isEmpty ? null : candidates.first;
  }
}
