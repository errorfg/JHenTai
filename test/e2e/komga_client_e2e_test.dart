import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/komga/komga_browse_models.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/komga/komga_query.dart';
import 'package:jhentai/src/network/komga_client.dart';

import 'support/local_komga.dart';

void main() {
  final KomgaE2eConfig? config = KomgaE2eConfig.load();
  if (config == null) {
    test('Komga end-to-end tests', () {}, skip: 'test/e2e/komga_e2e.json is absent');
    return;
  }
  late LocalKomga komga;
  late KomgaClient client;

  Future<List<KomgaSeries>> allSeries(KomgaQuery query, {int size = 50}) async {
    final List<KomgaSeries> result = <KomgaSeries>[];
    for (int page = 0; ; page++) {
      final KomgaPageResult<KomgaSeries> chunk = await client.listSeries(
        query,
        page: page,
        size: size,
      );
      result.addAll(chunk.content);
      if (chunk.isLast) {
        return result;
      }
    }
  }

  Future<List<KomgaBook>> allBooks(KomgaQuery query) async =>
      (await client.listBooks(query, page: 0, size: 100)).content;

  Future<KomgaSeries> seriesNamed(String title) async =>
      (await allSeries(const KomgaQuery(target: KomgaTarget.series)))
          .singleWhere((KomgaSeries s) => s.title == title);

  Future<List<KomgaBook>> volumes(String title) async => allBooks(
    KomgaQuery(
      target: KomgaTarget.books,
      seriesId: (await seriesNamed(title)).id,
      sortMode: KomgaSortMode.number,
      descending: false,
    ),
  );

  setUpAll(() async {
    komga = await LocalKomga.start(config);
    client = KomgaClient(
      serverUrl: komga.serverUrl,
      username: '',
      password: '',
      apiKey: komga.apiKey,
      connectionId: 'e2e',
    );
  });

  tearDownAll(() async {
    await komga.stop();
  });

  group('listing', () {
    test('pages through every series once, sorted by title', () async {
      final List<KomgaSeries> series = await allSeries(
        const KomgaQuery(
          target: KomgaTarget.series,
          sortMode: KomgaSortMode.title,
          descending: false,
        ),
        size: 2,
      );
      expect(series.map((KomgaSeries s) => s.title), <String>[
        TestLibrary.alpha,
        TestLibrary.beta,
        TestLibrary.gamma,
      ]);
    });

    test('books of a series follow the volume number both ways', () async {
      final String seriesId = (await seriesNamed(TestLibrary.alpha)).id;
      final List<KomgaBook> ascending = await allBooks(
        KomgaQuery(
          target: KomgaTarget.books,
          seriesId: seriesId,
          sortMode: KomgaSortMode.number,
          descending: false,
        ),
      );
      final List<KomgaBook> descending = await allBooks(
        KomgaQuery(
          target: KomgaTarget.books,
          seriesId: seriesId,
          sortMode: KomgaSortMode.number,
        ),
      );
      expect(ascending.map((KomgaBook b) => b.numberSort), <double>[1, 2, 3, 4, 5]);
      expect(descending.map((KomgaBook b) => b.numberSort), <double>[5, 4, 3, 2, 1]);
    });

    test('series carry the metadata shown in the series header', () async {
      final KomgaSeries alpha = await seriesNamed(TestLibrary.alpha);
      expect(alpha.booksCount, 5);
      expect(alpha.publisher, 'Pub X');
      expect(alpha.language, 'ja');
      expect(alpha.genres, <String>['action']);
      expect(alpha.tags, <String>['tag-a']);
      expect(alpha.readingDirection, 'RIGHT_TO_LEFT');
      expect(alpha.authors.map((KomgaAuthor a) => a.name), <String>['Author A']);
    });
  });

  group('search and filters', () {
    test('full-text search finds series and books across libraries', () async {
      final List<KomgaSeries> series = await allSeries(
        const KomgaQuery(
          target: KomgaTarget.series,
          search: 'Beta',
          sortMode: KomgaSortMode.relevance,
        ),
      );
      final List<KomgaBook> books = await allBooks(
        const KomgaQuery(
          target: KomgaTarget.books,
          search: 'Alpha',
          sortMode: KomgaSortMode.relevance,
        ),
      );
      expect(series.map((KomgaSeries s) => s.title), <String>[TestLibrary.beta]);
      expect(books, hasLength(5));
      expect(books.every((KomgaBook b) => b.seriesTitle == TestLibrary.alpha), isTrue);
    });

    Future<List<String>> titlesWith(KomgaFilters filters) async =>
        (await allSeries(
          KomgaQuery(
            target: KomgaTarget.series,
            filters: filters,
            sortMode: KomgaSortMode.title,
            descending: false,
          ),
        )).map((KomgaSeries s) => s.title).toList();

    test('each filter category selects the matching series', () async {
      expect(await titlesWith(const KomgaFilters(authors: {'Author A'})), <String>[TestLibrary.alpha]);
      expect(await titlesWith(const KomgaFilters(publishers: {'Pub Y'})), <String>[TestLibrary.beta]);
      expect(await titlesWith(const KomgaFilters(languages: {'zh'})), <String>[TestLibrary.beta]);
      expect(await titlesWith(const KomgaFilters(genres: {'action'})), <String>[TestLibrary.alpha]);
      // Series match tags of their books as well as their own.
      expect(await titlesWith(const KomgaFilters(tags: {'tag-b'})), <String>[TestLibrary.beta]);
    });

    test('values in one category are alternatives, categories combine', () async {
      expect(
        await titlesWith(const KomgaFilters(authors: {'Author A', 'Author B'})),
        <String>[TestLibrary.alpha, TestLibrary.beta],
      );
      expect(
        await titlesWith(const KomgaFilters(authors: {'Author A'}, publishers: {'Pub Y'})),
        isEmpty,
      );
    });

    test('book lists apply author and tag filters', () async {
      final List<KomgaBook> books = await allBooks(
        const KomgaQuery(
          target: KomgaTarget.books,
          filters: KomgaFilters(authors: {'Author B'}, tags: {'tag-b'}),
        ),
      );
      expect(books, hasLength(3));
    });

    test('filter options list the values the server has', () async {
      final KomgaFilterOptions options = await client.getFilterOptions(
        libraryId: komga.libraryId,
      );
      expect(options.authors, <String>['Author A', 'Author B']);
      expect(options.publishers, <String>['Pub X', 'Pub Y']);
      expect(options.languages, <String>['en', 'ja', 'zh']);
      expect(options.tags, <String>['tag-a', 'tag-b']);
      expect(options.genres, <String>['action', 'slice of life']);
    });
  });

  group('reading state', () {
    test('neighbouring volumes, with null at both ends', () async {
      final List<KomgaBook> alpha = await volumes(TestLibrary.alpha);
      expect((await client.siblingBook(alpha[1].id, next: true))!.id, alpha[2].id);
      expect((await client.siblingBook(alpha[1].id, next: false))!.id, alpha[0].id);
      expect(await client.siblingBook(alpha[4].id, next: true), isNull);
      expect(await client.siblingBook(alpha[0].id, next: false), isNull);
    });

    test('a whole series can be marked read and unread', () async {
      final String id = (await seriesNamed(TestLibrary.beta)).id;
      await client.markSeriesRead(id);
      final KomgaSeries read = await client.getSeries(id);
      expect(read.booksReadCount, 3);

      await client.markSeriesUnread(id);
      final KomgaSeries unread = await client.getSeries(id);
      expect(unread.booksReadCount, 0);
      expect(unread.booksUnreadCount, 3);
    });

    test('read-status filters and on deck follow server progress', () async {
      final List<KomgaBook> alpha = await volumes(TestLibrary.alpha);
      await client.reportReadProgress(alpha[0].id, alpha[0].pageCount - 1);
      try {
        final List<KomgaBook> read = await allBooks(
          const KomgaQuery(target: KomgaTarget.books, progress: KomgaProgressFilter.read),
        );
        expect(read.map((KomgaBook b) => b.id), <String>[alpha[0].id]);

        final List<KomgaBook> onDeck = (await client.onDeckBooks()).content;
        expect(onDeck.map((KomgaBook b) => b.id), <String>[alpha[1].id]);

        await client.reportReadProgress(alpha[1].id, 0);
        final List<KomgaBook> inProgress = await allBooks(
          const KomgaQuery(target: KomgaTarget.books, progress: KomgaProgressFilter.inProgress),
        );
        expect(inProgress.map((KomgaBook b) => b.id), <String>[alpha[1].id]);
        // A series with a book in progress is no longer on deck.
        expect((await client.onDeckBooks()).content, isEmpty);
      } finally {
        await client.markSeriesUnread(alpha[0].seriesId);
      }
    });

    test('new series, and updated series once a book arrives', () async {
      expect((await client.latestSeries(updated: false)).content, hasLength(3));
      // Komga counts a series as updated when the series itself was modified
      // after creation; metadata edits do not count, new books do.
      expect((await client.latestSeries(updated: true)).content, isEmpty);

      await Future<void>.delayed(const Duration(seconds: 1));
      await TestLibrary.addBetaVolume(komga.libraryDir, 4);
      await komga.rescan(TestLibrary.bookCount + 1);
      final List<KomgaSeries> updated = (await client.latestSeries(
        updated: true,
      )).content;
      expect(updated.map((KomgaSeries s) => s.title), <String>[TestLibrary.beta]);
      expect(updated.single.booksCount, 4);
    });
  });

  group('pages and files', () {
    Future<Uint8List> fetch(String url) async {
      final HttpClient http = HttpClient();
      try {
        final HttpClientRequest request = await http.getUrl(Uri.parse(url));
        client.imageHeaders.forEach(request.headers.set);
        final HttpClientResponse response = await request.close();
        expect(response.statusCode, 200, reason: url);
        final BytesBuilder bytes = BytesBuilder();
        await response.forEach(bytes.add);
        return bytes.toBytes();
      } finally {
        http.close();
      }
    }

    test('pages Flutter cannot decode are converted to PNG', () async {
      final KomgaBook tiffBook = (await volumes(TestLibrary.gamma)).last;
      final List<KomgaBookPage> pages = await client.getBookPages(tiffBook.id);
      final KomgaBookPage tiff = pages.last;
      expect(tiff.mediaType, 'image/tiff');

      final String converted = client.bookPageUrl(tiffBook.id, tiff.number, mediaType: tiff.mediaType);
      expect(Uri.parse(converted).queryParameters['convert'], 'png');
      final Uint8List bytes = await fetch(converted);
      expect(bytes.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);

      final String png = client.bookPageUrl(tiffBook.id, 1, mediaType: pages.first.mediaType);
      expect(Uri.parse(png).queryParameters.containsKey('convert'), isFalse);
    });

    test('page thumbnails are served as small images', () async {
      final KomgaBook book = (await volumes(TestLibrary.alpha)).first;
      final Uint8List bytes = await fetch(client.bookPageThumbnailUrl(book.id, 1));
      expect(bytes, isNotEmpty);
    });

    test('image EPUBs are readable, text EPUBs are not', () async {
      final List<KomgaBook> gamma = await volumes(TestLibrary.gamma);
      expect(gamma[0].isReadable, isTrue);
      expect((await client.getBookPages(gamma[0].id)).map((KomgaBookPage p) => p.fileName), <String>[
        'OEBPS/images/p1.png',
        'OEBPS/images/p2.png',
        'OEBPS/images/p3.png',
      ]);
      expect(gamma[1].isTextEpub, isTrue);
      expect(gamma[1].isReadable, isFalse);
      expect(gamma[1].pageCount, greaterThan(0));
      expect(await client.getBookPages(gamma[1].id), isEmpty);
    });

    test('the downloaded file holds the pages named by the page list', () async {
      final KomgaBook book = (await volumes(TestLibrary.alpha)).first;
      final Directory dir = await Directory.systemTemp.createTemp('komga-dl-');
      try {
        final String path = '${dir.path}/book.cbz';
        int received = 0;
        await client.downloadBookFile(
          book.id,
          path,
          onReceiveProgress: (int count, int _) => received = count,
        );
        final Archive archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
        final List<KomgaBookPage> pages = await client.getBookPages(book.id);
        for (final KomgaBookPage page in pages) {
          final ArchiveFile? entry = archive.findFile(page.fileName);
          expect(entry, isNotNull, reason: 'missing ${page.fileName}');
          expect(
            entry!.content,
            TestLibrary.pagePng('${TestLibrary.alpha} v1.cbz', page.number),
            reason: page.fileName,
          );
        }
        expect(received, File(path).lengthSync(), reason: 'progress bytes');
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  test('a rejected API key yields the version hint', () async {
    final KomgaClient wrongKey = KomgaClient(
      serverUrl: komga.serverUrl,
      username: '',
      password: '',
      apiKey: 'not-a-key',
      connectionId: 'e2e',
    );
    try {
      await wrongKey.getLibraries();
      fail('expected 401');
    } on DioException catch (e) {
      expect(e.response?.statusCode, 401);
      expect(KomgaClient.friendlyError(e), 'komgaApiKeyRejected');
    }
  });

  test('a rejected password yields the credentials hint', () async {
    final KomgaClient wrongPassword = KomgaClient(
      serverUrl: komga.serverUrl,
      username: LocalKomga.email,
      password: 'not-the-password',
      apiKey: '',
      connectionId: 'e2e',
    );
    try {
      await wrongPassword.getLibraries();
      fail('expected 401');
    } on DioException catch (e) {
      expect(e.response?.statusCode, 401);
      expect(KomgaClient.friendlyError(e), 'komgaAuthFailed');
    }
  });

  test('an account without the download role gets the permission hint', () async {
    const String email = 'reader-only@example.com';
    const String password = 'reader-password';
    await komga.api(
      'POST',
      '/api/v2/users',
      body: <String, dynamic>{
        'email': email,
        'password': password,
        'roles': <String>['PAGE_STREAMING'],
      },
    );
    final KomgaClient reader = KomgaClient(
      serverUrl: komga.serverUrl,
      username: email,
      password: password,
      apiKey: '',
      connectionId: 'e2e-reader',
    );
    final KomgaBook book = (await volumes(TestLibrary.alpha)).first;
    // The role only gates the file: this account still sees the book.
    expect((await reader.getBookPages(book.id)), isNotEmpty);

    final Directory dir = await Directory.systemTemp.createTemp('komga-403-');
    try {
      await reader.downloadBookFile(book.id, '${dir.path}/book.cbz');
      fail('expected 403');
    } on DioException catch (e) {
      expect(e.response?.statusCode, 403);
      expect(KomgaClient.friendlyError(e), 'komgaForbidden');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('a server that refuses the connection yields the network hint', () async {
    final ServerSocket closed = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int port = closed.port;
    await closed.close();
    final KomgaClient unreachable = KomgaClient(
      serverUrl: 'http://127.0.0.1:$port',
      username: '',
      password: '',
      apiKey: komga.apiKey,
      connectionId: 'e2e-unreachable',
    );
    try {
      await unreachable.getLibraries();
      fail('expected a connection error');
    } on DioException catch (e) {
      expect(e.response, isNull);
      expect(KomgaClient.friendlyError(e), 'komgaConnectionFailed');
    }
  });

  // Runs last: removes a file from the library.
  test('books deleted from disk are excluded from lists', () async {
    final String betaId = (await seriesNamed(TestLibrary.beta)).id;
    final KomgaQuery betaBooks = KomgaQuery(target: KomgaTarget.books, seriesId: betaId);
    final int before = (await allBooks(betaBooks)).length;
    final int total = (await client.listBooks(
      const KomgaQuery(target: KomgaTarget.books),
      page: 0,
      size: 1,
    )).totalElements;

    final File file = File('${komga.libraryDir.path}/${TestLibrary.beta}/${TestLibrary.beta} v3.cbz');
    await file.delete();
    await komga.rescan(total - 1);

    expect(await allBooks(betaBooks), hasLength(before - 1));
    final Map<String, dynamic> trash = await komga.api(
      'POST',
      '/api/v1/books/list',
      body: <String, dynamic>{
        'condition': <String, dynamic>{
          'deleted': <String, dynamic>{'operator': 'isTrue'},
        },
      },
    ) as Map<String, dynamic>;
    expect(trash['content'] as List<dynamic>, hasLength(1));
  });
}
