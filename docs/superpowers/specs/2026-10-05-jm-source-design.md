# JM（禁漫天堂）来源接入设计

## 1. 目标

按 nhentai、wnacg 的方式接入 JM：搜索、浏览、详情、在线阅读、下载、本地收藏、历史与云同步都使用本应用已有的页面、阅读器和下载服务，只把数据来源换成 JM 的移动端接口。

## 2. 依据

- 接口规则来自开源实现 hect0x7/JMComic-Crawler-Python（`jm_config.py`、`jm_client_impl.py`、`jm_toolkit.py`）。用户给出的 ComicSparks/jasmine 只剩界面层，其接口实现所在的 niuhuan/jasmine-rs-core 已不公开。
- 2026-10-05 在本机用只读请求核对过真实接口：域名服务器、`/setting`、`/search`、`/categories`、`/categories/filter`、`/album`、`/chapter`、`/chapter_view_template`、`/forum`、图片与封面。图片还原算法用真实图片做了数值验证：原图在预测的条带边界出现明显断层，还原后断层消失。

## 3. 接口规则

- 接口域名：内置 `www.cdnhjk.net`、`www.cdngwc.cc`、`www.cdngwc.net`、`www.cdngwc.club`；启动后从三个域名服务器之一获取最新列表（响应去掉开头非 ASCII 字符后，按下文解密，密钥 `diosfjckwpqpdfjkvnqQjsik`，取 `Server` 字段）。请求失败时依次换下一个域名。
- 请求头：`token = md5(ts + secret)`，`tokenparam = "ts,2.1.7"`，`user-agent` 使用参考实现中的安卓 WebView 标识。`secret` 一般为 `185Hcomic3PAPP7R`；`/chapter_view_template` 使用 `18comicAPPContent` 且必须用当前时间戳。
- 响应：`{code, errorMsg, data}`，`data` 为 Base64，AES-ECB 解密，密钥为 `md5(ts + 185Hcomic3PAPP7R)` 的 32 个十六进制字符，去掉 PKCS7 填充后是 JSON。
- 首次请求前调用一次 `/setting` 获取 cookies，之后的接口请求携带这些 cookies。
- 图片域名：`cdn-msp.jmapiproxy1.cc` 等 6 个，图片地址 `https://{图片域名}/media/photos/{章节ID}/{文件名}`，封面 `https://{图片域名}/media/albums/{本子ID}_3x4.jpg`。
- 图片切割：`scramble_id` 由 `/chapter_view_template` 的 `var scramble_id = (\d+);` 得到，取不到时用 220980。段数：章节 ID 小于 `scramble_id` 为 0（不切割）；小于 268850 为 10；否则 `x = 章节ID < 421926 ? 10 : 8`，`段数 = (md5(章节ID + 文件名去扩展名) 最后一个字符的码值 % x) * 2 + 2`。还原：把图片按高度等分成段数条（余数归第一条），原图自下而上的第 i 条放到结果自上而下的第 i 个位置。

## 4. 标识与数据模型

- 阅读和下载的单位是**章节**。本子的第一章 ID 等于本子 ID，所以单章节本子与 nhentai 的画廊完全对应；多章节本子的每一章是一个独立画廊。
- `GalleryUrl` 增加 `isJM`；规范地址 `https://18comic.vip/photo/{章节ID}`，与当前选择的线路无关，保存后不会因换线路而失效。可解析 18comic 各域名的 `/album/{id}` 与 `/photo/{id}`。`token` 占位为 `jmcomic`。
- `gid = 9000000000 + 章节ID`。原因：下载表、历史表等以 gid 为主键，JM 的 ID 与 E-Hentai 的 gid 处于同一数值范围，直接使用会互相覆盖。阅读进度键、历史、下载记录都随 gid 区分。
- 章节详情接口的 `series_id` 为所属本子 ID（为 0 时即本章节本身），本子元数据（作者、标签、观看、喜欢、简介、章节列表）从 `/album` 读取。
- 分类按 E-Hentai 分类名归一，保证列表卡片颜色可用：同人→Doujinshi，单本、短篇、韩漫→Manga，English Manga→Western，Cosplay→Cosplay，其他→Misc。
- 标签：作者→`artist`，作品→`parody`，角色→`character`，其余标签→`tag`。

## 5. 功能

