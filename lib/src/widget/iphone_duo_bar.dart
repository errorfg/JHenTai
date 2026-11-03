import 'dart:math';

import 'package:flutter/material.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/widget/native_glass.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/src/widgets/surfaces/status_bar_row.dart';
import 'package:liquid_glass_widgets/src/widgets/surfaces/vertical_bar_regions.dart';

/// A page and its controls on iPhone Duo: the controls go in a strip along the
/// right edge in every pose but one. The inner display held upright keeps
/// horizontal bars, as the system does: there the controls go beside the status
/// bar if [controlsBesideStatusBar], and otherwise stay in the page's own bar.
class IPhoneDuoBar extends StatelessWidget {
  const IPhoneDuoBar({
    super.key,
    required this.controls,
    required this.builder,
    this.controlsBesideStatusBar = false,
  });

  final Widget Function(Axis axis) controls;

  /// Builds the page; [inStrip] says its controls are in the strip, not for it to show.
  final Widget Function(BuildContext context, bool inStrip) builder;
  final bool controlsBesideStatusBar;

  @override
  Widget build(BuildContext context) {
    VerticalBarRegions.instance.observe();

    return ListenableBuilder(
      listenable: Listenable.merge([VerticalBarRegions.instance, VerticalBarRegions.instance.edge]),
      builder: (BuildContext context, _) {
        final GlassVerticalBarData? strip = GlassVerticalBar.resolve(
          viewPadding: MediaQuery.viewPaddingOf(context),
          size: MediaQuery.sizeOf(context),
          platform: TargetPlatform.iOS,
          textDirection: Directionality.of(context),
          displayFeatures: VerticalBarRegions.instance.value,
          systemEdge: VerticalBarRegions.instance.edge.value,
        );

        if (strip != null) {
          return _buildWithStrip(context, strip);
        }
        return controlsBesideStatusBar ? _buildWithTopRow(context) : builder(context, false);
      },
    );
  }

  /// On the right whichever edge the system chose. Where it chose the left, its
  /// status bar and camera are over there, with nothing to avoid on the right.
  Widget _buildWithStrip(BuildContext context, GlassVerticalBarData strip) {
    final bool systemStripOnRight = (strip.edge == GlassVerticalBarEdge.trailing) == (Directionality.of(context) == TextDirection.ltr);

    return Row(
      children: [
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeRight: true,
            child: Builder(builder: (BuildContext context) => builder(context, true)),
          ),
        ),
        Container(
          key: const ValueKey<String>('mobileSideRail'),
          width: strip.width,
          color: UIConfig.backGroundColor(context),
          padding: EdgeInsets.only(
            left: GlassVerticalBarMetrics.inset,
            top: systemStripOnRight ? strip.top : strip.rowTop,
            right: strip.width - GlassVerticalBarMetrics.controlExtent - GlassVerticalBarMetrics.inset,
            bottom: systemStripOnRight ? strip.bottom : GlassVerticalBarMetrics.edgeMargin,
          ),
          child: controls(Axis.vertical),
        ),
      ],
    );
  }

  /// The inner display held upright keeps the page's top inset clear for the
  /// status bar, which takes only the corner of it: the bar goes beside that.
  Widget _buildWithTopRow(BuildContext context) {
    final StatusBarRow? row = StatusBarRow.of(context);

    return Stack(
      children: [
        Positioned.fill(child: builder(context, false)),
        Positioned(
          key: const ValueKey<String>('mobileSideRail'),
          left: row?.left ?? GlassVerticalBarMetrics.titleInset,
          top: GlassVerticalBarMetrics.edgeMargin,
          right: row?.right ?? UIConfig.iPhoneDuoStatusCornerWidth + GlassVerticalBarMetrics.rowInset,
          height: GlassVerticalBarMetrics.rowHeight,
          child: controls(Axis.horizontal),
        ),
      ],
    );
  }
}

/// One control in the bar, on a circle of iOS's own glass.
class IPhoneDuoBarButton extends StatelessWidget {
  const IPhoneDuoBarButton({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: GlassVerticalBarMetrics.controlExtent,
      child: Stack(
        children: [
          const Positioned.fill(child: NativeGlass()),
          Material(type: MaterialType.transparency, child: Center(child: child)),
        ],
      ),
    );
  }
}

/// The controls of a page with the strip to itself, in the system's order from
/// the top: what navigates, then the page's actions sharing one capsule of glass.
class IPhoneDuoPageControls extends StatelessWidget {
  const IPhoneDuoPageControls({super.key, required this.navigation, required this.actions});

  /// Inside the capsule, before the first action and after the last.
  static const double _capsuleInset = 6;

  final List<Widget> navigation;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final Widget control in navigation) ...[
          IPhoneDuoBarButton(child: control),
          SizedBox(height: GlassVerticalBarMetrics.spacing),
        ],
        // A lone item is a circle, as in the system's bar.
        if (actions.length == 1) IPhoneDuoBarButton(child: actions.single),
        if (actions.length > 1) Flexible(child: _buildActions()),
      ],
    );
  }

  Widget _buildActions() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) => SizedBox(
        key: const ValueKey<String>('sideRail:actions'),
        width: GlassVerticalBarMetrics.controlExtent,
        height: min(actions.length * GlassVerticalBarMetrics.itemExtent + _capsuleInset * 2, constraints.maxHeight),
        child: Stack(
          children: [
            const Positioned.fill(child: NativeGlass()),
            Material(
              type: MaterialType.transparency,
              child: ScrollConfiguration(
                behavior: UIConfig.scrollBehaviourWithoutScrollBarWithMouse,
                child: ListView(
                  primary: false,
                  padding: const EdgeInsets.symmetric(vertical: _capsuleInset),
                  itemExtent: GlassVerticalBarMetrics.itemExtent,
                  children: [for (final Widget action in actions) Center(child: action)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
