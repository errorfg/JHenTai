import 'dart:async';

import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/sync_service.dart';

/// Where the reader stands in one chapter of a series.
class SeriesChapterProgress {
  const SeriesChapterProgress({
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

/// How far a multi-chapter series has been read: its highest-numbered
/// chapter with a record, the way a single gallery's progress is the page it
/// is at.
class SeriesProgress {
  const SeriesProgress({
    required this.chapterCount,
    required this.furthestIndex,
    required this.furthest,
  });

  final int chapterCount;

  /// Position of the furthest chapter among the album's chapters, from 0.
  final int furthestIndex;
  final SeriesChapterProgress furthest;

  double get fraction => ((furthestIndex + 1) / chapterCount).clamp(0, 1).toDouble();

  /// `143/237`, with the page while that chapter is being read:
  /// `143/237 · P15/30`.
  String get positionText {
    final String chapters = '${furthestIndex + 1}/$chapterCount';
    return furthest.inProgress ? '$chapters · ${furthest.pageText}' : chapters;
  }
}

/// Reading state of multi-chapter series (JM albums, Tachiyomi manga), kept
/// as read progress records so that cloud sync carries it like any other
/// progress. Each source has its key [prefix]:
///
/// - a chapter's own record (its gid) holds the page index, `''` for unread
///   or [markedReadValue];
/// - `<prefix>:pages:<chapter id>` holds the chapter's page count;
/// - `<prefix>:album:<series id>` holds the chapter last opened in the
///   reader, which lets the details page open that chapter straight away;
/// - `<prefix>:chapters:<series id>` holds the chapter ids of a
///   multi-chapter series in reading order, so that lists and the history
///   show the series as one entry with its progress, on every device,
///   without asking the site.
class SeriesReadingService {
  SeriesReadingService({required this.prefix, required this.gidOf});

  final String prefix;

  /// The gid of a chapter id; a chapter's progress is kept under its gid.
  final int Function(int chapterId) gidOf;

  /// A chapter marked read. Code that reads a chapter's progress as a page
  /// index takes it as page 0, which is where a re-read starts.
  static const String markedReadValue = 'read';

  String keyOfChapter(int chapterId) => gidOf(chapterId).toString();

  String keyOfPages(int chapterId) => '$prefix:pages:$chapterId';

  String keyOfSeries(int albumId) => '$prefix:album:$albumId';

  String get _chaptersKeyPrefix => '$prefix:chapters:';

  String keyOfChapters(int albumId) => '$_chaptersKeyPrefix$albumId';

  static List<int> _chapterIds(String? value) => (value ?? '')
      .split(',')
      .map((String id) => int.tryParse(id))
      .whereType<int>()
      .toList();

  /// Chapters of [albumId] in reading order, once it has been opened on
  /// some device and has more than one; empty otherwise.
  Future<List<int>> chaptersOf(int albumId) async {
    final String key = keyOfChapters(albumId);
    return _chapterIds((await readProgressService.getProgressRecords(<String>{key}))[key]?.value);
  }

  /// [chaptersOf] of each of [albumIds], read at once.
  Future<Map<int, List<int>>> chaptersOfAll(Iterable<int> albumIds) async {
    final Map<String, ReadProgressRecord> records =
        await readProgressService.getProgressRecords(<String>{for (final int id in albumIds) keyOfChapters(id)});
    return <int, List<int>>{for (final int id in albumIds) id: _chapterIds(records[keyOfChapters(id)]?.value)};
  }

  /// How far the multi-chapter album [albumId] has been read; null when it
  /// is not known as one, or nothing of it has a record.
  Future<SeriesProgress?> albumProgress(int albumId) async {
    final List<int> chapterIds = await chaptersOf(albumId);
    if (chapterIds.length < 2) {
      return null;
    }
    final Map<int, SeriesChapterProgress> progress = await progressOf(chapterIds);
    for (int i = chapterIds.length - 1; i >= 0; i--) {
      final SeriesChapterProgress chapter = progress[chapterIds[i]]!;
      if (chapter.hasRecord) {
        return SeriesProgress(chapterCount: chapterIds.length, furthestIndex: i, furthest: chapter);
      }
    }
    return null;
  }

  /// What is known about the series of this source: [albumOf] gives the album of every
  /// chapter of a multi-chapter album (the album's own id included);
  /// [resolved] holds every id looked up, single-chapter albums too.
  Future<({Map<int, int> albumOf, Set<int> resolved})> knownAlbums() async {
    final List<LocalConfig> rows = await localConfigService.readBySubKeyPrefix(
      configKey: ConfigEnum.readIndexRecord,
      prefix: _chaptersKeyPrefix,
    );
    final Map<int, int> albumOf = <int, int>{};
    final Set<int> resolved = <int>{};
    for (final LocalConfig row in rows) {
      final int? albumId = int.tryParse(row.subConfigKey.substring(_chaptersKeyPrefix.length));
      final List<int> chapterIds = _chapterIds(row.value);
      if (albumId == null) {
        continue;
      }
      resolved
        ..add(albumId)
        ..addAll(chapterIds);
      if (chapterIds.length > 1) {
        for (final int chapterId in chapterIds) {
          albumOf[chapterId] = albumId;
        }
        albumOf[albumId] = albumId;
      }
    }
    return (albumOf: albumOf, resolved: resolved);
  }

  /// Keeps that [albumId] has one chapter only, so it is not looked up
  /// again.
  Future<void> rememberSingle(int albumId) async {
    final String key = keyOfChapters(albumId);
    if ((await readProgressService.getProgressRecords(<String>{key}))[key] == null) {
      await readProgressService.writeProgressValues(<String, String>{key: '$albumId'});
    }
  }

  Future<Map<int, SeriesChapterProgress>> progressOf(List<int> chapterIds) async {
    final Map<String, ReadProgressRecord> records = await readProgressService.getProgressRecords(<String>{
      for (final int id in chapterIds) ...<String>[keyOfChapter(id), keyOfPages(id)],
    });
    return <int, SeriesChapterProgress>{
      for (final int id in chapterIds) id: _progress(records[keyOfChapter(id)], records[keyOfPages(id)]),
    };
  }

  static SeriesChapterProgress _progress(ReadProgressRecord? position, ReadProgressRecord? pages) {
    final int? pageCount = int.tryParse(pages?.value ?? '');
    final String value = position?.value ?? '';
    if (value == markedReadValue) {
      return SeriesChapterProgress(pageCount: pageCount, markedRead: true);
    }
    final int? pageIndex = int.tryParse(value);
    return SeriesChapterProgress(
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
  static int resumeChapter(List<int> chapterIds, Map<int, SeriesChapterProgress> progress) {
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
    final String key = keyOfSeries(albumId);
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
        if (entry.value > 0) keyOfPages(entry.key): '${entry.value}',
      if (openedChapterId != null) keyOfSeries(albumId): '$openedChapterId',
      if (chapterIds != null && chapterIds.length > 1) keyOfChapters(albumId): chapterIds.join(','),
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
    final Map<int, SeriesChapterProgress> progress = await progressOf(chapterIds);
    await _write(<String, String>{
      for (final int id in chapterIds)
        if (!progress[id]!.finished) keyOfChapter(id): markedReadValue,
    });
  }

  /// Marks [chapterIds] unread; chapters without progress are left alone.
  Future<void> markUnread(List<int> chapterIds) async {
    final Map<int, SeriesChapterProgress> progress = await progressOf(chapterIds);
    await _write(<String, String>{
      for (final int id in chapterIds)
        if (progress[id]!.markedRead || progress[id]!.pageIndex != null) keyOfChapter(id): '',
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
