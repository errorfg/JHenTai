import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart' as drift show Value;
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart' show LocalConfigCompanion;
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

WatchedProgressService watchedProgressService = WatchedProgressService();

/// A gallery of the watched list as the reading map keeps it: enough to show
/// its cover and to open the list at it.
class WatchedGallery {
  WatchedGallery({
    required this.gid,
    required this.url,
    required this.title,
    required this.cover,
    required this.publishTime,
    required this.at,
    this.older,
  });

  factory WatchedGallery.of(Gallery gallery, DateTime at) => WatchedGallery(
        gid: gallery.gid,
        url: gallery.galleryUrl.url,
        title: gallery.title,
        cover: GalleryImage(url: gallery.cover.url, width: gallery.cover.width, height: gallery.cover.height),
        publishTime: gallery.publishTime,
        at: at,
      );

  final int gid;
  final String url;
  final String title;
  final GalleryImage cover;

  /// As the list shows it, e.g. `2026-09-25 14:32`.
  final String publishTime;

  /// When it was scrolled past, or bookmarked.
  final DateTime at;

  /// The read gallery that came right after this one (older) in the list,
  /// when the two were scrolled past next to each other: the two are one
  /// stretch of the map.
  int? older;

  /// `2026-09-25`.
  String get day => publishTime.length >= 10 ? publishTime.substring(0, 10) : publishTime;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'gid': gid,
        'url': url,
        'title': title,
        'cover': <String, dynamic>{'url': cover.url, 'width': cover.width, 'height': cover.height},
        'publishTime': publishTime,
        'at': at.toUtc().toIso8601String(),
        if (older != null) 'older': older,
      };

  factory WatchedGallery.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> cover = (json['cover'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    return WatchedGallery(
      gid: json['gid'] as int,
      url: json['url'] as String? ?? '',
      title: json['title'] as String? ?? '',
      cover: GalleryImage(
        url: cover['url'] as String? ?? '',
        width: (cover['width'] as num?)?.toDouble(),
        height: (cover['height'] as num?)?.toDouble(),
      ),
      publishTime: json['publishTime'] as String? ?? '',
      at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      older: json['older'] as int?,
    );
  }
}

/// Galleries scrolled past one after another: newest first.
class WatchedReadRange {
  WatchedReadRange(this.gallerys);

  final List<WatchedGallery> gallerys;

  WatchedGallery get newest => gallerys.first;

  WatchedGallery get oldest => gallerys.last;
}

