import 'dart:convert';

import 'package:jhentai/src/database/database.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/service/jh_service.dart';

NHentaiFavoriteService nhentaiFavoriteService = NHentaiFavoriteService();

class NHentaiFavoriteService
    with JHLifeCircleBeanWithConfigStorage
    implements JHLifeCircleBean {
  static const int minFavoriteCategoryIndex = 0;
  static const int maxFavoriteCategoryIndex = 9;
  static const int defaultFavoriteCategoryIndex = 0;

  static final DateFormat _displayDateFormat = DateFormat('yyyy-MM-dd HH:mm');
  static final RegExp _keywordTokenPattern =
      RegExp(r'(\w+):"([^"]+)"|(\w+):(\S+)|"([^"]+)"|(\S+)');

  final Map<int, _NHentaiFavoriteEntry> _favoritesByGid =
      <int, _NHentaiFavoriteEntry>{};

  @override
  ConfigEnum get configEnum => ConfigEnum.nhentaiFavorite;

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  @override
  void applyBeanConfig(String configString) {
    _favoritesByGid.clear();

    dynamic decoded = jsonDecode(configString);
    if (decoded is! List) {
      return;
    }

    List<dynamic> rawList = decoded;
    for (dynamic item in rawList) {
      if (item is! Map) {
        continue;
      }

      _NHentaiFavoriteEntry? entry =
          _NHentaiFavoriteEntry.tryFromJson(item.cast<String, dynamic>());
      if (entry == null || !entry.gallery.galleryUrl.isNH) {
        continue;
      }

      _favoritesByGid[entry.gallery.gid] = entry;
    }
  }

  @override
  String toConfigString() {
    List<_NHentaiFavoriteEntry> sortedEntries = _favoritesByGid.values.toList()
      ..sort((a, b) => b.favoritedTime.compareTo(a.favoritedTime));

    return jsonEncode(sortedEntries.map((entry) => entry.toJson()).toList());
  }

  bool isFavorite(int gid) => _favoritesByGid.containsKey(gid);

  int? getFavoriteCategoryIndex(int gid) =>
      _favoritesByGid[gid]?.favoriteCategoryIndex;

  Future<void> addFavorite(
    Gallery gallery, {
    required int favoriteCategoryIndex,
    DateTime? favoritedTime,
  }) async {
    if (!gallery.galleryUrl.isNH) {
      return;
    }

    _NHentaiFavoriteEntry? existing = _favoritesByGid[gallery.gid];
    Gallery snapshot = _normalizeNhGallerySnapshot(gallery);

    _favoritesByGid[snapshot.gid] = _NHentaiFavoriteEntry(
      gallery: snapshot,
      favoritedTime:
          (favoritedTime ?? existing?.favoritedTime ?? DateTime.now()).toUtc(),
      favoriteCategoryIndex: _normalizeCategoryIndex(favoriteCategoryIndex),
    );

    await saveBeanConfig();
  }

  Future<void> removeFavorite(int gid) async {
    if (_favoritesByGid.remove(gid) == null) {
      return;
    }
    await saveBeanConfig();
  }

  List<Gallery> getDisplayFavorites({
    FavoriteSortOrder? sortOrder,
    SearchConfig? searchConfig,
  }) {
    List<_NHentaiFavoriteEntry> sortedEntries = _favoritesByGid.values
        .where((entry) => _matchesSearchConfig(entry, searchConfig))
        .toList()
      ..sort((a, b) => b.favoritedTime.compareTo(a.favoritedTime));

    return sortedEntries
        .map(
          (entry) => entry.gallery.copyWith(
            favoriteTagIndex: entry.favoriteCategoryIndex,
            favoriteTagName: null,
            publishTime: _resolveDisplayTime(entry, sortOrder),
          ),
        )
        .toList();
  }

  Gallery _normalizeNhGallerySnapshot(Gallery source) {
    // Persist a standalone immutable snapshot of the favorite item.
    Gallery snapshot = Gallery.fromJson(
      jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>,
    );

    return snapshot.copyWith(
      publishTime: _normalizeTimeString(
        snapshot.publishTime,
        fallbackTime: DateTime.now().toUtc(),
      ),
      favoriteTagIndex: null,
      favoriteTagName: null,
    );
  }

  String _resolveDisplayTime(
      _NHentaiFavoriteEntry entry, FavoriteSortOrder? sortOrder) {
    if (sortOrder == FavoriteSortOrder.publishedTime) {
      return _normalizeTimeString(
        entry.gallery.publishTime,
        fallbackTime: entry.favoritedTime,
      );
    }

    return _displayDateFormat.format(entry.favoritedTime.toUtc());
  }

  String _normalizeTimeString(String raw, {DateTime? fallbackTime}) {
    DateTime? parsed = _tryParseTimeString(raw);
    DateTime target = (parsed ?? fallbackTime ?? DateTime.now()).toUtc();
    return _displayDateFormat.format(target);
  }

  DateTime? _tryParseTimeString(String raw) {
    String normalized = raw.trim();
    if (normalized.isEmpty) {
      return null;
    }

    try {
      return _displayDateFormat.parseUtc(normalized);
    } catch (_) {}

    try {
      return DateFormat('yyyy-MM-dd HH:mm:ss').parseUtc(normalized);
    } catch (_) {}

    DateTime? parsed = DateTime.tryParse(normalized);
    return parsed?.toUtc();
  }

  int _normalizeCategoryIndex(int index) {
    if (index < minFavoriteCategoryIndex || index > maxFavoriteCategoryIndex) {
      return defaultFavoriteCategoryIndex;
    }
    return index;
  }

  bool _matchesSearchConfig(
      _NHentaiFavoriteEntry entry, SearchConfig? searchConfig) {
    if (searchConfig == null) {
      return true;
    }

    if (searchConfig.searchFavoriteCategoryIndex != null &&
        entry.favoriteCategoryIndex !=
            searchConfig.searchFavoriteCategoryIndex) {
      return false;
    }

    if (!_matchesTags(entry.gallery, searchConfig.tags)) {
      return false;
    }

    if (!_matchesKeyword(entry.gallery, searchConfig.keyword)) {
      return false;
    }

    return true;
  }

  bool _matchesTags(Gallery gallery, List<TagData>? tags) {
    if (tags == null || tags.isEmpty) {
      return true;
    }

    for (TagData tag in tags) {
      String value = _normalizeTerm(tag.key);
      if (value.isEmpty) {
        continue;
      }

      String namespace = _normalizeTerm(tag.namespace);
      if (!_matchesToken(
        gallery: gallery,
        qualifier: namespace.isEmpty ? null : namespace,
        value: value,
      )) {
        return false;
      }
    }

    return true;
  }

  bool _matchesKeyword(Gallery gallery, String? keyword) {
    if (keyword == null || keyword.trim().isEmpty) {
      return true;
    }

    List<_FavoriteKeywordToken> tokens = _parseKeywordTokens(keyword);
    if (tokens.isEmpty) {
      return true;
    }

    for (_FavoriteKeywordToken token in tokens) {
      if (!_matchesToken(
        gallery: gallery,
        qualifier: token.qualifier,
        value: token.value,
      )) {
        return false;
      }
    }

    return true;
  }

  List<_FavoriteKeywordToken> _parseKeywordTokens(String keyword) {
    String normalized = keyword.trim();
    if (normalized.isEmpty) {
      return const <_FavoriteKeywordToken>[];
    }

    List<_FavoriteKeywordToken> tokens = [];
    for (RegExpMatch match in _keywordTokenPattern.allMatches(normalized)) {
      String? qualifier = match.group(1) ?? match.group(3);
      String? value = match.group(2) ?? match.group(4);
      value ??= match.group(5) ?? match.group(6);

      String normalizedValue = _normalizeTerm(value ?? '');
      if (normalizedValue.isEmpty) {
        continue;
      }

      String? normalizedQualifier = qualifier == null
          ? null
          : _normalizeTerm(qualifier).replaceAll(':', '');

      if (normalizedQualifier == 'nh') {
        continue;
      }

      tokens.add(
        _FavoriteKeywordToken(
          qualifier:
              normalizedQualifier?.isEmpty == true ? null : normalizedQualifier,
          value: normalizedValue,
        ),
      );
    }

    return tokens;
  }

  bool _matchesToken({
    required Gallery gallery,
    required String? qualifier,
    required String value,
  }) {
    if (qualifier == null) {
      return _matchesGeneralTerm(gallery, value);
    }

    switch (qualifier) {
      case 'title':
        return _contains(gallery.title, value);
      case 'uploader':
        return _contains(gallery.uploader, value);
      case 'category':
        return _contains(gallery.category, value);
      case 'language':
        return _contains(gallery.language, value) ||
            _matchesNamespaceTag(gallery, 'language', value);
      case 'tag':
        return _matchesAnyTag(gallery, value);
      case 'comment':
      case 'favnote':
        return false;
      default:
        return _matchesNamespaceTag(gallery, qualifier, value);
    }
  }

  bool _matchesGeneralTerm(Gallery gallery, String value) {
    if (_contains(gallery.title, value) ||
        _contains(gallery.uploader, value) ||
        _contains(gallery.category, value) ||
        _contains(gallery.language, value)) {
      return true;
    }

    return _matchesAnyTag(gallery, value);
  }

  bool _matchesAnyTag(Gallery gallery, String value) {
    for (MapEntry<String, List> entry in gallery.tags.entries) {
      String namespace = _normalizeTerm(entry.key);
      if (namespace.contains(value)) {
        return true;
      }

      for (dynamic rawTag in entry.value) {
        String key = _normalizeTerm(rawTag.tagData.key ?? '');
        if (key.contains(value)) {
          return true;
        }

        if ('$namespace:$key'.contains(value)) {
          return true;
        }
      }
    }

    return false;
  }

  bool _matchesNamespaceTag(Gallery gallery, String namespace, String value) {
    List? tags = gallery.tags[namespace];
    if (tags == null || tags.isEmpty) {
      return false;
    }

    for (dynamic rawTag in tags) {
      String key = _normalizeTerm(rawTag.tagData.key ?? '');
      if (key.contains(value)) {
        return true;
      }
    }

    return false;
  }

  bool _contains(String? source, String value) {
    if (source == null) {
      return false;
    }
    return _normalizeTerm(source).contains(value);
  }

  String _normalizeTerm(String raw) {
    return raw.trim().toLowerCase().replaceAll('\$', '');
  }
}

