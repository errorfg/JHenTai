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

/// Of [favorites] (as the favorites list shows them), those with new
/// chapters: one came out after the series was favorited, and the newest
/// has not been opened. By gid, each with the time of its newest chapter.
Future<Map<int, DateTime>> favoritesWithNewChapters({
  required List<Gallery> favorites,
  required SeriesLatest? Function(Gallery gallery) latestOf,
  required SeriesReadingService reading,
}) async {
  final Map<int, SeriesLatest> candidates = <int, SeriesLatest>{};
  for (final Gallery gallery in favorites) {
    final SeriesLatest? latest = latestOf(gallery);
    final DateTime? favorited = _favoritedTime(gallery);
    if (latest != null && favorited != null && latest.at.isAfter(favorited)) {
      candidates[gallery.gid] = latest;
    }
  }
  if (candidates.isEmpty) {
    return <int, DateTime>{};
  }
  final Map<int, SeriesChapterProgress> progress =
      await reading.progressOf(candidates.values.map((SeriesLatest l) => l.chapterId).toSet().toList());
  return <int, DateTime>{
    for (final MapEntry<int, SeriesLatest> entry in candidates.entries)
      if (progress[entry.value.chapterId]?.hasRecord != true) entry.key: entry.value.at,
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
