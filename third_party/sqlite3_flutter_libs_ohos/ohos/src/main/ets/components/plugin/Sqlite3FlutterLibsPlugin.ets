import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';

/**
 * Nothing to do at runtime: the plugin exists so that the HAP depends on the
 * ohpm package sqlite3-native-library, whose libsqlite3.so package:sqlite3
 * opens by name. The channel answers the Android workaround call, which is
 * never made on HarmonyOS.
 */
export default class Sqlite3FlutterLibsPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;

  getUniqueClassName(): string {
    return 'Sqlite3FlutterLibsPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'sqlite3_flutter_libs');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    result.success(null);
  }
}
