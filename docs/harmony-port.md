# 鸿蒙移植记录

这份文档记录鸿蒙版的技术决策、已知的妥协和尚未验证的事项，每完成一段工作就更新。做法沿用 PiliPlus（errorfg/PiliPlus 的 `docs/harmony-port.md`）移植时走通的路线。分支 `feature/harmony`，自 `master`（8.2.0+380）。

## 1. 原则

- 本仓库同时出 iOS、安卓、桌面和鸿蒙的包。共用代码必须能用官方 Flutter 编译，鸿蒙专属的东西按平台隔离。
- 鸿蒙包名 `com.gallery.reader`，显示名 Gallery Reader。
- 鸿蒙包只在本机构建，不走 CI（仓库所有者的决定）。

## 2. 技术决策

### 2.1 工具链：Flutter OpenHarmony 3.47.7

- CPF-Flutter（gitcode）`flutter_flutter` 的 `oh-3.47.7-dev` 分支。它比仓库用的官方 3.44.4 新，应用自己的代码不需要为它改动就能编译。
- SDK 自带的 material、cupertino 认识鸿蒙平台，不需要补平台分支。

### 2.2 鸿蒙专属依赖放在 `ohos/pubspec_ohos.yaml`

- 构建时并入 `pubspec.yaml`，其他平台不读它。同名条目替换 `pubspec.yaml` 里的条目。
- `dependencies`：只含鸿蒙实现的包（如 `path_provider_ohos`），面向应用的包仍用 `pubspec.yaml` 里的版本。
- `dependency_overrides`：鸿蒙实现写在面向应用的包里的，整包换成鸿蒙分支；以及与 3.47.7 冲突的固定版本（`test`、`intl`）。
- 共用的 Dart 代码不能 `import` 只在这个文件里出现的包。

### 2.3 `file_picker`

- 应用用的是 8.x 的接口（`FilePicker.platform.…`）。8.x 没有鸿蒙实现；它的 Windows 代码要 win32 5.x，而鸿蒙版的 plus 系列插件要 win32 6.x，两者不能同时解析。
- 鸿蒙构建把它整包换成 `ohos/packages/file_picker`：8.3.7 去掉桌面与网页实现的副本，保留公开接口和方法通道实现。原生部分用 `file_picker_ohos`，两者的通道协议相同。
- 尚未在真机验证。已知 `file_picker_ohos` 保存文件时不预填文件名（见 PiliPlus 文档第 5 节第 8 条），需要同样的补丁。

### 2.4 `GetPlatform.isMobile`

- 应用用 `get` 包的 `GetPlatform.isMobile`、`isDesktop` 区分布局与功能（各 47、36 处）。鸿蒙上 `isAndroid`、`isIOS` 都为假，不处理的话鸿蒙既不算手机也不算桌面。
- 构建时给 `get` 打补丁，让 `isMobile` 在鸿蒙上为真。共用代码不改。
- `isAndroid` 的 25 处多数对应只有安卓才有的系统接口（刷新率、窗口标志、外部存储、应用链接校验），鸿蒙上保持关闭。其中需要逐个判断的见第 5 节。

### 2.5 数据库

- `sqlite3` 3.x 用构建钩子编译原生库。3.47.7 的鸿蒙工具链能直接跑这个钩子，包里带有 `libs/arm64-v8a/libsqlite3.so`，不需要另外的原生模块。

## 3. 构建

构建脚本和下面这些补丁不在仓库里：

- `flex_color_picker`、`chewie`：`switch (TargetPlatform)` 没有覆盖鸿蒙，补上（与安卓同组）。
- `get`：见 2.4。

仓库内与构建有关的文件：`ohos/`（宿主工程）、`ohos/pubspec_ohos.yaml`、`ohos/packages/`、`ohos/patches/`（只在鸿蒙构建时应用的补丁，目前为空）。

步骤：并入鸿蒙依赖 → 应用 `ohos/patches` → `pub get` → 包补丁 → `flutter build hap --release --no-codesign -t lib/src/main.dart`。

## 4. 插件状况

已接上鸿蒙实现（均未在真机验证）：path_provider、url_launcher、webview_flutter、video_player、local_auth、permission_handler、battery_plus、device_info_plus、package_info_plus、sensors_plus、share_plus、wakelock_plus、file_picker、saver_gallery、screen_brightness、sqlite3。

没有鸿蒙实现、尚未处理：

- fluttertoast、pasteboard、pdfx、receive_sharing_intent、volume_button_override、http_proxy、system_network_proxy。
- sqflite（`flutter_cache_manager` 用它记录图片缓存）。
- tachi_host（Tachiyomi 扩展的运行环境）、jni、just_audio、audio_session。
- 只有安卓有意义的：android_intent_plus、flutter_displaymode、flutter_windowmanager_plus。

## 5. 待办

- 真机启动与基本浏览、阅读、下载。
- 逐个核对 `isAndroid` 的分支：返回键拦截（`will_pop_interceptor.dart`）、存储权限（`permission_util.dart`）、下载路径（`path_service.dart`）、音量键翻页、后台模糊与恢复时验证。
- 第 4 节里没有实现的插件：先确认哪些在启动或常用路径上会被调用。
- 应用图标在桌面上的实际显示（前景图用的是安卓自适应图标的前景，安卓端另有 16% 的内缩）。
