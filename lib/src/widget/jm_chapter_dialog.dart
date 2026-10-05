import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/widget/eh_wheel_speed_controller.dart';

/// Chapters of a JM album; tapping one opens it. Albums can have hundreds
/// of chapters, so the list starts at the current one.
class JmChapterDialog extends StatefulWidget {
  final List<JmChapterRef> chapters;
  final int currentChapterId;
  final ValueChanged<JmChapterRef> onTap;

  const JmChapterDialog({
    super.key,
    required this.chapters,
    required this.currentChapterId,
    required this.onTap,
  });

  @override
  State<JmChapterDialog> createState() => _JmChapterDialogState();
}

class _JmChapterDialogState extends State<JmChapterDialog> {
  static const double _itemExtent = 48;

  late final ScrollController _controller = ScrollController(
    initialScrollOffset:
        max(0, widget.chapters.indexWhere((JmChapterRef c) => c.id == widget.currentChapterId) - 2) * _itemExtent,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${'chapters'.tr} (${widget.chapters.length})'),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      content: SizedBox(
        width: 420,
        height: min(widget.chapters.length * _itemExtent, MediaQuery.sizeOf(context).height * 0.6),
        child: EHWheelSpeedController(
          controller: _controller,
          child: ListView.builder(
            controller: _controller,
            itemExtent: _itemExtent,
            itemCount: widget.chapters.length,
            itemBuilder: (_, int index) {
              JmChapterRef chapter = widget.chapters[index];
              return ListTile(
                dense: true,
                selected: chapter.id == widget.currentChapterId,
                leading: Text('${index + 1}'),
                title: Text(JmSource.chapterName(chapter), maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: galleryDownloadService.containGallery(GalleryUrl.jm(chapter.id).gid)
                    ? const Icon(Icons.download_done, size: 18)
                    : null,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                onTap: () {
                  backRoute();
                  widget.onTap(chapter);
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
