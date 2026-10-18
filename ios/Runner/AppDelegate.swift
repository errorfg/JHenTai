import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Whether this is an iPad, where the app turns its interface within the
    // window, and the way up the screen is shown (UIInterfaceOrientation).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ScreenOrientation") {
      let channel = FlutterMethodChannel(name: "jhentai/screen_orientation", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { _, result in
        var orientation = UIInterfaceOrientation.unknown
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
          if #available(iOS 16.0, *) {
            orientation = scene.effectiveGeometry.interfaceOrientation
          } else {
            orientation = scene.interfaceOrientation
          }
        }
        result(["pad": UIDevice.current.userInterfaceIdiom == .pad, "orientation": orientation.rawValue])
      }
    }
  }
}
