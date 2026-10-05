import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/komga/komga_query.dart';
import 'package:jhentai/src/model/komga/komga_browse_models.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/path_service.dart';

KomgaDownloadService komgaDownloadService = KomgaDownloadService();

/// A Komga book stored on this device: its pages extracted in Komga's page
/// order, plus enough metadata to list and open it without the server.
class KomgaDownloadedBook {
  KomgaDownloadedBook({
    required this.connectionId,
    required this.book,
    required this.bookJson,
    required this.imagePaths,
    required this.downloadedAt,
  });

  final String connectionId;
  final KomgaBook book;
  final Map<String, dynamic> bookJson;
  final List<String> imagePaths;
  final DateTime downloadedAt;

  String get recordKey => 'komga:$connectionId:${book.id}';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'connectionId': connectionId,
    'book': bookJson,
    'images': imagePaths
        .map((String path) => path.split(Platform.pathSeparator).last)
        .toList(),
    'downloadedAt': downloadedAt.toUtc().toIso8601String(),
  };

  static KomgaDownloadedBook fromJson(Directory dir, Map<String, dynamic> json) {
    final Map<String, dynamic> bookJson = (json['book'] as Map)
        .cast<String, dynamic>();
    return KomgaDownloadedBook(
      connectionId: json['connectionId'] as String,
      book: KomgaBook.fromJson(bookJson),
      bookJson: bookJson,
      imagePaths: (json['images'] as List<dynamic>)
          .map((dynamic name) => '${dir.path}${Platform.pathSeparator}$name')
          .toList(),
      downloadedAt: DateTime.parse(json['downloadedAt'] as String),
    );
  }
}

enum KomgaDownloadState { queued, downloading, extracting, failed }

class KomgaDownloadTask {
  KomgaDownloadTask(this.book);

  final KomgaBook book;
  KomgaDownloadState state = KomgaDownloadState.queued;

  /// Download progress in [0, 1]; null when the size is unknown.
  double? progress;
  Object? error;
}

