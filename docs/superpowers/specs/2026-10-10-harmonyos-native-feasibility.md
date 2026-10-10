# 鸿蒙原生版（HarmonyOS NEXT）可行性评估

日期：2026-10-10
分支：`feature/harmonyos`（自 master `b0fd73ee` 开出）
状态：评估与试编译，未开始正式适配

## 1. 结论

能做，但本机现有工具链编不出任何鸿蒙 Flutter 工程：当前所有鸿蒙 Flutter SDK 版本（3.41.10、3.35.8）的嵌入层都用到了 HarmonyOS 6.1.1 SDK（API 24）里不存在的自动填充接口，连空工程都过不了 ArkTS 编译。先决条件是换到带 API 26 SDK 的 DevEco Studio 26.0 Beta1（需华为账号下载）。其余工作——Flutter 3.44 与 3.41 的差距、十余个插件换鸿蒙移植、数据库原生库、音量键插件、约 120 处平台判断、签名与流水线——都已逐项核对，没有不可解的项，第 8 节给出估计。

## 2. 现状

### 2.1 本项目

- Flutter 3.44.4（CI 用 3.44.8），`pubspec.yaml` 要求 Dart ≥ 3.12。
- 平台插件 61 个（`.flutter-plugins-dependencies`），按根包约 35 个。
- 自有原生代码只有两处：Android 的音量键拦截（`android/.../MainActivity.kt`，MethodChannel `com.gallery.reader.volume.event.intercept`）；桌面端的系统代理读取（`third_party/system_network_proxy_{macos,linux,windows}`）。没有 `dart:ffi` 直接调用。
- README 里已有「HarmonyOS compatibility」一节，指的是让 Android 包在鸿蒙上少弹风险提示，不是原生版。

### 2.2 鸿蒙版 Flutter SDK

- 仓库：`https://gitcode.com/openharmony-tpc/flutter_flutter`（README 给出的地址；`openharmony-sig` 下同名仓库可访问）。
- 标签：`3.41.10-ohos-1.0.1`（基于上游 3.41.9，Dart 3.11.5，引擎 2026-04-28）、`3.35.8-ohos-1.0.4`、`3.27.5-ohos-*`、`3.22.1-ohos-*`。分支里有 `oh-3.35.7-dev`、`br_3.47.0_bak`。README 的路线图写明 3.44 与 3.47 在计划中，日期为预估。
- 引擎与 Dart SDK 从华为云 OBS（`flutter-ohos.obs.cn-south-1.myhuaweicloud.com`）下载，本机可直接访问。
- 本机已克隆到 `/Users/georgezhang/vscode-project/flutter_ohos`（浅克隆，标签 3.41.10-ohos-1.0.1），`flutter doctor -v`：

  ```
  [✓] HarmonyOS toolchain - develop for HarmonyOS devices
      • OpenHarmony Sdk at /Applications/DevEco-Studio.app/Contents/sdk, available api versions has [24:default]
      • Ohpm version 6.1.2.285
      • Node version v18.20.1
      • Hvigorw binary at /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw
  ```

  所需环境变量（鸿蒙 SDK 的 README）：

  ```sh
  export TOOL_HOME=/Applications/DevEco-Studio.app/Contents
  export DEVECO_SDK_HOME=$TOOL_HOME/sdk
  export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home
  export PATH=/Users/georgezhang/vscode-project/flutter_ohos/bin:$TOOL_HOME/tools/ohpm/bin:$TOOL_HOME/tools/hvigor/bin:$TOOL_HOME/tools/node/bin:$PATH
  ```

### 2.3 本机其余条件

- DevEco Studio 6.1.1，HarmonyOS 6.1.1 SDK（API 24），JDK 17。
- 没有连接鸿蒙设备（`hdc list targets` 为空），磁盘上没有模拟器镜像。
- `hdc`、`ohpm`、`hvigorw` 都在 DevEco 的应用包内，不在 PATH。

## 3. Flutter 版本差距：3.44 → 3.41

