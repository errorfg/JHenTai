# Komga 阅读进度双向同步设计（子项目 1）

日期：2026-10-04
状态：设计已逐段确认，待审阅规格文档

## 1. 背景

### 1.1 总体拆分

Komga 功能补齐分为以下子项目，按依赖顺序实施。全部完成后，所有平台统一更新一版。

| 子项目 | 内容 |
|---|---|
| 1. 进度正确性（本文） | 修复进度缺陷，JHenTai 与 Komga 双向同步，上报失败后补发 |
| 2. 浏览结构 | 导航栈、服务端分页与无限滚动、系列内按卷号排序、系列详情、过滤已删除条目、修正 EPUB 判定、测量会话复用的必要性 |
| 3. 搜索与筛选 | 全文搜索（系列/书籍，跨书库）、服务端筛选（标签、类型、作者、出版社、语言、年龄分级、年份、连载状态） |
| 4. 首页与管理 | 继续阅读、待读、最近新增/更新；标记书或系列为已读/未读 |
| 5. 阅读器集成 | 下一本/上一本、图片格式转换、页面缩略图、按系列阅读方向 |
| 6. 离线下载 | 下载书或系列到本机阅读，进度联网后补发 |
| 独立小项 | eh2telegraph 的韩语、葡萄牙语、俄语文案 |

不在范围内：EPUB 小说阅读（服务器上没有小说）；收藏集、阅读列表、单行本（服务器上数量为 0，开始使用时再加）。

### 1.2 服务器现状（2026-10-04 只读查询）

- Komga 1.23.6；用户为管理员，具备 FILE_DOWNLOAD 角色。
- 1 个书库，143 个系列，2595 本书。52 本 EPUB 全部可按图片页阅读，其余为 ZIP/CBZ。
- 服务器上 28 本阅读中，33 本已读。

### 1.3 本子项目修复的缺陷

1. **覆盖服务器进度。** 打开书时起始页只取本地记录（`lib/src/pages/komga/komga_page.dart` 的 `_openBook`），阅读器 5 秒内上报当前页。服务器上较新的进度（例如在 Komga 网页端读完）会被改回第 1 页、阅读中。
2. **读到最后也不记为读完。** 各布局记录第一张可见图片（例如 `horizontal_double_column_layout_logic.dart` 的 `_readProgressListener`），而已读判定要求记录到最后一页（`komga_browse_models.dart` 的 `readingStatus`）。双页和滚动布局的最后一屏通常记为倒数第二页。
3. **上报失败不补发。** `ReadProgressFlushCoordinator` 失败只记日志，退出阅读器时不等待上报。
4. **导入时直接比较两个时钟。** Komga 的 readDate 取服务器时钟、秒精度；本地 utime 取设备时钟、毫秒精度。
5. **全量导入的分页没有固定顺序。** `KomgaClient._getReadProgressBooks` 不传排序参数。
6. **API 密钥被拒绝时提示不明确。** 保持"填了密钥就只发送密钥"的行为，只改错误提示。

## 2. 目标

- JHenTai 与 Komga 之间的阅读进度双向同步，以较新的进度为准。
- 任何一次上报失败都会在之后补发，补发前与服务器核对，不覆盖更新的服务器进度。
- 读到结尾时可靠地记为读完，Komga 同步标记为已读。
- "未读"能经 JHenTai 云同步在设备间传播，不被旧记录写回。

## 3. 术语与数据表示

- **进度记录键**：`komga:<connectionId>:<bookId>`，沿用现有 `KomgaClient.progressRecordKey`。
- **本地进度值**：`readIndexRecord` 中的字符串。非空为页序号（从 0 开始）；**空字符串表示未读**（空值记录）。没有记录与空值记录同样视为未读。
- **服务器状态 S**：`(page, completed, readDate)`；服务器上没有进度时 S 为"无进度"。
- **服务器状态折算为本地进度值**：`completed` 为真时取 `pageCount - 1`；否则取 `page - 1`，限制在 `[0, pageCount - 1]`；无进度时取空字符串。
- **本地进度值折算为上报内容**：页序号 `i` 发送 `PATCH /api/v1/books/{id}/read-progress {"page": i + 1}`（`i + 1 == pageCount` 时 Komga 自动记为读完）；空字符串发送 `DELETE /api/v1/books/{id}/read-progress`。
- **同步基准 B**：双方最后一次确认一致时的状态，包含 `serverPage`（可为空，表示无进度）、`serverCompleted`、`localValue`、`localUtime`。

### 3.1 存储

| 数据 | 位置 | 云同步 |
|---|---|---|
| 本地进度值 | `local_config`，`ConfigEnum.readIndexRecord`，子键为记录键 | 是（现有 oplog 引擎） |
| 同步基准 | `local_config`，新增 `ConfigEnum.komgaProgressBase`，子键为记录键，值为 JSON | 否 |
| 待核对清单 | `local_config`，新增 `ConfigEnum.komgaProgressPending`，子键为记录键，值为 JSON `{"connectionId","bookId"}` | 否 |

