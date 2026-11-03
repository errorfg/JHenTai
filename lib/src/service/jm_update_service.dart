import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/jm_favorite_service.dart';
import 'package:jhentai/src/service/jm_reading_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/series_update.dart';

JmUpdateService jmUpdateService = JmUpdateService();

/// The newest chapter of each JM album in the favorites.
///
/// JM's newest list (every category, newest first) is in the order of the
/// albums' last update: an album given a new chapter comes back to its top.
/// A check reads it from the top down to a day before the last check (some
/// two pages of 80 for each day) and asks for the details of the favorites
/// it finds updated since they were last known, one request each. The
/// first check, and one after a month without, asks for the details of
/// every favorite. Kept on this device.
class JmUpdateService with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  static const int _parallel = 3;

  /// Further back than this the newest list is not read: it ends after
  /// 10000 albums, about two months at JM's pace.
  static const Duration _scanReach = Duration(days: 30);

  /// Albums new to JM are not always where their update time puts them:
  /// the list is read this much further than the last check.
  static const Duration _overlap = Duration(days: 1);
  static const int _maxPages = 125;

  /// Set by tests.
  Future<JmSearchResult> Function(int page) latestPage = (int page) => ehRequest.jmSource.api.latest(page: page);
  Future<JmAlbum> Function(int id) albumOf = (int id) => ehRequest.jmSource.api.album(id);

  /// By album id.
  Map<int, SeriesLatest> _latest = <int, SeriesLatest>{};

  /// Albums whose details could not be had: asked again next time.
  Set<int> _retry = <int>{};
  DateTime? _checkedAt;

  final RxBool checking = false.obs;

  @override
  ConfigEnum get configEnum => ConfigEnum.jmUpdates;

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  @override
  void applyBeanConfig(String configString) {
    final Map<String, dynamic> json = jsonDecode(configString) as Map<String, dynamic>;
    _latest = <int, SeriesLatest>{
      for (final MapEntry<String, dynamic> e in ((json['latest'] as Map?) ?? const <String, dynamic>{}).cast<String, dynamic>().entries)
        int.parse(e.key): SeriesLatest.fromJson((e.value as Map).cast<String, dynamic>()),
    };
    _retry = ((json['retry'] as List?) ?? const <dynamic>[]).cast<int>().toSet();
    final int? checkedAt = (json['checkedAt'] as num?)?.toInt();
    _checkedAt = checkedAt == null ? null : DateTime.fromMillisecondsSinceEpoch(checkedAt, isUtc: true);
  }

  @override
  String toConfigString() => jsonEncode(<String, dynamic>{
        'latest': <String, dynamic>{for (final MapEntry<int, SeriesLatest> e in _latest.entries) '${e.key}': e.value.toJson()},
        'retry': _retry.toList(),
        if (_checkedAt != null) 'checkedAt': _checkedAt!.millisecondsSinceEpoch,
      });

  bool get hasChecked => _checkedAt != null;

  SeriesLatest? latestOf(Gallery gallery) => _latest[gallery.galleryUrl.jmChapterId];

  /// Looks for new chapters of the favorites; returns how many albums could
  /// not be asked (they are asked again next time). Throws when the newest
  /// list can not be read; nothing is kept then.
  Future<int> check() async {
    if (checking.isTrue) {
      return 0;
    }
    checking.value = true;
    try {
      final DateTime start = DateTime.now().toUtc();
      // With the time each was last updated, as kept when favorited.
      final Map<int, Gallery> favorites = <int, Gallery>{
        for (final Gallery g in jmFavoriteService.getDisplayFavorites(sortOrder: FavoriteSortOrder.publishedTime)) g.galleryUrl.jmChapterId: g,
      };

      final Set<int> ask;
      if (_checkedAt == null || start.difference(_checkedAt!) > _scanReach) {
        ask = favorites.keys.toSet();
      } else {
        ask = _retry.where(favorites.containsKey).toSet();
        final DateTime since = _checkedAt!.subtract(_overlap);
        for (int page = 1; page <= _maxPages; page++) {
          final List<JmAlbumSummary> albums = (await latestPage(page)).albums;
          for (final JmAlbumSummary album in albums) {
            final Gallery? favorite = favorites[album.id];
            final DateTime? known = favorite == null ? null : (_latest[album.id]?.at ?? _publishTime(favorite));
            if (album.updateAt != null && known != null && album.updateAt!.difference(known) >= const Duration(minutes: 1)) {
              ask.add(album.id);
            }
          }
          final DateTime? last = albums.lastOrNull?.updateAt;
          if (last == null || last.isBefore(since)) {
            break;
          }
        }
      }

      final List<int> queue = ask.toList();
      final Set<int> failed = <int>{};
      int next = 0;
      Future<void> worker() async {
        while (next < queue.length) {
          final int id = queue[next++];
          try {
            final JmAlbum album = await albumOf(id);
            _latest[id] = SeriesLatest(chapterId: album.chapters.last.id, at: album.addTime);
            if (album.chapters.length > 1) {
              await jmReadingService.remember(albumId: id, chapterIds: album.chapters.map((JmChapterRef c) => c.id).toList());
            }
          } catch (e) {
            failed.add(id);
            log.warning('Check new chapters of JM album $id failed', e);
          }
        }
      }

      await Future.wait(<Future<void>>[for (int i = 0; i < _parallel; i++) worker()]);
      _latest.removeWhere((int id, _) => !favorites.containsKey(id));
      _retry = failed;
      _checkedAt = start;
      await saveBeanConfig();
      return failed.length;
    } finally {
      checking.value = false;
    }
  }

  /// [Gallery.publishTime] of a favorite: `yyyy-MM-dd HH:mm`, UTC.
  static DateTime? _publishTime(Gallery gallery) {
    try {
      return DateFormat('yyyy-MM-dd HH:mm').parseUtc(gallery.publishTime);
    } catch (_) {
      return null;
    }
  }
}
