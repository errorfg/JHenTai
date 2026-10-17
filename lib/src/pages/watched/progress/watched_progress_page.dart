import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../service/watched_progress_service.dart';
import '../../../widget/eh_image.dart';
import '../watched_page_logic.dart';

/// How far the watched list has been read, as a timeline: the stretches
/// scrolled through (dark) and what lies between them (grey), each stretch
/// with the covers of the galleries at its ends; where the list was left,
/// and the bookmarks, where they are in the list. A cover opens the list at
/// its gallery.
class WatchedProgressPage extends StatelessWidget {
  const WatchedProgressPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('watchedProgress'.tr)),
      body: GetBuilder<WatchedProgressService>(
        id: WatchedProgressService.updateId,
        builder: (_) {
          final List<WatchedReadRange> ranges = watchedProgressService.ranges;
          if (ranges.isEmpty && watchedProgressService.bookmarks.isEmpty) {
            return const _Empty();
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
            children: [
              _Summary(ranges: ranges),
              if (watchedProgressService.lastPosition != null) _LastPosition(gallery: watchedProgressService.lastPosition!),
              const SizedBox(height: 12),
              ..._timeline(context, ranges),
            ],
          );
        },
      ),
    );
  }

  /// From the top of the list down: an open end, then each stretch read
  /// with the unread part below it.
  List<Widget> _timeline(BuildContext context, List<WatchedReadRange> ranges) {
    final List<WatchedGallery> marks = watchedProgressService.bookmarks;
    List<WatchedGallery> marksIn(bool Function(int gid) inside) => marks.where((WatchedGallery b) => inside(b.gid)).toList();

    final List<Widget> nodes = <Widget>[
      _TopNode(bookmarks: marksIn((int gid) => ranges.isEmpty || gid > ranges.first.newest.gid)),
    ];
    for (int i = 0; i < ranges.length; i++) {
      final WatchedReadRange range = ranges[i];
      final WatchedReadRange? below = i + 1 < ranges.length ? ranges[i + 1] : null;
      nodes
        ..add(_RangeNode(
          key: Key('watchedRange-${range.newest.gid}'),
          range: range,
          bookmarks: marksIn((int gid) => gid <= range.newest.gid && gid >= range.oldest.gid),
        ))
        ..add(_GapNode(
          key: Key('watchedGap-${range.oldest.gid}'),
          above: range,
          below: below,
          bookmarks: marksIn((int gid) => gid < range.oldest.gid && (below == null || gid > below.newest.gid)),
        ));
    }
    return nodes;
  }
}

/// Opens the watched list at [gid], back on its page.
void _openAt(int gid) {
  Get.back();
  (Get.isRegistered<WatchedPageLogic>() ? Get.find<WatchedPageLogic>() : Get.put(WatchedPageLogic(), permanent: true)).jumpToGallery(gid);
}

/// `09-25` this year, `2025-12-31` before.
String _shortDay(String day) => day.startsWith('${DateTime.now().year}-') ? day.substring(5) : day;

