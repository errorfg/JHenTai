# Changes to liquid_glass_widgets 1.14.2

Copied from pub.dev (MIT, see LICENSE) with `lib`, `shaders`, `ios`, the
license files, README and pubspec. `example` and `CHANGELOG.md` are left out.

On iOS 26 the item under a pressing finger is shown by a clear glass lens that
refracts and slightly magnifies it. The package draws a flat white fill under
the menu row and a white glow on button groups instead, and neither can be
configured away, so:

- `widgets/shared/glass_selection_lens.dart` (new): `GlassSelectionLens`, the
  lens of the moving tab indicator (`GlassEffect` with
  `AnimatedGlassIndicator.baseIndicatorSettings`) placed over one item of a
  `Stack`; it moves between items and fades out where it was.
- `widgets/overlays/glass_menu.dart`, `shared/glass_menu_internal.dart`,
  `glass_menu_item.dart`: the row under the finger gets the lens above it, and
  grows by `GlassMenu.selectionMagnification` (1.05) while pressed. The flat
  highlight is drawn only for a non-transparent `selectionColor`, which now
  defaults to transparent.
- `widgets/interactive/glass_button_group.dart`: `GlassButtonGroup.icons`
  gets the iOS 26 press-and-slide. The lens follows the finger from item to
  item, and the icon under it grows by `selectionMagnification` (1.15).
  Lifting the finger after a slide activates the item it is on; a press
  without a slide is still the item's own tap. The pill no longer glows under
  the finger, no longer turns white while pressed (`ambientBaseLight`), and
  no longer grows as a whole (`interactionScale`): while scaled, its premium
  refraction froze into an opaque frosted face.
- `analysis_options.yaml` (new): the package is analyzed without the app's
  lints.
