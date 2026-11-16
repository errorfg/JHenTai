// Starts the Tachiyomi extension host on a JVM inside the app's process:
// the channel protocol of ext_host/flutter (com.gallery.reader/exthost).
import {
  AbilityAware,
  AbilityPluginBinding,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import exthost from 'libexthost.so';

const TAG = 'TachiHostPlugin';
const CHANNEL = 'com.gallery.reader/exthost';

export default class TachiHostPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;

  getUniqueClassName(): string {
    return TAG;
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.context = binding.getAbility().context;
  }

  onDetachedFromAbility(): void {
    this.context = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'start') {
      const context = this.context;
      if (context == null) {
        result.error('start', 'no ability', null);
        return;
      }
      // The runtime image and the host jar are resources unpacked at
      // installation (resources/resfile/exthost).
      const base = `${context.resourceDir}/exthost`;
      exthost.start(`${base}/home/lib`, `${base}/exthost.jar`, context.tempDir, context.filesDir,
        call.args as string).then((port: number) => {
        result.success(port);
      }).catch((e: Error) => {
        result.error('start', e.message, null);
      });
    } else if (call.method === 'restartServer') {
      exthost.restartServer().then((port: number) => {
        result.success(port);
      }).catch((_: Error) => {
        result.success(-1);
      });
    } else {
      result.notImplemented();
    }
  }
}
