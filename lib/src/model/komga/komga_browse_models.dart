import 'dart:convert';

import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/service/read_progress_service.dart';

enum KomgaLibraryView { series, books }

enum KomgaDisplayMode { grid, list, detail }

enum KomgaProgressFilter { all, unread, inProgress, read, newlyAdded }

enum KomgaSortMode { addedAt, lastReadAt, title }

enum KomgaReadingStatus { unread, inProgress, read }

class KomgaBrowsePreferences {
  const KomgaBrowsePreferences({
    this.libraryView = KomgaLibraryView.series,
    this.displayMode = KomgaDisplayMode.grid,
    this.progressFilter = KomgaProgressFilter.all,
    this.sortMode = KomgaSortMode.addedAt,
    this.descending = true,
    this.lastSeenByLibrary = const <String, String>{},
    this.seenLibraries = const <String>{},
  });

  final KomgaLibraryView libraryView;
  final KomgaDisplayMode displayMode;
  final KomgaProgressFilter progressFilter;
  final KomgaSortMode sortMode;
  final bool descending;
  final Map<String, String> lastSeenByLibrary;
  final Set<String> seenLibraries;

  factory KomgaBrowsePreferences.fromJsonString(String? value) {
    if (value == null || value.trim().isEmpty) {
      return const KomgaBrowsePreferences();
    }

    try {
      final Map<String, dynamic> json = (jsonDecode(value) as Map)
          .cast<String, dynamic>();
      final Map<String, String> lastSeenByLibrary =
          ((json['lastSeenByLibrary'] as Map?) ?? const <String, String>{}).map(
            (dynamic key, dynamic value) =>
                MapEntry(key.toString(), value.toString()),
          );
      return KomgaBrowsePreferences(
        libraryView: _enumByName(
          KomgaLibraryView.values,
          json['libraryView'],
          KomgaLibraryView.series,
        ),
        displayMode: _enumByName(
          KomgaDisplayMode.values,
          json['displayMode'],
          KomgaDisplayMode.grid,
        ),
        progressFilter: _enumByName(
          KomgaProgressFilter.values,
          json['progressFilter'],
          KomgaProgressFilter.all,
        ),
        sortMode: _enumByName(
          KomgaSortMode.values,
          json['sortMode'],
          KomgaSortMode.addedAt,
        ),
        descending: json['descending'] as bool? ?? true,
        lastSeenByLibrary: lastSeenByLibrary,
        seenLibraries: <String>{
          ...lastSeenByLibrary.keys,
          ...((json['seenLibraries'] as List?) ?? const <dynamic>[]).map(
            (dynamic value) => value.toString(),
          ),
        },
      );
    } catch (_) {
      return const KomgaBrowsePreferences();
    }
  }

  String toJsonString() {
    return jsonEncode(<String, dynamic>{
      'libraryView': libraryView.name,
      'displayMode': displayMode.name,
      'progressFilter': progressFilter.name,
      'sortMode': sortMode.name,
      'descending': descending,
      'lastSeenByLibrary': lastSeenByLibrary,
      'seenLibraries': seenLibraries.toList(growable: false),
    });
  }

  KomgaBrowsePreferences copyWith({
    KomgaLibraryView? libraryView,
    KomgaDisplayMode? displayMode,
    KomgaProgressFilter? progressFilter,
    KomgaSortMode? sortMode,
    bool? descending,
    Map<String, String>? lastSeenByLibrary,
    Set<String>? seenLibraries,
  }) {
    return KomgaBrowsePreferences(
      libraryView: libraryView ?? this.libraryView,
      displayMode: displayMode ?? this.displayMode,
      progressFilter: progressFilter ?? this.progressFilter,
      sortMode: sortMode ?? this.sortMode,
      descending: descending ?? this.descending,
      lastSeenByLibrary: lastSeenByLibrary ?? this.lastSeenByLibrary,
      seenLibraries: seenLibraries ?? this.seenLibraries,
    );
  }

  DateTime? lastSeen(String sourceFingerprint, String libraryId) {
    return DateTime.tryParse(
      lastSeenByLibrary[_libraryKey(sourceFingerprint, libraryId)] ?? '',
    )?.toUtc();
  }

