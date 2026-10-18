# 扩展宿主

应用中 Tachiyomi 站点的后端：在应用内运行 Tachiyomi/Mihon 的扩展（APK），把它们的漫画列表、详情、章节、页面和图片经本机 HTTP 接口交给应用。做法与 Tachimanga 相同：

- **Android**：在应用进程内，用系统自带的运行环境直接加载扩展 APK。
- **iOS**：在应用进程内，用随应用打包的 OpenJDK（[openjdk/mobile](https://github.com/openjdk/mobile)，Zero 解释器，静态链接）运行。扩展的 dex 代码在安装时由 dex2jar 转成 JVM 类；扩展用到的 Android 类由 `compat/` 提供。
- **桌面（macOS、Windows、Linux）**：随应用的 Java 运行环境启动一个子进程，其余与 iOS 相同。应用退出时子进程随之退出。

接口只监听 127.0.0.1，每个请求都要带应用启动宿主时生成的令牌。

## 模块

| 目录 | 内容 |
|---|---|
| `core/` | Tachiyomi 的源接口（`eu.kanade.tachiyomi.*`）、扩展用的 Injekt 查找、宿主本体（扩展安装与加载、HTTP 接口、筛选和设置项的转换）。Android 应用也编译这些源码 |
| `compat/` | 扩展在 JVM 上用到的 Android 类：SharedPreferences、androidx.preference、Uri、Handler、Base64、CookieManager、WebView、org.json 等 |
| `jvm/` | JVM 上的入口：dex 转换、类加载、桌面子进程与 iOS 的启动方法 |
| `testext/` | 测试用的扩展，按真实扩展的方式编译成 APK（`jvm/src/test/resources/testext.apk`） |

## WebView

扩展用的 `android.webkit.WebView`：

- **Android**：系统的 WebView，与宿主的请求共用系统的 Cookie 存储。
- **iOS、macOS**：应用的 WKWebView。`compat/` 的 WebView 把加载、执行脚本、销毁等操作作为命令放进 `jvm/` 的 BrowserRelay；应用经 `GET /browser/poll` 取走命令，交给插件的 `TachiBrowser.swift` 驱动一个不显示的 WKWebView，再把页面开始、结束、出错、页面发出的请求、JavaScript 接口调用和执行结果经 `POST /browser/events` 交回（`lib/src/network/tachi/tachi_browser.dart`）。加载时带上宿主对该地址的 Cookie，页面结束时把页面的 Cookie（含 HttpOnly）存回宿主。页面发出的请求只能观察：`shouldInterceptRequest` 的返回值不生效；JavaScript 接口的方法会执行，但页面拿不到返回值。
- **Windows、Linux**：暂无，加载页面立即报错给扩展。

需要用户操作的步骤（登录、人机验证）在应用的“在网页中打开”页面完成；iOS、macOS 关闭页面时把站点的 Cookie 交给宿主（`/cookies/import`）。

扩展调用了宿主没有实现的 Android 类时，那一次调用失败并在应用中显示错误；扩展的其他功能不受影响（JVM 以 `-XX:-BytecodeVerificationRemote` 加载扩展类，用到时才解析）。

## 构建与测试

```bash
./gradlew :jvm:test          # 端到端测试：安装测试扩展、转换、加载，经 HTTP 接口调用各功能
./gradlew :jvm:hostJar       # build/dist/exthost.jar：桌面端与 iOS 使用的宿主
./gradlew :testext:testApk   # 重新生成测试扩展，需要 Android SDK（在 local.properties 写 sdk.dir）
```

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/ping` | 宿主是否在运行 |
| GET | `/extensions` | 已安装的扩展与来源 |
| POST | `/extensions/install` | `{"path"}`：安装本机上的 APK（宿主保存自己的副本） |
| POST | `/extensions/uninstall` | `{"pkg"}` |
| POST | `/source/popular`、`/source/latest` | `{"source", "page"}` |
| POST | `/source/search` | `{"source", "page", "query", "filters"}` |
| POST | `/source/filters` | 来源的筛选项及默认状态 |
| POST | `/manga/details`、`/manga/chapters` | `{"source", "manga"}` |
| POST | `/chapter/pages` | `{"source", "chapter"}` |
| GET | `/image`、`/cover` | 页面图片与封面，经来源的请求头和拦截器取得 |
| POST | `/source/preferences`、`/source/preferences/set` | 来源声明的设置项；设置时先经扩展的变更监听 |
| POST | `/source/preference-store`、`/source/preference-store/set` | 来源保存的全部偏好，供云同步 |
| POST | `/source/web` | `{"source"}`：来源站点的地址与 User-Agent，供“在网页中打开” |
| POST | `/cookies/get`、`/cookies/import`、`/cookies/clear` | 宿主的 Cookie，每条为 `{"url", "setCookie"}` |
| GET、POST | `/browser/poll`、`/browser/events` | WebView 的命令与事件（仅 iOS、macOS） |
| POST | `/config` | 应用的代理设置 |

## 来源与许可

- `core/src/main/kotlin/eu/kanade/tachiyomi/` 中的源接口与网络辅助代码取自 [Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server) 中的 Tachiyomi 代码，按其 Apache-2.0 许可使用（见该目录的 LICENSE），并按本宿主的需要做了修改。
- dex 转换使用 [dex2jar](https://github.com/ThexXTURBOXx/dex2jar)（Apache-2.0）。
- 其余代码是本项目自己的实现。
