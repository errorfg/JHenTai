import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/komga/komga_browse_models.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/komga/komga_query.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/pages/komga/komga_paged_loader.dart';
import 'package:jhentai/src/service/komga_download_service.dart';
import 'package:jhentai/src/service/komga_progress_sync_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';

/// One screen of the Komga browser. Each level keeps its own data and scroll
/// position, so going back shows it exactly as it was left.
sealed class KomgaLevel {
  double scrollOffset = 0;

  void dispose() {}
}

class KomgaHomeLevel extends KomgaLevel {
  /// Server progress changed while home was not shown.
  bool stale = false;
  List<KomgaLibrary> libraries = const <KomgaLibrary>[];
  List<KomgaBook> continueReading = const <KomgaBook>[];
  List<KomgaBook> onDeck = const <KomgaBook>[];
  List<KomgaSeries> newSeries = const <KomgaSeries>[];
  List<KomgaSeries> updatedSeries = const <KomgaSeries>[];
  bool loading = false;
  bool loaded = false;
  Object? error;
}

/// A paged list of series or books: a library, search results, or the
/// results of a tag/author/... filter.
class KomgaListLevel extends KomgaLevel {
  KomgaListLevel({
    required this.title,
    required this.query,
    this.library,
    this.newSince,
  });

  final String title;

  /// Set for library lists, whose view, filter and sort are remembered.
  final KomgaLibrary? library;
  KomgaQuery query;

  /// Items created after this are marked new; null before the first visit.
  final DateTime? newSince;
  late KomgaPagedLoader<Object> loader;

  bool get isSearch => query.hasSearch;

  @override
  void dispose() => loader.dispose();
}

/// One series: its header and its books.
class KomgaSeriesLevel extends KomgaLevel {
  KomgaSeriesLevel({required this.series, required this.query});

  KomgaSeries series;
  KomgaQuery query;
  late KomgaPagedLoader<Object> loader;

  /// What "continue reading" opens, and whether that means starting over.
  KomgaBook? continueTarget;
  bool continueRestarts = false;

  @override
  void dispose() => loader.dispose();
}

class KomgaDownloadsLevel extends KomgaLevel {}

/// State and actions of the Komga browser, independent of widgets.
class KomgaBrowseController extends ChangeNotifier {
  KomgaBrowseController({required this.client}) {
    _serverChanges = komgaProgressSyncService.serverProgressChanges.listen(
      _onServerProgressChanged,
    );
  }

  static final DateTime _beforeAnyItem = DateTime.utc(1);

  final KomgaClient client;
  final List<KomgaLevel> stack = <KomgaLevel>[KomgaHomeLevel()];
  KomgaBrowsePreferences preferences = const KomgaBrowsePreferences();

  /// Local progress of every loaded book, by progress record key.
  Map<String, ReadProgressEntry> progress = const <String, ReadProgressEntry>{};
  final Map<String?, KomgaFilterOptions> _filterOptions =
      <String?, KomgaFilterOptions>{};
  bool _disposed = false;
  late final StreamSubscription<String> _serverChanges;
  final Set<String> _changedSeries = <String>{};
  Timer? _serverChangeTimer;

  KomgaLevel get current => stack.last;

  bool get canGoBack => stack.length > 1;

  KomgaHomeLevel get home => stack.first as KomgaHomeLevel;

  Future<void> start() async {
    final String? value = await localConfigService.read(
      configKey: ConfigEnum.komgaBrowseSetting,
    );
    preferences = KomgaBrowsePreferences.fromJsonString(value);
    await refreshHome();
  }

  // ---- navigation ----

  bool goBack() {
    if (stack.length <= 1) {
      return false;
    }
    stack.removeLast().dispose();
    _notify();
    if (current is KomgaHomeLevel && home.stale) {
      unawaited(refreshHome());
    }
    return true;
  }

  Future<void> refreshCurrent() {
    return switch (current) {
      KomgaHomeLevel() => refreshHome(),
      final KomgaListLevel level => level.loader.refresh(),
      final KomgaSeriesLevel level => _refreshSeries(level),
      KomgaDownloadsLevel() => Future<void>.value(),
    };
  }

