# Komga macOS 界面测试实时状态

最后更新：2026-10-05 02:48（Asia/Singapore）。这是一份持续更新的本地状态文档；后续测试和修复后的复测继续更新本文件。

测试依据：[komga-macos-ui-test.md](komga-macos-ui-test.md)，共 13 项。

首轮被测应用：`dist/komga-test/JHenTai Komga 测试.app`，版本 `8.0.27`，独立应用标识 `top.jtmonster.jhentai.komgatest`。首轮测试基线为 `fee78bf6`，功能提交为 `ef9b2265`。源码修复后的结果，需要用重新编译的应用复测，不能沿用旧包的结论。

当前汇总：**13 项均已完成执行。12 项符合文档预期；5.6 的继续阅读、进度及头部计数通过，但鼠标手势方向与文档注解不符，需确认规格。Claude 问题 A、B 的修复均已通过界面复测，离线相邻书路径也通过。不能把文档方向差异省略后宣称所有细节完全符合预期。**

主要复测包：`dist/komga-test/JHenTai EH 控件树验证 2df3f394.app`，应用标识 `top.jtmonster.jhentai.komgatest.ehsemantics2df3f394`。它基于 `2df3f394`，包含 Claude 的 `4cf519c2` 修复及本会话的两处布局语义边界修复，使用独立数据目录。CUA 粘贴当时未实际填入设置表单，因此仅在这个包的本地数据库预置了被忽略配置中的同一 Komga 连接，未复制其他包的阅读数据，未开启云同步；这不算新包设置表单输入测试通过。表中合并首轮及修复后的实际证据，没有在同一新包中重新执行全部 13 项；新包重点补测了 5.1、5.2、5.6、5.7、5.9、5.10、5.13。问题 A 在 ed8 包及新包读完/切书返回时均观察到自动更新；问题 B 在线和已下载书离线切换均已通过。下面保留历史包证据，不删除旧问题记录。

最终收尾状态：**02:38 服务器测试系列 35 本全部未读，书 ID 与初始基线完全一致；本会话创建的第 5、6 卷两份下载均已删除，首页计数 0、下载列表为空；真实连接配置逐字还原，临时凭据备份删除，新包和本会话使用的 ed8 包均已退出。** 证据：`dist/komga-test/ui-test/ehsemantics2df3f394/final-cleanup-audit.json`（passed=true），以及 `download-final-count0.txt`、`download-final-empty.txt`、`final-series-unread.txt`。下文较早进度/下载数量都是历史状态。

## 13 项逐项状态

