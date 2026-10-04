# Komga 浏览、搜索、首页、阅读器集成与离线下载设计

日期：2026-10-04
前置：`2026-10-04-komga-progress-sync-design.md`（进度双向同步，已实现）

## 1. 依据

接口行为以 Komga 1.23.6 源码（tag `1.23.6`，提交 `ced89c5`）为准，并对真实服务器做了只读核对。

### 1.1 接口事实（源码）

| 能力 | 接口 | 要点 |
|---|---|---|
| 列表 | `POST /api/v1/series/list`、`POST /api/v1/books/list` | 请求体 `{condition, fullTextSearch}`；条件用 `allOf`/`anyOf` 组合，叶子形如 `{"libraryId":{"operator":"is","value":"…"}}`；`deleted` 用 `{"operator":"isFalse"}`；`author` 的值为 `{"name":…, "role":…}`；有 `fullTextSearch` 且未指定排序时按相关度排序 |
| 分页上限 | Spring Data 默认 | 每页最多 2000 条 |
| 首页 | `GET /api/v1/books/ondeck`、`GET /api/v1/series/new`、`GET /api/v1/series/updated` | new/updated 支持 `library_id`、`deleted`、`oneshot` 参数 |
| 单本、相邻 | `GET /api/v1/books/{id}`、`/next`、`/previous` | 按 numberSort；没有相邻本时 404 |
| 系列 | `GET /api/v1/series/{id}`；`POST`/`DELETE /api/v1/series/{id}/read-progress` | 整个系列标记已读/未读 |
| 书进度 | `PATCH /api/v1/books/{id}/read-progress`、`DELETE …` | `page` 必须在 1..页数；`completed=true` 时页数取总页数；readDate 存为 UTC，序列化为秒精度 `…Z` |
| 页面 | `GET /api/v1/books/{id}/pages`、`/pages/{n}`、`/pages/{n}/thumbnail` | 页面需 PAGE_STREAMING 角色；`convert=jpeg|png`；页面缩略图最长边 300px；页列表含 `fileName` |
| 文件下载 | `GET /api/v1/books/{id}/file`（CommonBookController）、`GET /api/v1/series/{id}/file` | 需 FILE_DOWNLOAD 角色；以附件形式返回原始文件 |
| 参考数据 | `GET /api/v1/tags`、`/genres`、`/publishers`、`/languages`、`/age-ratings`、`/api/v1/series/release-dates`、`GET /api/v2/authors` | 1.23.6 上标签等为 v1；作者 v2 分页，支持 `search`、`library_id` |

### 1.2 真实书库（只读核对）

- 系列约一半有出版社、语言和作者（作者来自书元数据聚合）；没有简介、标签、类型、发行日期、外部链接；连载状态均为默认值；16 个系列设置了从右到左的阅读方向。
- 书没有作者、标签、简介、发行日期；卷号均为整数。
- 页面格式只有 JPEG、PNG。

## 2. 范围

1. 浏览结构：页面内部层级栈；服务端分页与无限滚动；服务端排序与筛选；排除已删除条目；系列内排序独立且默认按卷号升序。
2. 系列详情头部：有值的元数据、已读/阅读中/未读本数、"继续阅读"按钮；作者、出版社、语言、标签、类型可点击，进入对应筛选结果。
3. 搜索与筛选：全文搜索系列和书（跨书库）；筛选面板按服务器上实际有值的类别显示（阅读状态、作者、出版社、语言、标签、类型）。
4. 首页：继续阅读、待读、最近新增系列、最近更新系列、书库列表、已下载。
5. 标记已读/未读：书和整个系列，长按菜单操作。
6. 阅读器集成：下一本/上一本、按系列阅读方向、页面缩略图、不受支持的图片格式转换。
7. 离线下载：下载书或整个系列，离线阅读，离线期间的进度联网后补发。
8. EPUB 判定：非图片型 EPUB 标注"无法在此阅读"。

不在范围内：收藏集、阅读列表、单行本（服务器上为 0）；复用登录会话（实测每次请求仅节省 2–3 毫秒）。

## 3. 设计

### 3.1 查询与客户端

