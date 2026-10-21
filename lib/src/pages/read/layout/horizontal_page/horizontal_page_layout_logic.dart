import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/setting/read_setting.dart';

import '../../spread_pages.dart';
import '../base/base_layout_logic.dart';
import 'horizontal_page_layout_state.dart';

class HorizontalPageLayoutLogic extends BaseLayoutLogic {
  HorizontalPageLayoutState state = HorizontalPageLayoutState();

  late PageController pageController;

  /// Done once [pageController] is made: after the wide images found in
  /// earlier readings are read, so that a book opens on the right page.
  final Completer<void> initCompleter = Completer<void>();

  /// The pages: one per image, two for an image that is split.
  PageParts parts = PageParts.unsplit(0);

  @override
  void onInit() {
    super.onInit();
    _init();
  }

  Future<void> _init() async {
    await readPageState.spreadPages.loaded;
    parts = _computeParts();
    pageController = PageController(initialPage: parts.firstPageOf(readPageState.currentImageIndex));

    /// record reading progress and sync thumbnails list index
    pageController.addListener(_readProgressListener);
    initCompleter.complete();
  }

  @override
  bool get splitsWideImages => true;

  /// A half is a page on screen, whole; fitting the width, it scrolls as a
  /// page does there.
  @override
  Size fitHalf(Size half) => readPageLogic.isInFitWidthReadDirection
      ? super.fitHalf(half)
      : applyBoxFit(BoxFit.contain, half, readPageState.displayRegionSize).destination;

  List<bool> _splitImages() => <bool>[for (int i = 0; i < readPageState.pageCount; i++) isSplit(i)];

  PageParts _computeParts() => PageParts(_splitImages());

  int get _currentPage => pageController.hasClients ? pageController.page!.toInt() : parts.firstPageOf(readPageState.currentImageIndex);

  /// The layout is built for the reading direction: wide images found
  /// while another layout was shown, or a change of the setting, change the
  /// pages, and the image being read stays. Shown again after another
  /// layout, it opens on the image read there: its controller, without a
  /// view, would open on the page it was made with.
  void syncParts() {
    if (!initCompleter.isCompleted) {
      return;
    }
    final List<bool> split = _splitImages();
    final bool changed = !parts.splitAs(split);
    if (changed) {
      parts = PageParts(split);
    }
    final int target = parts.firstPageOf(readPageState.currentImageIndex);
    if (!pageController.hasClients) {
      if (pageController.initialPage != target) {
        pageController
          ..removeListener(_readProgressListener)
          ..dispose();
        pageController = PageController(initialPage: target)..addListener(_readProgressListener);
      }
      return;
    }
    if (!changed) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (pageController.hasClients && _currentPage != target) {
        pageController.jumpToPage(target);
      }
    });
  }

  /// Lays the pages out again, staying on the part of the image being read.
  void _relayout() {
    if (!initCompleter.isCompleted) {
      return;
    }
    final int page = _currentPage;
    final int image = parts.imageOf(page);
    final ImagePart part = parts.partOf(page);
    parts = _computeParts();
    updateSafely([BaseLayoutLogic.pageId]);
    final int target = parts.pageOf(image, part);
    if (target != page) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (pageController.hasClients) {
          pageController.jumpToPage(target);
        }
      });
    }
  }

  @override
  void onSpreadFound(int index) {
    if (isSplit(index)) {
      _relayout();
    }
  }

  @override
  void onSplitSettingChanged() => _relayout();

  @override
  void onPagesAppended() {
    if (initCompleter.isCompleted) {
      parts = _computeParts();
    }
    super.onPagesAppended();
  }

  @override
  void toLeft() {
    if (readPageLogic.isInRight2LeftDirection) {
      toNext();
    } else {
      toPrev();
    }
  }

  @override
  void toRight() {
    if (readPageLogic.isInRight2LeftDirection) {
      toPrev();
    } else {
      toNext();
    }
  }

  @override
  void toPrev() => _toPage(_currentPage - 1);

  @override
  void toNext() => _toPage(_currentPage + 1);

  void _toPage(int page) {
    if (!initCompleter.isCompleted || !pageController.hasClients) {
      return;
    }
    final int target = page.clamp(0, parts.length - 1);
    if (readSetting.enablePageTurnAnime.isFalse) {
      pageController.jumpToPage(target);
    } else {
      pageController.animateToPage(target, duration: const Duration(milliseconds: 200), curve: Curves.ease);
    }
    readPageLogic.update([readPageLogic.sliderId]);
  }

  @override
  Future<void> jump2ImageIndex(int imageIndex) async {
    await initCompleter.future;
    pageController.jumpToPage(parts.firstPageOf(imageIndex));
    super.jump2ImageIndex(imageIndex);
  }

  @override
  Future<void> scroll2ImageIndex(int imageIndex, [Duration? duration]) async {
    await initCompleter.future;
    pageController.animateToPage(
      parts.firstPageOf(imageIndex),
      duration: duration ?? const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
    super.scroll2ImageIndex(imageIndex, duration);
  }

  @override
  void enterAutoMode() {
    _enterAutoModeByTurnPage();
  }

  void _enterAutoModeByTurnPage() {
    readPageLogic.toggleMenu();

    autoModeTimer = Timer.periodic(
      Duration(milliseconds: (readSetting.autoModeInterval.value * 1000).toInt()),
      (_) {
        /// changed read setting
        if (!readPageLogic.isInSinglePageReadDirection) {
          Get.engine.addPostFrameCallback((_) {
            readPageLogic.closeAutoMode();
          });
          autoModeTimer?.cancel();
          return;
        }

        /// stop when at last
        if (_currentPage >= parts.length - 1) {
          Get.engine.addPostFrameCallback((_) {
            readPageLogic.closeAutoMode();
          });
          autoModeTimer?.cancel();
          return;
        }

        toNext();
      },
    );
  }

  void _readProgressListener() {
    final int image = parts.imageOf(pageController.page!.toInt());
    readPageLogic.recordReadProgress(image);
    readPageLogic.syncThumbnails(image);
  }
}