  Future<void> openLibrary(KomgaLibrary library) async {
    final DateTime? newSince =
        preferences.lastSeen(client.sourceFingerprint, library.id) ??
        (preferences.hasSeenLibrary(client.sourceFingerprint, library.id)
            ? _beforeAnyItem
            : null);
    final KomgaListLevel level = KomgaListLevel(
      title: library.name,
      library: library,
      newSince: newSince,
      query: _libraryQuery(library.id),
    );
    _attachListLoader(level);
    _push(level);
    await Future.wait(<Future<void>>[
      level.loader.refresh(),
      _markLibrarySeen(library),
    ]);
  }

  Future<void> openSearch(String text) async {
    final KomgaListLevel level = KomgaListLevel(
      title: text.trim(),
      query: KomgaQuery(
        target: KomgaTarget.series,
        search: text.trim(),
        sortMode: KomgaSortMode.relevance,
      ),
    );
    _attachListLoader(level);
    _push(level);
    await level.loader.refresh();
  }

  /// Series sharing a tag, author, publisher, language or genre.
  Future<void> openFilter(String title, KomgaFilters filters) async {
    final KomgaListLevel level = KomgaListLevel(
      title: title,
      query: KomgaQuery(
        target: KomgaTarget.series,
        filters: filters,
        sortMode: KomgaSortMode.title,
        descending: false,
      ),
    );
    _attachListLoader(level);
    _push(level);
    await level.loader.refresh();
  }

  Future<void> openSeries(KomgaSeries series) async {
    final KomgaSeriesLevel level = KomgaSeriesLevel(
      series: series,
      query: KomgaQuery(
        target: KomgaTarget.books,
        seriesId: series.id,
        sortMode: preferences.seriesSortMode,
        descending: preferences.seriesDescending,
      ),
    );
    level.loader = _booksLoader(() => level.query);
    _push(level);
    await _refreshSeries(level);
  }

  Future<void> openDownloads() {
    _push(KomgaDownloadsLevel());
    return refreshProgress();
  }

  // ---- list options ----

  Future<void> setTarget(KomgaListLevel level, KomgaTarget target) {
    if (level.query.target == target) {
      return Future<void>.value();
    }
    level.query = KomgaQuery(
      target: target,
      libraryId: level.query.libraryId,
      search: level.query.search,
      progress: level.query.progress,
      filters: level.query.filters,
      sortMode: _sortFor(target, level.query.sortMode),
      descending: level.query.descending,
    );
    if (level.library != null) {
      _savePreferences(
        preferences.copyWith(
          libraryView: target == KomgaTarget.books
              ? KomgaLibraryView.books
              : KomgaLibraryView.series,
        ),
      );
    }
    return _reload(level);
  }

  Future<void> setProgressFilter(KomgaLevel level, KomgaProgressFilter filter) {
    switch (level) {
      case final KomgaListLevel list:
        list.query = list.query.copyWith(
          progress: filter,
          sortMode: filter == KomgaProgressFilter.newlyAdded
              ? KomgaSortMode.addedAt
              : null,
          descending: filter == KomgaProgressFilter.newlyAdded ? true : null,
        );
        if (list.library != null) {
          _savePreferences(
            preferences.copyWith(
              progressFilter: filter,
              sortMode: list.query.sortMode,
              descending: list.query.descending,
            ),
          );
        }
        return _reload(list);
      case final KomgaSeriesLevel series:
        series.query = series.query.copyWith(progress: filter);
        return series.loader.refresh();
      default:
        return Future<void>.value();
    }
  }

  Future<void> setSort(KomgaLevel level, KomgaSortMode mode, bool descending) {
    switch (level) {
      case final KomgaListLevel list:
        list.query = list.query.copyWith(sortMode: mode, descending: descending);
        if (list.library != null) {
          _savePreferences(
            preferences.copyWith(sortMode: mode, descending: descending),
          );
        }
        return _reload(list);
      case final KomgaSeriesLevel series:
        series.query = series.query.copyWith(
          sortMode: mode,
          descending: descending,
        );
        _savePreferences(
          preferences.copyWith(
            seriesSortMode: mode,
            seriesDescending: descending,
          ),
        );
        return series.loader.refresh();
      default:
        return Future<void>.value();
    }
  }

