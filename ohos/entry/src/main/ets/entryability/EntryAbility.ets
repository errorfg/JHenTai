import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import PdfRendererPlugin from '../plugins/PdfRendererPlugin';
import TachiBrowserPlugin from '../plugins/TachiBrowserPlugin';
import TachiHostPlugin from '../plugins/TachiHostPlugin';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // plugins without an OpenHarmony implementation, written against the
    // channel protocol of their Dart side
    flutterEngine.getPlugins()?.add(new PdfRendererPlugin())
    flutterEngine.getPlugins()?.add(new TachiHostPlugin())
    flutterEngine.getPlugins()?.add(new TachiBrowserPlugin())
  }
}
