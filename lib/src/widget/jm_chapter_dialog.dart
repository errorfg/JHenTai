import 'dart:math';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/service/jm_reading_service.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/widget/eh_wheel_speed_controller.dart';

/// Builds with the reading progress of [chapterIds], again whenever read
/// progress changes: reading, marking, or a cloud sync.
class JmChapterProgressBuilder extends StatefulWidget {
  const JmChapterProgressBuilder({
    super.key,
    required this.chapterIds,
    required this.builder,
  });

  final List<int> chapterIds;
  final Widget Function(BuildContext context, Map<int, JmChapterProgress> progress) builder;

  @override
  State<JmChapterProgressBuilder> createState() => _JmChapterProgressBuilderState();
}

class _JmChapterProgressBuilderState extends State<JmChapterProgressBuilder> {
  Map<int, JmChapterProgress> _progress = const <int, JmChapterProgress>{};
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    readProgressService.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(JmChapterProgressBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.chapterIds, widget.chapterIds)) {
      _load();
    }
  }

  @override
  void dispose() {
    readProgressService.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    final Map<int, JmChapterProgress> progress = await jmReadingService.progressOf(widget.chapterIds);
    if (mounted && generation == _generation) {
      setState(() => _progress = progress);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _progress);
}

/// `P15/30`, or `P15` while the page count is unknown.
String jmChapterPageText(JmChapterProgress progress) => progress.pageText;

/// Builds with how far the multi-chapter album [albumId] has been read
/// (null when it is not known as one, or untouched), again whenever read
/// progress changes.
class JmAlbumProgressBuilder extends StatefulWidget {
  const JmAlbumProgressBuilder({
    super.key,
    required this.albumId,
    required this.builder,
  });

  final int albumId;
  final Widget Function(BuildContext context, JmAlbumProgress? progress) builder;

  @override
  State<JmAlbumProgressBuilder> createState() => _JmAlbumProgressBuilderState();
}

class _JmAlbumProgressBuilderState extends State<JmAlbumProgressBuilder> {
  JmAlbumProgress? _progress;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    readProgressService.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(JmAlbumProgressBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.albumId != widget.albumId) {
      _progress = null;
      _load();
    }
  }

  @override
  void dispose() {
    readProgressService.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    final JmAlbumProgress? progress = await jmReadingService.albumProgress(widget.albumId);
    if (mounted && generation == _generation) {
      setState(() => _progress = progress);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _progress);
}

enum _ChapterAction { markRead, markUnread, markPreviousRead }

/// Chapters of a JM album with how far each has been read; tapping one
/// opens it. Albums can have hundreds of chapters, so the list starts at
/// the current one.
class JmChapterDialog extends StatefulWidget {
  final List<JmChapterRef> chapters;
  final int currentChapterId;
  final ValueChanged<JmChapterRef> onTap;

  /// After a chapter was marked read or unread here.
  final VoidCallback? onMarked;

  const JmChapterDialog({
    super.key,
    required this.chapters,
    required this.currentChapterId,
    required this.onTap,
    this.onMarked,
  });

  @override
  State<JmChapterDialog> createState() => _JmChapterDialogState();
}

class _JmChapterDialogState extends State<JmChapterDialog> {
  static const double _itemExtent = 56;

  late final List<int> _chapterIds = widget.chapters.map((JmChapterRef c) => c.id).toList();

  late final ScrollController _controller = ScrollController(
    initialScrollOffset: max(0, _chapterIds.indexOf(widget.currentChapterId) - 2) * _itemExtent,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _act(_ChapterAction action, int index) async {
    switch (action) {
      case _ChapterAction.markRead:
        await jmReadingService.markRead(<int>[_chapterIds[index]]);
      case _ChapterAction.markUnread:
        await jmReadingService.markUnread(<int>[_chapterIds[index]]);
      case _ChapterAction.markPreviousRead:
        await jmReadingService.markRead(_chapterIds.sublist(0, index));
    }
    widget.onMarked?.call();
  }

  @override
  Widget build(BuildContext context) {
    return JmChapterProgressBuilder(
      chapterIds: _chapterIds,
      builder: (BuildContext context, Map<int, JmChapterProgress> progress) {
        final int finished = progress.values.where((JmChapterProgress p) => p.finished).length;
        return AlertDialog(
          title: Text(
            '${'chapters'.tr} (${widget.chapters.length}) · ${'chaptersReadCount'.trParams(<String, String>{'count': '$finished'})}',
          ),
          contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          content: SizedBox(
            width: 460,
            height: min(widget.chapters.length * _itemExtent, MediaQuery.sizeOf(context).height * 0.6),
            child: EHWheelSpeedController(
              controller: _controller,
              child: ListView.builder(
                controller: _controller,
                itemExtent: _itemExtent,
                itemCount: widget.chapters.length,
                itemBuilder: (BuildContext context, int index) =>
                    _buildChapter(context, index, progress[_chapterIds[index]] ?? const JmChapterProgress()),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildChapter(BuildContext context, int index, JmChapterProgress progress) {
    final JmChapterRef chapter = widget.chapters[index];
    // Finished chapters fade, so what is left to read stands out.
    final Color? faded = progress.finished ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4) : null;
    final double? fraction = progress.inProgress ? progress.fraction : null;

    return ListTile(
      key: ValueKey<String>('jmChapter:${chapter.id}'),
      dense: true,
      selected: chapter.id == widget.currentChapterId,
      leading: Text('${index + 1}', style: TextStyle(color: faded)),
      title: Text(
        JmSource.chapterName(chapter),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: faded),
      ),
      subtitle: fraction == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(value: fraction, minHeight: 2),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (progress.finished)
            Icon(Icons.check, size: 18, color: faded)
          else if (progress.inProgress)
            Text(jmChapterPageText(progress), style: Theme.of(context).textTheme.bodySmall),
          if (galleryDownloadService.containGallery(GalleryUrl.jm(chapter.id).gid))
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.download_done, size: 18),
            ),
          PopupMenuButton<_ChapterAction>(
            key: ValueKey<String>('jmChapterMenu:${chapter.id}'),
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (_ChapterAction action) => _act(action, index),
            itemBuilder: (_) => <PopupMenuEntry<_ChapterAction>>[
              if (!progress.finished) PopupMenuItem(value: _ChapterAction.markRead, child: Text('markAsRead'.tr)),
              if (progress.finished || progress.inProgress)
                PopupMenuItem(value: _ChapterAction.markUnread, child: Text('markAsUnread'.tr)),
              if (index > 0)
                PopupMenuItem(value: _ChapterAction.markPreviousRead, child: Text('markPreviousChaptersRead'.tr)),
            ],
          ),
        ],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      onTap: () {
        backRoute();
        widget.onTap(chapter);
      },
    );
  }
}