基准和清单只描述本机与服务器的关系，不加入 `CloudConfigTypeEnum`，也不进入 oplog。

### 3.2 空值记录的兼容性

直接读取进度值的代码（`download_search_logic.dart`、`local_gallery_download_page_logic_mixin.dart` 等）都使用 `int.tryParse(值) ?? 0`，会把空值读作 0。旧版本程序同样读作 0：对 E-Hentai 画廊即"从头开始"，符合重置语义；对 Komga 书显示为第 1 页阅读中，只影响显示。

## 4. 冲突规则

实现为不依赖界面和网络的纯函数：

```
resolve(server: S, local: (value, utime)?, base: B?, pageCount) -> Decision
Decision = none | pushLocal | applyServer | updateBaseOnly
```

判定顺序：

1. 服务器折算值等于本地值（无记录按空字符串计）：双方都未读且没有基准时为 `none`（不为从未读过的书建立基准）；基准已一致时为 `none`；其余为 `updateBaseOnly`。
2. 没有基准（第一次接触这本书）：
   - 只有一方有进度：取有进度的一方（服务器有进度则 `applyServer`，本地有进度则 `pushLocal`）。
   - 双方都有进度：比较服务器 readDate 与本地 utime，较新者胜；相等时取服务器。
3. 有基准时，计算：
   - `serverChanged`：`(S.page, S.completed)` 与 `(B.serverPage, B.serverCompleted)` 不同。服务器无进度按 `(null, false)` 计。
   - `localChanged`：`(本地值, 本地 utime)` 与 `(B.localValue, B.localUtime)` 不同。

| serverChanged | localChanged | 结果 |
|---|---|---|
| 否 | 否 | `none` |
| 否 | 是 | `pushLocal` |
| 是 | 否 | `applyServer` |
| 是 | 是 | 比较 readDate 与本地 utime，较新者胜（服务器胜为 `applyServer`，本地胜为 `pushLocal`）；相等时取服务器 |

服务器无进度时没有 readDate；第 3 步冲突情形下，若服务器为无进度，视为服务器一方时间未知，取本地（`pushLocal`）。

执行结果：

- `applyServer`：用当前时间写入本地进度值（非空走 `updateReadProgress`，空字符串写空值记录），登记云同步，然后令基准等于 `(S, 新本地值, 新 utime)`。使用当前时间是为了让其他 JHenTai 设备在云同步时接受这条更新。
- `pushLocal`：按 3 节折算上报；成功后令基准等于 `(上报后的服务器状态, 本地值, 本地 utime)`。上报后的服务器状态：页序号 `i` 对应 `page = i + 1`、`completed = (i + 1 == pageCount)`；空字符串对应无进度。
- `updateBaseOnly`：只写基准。

## 5. 组件

### 5.1 `KomgaProgressState`（新文件 `lib/src/model/komga/komga_progress_state.dart`）

值类型（服务器状态、本地状态、基准）、两个折算函数和 `resolve`。不依赖 Flutter、数据库或网络。

### 5.2 `KomgaClient`（`lib/src/network/komga_client.dart`）

- 新增 `getBook(bookId)`：`GET /api/v1/books/{id}`，返回 `KomgaBook`（含 readProgress）。
- 新增 `deleteReadProgress(bookId)`：`DELETE /api/v1/books/{id}/read-progress`。
- `_getReadProgressBooks` 加固定排序（`readProgress.readDate,desc` 与 `name,asc`），旧接口回退同样处理。
- `friendlyError`：返回 401 且请求头带 `X-API-Key` 时，返回新文案 `komgaApiKeyRejected`。判断依据为 `DioException.requestOptions.headers`，不依赖客户端实例。

### 5.3 `ReadProgressService`（`lib/src/service/read_progress_service.dart`）

- `_entryFromRecord` 对空值记录返回 null；`getReadProgressEntriesByKeys` 相应跳过。
- `deleteReadProgress(key)` 改为写入空值记录（当前时间）并登记云同步，不再删除行。调用方（E-Hentai 详情页"重置阅读进度"）不变。
- 新增 `getProgressRecords(keys)`：一次查询批量返回原始 `(value, utime)`，包括空值记录，供冲突规则使用。
- `importReadProgressEntries` 在 Komga 导入改走新服务后若无其他调用者则删除。

### 5.4 `KomgaProgressSyncService`（新文件 `lib/src/service/komga_progress_sync_service.dart`）

全局实例，按现有 `JHLifeCircleBean` 方式注册。所有操作经同一个异步互斥串行执行，避免上报与补发同时处理同一本书。