| 编号 | 测试项 | 当前状态 | 已验证结果 | 未完成或需要处理的部分 |
| --- | --- | --- | --- | --- |
| 5.1 | 首页 | **通过** | 继续阅读、待读、最近新增、最近更新、书库、已下载入口可见；封面能加载；待读接口数量为 1，与界面一致。新包对“最近新增”分区用 CUA 横向拖动后，AX 可见卡片集合换成后面的系列；反向拖动恢复原来的卡片，证明分区可以横向滚动。 | 横向滚动由鼠标拖动验证。CUA 的 right 滚轮尝试没有取得横向位移，不以工具这一输入结果认定产品滚动缺陷。 |
| 5.2 | 书库浏览 | **通过** | 首轮遍历 146 个系列与当时服务器一致。00:28 新包重新遍历到“已全部加载”，147 个不同系列的完整名称集合与当前服务器一致。此前三种布局、三种排序、升降序和所有状态筛选已操作；00:21 明确设置“全部书籍 / 阅读中 / 标题升序 / 详细信息”，CUA 退出并重启后四项保留，首屏五本的顺序与详情完全一致。00:23 系列“已读”空结果与服务器总数 0 一致；“新添加”空结果与书库访问截止记录及服务器创建时间核对一致。 | 无已确认问题。147 是当前服务器内容，不用旧的 146 作为当前总数。 |
| 5.3 | 筛选面板 | 通过 | 系列面板显示作者、出版社、语言，未显示空的标签/类型。出版社筛选、系列详情核对、条件标签移除及结果恢复均已验证。全部书籍面板滚动到底后只有作者类别。 | 无已确认问题。 |
| 5.4 | 搜索 | 通过 | 输入测试系列部分繁体标题并回车后，标题变为“搜索：…”且找到测试系列；简体写法也能找到该繁体系列。本轮记录为服务端支持该简繁对照搜索。 | 无已确认问题。中文输入最终使用用户授权的系统文字输入，已用实际画面和搜索结果确认。 |
| 5.5 | 系列详情 | 通过 | 初始头部为 35 本全部未读，与服务器一致；阅读方向、作者、出版社标签正常；按卷号升序。作者、出版社标签跳转含测试系列，返回原系列页。降序第一本与服务器最后一本（卷号 35）一致，返回再进入仍为降序，书库仍保持添加时间排序。现已改回升序。 | 返回位置核对是在头部可见的位置执行，未单独覆盖较深滚动位置。阅读后的头部计数问题列于 5.6。 |
| 5.6 | 继续阅读与阅读器 | **主要功能通过；手势说明不符** | ed8 包第 1 卷第 5 页返回后，头部自动 0 已读、1 阅读中、34 未读，卡片与服务器均 5/156，无手动刷新。继续阅读、方向键翻页、缩略图通过。新包读完/切书返回也自动更新计数。最后补测鼠标拖动：第 3 页向左拖退到第 1 页；向右拖向后读，快速拖动带惯性最终到第 156 页。 | 原文“向左滑翻到下一页”与本次鼠标行为相反。当前横向连续布局源码 `reverse: logic.readPageLogic.isInRight2LeftDirection`，右到左排列实际按此方向运作；交 Claude 确认/修正文档预期，不擅自改原文将差异变成通过。A 修复已通过；触控板/触屏手势不由此次鼠标样本代替。 |
| 5.7 | 读完与下一本 | **新包复测通过** | 新 2df3f394 包：拖到末页，接口先确认第 1 卷 156/156、completed=true；点击末页下一本进入第 2 卷，翻页后第 1 卷保持完成、第 2 卷独立为第 2 页。菜单上一本回第 1 卷，再由菜单下一本回第 2 卷并翻到第 4 页。Escape 返回后，第 1 卷卡片已读完，第 2 卷 4/156；服务器始终保持第 1 卷 completed=true，头部自动为已读 1、阅读中 1、未读 33，没有手动刷新。 | 问题 B 远端书路径已通过。阅读器 AX 仍返回系列树，因此阅读器步骤用了 CUA 键盘、进度条拖动及鼠标坐标 fallback，未使用外部输入脚本。离线相邻书路径仍列于 5.10 待测。 |
| 5.8 | 别处修改的进度 | 通过 | 接口将第 3 卷设为第 10 页；刷新后卡片为 `10/153`；打开第 3 卷时阅读器为第 10 页，服务器仍为 `page=10`，没有改回第 1 页。 | macOS 本轮使用顶栏刷新按钮完成刷新，未验证鼠标下拉手势。 |
| 5.9 | 标记已读/未读 | **通过** | 新包第 4 卷长按 → 已读，卡片已读完、服务器 155/155 completed=true；再长按 → 未读，卡片和头部恢复、服务器进度为空。系列菜单批量已读后 35 本全部 completed=true，头部 35；再批量未读后头部 35 本未读，刷新及全量同步（提示同步 33 本）后服务器仍 35 本进度为空。 | 长按按用户原有授权使用仅投递到测试包 PID 的辅助事件，其余操作使用 CUA；没有激活窗口或移动系统指针，长按前后测试包 isActive 均为 false。无已确认问题。 |
| 5.10 | 离线下载 | **通过（含离线下一本）** | 第 5 卷下载后计数 1，列表唯一第 5 卷；再下载第 6 卷后计数 2。仅让测试包连接不可达，重启清空内存后仍能从下载入口读第 5 卷、翻页及显示缩略图；末页下一本进入第 6 卷并读到第 4 页。离线本地为第 5 卷第 151 页、第 6 卷第 4 页、两条 pending，服务器仍 35 本未读。恢复原配置后补发：服务器第 5 卷 151/completed=true、第 6 卷 4/false，其他 33 本未读。分别删除后计数 2→1→0，列表为空。 | 离线采用该测试包内的不可达本机连接夹具，保留 connectionId，移除真实密钥并用虚构认证；没有改系统网络。原配置已逐字恢复、临时备份已删除。没有下载整个系列。 |
| 5.11 | 全量同步按钮 | 通过 | 点击后界面显示“已同步 11 本书的进度”。随后测试系列仍保持全部未读。 | 无已确认问题。 |
| 5.12 | 错误提示 | 通过 | 保存错误 API 密钥后，首页显示密钥被拒绝及可改用用户名密码的提示；恢复正确密钥并保存后，首页内容恢复且认证错误消失。 | 当前正确密钥已恢复。未把密钥正文写入文档。 |
| 5.13 | 导航 | **通过** | 此前已验证首页 → 书库 → 系列 → 作者/出版社筛选及逐级返回，视图与排序保留，ed8 包 Escape 退出阅读器。23:33 在新 2df3f394 包中通过 CUA 控件点击 Komga 抽屉，再点击“主页”，AX 确认回到 EH 主页，左侧标签、画廊列表、右侧 J 同时存在。 | 完整补上了 Komga → 抽屉 → EH 的路径；未使用替代 UI 脚本。当前新包的阅读器按键问题仍单独记录于 5.7，不泛化此前 ed8 Escape 结果。 |

## 问题 A：阅读后系列头部计数没有自动更新（已修复，新包复测通过）

ed8aa2a8 复测：第 1 卷读到第 5 页返回后，头部自动更新且与卷卡片、服务器一致；未手动刷新。证据：`dist/komga-test/ui-test/ed8aa2a8/issue-a-fixed-page5.png`、`issue-a-retest.json`。下面保留旧包问题记录。

影响：用户退出阅读器后，系列汇总与卷卡片、服务器状态不一致。手动刷新可以更新头部，日常阅读返回时仍会看到旧计数。

复现步骤：

1. 测试系列初始 35 本全部未读。
2. 从系列页打开第 1 卷，翻到第 5 页。
3. 用阅读器左上角返回系列页，不手动刷新。
4. 核对第 1 卷卡片、系列头部，以及服务器的书/系列接口。

| 位置 | 实际结果 |
| --- | --- |
| 第 1 卷卡片 | 阅读中，`继续阅读 · 5/156` |
| 单本接口 | `page=5`，`completed=false` |
| 系列接口 | 已读 0、阅读中 1、未读 34 |
| 应用系列头部 | **已读 0、阅读中 0、未读 35** |

预期：返回系列页时，头部自动变为已读 0、阅读中 1、未读 34，与卷卡片和服务器一致。

证据：[series-after-page5.png](../../dist/komga-test/ui-test/series-after-page5.png)。

已核对的代码线索：

- `lib/src/pages/komga/komga_page.dart` 的 `_openBook()` 在阅读器返回后只调用 `controller.refreshProgress()`。
- `lib/src/pages/komga/komga_browse_controller.dart` 的 `refreshProgress()` 重读本地单本进度并通知界面；`_refreshSeries()` 才重新请求系列数据和继续阅读目标。
- `lib/src/pages/komga/komga_series_header.dart` 的计数取自 `level.series.booksReadCount/booksInProgressCount/booksUnreadCount`。

修复后需要重测：普通翻页返回、读完返回、下一本返回时，系列头部、单本卡片和继续阅读目标均应一致，不能只验证手动刷新后的状态。