- **搜索**：站点选择器增加 JM；关键词前缀 `jm:`；空关键词时显示最新（`/categories/filter`，按最新排序）；输入车号时直接返回该本子。JM 搜索使用 MySQL 布尔全文语法（2026-10-05 实测：空格分隔为“或”，`+词` 为“且”，`-词` 为“非”），用户输入的文字原样传递；标签与上传者（`namespace:"value$"`）转换为 `+词`，多选标签即要求全部命中。
- **详情页**：标题、封面、分类、页数、标签、观看与喜欢数；多章节本子显示章节行（第 i/N 章与章节名），点击打开章节列表，选择后进入该章节的详情页；评论只读（`/forum`）；“相似画廊”显示接口给出的相关本子，没有时按标题在 JM 中搜索；保留“在 E-Hentai 中搜索”。不提供评分、种子、归档、H@H、统计、添加标签、Telegraph 发送。手动刷新会丢弃本子与章节缓存，以便看到新增章节。
- **在线阅读**：缩略图与阅读都使用章节图片（JM 没有单独的页面缩略图）；图片在显示前还原。多章节本子在阅读器里可以切换上一章、下一章（复用 Komga 的相邻书机制）。阅读进度按章节记录。
- **下载**：按章节下载；需要还原的图片在下载后还原并以 JPEG（质量 92）保存，不需要还原的原样保存。多章节本子在详情页章节行中可以一次加入全部未下载的章节，默认分组为本子名。标签定时刷新只向 E-Hentai 接口提交 E-Hentai 画廊：该接口对其他来源的画廊返回错误条目，会使同一批全部解析失败（nhentai、wnacg 原本也受影响）。
- **收藏**：本地收藏，与 wnacg 共用 `LocalSourceFavoriteService`；收藏页增加 JM 来源，参与混合显示；云同步新增类型 12，按每个画廊最新的收藏时间合并。8.0.27 及更早的客户端遇到未知类型码会把整份远端配置当作首次同步并覆盖远端，因此所有同步设备需先升级到 8.0.28 及以后的版本。
- **设置**：高级设置新增 JM 页面，可选择接口线路与图片线路；设置单独保存，不放在登出时会清空的 EHSetting 中。
- **线路选择**（2026-10-06）：域名服务器只给出「線路1–5」，不标注地区；`/setting` 返回 `ipcountry`、`is_cn`、`cn_base_url` 与随请求变化的推荐图片域名 `img_host`。实测（本机出口为美国）線路1 `www.cdnhjk.net` 的 `/setting` 用时 3979 ms，線路3 `www.cdngwc.net` 为 509 ms；同一页图片（约 900 KB）在 `cdn-msp.jmapiproxy1.cc` 用时 3.7 s，在 `cdn-msp.jmapinodeudzn.net` 为 0.9 s。因此「自动」不再固定使用列表第一项，而是在本机测速后使用最快的线路：接口线路各发一次 `/setting`，图片线路各取一次小文件 `/media/logo/new_logo.png`，并行进行、每项 10 秒超时，每天最多一次；首次测速在第一次请求前完成，之后在后台进行；设置页可手动测速并显示各线路用时。服务器推荐的图片域名加入可选线路，在没有测速结果时使用。测速结果按设备保存，不参与云同步。

## 6. 账号登录

- **入口**：账号设置页保留一个“登录”入口（与原 E-Hentai 登录同一层级），只要还有站点未登录就显示；每个已登录的站点各占一行，显示账号并提供登出。
- **登录页**：原来的“EHenTai”标题换成站点下拉菜单（E-Hentai、nhentai、JM），只列出尚未登录的站点；全部登录后列出全部站点。调用方可以指定站点，否则默认第一个未登录的站点。
  - E-Hentai：原有的密码、Cookie、网页三种方式不变。
  - nhentai：nhentai 不提供应用的密码登录，账号即 nhentai.net 账户设置中生成的 API 密钥。先用该密钥请求 `/api/v2/user`，成功才保存（并按自动同步设置同步类型 10），提示已验证的用户名；失败不保存。原“高级设置 → nhentai 域名”页中的 API 密钥项移到这里。登出即清空密钥并同步。
  - JM：用户名与密码。`POST /login`，表单字段 `username`、`password`，请求头与其他接口相同；成功时解密数据含 `uid`、`username`、`s`，会话 cookie 为响应的 Set-Cookie 加上 `AVS=s`（参考实现指出重复登录时 Set-Cookie 可能缺少 AVS）。失败时服务器返回 HTTP 401 与 `{"code":401,"errorMsg":"無效的用戶名和/或密碼！"}`，界面显示该消息。会话 cookie 与用户名保存在单独的 JmAccountSetting，作为云同步类型 13（整体以较新者为准）在设备之间同步，之后每个 JM 请求都在 `/setting` 会话 cookie 之上附带它；登录、登出后按自动同步设置立即上传。8.0.30、8.0.31 保存在 JmSetting 中的登录在启动时迁移过来。

## 7. 不包含

JM 云端收藏与收藏夹、发表评论、签到、游戏与社区。

评论只读显示：JM 的评论内容为带样式的 `div`，日期形如 `Sep 04, 2026`（不含时间）；显示前转换为文本、换行、链接与图片，日期转为 `yyyy-MM-dd`。

## 8. 测试

- 端到端测试直接访问真实 JM 接口（只读），由被忽略的 `test/e2e/jm_e2e.json` 开启：域名更新、解密、搜索、车号跳转、本子与章节详情、多章节结构、切割参数、评论，以及用真实图片验证还原结果（条带边界断层消失）和下载后的 JPEG 输出。
- 单元测试：`GalleryUrl` 的解析与 gid 映射、段数计算、收藏合并与云同步类型。
- 登录：接口层验证错误账号得到服务器消息；界面层驱动登录页切换三个站点的表单，用错误账号向真实服务器登录并断言页面显示服务器消息，账号设置页列出 JM 账号并登出。`jm_e2e.json` 填写 `username`、`password` 后，另外验证真实账号登录与会话附带。
