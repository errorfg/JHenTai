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

- `sqlite3` 3.x 用构建钩子准备原生库，默认是下载预编译库。Flutter OpenHarmony 把目标系统报给钩子时写的是 Linux，钩子于是取了 glibc 的 Linux 版本；它依赖 `ld-linux-aarch64.so.1`，在鸿蒙上加载失败，表现为启动后白屏（所有读写数据库的初始化都失败）。
- 做法：让钩子从源码编译（`hooks.user_defines.sqlite3.source: source`，SQLite 3.50.2 的合并源文件，与该包默认版本相同）。Flutter OpenHarmony 传给钩子的编译器是鸿蒙 NDK 的 clang，只需再加 `--target=aarch64-linux-ohos`。编出的库只依赖 `libc.so`。
- 这段 `hooks` 配置由构建脚本在构建时追加到 `pubspec.yaml`，源文件放在本机构建区，不进仓库。

### 2.6 系统代理

- 鸿蒙版不读系统代理（仓库所有者的决定：手机上不需要）。`http_proxy` 没有鸿蒙实现，而 `GetPlatform.isMobile` 在鸿蒙上为真，所以 `getSystemProxyAddress` 里读取系统代理的条件从 `isMobile` 改成了 `isAndroid || isIOS`，对其他平台等价。
- 不改的话，网络请求模块的初始化会在这一步抛出异常，后面的 Cookie、缓存等初始化都不会执行。
- 设置里手动填写的代理不受影响。

### 2.7 读剪贴板

- 应用回到前台时读剪贴板、识别画廊链接。Flutter OpenHarmony 的嵌入层读剪贴板前向用户申请 `ohos.permission.READ_PASTEBOARD`，所以 `module.json5` 要声明它。
- 这是受限权限：签名用的描述文件必须带对应的 ACL，否则安装时报 `grant request permissions failed. PermissionName: ohos.permission.READ_PASTEBOARD`（错误码 9568289）。本机用的调试描述文件在声明权限后重新申请，得到了 `allowed-acls: [ohos.permission.READ_PASTEBOARD]`。上架分发要另行向应用市场申请，这里没有涉及。
- 仓库所有者在真机上确认识别与跳转正常（2026-11-16）。

### 2.8 Tachiyomi 扩展

- 扩展宿主是 JVM 程序（`ext_host/`）。鸿蒙上的做法与 iOS 相同：在应用进程内运行 Zero 解释器版的 OpenJDK。手机上没有依据可以启动子进程；带即时编译的虚拟机需要受限权限。
- 进行中，尚不可用。虚拟机的交叉编译在本机构建区的 `jdk-build/`。

## 3. 构建

构建脚本和下面这些补丁不在仓库里：

- `sqlite3` 的 `hooks` 配置与 SQLite 源文件：见 2.5。

- `flex_color_picker`、`chewie`：`switch (TargetPlatform)` 没有覆盖鸿蒙，补上（与安卓同组）。
- `get`：见 2.4。

仓库内与构建有关的文件：`ohos/`（宿主工程）、`ohos/pubspec_ohos.yaml`、`ohos/packages/`、`ohos/patches/`（只在鸿蒙构建时应用的补丁，目前为空）。

步骤：并入鸿蒙依赖 → 应用 `ohos/patches` → 追加 `hooks` 配置 → `pub get` → 包补丁 → `flutter build hap --release --no-codesign -t lib/src/main.dart`。

## 4. 插件状况

已接上鸿蒙实现（均未在真机验证）：path_provider、url_launcher、webview_flutter、video_player、local_auth、permission_handler、battery_plus、device_info_plus、package_info_plus、sensors_plus、share_plus、wakelock_plus、file_picker、saver_gallery、screen_brightness。

没有鸿蒙实现、尚未处理：

- fluttertoast、pasteboard、pdfx、receive_sharing_intent、volume_button_override。
- system_network_proxy、http_proxy：鸿蒙上不调用，见 2.6。
- sqflite（`flutter_cache_manager` 用它记录图片缓存）。
- tachi_host（Tachiyomi 扩展的运行环境）、jni、just_audio、audio_session。
- 只有安卓有意义的：android_intent_plus、flutter_displaymode、flutter_windowmanager_plus。

## 5. 待办

- PDF 书库页已能打开（顺带修了一个各平台共有的缺陷：`PdfService.refresh()` 覆盖了 `GetxController.refresh()`，每次 `update()` 都变成又一次扫描，界面一直转圈）。打开 PDF 文件（生成封面、渲染页面）用的 `pdfx` 没有鸿蒙实现，真机上只验证过空书库。仓库所有者要求在 Tachiyomi 之后处理这一项。
- 2026-11-16 曾见到一次界面全黑（切换来源后点底栏「设置」），未复现，原因不明。

- 真机：2026-11-16 在 Mate XTs 上启动成功，主页的排行榜、热门、最新能加载出图片（手机布局）。其余功能未验证。
- 逐个核对 `isAndroid` 的分支：返回键拦截（`will_pop_interceptor.dart`）、存储权限（`permission_util.dart`）、下载路径（`path_service.dart`）、音量键翻页、后台模糊与恢复时验证。
- 第 4 节里没有实现的插件：先确认哪些在启动或常用路径上会被调用。
- 应用图标在桌面上的实际显示（前景图用的是安卓自适应图标的前景，安卓端另有 16% 的内缩）。
