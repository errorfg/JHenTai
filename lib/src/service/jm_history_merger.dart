import 'package:jhentai/src/model/gallery_history_model.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/jm_reading_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

JmHistoryMerger jmHistoryMerger = JmHistoryMerger();

/// Finds out which album the JM history entries made per chapter belong to,
/// so that the history lists each album once.
///
/// Versions up to 8.0.36 recorded one entry for every chapter opened, and
/// devices still on them keep doing so. An entry names only its chapter;
/// its album is asked from JM, once per album (a chapter's lookup covers
/// its sibling chapters), and what is learnt is kept with the read progress
/// records, which cloud sync carries to the other devices.
class JmHistoryMerger {
  /// Lookups in one pass over a page of history.
  static const int maxLookupsPerPass = 20;

  /// Set by tests; the JM source by default.
  Future<JmAlbum> Function(int chapterId)? albumOfChapter;
  GalleryHistoryModel Function(JmAlbum album)? historyModelOfAlbum;

  bool _running = false;

  /// Lookups that failed in this run of the app, not tried again in it.
  final Set<int> _failed = <int>{};

  /// Looks up the albums of the entries of [rows] not known yet, and writes
  /// each multi-chapter album found as one entry, last read when its newest
  /// chapter entry was. Returns the number of such albums.
  Future<int> resolve(List<GalleryHistoryModel> rows) async {
    if (_running) {
      return 0;
    }
    _running = true;
    try {
      final Set<int> resolved = Set<int>.of((await jmReadingService.knownAlbums()).resolved);
      int merged = 0;
      int lookups = 0;
      for (final GalleryHistoryModel row in rows) {
        if (!row.galleryUrl.isJM) {
          continue;
        }
        final int id = row.galleryUrl.jmChapterId;
        // An entry made for a chapter is titled "album - chapter"; an album
        // with one chapter has its plain name and nothing to merge.
        if (resolved.contains(id) || _failed.contains(id) || !row.title.contains(' - ')) {
          continue;
        }
        if (lookups++ >= maxLookupsPerPass) {
          break;
        }

        final JmAlbum album;
        try {
          album = await (albumOfChapter ?? ehRequest.jmSource.albumOfChapter)(id);
        } catch (e) {
          log.warning('Look up the album of JM chapter $id failed', e);
          _failed.add(id);
          continue;
        }
        final List<int> chapterIds = album.chapters.map((JmChapterRef c) => c.id).toList();
        if (chapterIds.length < 2) {
          await jmReadingService.rememberSingle(id);
          resolved.add(id);
          continue;
        }
        await jmReadingService.remember(albumId: album.id, chapterIds: chapterIds);
        resolved
          ..add(album.id)
          ..addAll(chapterIds);
        await _writeAlbumEntry(album, chapterIds);
        merged++;
        log.info('JM album ${album.id}: ${chapterIds.length} chapters, its history entries are one now');
      }
      return merged;
    } finally {
      _running = false;
    }
  }

  /// The entry of [album] itself, in place of whatever is stored under its
  /// id (the entry of its first chapter), last read just after the newest of
  /// its chapters' entries, so that it replaces older copies on other
  /// devices as well.
  Future<void> _writeAlbumEntry(JmAlbum album, List<int> chapterIds) async {
    final Set<int> gids = <int>{GalleryUrl.jm(album.id).gid, for (final int id in chapterIds) GalleryUrl.jm(id).gid};
    final List<String> times = (await historyService.getRawHistoryByGids(gids)).map((h) => h.lastReadTime).toList();
    if (times.isEmpty) {
      return;
    }
    final String newest = times.reduce((String a, String b) => a.compareTo(b) >= 0 ? a : b);
    final DateTime? parsed = SyncTimeUtil.tryParse(newest);
    await historyService.recordAt(
      (historyModelOfAlbum ?? ehRequest.jmSource.historyModelOfAlbum)(album),
      parsed == null ? newest : SyncTimeUtil.format(parsed.add(const Duration(microseconds: 1))),
    );
  }
}