  Future<void> setFilters(KomgaListLevel level, KomgaFilters filters) {
    level.query = level.query.copyWith(filters: filters);
    return _reload(level);
  }

  void setDisplayMode(KomgaDisplayMode mode) {
    _savePreferences(preferences.copyWith(displayMode: mode));
    _notify();
  }

  Future<KomgaFilterOptions> filterOptions(String? libraryId) async {
    return _filterOptions[libraryId] ??= await client.getFilterOptions(
      libraryId: libraryId,
    );
  }

  // ---- reading state ----

  KomgaBookBrowseItem bookItem(KomgaBook book, {DateTime? newSince}) {
    return KomgaBookBrowseItem.fromBook(
      book: book,
      progress: progress[client.progressRecordKey(book.id)],
      newSince: newSince,
    );
  }

  /// Re-read local progress for every loaded book (after reading, cloud sync
  /// or a reconcile).
  Future<void> refreshProgress() async {
    final Set<String> keys = <String>{
      for (final KomgaBook book in _loadedBooks())
        client.progressRecordKey(book.id),
    };
    progress = await readProgressService.getReadProgressEntriesByKeys(keys);
    _notify();
  }

  Future<void> markBook(KomgaBook book, {required bool read}) async {
    await komgaProgressSyncService.markBook(client, book, read: read);
    await _afterReadingStateChange();
  }

  Future<void> markSeries(KomgaSeries series, {required bool read}) async {
    await komgaProgressSyncService.markSeries(client, series.id, read: read);
    await _afterReadingStateChange();
  }

  /// The book "continue reading" should open: the most recently read book
  /// in progress, else the first unread volume, else the first volume.
  Future<(KomgaBook?, bool restarts)> continueTarget(String seriesId) async {
    Future<KomgaBook?> first(KomgaQuery query) async =>
        (await client.listBooks(query, page: 0, size: 1)).content.firstOrNull;

    final KomgaBook? inProgress = await first(
      KomgaQuery(
        target: KomgaTarget.books,
        seriesId: seriesId,
        progress: KomgaProgressFilter.inProgress,
        sortMode: KomgaSortMode.lastReadAt,
      ),
    );
    if (inProgress != null) {
      return (inProgress, false);
    }
    final KomgaBook? unread = await first(
      KomgaQuery(
        target: KomgaTarget.books,
        seriesId: seriesId,
        progress: KomgaProgressFilter.unread,
        sortMode: KomgaSortMode.number,
        descending: false,
      ),
    );
    if (unread != null) {
      return (unread, false);
    }
    return (
      await first(
        KomgaQuery(
          target: KomgaTarget.books,
          seriesId: seriesId,
          sortMode: KomgaSortMode.number,
          descending: false,
        ),
      ),
      true,
    );
  }

  // ---- loading ----

  Future<void> refreshHome() async {
    final KomgaHomeLevel level = home;
    level.loading = true;
    level.stale = false;
    level.error = null;
    _notify();
    try {
      final List<KomgaLibrary> libraries = <KomgaLibrary>[
        ...await client.getLibraries(),
      ]..sort((KomgaLibrary a, KomgaLibrary b) => a.name.compareTo(b.name));
      final List<KomgaBook> continueReading = (await client.listBooks(
        const KomgaQuery(
          target: KomgaTarget.books,
          progress: KomgaProgressFilter.inProgress,
          sortMode: KomgaSortMode.lastReadAt,
        ),
        page: 0,
        size: 20,
      )).content;
      final List<KomgaBook> onDeck = (await client.onDeckBooks(
        size: 20,
      )).content;
      final List<KomgaSeries> newSeries = (await client.latestSeries(
        updated: false,
        size: 20,
      )).content;
      final List<KomgaSeries> updatedSeries = (await client.latestSeries(
        updated: true,
        size: 20,
      )).content;
      level
        ..libraries = libraries
        ..continueReading = continueReading
        ..onDeck = onDeck
        ..newSeries = newSeries
        ..updatedSeries = updatedSeries
        ..loaded = true;
      await _reconcile(<KomgaBook>[...continueReading, ...onDeck]);
    } catch (e) {
      level.error = e;
    } finally {
      level.loading = false;
      _notify();
    }
  }

