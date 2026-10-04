class KomgaLibrary {
  const KomgaLibrary({required this.id, required this.name});

  final String id;
  final String name;

  factory KomgaLibrary.fromJson(Map<String, dynamic> json) {
    return KomgaLibrary(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
    );
  }
}

class KomgaAuthor {
  const KomgaAuthor({required this.name, required this.role});

  final String name;
  final String role;

  factory KomgaAuthor.fromJson(Map<String, dynamic> json) {
    return KomgaAuthor(
      name: json['name'] as String? ?? '',
      role: json['role'] as String? ?? '',
    );
  }
}

class KomgaReadProgress {
  const KomgaReadProgress({
    required this.page,
    required this.completed,
    required this.readDate,
    required this.createdDate,
    required this.lastModifiedDate,
    required this.deviceId,
    required this.deviceName,
  });

  final int page;
  final bool completed;
  final DateTime? readDate;
  final DateTime? createdDate;
  final DateTime? lastModifiedDate;
  final String deviceId;
  final String deviceName;

  factory KomgaReadProgress.fromJson(Map<String, dynamic> json) {
    return KomgaReadProgress(
      page: (json['page'] as num?)?.toInt() ?? 0,
      completed: json['completed'] as bool? ?? false,
      readDate: _parseKomgaDate(json['readDate']),
      createdDate: _parseKomgaDate(json['created'] ?? json['createdDate']),
      lastModifiedDate: _parseKomgaDate(
        json['lastModified'] ?? json['lastModifiedDate'],
      ),
      deviceId: json['deviceId'] as String? ?? '',
      deviceName: json['deviceName'] as String? ?? '',
    );
  }
}

class KomgaSeries {
  const KomgaSeries({
    required this.id,
    required this.libraryId,
    required this.name,
    required this.title,
    required this.booksCount,
    required this.createdDate,
    required this.lastModifiedDate,
    required this.summary,
    required this.tags,
    required this.authors,
    this.booksReadCount = 0,
    this.booksUnreadCount = 0,
    this.booksInProgressCount = 0,
    this.status = '',
    this.publisher = '',
    this.language = '',
    this.genres = const <String>[],
    this.readingDirection = '',
    this.ageRating,
    this.releaseDate,
  });

  final String id;
  final String libraryId;
  final String name;
  final String title;
  final int booksCount;
  final DateTime? createdDate;
  final DateTime? lastModifiedDate;
  final String summary;

  /// Series tags together with the tags of its books, matching how Komga's
  /// tag condition selects series.
  final List<String> tags;
  final List<KomgaAuthor> authors;
  final int booksReadCount;
  final int booksUnreadCount;
  final int booksInProgressCount;
  final String status;
  final String publisher;
  final String language;
  final List<String> genres;

  /// LEFT_TO_RIGHT, RIGHT_TO_LEFT, VERTICAL, WEBTOON, or empty when unset.
  final String readingDirection;
  final int? ageRating;
  final DateTime? releaseDate;

  factory KomgaSeries.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> metadata =
        (json['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};
    final Map<String, dynamic> booksMetadata =
        (json['booksMetadata'] as Map?)?.cast<String, dynamic>() ?? const {};
    final String metadataTitle = metadata['title'] as String? ?? '';
    final String name = json['name'] as String? ?? '';

    final String summary = metadata['summary'] as String? ?? '';
    return KomgaSeries(
      id: json['id'] as String,
      libraryId: json['libraryId'] as String? ?? '',
      name: name,
      title: metadataTitle.trim().isEmpty ? name : metadataTitle,
      booksCount: (json['booksCount'] as num?)?.toInt() ?? 0,
      createdDate: _parseKomgaDate(json['created'] ?? json['createdDate']),
      lastModifiedDate: _parseKomgaDate(
        json['lastModified'] ?? json['lastModifiedDate'],
      ),
      summary: summary.trim().isEmpty
          ? booksMetadata['summary'] as String? ?? ''
          : summary,
      tags: <String>{
        ..._parseStringList(metadata['tags']),
        ..._parseStringList(booksMetadata['tags']),
      }.toList(growable: false),
      authors: _parseAuthors(booksMetadata['authors']),
      booksReadCount: (json['booksReadCount'] as num?)?.toInt() ?? 0,
      booksUnreadCount: (json['booksUnreadCount'] as num?)?.toInt() ?? 0,
      booksInProgressCount:
          (json['booksInProgressCount'] as num?)?.toInt() ?? 0,
      status: metadata['status'] as String? ?? '',
      publisher: metadata['publisher'] as String? ?? '',
      language: metadata['language'] as String? ?? '',
      genres: _parseStringList(metadata['genres']),
      readingDirection: metadata['readingDirection'] as String? ?? '',
      ageRating: (metadata['ageRating'] as num?)?.toInt(),
      releaseDate: _parseKomgaDate(booksMetadata['releaseDate']),
    );
  }
}

class KomgaBook {
  const KomgaBook({
    required this.id,
    required this.seriesId,
    required this.seriesTitle,
    required this.name,
    required this.title,
    required this.number,
    required this.pageCount,
    required this.mediaStatus,
    required this.mediaType,
    required this.mediaProfile,
    required this.mediaComment,
    required this.size,
    required this.sizeBytes,
    required this.createdDate,
    required this.lastModifiedDate,
    required this.summary,
    required this.tags,
    required this.authors,
    this.readProgress,
    this.numberSort = 0,
    this.epubDivinaCompatible = false,
  });

