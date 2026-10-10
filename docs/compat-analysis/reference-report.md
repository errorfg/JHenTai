# 参考项目代码分析报告

## 项目1: NClientV3 (Android nhentai 客户端)

仓库: `maxwai/NClientV3`，Java，Android 原生应用。

### 搜索方式: HTML 解析为主，JSON API 仅用于评论和收藏

NClientV3 **不使用** nhentai 的 JSON API (`/api/gallery/`) 进行搜索和列表获取。搜索和浏览全部通过 **HTML 解析** 完成：

- `InspectorV3.createDocument()` 用 OkHttp 请求 HTML 页面，然后用 Jsoup 解析
- `InspectorV3.doSearch()` 解析 HTML 中 class 为 `gallery` 的元素来提取搜索结果
- `InspectorV3.doSingle()` 解析单个画廊页面中的 `<script>` 标签，提取其中嵌入的 JSON 数据（`JSON.parse(...)` 部分）

JSON API 仅在以下场景使用：
- **评论**: `GET {baseUrl}/api/gallery/{id}/comments` (`CommentsFetcher`)
- **提交评论**: `POST {baseUrl}/api/gallery/{id}/comments/submit` (`CommentActivity`)
- **删除评论**: `POST {baseUrl}/api/comments/{id}/delete` (`CommentAdapter`)
- **收藏/取消收藏**: `POST {baseUrl}/api/gallery/{id}/favorite` 或 `unfavorite` (`GalleryActivity`)

### CDN 子域名

NClientV3 使用固定前缀的 CDN 子域名，`host` 部分可配置（默认 `nhentai.net`，支持镜像站）：

| 用途 | 子域名格式 | 示例 |
|------|-----------|------|
| 缩略图/封面 | `t1.{host}` | `https://t1.nhentai.net/galleries/{mediaId}/thumb.jpg` |
| 全尺寸图片 | `i1.{host}` | `https://i1.nhentai.net/galleries/{mediaId}/{page}.jpg` |
| 低质量缩略图 | `t1.{host}` | `https://t1.nhentai.net/galleries/{mediaId}/{page}t.jpg` |
| 用户头像 | `i.{host}` | `https://i.nhentai.net/{avatarUrl}` |

图片路径结构: `/galleries/{mediaId}/{filename}.{ext}`

- `mediaId` 是 nhentai 内部的媒体 ID（不同于画廊 ID `galleryId`）
- 封面: `cover.{ext}`
- 缩略图: `thumb.{ext}`
- 页面图片: `{pageNumber}.{ext}`（1-based）
- 低质量页面: `{pageNumber}t.{ext}`（thumbnail variant）

### 数据获取方式

**核心流程**（`InspectorV3`）:

1. **构建 URL**：根据请求类型拼接 HTML 页面 URL
   - 主页浏览: `{baseUrl}?page={page}`
   - 搜索: `{baseUrl}/search/?q={query}+{tags}&page={page}&sort={sortType}`
   - 按标签: `{baseUrl}/search/?q={tag:\"name\"}&page={page}`
   - 单个画廊: `{baseUrl}/g/{id}`
   - 收藏: `{baseUrl}/favorites/?q={query}&page={page}`
   - 随机: `{baseUrl}/random/`
   - 随机收藏: `{baseUrl}/favorites/random`

2. **请求并解析 HTML**：用 OkHttp 发送请求，Jsoup 解析 HTML

3. **提取数据**：
   - **搜索结果**: 解析 `.gallery` 元素 -> `SimpleGallery`
     - `data-tags` 属性获取标签 ID 列表
     - `<a>` 的 `href` 解析画廊 ID（格式: `/g/{id}/`）
     - `<img>` 的 `data-src` 或 `src` 解析缩略图 URL 和 mediaId
   - **单个画廊**: 解析 `<script>` 标签中的嵌入 JSON -> `Gallery` -> `GalleryData`
     - JSON 字段: `id`, `media_id`, `title`, `tags`, `images`, `upload_date`, `num_favorites`, `num_pages`
   - **分页**: 解析 `.last` class 元素的 `href` 获取总页数

