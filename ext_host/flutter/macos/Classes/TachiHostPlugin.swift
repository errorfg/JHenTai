import FlutterMacOS

/// On macOS the extension host is a child process the Dart side starts
/// (lib/src/network/tachi/tachi_host.dart); the plugin lends it WKWebView
/// (TachiBrowser, the same file as on iOS).
public class TachiHostPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    TachiBrowser.register(with: registrar)
  }
}