## 问题 B：下一本把上一卷的完成进度改回第 1 页（已修复，新包 UI 复测通过）

Claude 在 `4cf519c2` 提供修复。00:42 已在包含该修复的新 2df3f394 包完成完整界面路径：末页 → 下一本 → 上一本 → 下一本 → 新书翻页 → 返回系列。各阶段服务器第 1 卷均为 `page=156, completed=true`；第 2 卷独立从未读变为第 2 页，再保存到第 4 页。返回时卡片、头部计数和服务器一致，未手动刷新。证据：`dist/komga-test/ui-test/ehsemantics2df3f394/issue-b-retest.json` 及同目录 reader/series 证据。以下保留旧包复现记录。

影响：读完第 1 卷并进入第 2 卷后，第 1 卷失去已读完成状态，阅读进度实际在服务器上回退。

独立复现步骤（该前后对照中**没有点击“上一本”**）：

1. 打开测试系列第 1 卷，确认实际画面是第 1 卷。
2. 打开阅读器菜单，把进度条拖到末尾；末页已显示，底部出现“下一本”。
3. 在点击下一本之前，用单本接口确认第 1 卷为 `page=156, completed=true`。当前桌面阅读布局末尾同时可见第 155、156 页，底部显示首个可见页 `155/156`；接口确认已完成。
4. 点底部“下一本”，实际画面进入第 2 卷。
5. 再次请求第 1 卷接口，并返回系列页核对卡片。

| 核对时点 | 第 1 卷服务器进度 |
| --- | --- |
| 点下一本之前 | `page=156, completed=true` |
| 进入第 2 卷之后 | **`page=1, completed=false`** |

预期：第 1 卷仍保持完成状态，第 2 卷独立从自己的进度开始；第 2 卷的初始化、翻页或路由切换不能报告到第 1 卷。

证据：

- [next-book-audit.json](../../dist/komga-test/ui-test/next-book-audit.json)：接口前后对照，仅含页码和完成状态。
- [reader-end-next.png](../../dist/komga-test/ui-test/reader-end-next.png)：第 1 卷末尾及下一本按钮。
- [reader-next-resets-progress.png](../../dist/komga-test/ui-test/reader-next-resets-progress.png)：进入第 2 卷后的阅读器。
- [series-next-resets-progress.png](../../dist/komga-test/ui-test/series-next-resets-progress.png)：返回系列后，第 1 卷显示为第 1 页阅读中。

排查入口（以下是排查方向，尚未确认根因）：

- `lib/src/pages/read/read_page_logic.dart`：`openSiblingBook()` 用 `offRoute(Routes.read, ..., preventDuplicates: false)` 替换阅读器；`onInit()` 创建 `ReadProgressFlushCoordinator` 并绑定当前会话的进度键和报告回调。
- `lib/src/pages/komga/komga_reader_launcher.dart`：`_session()` 为每本书绑定 `readProgressRecordStorageKey`、`reportReadProgress` 和相邻书加载回调。
- `lib/src/service/komga_progress_sync_service.dart`：`report()` 根据书 ID 读取本地进度并推送。

重点核对相邻书切换时新旧阅读会话、GetX 控制器生命周期、进度写入键和远端报告回调的对应关系，以及旧会话尚未完成的报告。

修复后的远端书路径已按上述步骤复测通过。5.10 随后独立验证了已下载第 5 卷末页 → 第 6 卷的离线路径、进度独立及恢复连接后的补发，也已通过；没有用在线结论代替离线执行。

## 当前数据与产物

- 允许写入的系列标题、服务器地址和 API 密钥只从被忽略的 `test/e2e/komga_e2e.json` 读取，本文不保存这些值。
- 本轮打开过第 1、2、3 卷；CUA 长按模拟额外打开过第 4 卷。第 3 卷还通过接口设置过第 10 页。所有阅读、批量标记均限于测试系列。
- 整个测试系列执行过批量已读和批量未读。17:47、切换包前及 23:17 的核对均为历史状态；之后新 2df3f394 包又读取了第 1 卷。23:47 已再次用授权的系列恢复接口清空进度，核对 35 本均为空、ID 与初始基线一致。
- 正确 API 密钥及原始连接配置已恢复；没有开启云同步；本轮创建并删除了第 5、6 卷两份离线下载，最终计数为 0。
- 初始恢复基线：[baseline.json](../../dist/komga-test/ui-test/baseline.json)。最终数据核对：[final-cleanup-audit.json](../../dist/komga-test/ui-test/ehsemantics2df3f394/final-cleanup-audit.json)，顶层 cleanup-audit 同步为同一结果。较早的 current-audit 文件保留为历史证据。
- 截图和接口证据都在 `dist/komga-test/ui-test/`。截图包含书名，仅供本地查看，不应连同基线直接提交到公开仓库。
- 后续用户授权修复 EH 语义边界，本会话仅修改桌面和平板两个布局文件并完成 macOS EH 验证；未 commit/push、未进行 PR 操作。该修复不计为 13 项 Komga 测试已全部通过。

## 工具限制与后续更新

Computer Use 曾发生并发控制和认证连接故障；重启 app server 后点击和垂直滚动恢复过，后续又出现 `noWindowsAvailable`。这些属于测试执行限制，不能记作 Komga 产品缺陷。

用户此前授权仅对独立 JHenTai 测试版使用系统文字输入，以及替代长按手势。这两种替代操作都已执行成功；其中长按脚本还用在普通按钮和进度条上，造成窗口激活并占用用户桌面。用户已提出停止这种测试方式，本会话停止所有前台替代输入/手势，不再用截图坐标补普通操作。未完成项保留为待测。

