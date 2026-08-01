import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/service/archive_download_service.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/setting/download_setting.dart';
import 'package:jhentai/src/utils/file_util.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';
import 'package:path/path.dart';

/// Import the renderer only. pdfx's viewer widgets conflict with the project's
/// custom photo_view dependency, while its renderer is safe to reuse.
import 'package:pdfx/src/renderer/interfaces/document.dart' as pdf;
import 'package:pdfx/src/renderer/interfaces/page.dart' as pdf;

PdfService pdfService = PdfService();

class PdfService extends GetxController {
  static const String pageCacheDirectoryName = '.pdf_page_cache';
  static const double _renderBaseScale = 2.0;
  static const double _renderMinLongSide = 1800;
  static const double _renderMaxLongSide = 2600;

  final List<PdfDocumentEntry> documents = [];
  final Set<String> _scannedDocumentPaths = {};
  LoadingState loadingState = LoadingState.idle;

  @override
  Future<void> refresh() async {
    if (loadingState == LoadingState.loading) {
      return;
    }

    loadingState = LoadingState.loading;
    documents.clear();
    _scannedDocumentPaths.clear();
    update();

    try {
      for (final String scanRootPath in downloadSetting.extraGalleryScanPath) {
        final Directory scanRoot = Directory(scanRootPath);
        await _scanDirectory(scanRoot, scanRoot);
      }
      documents.sort((PdfDocumentEntry a, PdfDocumentEntry b) => FileUtil.naturalCompare(a.title, b.title));
      loadingState = LoadingState.success;
    } catch (e, stack) {
      loadingState = LoadingState.error;
      log.error('Refresh PDF library failed', e, stack);
    }

    update();
  }

  Future<List<GalleryImage>> getDocumentImages(PdfDocumentEntry entry) async {
    final File pdfFile = File(entry.path);
    final pdf.PdfDocument document = await pdf.PdfDocument.openFile(pdfFile.path);

    try {
      final List<GalleryImage> images = [];
      for (int pageNumber = 1; pageNumber <= document.pagesCount; pageNumber++) {
        final File imageFile = await _ensurePageImage(pdfFile, document, pageNumber);
        images.add(
          GalleryImage(
            url: '',
            path: relative(imageFile.path, from: pathService.getVisibleDir().path),
            downloadStatus: DownloadStatus.downloaded,
          ),
        );
      }
      return images;
    } finally {
      await document.close();
    }
  }

  Future<void> deleteDocument(PdfDocumentEntry entry) async {
    final File pdfFile = File(entry.path);
    final Directory cacheDirectory = _computeCacheDirectory(pdfFile);
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
    }
    if (await pdfFile.exists()) {
      await pdfFile.delete();
    }
    documents.removeWhere((PdfDocumentEntry item) => item.path == entry.path);
    update();
  }

  Future<void> _scanDirectory(Directory directory, Directory scanRoot) async {
    if (!await directory.exists() || _isHiddenDirectory(directory, scanRoot)) {
      return;
    }

    if (await File(join(directory.path, GalleryDownloadService.metadataFileName)).exists()) {
      return;
    }
    if (await File(join(directory.path, ArchiveDownloadService.metadataFileName)).exists()) {
      return;
    }

    await for (final FileSystemEntity entity in directory.list(followLinks: false)) {
      if (entity is Directory) {
        await _scanDirectory(entity, scanRoot);
      } else if (entity is File && FileUtil.isPdfExtension(entity.path)) {
        await _addDocument(entity, scanRoot);
      }
    }
  }

  Future<void> _addDocument(File pdfFile, Directory scanRoot) async {
    final String normalizedPath = normalize(absolute(pdfFile.path));
    if (!_scannedDocumentPaths.add(normalizedPath)) {
      return;
    }

    pdf.PdfDocument? document;
    try {
      document = await pdf.PdfDocument.openFile(pdfFile.path);
      if (document.pagesCount <= 0) {
        return;
      }
      final File coverFile = await _ensurePageImage(pdfFile, document, 1);
      final String relativeSourcePath = relative(pdfFile.path, from: scanRoot.path).replaceAll('\\', '/');
      final int fileSize = await pdfFile.length();
      final String progressKey = 'pdf:${sha1.convert(utf8.encode('$relativeSourcePath:$fileSize'))}';

      documents.add(
        PdfDocumentEntry(
          title: basenameWithoutExtension(pdfFile.path),
          path: pdfFile.path,
          pageCount: document.pagesCount,
          progressKey: progressKey,
          cover: GalleryImage(
            url: '',
            path: relative(coverFile.path, from: pathService.getVisibleDir().path),
            downloadStatus: DownloadStatus.downloaded,
          ),
        ),
      );
    } catch (e, stack) {
      log.error('Load PDF failed: ${pdfFile.path}', e, stack);
    } finally {
      await document?.close();
    }
  }

  bool _isHiddenDirectory(Directory directory, Directory scanRoot) {
    if (directory.path == scanRoot.path) {
      return false;
    }
    return basename(directory.path).startsWith('.');
  }

  Future<File> _ensurePageImage(File pdfFile, pdf.PdfDocument document, int pageNumber) async {
    final Directory cacheDirectory = _computeCacheDirectory(pdfFile);
    final File pageImageFile = File(join(cacheDirectory.path, '${pageNumber.toString().padLeft(5, '0')}.png'));
    if (await pageImageFile.exists()) {
      return pageImageFile;
    }

    await cacheDirectory.create(recursive: true);
    final pdf.PdfPage page = await document.getPage(pageNumber);
    try {
      final double scale = _computeRenderScale(page.width, page.height);
      final pdf.PdfPageImage? renderedImage = await page.render(width: max(1, page.width * scale), height: max(1, page.height * scale), format: pdf.PdfPageImageFormat.png, backgroundColor: '#FFFFFF');
      if (renderedImage == null) {
        throw StateError('Render PDF page failed: ${pdfFile.path}#$pageNumber');
      }
      await pageImageFile.writeAsBytes(renderedImage.bytes);
      return pageImageFile;
    } finally {
      await page.close();
    }
  }

  Directory _computeCacheDirectory(File pdfFile) {
    final FileStat stat = pdfFile.statSync();
    final String cacheKey = sha1.convert(utf8.encode('${pdfFile.absolute.path}:${stat.size}:${stat.modified.millisecondsSinceEpoch}')).toString();
    return Directory(join(pathService.getVisibleDir().path, pageCacheDirectoryName, cacheKey));
  }

  double _computeRenderScale(double width, double height) {
    final double longSide = max(width, height);
    if (longSide <= 0) {
      return 1;
    }

    final double targetLongSide = longSide * _renderBaseScale;
    if (targetLongSide < _renderMinLongSide) {
      return _renderMinLongSide / longSide;
    }
    if (targetLongSide > _renderMaxLongSide) {
      return _renderMaxLongSide / longSide;
    }
    return _renderBaseScale;
  }
}

class PdfDocumentEntry {
  const PdfDocumentEntry({required this.title, required this.path, required this.pageCount, required this.progressKey, required this.cover});

  final String title;
  final String path;
  final int pageCount;
  final String progressKey;
  final GalleryImage cover;
}