- `KomgaQuery`：目标（系列/书）、书库、系列、全文关键词、筛选条件（阅读状态、作者、出版社、语言、标签、类型）、排序。由它生成请求体：所有条件用 `allOf` 组合，并始终附加 `deleted isFalse`。
- 排序映射：添加时间 → `createdDate`；最近阅读 → 系列 `readDate`、书 `readProgress.readDate`；标题 → 系列 `metadata.titleSort`、书 `metadata.title`；卷号 → `metadata.numberSort`；搜索时默认相关度。每种排序附加次要键（系列 `metadata.titleSort`、书 `metadata.numberSort`），加载时按编号去重。
- "新添加"筛选：按添加时间倒序加载，遇到早于该书库上次访问时间的条目即停止。
- `KomgaClient` 新增：分页列表、单个系列、待读、最近新增/更新系列、继续阅读书单、相邻书、系列标记已读/未读、书标记已读、参考数据、文件下载（带进度回调）。`bookPageUrl` 对 JPEG/PNG/GIF/WebP/BMP 以外的页面附加 `convert=png`。

### 3.2 页面结构

`komga_page.dart` 现有 1900 余行，按职责拆分：

- `komga_page.dart`：外壳（抽屉、顶栏、层级栈、返回）。
- `komga_home_view.dart`：首页分区。
- `komga_list_view.dart`：分页列表（系列/书），含工具栏、筛选面板、底部加载状态。
- `komga_series_header.dart`：系列详情头部。
- `komga_item_widgets.dart`：卡片、列表、详情三种条目样式与长按菜单。
- `komga_paged_loader.dart`：分页加载（首页、下一页、去重、出错保留已有条目、提前停止）。

层级：首页 → 书库 / 搜索结果 / 筛选结果 / 已下载 → 系列。每层保存自己的查询、条目、分页和滚动位置；返回时直接恢复。

### 3.3 进度与阅读状态

- 每加载一页书，用其自带的服务器进度调用 `reconcileBooks`。
- 书的状态显示本地进度；系列的状态显示服务器返回的已读/阅读中/未读本数。
- 标记书已读：本地写入最后一页并上报；标记未读：本地写入空值记录并上报（DELETE）。标记系列：先调用系列接口，再取该系列全部书执行 `reconcileBooks`，把服务器状态同步到本地。
- "继续阅读"：查询该系列阅读中的书（按 `readProgress.readDate` 倒序取第一本）；没有则取卷号最小的未读本；全部读完则从第一卷重读。

### 3.4 阅读器

- `ReadPageInfo` 增加 `loadSiblingBook`（异步取上一本/下一本的 `ReadPageInfo`）与 `readDirectionOverride`。
- 读到最后一页继续翻页时，提示并提供"下一本"；顶部菜单提供上一本/下一本。切换时替换当前阅读页。
- Komga 阅读方向映射：从左到右 → 从左到右翻页；从右到左 → 从右到左翻页；纵向、条漫 → 纵向滚动。用户当前为双页模式时保留双页。系列未设置时使用用户设置。
- `GalleryImage` 增加缩略图地址，阅读器缩略图条优先使用页面缩略图接口。

### 3.5 离线下载

- 存储：`<下载目录>/komga/<connectionId>/<bookId>/`，内含按 Komga 页列表顺序解出的图片与 `manifest.json`（书数据、页列表、系列标题、阅读方向、下载时间）。
- 流程：取页列表 → 下载原始文件（ZIP/CBZ/EPUB 均为 ZIP 容器）→ 按页列表的 `fileName` 依次解出 → 写 manifest → 删除原始文件。下载按队列顺序进行，显示进度，失败可重试。
- 阅读：已下载的书直接用本地图片打开，不需要网络；进度键与在线阅读相同，上报失败进入待核对清单，联网后补发。
- 管理：首页"已下载"层列出全部已下载书（离线可用）；长按菜单下载、删除；系列可整体下载。服务器不可达时首页仍可进入"已下载"。

### 3.6 EPUB

`KomgaBook` 解析 `media.epubDivinaCompatible`；可读条件增加"非 EPUB 或可按图片页阅读"。不可读的书标注并在点击时提示原因。

## 4. 验证

- 端到端测试位于 `test/e2e/`，读取 `test/e2e/komga_e2e.json`（已加入 `.gitignore`，示例为 `komga_e2e.example.json`），文件不存在时跳过。测试使用应用自己的客户端、服务与页面，经真实网络连接真实 Komga，断言服务器返回与界面结果。
- 写操作只作用于配置中指定的系列，测试结束恢复该系列的阅读进度，下载文件写入临时目录并删除。
- 全量测试必须通过。