19:38 的只读 CUA 控件树仅返回窗口、菜单栏、`container jhentai` 和文本 `J`，没有页面按钮或书列表。历史上曾读到过设置输入框、保存按钮、系列计数和列表，因此不能说 Flutter 从来没有提供控件树，但当前树不足以支持可靠决策。已在独立构建目录 `dist/komga-test/ax-build-source/` 中编译了保持 Dart 语义收集和 macOS 原生 AX 桥开启的试验包；仍未完成后台 CUA 绑定，不能认定已解决。现已停止继续改包，改为跨应用读取对照。主工作树的功能源码没有改动。

`-10005` 已观察到多种附带错误：`noWindowsAvailable`、`timeoutReached`、ScreenCaptureKit 的 `-3811` 捕捉失败。不能把该代码本身等同于没有窗口，更不能据此归因于 Flutter。控件树缺失与 CUA 绑定/捕捉失败分别记录。

首页横向滚动暂未验证成功，未列为已确认产品问题。全新安装缓存/日志目录的两处修复不属于这 13 项，本轮尚未重新创建干净数据目录单独回归。

用户授权向 Warp 中 Claude 回传报告，但 CUA 安全策略拒绝访问 `dev.warp.Warp-Stable`。尚未发送消息；Claude 可直接读取本文件。后续每完成测试或复测，更新上面的同一张表、问题状态、证据及最新数据核对时间。

## CUA 跨应用只读对照

用户指定以 Excel 为普通桌面程序对照。本次没有点击、输入、滚动、切换工作簿或修改单元格。

| 应用 | 读取结果 | 判断范围 |
| --- | --- | --- |
| Microsoft Excel | `getApp` 成功（2.32 秒）；随后 `getAXState` 成功（0.80 秒），129 个编号节点，包括最近工作簿表格、搜索框、创建/取消按钮和菜单栏。没有 `-10005`。 | 已确认 CUA 能读取 Excel 当前“打开新的和最近使用的文件”窗口；未测试编辑操作。 |
| 原始 ed8aa2a8 JHenTai 测试包 | `getAXState` 成功，但只有窗口、容器和右侧占位文字 J，没有页面控件。 | 当前 Flutter 页面树不完整；不能据此认定 CUA 绑定错误由 Flutter 导致。 |
| 活动监视器、App Store | 完整控件树读取成功。 | 证明 CUA 读取能力并非全面失效。 |
| 系统设置 | `-10005: noWindowsAvailable`。 | 仅确认应用被列为运行；未独立确认它当时有打开的窗口，不能单凭此条认定工具 bug。 |
| 访达 | `-10005`，附带 `com.apple.ScreenCaptureKit.SCStreamErrorDomain`、`Code=-3811` 捕捉失败。 | 同一外层代码能发生在原生应用；应检查 CUA/系统捕捉链路，不能记作 Flutter 产品缺陷。 |
| 隔离 AX 试验包 | Release 编译成功；后台变体 CUA `getApp` 返回 `-10005: timeoutReached`。v3 应用日志确认窗口可见、`foreground=false`、`keyWindow=false`。 | 后台绑定仍未成功；没有用前台输入绕过。双栏语义边界的修改尚未得到 CUA 实测确认，不属于已验证产品修复。 |

结论：`-10005` 不限于 Flutter；Excel 的只读对照成功，不能排除 CUA 对特定应用/窗口处理的 bug，也不能据此认定 CUA 全部失效。此轮没有推进 13 项 Komga 测试，也没有把未测项改成通过。

脱敏对照记录：`dist/komga-test/ui-test/cua-cross-app-comparison.json`。原始 JHenTai 控件树：`ax-tree-before.txt`、`ax-tree-forced-bridge-only.txt`。隔离试验改动：`accessibility-build.patch`；没有提交到主工作树。没有将 Excel 工作簿名、文件路径或账户信息写入本文或对照 JSON。

当时的服务器只读审计：`dist/komga-test/ui-test/ed8aa2a8/audit-after-ui-stop.json`，测试系列 35 本中，第 1 卷 `page=156, completed=true`，第 2 卷 `page=4, completed=false`，其余 33 本进度为空。该审计不单独作为问题 B 的 UI 复测通过证据，也不是当前数据状态；最新恢复结果见文首。

## CUA 恢复与替代输入的记录核对

已核对本会话实际调用和返回记录，以下时间均为 Asia/Singapore：

- 16:35 按独立应用名称重新绑定后，CUA `app.click` 和垂直 `app.scroll` 成功，进入首页、书库，随后实际遍历到 146 个系列。此阶段没有依赖系统文字输入或长按脚本。
- 17:02 在 app server 重启后重置 CUA 运行时，重新绑定原始 Release 包；17:02:59 的 CUA 坐标点击成功打开阅读源菜单，17:03:08 的控件编号点击进入 Komga，控件树随之更新。没有重新编译 Flutter，也没有用替代脚本完成这两步。
- 17:16 起记录到授权的系统文字输入脚本调用，用于搜索和密钥输入；这类结果应标为替代输入，不能作为 CUA 文字输入恢复的证据。
- 17:40 起又出现 `-10005: noWindowsAvailable`，所以前面“恢复”的说法只适用于当次验证，不能理解为错误永久解决。
- 17:58 起记录到独立长按脚本调用，后来还用在普通按钮和进度条上。这些操作会激活测试版并占用前台，属于替代方法，不能汇报成 CUA 自身恢复。该做法已停止。

纠正：原始 Flutter 测试包曾通过 CUA 正常读取 Komga 按钮、筛选、系列列表并执行点击/滚动，不能把某些页面仅剩 J 的观察泛化为整个应用不提供控件树。相同包不改编译配置也曾恢复操作，因此应优先排查 CUA 会话、窗口绑定、认证和捕捉链路；不能以 `-10005` 为依据继续改 Flutter 构建。尚未确定 CUA 内部具体故障点，独立 AX 试验包的改动也不认定为已验证修复。

