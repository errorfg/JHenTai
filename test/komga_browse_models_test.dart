import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/komga/komga_browse_models.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/service/read_progress_service.dart';

void main() {
  group('Komga local reading state', () {
    test(
      'distinguishes unread, first page, completed, and single-page books',
      () {
        final KomgaBook tenPages = _book('ten', pages: 10);
        final KomgaBook singlePage = _book('single', pages: 1);

        final KomgaBookBrowseItem unread = KomgaBookBrowseItem.fromBook(
          book: tenPages,
          progress: null,
        );
        final KomgaBookBrowseItem firstPage = KomgaBookBrowseItem.fromBook(
          book: tenPages,
          progress: _progress('ten', 0, 1),
        );
        final KomgaBookBrowseItem completed = KomgaBookBrowseItem.fromBook(
          book: tenPages,
          progress: _progress('ten', 9, 2),
        );
        final KomgaBookBrowseItem completedSingle =
            KomgaBookBrowseItem.fromBook(
              book: singlePage,
              progress: _progress('single', 0, 3),
            );

        expect(unread.readingStatus, KomgaReadingStatus.unread);
        expect(unread.currentPage, 0);
        expect(unread.progressFraction, 0);
        expect(firstPage.readingStatus, KomgaReadingStatus.inProgress);
        expect(firstPage.currentPage, 1);
        expect(firstPage.progressFraction, 0.1);
        expect(completed.readingStatus, KomgaReadingStatus.read);
        expect(completed.progressFraction, 1);
        expect(completedSingle.readingStatus, KomgaReadingStatus.read);
      },
    );

    test('sorts globally by JHenTai last-read time and leaves unread last', () {
      final KomgaBookBrowseItem older = KomgaBookBrowseItem.fromBook(
        book: _book('older', title: 'Older'),
        progress: _progress('older', 1, 10),
      );
      final KomgaBookBrowseItem newer = KomgaBookBrowseItem.fromBook(
        book: _book('newer', title: 'Newer'),
        progress: _progress('newer', 1, 20),
      );
      final KomgaBookBrowseItem unread = KomgaBookBrowseItem.fromBook(
        book: _book('unread', title: 'Unread'),
        progress: null,
      );

      final List<KomgaBookBrowseItem> sorted =
          filterAndSortKomgaItems<KomgaBookBrowseItem>(
            <KomgaBookBrowseItem>[older, unread, newer],
            filter: KomgaProgressFilter.all,
            sortMode: KomgaSortMode.lastReadAt,
            descending: true,
          );

      expect(sorted.map((KomgaBookBrowseItem item) => item.book.id), <String>[
        'newer',
        'older',
        'unread',
      ]);
    });

    test('newly added is independent of reading status', () {
      final DateTime watermark = DateTime.utc(2026, 8, 1);
      final KomgaBookBrowseItem item = KomgaBookBrowseItem.fromBook(
        book: _book('new-read', created: DateTime.utc(2026, 8, 2), pages: 1),
        progress: _progress('new-read', 0, 20),
        newSince: watermark,
      );

      expect(item.isNew, true);
      expect(item.readingStatus, KomgaReadingStatus.read);
      expect(
        filterAndSortKomgaItems<KomgaBookBrowseItem>(
          <KomgaBookBrowseItem>[item],
          filter: KomgaProgressFilter.newlyAdded,
          sortMode: KomgaSortMode.addedAt,
          descending: true,
        ),
        <KomgaBookBrowseItem>[item],
      );
    });
  });

  group('Komga series aggregation', () {
    test(
      'uses only local book progress and notices a new book in an old series',
      () {
        final DateTime watermark = DateTime.utc(2026, 8, 1);
        final KomgaBookBrowseItem completed = KomgaBookBrowseItem.fromBook(
          book: _book(
            'completed',
            seriesId: 'series',
            created: DateTime.utc(2026, 7, 1),
            pages: 2,
          ),
          progress: _progress('completed', 1, 10),
          newSince: watermark,
        );
        final KomgaBookBrowseItem newUnread = KomgaBookBrowseItem.fromBook(
          book: _book(
            'new',
            seriesId: 'series',
            created: DateTime.utc(2026, 8, 2),
            pages: 2,
          ),
          progress: null,
          newSince: watermark,
        );
        final KomgaSeriesBrowseItem series = KomgaSeriesBrowseItem.fromSeries(
          series: _series('series', created: DateTime.utc(2026, 1, 1)),
          books: <KomgaBookBrowseItem>[completed, newUnread],
          newSince: watermark,
        );

        expect(series.readingStatus, KomgaReadingStatus.inProgress);
        expect(series.readCount, 1);
        expect(series.unreadCount, 1);
        expect(series.isNew, true);
        expect(series.addedAt, DateTime.utc(2026, 8, 2));
        expect(series.progressFraction, 0.5);
      },
    );

    test('treats books missing from the aggregate as unread', () {
      final KomgaSeriesBrowseItem series = KomgaSeriesBrowseItem.fromSeries(
        series: _series('series', created: DateTime.utc(2026, 1, 1)),
        books: <KomgaBookBrowseItem>[
          KomgaBookBrowseItem.fromBook(
            book: _book('known', seriesId: 'series', pages: 2),
            progress: _progress('known', 1, 10),
          ),
        ],
      );

      expect(series.bookCount, 2);
      expect(series.readCount, 1);
      expect(series.unreadCount, 1);
      expect(series.readingStatus, KomgaReadingStatus.inProgress);
      expect(series.progressFraction, 0.5);
    });
  });

  test('browse preferences and per-library watermark round-trip', () {
    final KomgaBrowsePreferences preferences = const KomgaBrowsePreferences()
        .copyWith(
          libraryView: KomgaLibraryView.books,
          displayMode: KomgaDisplayMode.detail,
          progressFilter: KomgaProgressFilter.inProgress,
          sortMode: KomgaSortMode.lastReadAt,
          descending: false,
        )
        .markLibrarySeen('connection', 'library', DateTime.utc(2026, 8, 2));

    final KomgaBrowsePreferences restored =
        KomgaBrowsePreferences.fromJsonString(preferences.toJsonString());

    expect(restored.libraryView, KomgaLibraryView.books);
    expect(restored.displayMode, KomgaDisplayMode.detail);
    expect(restored.progressFilter, KomgaProgressFilter.inProgress);
    expect(restored.sortMode, KomgaSortMode.lastReadAt);
    expect(restored.descending, false);
    expect(
      restored.lastSeen('connection', 'library'),
      DateTime.utc(2026, 8, 2),
    );
    expect(restored.hasSeenLibrary('connection', 'library'), true);
  });

  test('an empty library still records that its baseline was seen', () {
    final KomgaBrowsePreferences restored =
        KomgaBrowsePreferences.fromJsonString(
          const KomgaBrowsePreferences()
              .markLibrarySeen('connection', 'empty-library', null)
              .toJsonString(),
        );

    expect(restored.hasSeenLibrary('connection', 'empty-library'), true);
    expect(restored.lastSeen('connection', 'empty-library'), isNull);
  });

  test('old watermark payloads imply the library has been seen', () {
    final KomgaBrowsePreferences
    restored = KomgaBrowsePreferences.fromJsonString(
      '{"lastSeenByLibrary":{"connection::library":"2026-08-02T00:00:00.000Z"}}',
    );

    expect(restored.hasSeenLibrary('connection', 'library'), true);
  });
}

