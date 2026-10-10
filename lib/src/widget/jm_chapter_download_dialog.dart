import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/widget/eh_wheel_speed_controller.dart';

/// Picks the chapters of a JM album to download; closes with their ids in
/// reading order, or with null when cancelled. Chapters already in the
/// download list cannot be picked. The shortcuts replace the selection:
/// every chapter, or the next 10 or 20 from the current chapter on that are
/// not downloaded yet.
class JmChapterDownloadDialog extends StatefulWidget {
  final List<JmChapterRef> chapters;
  final int currentChapterId;

  /// Whether a chapter is already in the download list; the download
  /// service by default.
  final bool Function(int chapterId)? isDownloaded;

  const JmChapterDownloadDialog({
    super.key,
    required this.chapters,
    required this.currentChapterId,
    this.isDownloaded,
  });

  @override
  State<JmChapterDownloadDialog> createState() => _JmChapterDownloadDialogState();
}

class _JmChapterDownloadDialogState extends State<JmChapterDownloadDialog> {
  static const double _itemExtent = 44;

  late final int _currentIndex = max(
    0,
    widget.chapters.indexWhere((JmChapterRef c) => c.id == widget.currentChapterId),
  );

  late final ScrollController _controller = ScrollController(
    initialScrollOffset: max(0, _currentIndex - 2) * _itemExtent,
  );

  /// Indexes of the chapters picked.
  final Set<int> _selected = <int>{};

  bool _downloaded(int index) {
    final int id = widget.chapters[index].id;
    return widget.isDownloaded?.call(id) ?? galleryDownloadService.containGallery(GalleryUrl.jm(id).gid);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _select(Iterable<int> indexes) {
    setState(() {
      _selected
        ..clear()
        ..addAll(indexes);
    });
  }

  /// The first [count] chapters from the current one on that are not
  /// downloaded yet.
  Iterable<int> _next(int count) => <int>[
        for (int i = _currentIndex; i < widget.chapters.length; i++)
          if (!_downloaded(i)) i,
      ].take(count);

  Iterable<int> get _all => <int>[
        for (int i = 0; i < widget.chapters.length; i++)
          if (!_downloaded(i)) i,
      ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('downloadChapters'.tr),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  key: const Key('jmDownloadAll'),
                  label: Text('selectAll'.tr),
                  onPressed: () => _select(_all),
                ),
                for (final int count in const <int>[10, 20])
                  ActionChip(
                    key: Key('jmDownloadNext$count'),
                    label: Text('nextChapters'.trParams(<String, String>{'count': '$count'})),
                    onPressed: () => _select(_next(count)),
                  ),
                ActionChip(
                  key: const Key('jmDownloadNone'),
                  label: Text('clearSelection'.tr),
                  onPressed: () => _select(const <int>[]),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: min(widget.chapters.length * _itemExtent, MediaQuery.sizeOf(context).height * 0.5),
              child: EHWheelSpeedController(
                controller: _controller,
                child: ListView.builder(
                  controller: _controller,
                  itemExtent: _itemExtent,
                  itemCount: widget.chapters.length,
                  itemBuilder: _buildChapter,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: backRoute, child: Text('cancel'.tr)),
        TextButton(
          key: const Key('jmDownloadConfirm'),
          onPressed: _selected.isEmpty
              ? null
              : () => backRoute(
                    result: (_selected.toList()..sort()).map((int i) => widget.chapters[i].id).toList(),
                  ),
          child: Text('${'download'.tr} (${_selected.length})'),
        ),
      ],
    );
  }

  Widget _buildChapter(BuildContext context, int index) {
    final JmChapterRef chapter = widget.chapters[index];
    final bool downloaded = _downloaded(index);
    return CheckboxListTile(
      key: ValueKey<String>('jmDownloadChapter:${chapter.id}'),
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      value: downloaded || _selected.contains(index),
      onChanged: downloaded
          ? null
          : (bool? value) => setState(() => value == true ? _selected.add(index) : _selected.remove(index)),
      selected: index == _currentIndex,
      title: Text(
        '${index + 1}  ${JmSource.chapterName(chapter)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      secondary: downloaded ? const Icon(Icons.download_done, size: 18) : null,
    );
  }
}