脱敏核对记录：`dist/komga-test/ui-test/cua-recovery-history.json`。没有复制完整会话记录、私有书名或配置值。

## 本轮恢复测试与独立静态调查

当前仍未完成全量 13 项。没有把新调查的静态结论当成产品测试通过，也没有将新的阅读器症状当成已定位根因。

- 同一 ed8 包：用户切入 Komga 后，CUA 能读取完整首页树；按控件点击测试系列成功。后一次读取只有窗口外壳，重绑不改善；单次 CUA 窗口 Raise 后恢复完整系列树。该单次观察不证明失焦或具体通知是原因。
- 为隔离问题 B 复测，通过系列菜单标记整个授权测试系列未读，界面 35 本全部未读；服务器 GET 核对也 35 本进度为空。没有执行下载整个系列。
- 打开第 1 卷后，CUA 截图显示阅读器 1/156，AX 返回上一层系列页的完整按钮和计数。Space 后未见菜单展开；坐标点击中央区域返回 `-10005: noWindowsAvailable`。当前只能确认 CUA 截图与 AX 输出不一致，尚未判断是原生树、选择/缓存或捕捉哪一层的问题。
- Escape 退出有效，返回后的系列头部自动为已读 0、阅读中 1、未读 34，卡片为 1/156。问题 A 的自动头部更新再次被观察到；问题 B 尚未完成末页→下一本复测。
- 该阶段数据记录在 `dist/komga-test/ui-test/ed8aa2a8/current-audit.json`，已被后续恢复覆盖；最新状态以文首 cleanup-audit 为准。

阅读器现场对照：`dist/komga-test/ui-test/ed8aa2a8/reader-ui-ax-mismatch.png`、`reader-ui-ax-mismatch.txt`、`reader-ui-ax-mismatch.json`。截图和 AX 文本含私有书名，仅供本地，不提交或发布。

独立调查产物：

1. `dist/komga-test/ui-test/cua-static-investigation.md`：SDK、IDA 静态代码和社区核对。已定位坐标 click/scroll 的窗口候选筛选和空交集 throw 条件；历史当时的具体候选字典、AX windowID 返回值和 CG 列表没有采样，故具体历史根因仍未定位。原来仅时间相关性的升级解释不作为根因结论。
2. `dist/komga-test/ui-test/eh-semantics-investigation.md`：真实 GetPageRoute/ResizableContainer/BlankPage 的 8 个无 GUI 对照通过，定位左右 Navigator 缺少语义容器时 ModalBarrier/BlockSemantics 清除前绘制栏的机制。当时尚未验证真实 macOS；后续验证已完成，见下一节。
3. `dist/komga-test/ui-test/reader-semantics-investigation.md`：真实 ReadPage/toRoute 无 GUI 对照有页码、时间和 tap 区域，展开菜单后有返回、前后书和 slider；正常阅读器打开时系列语义消失。该验证未模拟真实书页加载或 native AX，因此不冒充真实 macOS 验证，也没有复现现场的旧系列 AX。

阅读器菜单关闭时少带名控件，不能单独解释 CUA 返回完整旧系列树。`getAXStateAndScreenshot` 在 native 层有两个异步捕捉分支，不保证原子配对；也不能据此就认定缓存是本次原因。

`open -g` 只影响启动请求，项目 WindowsService 后续仍调用 windowManager.show/focus，故不能保证该测试包不取得前台。真实应用验证由主线独占；调查智能体未启动应用或控制 UI。

以上产物均未暂存、提交或发布。`dist/` 当前未被 Git ignore，不能把存放于 dist 等同于自动排除提交。

## EH 双栏语义边界修复：主线实施与真实 macOS 验证

用户授权由主智能体修改并直接验证。主工作树仅修改桌面与 tablet_v2 两个布局文件：为每栏 Navigator 增加 `Semantics(container: true, explicitChildNodes: true)`，阻止该栏 ModalBarrier/BlockSemantics 清除相邻栏的语义。

验证结果：

- 8 个无 GUI 语义对照全部通过；项目全量 161 项测试全部通过，使用临时本地 Komga 测试实例，没有修改用户真实服务器。
- 在独立工作树 `dist/komga-test/eh-semantics-build/` 构建标准 Release 包，没有加入此前的原生语义强制开启或窗口激活试验代码。
- 实际启动 `dist/komga-test/JHenTai EH 控件树验证 2df3f394.app`，独立应用标识 `top.jtmonster.jhentai.komgatest.ehsemantics2df3f394`。EH 首页 CUA 原生 AX 返回 64 个编号节点，左侧标签栏按钮、左栏主页和画廊列表、右侧 J 同时存在。
- 通过控件编号点击左侧搜索标签，AX 出现输入框，侧栏按钮和右侧 J 保留；通过主页控件返回后，主页和 J 仍同时可读。没有用替代 UI 脚本完成验证。

证据：`dist/komga-test/ui-test/eh-fixed-runtime-tree.txt`、`eh-fixed-search-tree.txt`、`eh-semantics-fix-verification.json`、`eh-semantics-fix-test.log`、`eh-semantics-full-tests.log`、`eh-semantics-fix.patch`。

桌面 EH 的语义清除问题已完成源码修复和真实 macOS 验证。平板采用同一修复，但没有进行 iPad/Android 实机 AX/读屏验证。阅读器的截图/AX不一致与历史 CUA `noWindowsAvailable` 原因不因此判为已修复。主线 13 项 Komga 测试仍未全量完成；最新计数见文首。修复未 commit/push，也未操作 PR。

## 23:20–23:48 继续测试：导航完成，其余受 CUA 操作限制

