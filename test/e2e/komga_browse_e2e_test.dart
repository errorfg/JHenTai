import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/komga/komga_browse_models.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/komga/komga_query.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/pages/komga/komga_browse_controller.dart';
import 'package:jhentai/src/pages/komga/komga_reader_launcher.dart';
import 'package:jhentai/src/service/komga_download_service.dart';
import 'package:jhentai/src/service/komga_progress_sync_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';

import 'support/e2e_app.dart';
import 'support/local_komga.dart';

/// The browser, downloads and reader preparation against a real Komga.
void main() {
  final KomgaE2eConfig? config = KomgaE2eConfig.load();
  if (config == null) {
    test('Komga browse e2e', () {}, skip: 'test/e2e/komga_e2e.json is absent');
    return;
  }

  late LocalKomga komga;
  late KomgaClient client;
  late E2eDevice device;
  late Directory downloads;
  late List<KomgaBook> alpha;
  late List<KomgaBook> gamma;

  setUpAll(() async {
    log = SilentLogService();
    komga = await LocalKomga.start(config);
    client = e2eClient(komga);
    device = E2eDevice()..activate();
    downloads = await Directory.systemTemp.createTemp('komga-downloads-');
    komgaDownloadService = KomgaDownloadService(rootProvider: () => downloads);
    alpha = await seriesVolumes(client, TestLibrary.alpha);
    gamma = await seriesVolumes(client, TestLibrary.gamma);
  });

  tearDownAll(() async {
    await device.close();
    await downloads.delete(recursive: true);
    await komga.stop();
  });

  List<String> titles(KomgaLevel level) => switch (level) {
    final KomgaListLevel l => l.loader.items,
    final KomgaSeriesLevel l => l.loader.items,
    _ => const <Object>[],
  }.map((Object item) => switch (item) {
        final KomgaSeries s => s.title,
        final KomgaBook b => b.title,
        _ => '',
      }).toList();

  group('browsing', () {
    late KomgaBrowseController controller;

    setUp(() async {
      controller = KomgaBrowseController(client: client);
      await controller.start();
    });

    tearDown(() => controller.dispose());

    test('home lists the library and the newly added series', () {
      expect(controller.home.libraries.map((KomgaLibrary l) => l.name), <String>['E2E']);
      expect(controller.home.newSeries, hasLength(3));
      expect(controller.home.continueReading, isEmpty);
    });

    test('a library pages its series and switches to books', () async {
      await controller.openLibrary(controller.home.libraries.single);
      final KomgaListLevel level = controller.current as KomgaListLevel;
      expect(titles(level), hasLength(3));

      await controller.setTarget(level, KomgaTarget.books);
      expect(titles(level), hasLength(TestLibrary.bookCount));
      expect(controller.preferences.libraryView, KomgaLibraryView.books);
      await controller.setTarget(level, KomgaTarget.series);
    });

    test('a series lists volumes in order and continue reading follows marks', () async {
      final KomgaSeries series = await client.getSeries(alpha.first.seriesId);
      await controller.openSeries(series);
      final KomgaSeriesLevel level = controller.current as KomgaSeriesLevel;
      expect(titles(level), <String>[for (int v = 1; v <= 5; v++) '${TestLibrary.alpha} vol $v']);
      expect(level.continueTarget!.id, alpha[0].id);
      expect(level.continueRestarts, isFalse);

      await controller.markBook(alpha[0], read: true);
      expect(level.continueTarget!.id, alpha[1].id);
      expect(level.series.booksReadCount, 1);

      await controller.markSeries(series, read: true);
      expect(level.continueTarget!.id, alpha[0].id);
      expect(level.continueRestarts, isTrue);

      await controller.markSeries(series, read: false);
      expect(level.continueRestarts, isFalse);
      expect(level.series.booksReadCount, 0);
    });

    test('a progress report landing after the reader closes updates the series header', () async {
      final KomgaSeries series = await client.getSeries(alpha.first.seriesId);
      await controller.openSeries(series);
      final KomgaSeriesLevel level = controller.current as KomgaSeriesLevel;
      expect(level.series.booksInProgressCount, 0);
      final List<Object> books = List<Object>.of(level.loader.items);

      // What the reader does on close: write local progress, then report.
      await readProgressService.updateReadProgress(client.progressRecordKey(alpha[2].id), 1);
      await komgaProgressSyncService.report(client, alpha[2], 1);

      final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
      while (level.series.booksInProgressCount == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(level.series.booksInProgressCount, 1);
      expect(level.continueTarget!.id, alpha[2].id);
      // Only the header refreshed; the loaded book list is the same.
      expect(level.loader.items, books);

      await controller.markSeries(series, read: false);
    });

    test('a library list refreshes the counts of a series read elsewhere in the app', () async {
      await controller.openLibrary(controller.home.libraries.single);
      final KomgaListLevel library = controller.current as KomgaListLevel;
      KomgaSeries listed() => library.loader.items
          .whereType<KomgaSeries>()
          .singleWhere((KomgaSeries s) => s.title == TestLibrary.alpha);
      expect(listed().booksInProgressCount, 0);

      await readProgressService.updateReadProgress(client.progressRecordKey(alpha[3].id), 1);
      await komgaProgressSyncService.report(client, alpha[3], 1);

      final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
      while (listed().booksInProgressCount == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(listed().booksInProgressCount, 1);

      await controller.markSeries(listed(), read: false);
    });

    test('filters and search open their own levels; back restores the previous one', () async {
      await controller.openLibrary(controller.home.libraries.single);
      final KomgaListLevel library = controller.current as KomgaListLevel;
      final List<Object> libraryItems = List<Object>.of(library.loader.items);

      await controller.openFilter('Author A', const KomgaFilters(authors: {'Author A'}));
      expect(titles(controller.current), <String>[TestLibrary.alpha]);

      await controller.openSearch(TestLibrary.gamma);
      expect(titles(controller.current), <String>[TestLibrary.gamma]);

      controller.goBack();
      controller.goBack();
      expect(identical(controller.current, library), isTrue);
      expect(library.loader.items, libraryItems);
    });
  });

  test('"newly added" shows only books added since the last visit', () async {
    final KomgaBrowseController first = KomgaBrowseController(client: client);
    await first.start();
    await first.openLibrary(first.home.libraries.single);
    first.dispose();

    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await TestLibrary.addBetaVolume(komga.libraryDir, 9);
    await komga.rescan(TestLibrary.bookCount + 1);

    final KomgaBrowseController second = KomgaBrowseController(client: client);
    await second.start();
    await second.openLibrary(second.home.libraries.single);
    final KomgaListLevel level = second.current as KomgaListLevel;
    await second.setTarget(level, KomgaTarget.books);
    await second.setProgressFilter(level, KomgaProgressFilter.newlyAdded);
    expect(titles(level), <String>['${TestLibrary.beta} vol 9']);
    await second.setProgressFilter(level, KomgaProgressFilter.all);
    await second.setTarget(level, KomgaTarget.series);
    second.dispose();
  });

  group('downloads', () {
    Future<void> download(KomgaBook book) async {
      komgaDownloadService.enqueue(client, book);
      await komgaDownloadService.whenIdle();
      final KomgaDownloadTask? failed = komgaDownloadService.task(client.progressRecordKey(book.id));
      expect(failed, isNull, reason: 'download failed: ${failed?.error}');
    }

    test('a downloaded book holds its pages in order and survives a restart', () async {
      final KomgaBook book = alpha[0];
      await download(book);
      final KomgaDownloadedBook stored = komgaDownloadService.downloaded(client.progressRecordKey(book.id))!;
      expect(stored.imagePaths, hasLength(4));
      for (int page = 1; page <= 4; page++) {
        expect(
          File(stored.imagePaths[page - 1]).readAsBytesSync(),
          TestLibrary.pagePng('${TestLibrary.alpha} v1.cbz', page),
          reason: 'page $page',
        );
      }

      komgaDownloadService = KomgaDownloadService(rootProvider: () => downloads);
      await komgaDownloadService.reload();
      expect(
        komgaDownloadService.downloadedBooks('e2e').map((KomgaDownloadedBook d) => d.book.id),
        <String>[book.id],
      );
    });

    test('an image EPUB downloads its images; a TIFF page is stored as PNG', () async {
      await download(gamma[0]);
      final KomgaDownloadedBook epub = komgaDownloadService.downloaded(client.progressRecordKey(gamma[0].id))!;
      expect(
        File(epub.imagePaths[1]).readAsBytesSync(),
        TestLibrary.pagePng('epub-images', 2),
      );

      await download(gamma[2]);
      final KomgaDownloadedBook tiff = komgaDownloadService.downloaded(client.progressRecordKey(gamma[2].id))!;
      expect(tiff.imagePaths.last, endsWith('.png'));
      expect(File(tiff.imagePaths.last).readAsBytesSync().sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
    });

    test('a text EPUB cannot be downloaded', () async {
      komgaDownloadService.enqueue(client, gamma[1]);
      await komgaDownloadService.whenIdle();
      expect(komgaDownloadService.task(client.progressRecordKey(gamma[1].id))!.state, KomgaDownloadState.failed);
      expect(komgaDownloadService.downloaded(client.progressRecordKey(gamma[1].id)), isNull);
    });

    test('deleting a download removes its files', () async {
      await download(alpha[4]);
      final String key = client.progressRecordKey(alpha[4].id);
      final String dir = File(komgaDownloadService.downloaded(key)!.imagePaths.first).parent.path;
      await komgaDownloadService.delete(key);
      expect(komgaDownloadService.downloaded(key), isNull);
      expect(Directory(dir).existsSync(), isFalse);
    });
  });

  group('reader sessions', () {
    test('online books stream pages and open their neighbours', () async {
      final ReadPageInfo info = await KomgaReaderLauncher(client).prepare(alpha[1]);
      expect(info.mode, ReadMode.remote);
      expect(info.pageCount, 4);
      expect(info.images!.first.thumbnailUrl, contains('/pages/1/thumbnail'));

      final ReadPageInfo next = (await info.loadSiblingBook!(next: true))!;
      expect(next.galleryTitle, '${TestLibrary.alpha} vol 3');
      final ReadPageInfo last = await KomgaReaderLauncher(client).prepare(alpha[4]);
      expect(await last.loadSiblingBook!(next: true), isNull);
    });

    test('a page Flutter cannot decode is requested as PNG', () async {
      // Read it online: a downloaded copy would open from disk instead.
      await komgaDownloadService.delete(client.progressRecordKey(gamma[2].id));
      final ReadPageInfo info = await KomgaReaderLauncher(client).prepare(gamma[2]);
      expect(Uri.parse(info.images!.last.url).queryParameters['convert'], 'png');
      expect(Uri.parse(info.images!.first.url).queryParameters.containsKey('convert'), isFalse);
    });

    test('a text EPUB is refused with a message', () async {
      await expectLater(
        KomgaReaderLauncher(client).prepare(gamma[1]),
        throwsA(isA<KomgaOpenException>()),
      );
    });

    test('downloaded books open from disk, and offline siblings come from downloads', () async {
      komgaDownloadService.enqueue(client, alpha[0]);
      komgaDownloadService.enqueue(client, alpha[1]);
      await komgaDownloadService.whenIdle();

      final KomgaReaderLauncher offline = KomgaReaderLauncher(offlineClient(komga));
      final ReadPageInfo info = await offline.prepare(alpha[0]);
      expect(info.mode, ReadMode.local);
      expect(info.images!.every((dynamic image) => File(image.path as String).existsSync()), isTrue);

      final ReadPageInfo next = (await info.loadSiblingBook!(next: true))!;
      expect(next.mode, ReadMode.local);
      expect(next.galleryTitle, '${TestLibrary.alpha} vol 2');
      final Uint8List firstPage = File(next.images!.first.path!).readAsBytesSync();
      expect(firstPage, TestLibrary.pagePng('${TestLibrary.alpha} v2.cbz', 1));
    });
  });
}
