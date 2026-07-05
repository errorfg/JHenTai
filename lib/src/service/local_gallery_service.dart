import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/list_extension.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/utils/file_util.dart';
import 'package:path/path.dart';
/// Import renderer only: the pdfx viewer widgets are incompatible with the project's photo_view fork
import 'package:pdfx/src/renderer/interfaces/document.dart' as pdf;
import 'package:pdfx/src/renderer/interfaces/page.dart' as pdf;

import '../model/gallery_image.dart';
import '../pages/download/grid/mixin/grid_download_page_service_mixin.dart';
import '../setting/download_setting.dart';
import 'jh_service.dart';
import 'path_service.dart';
import 'log.dart';
import '../widget/loading_state_indicator.dart';
import 'archive_download_service.dart';

/// Load galleries in download directory but is not downloaded by JHenTai
LocalGalleryService localGalleryService = LocalGalleryService();

class LocalGalleryService extends GetxController
    with GridBasePageServiceMixin, JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  static const String rootPath = '';
  static const String pdfPageCacheDirName = '.pdf_page_cache';
  static const double _pdfRenderBaseScale = 2.0;
  static const double _pdfRenderMinLongSide = 1800;
  static const double _pdfRenderMaxLongSide = 2600;

  LoadingState loadingState = LoadingState.idle;

  List<LocalGallery> allGallerys = [];
  Map<String, List<LocalGallery>> path2GalleryDir = {};
  Map<String, List<String>> path2SubDir = {};

  Map<int, LocalGallery> gid2EHViewerGallery = {};

  List<String> get rootDirectories => path2SubDir[rootPath] ?? [];

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);

    await refreshLocalGallerys();
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Future<void> refreshLocalGallerys() {
    if (loadingState == LoadingState.loading) {
      return Future.value();
    }
    loadingState = LoadingState.loading;

    int preCount = allGallerys.length;

    allGallerys.clear();
    path2GalleryDir.clear();
    path2SubDir.clear();
    update([galleryCountChangedId]);

    DateTime start = DateTime.now();
    return _loadGalleriesFromDisk().whenComplete(() {
      log.info(
        'Refresh local gallerys, preCount:$preCount, newCount: ${allGallerys.length}, timeCost: ${DateTime.now().difference(start).inMilliseconds}ms',
      );
      loadingState = LoadingState.success;
      update([galleryCountChangedId]);
    });
  }

  Future<List<GalleryImage>> getGalleryImages(LocalGallery gallery) {
    if (gallery.isPdf) {
      return _getPdfGalleryImages(gallery);
    }

    List<File> imageFiles = Directory(gallery.path)
        .listSync()
        .whereType<File>()
        .where((image) => FileUtil.isImageExtension(image.path))
        .toList()
      ..sort(FileUtil.naturalCompareFile);

    return Future.value(imageFiles
        .map(
          (file) => GalleryImage(
            url: '',
            path: relative(file.path, from: pathService.getVisibleDir().path),
            downloadStatus: DownloadStatus.downloaded,
          ),
        )
        .toList());
  }

  void deleteGallery(LocalGallery gallery, String parentPath) {
    log.info('Delete local gallery: ${gallery.title}');

    if (gallery.isPdf) {
      File pdfFile = File(gallery.path);
      Directory cacheDirectory = _computePdfCacheDirectory(pdfFile);
      if (cacheDirectory.existsSync()) {
        cacheDirectory.delete(recursive: true).catchError((e) {
          log.error('Delete local pdf cache error!', e);
          log.uploadError(e);
          return cacheDirectory;
        });
      }
      pdfFile.delete().catchError((e) {
        log.error('Delete local pdf gallery error!', e);
        log.uploadError(e);
        return pdfFile;
      });

      allGallerys.removeWhere((g) => g.title == gallery.title);
      path2GalleryDir[parentPath]?.removeWhere((g) => g.title == gallery.title);
      update([galleryCountChangedId]);
      return;
    }

    Directory dir = Directory(gallery.path);

    List<File> allFiles = dir.listSync().whereType<File>().toList();
    List<File> imageFiles = dir
        .listSync()
        .whereType<File>()
        .where((image) => FileUtil.isImageExtension(image.path))
        .toList();
    if (allFiles.length == imageFiles.length) {
      dir.delete(recursive: true).catchError((e) {
        log.error('Delete local gallery error!', e);
        log.uploadError(e);
        return dir;
      });
    } else {
      for (File file in imageFiles) {
        file.delete().catchError((e) {
          log.error('Delete local gallery error!', e);
          log.uploadError(e);
          return file;
        });
      }
    }

    allGallerys.removeWhere((g) => g.title == gallery.title);
    path2GalleryDir[parentPath]?.removeWhere((g) => g.title == gallery.title);

    update([galleryCountChangedId]);
  }

  Future<void> _loadGalleriesFromDisk() {
    List<Future> futures = downloadSetting.extraGalleryScanPath
        .map((path) => _parseDirectory(Directory(path), true))
        .toList();

    return Future.wait(futures).onError((error, stackTrace) {
      log.error(
          '_loadGalleriesFromDisk failed, path: ${downloadSetting.extraGalleryScanPath}',
          error,
          stackTrace);
      return [];
    }).whenComplete(() {
      allGallerys.sort((a, b) => FileUtil.naturalCompare(a.title, b.title));
      for (List<LocalGallery> dirs in path2GalleryDir.values) {
        dirs.sort((a, b) => FileUtil.naturalCompare(a.title, b.title));
      }
    });
  }

  Future<LocalGalleryParseResult> _parseDirectory(
      Directory directory, bool isRootDir) {
    Completer<LocalGalleryParseResult> completer = Completer();
    LocalGalleryParseResult result = LocalGalleryParseResult();

    Future<bool> future = directory.exists();

    /// skip if it is JHenTai gallery directory -> metadata file exists
    future = future.then<bool>((success) {
      if (success) {
        return File(
                join(directory.path, GalleryDownloadService.metadataFileName))
            .exists()
            .then((value) => !value);
      } else {
        completer.isCompleted ? null : completer.complete(result);
        return false;
      }
    }).catchError((e, stack) {
      completer.isCompleted ? null : completer.completeError(e, stack);
      return false;
    });

    future = future.then<bool>((success) {
      if (success) {
        return File(
                join(directory.path, ArchiveDownloadService.metadataFileName))
            .exists()
            .then((value) => !value);
      } else {
        completer.isCompleted ? null : completer.complete(result);
        return false;
      }
    }).catchError((e, stack) {
      completer.isCompleted ? null : completer.completeError(e, stack);
      return false;
    });

    /// recursively list all files in directory
    future = future.then<bool>((success) {
      if (success) {
        List<Future> subFutures = [];
        List<File> images = [];
        List<File> pdfs = [];
        String parentPath = isRootDir ? rootPath : directory.parent.path;

        directory.list().listen(
          (entity) {
            if (entity is File && FileUtil.isImageExtension(entity.path)) {
              result.isLegalGalleryDir = true;
              images.add(entity);
            } else if (entity is File && FileUtil.isPdfExtension(entity.path)) {
              result.isLegalGalleryDir = true;
              pdfs.add(entity);
            } else if (entity is Directory) {
              subFutures.add(
                _parseDirectory(entity, false).then((subResult) {
                  if (subResult.isLegalGalleryDir ||
                      subResult.isLegalNestedGalleryDir) {
                    result.isLegalNestedGalleryDir = true;
                    (path2SubDir[parentPath] ??= [])
                        .addIfNotExists(directory.path);
                    path2SubDir[parentPath]!.sort((a, b) =>
                        FileUtil.naturalCompare(basenameWithoutExtension(a),
                            basenameWithoutExtension(b)));
                  }
                }),
              );
            }
          },
          onDone: () async {
            try {
              if (images.isNotEmpty) {
                images.sort(FileUtil.naturalCompareFile);
                _initGalleryInfoInMemory(directory, images[0], parentPath);
              }

              pdfs.sort(FileUtil.naturalCompareFile);
              for (File pdfFile in pdfs) {
                await _initPdfGalleryInfoInMemory(pdfFile, parentPath);
              }

              await Future.wait(subFutures);
              completer.isCompleted ? null : completer.complete(result);
            } catch (e, stack) {
              completer.isCompleted ? null : completer.completeError(e, stack);
            }
          },
          onError: completer.completeError,
        );
      } else {
        completer.isCompleted ? null : completer.complete(result);
      }
      return success;
    }).catchError((e, stack) {
      completer.isCompleted ? null : completer.completeError(e, stack);
      return false;
    });

    return completer.future;
  }

  void _initGalleryInfoInMemory(
      Directory galleryDir, File coverImage, String parentPath) {
    LocalGallery gallery = LocalGallery(
      title: basename(galleryDir.path),
      path: galleryDir.path,
      cover: GalleryImage(
        url: '',
        path: relative(coverImage.path, from: pathService.getVisibleDir().path),
        downloadStatus: DownloadStatus.downloaded,
      ),
    );

    allGallerys.add(gallery);
    (path2GalleryDir[parentPath] ??= []).add(gallery);
  }

  Future<void> _initPdfGalleryInfoInMemory(
      File pdfFile, String parentPath) async {
    pdf.PdfDocument? document;
    try {
      document = await pdf.PdfDocument.openFile(pdfFile.path);
      File coverFile = await _ensurePdfPageImage(pdfFile, document, 1);

      LocalGallery gallery = LocalGallery(
        title: basenameWithoutExtension(pdfFile.path),
        path: pdfFile.path,
        cover: GalleryImage(
          url: '',
          path:
              relative(coverFile.path, from: pathService.getVisibleDir().path),
          downloadStatus: DownloadStatus.downloaded,
        ),
        isPdf: true,
      );

      allGallerys.add(gallery);
      (path2GalleryDir[parentPath] ??= []).add(gallery);
    } catch (e, stack) {
      log.error(
          'Init local pdf gallery failed, path: ${pdfFile.path}', e, stack);
      log.uploadError(e, stackTrace: stack);
    } finally {
      await document?.close();
    }
  }

  Future<List<GalleryImage>> _getPdfGalleryImages(LocalGallery gallery) async {
    File pdfFile = File(gallery.path);
    pdf.PdfDocument document = await pdf.PdfDocument.openFile(pdfFile.path);

    try {
      List<GalleryImage> images = [];
      for (int pageNumber = 1; pageNumber <= document.pagesCount; pageNumber++) {
        File imageFile =
            await _ensurePdfPageImage(pdfFile, document, pageNumber);
        images.add(
          GalleryImage(
            url: '',
            path: relative(imageFile.path,
                from: pathService.getVisibleDir().path),
            downloadStatus: DownloadStatus.downloaded,
          ),
        );
      }
      return images;
    } finally {
      await document.close();
    }
  }

  Future<File> _ensurePdfPageImage(
      File pdfFile, pdf.PdfDocument document, int pageNumber) async {
    Directory cacheDirectory = _computePdfCacheDirectory(pdfFile);
    File pageImageFile = File(join(
        cacheDirectory.path, pageNumber.toString().padLeft(5, '0') + '.png'));
    if (pageImageFile.existsSync()) {
      return pageImageFile;
    }

    if (!cacheDirectory.existsSync()) {
      cacheDirectory.createSync(recursive: true);
    }

    pdf.PdfPage page = await document.getPage(pageNumber);

    try {
      double scale = _computePdfRenderScale(page.width, page.height);
      pdf.PdfPageImage? renderedImage = await page.render(
        width: max(1, page.width * scale),
        height: max(1, page.height * scale),
        format: pdf.PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      if (renderedImage == null) {
        throw StateError(
            'Encode pdf page image failed: ${pdfFile.path}#$pageNumber');
      }
      await pageImageFile.writeAsBytes(renderedImage.bytes);
      return pageImageFile;
    } finally {
      await page.close();
    }
  }

  Directory _computePdfCacheDirectory(File pdfFile) {
    FileStat stat = pdfFile.statSync();
    String cacheKey = sha1
        .convert(utf8.encode(
            '${pdfFile.absolute.path}:${stat.size}:${stat.modified.millisecondsSinceEpoch}'))
        .toString();
    return Directory(
        join(pathService.getVisibleDir().path, pdfPageCacheDirName, cacheKey));
  }

  double _computePdfRenderScale(double width, double height) {
    double longSide = max(width, height);
    if (longSide <= 0) {
      return 1;
    }

    double scale = _pdfRenderBaseScale;
    double targetLongSide = longSide * scale;
    if (targetLongSide < _pdfRenderMinLongSide) {
      return _pdfRenderMinLongSide / longSide;
    }
    if (targetLongSide > _pdfRenderMaxLongSide) {
      return _pdfRenderMaxLongSide / longSide;
    }
    return scale;
  }
}

class LocalGallery {
  String title;
  String path;
  GalleryImage cover;
  bool isPdf;

  LocalGallery(
      {required this.title,
      required this.path,
      required this.cover,
      this.isPdf = false});
}

class LocalGalleryParseResult {
  /// has images
  bool isLegalGalleryDir = false;

  /// has subDirectory that has images
  bool isLegalNestedGalleryDir = false;
}