KomgaBook _book(
  String id, {
  String title = 'Book',
  String seriesId = 'series',
  int pages = 10,
  DateTime? created,
}) {
  return KomgaBook.fromJson(<String, dynamic>{
    'id': id,
    'seriesId': seriesId,
    'seriesTitle': 'Series',
    'name': '$id.cbz',
    'created': (created ?? DateTime.utc(2026, 1, 1)).toIso8601String(),
    'metadata': <String, dynamic>{
      'title': title,
      'number': '1',
      'authors': <dynamic>[],
      'tags': <dynamic>[],
    },
    'media': <String, dynamic>{
      'status': 'READY',
      'mediaType': 'application/zip',
      'pagesCount': pages,
    },
  });
}

KomgaSeries _series(String id, {required DateTime created}) {
  return KomgaSeries.fromJson(<String, dynamic>{
    'id': id,
    'libraryId': 'library',
    'name': 'Series',
    'booksCount': 2,
    'created': created.toIso8601String(),
    'metadata': <String, dynamic>{'title': 'Series', 'tags': <dynamic>[]},
    'booksMetadata': <String, dynamic>{'authors': <dynamic>[]},
  });
}

ReadProgressEntry _progress(String id, int pageIndex, int seconds) {
  return ReadProgressEntry(
    key: 'komga:connection:$id',
    pageIndex: pageIndex,
    lastReadAt: DateTime.utc(2026, 8, 1, 0, 0, seconds),
  );
}
