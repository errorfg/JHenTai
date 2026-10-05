![platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Windows%20%7C%20MacOS%20%7C%20Linux-brightgreen)
![last-commit](https://img.shields.io/github/last-commit/errorfg/JHenTai)
[![downloads](https://img.shields.io/github/downloads/errorfg/JHenTai/total)](https://github.com/errorfg/JHenTai/releases)
[![downloads](https://img.shields.io/github/downloads/errorfg/JHenTai/latest/total)](https://github.com/errorfg/JHenTai/releases)
![star](https://img.shields.io/github/stars/errorfg/JHenTai)
[![issue](https://img.shields.io/badge/chat-issue-brightgreen)](https://github.com/errorfg/JHenTai/issues/new)

# JHenTai

English | [简体中文](./README_cn.md) | [한국어](./README_kr.md)

A multi-source manga reader for Android, iOS, Windows, macOS and Linux, built on [JHenTai](https://github.com/jiangtian616/JHenTai). E-Hentai stays at its center; nhentai, wnacg, JM, Komga servers and local books are read with the same reader, downloads, favorites, history and cloud sync.

For E-Hentai questions, the upstream [Q&A](https://github.com/jiangtian616/JHenTai/wiki/Common-Questions) still applies.

## Why This Fork

Image-search bots mostly answer with nhentai pages, while I mainly use E-Hentai. The fork began with a jump from an nhentai gallery to the same gallery on E-Hentai. That led to reading the other sites directly, and once the JHenTai reader proved good, other manga sources, Komga servers and local books followed, all through the same reader.

## Supported Sources

| Source | What works |
| --- | --- |
| E-Hentai / ExHentai | Everything from upstream: browsing, popular, ranklist, watched, search, details, rating, tag voting, comments, favorites, torrents, archives, H@H, downloads, password/cookie/web login. |
| nhentai | Search, details, online reading, downloads and local favorites, on nhentai.net and configurable mirror domains. With an API key from the nhentai.net account settings (official API v2): richer metadata, comments, related galleries, tag suggestions, remote favorites, tag blacklist, ZIP/CBZ and torrent downloads. |
| wnacg | Search, browsing, details, online reading, downloads and local favorites, with a configurable domain and link jumping. |
| JM (18comic) | Home sections, category browsing (including Korean webtoons), rankings by day/week/month/all time, weekly picks, search, album-number jump, details with chapter list, read-only comments and related albums, online reading with image descrambling, previous/next chapter in the reader, downloads (single chapters or all chapters), local favorites, account login, selectable API and image lines. |
| Komga | Libraries, series and books with server-side paging, sorting and filters, full-text search, a home page, offline downloads and two-way read-progress sync. |
| Local | Downloaded galleries and archives (with archive preview), local image folders, and a PDF library. |

Across sources:

- a source picker at the top of the navigation drawer (the top of the side bar on desktop) switches the whole app between E-Hentai, nhentai, wnacg, JM, Komga and PDF, and shows the account of the chosen site; search keeps its own per-search site switch;
- an `EH` button on nhentai, wnacg and JM details searches the same title on E-Hentai;
- one login page with a site picker (E-Hentai, nhentai, JM);
- favorites of all sources can be shown mixed with E-Hentai favorites or separately;
- cloud sync (WebDAV or S3-compatible) of settings, local favorites, history and reading progress;
- a "Send to Telegraph bot" button for a self-hosted eh2telegraph service.

## Changes Compared With Upstream

Compared with `upstream/master` (based on current `upstream/master..master` commit history), this fork currently contains additional work in these areas:

- HarmonyOS compatibility / app identity adjustments:
  - package/app identity related changes to reduce HarmonyOS risk-popup friction.
- Cloud sync enhancements:
  - WebDAV config sync.
  - S3-compatible sync provider (unified architecture).
  - incremental/smart merge improvements with better local timestamp detection.
  - auto sync on startup, app resumed/shown, and new history record creation.
  - sync settings included in config export.
  - home sync progress indicator with desktop entry via title/progress display.
  - sync consistency fixes for search history merge and reading progress after cloud sync.
  - incremental oplog sync for history and read progress: routine syncs transfer only changes, immune to concurrent-device overwrites and clock skew.
  - Komga server configuration and credentials included in config sync for automatic cross-device setup.
  - `nhentai` API key included in config sync, with automatic migration from the legacy EH setting payload.
  - JM local favorites included in config sync.
  - config sync keeps remote entries it does not understand (written by newer versions) and the types it is not syncing, and aborts instead of uploading when the remote file cannot be read.
- Gallery and search UX:
  - multi-tag selection in detail page.
  - client-side filters for Popular and Ranklist pages.
  - `nhentai` fallback search/detail/image flow support.
  - `nhentai` search supports EH/NH mode toggle (non-prefix input works in NH mode), while keeping `nh:` keyword-prefix compatibility and NH tag translation.
  - dedicated `EH` action on `nhentai` details to extract title and search on E-Hentai.
  - `nhentai` details page favorite action and EH-aligned favorite flow.
  - optional official `nhentai` API v2 mode with richer gallery metadata, comments, related galleries, tag suggestions, remote favorites, and tag blacklist management; the existing parser remains available when no API key is configured.
  - official `nhentai` ZIP/CBZ and torrent downloads, signed URLs, dynamic CDN configuration, and expanded category/language/page-range search filters.
  - `wnacg` site integration: search, browse, detail, download, local favorites, cloud sync with configurable domain.
  - three-way EH/NH/WN search toggle and `wn:` keyword-prefix support.
  - JM (18comic) source integration: search via the site toggle or `jm:` prefix, latest list, album-number jump, details with chapter list and read-only comments, descrambled online reading and downloads, previous/next chapter in the reader, download of all chapters, and selectable API and image lines.
  - EH/NH/WN/JM favorites support both mixed insertion and split display with menu switching.
  - single login page with a site picker (E-Hentai, `nhentai`, JM); the account page shows and logs out each site separately, and the `nhentai` API key is entered there and verified before it is saved.
  - wnacg URL link jumping with automatic domain rewriting.
  - "Send to Telegraph bot" button on E-Hentai/ExHentai/`nhentai` details, posting the gallery to a self-hosted eh2telegraph service; its address and token are included in config sync.
- Foldable device support:
  - global floating button to toggle between portrait and landscape orientation (mobile layout only).
- Local library & downloads:
  - archive preview page for browsing images inside downloaded archives.
  - switchable JHenTai, Komga, and PDF reading sources with a shared reader.
  - dedicated PDF library for scanned local PDF files (including Windows rendering via pdfx).
  - Komga browsing with server-side paging, sorting and filters, full-text search, a home page (continue reading, on deck, recently added/updated series, downloads), series details with clickable metadata, and card/list/detail layouts.
  - two-way Komga read-progress sync that tolerates clock skew between devices and the server, with retry of failed reports; mark books or whole series read/unread.
  - Komga reader integration: previous/next book, page thumbnails, and PNG conversion for formats Flutter cannot decode; the layout always follows the reader's own settings, not the server's series reading direction.
  - offline Komga downloads of single books or whole series, readable without the server, with progress reported once back online.
  - Komga source pages reuse the complete JHenTai navigation drawer and consistent light/dark app surfaces.
  - Komga book and series menus also open with a right click, at the pointer on desktop layouts.
- Framework:
  - Flutter upgraded to 3.44.8, fixing dialogs auto-dismissing on iPadOS 26.1+ (flutter/flutter#177992).
  - in-app update check, update dialog, About page, AltStore source and Linux package homepage point to this fork; the update check compares build numbers, so build-only fix releases are offered too.
- CI/workflow updates in this fork:
  - branch checks for non-master branches with Android APK artifact uploads.
  - branch check focus on Android release APK artifact.
  - docs-only changes skip build.
  - `[skip-build]` keyword support with head-commit based checks.
  - publish/release workflow hardening for tag detection timing and changelog handling.

## Download & Install

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

Install for Android: download .apk according to your device architecture and install.

- arm64-v8a：Suitable for Android phones with 8th generation ARM processor(common choice)
- armeabiv-v7a：Suitable for Android phones with 7th generation ARM processor
- x86_64：rare

Install for iOS: download .ipa, then use [AltStore](https://altstore.io) or SideLoadly to sign.

- You can get easier installation and updates by adding [AltStore Repo](https://intradeus.github.io/http-protocol-redirector?r=altstore://source?url=https://raw.githubusercontent.com/errorfg/JHenTai/refs/heads/master/altsource/AltSource.json)

Install for Windows: download Windows_xxx.zip, then unpack it.

- If you use a proxy server, set proxy address at network setting page.
- If you're using Windows 11 and can't launch app, try to run jhentai.exe in compatibility mode.
- If it's blocked by Windows Defender, Please trust it.

Install for MacOS(No maintenance): download .dmg.

- Trust it in system setting.
- If you use a proxy server, set proxy address at network setting page.

Install for Linux(No maintenance): download Linux-amd64.deb or Linux-x86_64.AppImage due to your platform, then install
or execute it (You may need to install webkit2gtk-4.1).

Fedora-based dnf linux distro:

```bash
sudo rpm --import https://meeks233.github.io/Jhentai-rpm/fedora/RPM-GPG-KEY-jhentai
sudo curl -fsSL -o /etc/yum.repos.d/jhentai.repo https://meeks233.github.io/Jhentai-rpm/fedora/jhentai.repo
sudo dnf install -y jhentai
```


- If you use a proxy server, set proxy address at network setting page.

## Update

Update for Android: download .apk according to your device architecture and install.

Update for iOS: download .ipa, then use [AltStore](https://altstore.io) or SideLoadly to sign.

Update for Windows: Delete old unpacked directory directly, then download latest Windows_xxx.zip, unpack it.

Update for MacOS(No maintenance): download .dmg.

Update for Linux(No maintenance): Delete old and download the latest product.

## Help With Translation

Please submit a PR if you want to help with translation.

[steps](https://github.com/errorfg/JHenTai#Translation)

## Screenshots

### Mobile Layout

<img width="250" src="screenshot/mobile_v2.jpg"/>

### Tablet Layout

<img width="770" src="screenshot/tabletV2.png"/>

### Desktop Layout

<img width="770" src="screenshot/desktop1.png"/>

### Gallery & Search

<img width="250" style="margin-right:10px" src="screenshot/mobile_v2.jpg"/><img width="250" style="margin-right:10px" src="screenshot/search.jpg"/> 

### Gallery Detail

<img width="250" src="screenshot/detail.png" style="margin-right:10px" /><img width="250" src="screenshot/archive.jpg" style="margin-right:10px" />

### Setting & Download

<img width="270" src="screenshot/setting_en.jpg" style="margin-right:10px" /><img width="250" src="screenshot/download.jpg" style="margin-right:10px" />

### Read

<img width="250" src="screenshot/read.jpg" /><img src="screenshot/read_double_column.png" /><img src="screenshot/read_continuous_scroll.png" />

## E-Hentai Features (from upstream)

-   [x] Mobile, tablet, desktop layout(3 kinds)
-   [x] Vertical, horizontal, double column read page layout(4 kinds)
-   [x] GalleryPage, Popular, Favorite, Watched, History, support multiple gallery list style
-   [x] search, search suggestion, tap tag to search, file search, jump to a certain page
-   [x] online reading and download, support restore download task, support synchronize updates after the uploader has
    uploaded a new version
-   [x] archive download and automatic unpacking and reading
-   [x] support loading local images and read
-   [x] support assign priority to download task manually
-   [x] support assign group to gallery and archive
-   [x] favorite, rating, torrent, archive, statistics, share
-   [x] password login, Cookie login, web login
-   [x] support EX site(domain fronting optional)
-   [x] vote for Tag, watch and hidden tags
-   [x] comment, vote for comment
-   [x] Fingerprint unlock

## Translation

> [languageCode](https://github.com/unicode-org/cldr/blob/master/common/validity/language.xml)
>
> [countryCode](https://github.com/unicode-org/cldr/blob/master/common/validity/region.xml)

1. Copy `/lib/src/l18n/en_US.dart ` and rename to `{your_languageCode}_{your_countryCode}.dart`
2. Rename classname in new file(optional)
3. Modify k-v pairs in method `keys` ,translate values to your language

Now you can submit your PR, I'll do the remaining things. Or you can go on with:

4. Enter `/lib/src/l18n/locale_text.dart ` , add a new k-v pair in method `keys`
   => `{your_languageCode}_{your_countryCode} : {your_className}.keys()`
5. Enter `/lib/src/consts/locale_consts.dart`, add a new k-v pair in
   property `localeCode2Description`: `{your_languageCode}_{your_countryCode} : {languageDescription}` to describe your
   language.

## About compiling

1. You need to manage your Android signing by yourself,
   check https://docs.flutter.dev/deployment/android#signing-the-app
2. Just run this project via IDEA or VSCode simply.

## Main Dart Dependencies

- [get](https://pub.flutter-io.cn/packages/get): dependency management, state management, l18n, NoSQL
- [dio](https://pub.flutter-io.cn/packages?q=dio): network
- [extendedImage](https://pub.flutter-io.cn/packages/extended_image): image
- [drift](https://pub.flutter-io.cn/packages/drift): database

## Acknowledgements

This fork is built on [JHenTai](https://github.com/jiangtian616/JHenTai) by [jiangtian616](https://github.com/jiangtian616): the reader, the E-Hentai features, the layouts and the download system come from it.

Projects this fork learned from (approaches were studied and reimplemented in JHenTai):

- [JMComic-Crawler-Python](https://github.com/hect0x7/JMComic-Crawler-Python): JM mobile API rules, response decryption and image descrambling.
- [jasmine](https://github.com/ComicSparks/jasmine): the JM reader that prompted the JM integration.
- [NClientV3](https://github.com/maxwai/NClientV3) (a fork of [NClientV2](https://github.com/Dar9586/NClientV2)) and [Kuron (nhasixapp)](https://github.com/shirokun20/nhasixapp): nhentai clients.
- [wnacg-downloader](https://github.com/lanyeeee/wnacg-downloader): wnacg.
- [Komga](https://github.com/gotson/komga): the media server behind the Komga source.
- [eh2telegraph](https://github.com/qini7-sese/eh2telegraph): the bot behind "Send to Telegraph".

Upstream JHenTai's references and contributors:

Layout and style references:

- [FEhviewer](https://github.com/honjow/FEhViewer) : Mainly
- [EHPanda](https://github.com/tatsuz0u/EhPanda)
- [EHViewer](https://gitlab.com/NekoInverter/EhViewer)

Tag translation:

- [EhTagTranslation](https://github.com/EhTagTranslation/Database)

Tag order optimization:

- [e-hentai-db](https://github.com/ccloli/e-hentai-db)
- [e-hentai-tag-count](https://github.com/mokurin000/e-hentai-tag-count)
- [EhSyringe](https://github.com/EhTagTranslation/EhSyringe)

App translation：

- [andyching168](https://github.com/andyching168) [kenny03211](https://github.com/kenny03211) [NeKoOuO](https://github.com/NeKoOuO) 繁體中文(台灣)
- [lucas-04](https://github.com/lucas-04) Português brasileiro
- [qlife1146](https://github.com/qlife1146) 한국어
- [bropines](https://github.com/bropines) Russian

Many thanks to these projects and people.
