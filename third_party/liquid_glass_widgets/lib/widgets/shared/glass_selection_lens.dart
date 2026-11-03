import 'package:flutter/cupertino.dart';

import '../../src/renderer/liquid_glass_renderer.dart';
import '../../types/glass_quality.dart';
import 'animated_glass_indicator.dart';
import 'glass_effect.dart';

/// A clear glass lens over the item under the finger, the iOS 26 way of
/// showing which item a press-and-slide is on: no fill, the lens refracts the
/// item below it. Lies above the items, as a child of their [Stack]; moves
/// from item to item and fades out where it was when the finger lifts.
///
/// Added to the vendored package; see PATCHES.md.
class GlassSelectionLens extends StatefulWidget {
  /// Creates a lens over [rect], or a fading one where it last was when
  /// [rect] is null.
  const GlassSelectionLens({
    super.key,
    required this.rect,
    required this.borderRadius,
    required this.quality,
    this.bulge = 3.0,
  });

  /// The item under the finger, in the coordinates of the parent [Stack].
  final Rect? rect;

  /// Corner radius of the item; the lens adds [bulge] to it.
  final double borderRadius;

  final GlassQuality quality;

  /// How far the lens reaches past the item on each side.
  final double bulge;

  @override
  State<GlassSelectionLens> createState() => _GlassSelectionLensState();
}

class _GlassSelectionLensState extends State<GlassSelectionLens> {
  Rect? _lastRect;

  /// A lens that appears jumps to its item instead of sliding from the
  /// item it last faded out over.
  bool _jump = true;

  @override
  void didUpdateWidget(GlassSelectionLens oldWidget) {
    super.didUpdateWidget(oldWidget);
    _jump = oldWidget.rect == null;
  }

  @override
  Widget build(BuildContext context) {
    final Rect? rect = widget.rect ?? _lastRect;
    _lastRect = rect;
    if (rect == null) {
      return const SizedBox.shrink();
    }
    final bool standard = widget.quality != GlassQuality.premium;
    return AnimatedPositioned.fromRect(
      rect: rect.inflate(widget.bulge),
      duration: _jump ? Duration.zero : const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: widget.rect == null ? 0 : 1),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          builder: (BuildContext context, double t, _) {
            if (t < 0.01) {
              return const SizedBox.expand();
            }
            // The same lens and rim values as the moving tab indicator.
            return GlassEffect(
              shape: LiquidRoundedRectangle(
                borderRadius: widget.borderRadius + widget.bulge,
              ),
              settings: AnimatedGlassIndicator.baseIndicatorSettings
                  .copyWith(visibility: t),
              quality: widget.quality,
              interactionIntensity: t,
              clipExpansion: const EdgeInsets.all(12),
              rimThickness: standard ? 0.35 : 0.8,
              ambientRim: standard ? 0.08 : 0.1,
              baseAlphaMultiplier: standard ? 0.08 : 0.2,
              edgeAlphaMultiplier: standard ? 0.15 : 0.4,
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
    );
  }
}
