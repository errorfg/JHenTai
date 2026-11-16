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
- 8.x 靠各平台的插件注册来设定实现。鸿蒙上副本声明的 `dartPluginClass` 没有被注册，`FilePicker.platform` 未初始化，一调用就抛出 `LateInitializationError`。副本里只有一种实现，直接把它设为默认值。
- 选取文件已在真机验证（导入 PDF）。未处理：`getDirectoryPath` 返回的是系统的文件地址而不是普通路径（影响下载路径、额外扫描路径两个设置项）；`file_picker_ohos` 保存文件时不预填文件名（见 PiliPlus 文档第 5 节第 8 条）。

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

- 扩展宿主是 JVM 程序（`ext_host/`）。鸿蒙上的做法与 iOS 相同：在应用进程内运行 Zero 解释器版的 OpenJDK。没有找到第三方应用在手机上启动子进程的依据；带即时编译的虚拟机需要受限权限。
- 虚拟机：与 iOS 相同的 OpenJDK 源码提交和模块集合，用鸿蒙 NDK 交叉编译成静态库，再连同 libffi 链接成 `libjdkhost.so`（约 8.7 MB）。为鸿蒙打了 5 个补丁。构建脚本、补丁和说明在本机构建区的 `jdk-build/`，不在仓库里。
- 桥接：`ohos/entry/src/main/cpp/exthost.c`（`libexthost.so`），在一个 8 MB 栈的独立线程里创建虚拟机并调用宿主的 `Embedded.start`。创建前先检查运行时镜像和宿主 jar 是否存在，因为虚拟机找不到运行时镜像时会直接结束进程。`libjdkhost.so` 或 JDK 头文件不在时，这个库照样能编译，启动时报告「本构建不含扩展宿主」。
- 插件：`TachiHostPlugin.ets` 实现 `ext_host/flutter` 的通道协议（`com.gallery.reader/exthost`）。
- 运行时镜像（约 12.3 MB）和宿主 jar（约 9.1 MB）放在 `resources/resfile/exthost/`，系统在安装时解包到磁盘，路径取自 `context.resourceDir`。
- 启动防护与 iOS 相同（启动前写标记文件，启动返回后删除）。另外，标记存在而上次停留在 Tachiyomi 时，应用打开后回到 E-Hentai。
- 网络走 JDK 自带的 TLS（iOS 为了速度改用了系统的网络接口，鸿蒙没有做）。
- 扩展用的不显示网页视图：`TachiBrowserPlugin.ets`，协议与 iOS 的 `TachiBrowser.swift` 相同（通道 `com.gallery.reader/exthost/browser`），用系统的 ArkWeb。每个视图是窗口里的一个 `Web` 组件，垫在应用画面下面（`TachiWebHost.ets` 提供承载节点，`pages/Index.ets` 把它放在 Flutter 视图之下），不接收触摸；做法与 iOS 把 `WKWebView` 插在窗口最底层相同。最初做成了只构建、不上屏的组件，仓库所有者指出这类页面要应付对真实浏览器的检测，必须在界面树里渲染，于是改成现在这样。被应用画面完全盖住时内核是否照常运行页面脚本，尚未在真机验证。与 iOS 的差别：
  - 页面的全部请求由引擎的 `onInterceptRequest` 上报（与安卓的 `shouldInterceptRequest` 范围相同），控制台输出由 `onConsole` 上报，所以注入的脚本只负责定义宿主的 JavaScript 接口。
  - 引擎要求导航决定当场返回，而宿主的决定要经过一次往返才到。做法是上报后先放行，宿主拒绝时停止加载。
  - 引擎的 Cookie 接口只给名字和值，交回宿主的 Cookie 都按该站点的会话 Cookie 处理（没有域、有效期、HttpOnly 等属性）。
  - 需要用户动手的步骤（登录、点选或拖动滑块的人机验证）不在这些视图里做，而是在看得见的「在网页中打开」页面（`TachiWebViewPage`，`webview_flutter` 的鸿蒙实现）里完成；它与这些视图共用引擎的 Cookie，关闭时把站点的 Cookie 交给宿主。这个页面原先在鸿蒙上不显示入口，现已启用。
  - 2026-11-16 编译通过，尚未在真机验证。
- 仓库所有者在真机上确认能安装插件并正常使用（2026-11-16，当时还没有网页视图）。整个包因此从 43.8 MB 增加到 75.7 MB。
- 命令行（`hdc shell`）不能执行未签名的可执行文件（`Permission denied`，退出码 126），所以虚拟机只能在已签名的应用里验证。

### 2.9 PDF