/// Downloads Komga books for offline reading, one at a time.
class KomgaDownloadService extends ChangeNotifier
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  KomgaDownloadService({Directory Function()? rootProvider})
    : _rootProvider = rootProvider;

  static const String _manifestName = 'manifest.json';

  final Directory Function()? _rootProvider;
  final Map<String, KomgaDownloadedBook> _downloaded =
      <String, KomgaDownloadedBook>{};
  final Map<String, KomgaDownloadTask> _tasks = <String, KomgaDownloadTask>{};
  final List<(KomgaClient, String)> _queue = <(KomgaClient, String)>[];
  bool _running = false;
  Completer<void>? _idle;

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies..add(pathService);

  @override
  Future<void> doInitBean() async {
    await reload();
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Directory get root =>
      _rootProvider?.call() ??
      Directory(
        '${(pathService.appSupportDir ?? pathService.getVisibleDir()).path}'
        '${Platform.pathSeparator}komga_downloads',
      );

  /// Read every manifest under [root].
  Future<void> reload() async {
    _downloaded.clear();
    if (await root.exists()) {
      await for (final FileSystemEntity entity in root.list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith(_manifestName)) {
          continue;
        }
        try {
          final KomgaDownloadedBook book = KomgaDownloadedBook.fromJson(
            entity.parent,
            (jsonDecode(await entity.readAsString()) as Map)
                .cast<String, dynamic>(),
          );
          _downloaded[book.recordKey] = book;
        } catch (e) {
          log.warning('Unreadable Komga download manifest ${entity.path}', e);
        }
      }
    }
    notifyListeners();
  }

  KomgaDownloadedBook? downloaded(String recordKey) => _downloaded[recordKey];

  KomgaDownloadTask? task(String recordKey) => _tasks[recordKey];

  /// Downloaded books of one server connection, by series then volume.
  List<KomgaDownloadedBook> downloadedBooks(String connectionId) {
    return _downloaded.values
        .where((KomgaDownloadedBook b) => b.connectionId == connectionId)
        .toList()
      ..sort((KomgaDownloadedBook a, KomgaDownloadedBook b) {
        final int series = a.book.seriesTitle.compareTo(b.book.seriesTitle);
        return series != 0
            ? series
            : a.book.numberSort.compareTo(b.book.numberSort);
      });
  }

  /// Queue [book]; already downloaded or queued books are skipped.
  void enqueue(KomgaClient client, KomgaBook book) {
    final String key = client.progressRecordKey(book.id);
    final KomgaDownloadTask? existing = _tasks[key];
    if (_downloaded.containsKey(key) ||
        (existing != null && existing.state != KomgaDownloadState.failed)) {
      return;
    }
    _tasks[key] = KomgaDownloadTask(book);
    _queue.add((client, key));
    notifyListeners();
    unawaited(_drain());
  }

  /// Queue every readable book of [series] in volume order.
  Future<void> enqueueSeries(KomgaClient client, KomgaSeries series) async {
    final KomgaPageResult<KomgaBook> books = await client.listBooks(
      KomgaQuery(
        target: KomgaTarget.books,
        seriesId: series.id,
        sortMode: KomgaSortMode.number,
        descending: false,
      ),
      page: 0,
      size: 2000,
    );
    for (final KomgaBook book in books.content.where(
      (KomgaBook b) => b.isReadable,
    )) {
      enqueue(client, book);
    }
  }

  /// Completes when the queue is empty.
  Future<void> whenIdle() => _running ? _idle!.future : Future<void>.value();

  Future<void> delete(String recordKey) async {
    final KomgaDownloadedBook? book = _downloaded.remove(recordKey);
    _tasks.remove(recordKey);
    if (book != null) {
      final Directory dir = _bookDir(book.connectionId, book.book.id);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
    notifyListeners();
  }

  Directory _bookDir(String connectionId, String bookId) => Directory(
    '${root.path}${Platform.pathSeparator}$connectionId'
    '${Platform.pathSeparator}$bookId',
  );

  Future<void> _drain() async {
    if (_running) {
      return;
    }
    _running = true;
    _idle = Completer<void>();
    try {
      while (_queue.isNotEmpty) {
        final (KomgaClient client, String key) = _queue.removeAt(0);
        final KomgaDownloadTask? task = _tasks[key];
        if (task == null) {
          continue;
        }
        try {
          await _download(client, task);
          _tasks.remove(key);
        } catch (e) {
          log.warning('Komga download failed: ${task.book.title}', e);
          task
            ..state = KomgaDownloadState.failed
            ..error = e;
        }
        notifyListeners();
      }
    } finally {
      _running = false;
      _idle!.complete();
    }
  }

  Future<void> _download(KomgaClient client, KomgaDownloadTask task) async {
    final KomgaBook book = task.book;
    final List<KomgaBookPage> pages = (await client.getBookPages(book.id))
      ..sort((KomgaBookPage a, KomgaBookPage b) => a.number.compareTo(b.number));
    if (pages.isEmpty) {
      throw StateError('Book has no image pages');
    }
    final Map<String, dynamic> bookJson = await client.getBookJson(book.id);

    final Directory dir = _bookDir(client.connectionId, book.id);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);
    final String archivePath = '${dir.path}${Platform.pathSeparator}book.part';

    task.state = KomgaDownloadState.downloading;
    notifyListeners();
    await client.downloadBookFile(
      book.id,
      archivePath,
      onReceiveProgress: (int received, int total) {
        task.progress = total > 0 ? received / total : null;
        notifyListeners();
      },
    );

    task.state = KomgaDownloadState.extracting;
    notifyListeners();
    final List<String> fileNames = pages
        .map((KomgaBookPage p) => p.fileName)
        .toList();
    final String dirPath = dir.path;
    final List<String> images = await _extractInBackground(
      archivePath,
      fileNames,
      dirPath,
    );
    await File(archivePath).delete();
    // The reader cannot decode some formats (TIFF, for example); store the
    // server-converted PNG for those pages instead.
    for (int i = 0; i < pages.length; i++) {
      if (KomgaClient.isDecodableMediaType(pages[i].mediaType)) {
        continue;
      }
      await File(images[i]).delete();
      images[i] = '${images[i].substring(0, images[i].lastIndexOf('.'))}.png';
      await client.downloadPageImage(book.id, pages[i], images[i]);
    }

    final KomgaDownloadedBook downloaded = KomgaDownloadedBook(
      connectionId: client.connectionId,
      book: KomgaBook.fromJson(bookJson),
      bookJson: bookJson,
      imagePaths: images,
      downloadedAt: DateTime.now(),
    );
    await File(
      '${dir.path}${Platform.pathSeparator}$_manifestName',
    ).writeAsString(jsonEncode(downloaded.toJson()));
    _downloaded[downloaded.recordKey] = downloaded;
  }
}

/// Runs [_extractPages] in a background isolate. The closure is created here,
/// not inside a service method, so it captures only these three sendable
/// arguments and not the service.
Future<List<String>> _extractInBackground(
  String archivePath,
  List<String> fileNames,
  String dirPath,
) {
  return Isolate.run(() => _extractPages(archivePath, fileNames, dirPath));
}

/// Extract [fileNames] from the book archive into [dirPath] as 0001.ext,
/// 0002.ext, ... in page order. Runs in a background isolate.
List<String> _extractPages(
  String archivePath,
  List<String> fileNames,
  String dirPath,
) {
  final InputFileStream input = InputFileStream(archivePath);
  try {
    final Archive archive = ZipDecoder().decodeBuffer(input);
    final List<String> paths = <String>[];
    for (int i = 0; i < fileNames.length; i++) {
      final ArchiveFile? entry = archive.findFile(fileNames[i]);
      if (entry == null) {
        throw StateError('Page ${fileNames[i]} is missing from the book file');
      }
      final String name = fileNames[i].split('/').last;
      final int dot = name.lastIndexOf('.');
      final String ext = dot >= 0 ? name.substring(dot) : '';
      final String path =
          '$dirPath${Platform.pathSeparator}${(i + 1).toString().padLeft(4, '0')}$ext';
      final OutputFileStream output = OutputFileStream(path);
      entry.writeContent(output);
      output.close();
      paths.add(path);
    }
    return paths;
  } finally {
    input.close();
  }
}
