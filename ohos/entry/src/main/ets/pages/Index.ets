import common from '@ohos.app.ability.common';
import { FlutterPage } from '@ohos/flutter_ohos'
import { tachiWebHost } from '../plugins/TachiWebHost';

let storage = LocalStorage.getShared()
const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS'

@Entry(storage)
@Component
struct Index {
  private context = getContext(this) as common.UIAbilityContext
  @LocalStorageLink('viewId') viewId: string = "";

  build() {
    Stack() {
      // The web views of Tachiyomi extensions, under the app's content
      // (plugins/TachiBrowserPlugin.ets).
      NodeContainer(tachiWebHost)
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      FlutterPage({ viewId: this.viewId })
    }
    .width('100%')
    .height('100%')
  }

  onBackPress(): boolean {
    this.context.eventHub.emit(EVENT_BACK_PRESS)
    return true
  }
}
