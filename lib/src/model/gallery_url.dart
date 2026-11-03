import 'dart:convert';

import 'package:jhentai/src/exception/internal_exception.dart';
import 'package:jhentai/src/model/content_source.dart';
import 'package:jhentai/src/setting/eh_setting.dart';

class GalleryUrl {
  final bool isEH;
  final bool isNH;
  final bool isWN;
  final bool isJM;

  /// A Tachiyomi manga or chapter, see [GalleryUrl.tachiManga].
  final bool isTachi;
  final String? sourceHost;

  /// Tachiyomi source id, and the source's own URLs of the manga and, for a
  /// chapter, of the chapter.
  final String? tachiSource;
  final String? tachiMangaPath;
  final String? tachiChapterPath;

  final int gid;

  final String token;

  const GalleryUrl({
    required this.isEH,
    required this.gid,
    required this.token,
    this.isNH = false,
    this.isWN = false,
    this.isJM = false,
    this.isTachi = false,
    this.sourceHost,
    this.tachiSource,
    this.tachiMangaPath,
    this.tachiChapterPath,
  }) : assert(isWN || isNH || isJM || isTachi || token.length == 10);

  /// JM ids share their range with E-Hentai gids; tables keyed by gid
  /// (downloads, history) would mix them up, so JM gids are shifted.
  static const int jmGidOffset = 9000000000;

  /// A JM chapter; an album's first chapter has the album's id.
  factory GalleryUrl.jm(int chapterId) => GalleryUrl(
        isEH: true,
        isJM: true,
        gid: jmGidOffset + chapterId,
        token: 'jmcomic',
      );

  int get jmChapterId => gid - jmGidOffset;

  /// Tachiyomi gids: a hash of the source and the source's URL, in
  /// [tachiGidOffset, 2 * tachiGidOffset). Above JM's range, and below 2^53
  /// so that JavaScript (the sync server) reads them exactly.
  static const int tachiGidOffset = 1000000000000000;

  /// A Tachiyomi manga, as the history and favorites keep it.
  factory GalleryUrl.tachiManga(String source, String mangaPath) => GalleryUrl(
        isEH: true,
        isTachi: true,
        gid: tachiGid('m', source, mangaPath),
        token: 'tachiyomi',
        tachiSource: source,
        tachiMangaPath: mangaPath,
      );

  /// A chapter of a Tachiyomi manga; read progress and downloads are kept
  /// per chapter.
  factory GalleryUrl.tachiChapter(String source, String mangaPath, String chapterPath) => GalleryUrl(
        isEH: true,
        isTachi: true,
        gid: tachiGid('c', source, chapterPath),
        token: 'tachiyomi',
        tachiSource: source,
        tachiMangaPath: mangaPath,
        tachiChapterPath: chapterPath,
      );

  bool get isTachiChapter => isTachi && tachiChapterPath != null;

  /// The site the gallery is from. [isEH] tells E-Hentai from ExHentai for
  /// an E-Hentai gallery only; galleries of the other sites set it as well.
  ContentSource get source => isTachi
      ? ContentSource(SourceKind.tachiyomi, tachiSource)
      : isJM
          ? ContentSource.jm
          : isWN
              ? ContentSource.wnacg
              : isNH
                  ? ContentSource.nhentai
                  : ContentSource.ehentai;

  /// A gallery of E-Hentai or ExHentai.
  bool get isEHGallery => source.kind == SourceKind.ehentai;

  /// The gallery's key in data kept by key (read progress, double pages,
  /// block rules, synced history): the site's key and number for E-Hentai,
  /// nhentai and wnacg, whose numbers overlap ('nh:123'); the gid of a JM
  /// or Tachiyomi gallery, which is unique already.
  String get contentKey => switch (source.kind) {
        SourceKind.ehentai || SourceKind.nhentai || SourceKind.wnacg => '${source.kind.key}:$gid',
        SourceKind.jm || SourceKind.tachiyomi => '$gid',
      };

  /// What versions up to 8.1.1 kept such data under: the bare number, which
  /// any of E-Hentai, nhentai and wnacg may have had; null where that is
  /// [contentKey].
  String? get legacyKey => contentKey == '$gid' ? null : '$gid';

  /// nhentai and wnacg galleries in tables keyed by number: in ranges of
  /// their own, above E-Hentai's gids and below JM's.
  static const int nhStorageOffset = 7000000000;
  static const int wnStorageOffset = 8000000000;

