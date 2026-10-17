import Flutter
import UIKit

/// Starts the extension host on the JVM in the app's process.
public class TachiHostPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.gallery.reader/exthost", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(TachiHostPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      guard let config = call.arguments as? String else {
        result(FlutterError(code: "start", message: "missing configuration", details: nil))
        return
      }
      // Creating the JVM takes a while; not on the main thread.
      DispatchQueue.global(qos: .userInitiated).async {
        var error: NSError?
        let port = ExtHostJVM.start(withConfig: config, error: &error)
        DispatchQueue.main.async {
          if port > 0 {
            result(Int(port))
          } else {
            result(FlutterError(code: "start", message: error?.localizedDescription ?? "the host did not start", details: nil))
          }
        }
      }
    case "restartServer":
      DispatchQueue.global(qos: .userInitiated).async {
        let port = ExtHostJVM.restartServer()
        DispatchQueue.main.async { result(Int(port)) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