  Future<void> _refreshSeries(KomgaSeriesLevel level) async {
    final Future<void> books = level.loader.refresh();
    await _refreshSeriesHeader(level);
    await books;
  }

  /// Server counts and the "continue reading" target, without reloading the
  /// book list (its scroll position stays).
  Future<void> _refreshSeriesHeader(KomgaSeriesLevel level) async {
    try {
      level.series = await client.getSeries(level.series.id);
      final (KomgaBook? target, bool restarts) = await continueTarget(
        level.series.id,
      );
      level
        ..continueTarget = target
        ..continueRestarts = restarts;
    } catch (e) {
      // The header falls back to the series data from the list.
      log.warning('Komga series details failed to load', e);
    }
    _notify();
  }

  /// Replace listed series whose server counts changed, in place, so a list
  /// returned to shows current counts without reloading.
  Future<void> _refreshListedSeries(
    KomgaListLevel level,
    Set<String> changed,
  ) async {
    final List<Object> items = level.loader.items;
    for (int i = 0; i < items.length; i++) {
      final Object item = items[i];
      if (item is KomgaSeries && changed.contains(item.id)) {
        try {
          items[i] = await client.getSeries(item.id);
        } catch (e) {
          log.warning('Komga series refresh failed', e);
        }
      }
    }
    _notify();
  }

