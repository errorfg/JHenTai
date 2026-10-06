import 'dart:async';

import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/sync_service.dart';

JmReadingService jmReadingService = JmReadingService();

/// Where the reader stands in one chapter of a JM album.
class JmChapterProgress {
  const JmChapterProgress({
    this.pageIndex,
    this.pageCount,
    this.markedRead = false,
    this.readAt,
  });

  /// Page last read, from 0; null when the chapter has not been read or
  /// was marked.
  final int? pageIndex;

  /// Null until the chapter has been opened on some device.
  final int? pageCount;

  final bool markedRead;

  /// When [pageIndex] was saved, as stored: fixed-width UTC ISO 8601, so it
  /// orders as text.
  final String? readAt;

  /// Marked read, or read up to the last page (which the reader saves once
  /// the end of the chapter is on screen).
  bool get finished => markedRead || (pageIndex != null && pageCount != null && pageIndex! >= pageCount! - 1);

  bool get inProgress => !finished && pageIndex != null;

  /// Read, being read or marked: anything but untouched.
  bool get hasRecord => markedRead || pageIndex != null;

  /// Share of the chapter read, when its page count is known.
  double? get fraction {
    if (pageIndex == null || pageCount == null || pageCount! <= 0) {
      return null;
    }
    return ((pageIndex! + 1) / pageCount!).clamp(0, 1).toDouble();
  }

  /// `P15/30`, or `P15` while the page count is unknown.
  String get pageText {
    final int page = (pageIndex ?? 0) + 1;
    return pageCount == null ? 'P$page' : 'P$page/$pageCount';
  }
}

/// How far a multi-chapter album has been read: its highest-numbered chapter
/// with a record, the way a single gallery's progress is the page it is at.
class JmAlbumProgress {
  const JmAlbumProgress({
    required this.chapterCount,
    required this.furthestIndex,
    required this.furthest,
  });

  final int chapterCount;

  /// Position of the furthest chapter among the album's chapters, from 0.
  final int furthestIndex;
  final JmChapterProgress furthest;

  double get fraction => ((furthestIndex + 1) / chapterCount).clamp(0, 1).toDouble();

  /// `143/237`, with the page while that chapter is being read:
  /// `143/237 · P15/30`.
  String get positionText {
    final String chapters = '${furthestIndex + 1}/$chapterCount';
    return furthest.inProgress ? '$chapters · ${furthest.pageText}' : chapters;
  }
}

/// Reading state of multi-chapter JM albums, kept as read progress records
/// so that cloud sync carries it like any other progress:
///
/// - a chapter's own record (its gid) holds the page index, `''` for unread
///   or [markedReadValue];
/// - `jm:pages:<chapter id>` holds the chapter's page count;
/// - `jm:album:<album id>` holds the chapter last opened in the reader,
///   which lets the details page request that chapter straight away;
/// - `jm:chapters:<album id>` holds the chapter ids of a multi-chapter album
///   in reading order, so that lists and the history show the album as one
///   entry with its progress, on every device, without asking JM.
class JmReadingService {
  /// A chapter marked read. Code that reads a chapter's progress as a page
  /// index takes it as page 0, which is where a re-read starts.
  static const String markedReadValue = 'read';

  static String chapterKey(int chapterId) => GalleryUrl.jm(chapterId).gid.toString();

  static String pagesKey(int chapterId) => 'jm:pages:$chapterId';

  static String albumKey(int albumId) => 'jm:album:$albumId';

  static const String _chaptersKeyPrefix = 'jm:chapters:';

  static String chaptersKey(int albumId) => '$_chaptersKeyPrefix$albumId';

  static List<int> _chapterIds(String? value) => (value ?? '')
      .split(',')
      .map((String id) => int.tryParse(id))
      .whereType<int>()
      .toList();

  /// Chapters of [albumId] in reading order, once it has been opened on
  /// some device and has more than one; empty otherwise.
  Future<List<int>> chaptersOf(int albumId) async {
    final String key = chaptersKey(albumId);
    return _chapterIds((await readProgressService.getProgressRecords(<String>{key}))[key]?.value);
  }

  /// How far the multi-chapter album [albumId] has been read; null when it
  /// is not known as one, or nothing of it has a record.
  Future<JmAlbumProgress?> albumProgress(int albumId) async {
    final List<int> chapterIds = await chaptersOf(albumId);
    if (chapterIds.length < 2) {
      return null;
    }
    final Map<int, JmChapterProgress> progress = await progressOf(chapterIds);
    for (int i = chapterIds.length - 1; i >= 0; i--) {
      final JmChapterProgress chapter = progress[chapterIds[i]]!;
      if (chapter.hasRecord) {
        return JmAlbumProgress(chapterCount: chapterIds.length, furthestIndex: i, furthest: chapter);
      }
    }
    return null;
  }

