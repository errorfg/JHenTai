import 'package:flutter/widgets.dart';
import 'package:photo_view/photo_view.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';


class HorizontalListLayoutState {
  final PhotoViewController photoViewController = PhotoViewController();

  final ItemPositionsListener itemPositionsListener = ItemPositionsListener.create();
  final ItemScrollController itemScrollController = ItemScrollController();
  final ScrollOffsetController scrollOffsetController = ScrollOffsetController();

  /// The list is built anew, its first image at [initialAlignment], when
  /// pages are put before the first.
  Key listKey = UniqueKey();
  double initialAlignment = 0;
}
