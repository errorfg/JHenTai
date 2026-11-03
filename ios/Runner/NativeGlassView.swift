import Flutter
import UIKit

/// iOS's own Liquid Glass behind Flutter content; see native_glass.dart.
final class NativeGlassFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return NativeGlassPlatformView(frame: frame, arguments: args as? [String: Any] ?? [:])
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

private final class NativeGlassPlatformView: NSObject, FlutterPlatformView {
  private let container: NativeGlassContainerView

  init(frame: CGRect, arguments: [String: Any]) {
    let glass = NativeGlassEffectView()
    glass.cornerRadius = (arguments["cornerRadius"] as? NSNumber).map { CGFloat(truncating: $0) }
    glass.overrideUserInterfaceStyle = arguments["dark"] as? Bool == true ? .dark : .light
    let margin = (arguments["margin"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
    container = NativeGlassContainerView(frame: frame, glass: glass, margin: margin)
  }

  func view() -> UIView {
    return container
  }
}

/// Glass draws past its bounds. Flutter covers a platform view with what is
/// above it only as far as the view's frame, so the frame has to take that in.
private final class NativeGlassContainerView: UIView {
  private let glass: NativeGlassEffectView
  private let margin: CGFloat

  init(frame: CGRect, glass: NativeGlassEffectView, margin: CGFloat) {
    self.glass = glass
    self.margin = margin
    super.init(frame: frame)
    backgroundColor = .clear
    addSubview(glass)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    glass.frame = bounds.insetBy(dx: margin, dy: margin)
  }
}

private final class NativeGlassEffectView: UIVisualEffectView {
  /// Null: a capsule, whatever the size.
  var cornerRadius: CGFloat?

  init() {
    if #available(iOS 26.0, *) {
      super.init(effect: UIGlassEffect())
    } else {
      super.init(effect: UIBlurEffect(style: .systemThinMaterial))
    }
    clipsToBounds = true
    layer.cornerCurve = .continuous
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = cornerRadius ?? min(bounds.width, bounds.height) / 2
  }
}