4. **搜索查询格式**:
   - 标签查询: `{type}:"{name}"`（例如: `language:"english"`）
   - 排除标签: `-{type}:"{name}"`
   - 排序参数: `sort=popular`, `sort=popular-week`, `sort=popular-today`, `sort=popular-month`
   - 页数范围: 通过 `Ranges` 对象添加到查询串

**镜像站支持**:
- 默认域名: `nhentai.net`
- 可在设置中配置 `mirror`，所有 URL 中的 host 部分替换为镜像域名
- `Utility.getHost()` -> `Global.getMirror()` -> SharedPreferences 存储

**标签数据**:
- 从 GitHub 仓库定期同步标签数据: `https://raw.githubusercontent.com/maxwai/NClientV3/main/data/tags.json`
- JSON 数组格式: `[id, name, count, typeId]`
- 每 7 天检查一次更新

---

## 项目2: wnacg-downloader (Tauri/Rust wnacg 下载器)

仓库: wnacg-downloader，Tauri v2 + React 前端，Rust 后端。

### 默认域名

```rust
const DEFAULT_API_DOMAIN: &str = "www.wn07.ru";
```

支持自定义域名，通过 `ApiDomainMode` 枚举切换：
- `Default`: 使用 `www.wn07.ru`
- `Custom`: 使用用户配置的 `custom_api_domain`

所有请求都基于 `https://{api_domain}/` 构建。

### 搜索 URL 格式

**关键词搜索**:
```
GET https://{api_domain}/search/index.php?q={keyword}&syn=yes&f=_all&s=create_time_DESC&p={page_num}
```
参数:
- `q`: 搜索关键词
- `syn`: `yes`（同义词搜索）
- `f`: `_all`（搜索所有字段）
- `s`: `create_time_DESC`（按创建时间降序排列）
- `p`: 页码

**标签搜索**:
```
GET https://{api_domain}/albums-index-page-{page_num}-tag-{tag_name}.html
```

**漫画详情页**:
```
GET https://{api_domain}/photos-index-aid-{id}.html
```

**图片列表页**:
```
GET https://{api_domain}/photos-gallery-aid-{id}.html
```

**书架/收藏**:
```
GET https://{api_domain}/users-users_fav-page-{page_num}-c-{shelf_id}.html
```

**登录**:
```
POST https://{api_domain}/users-check_login.html
form: { login_name, login_pass }
```

**用户信息**:
```
GET https://{api_domain}/users.html
```

### CSS Selector 汇总

全部使用 `scraper` crate（Rust 版 CSS selector 引擎）解析 HTML。

#### 搜索结果页 (`SearchResult::from_html`)

| 目标 | CSS Selector | 提取方式 |
|------|-------------|---------|
| 漫画列表项 | `.li.gallary_item` | 遍历每个 `<li>` |
| 当前页码 | `.thispage` | `<span>` 的文本内容 |
| 总页数(标签搜索) | `.f_left.paginator > a`(最后一个) | `<a>` 的文本 |
| 总结果数(关键词搜索) | `#bodywrap .result > b` | `<b>` 的文本，每页24条计算总页数 |

#### 搜索结果中的漫画项 (`ComicInSearch::from_li`)

| 目标 | CSS Selector | 提取方式 |
|------|-------------|---------|
| 标题链接 | `.title > a` | `href` 属性: `/photos-index-aid-{id}.html` |
| 标题文本 | `.title > a` | `title` 属性（带HTML标签版本），`text()`（纯文本版本） |
| 封面图 | `img` | `src` 属性，加 `https:` 前缀 |
| 额外信息 | `.info_col` | `<div>` 的文本内容 |

#### 漫画详情页 (`Comic::from_html`)