鸿蒙 SDK 最高 3.41，本项目 3.44。在 3.41 下的实际结果（工作树 `/tmp/jh-ohos`，未提交）：

依赖解析：只有三个包要求 Dart ≥ 3.12，放宽后 271 个包解析成功，64 个包版本与 3.44 的 lock 不同（多为补丁号）。

| 包 | 3.44 下 | 3.41 下 |
|---|---|---|
| saver_gallery | 5.1.0 | 4.1.2（鸿蒙上本来就要换，见第 4 节） |
| simple_animations | 5.3.0 | 5.2.0 |
| test（dev） | 1.31.0 | 1.30.0 |

静态分析：错误全部来自 3.44 才有的 API，共 4 种、13 处，两个 SDK 都能接受的写法都存在：

| 3.44 写法 | 处数 | 两边都可用的写法 |
|---|---|---|
| `CustomScrollView(scrollCacheExtent: ScrollCacheExtent.pixels(n))` | 9 | `cacheExtent: n`（3.44 中弃用但仍有效） |
| `ScrollCacheExtent.viewport(x)`（`cached_page_view.dart`） | 1 | 3.41 没有按视口倍数的缓存区，只能给像素值 |
| `ReorderableListView(onReorderItem:)` | 1 | `onReorder:`（3.44 中弃用；两者的 newIndex 语义不同，要照旧版处理） |
| `saver_gallery` 5 的 `albumPath` | 1 | 随替换包一起改 |
| `switch (defaultTargetPlatform)` 缺 `TargetPlatform.ohos` | 1 | `default:`（3.44 没有 `ohos` 枚举值，不能写成 case） |

两种维护方式：

1. 鸿蒙用 3.41-ohos，其它平台继续 3.44；一份代码，两条流水线。代价是上面 13 处退回弃用写法，并且以后不能用 3.44 独有的 API，直到鸿蒙 SDK 跟上。
2. 所有平台都用 3.41-ohos（鸿蒙 SDK 也能出 APK、IPA、桌面包）。其它平台退回 3.41，与之前刻意升到 3.44 相悖，不取。

## 4. 插件对照

鸿蒙移植的插件以 git 依赖引用，命名规则：官方包在 `openharmony-sig/flutter_packages`（按包取分支或标签，`path: packages/<包>/<包>`），第三方包各自一个仓库，名为 `fluttertpc_<包>` 或 `flutter_<包>`。以下为逐个核对的结果（`git ls-remote` 验证过存在与分支名）。

### 4.1 有移植，直接替换

| 包 | 项目版本 | 移植仓库与引用 | 说明 |
|---|---|---|---|
| path_provider | 2.1.6 | flutter_packages `br_path_provider-v2.1.5_ohos` | |
| url_launcher | 6.3.2 | flutter_packages 标签 `url_launcher_v6.3.2-ohos-1.0.2` | |
| local_auth | 3.0.1 | flutter_packages 标签 `local_auth-v3.0.1-ohos-1.0.0` | 锁屏页用 |
| webview_flutter | 4.14.0 | flutter_packages 标签 `webview_flutter-v4.13.1-ohos-1.0.2` | 退到 4.13.1 |
| video_player | 2.11.1 | flutter_packages 标签 `video_player-v2.11.1-ohos-1.0.0` | 评论区 HTML 间接引入 |
| file_picker | 8.3.7 | fluttertpc_file_picker `br_v8.0.7_ohos`（另有 10.3.8） | 8 处调用 |
| permission_handler | 12.0.3 | flutter_permission_handler 标签 `12.0.1-ohos-1.0.0` | |
| battery_plus | 7.1.0 | flutter_plus_plugins `br_battery_plus-v7.0.0_ohos` | |
| device_info_plus | 11.1.0 | flutter_plus_plugins `br_device_info_plus-v11.1.0_ohos` | |
| package_info_plus | 9.0.1 | flutter_plus_plugins `br_package_info_plus-v9.0.0_ohos` | |
| share_plus | 12.0.2 | flutter_plus_plugins `br_share_plus-v12.0.1_ohos` | |
| wakelock_plus | 1.5.2 | fluttertpc_wakelock_plus 标签 `1.4.0-ohos-1.0.0` | |
| fluttertoast | 8.2.8 | flutter_fluttertoast `br_8.2.8_ohos` | |
| pdfx | 2.9.2 | flutter_pdfx 标签 `2.9.2-ohos-1.0.0` | |
| receive_sharing_intent | 1.8.1 | fluttertpc_receive_sharing_intent 标签 `1.8.1-ohos-1.0.0` | |
| sqflite | 2.4.3 | flutter_sqflite 标签 `2.4.2-ohos-1.0.0` | 只被 flutter_cache_manager 间接引入 |
| just_audio / audio_session | 0.10.6 / 0.2.4 | fluttertpc_just_audio `br_v0.10.5_ohos`、flutter_audio_session `br_v0.2.2_ohos` | 评论区 HTML 间接引入 |
| screen_brightness | 2.1.11 | 上游自带 `screen_brightness_ohos` 2.1.4，已在 lock 中 | 不用改 |

