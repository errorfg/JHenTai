import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2_logic.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2_state.dart';
import 'package:jhentai/src/widget/iphone_duo_bar.dart';
import 'package:jhentai/src/widget/native_glass.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// The home's navigation on iPhone Duo, in place of the bottom bar and the left
/// drawer: a strip along the right edge in every pose but one, and beside the
/// status bar at the top of the inner display held upright. The tabs scroll
/// along the bar; a swipe away from the edge, or the menu button, pulls out the
/// panel that names them.
class IPhoneDuoNavigation extends StatelessWidget {
  const IPhoneDuoNavigation({super.key, required this.logic, required this.state, required this.child});

  final MobileLayoutPageV2Logic logic;
  final MobileLayoutPageV2State state;
  final Widget child;

  /// Inside the capsule, before the first tab and after the last.
  static const double _capsuleInset = 6;

  /// The bottom bar this replaces is what took up the bottom inset. Without it
  /// the pages would keep an empty band there, instead of running to the bottom
  /// of the screen.
  @override
  Widget build(BuildContext context) {
    return IPhoneDuoBar(
      controlsBesideStatusBar: true,
      controls: _buildControls,
      builder: (BuildContext context, _) => MediaQuery.removePadding(context: context, removeBottom: true, child: child),
    );
  }

  Widget _buildControls(Axis axis) {
    return Flex(
      direction: axis,
      children: [
        _buildMenuButton(),
        SizedBox.square(dimension: GlassVerticalBarMetrics.spacing),
        Expanded(
          child: Align(
            alignment: axis == Axis.vertical ? Alignment.bottomCenter : Alignment.centerLeft,
            child: _buildTabs(axis),
          ),
        ),
      ],
    );
  }

  Widget _buildMenuButton() {
    return IPhoneDuoBarButton(
      key: const ValueKey<String>('sideRail:panel'),
      child: Builder(
        builder: (BuildContext context) => IconButton(
          icon: const Icon(Icons.menu),
          color: UIConfig.desktopLeftTabIconColor(context),
          onPressed: () => MobileLayoutPageV2State.scaffoldKey.currentState?.openEndDrawer(),
        ),
      ),
    );
  }

  Widget _buildTabs(Axis axis) {
    final double itemExtent = axis == Axis.vertical ? GlassVerticalBarMetrics.itemExtent : GlassVerticalBarMetrics.controlExtent;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) => GetBuilder<MobileLayoutPageV2Logic>(
        id: logic.tabBarId,
        builder: (_) {
          final double length = min(
            state.icons.length * itemExtent + _capsuleInset * 2,
            axis == Axis.vertical ? constraints.maxHeight : constraints.maxWidth,
          );

          return SizedBox(
            key: const ValueKey<String>('sideRail:tabs'),
            width: axis == Axis.vertical ? GlassVerticalBarMetrics.controlExtent : length,
            height: axis == Axis.vertical ? length : GlassVerticalBarMetrics.controlExtent,
            child: Stack(
              children: [
                const Positioned.fill(child: NativeGlass()),
                Material(
                  type: MaterialType.transparency,
                  child: ScrollConfiguration(
                    behavior: UIConfig.scrollBehaviourWithoutScrollBarWithMouse,
                    child: ListView.builder(
                      primary: false,
                      scrollDirection: axis,
                      padding: axis == Axis.vertical
                          ? const EdgeInsets.symmetric(vertical: _capsuleInset)
                          : const EdgeInsets.symmetric(horizontal: _capsuleInset),
                      itemCount: state.icons.length,
                      itemExtent: itemExtent,
                      itemBuilder: _buildTab,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTab(BuildContext context, int index) {
    final bool selected = state.selectedDrawerTabIndex == index;

    return Center(
      key: ValueKey<String>('sideRail:${state.icons[index].name.name}'),
      child: IconButton(
        tooltip: state.icons[index].name.name.tr,
        icon: selected ? state.icons[index].selectedIcon : state.icons[index].unselectedIcon,
        color: selected ? Theme.of(context).colorScheme.primary : UIConfig.desktopLeftTabIconColor(context),
        style: selected ? IconButton.styleFrom(backgroundColor: UIConfig.desktopLeftTabIconColor(context).withValues(alpha: 0.1)) : null,
        onPressed: () => logic.handleTapSideRailButton(index),
      ),
    );
  }
}