  bool hasSeenLibrary(String sourceFingerprint, String libraryId) {
    final String key = _libraryKey(sourceFingerprint, libraryId);
    return seenLibraries.contains(key) || lastSeenByLibrary.containsKey(key);
  }

  KomgaBrowsePreferences markLibrarySeen(
    String sourceFingerprint,
    String libraryId,
    DateTime? timestamp,
  ) {
    final String key = _libraryKey(sourceFingerprint, libraryId);
    return copyWith(
      lastSeenByLibrary: <String, String>{
        ...lastSeenByLibrary,
        if (timestamp != null) key: timestamp.toUtc().toIso8601String(),
      },
      seenLibraries: <String>{...seenLibraries, key},
    );
  }

  static String _libraryKey(String sourceFingerprint, String libraryId) {
    return '$sourceFingerprint::$libraryId';
  }
}

abstract interface class KomgaBrowseItem {
  String get title;

  DateTime? get addedAt;

  DateTime? get lastReadAt;

  KomgaReadingStatus get readingStatus;

  bool get isNew;
}

class KomgaBookBrowseItem implements KomgaBrowseItem {
  const KomgaBookBrowseItem({
    required this.book,
    required this.progress,
    required this.isNew,
  });

  final KomgaBook book;
  final ReadProgressEntry? progress;

  @override
  final bool isNew;

  factory KomgaBookBrowseItem.fromBook({
    required KomgaBook book,
    required ReadProgressEntry? progress,
    DateTime? newSince,
  }) {
    return KomgaBookBrowseItem(
      book: book,
      progress: progress,
      isNew:
          newSince != null &&
          book.createdDate != null &&
          book.createdDate!.isAfter(newSince),
    );
  }

  @override
  String get title => book.title;

  @override
  DateTime? get addedAt => book.createdDate;

  @override
  DateTime? get lastReadAt => progress?.lastReadAt;

  @override
  KomgaReadingStatus get readingStatus {
    if (progress == null) {
      return KomgaReadingStatus.unread;
    }
    if (book.pageCount > 0 && progress!.pageIndex >= book.pageCount - 1) {
      return KomgaReadingStatus.read;
    }
    return KomgaReadingStatus.inProgress;
  }

  int get currentPage {
    if (progress == null || book.pageCount <= 0) {
      return 0;
    }
    return (progress!.pageIndex + 1).clamp(0, book.pageCount).toInt();
  }

  double get progressFraction {
    if (book.pageCount <= 0) {
      return 0;
    }
    return (currentPage / book.pageCount).clamp(0, 1).toDouble();
  }
}

class KomgaSeriesBrowseItem implements KomgaBrowseItem {
  const KomgaSeriesBrowseItem({
    required this.series,
    required this.books,
    required this.readingStatus,
    required this.isNew,
    required this.addedAt,
    required this.lastReadAt,
    required this.readCount,
    required this.inProgressCount,
    required this.unreadCount,
    required this.progressFraction,
  });

  final KomgaSeries series;
  final List<KomgaBookBrowseItem> books;

  @override
  final KomgaReadingStatus readingStatus;

  @override
  final bool isNew;

  @override
  final DateTime? addedAt;

  @override
  final DateTime? lastReadAt;

  final int readCount;
  final int inProgressCount;
  final int unreadCount;
  final double progressFraction;

  @override
  String get title => series.title;

  int get bookCount =>
      series.booksCount > books.length ? series.booksCount : books.length;

