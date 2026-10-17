import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../model/gallery.dart';
import '../../service/watched_progress_service.dart';

/// A card of the watched list: tells how much of it is on screen, is shown
/// faded when it was read before it was built, and carries a ribbon while
/// it is bookmarked.
///
/// The fade is decided when the card is built, so a card does not fade
/// while it is being looked at; it shows faded the next time it comes into
/// view.
class WatchedCard extends StatefulWidget {
  const WatchedCard({super.key, required this.gallery, required this.onVisibilityChanged, required this.child});

  final Gallery gallery;
  final void Function(Gallery gallery, double visibleFraction) onVisibilityChanged;
  final Widget child;

  static const double readOpacity = 0.45;

  @override
  State<WatchedCard> createState() => _WatchedCardState();
}

class _WatchedCardState extends State<WatchedCard> {
  late final bool _wasRead = watchedProgressService.isRead(widget.gallery.gid);

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: Key('watched-card-${widget.gallery.gid}'),
      onVisibilityChanged: (VisibilityInfo info) => widget.onVisibilityChanged(widget.gallery, info.visibleFraction),
      child: Stack(
        children: [
          Opacity(opacity: _wasRead ? WatchedCard.readOpacity : 1, child: widget.child),
          GetBuilder<WatchedProgressService>(
            id: WatchedProgressService.updateId,
            builder: (_) => watchedProgressService.isBookmarked(widget.gallery.gid)
                ? Positioned(
                    top: 0,
                    right: 14,
                    child: Icon(Icons.bookmark, size: 22, color: Theme.of(context).colorScheme.primary),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