- 渲染：`pdfx` 没有鸿蒙实现。宿主里的 `PdfRendererPlugin.ets` 用系统的 PDF Kit 实现 `pdfx` 的方法通道协议（`io.scer.pdf_renderer`）。
- `pdfx` 用 `universal_platform` 判断平台，后者把不认识的系统都当作安卓，于是在鸿蒙上选了 Pigeon 实现。`PdfService` 在鸿蒙上显式选用方法通道实现；宿主按安卓分支的约定把渲染结果写成临时文件返回，`pdfx` 读完后删除。
- 导入：书库页的加号选取 PDF，拷进应用自己的 `pdf` 目录（与下载目录同级），该目录与额外扫描路径一起扫描。这是共用代码，各平台都有。原因是鸿蒙上应用读不到沙箱以外的目录，只靠扫描路径没有办法把文件放进来。
- 真机上导入、扫描、读页数都成功（日志）；封面与翻页由仓库所有者测试。

### 2.10 启动窗

- 系统在应用画面出来之前画启动窗，`module.json5` 必须给出图标和背景色。图标用一张透明图，背景用应用默认主题的底色（浅色 `#FDF7FF`、深色 `#141218`，由默认主题色算出）。
- 启动窗跟随系统的深浅色，读不到应用里的主题设置；换了主题色之后底色也不会跟着变。

## 3. 构建

构建脚本和下面这些补丁不在仓库里：

- `sqlite3` 的 `hooks` 配置与 SQLite 源文件：见 2.5。
- Tachiyomi 的虚拟机、JDK 头文件、运行时镜像和宿主 jar：见 2.8，构建时拷入宿主工程。

- `flex_color_picker`、`chewie`：`switch (TargetPlatform)` 没有覆盖鸿蒙，补上（与安卓同组）。
- `get`：见 2.4。

仓库内与构建有关的文件：`ohos/`（宿主工程）、`ohos/pubspec_ohos.yaml`、`ohos/packages/`、`ohos/patches/`（只在鸿蒙构建时应用的补丁，目前为空）。

步骤：并入鸿蒙依赖 → 应用 `ohos/patches` → 追加 `hooks` 配置 → `pub get` → 包补丁 → `flutter build hap --release --no-codesign -t lib/src/main.dart`。

## 4. 插件状况

已接上鸿蒙实现：path_provider、url_launcher、webview_flutter、video_player、local_auth、permission_handler、battery_plus、device_info_plus、package_info_plus、sensors_plus、share_plus、wakelock_plus、file_picker、saver_gallery、screen_brightness、pdfx（宿主实现）、tachi_host（宿主实现）。其中在真机上用到并确认的：path_provider、file_picker（选文件）、pdfx、tachi_host；其余由仓库所有者在使用中测试，没有逐项记录。

没有鸿蒙实现、尚未处理：

- fluttertoast（原生提示；应用内的提示用的是 Dart 画的 FToast，不受影响）、pasteboard（复制图片到剪贴板）、receive_sharing_intent、volume_button_override。
- system_network_proxy、http_proxy：鸿蒙上不调用，见 2.6。
- sqflite（`flutter_cache_manager` 用它记录图片缓存）。
- jni、just_audio、audio_session。
- 只有安卓有意义的：android_intent_plus、flutter_displaymode、flutter_windowmanager_plus。

## 5. 待办与已知问题

- 界面全黑：切到 Komga 再回到 E-Hentai 时出现过（仓库所有者报告，2026-11-16）。带异常输出的版本上没有抓到异常，原因不明。
- 选目录返回的不是普通路径（见 2.3）。
- 安装 Tachiyomi 插件后转圈不结束：出现过一次，之后没有复现，没有针对它改动。读代码可知转圈标记要等安装之后的保存、重新读取列表、写回来源设置三步都结束才清除。
- 逐个核对 `isAndroid` 的分支：返回键拦截（`will_pop_interceptor.dart`）、存储权限（`permission_util.dart`）、下载路径（`path_service.dart`）、音量键翻页、后台模糊与恢复时验证。
- 应用图标在桌面上的实际显示（前景图用的是安卓自适应图标的前景，安卓端另有 16% 的内缩）。

## 6. 顺带修的共用代码缺陷

移植中发现、各平台都受影响的问题：

- `PdfService.refresh()` 覆盖了 `GetxController.refresh()`，每次 `update()` 都变成又一次扫描，PDF 书库一直转圈。改名为 `scan()`。
- 带操作按钮的提示条不自动消失：Flutter 新版本里 `SnackBar` 有 `action` 时 `persist` 默认为真。显式设为 `false`。
- 从 Komga、PDF 切回站点后画廊链接提示重复出现：已提示过的链接记在主页的实例字段里，主页重建后丢失。改为静态字段。

## 7. 调试方法

- 正式包里 Dart 的 `print` 会进系统日志（`hilog`，标签里带 `flutter settings log message`）。框架层的异常和各服务初始化时被捕获的异常不会进，要看的话在构建副本里临时加输出（本机 `tools/diag_boot.py`）。
- 测试版：用 `local-debug/dev-sync/test-build.json` 作为 `--dart-define-from-file` 构建，只与测试用的同步环境通信；本机 `tools/preset_test.py` 让它启动时自动打开同步，账号和 Komga 配置随之进来，不用在设置页里操作。