| 目标 | CSS Selector | 提取方式 |
|------|-------------|---------|
| 漫画 ID | `head > link` | `href` 属性: `/feed-index-aid-{id}.html` |
| 标题 | `#bodywrap > h2` | `<h2>` 的文本内容 |
| 封面 | `.asTBcell.uwthumb > img` | `src` 属性，去掉前导 `/`，加 `https://` |
| 分类 | `.asTBcell.uwconn > label`(第1个) | 文本去掉 `分類：` 前缀 |
| 图片数量 | `.asTBcell.uwconn > label`(第2个) | 文本去掉 `頁數：` 前缀和 `P` 后缀 |
| 标签 | `.tagshow` | 遍历每个 `<a>`，提取文本和 `href` |
| 简介 | `.asTBcell.uwconn > p` | `<p>` 的 HTML 内容 |

#### 书架页 (`GetShelfResult::from_html`)

| 目标 | CSS Selector | 提取方式 |
|------|-------------|---------|
| 漫画列表 | `.asTB` | 遍历每个 `<div>` |
| 当前页码 | `.thispage` | `<span>` 的文本 |
| 总页数 | `.f_left.paginator > a`(最后一个) | `<a>` 的文本 |
| 当前书架 | `.cur` | `href`: `/users-users_fav-c-{id}.html` |
| 书架列表 | `.nav_list > a` | `href` 和文本 |

#### 书架中的漫画 (`ComicInShelf::from_div`)

| 目标 | CSS Selector | 提取方式 |
|------|-------------|---------|
| 标题链接 | `.l_title > a` | `href`: `/photos-index-aid-{id}.html`，文本为标题 |
| 封面 | `.asTBcell.thumb img` | `src` 属性，加 `https:` 前缀 |
| 收藏时间 | `.l_catg > span` | 文本去掉 `創建時間：` 前缀 |
| 所属书架 | `.l_catg > a` | `href`: `/users-users_fav-c-{id}.html` |

#### 用户信息页 (`UserProfile::from_html`)

| 目标 | CSS Selector | 提取方式 |
|------|-------------|---------|
| 未登录检测 | `.title.title_c` | 存在则未登录 |
| 头像+用户名 | `.top_utab.ui > a` | `<a>` 内的 `<img>` 的 `src` 为头像，`<a>` 的文本为用户名 |

### 图片列表获取

图片列表通过专门的页面获取: `https://{api_domain}/photos-gallery-aid-{id}.html`

解析方式 **不是** CSS selector，而是从 HTML 中提取 **JavaScript 变量**：

1. 找到包含 `var imglist = ` 的行
2. 提取 `[` 到 `]` 之间的 JSON 内容
3. 进行字符串替换使其成为合法 JSON：
   - `url:` -> `"url":`
   - `caption:` -> `"caption":`
   - `fast_img_host+` -> 移除（这是 JS 变量拼接）
   - `\"` -> `"`
4. 解析为 `ImgList`（`Vec<ImgInImgList>`）

每个 `ImgInImgList` 包含：
- `url`: 图片路径，格式如 `//img5.wnimg.ru/data/2826/33/01.jpg`（缺少 `https:` 前缀）
- `caption`: 图片序号，如 `[01]`, `[001]`

注意：最后一张图片 URL 为 `/themes/weitu/images/bg/shoucang.jpg`（收藏提示图），下载时需过滤。

下载时的图片 URL 构建：`https:{url}`（即加上 `https:` 前缀）。

### 下载流程

1. 调用 `get_comic(id)` 获取漫画详情（HTML 解析）+ 图片列表（JS 变量解析）
2. 创建临时下载目录: `.下载中-{title}/`
3. 保存元数据: `元数据.json`（Comic 的 JSON 序列化）
4. 并发下载图片（信号量控制并发数，默认 comic 2 并发，img 10 并发）
5. 支持格式转换（JPEG/PNG/WebP，GIF 保持原格式）
6. 下载完成后重命名目录为 `{title}/`
7. 支持暂停/恢复/取消
