import 'package:jhentai/src/model/komga/komga_browse_models.dart';

enum KomgaTarget { series, books }

/// Value filters chosen in the filter panel. Values within one category are
/// alternatives (any of); categories combine (all of).
class KomgaFilters {
  const KomgaFilters({
    this.authors = const <String>{},
    this.publishers = const <String>{},
    this.languages = const <String>{},
    this.tags = const <String>{},
    this.genres = const <String>{},
  });

  final Set<String> authors;
  final Set<String> publishers;
  final Set<String> languages;
  final Set<String> tags;
  final Set<String> genres;

  bool get isEmpty =>
      authors.isEmpty &&
      publishers.isEmpty &&
      languages.isEmpty &&
      tags.isEmpty &&
      genres.isEmpty;

  int get count =>
      authors.length +
      publishers.length +
      languages.length +
      tags.length +
      genres.length;

  KomgaFilters copyWith({
    Set<String>? authors,
    Set<String>? publishers,
    Set<String>? languages,
    Set<String>? tags,
    Set<String>? genres,
  }) {
    return KomgaFilters(
      authors: authors ?? this.authors,
      publishers: publishers ?? this.publishers,
      languages: languages ?? this.languages,
      tags: tags ?? this.tags,
      genres: genres ?? this.genres,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is KomgaFilters &&
      _sameSet(authors, other.authors) &&
      _sameSet(publishers, other.publishers) &&
      _sameSet(languages, other.languages) &&
      _sameSet(tags, other.tags) &&
      _sameSet(genres, other.genres);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(authors),
    Object.hashAllUnordered(publishers),
    Object.hashAllUnordered(languages),
    Object.hashAllUnordered(tags),
    Object.hashAllUnordered(genres),
  );

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}

/// One list request against `POST /api/v1/{series,books}/list`.
class KomgaQuery {
  const KomgaQuery({
    required this.target,
    this.libraryId,
    this.seriesId,
    this.search = '',
    this.progress = KomgaProgressFilter.all,
    this.filters = const KomgaFilters(),
    this.sortMode = KomgaSortMode.addedAt,
    this.descending = true,
  });

  final KomgaTarget target;
  final String? libraryId;

  /// Books of one series (books target only).
  final String? seriesId;
  final String search;
  final KomgaProgressFilter progress;
  final KomgaFilters filters;
  final KomgaSortMode sortMode;
  final bool descending;

  bool get hasSearch => search.trim().isNotEmpty;

  KomgaQuery copyWith({
    String? search,
    KomgaProgressFilter? progress,
    KomgaFilters? filters,
    KomgaSortMode? sortMode,
    bool? descending,
  }) {
    return KomgaQuery(
      target: target,
      libraryId: libraryId,
      seriesId: seriesId,
      search: search ?? this.search,
      progress: progress ?? this.progress,
      filters: filters ?? this.filters,
      sortMode: sortMode ?? this.sortMode,
      descending: descending ?? this.descending,
    );
  }

  /// Request body. Conditions are always combined with `allOf` and always
  /// exclude books and series that Komga keeps in its trash.
  Map<String, dynamic> toRequestBody() {
    final List<Map<String, dynamic>> conditions = <Map<String, dynamic>>[
      <String, dynamic>{
        'deleted': <String, dynamic>{'operator': 'isFalse'},
      },
      if (libraryId != null) _is('libraryId', libraryId!),
      if (seriesId != null && target == KomgaTarget.books)
        _is('seriesId', seriesId!),
      if (_readStatus != null) _is('readStatus', _readStatus!),
      if (filters.authors.isNotEmpty)
        _anyOf(
          filters.authors.map(
            (String name) => _is('author', <String, dynamic>{'name': name}),
          ),
        ),
      if (filters.tags.isNotEmpty)
        _anyOf(filters.tags.map((String tag) => _is('tag', tag))),
      if (target == KomgaTarget.series && filters.publishers.isNotEmpty)
        _anyOf(filters.publishers.map((String p) => _is('publisher', p))),
      if (target == KomgaTarget.series && filters.languages.isNotEmpty)
        _anyOf(filters.languages.map((String l) => _is('language', l))),
      if (target == KomgaTarget.series && filters.genres.isNotEmpty)
        _anyOf(filters.genres.map((String g) => _is('genre', g))),
    ];
    return <String, dynamic>{
      'condition': <String, dynamic>{'allOf': conditions},
      if (hasSearch) 'fullTextSearch': search.trim(),
    };
  }

  /// `sort` query parameters. Searching without an explicit sort lets Komga
  /// order by relevance. A secondary key narrows ties for offset paging.
  List<String> toSortParams() {
    if (sortMode == KomgaSortMode.relevance) {
      return const <String>[];
    }
    final String direction = descending ? 'desc' : 'asc';
    final String primary = switch ((target, sortMode)) {
      (KomgaTarget.series, KomgaSortMode.addedAt) => 'createdDate',
      (KomgaTarget.series, KomgaSortMode.lastReadAt) => 'readDate',
      (KomgaTarget.series, KomgaSortMode.title) => 'metadata.titleSort',
      (KomgaTarget.series, _) => 'metadata.titleSort',
      (KomgaTarget.books, KomgaSortMode.addedAt) => 'createdDate',
      (KomgaTarget.books, KomgaSortMode.lastReadAt) => 'readProgress.readDate',
      (KomgaTarget.books, KomgaSortMode.title) => 'metadata.title',
      (KomgaTarget.books, _) => 'metadata.numberSort',
    };
    final String secondary = target == KomgaTarget.series
        ? 'metadata.titleSort'
        : 'metadata.numberSort';
    return <String>[
      '$primary,$direction',
      if (secondary != primary) '$secondary,asc',
    ];
  }

  String? get _readStatus => switch (progress) {
    KomgaProgressFilter.unread => 'UNREAD',
    KomgaProgressFilter.inProgress => 'IN_PROGRESS',
    KomgaProgressFilter.read => 'READ',
    _ => null,
  };

  static Map<String, dynamic> _is(String field, Object value) =>
      <String, dynamic>{
        field: <String, dynamic>{'operator': 'is', 'value': value},
      };

  static Map<String, dynamic> _anyOf(Iterable<Map<String, dynamic>> items) =>
      <String, dynamic>{'anyOf': items.toList()};
}

/// Values the server has for each filter category. Categories without values
/// are not offered.
class KomgaFilterOptions {
  const KomgaFilterOptions({
    this.authors = const <String>[],
    this.publishers = const <String>[],
    this.languages = const <String>[],
    this.tags = const <String>[],
    this.genres = const <String>[],
  });

  final List<String> authors;
  final List<String> publishers;
  final List<String> languages;
  final List<String> tags;
  final List<String> genres;
}