  /// Gids of the chapters of every known multi-chapter album, the album's
  /// own (its first chapter's) left out: history entries made per chapter
  /// by earlier versions, now shown as their album's one entry.
  Future<Set<int>> chapterGidsOfKnownAlbums() async {
    final List<LocalConfig> rows = await localConfigService.readBySubKeyPrefix(
      configKey: ConfigEnum.readIndexRecord,
      prefix: _chaptersKeyPrefix,
    );
    final Set<int> gids = <int>{};
    for (final LocalConfig row in rows) {
      final int? albumId = int.tryParse(row.subConfigKey.substring(_chaptersKeyPrefix.length));
      for (final int chapterId in _chapterIds(row.value)) {
        if (chapterId != albumId) {
          gids.add(GalleryUrl.jm(chapterId).gid);
        }
      }
    }
    return gids;
  }

  Future<Map<int, JmChapterProgress>> progressOf(List<int> chapterIds) async {
    final Map<String, ReadProgressRecord> records = await readProgressService.getProgressRecords(<String>{
      for (final int id in chapterIds) ...<String>[chapterKey(id), pagesKey(id)],
    });
    return <int, JmChapterProgress>{
      for (final int id in chapterIds) id: _progress(records[chapterKey(id)], records[pagesKey(id)]),
    };
  }

  static JmChapterProgress _progress(ReadProgressRecord? position, ReadProgressRecord? pages) {
    final int? pageCount = int.tryParse(pages?.value ?? '');
    final String value = position?.value ?? '';
    if (value == markedReadValue) {
      return JmChapterProgress(pageCount: pageCount, markedRead: true);
    }
    final int? pageIndex = int.tryParse(value);
    return JmChapterProgress(
      pageIndex: pageIndex,
      pageCount: pageCount,
      readAt: pageIndex == null ? null : position!.utime,
    );
  }

  /// The chapter to continue with, of [chapterIds] in reading order.
  ///
  /// The chapter read most recently, or the first unfinished one after it
  /// once it is finished. Marking is not reading: without any chapter read,
  /// the first unfinished chapter, so that marking the first 142 chapters
  /// read leads to the 143rd.
  static int resumeChapter(List<int> chapterIds, Map<int, JmChapterProgress> progress) {
    bool finished(int index) => progress[chapterIds[index]]?.finished ?? false;

    int? last;
    String lastReadAt = '';
    for (int i = 0; i < chapterIds.length; i++) {
      final String? readAt = progress[chapterIds[i]]?.readAt;
      if (readAt != null && readAt.compareTo(lastReadAt) >= 0) {
        last = i;
        lastReadAt = readAt;
      }
    }

    if (last != null) {
      if (!finished(last)) {
        return chapterIds[last];
      }
      for (int i = last + 1; i < chapterIds.length; i++) {
        if (!finished(i)) {
          return chapterIds[i];
        }
      }
      return chapterIds[last];
    }
    for (int i = 0; i < chapterIds.length; i++) {
      if (!finished(i)) {
        return chapterIds[i];
      }
    }
    return chapterIds.last;
  }

  /// The chapter of [albumId] last opened in the reader, if any.
  Future<int?> lastOpenedChapter(int albumId) async {
    final String key = albumKey(albumId);
    return int.tryParse((await readProgressService.getProgressRecords(<String>{key}))[key]?.value ?? '');
  }

  /// Keeps the page counts of chapters of [albumId] and, when given, the
  /// chapter opened in the reader and the album's chapters in reading
  /// order. Values already stored are not written again, so nothing new
  /// goes to the cloud.
  Future<void> remember({
    required int albumId,
    Map<int, int> pageCounts = const <int, int>{},
    int? openedChapterId,
    List<int>? chapterIds,
  }) async {
    final Map<String, String> wanted = <String, String>{
      for (final MapEntry<int, int> entry in pageCounts.entries)
        if (entry.value > 0) pagesKey(entry.key): '${entry.value}',
      if (openedChapterId != null) albumKey(albumId): '$openedChapterId',
      if (chapterIds != null && chapterIds.length > 1) chaptersKey(albumId): chapterIds.join(','),
    };
    if (wanted.isEmpty) {
      return;
    }
    final Map<String, ReadProgressRecord> stored = await readProgressService.getProgressRecords(wanted.keys.toSet());
    final Map<String, String> changes = <String, String>{
      for (final MapEntry<String, String> entry in wanted.entries)
        if (stored[entry.key]?.value != entry.value) entry.key: entry.value,
    };
    if (changes.isNotEmpty) {
      await readProgressService.writeProgressValues(changes);
    }
  }

  /// Marks [chapterIds] read, all at one time; chapters already finished
  /// keep their record.
  Future<void> markRead(List<int> chapterIds) async {
    final Map<int, JmChapterProgress> progress = await progressOf(chapterIds);
    await _write(<String, String>{
      for (final int id in chapterIds)
        if (!progress[id]!.finished) chapterKey(id): markedReadValue,
    });
  }

  /// Marks [chapterIds] unread; chapters without progress are left alone.
  Future<void> markUnread(List<int> chapterIds) async {
    final Map<int, JmChapterProgress> progress = await progressOf(chapterIds);
    await _write(<String, String>{
      for (final int id in chapterIds)
        if (progress[id]!.markedRead || progress[id]!.pageIndex != null) chapterKey(id): '',
    });
  }

  Future<void> _write(Map<String, String> values) async {
    if (values.isEmpty) {
      return;
    }
    await readProgressService.writeProgressValues(values);
    unawaited(syncService.syncReadProgress());
  }
}
