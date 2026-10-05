![platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Windows%20%7C%20MacOS%20%7C%20Linux-brightgreen)
![last-commit](https://img.shields.io/github/last-commit/errorfg/JHenTai)
[![downloads](https://img.shields.io/github/downloads/errorfg/JHenTai/total)](https://github.com/errorfg/JHenTai/releases)
[![downloads](https://img.shields.io/github/downloads/errorfg/JHenTai/latest/total)](https://github.com/errorfg/JHenTai/releases)
![star](https://img.shields.io/github/stars/errorfg/JHenTai)
[![issue](https://img.shields.io/badge/chat-issue-brightgreen)](https://github.com/errorfg/JHenTai/issues/new)

# JHenTai

[English](./README.md) | 简体中文 | [한국어](./README_kr.md)

基于 [JHenTai](https://github.com/jiangtian616/JHenTai) 的多来源漫画阅读器，支持 Android、iOS、Windows、macOS 和 Linux。以 E-Hentai 为中心，nhentai、wnacg、JM、Komga 服务器和本地书籍都使用同一套阅读器、下载、收藏、历史与云同步。

E-Hentai 相关问题仍可参考上游的[常见问题](https://github.com/jiangtian616/JHenTai/wiki/%E5%B8%B8%E8%A7%81%E9%97%AE%E9%A2%98)。

## 缘起

搜图机器人给出的结果大多是 nhentai 的页面，而我主要使用 E-Hentai，所以最初做的是一个跳转功能：从 nhentai 画廊找到 E-Hentai 上的同一画廊。之后开始直接阅读其他站点的内容；又发现 JHenTai 的阅读器很好用，于是陆续加入了其他漫画站点、Komga 服务器和本地书籍的阅读，全部共用这一个阅读器。

## 支持的来源

| 来源 | 支持的功能 |
| --- | --- |
| E-Hentai / ExHentai | 上游的全部功能：浏览、热门、排行榜、关注、搜索、详情、评分、标签投票、评论、收藏、种子、归档、H@H、下载，以及密码、Cookie、网页三种登录方式。 |
| nhentai | 搜索、详情、在线阅读、下载和本地收藏，支持 nhentai.net 与可配置的镜像域名。在 nhentai.net 账户设置中生成 API 密钥并登录后（官方 API v2），另有更完整的元数据、评论、相关画廊、标签建议、云端收藏、标签黑名单，以及 ZIP/CBZ 与种子下载。 |
| wnacg | 搜索、浏览、详情、在线阅读、下载和本地收藏，可配置域名并支持链接跳转。 |
| JM（禁漫天堂） | 首页推荐、按分类浏览（含韩漫）、日/周/月/总排行、每周必看、搜索、车号跳转、带章节列表的详情、只读评论和相关本子、在线阅读（图片自动还原）、阅读器内切换上一章与下一章、下载（单章或全部章节）、本地收藏、账号登录，可选择接口线路与图片线路。 |
| Komga | 书库、系列与书的服务器端分页、排序和筛选，全文搜索，首页，离线下载，以及阅读进度双向同步。 |
| 本地 | 已下载的画廊与归档（支持归档预览）、本地图片文件夹、PDF 书库。 |

跨来源的功能：

- 侧边栏顶部（桌面布局为侧栏顶部）的来源下拉菜单在 E-Hentai、nhentai、wnacg、JM、Komga、PDF 之间切换整个应用，并显示所选站点的账号；搜索页内单独切换站点的功能保留；
- nhentai、wnacg、JM 的详情页有 `EH` 按钮，用标题在 E-Hentai 上搜索同一画廊；
- 统一的登录页，可在 E-Hentai、nhentai、JM 之间选择；
- 各来源的收藏可以与 E-Hentai 收藏混合显示，也可以分开显示；
- 设置、本地收藏、历史和阅读进度通过 WebDAV 或 S3 兼容存储云同步；
- 「发送到 Telegraph 机器人」按钮，配合自行部署的 eh2telegraph 服务。

## 相对上游的改动

以下内容基于当前 `upstream/master..master` 提交历史整理：

- 鸿蒙兼容 / 应用标识调整：
  - 针对 HarmonyOS 风险弹窗场景做过包名/标识相关调整。
- 云同步增强：
  - 增加 WebDAV 配置同步。
  - 增加 S3 兼容同步（统一架构）。
  - 增量同步与智能合并策略优化（改进本地时间戳识别）。
  - 支持启动自动同步、应用恢复/展示时自动同步、以及新增历史记录时自动同步。
  - 导出配置时可包含同步设置。
  - 首页增加同步进度指示，桌面端可通过标题区域查看同步进度。
  - 修复搜索历史同步合并与云同步后阅读进度一致性问题。
  - 历史记录与阅读进度改为增量日志同步：日常同步只传输变化，不受多设备并发覆盖与时钟偏差影响。
  - Komga 服务器配置与凭据纳入配置同步，新设备自动完成设置。
  - `nhentai` API 密钥纳入配置同步，并自动迁移旧版保存在 EH 设置中的密钥。
  - JM 本地收藏纳入配置同步。
  - 配置同步原样保留无法识别的远端条目（由更新版本写入）以及本次未同步的类型；远端文件无法读取时中止同步，不再上传。
- 画廊与检索体验：
  - 详情页支持多 Tag 选择搜索。
  - Popular / Ranklist 页支持客户端过滤。
  - 增加 `nhentai` 备选链路（搜索/详情/图片页）。
  - `nhentai` 搜索支持 EH/NH 模式切换（NH 模式下可直接非 `nh:` 前缀输入），并兼容 `nh:` 关键词前缀与 NH 标签翻译。
  - `nhentai` 详情页新增 `EH` 按钮，可提取标题并回搜 E-Hentai。
  - `nhentai` 详情页支持收藏动作，收藏流程与 EH 对齐。
  - 可选的 `nhentai` 官方 API v2 模式：更完整的画廊元数据、评论、相关画廊、标签建议、云端收藏与标签黑名单管理；未配置 API 密钥时仍使用原有解析方式。
  - `nhentai` 官方 ZIP/CBZ 与种子下载、签名地址、动态 CDN 配置，以及更多分类、语言、页数范围搜索筛选。
  - 增加 `wnacg` 站点集成：搜索、浏览、详情、下载、本地收藏、云同步，支持自定义域名。
  - 搜索页三选一切换（EH/NH/WN）及 `wn:` 关键词前缀。
  - 接入 JM（禁漫天堂）：站点切换或 `jm:` 前缀搜索、最新列表、车号跳转、带章节列表与只读评论的详情、图片还原后的在线阅读与下载、阅读器内上一章与下一章、全部章节下载，可选择接口线路与图片线路。
  - EH / NH / WN / JM 收藏同时支持混合插入与分菜单切换显示。
  - 统一的登录页可选择站点（E-Hentai、`nhentai`、JM）；账号设置页分别显示并登出各站点，`nhentai` API 密钥在登录页填写，验证成功后才保存。
  - 支持 wnacg 链接跳转，自动域名重写。
  - E-Hentai / ExHentai / `nhentai` 详情页的「发送到 Telegraph 机器人」按钮，把画廊提交给自行部署的 eh2telegraph 服务；服务地址与令牌纳入配置同步。
- 折叠屏设备支持：
  - 移动端布局新增全局悬浮按钮，可一键切换竖屏 / 横屏方向。
- 本地书库与下载：
  - 归档预览页，可浏览已下载归档中的图片。
  - JHenTai、Komga、PDF 三种阅读来源可切换，共用同一阅读器。
  - 独立的 PDF 书库，扫描本地 PDF 文件（Windows 通过 pdfx 渲染）。
  - Komga 浏览：服务器端分页、排序与筛选，全文搜索，首页（继续阅读、待读、最近新增与更新的系列、已下载），可点击元数据的系列详情，卡片、列表、详情三种布局。
  - Komga 阅读进度双向同步，容忍设备与服务器之间的时钟偏差，上报失败时重试；可将单本书或整个系列标记为已读或未读。
  - Komga 阅读器集成：上一本、下一本，页面缩略图，Flutter 无法解码的格式转换为 PNG；阅读布局始终按阅读器自身设置，不采用服务器上的系列阅读方向。
  - Komga 离线下载单本书或整个系列，无需服务器即可阅读，联网后补报阅读进度。
  - Komga 来源页面使用完整的 JHenTai 侧边导航，并统一浅色与深色界面。
  - Komga 的书与系列菜单也可通过右键打开，桌面布局下在鼠标位置弹出。
- 框架：
  - Flutter 升级到 3.44.8，修复 iPadOS 26.1 及以上弹窗自动消失的问题（flutter/flutter#177992）。
  - 应用内检查更新、更新弹窗、关于页、AltStore 安装源和 Linux 安装包主页指向本仓库；检查更新时比较构建号，只升构建号的修复版也会提示更新。
- CI 流程（fork 自定义）：
  - 非 master 分支增加构建检查并上传 Android APK artifact。
  - 分支检查聚焦 Android release APK artifact 产出。
  - 仅文档改动默认跳过编译。
  - 支持通过 `[skip-build]` 关键词主动跳过编译任务（仅检查 head commit）。
  - 发布流程补强：调整 tag 检测时机，改进 changelog 处理稳定性。

## 下载&安装

[<img src="https://raw.githubusercontent.com/errorfg/JHenTai/master/badges/download_from_github.png" 
      alt="Download from GitHub" 
      height="60">](https://github.com/errorfg/JHenTai/releases)
[<img src="https://raw.githubusercontent.com/errorfg/JHenTai/master/badges/get_it_on_obtainium.png" 
      alt="Get it on Obtainium" 
      height="60">](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22top.jtmonster.jhentai%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2Ferrorfg%2FJHenTai%22%2C%22author%22%3A%22jiangtian616%22%2C%22name%22%3A%22JHenTai%22%2C%22preferredApkIndex%22%3A0%2C%22additionalSettings%22%3A%22%7B%5C%22includePrereleases%5C%22%3Afalse%2C%5C%22fallbackToOlderReleases%5C%22%3Atrue%2C%5C%22filterReleaseTitlesByRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22filterReleaseNotesByRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22verifyLatestTag%5C%22%3Afalse%2C%5C%22sortMethodChoice%5C%22%3A%5C%22date%5C%22%2C%5C%22useLatestAssetDateAsReleaseDate%5C%22%3Afalse%2C%5C%22releaseTitleAsVersion%5C%22%3Afalse%2C%5C%22trackOnly%5C%22%3Afalse%2C%5C%22versionExtractionRegEx%5C%22%3A%5C%22v(.*)%5C%22%2C%5C%22matchGroupToUse%5C%22%3A%5C%22%241%5C%22%2C%5C%22versionDetection%5C%22%3Atrue%2C%5C%22releaseDateAsVersion%5C%22%3Afalse%2C%5C%22useVersionCodeAsOSVersion%5C%22%3Afalse%2C%5C%22apkFilterRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22invertAPKFilter%5C%22%3Afalse%2C%5C%22autoApkFilterByArch%5C%22%3Atrue%2C%5C%22appName%5C%22%3A%5C%22JHenTai%5C%22%2C%5C%22appAuthor%5C%22%3A%5C%22JTMonster%5C%22%2C%5C%22shizukuPretendToBeGooglePlay%5C%22%3Afalse%2C%5C%22allowInsecure%5C%22%3Afalse%2C%5C%22exemptFromBackgroundUpdates%5C%22%3Afalse%2C%5C%22skipUpdateNotifications%5C%22%3Afalse%2C%5C%22about%5C%22%3A%5C%22https%3A%2F%2Fgithub.com%2Ferrorfg%2FJHenTai%2Fblob%2Fmaster%2FREADME.md%5C%22%2C%5C%22refreshBeforeDownload%5C%22%3Afalse%7D%22%2C%22overrideSource%22%3Anull%7D)


[<img src="https://raw.githubusercontent.com/errorfg/JHenTai/master/badges/add_to_altstore.png" 
      alt="Add to AltStore" 
      height="60">](https://intradeus.github.io/http-protocol-redirector?r=altstore://source?url=https://raw.githubusercontent.com/errorfg/JHenTai/refs/heads/master/altsource/AltSource.json)
[<img src="https://raw.githubusercontent.com/errorfg/JHenTai/master/badges/add_to_sidestore.png" 
      alt="Add to SideStore" 
      height="60">](https://intradeus.github.io/http-protocol-redirector?r=sidestore://source?url=https://raw.githubusercontent.com/errorfg/JHenTai/refs/heads/master/altsource/AltSource.json)
[<img src="https://raw.githubusercontent.com/errorfg/JHenTai/master/badges/add_to_feather.png" 
      alt="Add to Feather" 
      height="60">](https://intradeus.github.io/http-protocol-redirector?r=feather://source/https://raw.githubusercontent.com/errorfg/JHenTai/refs/heads/master/altsource/AltSource.json)

安卓安装:  下载对应自己设置架构的apk文件，直接安装即可。

- arm64-v8a：适用于较新的第8代ARM处理器安卓手机(常见选择)
- armeabiv-v7a：适用于较老的第7代ARM处理器安卓手机
- x86_64：少见

iOS安装:  下载ipa文件后，使用[AltStore](https://altstore.io)、SideLoadly、爱思助手等任一工具进行自签名。

- 你可以通过[ AltStore 订阅](https://intradeus.github.io/http-protocol-redirector?r=altstore://source?url=https://raw.githubusercontent.com/errorfg/JHenTai/refs/heads/master/altsource/AltSource.json)来获得更便捷的安装与更新体验

Windows安装： 下载Windows_xxx.zip后解压即可。

- 如果你使用了代理服务器，在网络设置里配置代理地址。
- 如果你使用的是Win11且出现打不开应用的情况， 请尝试右键更改jhentai.exe的属性，以兼容模式启动。
- 如果Windows Defender报毒，请信任它。

MacOS安装（不维护）： 下载dmg后安装即可。

- 在系统设置-安全性与隐私中信任应用
- 如果你使用了代理服务器，在网络设置里配置代理地址。

Linux安装（不维护）：根据你的系统选择 Linux-amd64.deb 或 Linux-x86_64.AppImage，下载后安装运行即可。(视需要你可能需要安装webkit2gtk-4.1)

基于 Fedora 的 dnf Linux 发行版：

```bash
sudo rpm --import https://meeks233.github.io/Jhentai-rpm/fedora/RPM-GPG-KEY-jhentai
sudo curl -fsSL -o /etc/yum.repos.d/jhentai.repo https://meeks233.github.io/Jhentai-rpm/fedora/jhentai.repo
sudo dnf install -y jhentai
```

- 如果你使用了代理服务器，在网络设置里配置代理地址。

## 更新

安卓更新： 下载对应自己设置架构的apk文件，直接覆盖安装即可。

iOS更新： 下载ipa文件后，使用[AltStore](https://altstore.io)、SideLoadly、爱思助手等任一工具进行自签名覆盖安装。

Windows更新： 直接删除旧的解压出来的文件夹，下载最新的Windows_xxx.zip后解压使用即可。

MacOS更新（不维护）： 直接删除旧包后，下载最新的包使用即可。

Linux更新（不维护）： 直接删除旧包后，下载最新的包使用即可。

## 截图

### 手机模式

<img width="250" src="screenshot/mobile_v2.jpg"/>

### 平板模式

<img width="770" src="screenshot/tabletV2.png"/>

### 桌面模式

<img width="770" src="screenshot/desktop1.png"/>

### 画廊页 & 搜索页

<img width="250" style="margin-right:10px" src="screenshot/mobile_v2.jpg"/><img width="250" style="margin-right:10px" src="screenshot/search.jpg"/> 

### 画廊详情页

<img width="250" src="screenshot/detail.png" style="margin-right:10px" /><img width="250" src="screenshot/archive.jpg" style="margin-right:10px" />

### 设置 & 下载

<img width="250" src="screenshot/setting_zh.jpg" style="margin-right:10px" /><img width="250" src="screenshot/download.jpg" style="margin-right:10px" />

### 阅读

<img width="250" src="screenshot/read.jpg" /><img src="screenshot/read_double_column.png" /><img  src="screenshot/read_continuous_scroll.png" />

## E-Hentai 功能（来自上游）

- [x] 支持手机、平板、桌面三端布局
- [x] 支持上下、左右、双列等共四种阅读布局
- [x] 主页、热门、收藏、关注、历史，支持多种画廊样式
- [x] 搜索、搜索Tag提示、点击Tag快捷搜索、以图搜图、跳页
- [x] 在线阅读与下载，支持恢复下载记录，支持在上传者更新画廊后同步更新本地已下载的画廊
- [x] 支持下载归档并自动解压、阅读
- [x] 支持读取本地图片，当作本地阅读器
- [x] 下载画廊支持手动调节任务优先级、下载分组、自定义排序
- [x] 画廊和归档支持打上分组标签，统一展开折叠
- [x] 收藏、评分、磁力、归档、统计、分享
- [x] 账号密码登录、Cookie登录、Web登录
- [x] 支持域名前置直连里站
- [x] Tag翻译、Tag投票、关注Tag、隐藏Tag
- [x] 评论、评论投票
- [x] 指纹解锁

## 国际化步骤

> [languageCode](https://github.com/unicode-org/cldr/blob/master/common/validity/language.xml)
>
> [countryCode](https://github.com/unicode-org/cldr/blob/master/common/validity/region.xml)

1. 复制 `/lib/src/l18n/en_US.dart` 一份并重命名为`{your_languageCode}_{your_countryCode}.dart`
2. 更改新文件的class name(可选)
3. 修改keys方法返回的所有键值对，将value翻译为你的语言

你可以只做以上步骤然后提交PR，我会补充其他的步骤，或者你自己可以继续：

4. 在 `/lib/src/l18n/locale_text.dart`
   的keys方法中增加一条键值对`{your_languageCode}_{your_countryCode} : {your_className}.keys()`
5. 在 `/lib/src/consts/locale_consts.dart` 的 `localeCode2Description`
   属性中增加一条键值对`{your_languageCode}_{your_countryCode} : {languageDescription}`，用于描述你的语言

## 项目编译相关

1. 你需要自己管理安卓签名文件，见https://docs.flutter.dev/deployment/android#signing-the-app
2. 使用IDEA或者VSCode直接运行即可

## 主要dart依赖

- [get](https://pub.flutter-io.cn/packages/get): 依赖管理、状态管理、国际化、NoSQL
- [dio](https://pub.flutter-io.cn/packages?q=dio): 网络
- [extendedImage](https://pub.flutter-io.cn/packages/extended_image): 图片
- [drift](https://pub.flutter-io.cn/packages/drift): 数据库

## 致谢

本项目基于 [jiangtian616](https://github.com/jiangtian616) 的 [JHenTai](https://github.com/jiangtian616/JHenTai)：阅读器、E-Hentai 功能、界面布局和下载系统都来自上游。

本项目参考过的程序（研究其做法后在 JHenTai 中重新实现）：

- [JMComic-Crawler-Python](https://github.com/hect0x7/JMComic-Crawler-Python)：JM 移动端接口规则、响应解密与图片还原。
- [jasmine](https://github.com/ComicSparks/jasmine)：促成 JM 接入的 JM 阅读器。
- [NClientV3](https://github.com/maxwai/NClientV3)（[NClientV2](https://github.com/Dar9586/NClientV2) 的分支）与 [Kuron (nhasixapp)](https://github.com/shirokun20/nhasixapp)：nhentai 客户端。
- [wnacg-downloader](https://github.com/lanyeeee/wnacg-downloader)：wnacg。
- [Komga](https://github.com/gotson/komga)：Komga 来源所对接的媒体服务器。
- [eh2telegraph](https://github.com/qini7-sese/eh2telegraph)：「发送到 Telegraph 机器人」所对接的机器人。

上游 JHenTai 的参考项目与贡献者：

布局样式参考:

- [FEhviewer](https://github.com/honjow/FEhViewer) : 主要
- [EHPanda](https://github.com/tatsuz0u/EhPanda)
- [EHViewer](https://gitlab.com/NekoInverter/EhViewer)

标签翻译数据库:

- [EhTagTranslation](https://github.com/EhTagTranslation/Database)

标签排序:

- [e-hentai-db](https://github.com/ccloli/e-hentai-db)
- [e-hentai-tag-count](https://github.com/mokurin000/e-hentai-tag-count)
- [EhSyringe](https://github.com/EhTagTranslation/EhSyringe)

App翻译：

- [andyching168](https://github.com/andyching168) [kenny03211](https://github.com/kenny03211) [NeKoOuO](https://github.com/NeKoOuO) 繁體中文(台灣)
- [lucas-04](https://github.com/lucas-04) 葡萄牙语 Português brasileiro
- [qlife1146](https://github.com/qlife1146) 韩语
- [bropines](https://github.com/bropines) Russian

十分感谢以上项目与人员。