这些仓库大多已有 `br_3.41_dev` 分支，说明社区在跟进 3.41。

### 4.2 数据库：sqlite3 / drift

项目用 drift 2.34（要求 `sqlite3 ^3.1.5`，现为 3.3.4）加 `sqlite3_flutter_libs` 0.5.42 装载原生库。社区的 `fluttertpc_sqlite3` 仓库只有模板 README，没有代码。可用的是 `https://github.com/SageMik/sqlite3-ohos.dart` 的 `sqlite3_flutter_libs-0.5.25-ohos`：其 `ohos/` 模块没有 C 代码，只在 `oh-package.json5` 依赖 ohpm 仓库的 `sqlite3-native-library ^3.46.0`，Dart 侧 `DynamicLibrary.open('libsqlite3.so')`。因此做法是：Dart 侧 `sqlite3` 保持 3.3.4，只给 `sqlite3_flutter_libs` 加一个鸿蒙模块（照该 fork 的 `ohos/` 目录，十几个文件），原生库来自 ohpm。工作量小，但要自己维护这个模块。

### 4.3 没有移植：替换或放弃

| 包 | 用途与位置 | 处理 |
|---|---|---|
| saver_gallery | 阅读器保存图片到相册（`base_layout_logic.dart` 一处） | 换 `flutter_image_gallery_saver` 标签 `2.0.3-ohos.1.0.0-beta.2`（API 不同，一处调用） |
| pasteboard | 阅读器复制图片到剪贴板（一处） | 鸿蒙上不提供此功能 |
| volume_button_override + `MainActivity.kt` | 音量键翻页（`volume_service.dart`，按 isAndroid/isIOS 分支） | 自写 ArkTS 插件：InputKit `inputConsumer.on('keyPressed')` 可订阅音量键并阻止系统默认行为 |
| system_network_proxy / http_proxy | 读取系统代理（`proxy_util.dart`，按 isDesktop/isMobile 分支） | 鸿蒙上跳过，由用户手动填代理 |
| flutter_displaymode | 刷新率（Android 专有，已按 isAndroid 守卫） | 不做 |
| flutter_windowmanager_plus | 防截屏 FLAG_SECURE（Android 专有，已守卫） | 可用 `fluttertpc_screen_protector` 标签 `1.4.2_1-ohos-1.0.0`，非必需 |
| android_intent_plus | App Links 设置页（Android 专有，已守卫） | 不做 |
| window_manager、desktop_webview_window、screen_retriever、system_network_proxy_* | 桌面专有 | 不参与鸿蒙构建 |
| jni / jni_flutter | 只被 path_provider_android 引入 | 随 path_provider 的移植消失 |

## 5. 平台判断

`GetPlatform.isMobile` 定义为 iOS 或 Android，鸿蒙上为否；`isDesktop` 也为否。项目里 `GetPlatform.isMobile` 42 处、`isAndroid` 13 处、`isIOS` 12 处、`isDesktop` 33 处、`Platform.isAndroid` 20 处，分布在 37 个文件：沉浸模式、音量键、布局选择、权限、保存路径、设置页的条目显示等。鸿蒙 SDK 提供 `Platform.isOhos` 与 `TargetPlatform.ohos`。需要一个项目级的平台工具（把鸿蒙算作移动端），并逐处核对这 120 处判断。