  /// The gallery's number in tables keyed by number (history): its gid,
  /// but for nhentai and wnacg galleries, in the ranges above, so that a
  /// number of two sites is two rows. Up to 8.1.1 their rows had the bare
  /// number.
  int get storageGid => switch (source.kind) {
        SourceKind.nhentai => nhStorageOffset + gid,
        SourceKind.wnacg => wnStorageOffset + gid,
        SourceKind.ehentai || SourceKind.jm || SourceKind.tachiyomi => gid,
      };

  /// The site's own number of the gallery kept under [storageGid]: what
  /// folders of downloads are named by, as up to 8.1.1.
  static int siteNumberOf(int storageGid) => storageGid >= nhStorageOffset && storageGid < wnStorageOffset
      ? storageGid - nhStorageOffset
      : storageGid >= wnStorageOffset && storageGid < jmGidOffset
          ? storageGid - wnStorageOffset
          : storageGid;

  /// [storageGid] of the gallery stored with the address [url]; [gid] when
  /// it can not be read.
  static int storageGidOfStored(String url, int gid) => tryParseStored(url)?.storageGid ?? gid;

  /// [storageGid] of the gallery of [contentKey]; null for a key of no
  /// gallery.
  static int? storageGidOfKey(String contentKey) {
    final Match? match = RegExp(r'^(?:(eh|nh|wn):)?(\d+)$').firstMatch(contentKey);
    if (match == null) {
      return null;
    }
    final int number = int.parse(match.group(2)!);
    return switch (match.group(1)) {
      'nh' => nhStorageOffset + number,
      'wn' => wnStorageOffset + number,
      _ => number,
    };
  }

  /// [contentKey] and [legacyKey] of the gallery stored with the address
  /// [url] and the number [gid]; the number alone when the address can not
  /// be read.
  static ({String key, String? legacy}) keysOf(String url, int gid) {
    final GalleryUrl? parsed = tryParseStored(url);
    return parsed == null ? (key: '$gid', legacy: null) : (key: parsed.contentKey, legacy: parsed.legacyKey);
  }

  /// The manga of a Tachiyomi chapter (or the manga itself).
  GalleryUrl get tachiMangaUrl => GalleryUrl.tachiManga(tachiSource!, tachiMangaPath!);

  /// FNV-1a (64 bit) of `kind|source|path` in UTF-8, folded into
  /// [tachiGidOffset]'s range. Every device computes the same gid.
  static int tachiGid(String kind, String source, String path) {
    int hash = 0xcbf29ce484222325;
    for (final int byte in utf8.encode('$kind|$source|$path')) {
      hash ^= byte;
      hash = hash * 0x100000001b3;
    }
    return tachiGidOffset + (hash & 0x3FFFFFFFFFFFF) % tachiGidOffset;
  }

  static bool isTachiGid(int gid) => gid >= tachiGidOffset && gid < 2 * tachiGidOffset;

  static GalleryUrl? _tryParseTachi(String url) {
    if (!url.startsWith('tachiyomi://')) {
      return null;
    }
    final Uri? uri = Uri.tryParse(url);
    final String? manga = uri?.queryParameters['m'];
    if (uri == null || uri.host.isEmpty || manga == null) {
      return null;
    }
    final String? chapter = uri.queryParameters['c'];
    return uri.path == '/chapter' && chapter != null ? GalleryUrl.tachiChapter(uri.host, manga, chapter) : GalleryUrl.tachiManga(uri.host, manga);
  }

  static GalleryUrl? tryParse(String url) {
    GalleryUrl? tachi = _tryParseTachi(url);
    if (tachi != null) {
      return tachi;
    }

    RegExp regExp =
        RegExp(r'https://e([-x])hentai\.org/g/(\d+)/([a-z0-9]{10})');
    Match? match = regExp.firstMatch(url);
    if (match != null) {
      return GalleryUrl(
        isEH: match.group(1) == '-',
        gid: int.parse(match.group(2)!),
        token: match.group(3)!,
      );
    }

    for (String domain in ehSetting.nhentaiDomains) {
      String escapedDomain = domain.replaceAll('.', r'\.');
      RegExp nhRegExp = RegExp('https?://(?:www\\.)?$escapedDomain/g/(\\d+)(?:/|\$)');
      Match? nhMatch = nhRegExp.firstMatch(url);
      if (nhMatch != null) {
        return GalleryUrl(
          isEH: true,
          isNH: true,
          gid: int.parse(nhMatch.group(1)!),
          token: 'nhentai',
          sourceHost: domain,
        );
      }
    }

    Uri? wnUri = Uri.tryParse(url);
    if (wnUri != null) {
      String host = wnUri.host;
      bool isWnHost = host == 'wnacg.com' || host == 'www.wnacg.com' || host == ehSetting.wnacgDomain.value;
      if (isWnHost) {
        RegExp wnAidRegExp = RegExp(r'aid-(\d+)');
        Match? wnMatch = wnAidRegExp.firstMatch(wnUri.path);
        if (wnMatch != null) {
          return GalleryUrl(
            isEH: true,
            isWN: true,
            gid: int.parse(wnMatch.group(1)!),
            token: 'wnacg',
          );
        }
      }
    }

    if (wnUri != null && _isJmHost(wnUri.host)) {
      Match? jmMatch = RegExp(r'^/(?:album|photo)/(\d+)').firstMatch(wnUri.path);
      if (jmMatch != null) {
        return GalleryUrl.jm(int.parse(jmMatch.group(1)!));
      }
    }

    return null;
  }

