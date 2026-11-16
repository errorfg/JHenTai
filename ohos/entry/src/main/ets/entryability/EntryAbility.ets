import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import PdfRendererPlugin from '../plugins/PdfRendererPlugin';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // plugins without an OpenHarmony implementation, written against the
    // channel protocol of their Dart side
    flutterEngine.getPlugins()?.add(new PdfRendererPlugin())
  }
}