String _span(WatchedGallery newer, WatchedGallery older) =>
    newer.day == older.day ? _shortDay(newer.day) : '${_shortDay(newer.day)} → ${_shortDay(older.day)}';

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timeline, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text('watchedProgressEmpty'.tr, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.ranges});

  final List<WatchedReadRange> ranges;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int read = ranges.fold<int>(0, (int sum, WatchedReadRange r) => sum + r.gallerys.length);
    return Card(
      elevation: 0,
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Text('$read', style: theme.textTheme.headlineMedium?.copyWith(color: theme.colorScheme.onPrimaryContainer, fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('watchedReadCount'.tr, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
                  if (ranges.isNotEmpty)
                    Text(
                      'watchedRangeSummary'.trParams(<String, String>{
                        'ranges': '${ranges.length}',
                        'oldest': _shortDay(ranges.last.oldest.day),
                      }),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LastPosition extends StatelessWidget {
  const _LastPosition({required this.gallery});

  final WatchedGallery gallery;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      key: const Key('watchedLastPosition'),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openAt(gallery.gid),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              _Cover(gallery: gallery, width: 56, height: 78),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('watchedLastPosition'.tr, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
                    const SizedBox(height: 2),
                    Text(gallery.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 2),
                    Text(gallery.publishTime, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(onPressed: () => _openAt(gallery.gid), child: Text('watchedContinue'.tr)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row of the timeline: the rail on the left ([dark] for read, else
/// grey; [dot] where something is), [child] on the right.
class _Rail extends StatelessWidget {
  const _Rail({required this.dark, required this.child, this.dot = false});

  final bool dark;
  final bool dot;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                Center(
                  child: Container(
                    width: dark ? 6 : 2,
                    decoration: BoxDecoration(
                      color: dark ? colors.primary : colors.outlineVariant,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
                if (dot)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: dark ? colors.primary : colors.surface,
                        shape: BoxShape.circle,
                        border: Border.all(color: dark ? colors.primary : colors.outline, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _TopNode extends StatelessWidget {
  const _TopNode({required this.bookmarks});

  final List<WatchedGallery> bookmarks;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return _Rail(
      dark: false,
      dot: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('watchedNewest'.tr, style: theme.textTheme.titleSmall),
            Text('watchedNewestHint'.tr, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
            for (final WatchedGallery bookmark in bookmarks) _BookmarkRow(gallery: bookmark),
          ],
        ),
      ),
    );
  }
}

class _RangeNode extends StatelessWidget {
  const _RangeNode({super.key, required this.range, required this.bookmarks});

  final WatchedReadRange range;
  final List<WatchedGallery> bookmarks;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final WatchedGallery? last = watchedProgressService.lastPosition;
    final bool leftHere = last != null && last.gid <= range.newest.gid && last.gid >= range.oldest.gid;
    return _Rail(
      dark: true,
      dot: true,
      child: Card(
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 4),
        color: theme.colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(_span(range.newest, range.oldest), style: theme.textTheme.titleSmall)),
                  if (leftHere)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.place, size: 18, color: theme.colorScheme.primary),
                    ),
                  _Chip(text: 'watchedRangeCount'.trParams(<String, String>{'count': '${range.gallerys.length}'})),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _EndTile(gallery: range.newest, label: 'watchedRangeTop'.tr)),
                  if (range.gallerys.length > 1) ...[
                    const SizedBox(width: 8),
                    Expanded(child: _EndTile(gallery: range.oldest, label: 'watchedRangeBottom'.tr)),
                  ],
                ],
              ),
              for (final WatchedGallery bookmark in bookmarks) _BookmarkRow(gallery: bookmark),
            ],
          ),
        ),
      ),
    );
  }
}

class _GapNode extends StatelessWidget {
  const _GapNode({super.key, required this.above, required this.below, required this.bookmarks});

  final WatchedReadRange above;
  final WatchedReadRange? below;
  final List<WatchedGallery> bookmarks;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String span = below == null
        ? 'watchedGapOlder'.trParams(<String, String>{'day': _shortDay(above.oldest.day)})
        : 'watchedGapBetween'.trParams(<String, String>{'span': _span(above.oldest, below!.newest)});
    return _Rail(
      dark: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(span, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              key: Key('watchedContinueBelow-${above.oldest.gid}'),
              icon: const Icon(Icons.south, size: 18),
              label: Text('watchedContinueBelow'.tr),
              onPressed: () => _openAt(above.oldest.gid),
            ),
            for (final WatchedGallery bookmark in bookmarks) _BookmarkRow(gallery: bookmark),
          ],
        ),
      ),
    );
  }
}

/// The gallery at one end of a stretch.
class _EndTile extends StatelessWidget {
  const _EndTile({required this.gallery, required this.label});

  final WatchedGallery gallery;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      key: Key('watchedEnd-${gallery.gid}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => _openAt(gallery.gid),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Cover(gallery: gallery, width: 46, height: 64),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
                Text(gallery.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                Text(gallery.publishTime, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BookmarkRow extends StatelessWidget {
  const _BookmarkRow({required this.gallery});

  final WatchedGallery gallery;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: Key('watchedBookmark-${gallery.gid}'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => _openAt(gallery.gid),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                Icon(Icons.bookmark, size: 18, color: theme.colorScheme.onTertiaryContainer),
                const SizedBox(width: 6),
                _Cover(gallery: gallery, width: 32, height: 44),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(gallery.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onTertiaryContainer)),
                      Text(gallery.publishTime, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onTertiaryContainer)),
                    ],
                  ),
                ),
                IconButton(
                  key: Key('watchedBookmarkRemove-${gallery.gid}'),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'removeWatchedBookmark'.tr,
                  icon: Icon(Icons.close, size: 18, color: theme.colorScheme.onTertiaryContainer),
                  onPressed: () => watchedProgressService.removeBookmark(gallery.gid),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: colors.primary, borderRadius: BorderRadius.circular(10)),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.onPrimary)),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.gallery, required this.width, required this.height});

  final WatchedGallery gallery;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return EHImage(
      galleryImage: gallery.cover,
      containerWidth: width,
      containerHeight: height,
      containerColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
      fit: BoxFit.cover,
    );
  }
}
