/// What the extension host (`ext_host/`) sends and takes, as Dart objects.
/// Source ids are kept as strings: they are 64-bit and arrive as JSON text.
library;

class TachiSourceInfo {
  const TachiSourceInfo({
    required this.id,
    required this.name,
    required this.lang,
    required this.baseUrl,
    required this.supportsLatest,
    required this.configurable,
  });

  final String id;
  final String name;
  final String lang;
  final String? baseUrl;
  final bool supportsLatest;
  final bool configurable;

  factory TachiSourceInfo.fromJson(Map<String, dynamic> json) => TachiSourceInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        lang: json['lang'] as String? ?? '',
        baseUrl: json['baseUrl'] as String?,
        supportsLatest: json['supportsLatest'] as bool? ?? false,
        configurable: json['configurable'] as bool? ?? false,
      );
}

class TachiExtension {
  const TachiExtension({
    required this.pkg,
    required this.name,
    required this.versionName,
    required this.versionCode,
    required this.libVersion,
    required this.nsfw,
    required this.sources,
  });

  final String pkg;
  final String name;
  final String versionName;
  final int versionCode;
  final String libVersion;
  final bool nsfw;
  final List<TachiSourceInfo> sources;

  /// The language shown for the extension: its sources' if they share one.
  String get lang {
    final Set<String> langs = sources.map((TachiSourceInfo s) => s.lang).toSet();
    return langs.length == 1 ? langs.single : 'all';
  }

  factory TachiExtension.fromJson(Map<String, dynamic> json) => TachiExtension(
        pkg: json['pkg'] as String,
        name: json['name'] as String,
        versionName: json['versionName'] as String,
        versionCode: (json['versionCode'] as num).toInt(),
        libVersion: json['libVersion'] as String,
        nsfw: json['nsfw'] as bool? ?? false,
        sources: (json['sources'] as List).map((dynamic s) => TachiSourceInfo.fromJson(s as Map<String, dynamic>)).toList(),
      );
}

/// An extension listed in a repository's `index.min.json`.
class TachiRepoExtension {
  const TachiRepoExtension({
    required this.repo,
    required this.name,
    required this.pkg,
    required this.apk,
    required this.lang,
    required this.versionCode,
    required this.versionName,
    required this.nsfw,
    required this.sources,
  });

  /// The index URL this entry came from.
  final String repo;
  final String name;
  final String pkg;
  final String apk;
  final String lang;
  final int versionCode;
  final String versionName;
  final bool nsfw;
  final List<TachiSourceInfo> sources;

  /// Repositories keep APKs in `apk/` and icons in `icon/`, next to the index.
  String get _base => repo.substring(0, repo.lastIndexOf('/'));

  String get apkUrl => '$_base/apk/$apk';

  String get iconUrl => '$_base/icon/$pkg.png';

  String get displayName => name.replaceFirst(RegExp(r'^Tachiyomi:\s*'), '');

  factory TachiRepoExtension.fromJson(String repo, Map<String, dynamic> json) => TachiRepoExtension(
        repo: repo,
        name: json['name'] as String,
        pkg: json['pkg'] as String,
        apk: json['apk'] as String,
        lang: json['lang'] as String? ?? '',
        versionCode: (json['code'] as num).toInt(),
        versionName: json['version'] as String? ?? '',
        nsfw: (json['nsfw'] as num?) == 1,
        sources: ((json['sources'] as List?) ?? const <dynamic>[])
            .map(
              (dynamic s) => TachiSourceInfo(
                id: (s as Map<String, dynamic>)['id'].toString(),
                name: s['name'] as String? ?? '',
                lang: s['lang'] as String? ?? '',
                baseUrl: s['baseUrl'] as String?,
                supportsLatest: false,
                configurable: false,
              ),
            )
            .toList(),
      );
}

/// Publication status, as Tachiyomi numbers it.
enum TachiMangaStatus { unknown, ongoing, completed, licensed, publishingFinished, cancelled, onHiatus }

class TachiManga {
  TachiManga({
    required this.url,
    required this.title,
    this.thumbnailUrl,
    this.artist,
    this.author,
    this.description,
    this.genre,
    this.status = 0,
    this.initialized = false,
  });

  final String url;
  final String title;
  final String? thumbnailUrl;
  final String? artist;
  final String? author;
  final String? description;
  final String? genre;
  final int status;
  final bool initialized;

  List<String> get genres => (genre ?? '').split(',').map((String g) => g.trim()).where((String g) => g.isNotEmpty).toSet().toList();