/// How far the E-Hentai watched list has been read: every gallery scrolled
/// past counts as read, and the galleries scrolled past one after another
/// make a stretch of the reading map ([ranges]). Besides, where the list was
/// left ([lastPosition]) and the galleries bookmarked by hand.
///
/// On this device only. Rows are written a second after the last change.
class WatchedProgressService extends GetxController with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  static const String updateId = 'watchedProgress';

  @override
  List<JHLifeCircleBean> get initDependencies => super.initDependencies..addAll([localConfigService]);

  final Map<int, WatchedGallery> _read = <int, WatchedGallery>{};
  final Set<int> _dirty = <int>{};
  bool _bookmarksDirty = false;
  Timer? _flushTimer;

  /// Set by tests.
  Duration flushDelay = const Duration(seconds: 1);

  /// Where the list was when it was last scrolled: the gallery at its top.
  WatchedGallery? lastPosition;

  /// Bookmarked by hand, in the order of the list (newest first).
  final List<WatchedGallery> bookmarks = <WatchedGallery>[];

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
    await load();
  }

  @override
  Future<void> doAfterBeanReady() async {}

  /// Reads what is stored, replacing what is in memory.
  Future<void> load() async {
    _read.clear();
    bookmarks.clear();
    lastPosition = null;
    for (final config in await localConfigService.readWithAllSubKeys(configKey: ConfigEnum.watchedRead)) {
      try {
        final WatchedGallery gallery = WatchedGallery.fromJson(jsonDecode(config.value) as Map<String, dynamic>);
        _read[gallery.gid] = gallery;
      } catch (e) {
        log.warning('Skip a broken watched-list row ${config.subConfigKey}', e);
      }
    }
    final String? saved = await localConfigService.read(configKey: ConfigEnum.watchedBookmarks);
    if (saved != null) {
      try {
        final Map<String, dynamic> json = jsonDecode(saved) as Map<String, dynamic>;
        lastPosition = json['last'] == null ? null : WatchedGallery.fromJson(json['last'] as Map<String, dynamic>);
        bookmarks.addAll([for (final dynamic b in json['bookmarks'] as List? ?? const <dynamic>[]) WatchedGallery.fromJson(b as Map<String, dynamic>)]);
      } catch (e) {
        log.warning('Skip broken watched-list bookmarks', e);
      }
    }
  }

  bool isRead(int gid) => _read.containsKey(gid);

  int get readCount => _read.length;

  /// The galleries [from] to [to] of [gallerys] (the list as shown; either
  /// order) were scrolled past one after another: each is read, and each
  /// two next to each other are one stretch. A read gallery shown right
  /// before or after them joins the stretch too.
  void markRead(List<Gallery> gallerys, int from, int to) {
    if (gallerys.isEmpty) {
      return;
    }
    final int low = max(0, min(from, to));
    final int high = min(gallerys.length - 1, max(from, to));
    final DateTime now = DateTime.now().toUtc();
    for (int i = low; i <= high; i++) {
      final Gallery gallery = gallerys[i];
      WatchedGallery? entry = _read[gallery.gid];
      if (entry == null) {
        entry = _read[gallery.gid] = WatchedGallery.of(gallery, now);
        _dirty.add(gallery.gid);
      }
      if (i < high) {
        _link(entry, gallerys[i + 1].gid);
      }
    }
    if (low > 0) {
      final WatchedGallery? before = _read[gallerys[low - 1].gid];
      if (before != null) {
        _link(before, gallerys[low].gid);
      }
    }
    if (high + 1 < gallerys.length && _read.containsKey(gallerys[high + 1].gid)) {
      _link(_read[gallerys[high].gid]!, gallerys[high + 1].gid);
    }
    _scheduleFlush();
  }

  void _link(WatchedGallery entry, int older) {
    if (entry.older != older) {
      entry.older = older;
      _dirty.add(entry.gid);
    }
  }

  /// The stretches read, the one highest in the list first.
  List<WatchedReadRange> get ranges {
    final List<WatchedGallery> byPlace = _read.values.toList()..sort((a, b) => b.gid.compareTo(a.gid));
    // A gallery another one leads to does not start a stretch.
    final Set<int> ledTo = <int>{
      for (final WatchedGallery g in _read.values)
        if (g.older != null && _read.containsKey(g.older)) g.older!,
    };
    final Set<int> placed = <int>{};
    final List<WatchedReadRange> ranges = <WatchedReadRange>[];

    void collect(WatchedGallery start) {
      final List<WatchedGallery> stretch = <WatchedGallery>[];
      WatchedGallery? current = start;
      while (current != null && placed.add(current.gid)) {
        stretch.add(current);
        current = current.older == null ? null : _read[current.older];
      }
      ranges.add(WatchedReadRange(stretch));
    }

    for (final WatchedGallery gallery in byPlace) {
      if (!ledTo.contains(gallery.gid) && !placed.contains(gallery.gid)) {
        collect(gallery);
      }
    }
    // Links gone round in a circle: whatever is left starts where it is.
    for (final WatchedGallery gallery in byPlace) {
      if (!placed.contains(gallery.gid)) {
        collect(gallery);
      }
    }
    ranges.sort((a, b) => b.newest.gid.compareTo(a.newest.gid));
    return ranges;
  }

  void setLastPosition(Gallery gallery) {
    if (lastPosition?.gid == gallery.gid) {
      return;
    }
    lastPosition = WatchedGallery.of(gallery, DateTime.now().toUtc());
    _bookmarksDirty = true;
    _scheduleFlush();
  }

  bool isBookmarked(int gid) => bookmarks.any((WatchedGallery b) => b.gid == gid);

  void addBookmark(Gallery gallery) {
    if (isBookmarked(gallery.gid)) {
      return;
    }
    bookmarks
      ..add(WatchedGallery.of(gallery, DateTime.now().toUtc()))
      ..sort((a, b) => b.gid.compareTo(a.gid));
    _bookmarksDirty = true;
    _scheduleFlush();
  }

  void removeBookmark(int gid) {
    bookmarks.removeWhere((WatchedGallery b) => b.gid == gid);
    _bookmarksDirty = true;
    _scheduleFlush();
  }

  void _scheduleFlush() {
    updateSafely([updateId]);
    _flushTimer?.cancel();
    _flushTimer = Timer(flushDelay, () => unawaited(flush()));
  }

  /// Writes what changed since the last time.
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    final List<int> dirty = _dirty.toList();
    _dirty.clear();
    final bool bookmarksDirty = _bookmarksDirty;
    _bookmarksDirty = false;
    try {
      if (dirty.isNotEmpty) {
        final String now = SyncTimeUtil.nowIso();
        await localConfigService.batchWrite(<LocalConfigCompanion>[
          for (final int gid in dirty)
            if (_read[gid] != null)
              LocalConfigCompanion(
                configKey: drift.Value(ConfigEnum.watchedRead.key),
                subConfigKey: drift.Value('$gid'),
                value: drift.Value(jsonEncode(_read[gid]!.toJson())),
                utime: drift.Value(now),
              ),
        ]);
      }
      if (bookmarksDirty) {
        await localConfigService.write(
          configKey: ConfigEnum.watchedBookmarks,
          value: jsonEncode(<String, dynamic>{
            'last': lastPosition?.toJson(),
            'bookmarks': <Map<String, dynamic>>[for (final WatchedGallery b in bookmarks) b.toJson()],
          }),
        );
      }
    } catch (e, s) {
      log.error('Save watched-list progress failed', e, s);
      _dirty.addAll(dirty);
      _bookmarksDirty = _bookmarksDirty || bookmarksDirty;
    }
  }
}