class _NHentaiFavoriteEntry {
  final Gallery gallery;
  final DateTime favoritedTime;
  final int favoriteCategoryIndex;

  const _NHentaiFavoriteEntry({
    required this.gallery,
    required this.favoritedTime,
    required this.favoriteCategoryIndex,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'gallery': gallery.toJson(),
      'favoritedTime': favoritedTime.toUtc().toIso8601String(),
      'favoriteCategoryIndex': favoriteCategoryIndex,
    };
  }

  static _NHentaiFavoriteEntry? tryFromJson(Map<String, dynamic> map) {
    dynamic rawGallery = map['gallery'];
    if (rawGallery is! Map) {
      return null;
    }

    Gallery gallery = Gallery.fromJson(rawGallery.cast<String, dynamic>());

    DateTime? favoritedTime =
        DateTime.tryParse(map['favoritedTime']?.toString() ?? '');
    favoritedTime ??= DateTime.tryParse(gallery.publishTime);
    favoritedTime ??= DateTime.now();

    int favoriteCategoryIndex =
        int.tryParse(map['favoriteCategoryIndex']?.toString() ?? '') ??
            NHentaiFavoriteService.defaultFavoriteCategoryIndex;
    if (favoriteCategoryIndex <
            NHentaiFavoriteService.minFavoriteCategoryIndex ||
        favoriteCategoryIndex >
            NHentaiFavoriteService.maxFavoriteCategoryIndex) {
      favoriteCategoryIndex =
          NHentaiFavoriteService.defaultFavoriteCategoryIndex;
    }

    return _NHentaiFavoriteEntry(
      gallery: gallery,
      favoritedTime: favoritedTime.toUtc(),
      favoriteCategoryIndex: favoriteCategoryIndex,
    );
  }
}

class _FavoriteKeywordToken {
  final String? qualifier;
  final String value;

  const _FavoriteKeywordToken({
    required this.qualifier,
    required this.value,
  });
}