  /// JHenTai changed server progress (a reader report, a mark): refresh the
  /// server-side counts shown for those series. Reports often land after the
  /// reader has closed, so this cannot rely on the return from the reader.
  void _onServerProgressChanged(String seriesId) {
    _changedSeries.add(seriesId);
    _serverChangeTimer?.cancel();
    _serverChangeTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_refreshAfterServerChange()),
    );
  }

  Future<void> _refreshAfterServerChange() async {
    final Set<String> changed = <String>{..._changedSeries};
    _changedSeries.clear();
    if (_disposed) {
      return;
    }
    for (final KomgaLevel level in List<KomgaLevel>.of(stack)) {
      if (level is KomgaSeriesLevel && changed.contains(level.series.id)) {
        await _refreshSeriesHeader(level);
      }
      if (level is KomgaListLevel) {
        await _refreshListedSeries(level, changed);
      }
    }
    if (current is KomgaHomeLevel) {
      await refreshHome();
    } else {
      home.stale = true;
    }
  }

  KomgaQuery _libraryQuery(String libraryId) {
    final KomgaTarget target =
        preferences.libraryView == KomgaLibraryView.books
        ? KomgaTarget.books
        : KomgaTarget.series;
    final bool newOnly =
        preferences.progressFilter == KomgaProgressFilter.newlyAdded;
    return KomgaQuery(
      target: target,
      libraryId: libraryId,
      progress: preferences.progressFilter,
      sortMode: newOnly
          ? KomgaSortMode.addedAt
          : _sortFor(target, preferences.sortMode),
      descending: newOnly ? true : preferences.descending,
    );
  }

  /// Series have no volume number; searches may sort by relevance only.
  static KomgaSortMode _sortFor(KomgaTarget target, KomgaSortMode mode) {
    if (target == KomgaTarget.series && mode == KomgaSortMode.number) {
      return KomgaSortMode.title;
    }
    return mode;
  }

  void _attachListLoader(KomgaListLevel level) {
    level.loader = level.query.target == KomgaTarget.series
        ? _seriesLoader(level)
        : _booksLoader(() => level.query, newSince: () => level.newSince);
  }

  Future<void> _reload(KomgaListLevel level) {
    level.loader.dispose();
    _attachListLoader(level);
    _notify();
    return level.loader.refresh();
  }

  KomgaPagedLoader<Object> _seriesLoader(KomgaListLevel level) {
    final KomgaPagedLoader<Object> loader = KomgaPagedLoader<Object>(
      fetch: (int page) async {
        final KomgaPageResult<KomgaSeries> result = await client.listSeries(
          level.query,
          page: page,
        );
        return KomgaPageResult<Object>(
          content: result.content,
          page: result.page,
          totalPages: result.totalPages,
          isLast: result.isLast,
          totalElements: result.totalElements,
        );
      },
      idOf: (Object item) => (item as KomgaSeries).id,
      stopWhen: _newOnlyStop(() => level.query, () => level.newSince),
    );
    loader.addListener(_notify);
    return loader;
  }

  KomgaPagedLoader<Object> _booksLoader(
    KomgaQuery Function() query, {
    DateTime? Function()? newSince,
  }) {
    final KomgaPagedLoader<Object> loader = KomgaPagedLoader<Object>(
      fetch: (int page) async {
        final KomgaPageResult<KomgaBook> result = await client.listBooks(
          query(),
          page: page,
        );
        return KomgaPageResult<Object>(
          content: result.content,
          page: result.page,
          totalPages: result.totalPages,
          isLast: result.isLast,
          totalElements: result.totalElements,
        );
      },
      idOf: (Object item) => (item as KomgaBook).id,
      stopWhen: newSince == null ? null : _newOnlyStop(query, newSince),
      onPageLoaded: (List<Object> items) =>
          _reconcile(items.cast<KomgaBook>()),
    );
    loader.addListener(_notify);
    return loader;
  }

  /// "Newly added" lists are sorted newest first; stop at the first item
  /// that is not newer than the last visit.
  bool Function(Object)? _newOnlyStop(
    KomgaQuery Function() query,
    DateTime? Function() newSince,
  ) {
    return (Object item) {
      if (query().progress != KomgaProgressFilter.newlyAdded) {
        return false;
      }
      final DateTime? since = newSince();
      final DateTime? created = switch (item) {
        final KomgaSeries s => s.createdDate,
        final KomgaBook b => b.createdDate,
        _ => null,
      };
      return since == null || created == null || !created.isAfter(since);
    };
  }

  Future<void> _reconcile(List<KomgaBook> books) async {
    if (books.isEmpty) {
      return;
    }
    try {
      await komgaProgressSyncService.reconcileBooks(client, books);
    } catch (e) {
      log.warning('Komga progress reconcile failed', e);
    }
    await refreshProgress();
  }

  Future<void> _afterReadingStateChange() async {
    await refreshProgress();
    for (final KomgaLevel level in stack) {
      if (level is KomgaSeriesLevel) {
        await _refreshSeries(level);
      }
    }
    if (current is KomgaHomeLevel) {
      await refreshHome();
    }
  }

  Future<void> _markLibrarySeen(KomgaLibrary library) async {
    try {
      final KomgaQuery newest = KomgaQuery(
        target: KomgaTarget.books,
        libraryId: library.id,
      );
      final DateTime? latest = (await client.listBooks(
        newest,
        page: 0,
        size: 1,
      )).content.firstOrNull?.createdDate;
      await _savePreferences(
        preferences.markLibrarySeen(
          client.sourceFingerprint,
          library.id,
          latest ?? _beforeAnyItem,
        ),
      );
    } catch (e) {
      log.warning('Komga library visit was not recorded', e);
    }
  }

  Iterable<KomgaBook> _loadedBooks() sync* {
    for (final KomgaLevel level in stack) {
      switch (level) {
        case KomgaHomeLevel():
          yield* level.continueReading;
          yield* level.onDeck;
        case KomgaListLevel():
        case KomgaSeriesLevel():
          final KomgaPagedLoader<Object> loader = level is KomgaListLevel
              ? level.loader
              : (level as KomgaSeriesLevel).loader;
          yield* loader.items.whereType<KomgaBook>();
        case KomgaDownloadsLevel():
          yield* komgaDownloadService
              .downloadedBooks(client.connectionId)
              .map((KomgaDownloadedBook d) => d.book);
      }
    }
  }

  void _push(KomgaLevel level) {
    stack.add(level);
    _notify();
  }

  Future<void> _savePreferences(KomgaBrowsePreferences next) {
    preferences = next;
    return localConfigService.write(
      configKey: ConfigEnum.komgaBrowseSetting,
      value: next.toJsonString(),
    );
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _serverChangeTimer?.cancel();
    unawaited(_serverChanges.cancel());
    for (final KomgaLevel level in stack) {
      level.dispose();
    }
    super.dispose();
  }
}