| 方法 | 用途 |
|---|---|
| `reconcileBooks(client, books)` | 书籍列表返回后，批量读取本地进度与基准，用列表自带的 readProgress 逐本执行 `resolve`；本地写入合并为一次批量写；需要上报的书登记清单并发送。不增加查询请求 |
| `reconcileBeforeOpen(client, book) -> int` | 打开书前 `getBook` 取最新状态，执行 `resolve`，返回起始页序号。请求失败时返回本地进度 |
| `report(client, book, imageIndex)` | 阅读器上报：登记清单 → 发送 → 成功则移出清单并更新基准，失败则保留 |
| `drainPending(client)` | 补发：逐条 `getBook` 后执行 `resolve` 并执行结果 |
| `syncAll(client)` | "与 Komga 同步阅读进度"按钮：取服务器上全部有进度的书，并合并本连接下本地有进度的记录键（不在服务器列表中的视为服务器无进度），逐本执行 `resolve` |

补发时机：Komga 页面初始化与刷新时；应用回到前台时（`AppManager.registerDidChangeAppLifecycleStateCallback`）；应用启动后。后两者仅在 Komga 已配置且清单不为空时执行。

### 5.5 阅读器（`lib/src/pages/read/`）

- `ReadPageLogic.recordReadProgress(int index, {bool reachedEnd = false})`：`currentImageIndex` 保持原含义（页码显示、翻页不变）；另存 `reachedEnd`。保存进度时使用 `reachedEnd ? pageCount - 1 : currentImageIndex`。
- 各布局计算 `reachedEnd`：
  - 单页翻页：当前页为最后一页。
  - 双页：当前屏的图片序号包含最后一页。
  - 纵向/横向滚动：可见项中包含最后一页，且其末端位置 `itemTrailingEdge <= 1`。
- `ReadPageInfo.reportReadProgress` 的注释改为"向远端来源上报进度"，签名不变。

### 5.6 Komga 页面（`lib/src/pages/komga/komga_page.dart`）

- `_openBook`：起始页改用 `reconcileBeforeOpen`；上报回调改为 `komgaProgressSyncService.report`。
- 书库内容加载完成后调用 `reconcileBooks`。
- 顶部按钮调用 `syncAll`，结果提示改为"已同步 N 本书的进度"/"已是最新"。
- `_initialize` 与 `_refreshCurrent` 调用 `drainPending`。

### 5.7 文案（6 个语言文件同步）

- `komgaProgressSyncHint`："阅读进度与 Komga 双向同步，以较新的进度为准。"
- `komgaImportProgress`："与 Komga 同步阅读进度"；`komgaImportProgressImported`："已同步 @count 本书的进度"；`komgaImportProgressUpToDate`："阅读进度已是最新"。
- 新增 `komgaApiKeyRejected`："API 密钥被拒绝。请确认密钥有效；Komga 1.20 之前的版本不支持用 API 密钥访问，可改用用户名和密码。"

## 6. 错误处理

| 情况 | 处理 |
|---|---|
| 401 / 403 | 本轮补发停止，清单保留 |
| 404（书已不在服务器上） | 移除清单项与基准 |
| 网络错误、超时 | 本轮补发停止，清单保留 |
| 清单项的 connectionId 与当前连接不同 | 丢弃该清单项 |
| `reconcileBeforeOpen` 请求失败 | 使用本地进度打开，不阻止阅读 |
| 进程在"写本地"与"登记清单"之间被结束 | 下次该书出现在列表或被打开时，本地相对基准已变、服务器未变，按规则补报 |

## 7. 测试

1. `resolve`：第 4 节每条判定，以及页码相同只更新基准、服务器无进度、本地为空值记录、没有本地记录、页序号越界被限制。
2. `KomgaProgressSyncService`：假的 Komga 客户端加 `AppDb.forTesting(NativeDatabase.memory())`，覆盖发送成功/失败后的清单状态、补发时上报与采用服务器进度两种走向、404/401/网络错误、其他连接的清单项被丢弃、设备 A 离线进度经云同步到达设备 B 后由 B 上报、`syncAll` 对服务器无进度书的处理。
3. `ReadProgressService`：空值记录读取为无进度；`deleteReadProgress` 写入空值记录并登记云同步。
4. 读完判定：双页、纵向滚动、横向滚动的"到结尾"与"未到结尾"，包括离开结尾后恢复。
5. `friendlyError`：带 API 密钥的 401 返回新文案，其他错误不变。
6. 更新现有 Komga 测试（`komga_browse_page_test.dart` 中的导入流程等），全量测试通过。
7. 真实服务器验证：macOS 构建连接用户服务器，读一本书后查询服务器进度。执行前征得用户同意，并由用户指定书目。

## 8. 约束

- 所有设备都需升级到包含本改动与 `431a8e61` 同步修复的版本。旧版本仍按单向上报工作，会继续存在缺陷 1。
- 现有接口要求：`GET /api/v1/books/{id}`、`PATCH`/`DELETE /api/v1/books/{id}/read-progress` 在 Komga 0.x 已存在；`POST /api/v1/books/list` 为 1.19.0+，已有旧接口回退。