  factory KomgaSeriesBrowseItem.fromSeries({
    required KomgaSeries series,
    required List<KomgaBookBrowseItem> books,
    DateTime? newSince,
  }) {
    final int readCount = books
        .where(
          (KomgaBookBrowseItem item) =>
              item.readingStatus == KomgaReadingStatus.read,
        )
        .length;
    final int inProgressCount = books
        .where(
          (KomgaBookBrowseItem item) =>
              item.readingStatus == KomgaReadingStatus.inProgress,
        )
        .length;
    final int knownUnreadCount = books
        .where(
          (KomgaBookBrowseItem item) =>
              item.readingStatus == KomgaReadingStatus.unread,
        )
        .length;
    final int missingBookCount = (series.booksCount - books.length)
        .clamp(0, series.booksCount)
        .toInt();
    final int unreadCount = knownUnreadCount + missingBookCount;
    final int effectiveBookCount = books.length + missingBookCount;

    final KomgaReadingStatus readingStatus;
    if (effectiveBookCount > 0 && readCount == effectiveBookCount) {
      readingStatus = KomgaReadingStatus.read;
    } else if (readCount > 0 || inProgressCount > 0) {
      readingStatus = KomgaReadingStatus.inProgress;
    } else {
      readingStatus = KomgaReadingStatus.unread;
    }

    final Iterable<DateTime> addedDates = <DateTime?>[
      series.createdDate,
      ...books.map((KomgaBookBrowseItem item) => item.addedAt),
    ].whereType<DateTime>();
    final Iterable<DateTime> readDates = books
        .map((KomgaBookBrowseItem item) => item.lastReadAt)
        .whereType<DateTime>();
    final int knownTotalPages = books.fold<int>(
      0,
      (int total, KomgaBookBrowseItem item) =>
          total + (item.book.pageCount > 0 ? item.book.pageCount : 0),
    );
    final int estimatedMissingBookPages = missingBookCount == 0
        ? 0
        : missingBookCount *
              (knownTotalPages > 0 && books.isNotEmpty
                  ? (knownTotalPages / books.length).ceil()
                  : 1);
    final int totalPages = knownTotalPages + estimatedMissingBookPages;
    final int readPages = books.fold<int>(
      0,
      (int total, KomgaBookBrowseItem item) => total + item.currentPage,
    );

    return KomgaSeriesBrowseItem(
      series: series,
      books: List<KomgaBookBrowseItem>.unmodifiable(books),
      readingStatus: readingStatus,
      isNew:
          books.any((KomgaBookBrowseItem item) => item.isNew) ||
          (newSince != null &&
              series.createdDate != null &&
              series.createdDate!.isAfter(newSince)),
      addedAt: _latestOrNull(addedDates),
      lastReadAt: _latestOrNull(readDates),
      readCount: readCount,
      inProgressCount: inProgressCount,
      unreadCount: unreadCount,
      progressFraction: totalPages == 0
          ? 0
          : (readPages / totalPages).clamp(0, 1).toDouble(),
    );
  }
}

List<T> filterAndSortKomgaItems<T extends KomgaBrowseItem>(
  Iterable<T> items, {
  required KomgaProgressFilter filter,
  required KomgaSortMode sortMode,
  required bool descending,
}) {
  final List<T> result = items.where((T item) {
    return switch (filter) {
      KomgaProgressFilter.all => true,
      KomgaProgressFilter.unread =>
        item.readingStatus == KomgaReadingStatus.unread,
      KomgaProgressFilter.inProgress =>
        item.readingStatus == KomgaReadingStatus.inProgress,
      KomgaProgressFilter.read => item.readingStatus == KomgaReadingStatus.read,
      KomgaProgressFilter.newlyAdded => item.isNew,
    };
  }).toList();

  result.sort((T a, T b) {
    final int primary = switch (sortMode) {
      KomgaSortMode.addedAt => _compareNullableDate(
        a.addedAt,
        b.addedAt,
        descending,
      ),
      KomgaSortMode.lastReadAt => _compareNullableDate(
        a.lastReadAt,
        b.lastReadAt,
        descending,
      ),
      KomgaSortMode.title =>
        descending
            ? b.title.toLowerCase().compareTo(a.title.toLowerCase())
            : a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    };
    if (primary != 0) {
      return primary;
    }
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  });
  return result;
}

T _enumByName<T extends Enum>(List<T> values, dynamic name, T fallback) {
  for (final T value in values) {
    if (value.name == name) {
      return value;
    }
  }
  return fallback;
}

DateTime? _latestOrNull(Iterable<DateTime> values) {
  DateTime? latest;
  for (final DateTime value in values) {
    if (latest == null || value.isAfter(latest)) {
      latest = value;
    }
  }
  return latest;
}

int _compareNullableDate(DateTime? a, DateTime? b, bool descending) {
  if (a == null && b == null) {
    return 0;
  }
  if (a == null) {
    return 1;
  }
  if (b == null) {
    return -1;
  }
  return descending ? b.compareTo(a) : a.compareTo(b);
}