  TachiMangaStatus get statusValue => status >= 0 && status < TachiMangaStatus.values.length ? TachiMangaStatus.values[status] : TachiMangaStatus.unknown;

  factory TachiManga.fromJson(Map<String, dynamic> json) => TachiManga(
        url: json['url'] as String? ?? '',
        title: json['title'] as String? ?? '',
        thumbnailUrl: json['thumbnailUrl'] as String?,
        artist: json['artist'] as String?,
        author: json['author'] as String?,
        description: json['description'] as String?,
        genre: json['genre'] as String?,
        status: (json['status'] as num?)?.toInt() ?? 0,
        initialized: json['initialized'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'title': title,
        'thumbnailUrl': thumbnailUrl,
        'artist': artist,
        'author': author,
        'description': description,
        'genre': genre,
        'status': status,
        'initialized': initialized,
      };
}

class TachiMangasPage {
  const TachiMangasPage(this.mangas, this.hasNextPage);

  final List<TachiManga> mangas;
  final bool hasNextPage;
}

class TachiChapter {
  const TachiChapter({
    required this.url,
    required this.name,
    this.dateUpload = 0,
    this.chapterNumber = -1,
    this.scanlator,
  });

  final String url;
  final String name;

  /// Milliseconds since the epoch; 0 when the source does not say.
  final int dateUpload;
  final double chapterNumber;
  final String? scanlator;

  factory TachiChapter.fromJson(Map<String, dynamic> json) => TachiChapter(
        url: json['url'] as String? ?? '',
        name: json['name'] as String? ?? '',
        dateUpload: (json['dateUpload'] as num?)?.toInt() ?? 0,
        chapterNumber: (json['chapterNumber'] as num?)?.toDouble() ?? -1,
        scanlator: json['scanlator'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'name': name,
        'dateUpload': dateUpload,
        'chapterNumber': chapterNumber,
        'scanlator': scanlator,
      };
}

class TachiPage {
  const TachiPage({required this.index, required this.url, this.imageUrl});

  final int index;

  /// The page's own URL, for sources that find the image URL in a second step.
  final String url;
  final String? imageUrl;

  factory TachiPage.fromJson(Map<String, dynamic> json) => TachiPage(
        index: (json['index'] as num?)?.toInt() ?? 0,
        url: json['url'] as String? ?? '',
        imageUrl: json['imageUrl'] as String?,
      );
}

/// One filter of a source, as JSON the app edits in place and sends back
/// with a search. [type] is one of header, separator, select, text,
/// checkbox, tristate, group, sort.
class TachiFilter {
  TachiFilter(this.json);

  final Map<String, dynamic> json;

  String get type => json['type'] as String? ?? 'unknown';

  String get name => json['name'] as String? ?? '';

  List<String> get values => ((json['values'] as List?) ?? const <dynamic>[]).map((dynamic v) => v.toString()).toList();

  dynamic get state => json['state'];

  set state(dynamic value) => json['state'] = value;

  /// The filters of a group.
  List<TachiFilter> get children => type == 'group' ? ((json['state'] as List?) ?? const <dynamic>[]).map((dynamic f) => TachiFilter(f as Map<String, dynamic>)).toList() : const <TachiFilter>[];

  static List<TachiFilter> listFromJson(List<dynamic> json) => json.map((dynamic f) => TachiFilter(Map<String, dynamic>.from(f as Map))).toList();

  static List<dynamic> listToJson(List<TachiFilter> filters) => filters.map((TachiFilter f) => f.json).toList();
}

/// One setting of a source. [type]: category, list, multiSelect, text,
/// switch, info.
class TachiPreference {
  const TachiPreference(this.json);

  final Map<String, dynamic> json;

  String get type => json['type'] as String? ?? 'info';

  String? get key => json['key'] as String?;

  String get title => json['title'] as String? ?? '';

  String? get summary => json['summary'] as String?;

  bool get visible => json['visible'] as bool? ?? true;

  bool get enabled => json['enabled'] as bool? ?? true;

  String? get dialogTitle => json['dialogTitle'] as String?;

  String? get dialogMessage => json['dialogMessage'] as String?;

  List<String> get entries => ((json['entries'] as List?) ?? const <dynamic>[]).cast<String>();

  List<String> get entryValues => ((json['entryValues'] as List?) ?? const <dynamic>[]).cast<String>();

  dynamic get value => json['value'];
}

class TachiHostException implements Exception {
  const TachiHostException(this.message, {this.kind, this.httpCode});

  final String message;

  /// http (the site answered with an error), extension, request, source,
  /// unsupported (the extension needs something the host lacks).
  final String? kind;
  final int? httpCode;

  @override
  String toString() => message;
}