  final String id;
  final String seriesId;
  final String seriesTitle;
  final String name;
  final String title;
  final String number;
  final int pageCount;
  final String mediaStatus;
  final String mediaType;
  final String mediaProfile;
  final String mediaComment;
  final String size;
  final int sizeBytes;
  final DateTime? createdDate;
  final DateTime? lastModifiedDate;
  final String summary;
  final List<String> tags;
  final List<KomgaAuthor> authors;
  final KomgaReadProgress? readProgress;
  final double numberSort;

  /// Only image EPUBs expose pages; text EPUBs report a computed page count
  /// but an empty page list.
  final bool epubDivinaCompatible;

  bool get isTextEpub => mediaProfile == 'EPUB' && !epubDivinaCompatible;

  bool get isReadable =>
      mediaStatus == 'READY' && pageCount > 0 && !isTextEpub;

  factory KomgaBook.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> metadata =
        (json['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};
    final Map<String, dynamic> media =
        (json['media'] as Map?)?.cast<String, dynamic>() ?? const {};
    final Map<String, dynamic>? readProgress = (json['readProgress'] as Map?)
        ?.cast<String, dynamic>();
    final String metadataTitle = metadata['title'] as String? ?? '';
    final String name = json['name'] as String? ?? '';

    return KomgaBook(
      id: json['id'] as String,
      seriesId: json['seriesId'] as String? ?? '',
      seriesTitle: json['seriesTitle'] as String? ?? '',
      name: name,
      title: metadataTitle.trim().isEmpty ? name : metadataTitle,
      number: metadata['number'] as String? ?? '',
      pageCount: (media['pagesCount'] as num?)?.toInt() ?? 0,
      mediaStatus: media['status'] as String? ?? 'UNKNOWN',
      mediaType: media['mediaType'] as String? ?? '',
      mediaProfile: media['mediaProfile'] as String? ?? '',
      mediaComment: media['comment'] as String? ?? '',
      size: json['size'] as String? ?? '',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      createdDate: _parseKomgaDate(json['created'] ?? json['createdDate']),
      lastModifiedDate: _parseKomgaDate(
        json['lastModified'] ?? json['lastModifiedDate'],
      ),
      summary: metadata['summary'] as String? ?? '',
      tags: _parseStringList(metadata['tags']),
      authors: _parseAuthors(metadata['authors']),
      readProgress: readProgress == null
          ? null
          : KomgaReadProgress.fromJson(readProgress),
      numberSort: (metadata['numberSort'] as num?)?.toDouble() ?? 0,
      epubDivinaCompatible: media['epubDivinaCompatible'] as bool? ?? false,
    );
  }
}

class KomgaBookPage {
  const KomgaBookPage({
    required this.number,
    this.width,
    this.height,
    required this.mediaType,
    this.fileName = '',
  });

  final int number;
  final int? width;
  final int? height;
  final String mediaType;

  /// Path of the page inside the book file (CBZ entry or EPUB image path).
  final String fileName;

  factory KomgaBookPage.fromJson(Map<String, dynamic> json) {
    return KomgaBookPage(
      number: (json['number'] as num?)?.toInt() ?? 0,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      mediaType: json['mediaType'] as String? ?? '',
      fileName: json['fileName'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'number': number,
    'width': width,
    'height': height,
    'mediaType': mediaType,
    'fileName': fileName,
  };
}

class KomgaPageResult<T> {
  const KomgaPageResult({
    required this.content,
    required this.page,
    required this.totalPages,
    required this.isLast,
    this.totalElements = 0,
  });

  final List<T> content;
  final int page;
  final int totalPages;
  final bool isLast;
  final int totalElements;

  factory KomgaPageResult.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) converter,
  ) {
    final List<dynamic> rawContent =
        json['content'] as List<dynamic>? ?? const [];
    final int page = (json['number'] as num?)?.toInt() ?? 0;
    final int totalPages = (json['totalPages'] as num?)?.toInt() ?? 1;
    return KomgaPageResult<T>(
      content: rawContent
          .map(
            (dynamic item) => converter((item as Map).cast<String, dynamic>()),
          )
          .toList(),
      page: page,
      totalPages: totalPages,
      isLast: json['last'] as bool? ?? page + 1 >= totalPages,
      totalElements: (json['totalElements'] as num?)?.toInt() ?? 0,
    );
  }
}

DateTime? _parseKomgaDate(dynamic value) {
  return value is String ? DateTime.tryParse(value) : null;
}

List<String> _parseStringList(dynamic value) {
  return (value as List<dynamic>? ?? const <dynamic>[])
      .whereType<String>()
      .toList(growable: false);
}

List<KomgaAuthor> _parseAuthors(dynamic value) {
  return (value as List<dynamic>? ?? const <dynamic>[])
      .whereType<Map>()
      .map((Map item) => KomgaAuthor.fromJson(item.cast<String, dynamic>()))
      .toList(growable: false);
}