## 6. 构建、签名、运行

- `flutter create --platforms ohos .` 生成 `ohos/` 工程（与 `android/`、`ios/` 并列），`flutter build hap --debug|--release`，产物在 `ohos/entry/build/default/outputs/default/`。
- 签名：调试用 DevEco 的自动签名，需要在 DevEco 里登录华为开发者账号；上架需手动申请发布证书。没有签名的 HAP 不能装到真机或模拟器。
- 运行：真机（开发者模式 + USB 调试）或 DevEco 模拟器（设备管理器里下载镜像，也要登录）。本机两者都没有。
- CI：GitHub Actions 没有现成的鸿蒙环境，需要在 job 里下载 DevEco 命令行工具与鸿蒙 Flutter SDK（各数 GB），构建缓存要另行设计；签名密钥要进 Secrets。

## 7. 试编译记录

### 7.1 本项目（工作树 `/tmp/jh-ohos`，3.41.10-ohos-1.0.1）

只改了第 3 节列出的 13 处代码与三个包的版本约束，没有换任何插件。`flutter analyze` 剩 349 条，全是信息与警告，没有错误。`flutter create --platforms ohos --org top.jtmonster -t app .` 生成 `ohos/` 工程（模板 `compatibleSdkVersion: "5.1.0(18)"`，`runtimeOS: "HarmonyOS"`）。`flutter build hap --debug` 在 hvigor 的 `CompileArkTS` 阶段失败，15 个错误全部在引擎自带的嵌入层 `@ohos/flutter_ohos`（`src/main/ets/plugin/editing/OhosAutoFillHelper.ets`）：

```
Namespace 'autoFillManager' has no exported member 'AutoFillType' / 'ViewData' / 'AutoFillTriggerType' / 'FillRequest' / 'AutoFillCallback' / 'FillFailureResult' / 'SaveRequest'
Property 'requestAutoFill' does not exist on type 'typeof autoFillManager'
Expected 1-2 arguments, but got 3.
```

Dart 侧没有参与：失败发生在编译 Dart 之前。

### 7.2 对照：空工程

用 `flutter create -t app --platforms ohos` 新建的空工程，3.41.10-ohos-1.0.1 与 3.35.8-ohos-1.0.4（另克隆到 `/Users/georgezhang/vscode-project/flutter_ohos_335`）两个 SDK 都在同一处、同一组错误失败。与本项目无关。

### 7.3 原因

- 本机 SDK 的 `@ohos.app.ability.autoFillManager.d.ts` 只导出 `AutoSaveCallback` 与 `requestAutoSave`。
- OpenHarmony 主线的同名声明文件里，`ViewData`、`FillRequest`、`SaveRequest`、`AutoFillType` 标为 `@systemapi`（三方应用不可用）；`requestAutoFill`、`AutoFillCallback`、`AutoFillTriggerType`、`FillFailureResult` 根本不存在。即它们是 HarmonyOS 新版 SDK 新开放的接口。
- 嵌入层的 `CHANGELOG_OHOS.md`：3.41.9-ohos-0.0.3-beta「手机端支持密码保险箱功能」，3.41.9-ohos-1.0.1（2026-08-17）「支持密码保险箱功能」。3.35.8 线同步了这部分代码。
- 社区同款 issue：flutter_flutter #2835「oh-3.41.9-release 无法正常运行」（2026-09-29，报告者 DevEco Studio 6.0.0 Release，同一组错误，另有 `CompetitionStrategy`、`isInFreeWindowMode` 两处新接口报错），报告者留言「可以了，升级 DevEco-Studio 版本」后关闭。
- 公开资料：DevEco Studio 26.0 Beta1 是与 HarmonyOS 7.0（API 26）配套的版本。本机的 6.1.1.290 Release（API 24）不够。