- 对 ed8 包执行 CUA 退出/重启后，启动 EH 时仍只见右栏 J；这是尚未包含布局语义修复的旧包，不据此否定新包修复。
- 对新 2df3f394 包执行 CUA 退出/重启后，控件编号点击成功打开阅读源菜单、进入 Komga、进入唯一允许写入的测试系列。该系列初始头部 35 本全部未读。
- 第 1 卷实际截图为阅读器 1/156，AX 输出仍为旧系列页面；小写 space 未见菜单展开，Escape 未见截图返回。仅证明这次没有取得预期的操作结果，未确定事件是否送达、运行时焦点或捕捉缓存的原因。`Esc` 别名另外返回 keyNotFound，不能混同为窗口错误。
- 退出该进程并重新启动后，继续可用的 AX 按钮测试：Komga 首页 → 抽屉 → 主页，返回 EH，补完 5.13。证据：`ehsemantics2df3f394/komga-to-eh-navigation.txt`、`komga-to-eh-navigation.json`。
- 试图继续 5.2 持久化测试时，首页 `CUA scroll` 返回 `-10005: noWindowsAvailable`，未滚动到书库入口；没有新增持久化通过结论。5.10 仍没有开始，没有创建下载。
- 依用户前面授权的后台只读 AX 验证方案，仅读取新包的窗口元数据：PID 27979，AXWindows 读取成功但数量 0，AXEnhancedUserInterface=true；CG 窗口 2952 为 onScreen=false，该 PID 的屏幕上窗口列表为空。CUA Raise 前后保持相同 PID、窗口 ID 和可见状态；通过应用 Window 菜单选择 JHenTai 后，主窗口也仍为 onScreen=false。证据：`window-diagnostic.json`、`window-diagnostic-after-cua-raise.json`、`window-diagnostic-after-window-menu.json`。
- 静态调查已确认坐标目标路径筛选屏幕上的窗口。因此当前窗口 2952 无法进入该筛选交集；未读取 CUA 原生候选字典，不能将此进一步宣称为全部历史 -10005 的根因，也没有确定该窗口为何不在屏幕上。该观察不解释阅读器旧 AX 或键盘输入问题。
- 本轮 UI 操作只使用 CUA；原生脚本仅做上述只读窗口元数据检查。没有用 System Events、CGEvent 或截图坐标补普通操作，没有激活或输入的替代脚本。设置预置仅写新包独立数据库的 komgaSetting 一行，服务器地址及密钥没有输出或写入本报告。
- 23:47 恢复接口返回成功，再查 35 本全部未读；没有下载需要删除。证据：`ehsemantics2df3f394/cleanup-audit.json`。后续恢复测试时仍应重新检查基线，并在结束时再次恢复。

上述新证据全部位于 `dist/komga-test/ui-test/ehsemantics2df3f394/`，包含私有书名的 AX 文本与截图仅供本地查看。调查智能体继续只读分析键盘与 AXPress 的原生代码；没有将尚无运行时验证的机制记为故障原因。

## 2026-10-05 00:11 调用方式核对与窗口结论的边界

用户指出此前后台 CUA 可以工作，质疑当前是否改用了截图点击。核对本轮实际调用和磁盘上的 SDK 后确认：

- 返回 EH 的操作为 `fixedApp.click(65)`（Komga 抽屉）和随后新树中的 `fixedApp.click(67)`（主页），均为 CUA 控件编号调用；AX 输出确认返回 EH。
- 首页滚动失败的调用为 `fixedApp.scroll(71, 'down', 2)`，传入控件编号，没有由主线指定截图坐标。SDK 将其构造为 `element_index=71` 的 scroll 请求。
- `getAXState()` 与 `getAXStateAndScreenshot()` 都调用 `get_app_state`；后者额外读取返回的截图字节。本地 `bind_mac_app.js` 没有由这两个读取方法切换后续输入模式的逻辑。截图用于验证阅读器画面与 AX 是否一致，并非本轮普通点击的定位来源。
- CUA 元素点击的 AXPress 分支直接操作 AX 对象；已定位的原生滚动路径会经过鼠标窗口候选筛选。这是 CUA 内部不同动作的实现差异，不能把它记为主线切换到了其他 UI 自动化技术。当前每次成功元素点击实际走 AXPress 还是 fallback，未取得 native trace。
- 前节的 onScreen=false 来自主线另一个进程执行的只读检查，不是那次失败请求内部的 CG 名单。尚未证明这份读数与 CUA 服务处于相同 GUI/窗口服务会话，也未取得 CUA 候选字典。因此它不足以证明本次失败原因，更不足以要求用户先把窗口移动到当前桌面。
- 之前后台点击和滚动成功的记录仍然有效。为什么相同类型操作现在失败，尚无结论；调查智能体继续只读核对 scroll 分支及会话上下文。窗口位置问答不再作为继续测试的必要前提。

本轮核对没有进行新的 UI 测试、移动窗口或服务器写入。13 项计数仍为 8 通过、1 修复待复测、3 部分完成、1 未开始；最新服务器恢复证据仍为 23:47 的 cleanup-audit。

## 2026-10-05 00:16–00:29 实际继续测试：补完 5.2

本轮继续使用 CUA。重新读取当前源菜单后按控件进入 Komga；首页纵向滚动确实改变可见分区并显示书库入口，后续多次书库滚动也实际生效。没有要求用户移动窗口，没有用替代输入脚本。本次成功不能证明此前故障的原因或工具永久恢复。

- 明确设置非默认组合：全部书籍、阅读中、标题升序、详细信息。记录实际界面后，通过 CUA super+q 退出，得到 App quit，再重新启动、进入同一书库。四项配置保留，首屏五本的名称、顺序、进度、日期与文件大小完全一致；持久化数据库的五个字段也符合预期。
- 系列“已读”显示空状态，服务器同书库 READ 总数为 0。“新添加”也显示空状态；以该连接/书库记录的截止时间核对服务器系列 createdDate，没有更新的系列。
- 当前服务器有 147 个系列，较首轮的 146 有变化，因此重新逐屏遍历当前书库。共采样 15 个视口，到“已全部加载”，147 个不同名称与当前服务器集合完全一致，missing=0、extra=0。
- 首页横向 scroll 本次未报错，但没有取得位置变化证据，5.1 的横向滚动仍不标为通过。

