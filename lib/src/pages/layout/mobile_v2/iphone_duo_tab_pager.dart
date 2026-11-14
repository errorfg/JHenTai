import 'package:flutter/material.dart';
import 'package:jhentai/src/model/tab_bar_icon.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2_logic.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2_state.dart';

/// The home's pages on iPhone Duo's inner display held upright, where the tabs
/// lie side by side along the top: a swipe across the page brings in the page
/// of the tab beside it, under the finger. Tabs that open a route of their own
/// are passed over.
class IPhoneDuoTabPager extends StatefulWidget {
  const IPhoneDuoTabPager({super.key, required this.logic, required this.state});

  final MobileLayoutPageV2Logic logic;
  final MobileLayoutPageV2State state;

  @override
  State<IPhoneDuoTabPager> createState() => _IPhoneDuoTabPagerState();
}

class _IPhoneDuoTabPagerState extends State<IPhoneDuoTabPager> with SingleTickerProviderStateMixin {
  /// Past this speed along the swipe, in logical pixels a second, letting go
  /// switches however short the swipe was.
  static const double _flingVelocity = 365;

  /// How far the selected tab's page is from its place, in widths. Below zero
  /// the next tab's page shows after it; above zero the previous one's before it.
  late final AnimationController _offset = AnimationController.unbounded(vsync: this);

  List<TabBarIcon> get _icons => widget.state.icons;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  /// The nearest tab on that side whose page shows in place.
  int? _neighbour(int step) {
    for (int index = widget.state.selectedDrawerTabIndex + step; index >= 0 && index < _icons.length; index += step) {
      if (!_icons[index].enterNewRoute) {
        return index;
      }
    }
    return null;
  }

  /// The tab whose page shows beside the selected one's.
  int? get _beside {
    if (_offset.value == 0) {
      return null;
    }
    return _neighbour(_offset.value < 0 ? 1 : -1);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final double width = context.size!.width;
    _offset.value = (_offset.value + details.primaryDelta! / width).clamp(
      _neighbour(1) == null ? 0.0 : -1.0,
      _neighbour(-1) == null ? 0.0 : 1.0,
    );

    final int? beside = _beside;
    if (beside != null && !_icons[beside].shouldRender) {
      setState(() => _icons[beside].shouldRender = true);
    }
  }

  void _handleDragEnd(DragEndDetails details) {
    final double offset = _offset.value;
    final int? beside = _beside;

    if (beside != null) {
      // Speed in the direction the page was pulled.
      final double speed = (details.primaryVelocity ?? 0) * (offset < 0 ? -1 : 1);

      if (speed > _flingVelocity || (offset.abs() > 0.5 && speed > -_flingVelocity)) {
        // The page pulled in becomes the selected one, where it already is.
        widget.logic.handleTapTabBarButton(beside);
        _offset.value = offset - offset.sign;
      }
    }

    _settle();
  }

  void _settle() {
    if (_offset.value == 0) {
      return;
    }
    _offset.animateTo(
      0,
      duration: Duration(milliseconds: (300 * _offset.value.abs()).round().clamp(100, 300)),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<TabBarIcon> rendered = _icons.where((TabBarIcon icon) => icon.shouldRender).toList();
    // Built here, not as the pages move, so that a move only repositions them.
    final List<Widget> pages = [for (final TabBarIcon icon in rendered) RepaintBoundary(child: icon.page.call())];

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _offset.stop(),
      onHorizontalDragUpdate: _handleDragUpdate,
      onHorizontalDragEnd: _handleDragEnd,
      onHorizontalDragCancel: _settle,
      child: AnimatedBuilder(
        animation: _offset,
        builder: (BuildContext context, _) {
          final TabBarIcon selected = _icons[widget.state.selectedDrawerTabIndex];
          final int? besideIndex = _beside;
          final TabBarIcon? beside = besideIndex == null ? null : _icons[besideIndex];
          final double offset = _offset.value;

          return Stack(
            children: [
              for (final (int index, TabBarIcon icon) in rendered.indexed)
                Offstage(
                  // Pages of two schemes may share a type; keep their states apart.
                  key: ValueKey<String>(icon.routeName),
                  offstage: icon != selected && icon != beside,
                  child: FractionalTranslation(
                    translation: Offset(icon == selected ? offset : (icon == beside ? offset - offset.sign : 0), 0),
                    child: pages[index],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