因此：现在的鸿蒙 Flutter SDK 要求 API 26 的 HarmonyOS SDK，也就是 DevEco Studio 26.0 Beta1。它面向 HarmonyOS 7.0，编出的包能否在 HarmonyOS 6.x 真机上运行要靠 `compatibleSdkVersion` 与运行时判断，需要上机验证。同一 issue 列表里还有「3.41.10-ohos-1.0.1 release/profile（AOT）启动即 SIGSEGV」（Mate X5，HarmonyOS 6.1.0.135，open）与「3.41.10-ohos-1.0.0 进入二级界面普遍掉帧」（HarmonyOS 6.1.0，open），说明 3.41 线在 6.1 设备上还有未解决的运行期问题。

### 7.4 旁证：社区已适配插件的实际存在性

第 4 节表中的仓库与分支名均经 `git ls-remote` 核对；`fluttertpc_sqlite3` 存在但只有模板 README；`fluttertpc_saver_gallery`、`fluttertpc_pasteboard`、`fluttertpc_volume_button_override`、`fluttertpc_system_network_proxy`、`fluttertpc_http_proxy` 均不存在。

## 8. 工作量与建议

### 8.1 先决条件（用户）

1. 安装 DevEco Studio 26.0 Beta1（华为账号下载），与 6.1.1 并存即可；装好后我用空工程复验 `flutter build hap`。
2. 一台 HarmonyOS NEXT 真机（开发者模式、USB 调试），或在 DevEco 里登录账号下载模拟器镜像。没有签名的 HAP 装不上任何设备，自动签名也要登录。
3. 发布阶段需要华为开发者账号的发布证书。

### 8.2 适配工作（先决条件满足后）

| 项 | 内容 | 估计 |
|---|---|---|
| 工具链验证 | 空工程编译、安装、运行 | 0.5 天 |
| Flutter 版本差距 | 13 处代码改为两边都能编的写法；`pubspec` 的 Dart 下限降到 3.11；saver_gallery、simple_animations、test 的约束放宽；其它平台继续 3.44 | 0.5 天 |
| 插件替换 | 18 个包换鸿蒙移植。放在 `pubspec_overrides.yaml` 里、只在鸿蒙流水线生成，这样 Android、iOS、桌面不受影响 | 1 天 |
| 数据库 | 给 `sqlite3_flutter_libs` 加鸿蒙模块（ohpm `sqlite3-native-library`），drift 不动 | 0.5 天 |
| 平台判断 | 项目级平台工具，鸿蒙算移动端；逐处核对 120 处 | 1–2 天 |
| 音量键 | ArkTS 插件：InputKit `inputConsumer.on('keyPressed')` 接到现有的 MethodChannel | 0.5–1 天 |
| 保存到相册、剪贴板、代理 | 换 `flutter_image_gallery_saver`；剪贴板复图与系统代理在鸿蒙上不提供 | 0.5 天 |
| 鸿蒙工程 | 包名、图标、启动页、权限（网络、相册写入、生物认证）、`module.json5` | 0.5–1 天 |
| 签名与流水线 | GitHub Actions 自建鸿蒙环境（DevEco 命令行工具 + 鸿蒙 Flutter SDK，各数 GB）、签名材料进 Secrets、产物 HAP | 1–2 天 |
| 真机调试 | 阅读器手势、沉浸模式、WebView 登录、下载目录、同步、Komga | 不可预估，取决于 3.41 线在 6.x 设备上的稳定性（见 7.3 的两个 open issue） |

合计约两周到首个可装机的测试包，不含真机调试。

### 8.3 不采用的做法

- 全部平台改用 3.41-ohos：与刻意升到 3.44 相悖。
- 修改引擎的 `flutter.har` 去掉密码保险箱代码：每次 SDK 更新都要重做，且 3.35/3.41 的其它新接口（`CompetitionStrategy`、`isInFreeWindowMode`）同样会撞上旧 SDK。
- 退回 3.27.5-ohos（配套 API 20+，无密码保险箱代码）：与 3.44 的代码差距远大于 13 处，引擎也旧一代。