证据均位于 `dist/komga-test/ui-test/ehsemantics2df3f394/`：`library-before-restart.txt`、`library-after-restart.txt`、`library-persistence-audit.json`、`library-series-read-empty.txt`、`library-newly-added-empty.txt`、`library-empty-filter-audit.json`、`library-pagination-current.txt/json`、`library-pagination-server-audit.json`。原始 AX 文本及分页名称列表只供本地查看，不提交或发布。

5.2 更新为通过，当前 9 通过、1 修复待复测、2 部分完成、1 未开始。本轮到此只浏览书库，未打开其他系列的阅读器、未下载、未改服务器进度。下一步继续测试系列的 5.7 修复路径。

## 2026-10-05 00:34–00:43 问题 B 完整界面复测通过

阅读器仍出现 AX 返回旧系列树的异常，但本轮 Space 后实际截图确认菜单已展开，不能仅凭 AX 没变化就认定普通按键没有生效。继续使用 CUA 的键盘、原生鼠标拖动及坐标点击完成了以下路径；没有使用 System Events、CGEvent 或其他输入脚本。与此前只按 AX 编号的操作阶段分开记录，不能声称本次阅读器操作全由 AX 控件完成。

1. 第 1 卷拖到末页，实际显示末页和下一本按钮；点击下一本前，接口确认 `156 / completed=true`。
2. 点击末页下一本，实际封面进入第 2 卷。翻页后接口第 2 卷为 `2 / completed=false`，第 1 卷仍 `156 / true`。
3. 第 2 卷菜单“上一本”回到第 1 卷末尾，接口两卷状态保持 `156 / true`、`2 / false`。
4. 第 1 卷菜单“下一本”再次进入第 2 卷，继续翻页后第 2 卷为 `4 / false`，第 1 卷仍 `156 / true`。
5. Escape 返回系列页，AX 确认第 1 卷已读完、第 2 卷 4/156；头部自动显示已读 1、阅读中 1、未读 33，继续阅读目标为第 2 卷。接口系列计数相同，没有手动刷新。

全部对照汇总：`ehsemantics2df3f394/issue-b-retest.json`；各阶段 `issue-b-before-next.json`、`issue-b-after-next-and-pages.json`、`issue-b-after-previous.json`、`issue-b-after-roundtrip.json`、`issue-b-after-return.json`；系列 AX 为 `issue-b-returned-series.txt`。实际画面记录为 `reader-end-cua.png`、`reader-end-next-button-cua.png`、`reader-next-volume-cua.png`、`reader-volume2-menu-cua.png`、`reader-previous-volume-cua.png`。均仅供本地查看。

5.7 更新为通过，当前 10 通过、2 部分完成、1 未开始。问题 A 的头部自动更新也在本次读完/切书返回路径上再次观察到。离线下载与离线相邻切换仍未开始，本次不将其记为通过。当前数据为第 1 卷完成、第 2 卷第 4 页，测试结束需统一恢复未读。

## 2026-10-05 01:10–01:16 补完单本及批量标记 5.9

单本菜单只支持长按。按用户原有“授权测试版的长按手势”，辅助程序严格限制到新测试包的 PID/窗口及第 4、5、6 卷，使用 NSEvent 派生鼠标事件、窗口局部坐标、PID 定向投递及 0.9 秒保持；没有 activate、系统全局投递或 cursorMove。第 4 卷两次实际长按成功打开正确菜单，进程 isActive 前后均 false。菜单选择及普通刷新/同步均由 CUA 完成。

- 第 4 卷标记已读：卡片已读完，头部已读 2、阅读中 1、未读 32，接口第 4 卷 `page=155, completed=true`。
- 第 4 卷标记未读：卡片未读，头部回到已读 1、阅读中 1、未读 33，接口第 4 卷 readProgress 为空。
- 新包重新执行整系列已读：头部已读 35，接口确认 35 本均 completed=true。
- 整系列未读后刷新并全量同步：界面仍 35 本未读，提示同步 33 本进度；接口确认 35 本全部为空，没有回推此前第 1、2、4 卷的旧进度。

证据：`ehsemantics2df3f394/single-book-mark-read.json`、`single-book-mark-unread.json/txt`、`bulk-mark-read.txt`、`bulk-mark-unread.txt`、`series-bulk-read.json`、`unread-after-refresh-sync.txt`、`series-after-refresh-sync.json`。辅助代码位于本机 `/tmp/jhentai-test-background-longpress.swift`，不在仓库源码中。首版只用 public CGEvent 字段没有打开菜单，后续匹配了 CUA 的组合构造后成功；多项构造同时改变，不能单独归因某字段，更不作为历史 -10005 的根因。

5.9 更新为通过，当前 11 通过、1 部分完成、1 未开始。开始准备第 5、6 卷单本下载，仍禁止下载整个系列。

## 2026-10-05 01:27–01:34 补完首页横向滚动，下载两卷完成

