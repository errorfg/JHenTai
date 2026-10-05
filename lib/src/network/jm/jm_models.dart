/// Parsed JM mobile API responses. The API mixes strings and numbers for
/// the same fields, so every field goes through [_int] / [_str].
int _int(dynamic value, [int fallback = 0]) =>
    value is int ? value : int.tryParse('${value ?? ''}') ?? fallback;

String _str(dynamic value) => value == null ? '' : '$value';

List<String> _strings(dynamic value) => value is List
    ? value.map(_str).where((String s) => s.isNotEmpty).toList()
    : value is String && value.trim().isNotEmpty
    ? value.trim().split(RegExp(r'\s+'))
    : const <String>[];

/// An album in a search or browse list.
class JmAlbumSummary {
  const JmAlbumSummary({
    required this.id,
    required this.name,
    required this.author,
    required this.categoryTitle,
    required this.subCategoryTitle,
    required this.addDate,
    required this.updateAt,
  });

  factory JmAlbumSummary.fromJson(Map<String, dynamic> json) => JmAlbumSummary(
    id: _int(json['id']),
    name: _str(json['name']),
    author: _str(json['author']),
    categoryTitle: _str((json['category'] as Map?)?['title']),
    subCategoryTitle: _str((json['category_sub'] as Map?)?['title']),
    addDate: _str(json['adddate']),
    updateAt: _int(json['update_at']) > 0
        ? DateTime.fromMillisecondsSinceEpoch(
            _int(json['update_at']) * 1000,
            isUtc: true,
          )
        : null,
  );

  final int id;
  final String name;
  final String author;
  final String categoryTitle;
  final String subCategoryTitle;

  /// `yyyy-MM-dd`, empty when the list does not carry it.
  final String addDate;

  /// Last update, when the list carries it.
  final DateTime? updateAt;
}

class JmSearchResult {
  const JmSearchResult({
    required this.total,
    required this.albums,
    this.redirectAlbumId,
  });

  factory JmSearchResult.fromJson(Map<String, dynamic> json) => JmSearchResult(
    total: _int(json['total']),
    albums: (json['content'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((Map m) => JmAlbumSummary.fromJson(m.cast<String, dynamic>()))
        .toList(),
    redirectAlbumId: json['redirect_aid'] == null
        ? null
        : _int(json['redirect_aid']),
  );

  final int total;
  final List<JmAlbumSummary> albums;

  /// Set when the query was an album number: the server answers with the
  /// album id instead of a list.
  final int? redirectAlbumId;
}

class JmChapterRef {
  const JmChapterRef({required this.id, required this.name, required this.sort});

  factory JmChapterRef.fromJson(Map<String, dynamic> json) => JmChapterRef(
    id: _int(json['id']),
    name: _str(json['name']),
    sort: _int(json['sort'], 1),
  );

  final int id;
  final String name;
  final int sort;
}

class JmAlbum {
  const JmAlbum({
    required this.id,
    required this.name,
    required this.authors,
    required this.description,
    required this.tags,
    required this.works,
    required this.actors,
    required this.chapters,
    required this.totalPhotos,
    required this.addTime,
    required this.views,
    required this.likes,
    required this.commentCount,
    required this.related,
  });

  factory JmAlbum.fromJson(Map<String, dynamic> json) {
    final int id = _int(json['id']);
    final List<JmChapterRef> chapters =
        (json['series'] as List? ?? const <dynamic>[])
            .whereType<Map>()
            .map((Map m) => JmChapterRef.fromJson(m.cast<String, dynamic>()))
            .toList()
          ..sort((JmChapterRef a, JmChapterRef b) => a.sort.compareTo(b.sort));
    return JmAlbum(
      id: id,
      name: _str(json['name']),
      authors: _strings(json['author']),
      description: _str(json['description']),
      tags: _strings(json['tags']),
      works: _strings(json['works']),
      actors: _strings(json['actors']),
      // A single-chapter album has no series; its only chapter shares the
      // album id.
      chapters: chapters.isEmpty
          ? <JmChapterRef>[JmChapterRef(id: id, name: '', sort: 1)]
          : chapters,
      totalPhotos: _int(json['total_photos']),
      addTime: DateTime.fromMillisecondsSinceEpoch(
        _int(json['addtime']) * 1000,
        isUtc: true,
      ),
      views: _int(json['total_views']),
      likes: _int(json['likes']),
      commentCount: _int(json['comment_total']),
      related: (json['related_list'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map((Map m) => JmAlbumSummary.fromJson(m.cast<String, dynamic>()))
          .toList(),
    );
  }

  final int id;
  final String name;
  final List<String> authors;
  final String description;
  final List<String> tags;
  final List<String> works;
  final List<String> actors;

  /// In reading order; never empty.
  final List<JmChapterRef> chapters;

  /// Pages of all chapters together.
  final int totalPhotos;
  final DateTime addTime;
  final int views;
  final int likes;
  final int commentCount;

  /// Albums the server recommends alongside this one.
  final List<JmAlbumSummary> related;
}

class JmChapter {
  const JmChapter({
    required this.id,
    required this.albumId,
    required this.name,
    required this.images,
  });

  factory JmChapter.fromJson(Map<String, dynamic> json) {
    final int id = _int(json['id']);
    final int seriesId = _int(json['series_id']);
    return JmChapter(
      id: id,
      // series_id is "0" for a single-chapter album.
      albumId: seriesId > 0 ? seriesId : id,
      name: _str(json['name']),
      images: _strings(json['images']),
    );
  }

  final int id;
  final int albumId;
  final String name;

  /// Page file names in order, e.g. `00001.webp`.
  final List<String> images;
}

class JmComment {
  const JmComment({
    required this.id,
    required this.nickname,
    required this.content,
    required this.time,
    required this.likes,
  });

  factory JmComment.fromJson(Map<String, dynamic> json) => JmComment(
    id: _int(json['CID']),
    nickname: _str(json['nickname']).isNotEmpty
        ? _str(json['nickname'])
        : _str(json['username']),
    content: _str(json['content']),
    time: _str(json['addtime']),
    likes: _int(json['likes']),
  );

  final int id;
  final String nickname;

  /// HTML.
  final String content;

  /// As sent by the server, e.g. `Oct 05, 2026`.
  final String time;
  final int likes;
}

/// A logged-in JM account.
class JmUser {
  const JmUser({required this.id, required this.username});

  factory JmUser.fromJson(Map<String, dynamic> json) =>
      JmUser(id: _int(json['uid']), username: _str(json['username']));

  final int id;
  final String username;
}

/// The JM API answered with an error.
class JmApiException implements Exception {
  const JmApiException(this.message);

  final String message;

  @override
  String toString() => 'JmApiException: $message';
}
