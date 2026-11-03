import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// iOS's own Liquid Glass (UIGlassEffect), for content laid over it: a capsule
/// unless [cornerRadius] is given. It takes no touches.
///
/// Keep clips out of its ancestors: Flutter masks a platform view under a
/// clip, and an effect view under a mask stops sampling what is behind it.
class NativeGlass extends StatelessWidget {
  const NativeGlass({super.key, this.cornerRadius});

  final double? cornerRadius;

  /// Glass draws past its bounds, and what is above a platform view covers it
  /// only as far as the view's frame: its edges would show through a page
  /// moving over it. So the view is this much larger than the glass inside.
  static const double margin = 24;

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;

    return IgnorePointer(
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            left: -margin,
            top: -margin,
            right: -margin,
            bottom: -margin,
            child: UiKitView(
              // The creation params are all the view is told.
              key: ValueKey<Brightness>(brightness),
              viewType: 'jhentai/native_glass',
              creationParams: <String, Object?>{'cornerRadius': cornerRadius, 'dark': brightness == Brightness.dark, 'margin': margin},
              creationParamsCodec: const StandardMessageCodec(),
            ),
          ),
        ],
      ),
    );
  }
}