- 最近新增分区：CUA 横向滚轮没有改变测试系列卡片 X 位置，伴随纵向位置变化，未把这次滚轮尝试记为横向通过。随后使用 CUA 横向 drag，可见 AX 卡片从最前面的系列变为后面的系列；反向 drag 恢复原来的系列，其他分区保持，5.1 更新为通过。证据：`home-horizontal-after-drag.txt`、`home-horizontal-restored.txt`；只读卡片位置记录 `home-horizontal-before.json`、`home-horizontal-after-scroll.json`。
- 第 5 卷单独下载完成，首页计数 1、下载列表唯一第 5 卷；然后第 6 卷单独下载完成，首页计数 2、下载列表两卷就绪。证据：`download-home-count1.txt`、`download-volume5-only.txt`、`download-home-count2.txt`、`download-volumes5-6.txt`。没有下载整个系列，尚未打开下载书的阅读器。
- 离线验证准备采用仅该测试包的临时 Komga 配置：保留下载所属 connectionId，连接到已确认拒绝 TCP 连接的本机端口，并使用虚构认证、移除真实 API 密钥。配置只在测试包退出后更改，原始一行配置以 0600 文件临时备份，恢复时逐字核对并删除备份。这模拟 Komga 连接不可达，不更改系统网络；真实服务器审计仍从原被忽略配置独立读取。

当前 12 通过、1 进行中。离线阅读、离线相邻切换、补发和删除下载尚未验证，继续执行后更新本文件。

## 最终离线验证与收尾

已在新包完成此前要求的离线相邻切换路径：

1. 两卷下载完成后，退出测试包。原 Komga 配置一行以 0600 文件临时备份，保留原 connectionId，临时指向已验证 TCP connection refused 的本机端口；真实 API 密钥移除，仅用虚构认证。原系统网络保持，真实服务器审计使用独立的原配置。
2. 重启后 Komga 首页实际显示 Connection refused；已下载入口计数仍 2。第 5 卷打开、翻到第 3 页、缩略图及书页正常显示，证明不依赖此前阅读器内存缓存。
3. 第 5 卷末页点下一本进入已下载第 6 卷，读到第 4 页再退出。下载列表第 5 卷已读完、第 6 卷 4/149。
4. 本地读索引分别为 150、3（对应第 151、4 页），两条 pending 的 connectionId/bookId 分别匹配第 5、6 卷；独立 GET 核对服务器仍 35 本全部未读，进度没有在离线阶段写出。
5. 退出并逐字恢复原配置，核对原 value/utime 一致、删除临时凭据备份。重启进入 Komga 并刷新后，服务器第 5 卷 `151 / completed=true`、第 6 卷 `4 / completed=false`，与本地一致；其他 33 卷进度为空。离线切书没有串写第 5 卷的完成状态。
6. 通过各卷长按菜单删除下载，先删第 5 卷后首页计数 1，再删第 6 卷后计数 0；下载列表显示“没有已下载的书”。
7. 所有补测结束后，通过系列菜单清空本地旧进度，退出新包及本会话使用的 ed8 包，再执行文档规定的系列恢复接口并核对：35 本全未读、ID 同基线、两份下载已删除、原配置恢复、备份删除、应用退出。最终 cleanup passed=true。

离线证据：`offline-fixture-apply.json`、`offline-home-connection-error.txt`、`offline-volume5-pages.png`、`offline-volume5-end-next.png`、`offline-next-volume6-pages.png`、`offline-returned-downloads.txt`、`offline-local-progress.json`、`series-offline-before.json`、`offline-fixture-restore.json`、`series-offline-after.json`、`offline-progress-replay-audit.json`。收尾证据：`download-after-delete5-count1.txt`、`download-final-count0.txt`、`download-final-empty.txt`、`final-series-unread.txt`、`final-cleanup-audit.json`。都位于 `dist/komga-test/ui-test/ehsemantics2df3f394/`，原始截图/AX 仅供本地。

## 补测发现的文档差异与额外 UI 提示

**方向说明差异（5.6）：** 鼠标拖动已实际验证。截图页码为 3 → 左拖后 1 → 右拖后惯性滚动到 156；当前源码横向连续列表以右到左方向设置 reverse。该行为与原文“向左滑翻到下一页”不符。仅记录实际鼠标行为及源码方向，不替 Claude 决定应改手势还是改文档，也不改原测试预期。证据：`reader-mouse-swipe-before.png`、`reader-mouse-swipe-left.png`、`reader-mouse-swipe-right.png`、`reader-mouse-swipe-right-settled.png`、`reader-mouse-swipe-return.txt`、`reader-mouse-swipe-audit.json`。

**额外 UI 改进项：** 连接拒绝时，中文界面显示了 Dio 的英文技术错误正文，并提到 library；重试及已下载入口仍可用。这是已观察到的提示文案问题，不是离线阅读/补发失败。`KomgaClient.friendlyError()` 对无 HTTP 状态的 DioException 直接返回 error.message，可在此处映射成本地化的网络连接提示。证据为 `offline-home-connection-error.txt`，尚未修改该代码。

**接口审计脚本修正：** 最终复核发现首次“新添加”接口对照脚本只读取 createdDate，而生产解码器接受 `created ?? createdDate`。最终已按真实 JSON 字段重算，并强制验证全部日期有效：147 个系列、READ 总数 0，最新 created 与书库截止值均为 2026-10-04T13:04:46Z，newly-added 为 0，与已记录空 UI 一致。`library-empty-filter-audit-final.json` 替代早先未验证日期有效性的脚本结果；没有用无效日期默认为 0 作为最终证据。

阅读器 AX 仍可返回旧系列/下载列表，而实际画面已是阅读器；本轮用 CUA 键盘及鼠标 fallback 完成相关功能测试，不宣称已修复该 AX 问题。历史 -10005 的具体运行时根因仍未定位，独立报告只对已确认的原生分支、失败条件和长按构造作有限结论。桌面 EH 双栏语义修复已真实验证，平板仍无实机验证。这些限制与上述功能测试结果分开记录。

测试结束后按用户授权再次尝试访问 Warp 中的 Claude，CUA 返回 `Computer Use is not allowed to use the app 'dev.warp.Warp-Stable' for safety reasons.` 自动审批没有提供更具体理由，因此消息未发送。本状态文档已更新，可由 Claude 直接读取；没有绕过拒绝使用其他输入方式。
