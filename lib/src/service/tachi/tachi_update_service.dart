import 'dart:async';
import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/tachi/tachi_models.dart';
import 'package:jhentai/src/network/tachi/tachi_source.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/tachi/tachi_favorite_service.dart';

TachiUpdateService tachiUpdateService = TachiUpdateService();

/// A chapter found new on a manga in the favorites.
class TachiUpdate {
  const TachiUpdate({
    required this.source,
    required this.mangaPath,
    required this.mangaTitle,
    required this.cover,
    required this.chapterPath,
    required this.chapterName,
    required this.chapterDate,
    required this.foundAt,
  });

  final String source;
  final String mangaPath;
  final String mangaTitle;

  /// As kept in galleries: a `tachi-cover://` address.
  final String cover;
  final String chapterPath;
  final String chapterName;

  /// Milliseconds since the epoch; 0 when the source does not say.
  final int chapterDate;
  final int foundAt;

  GalleryUrl get chapterUrl => GalleryUrl.tachiChapter(source, mangaPath, chapterPath);

  factory TachiUpdate.fromJson(Map<String, dynamic> json) => TachiUpdate(
        source: json['source'] as String,
        mangaPath: json['manga'] as String,
        mangaTitle: json['title'] as String? ?? '',
        cover: json['cover'] as String? ?? '',
        chapterPath: json['chapter'] as String,
        chapterName: json['name'] as String? ?? '',
        chapterDate: (json['date'] as num?)?.toInt() ?? 0,
        foundAt: (json['foundAt'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source,
        'manga': mangaPath,
        'title': mangaTitle,
        'cover': cover,
        'chapter': chapterPath,
        'name': chapterName,
        'date': chapterDate,
        'foundAt': foundAt,
      };
}

/// New chapters of the Tachiyomi manga in the favorites. Only a manual
/// refresh asks the sites, one chapter list request per manga; the first
/// check of a manga records its chapters without listing them as new. Kept
/// on this device.
class TachiUpdateService with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  static const int _keptUpdates = 500;
  static const int _parallel = 3;

  @override
  ConfigEnum get configEnum => ConfigEnum.tachiUpdates;

  /// Chapter paths seen, by manga gid.
  Map<int, Set<String>> _known = <int, Set<String>>{};

  final RxList<TachiUpdate> updates = <TachiUpdate>[].obs;
  final RxBool checking = false.obs;
  final RxInt checked = 0.obs;
  final RxInt total = 0.obs;
  final RxInt failed = 0.obs;
  int lastCheckedAt = 0;

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  @override
  void applyBeanConfig(String configString) {
    final Map<String, dynamic> json = jsonDecode(configString) as Map<String, dynamic>;
    _known = <int, Set<String>>{
      for (final MapEntry<String, dynamic> e in ((json['known'] as Map?) ?? const <String, dynamic>{}).cast<String, dynamic>().entries)
        int.parse(e.key): (e.value as List).cast<String>().toSet(),
    };
    updates.value = ((json['updates'] as List?) ?? const <dynamic>[]).map((dynamic u) => TachiUpdate.fromJson(u as Map<String, dynamic>)).toList();
    lastCheckedAt = (json['checkedAt'] as num?)?.toInt() ?? 0;
  }

  @override
  String toConfigString() => jsonEncode(<String, dynamic>{
        'known': <String, dynamic>{for (final MapEntry<int, Set<String>> e in _known.entries) '${e.key}': e.value.toList()},
        'updates': updates.map((TachiUpdate u) => u.toJson()).toList(),
        'checkedAt': lastCheckedAt,
      });

  /// Asks the source of every Tachiyomi favorite for its chapters.
  Future<void> refresh() async {
    if (checking.isTrue) {
      return;
    }
    final List<Gallery> favorites = tachiFavoriteService.getDisplayFavorites();
    checking.value = true;
    checked.value = 0;
    failed.value = 0;
    total.value = favorites.length;
    final List<TachiUpdate> found = <TachiUpdate>[];
    final int now = DateTime.now().millisecondsSinceEpoch;
    int next = 0;

    Future<void> worker() async {
      while (next < favorites.length) {
        final Gallery gallery = favorites[next++];
        final GalleryUrl url = gallery.galleryUrl;
        try {
          final TachiMangaEntry entry = await ehRequest.tachiSource.manga(url, refresh: true);
          final Set<String> paths = entry.chapters.map((TachiChapter c) => c.url).toSet();
          final Set<String>? known = _known[url.gid];
          if (known != null) {
            for (final TachiChapter chapter in entry.chapters.where((TachiChapter c) => !known.contains(c.url))) {
              found.add(TachiUpdate(
                source: entry.source,
                mangaPath: entry.manga.url,
                mangaTitle: entry.manga.title.isEmpty ? gallery.title : entry.manga.title,
                cover: gallery.cover.url,
                chapterPath: chapter.url,
                chapterName: chapter.name,
                chapterDate: chapter.dateUpload,
                foundAt: now,
              ));
            }
          }
          _known[url.gid] = paths;
        } catch (e) {
          failed.value++;
          log.warning('Check updates of ${gallery.title} failed', e);
        } finally {
          checked.value++;
        }
      }
    }

    try {
      await Future.wait(<Future<void>>[for (int i = 0; i < _parallel; i++) worker()]);
      found.sort((TachiUpdate a, TachiUpdate b) => b.chapterDate.compareTo(a.chapterDate));
      final List<TachiUpdate> all = <TachiUpdate>[...found, ...updates];
      updates.value = all.length > _keptUpdates ? all.sublist(0, _keptUpdates) : all;
      lastCheckedAt = now;
      await saveBeanConfig();
    } finally {
      checking.value = false;
    }
  }

  /// Forgets what is known of [mangaGid], e.g. after it left the favorites.
  Future<void> forget(int mangaGid) async {
    if (_known.remove(mangaGid) != null) {
      await saveBeanConfig();
    }
  }
}
