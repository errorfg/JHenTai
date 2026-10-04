import 'dart:convert';

import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/service/read_progress_service.dart';

enum KomgaLibraryView { series, books }

enum KomgaDisplayMode { grid, list, detail }

enum KomgaProgressFilter { all, unread, inProgress, read, newlyAdded }

/// [number] sorts books by volume number; [relevance] is used for search.
enum KomgaSortMode { addedAt, lastReadAt, title, number, relevance }

enum KomgaReadingStatus { unread, inProgress, read }

class KomgaBrowsePreferences {
  const KomgaBrowsePreferences({
    this.libraryView = KomgaLibraryView.series,
    this.displayMode = KomgaDisplayMode.grid,
    this.progressFilter = KomgaProgressFilter.all,
    this.sortMode = KomgaSortMode.addedAt,
    this.descending = true,
    this.seriesSortMode = KomgaSortMode.number,
    this.seriesDescending = false,
    this.lastSeenByLibrary = const <String, String>{},
    this.seenLibraries = const <String>{},
  });

  final KomgaLibraryView libraryView;
  final KomgaDisplayMode displayMode;
  final KomgaProgressFilter progressFilter;
  final KomgaSortMode sortMode;
  final bool descending;

  /// Sort inside one series; kept apart so reading order is not inherited
  /// from the library-level "newest first".
  final KomgaSortMode seriesSortMode;
  final bool seriesDescending;
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
        seriesSortMode: _enumByName(
          KomgaSortMode.values,
          json['seriesSortMode'],
          KomgaSortMode.number,
        ),
        seriesDescending: json['seriesDescending'] as bool? ?? false,
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
      'seriesSortMode': seriesSortMode.name,
      'seriesDescending': seriesDescending,
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
    KomgaSortMode? seriesSortMode,
    bool? seriesDescending,
    Map<String, String>? lastSeenByLibrary,
    Set<String>? seenLibraries,
  }) {
    return KomgaBrowsePreferences(
      libraryView: libraryView ?? this.libraryView,
      displayMode: displayMode ?? this.displayMode,
      progressFilter: progressFilter ?? this.progressFilter,
      sortMode: sortMode ?? this.sortMode,
      descending: descending ?? this.descending,
      seriesSortMode: seriesSortMode ?? this.seriesSortMode,
      seriesDescending: seriesDescending ?? this.seriesDescending,
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

/// A series with its reading state as Komga reports it. Since lists are
/// paged, the books of a series are not all loaded; the counts come from the
/// series itself.
class KomgaSeriesBrowseItem implements KomgaBrowseItem {
  const KomgaSeriesBrowseItem({required this.series, required this.isNew});

  final KomgaSeries series;

  @override
  final bool isNew;

  factory KomgaSeriesBrowseItem.fromSeries({
    required KomgaSeries series,
    DateTime? newSince,
  }) {
    return KomgaSeriesBrowseItem(
      series: series,
      isNew:
          newSince != null &&
          series.createdDate != null &&
          series.createdDate!.isAfter(newSince),
    );
  }

  @override
  String get title => series.title;

  @override
  DateTime? get addedAt => series.createdDate;

  @override
  DateTime? get lastReadAt => null;

  int get bookCount => series.booksCount;

  int get readCount => series.booksReadCount;

  int get inProgressCount => series.booksInProgressCount;

  int get unreadCount => series.booksUnreadCount;

  @override
  KomgaReadingStatus get readingStatus {
    if (series.booksCount > 0 && readCount >= series.booksCount) {
      return KomgaReadingStatus.read;
    }
    if (readCount > 0 || inProgressCount > 0) {
      return KomgaReadingStatus.inProgress;
    }
    return KomgaReadingStatus.unread;
  }

  double get progressFraction => series.booksCount == 0
      ? 0
      : (readCount / series.booksCount).clamp(0, 1).toDouble();
}

T _enumByName<T extends Enum>(List<T> values, dynamic name, T fallback) {
  for (final T value in values) {
    if (value.name == name) {
      return value;
    }
  }
  return fallback;
}