  static bool _isJmHost(String host) => host.contains('18comic') || host.contains('jmcomic');

  static GalleryUrl parse(String url) {
    GalleryUrl? galleryUrl = tryParse(url);
    if (galleryUrl == null) {
      throw InternalException(message: 'Parse gallery url failed, url:$url');
    }

    return galleryUrl;
  }

  /// A gallery url this app wrote down itself (history, favorites, downloads)
  /// and may now read on another device or after its settings changed: an
  /// nhentai url on a domain not in this device's list of nhentai domains is
  /// still one ([url] writes `https://<domain>/g/<id>/`), and so is a wnacg
  /// url on a domain other than the one set now
  /// (`https://<domain>/photos-index-aid-<id>.html`).
  static GalleryUrl? tryParseStored(String url) {
    GalleryUrl? galleryUrl = tryParse(url);
    if (galleryUrl != null) {
      return galleryUrl;
    }
    Match? wnMatch = RegExp(r'^https?://[^/]+/photos-index-aid-(\d+)\.html$').firstMatch(url);
    if (wnMatch != null) {
      return GalleryUrl(
        isEH: true,
        isWN: true,
        gid: int.parse(wnMatch.group(1)!),
        token: 'wnacg',
      );
    }
    Match? nhMatch = RegExp(r'^https?://([^/]+)/g/(\d+)/?$').firstMatch(url);
    if (nhMatch == null) {
      return null;
    }
    return GalleryUrl(
      isEH: true,
      isNH: true,
      gid: int.parse(nhMatch.group(2)!),
      token: 'nhentai',
      sourceHost: nhMatch.group(1)!.replaceFirst(RegExp(r'^www\.'), ''),
    );
  }

  /// [tryParseStored], throwing when even that fails.
  static GalleryUrl parseStored(String url) {
    GalleryUrl? galleryUrl = tryParseStored(url);
    if (galleryUrl == null) {
      throw InternalException(message: 'Parse gallery url failed, url:$url');
    }

    return galleryUrl;
  }

  String get url {
    if (isTachi) {
      return Uri(
        scheme: 'tachiyomi',
        host: tachiSource,
        path: tachiChapterPath == null ? '/manga' : '/chapter',
        queryParameters: <String, String>{'m': tachiMangaPath!, if (tachiChapterPath != null) 'c': tachiChapterPath!},
      ).toString();
    }
    if (isJM) {
      return 'https://18comic.vip/photo/$jmChapterId';
    }
    if (isWN) {
      return 'https://${ehSetting.wnacgDomain.value}/photos-index-aid-$gid.html';
    }
    if (isNH) {
      return 'https://${sourceHost ?? 'nhentai.net'}/g/$gid/';
    }
    return isEH
        ? 'https://e-hentai.org/g/$gid/$token/'
        : 'https://exhentai.org/g/$gid/$token/';
  }

  GalleryUrl copyWith({
    bool? isEH,
    bool? isNH,
    bool? isWN,
    bool? isJM,
    String? sourceHost,
    int? gid,
    String? token,
  }) {
    return GalleryUrl(
      isEH: isEH ?? this.isEH,
      isNH: isNH ?? this.isNH,
      isWN: isWN ?? this.isWN,
      isJM: isJM ?? this.isJM,
      isTachi: isTachi,
      sourceHost: sourceHost ?? this.sourceHost,
      gid: gid ?? this.gid,
      token: token ?? this.token,
      tachiSource: tachiSource,
      tachiMangaPath: tachiMangaPath,
      tachiChapterPath: tachiChapterPath,
    );
  }

  @override
  String toString() {
    return 'GalleryUrl{isEH: $isEH, isNH: $isNH, isWN: $isWN, isJM: $isJM, isTachi: $isTachi, sourceHost: $sourceHost, gid: $gid, token: $token, tachiSource: $tachiSource, tachiMangaPath: $tachiMangaPath, tachiChapterPath: $tachiChapterPath}';
  }
}
