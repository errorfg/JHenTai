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
  private let glass: NativeGlassEffectView

  init(frame: CGRect, arguments: [String: Any]) {
    glass = NativeGlassEffectView(frame: frame)
    glass.cornerRadius = (arguments["cornerRadius"] as? NSNumber).map { CGFloat(truncating: $0) }
    glass.overrideUserInterfaceStyle = arguments["dark"] as? Bool == true ? .dark : .light
  }

  func view() -> UIView {
    return glass
  }
}

private final class NativeGlassEffectView: UIVisualEffectView {
  /// Null: a capsule, whatever the size.
  var cornerRadius: CGFloat?

  init(frame: CGRect) {
    if #available(iOS 26.0, *) {
      super.init(effect: UIGlassEffect())
    } else {
      super.init(effect: UIBlurEffect(style: .systemThinMaterial))
    }
    self.frame = frame
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
