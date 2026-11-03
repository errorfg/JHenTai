import 'package:intl/intl.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/service/series_reading_service.dart';

/// The newest chapter of a series in the favorites (a JM album, a
/// Tachiyomi manga), as its last check found it.
class SeriesLatest {
  const SeriesLatest({required this.chapterId, required this.at});

  /// Its id among the source's progress records ([SeriesReadingService]).
  final int chapterId;

  /// When it came out; when the source does not say, when a check first
  /// found it.
  final DateTime at;

  factory SeriesLatest.fromJson(Map<String, dynamic> json) => SeriesLatest(
        chapterId: (json['chapter'] as num).toInt(),
        at: DateTime.fromMillisecondsSinceEpoch((json['at'] as num).toInt(), isUtc: true),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{'chapter': chapterId, 'at': at.millisecondsSinceEpoch};
}

/// Of [favorites] (as the favorites list shows them), those not caught up
/// with: their newest chapter has not been opened. The newest is the one
/// the last check found; before one did, the last of the chapters kept when
/// the series was opened, or the series itself when it is a chapter
/// ([singleChapterOf]). One whose newest is not known at all has not been
/// read either. By gid, each with the time of its newest chapter, or else
/// when it was favorited.
Future<Map<int, DateTime>> favoritesNotCaughtUp({
  required List<Gallery> favorites,
  required SeriesLatest? Function(Gallery gallery) latestOf,
  required SeriesReadingService reading,
  required int Function(Gallery gallery) seriesIdOf,
  int? Function(Gallery gallery)? singleChapterOf,
}) async {
  final Map<int, List<int>> kept = await reading.chaptersOfAll(<int>{
    for (final Gallery gallery in favorites)
      if (latestOf(gallery) == null) seriesIdOf(gallery),
  });
  final Map<int, int?> newest = <int, int?>{
    for (final Gallery gallery in favorites)
      gallery.gid: latestOf(gallery)?.chapterId ?? kept[seriesIdOf(gallery)]?.lastOrNull ?? singleChapterOf?.call(gallery),
  };
  final Map<int, SeriesChapterProgress> progress = await reading.progressOf(newest.values.whereType<int>().toSet().toList());
  return <int, DateTime>{
    for (final Gallery gallery in favorites)
      if (newest[gallery.gid] == null || progress[newest[gallery.gid]]?.hasRecord != true)
        gallery.gid: latestOf(gallery)?.at ?? _favoritedTime(gallery) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  };
}

/// [Gallery.favoritedTime] of a local favorite: `yyyy-MM-dd HH:mm`, UTC.
DateTime? _favoritedTime(Gallery gallery) {
  final String? text = gallery.favoritedTime;
  if (text == null) {
    return null;
  }
  try {
    return DateFormat('yyyy-MM-dd HH:mm').parseUtc(text);
  } catch (_) {
    return null;
  }
}
