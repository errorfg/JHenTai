![platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Windows%20%7C%20MacOS%20%7C%20Linux-brightgreen)
![last-commit](https://img.shields.io/github/last-commit/errorfg/JHenTai)
[![downloads](https://img.shields.io/github/downloads/errorfg/JHenTai/total)](https://github.com/errorfg/JHenTai/releases)
[![downloads](https://img.shields.io/github/downloads/errorfg/JHenTai/latest/total)](https://github.com/errorfg/JHenTai/releases)
![star](https://img.shields.io/github/stars/errorfg/JHenTai)
[![issue](https://img.shields.io/badge/chat-issue-brightgreen)](https://github.com/errorfg/JHenTai/issues/new)

# JHenTai

[English](./README.md) | [简体中文](./README_cn.md) | 한국어

[JHenTai](https://github.com/jiangtian616/JHenTai)를 바탕으로 한 다중 소스 만화 뷰어로, Android, iOS, Windows, macOS, Linux를 지원합니다. E-Hentai를 중심으로 nhentai, wnacg, JM, Komga 서버와 로컬 도서를 같은 뷰어, 다운로드, 즐겨찾기, 기록, 클라우드 동기화로 읽습니다.

E-Hentai 관련 질문은 업스트림의 [Q&A](https://github.com/jiangtian616/JHenTai/wiki/Common-Questions)를 참고하세요.

## 시작하게 된 이유

이미지 검색 봇은 대부분 nhentai 페이지를 알려 주지만, 저는 주로 E-Hentai를 사용합니다. 그래서 처음에는 nhentai 갤러리에서 E-Hentai의 같은 갤러리로 넘어가는 기능을 만들었습니다. 이후 다른 사이트를 직접 읽게 되었고, JHenTai 뷰어가 쓰기 좋다는 것을 알게 되어 다른 만화 사이트, Komga 서버, 로컬 도서도 같은 뷰어로 읽을 수 있게 했습니다.

## 지원 소스

| 소스 | 지원 기능 |
| --- | --- |
| E-Hentai / ExHentai | 업스트림의 모든 기능: 둘러보기, 인기, 랭킹, 구독, 검색, 상세, 평가, 태그 투표, 댓글, 즐겨찾기, 토렌트, 아카이브, H@H, 다운로드, 암호·쿠키·웹 로그인. |
| nhentai | nhentai.net과 설정 가능한 미러 도메인에서 검색, 상세, 온라인 보기, 다운로드, 로컬 즐겨찾기. nhentai.net 계정 설정에서 만든 API 키로 로그인하면(공식 API v2) 더 자세한 메타데이터, 댓글, 관련 갤러리, 태그 제안, 클라우드 즐겨찾기, 태그 차단 목록, ZIP/CBZ와 토렌트 다운로드. |
| wnacg | 검색, 둘러보기, 상세, 온라인 보기, 다운로드, 로컬 즐겨찾기. 도메인 설정과 링크 이동 지원. |
| JM (18comic) | 홈 추천, 카테고리별 둘러보기(한국 웹툰 포함), 일·주·월·전체 랭킹, 주간 추천, 검색, 작품 번호 이동, 챕터 목록이 있는 상세, 읽기 전용 댓글과 관련 작품, 이미지 복원 온라인 보기, 뷰어에서 이전·다음 챕터, 다운로드(챕터 하나 또는 전체), 로컬 즐겨찾기, 계정 로그인, API·이미지 회선 선택. |
| Komga | 라이브러리·시리즈·책의 서버 측 페이지 나눔, 정렬, 필터, 전문 검색, 홈, 오프라인 다운로드, 읽기 진행 상황 양방향 동기화. |
| 로컬 | 다운로드한 갤러리와 아카이브(아카이브 미리보기), 로컬 이미지 폴더, PDF 서재. |

소스 공통 기능:

- 내비게이션 서랍 맨 위(데스크톱은 사이드바 맨 위)의 소스 선택 메뉴로 E-Hentai, nhentai, wnacg, JM, Komga, PDF 사이에서 앱 전체를 전환하고, 선택한 사이트의 계정을 표시합니다. 검색 페이지의 사이트 전환은 그대로 유지됩니다.
- nhentai, wnacg, JM 상세 페이지의 `EH` 버튼으로 같은 제목을 E-Hentai에서 검색합니다.
- 하나의 로그인 페이지에서 E-Hentai, nhentai, JM 중 사이트를 고릅니다.
- 모든 소스의 즐겨찾기를 E-Hentai 즐겨찾기와 섞어서 또는 따로 표시할 수 있습니다.
- 설정, 로컬 즐겨찾기, 기록, 읽기 진행 상황을 WebDAV 또는 S3 호환 저장소로 클라우드 동기화합니다.
- 직접 배포한 eh2telegraph 서비스로 보내는 "Telegraph 봇으로 보내기" 버튼.

업스트림 대비 자세한 변경 사항은 [English README](./README.md#changes-compared-with-upstream)를 참고하세요.

## 다운로드 & 설치

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

Android 설치: 사용자의 디바이스 아키텍처에 맞는 .apk 파일을 다운로드 후 설치하세요.

- arm64-v8a：8세대 ARM 프로세서를 탑재한 안드로이드 폰에 해당됨(일반적인 선택)
- armeabiv-v7a：7세대 ARM 프로세서를 탑재한 안드로이드 폰에 해당됨
- x86_64：희귀함

iOS 설치: [AltStore](https://altstore.io)나 SideLoadly를 이용해 .ipa 파일을 다운로드하고 접속하세요.

Windows 설치: download Windows_xxx.zip 파일을 다운로드하고 압축 해제를 하세요. 만약 프록시 서버를 이용한다면 네트워크 설정에서 프록시 주소를 설정해 주세요. Windows 11을
사용하는데 앱 실행이 되지 않는다면 호환성 모드를 켠 상태에서 실행해 보세요. Windows Defender에 차단된 경우라면 허용으로 바꿔주세요.

MacOS 설치(지원 중지): .dmg 파일을 다운로드합니다. 만약 프록시 서버를 이용한다면 네트워크 설정에서 프록시 주소를 설정해 주세요.

Linux 설치(지원 중지): Linux_xxx.zip 파일을 다운로드하고 압축 해제를 하세요. 만약 프록시 서버를 이용한다면 네트워크 설정에서 프록시 주소를 설정해 주세요.

Fedora 기반 dnf Linux 배포판:

```bash
sudo rpm --import https://meeks233.github.io/Jhentai-rpm/fedora/RPM-GPG-KEY-jhentai
sudo curl -fsSL -o /etc/yum.repos.d/jhentai.repo https://meeks233.github.io/Jhentai-rpm/fedora/jhentai.repo
sudo dnf install -y jhentai
```

## 스크린샷

### 모바일 레이아웃

<img width="250" src="screenshot/mobile_v2.jpg"/>

### 태블릿 레이아웃

<img width="770" src="screenshot/tabletV2.png"/>

### 데스크톱 레이아웃

<img width="770" src="screenshot/desktop1.png"/>

### 갤러리 & 검색

<img width="250" style="margin-right:10px" src="screenshot/mobile_v2.jpg"/><img width="250" style="margin-right:10px" src="screenshot/search.jpg"/> 

### 갤러리 세부 정보

<img width="250" src="screenshot/detail.png" style="margin-right:10px" /><img width="250" src="screenshot/archive.jpg" style="margin-right:10px" />

### 설정 & 다운로드

<img width="250" src="screenshot/setting_en.jpg" style="margin-right:10px" /><img width="250" src="screenshot/download.jpg" style="margin-right:10px" />

### 보기

<img width="250" src="screenshot/read.jpg" /><img src="screenshot/read_double_column.png" /><img  src="screenshot/read_continuous_scroll.png" />

## E-Hentai 기능 (업스트림)

- [x] 모바일, 태블릿, 데스크톱 레이아웃(세 종류)
- [x] 가로, 세로 각각 두 쪽 레이아웃(네 종류)
- [x] 갤러리 페이지, 인기 있음, 즐겨찾기, 본 적 있음, 기록에 서로 다른 갤러리 목록 스타일 지원
- [x] 검색, 검색 추천, 태그를 눌러 검색, 파일 검색, 특정 페이지로 이동
- [x] 온라인 보기 및 다운롣, 다운로드 작업 복원 지원, 업로더가 새로운 버전을 업로드했을 때 업데이트 동기화 지원
- [x] 아카이브 다운로드, 자동 압축 해제 후 보기
- [x] 로컬 이미지 불러오기 및 보기 지원
- [x] 다운로드 작업 우선순위 수동 지정 지원
- [x] 갤러리 및 아카이브에 그룹 설정 지원
- [x] 즐겨찾기, 점수, 토렌트, 아카이브, 통계, 공유
- [x] 암호 로그인, 쿠키 로그인, 웹 로그인
- [x] EX 사이트 지원(도메인 프론팅은 선택사항)
- [x] 태그 추천/비추천, 태그 강조/숨김
- [x] 댓글, 댓글 추천
- [x] 지문 잠금 해제

## 번역

> [언어 코드](https://github.com/unicode-org/cldr/blob/master/common/validity/language.xml)
>
> [지역 코드](https://github.com/unicode-org/cldr/blob/master/common/validity/region.xml)

1. `/lib/src/l18n/en_US.dart`를 복사 후 이름을 `{사용자의_언어_코드}_{사용자의_지역_코드}.dart`로 바꾸세요
2. 새 파일의 클래스명을 바꾸세요(선택 사항)
3. 메서드 `keys`에서 k-v 쌍을 수정하고, 값을 사용자 언어로 번역하세요

여기까지 한 후에 풀 리퀘스트를 제출하시면 나머지 작업은 제가 합니다. 아니면 다음 사항을 계속 진행하셔도 됩니다:

4. `/lib/src/l18n/locale_text.dart`에 들어간 후, 새로운 k-v 쌍을 메서드 `keys`에 추가하세요.
   => `{사용자의_언어_코드}_{사용자의_지역_코드} : {사용자의_클래스명}.keys()`
5. Enter `/lib/src/consts/locale_consts.dart`에 들어간 후, `localeCode2Description` 속성에 새로운 k-v 쌍을
   추가하세요 : `{사용자의_언어_코드}_{사용자의_지역_코드} : {언어 설명}` 형식으로 사용자 언어의 설명을 작성하세요.

## 컴파일 정보

1. Android 서명을 직접 관리하려면 다음 사이트를 확인하세요: https://docs.flutter.dev/deployment/android#signing-the-app

## Dart 주요 종속성

- [get](https://pub.flutter-io.cn/packages/get): 종속성 관리, 상태 관리, l18n, NoSQL
- [dio](https://pub.flutter-io.cn/packages?q=dio): 네트워크
- [extendedImage](https://pub.flutter-io.cn/packages/extended_image): 이미지
- [drift](https://pub.flutter-io.cn/packages/drift): 데이터베이스

## 감사의 말씀

이 프로젝트는 [jiangtian616](https://github.com/jiangtian616)의 [JHenTai](https://github.com/jiangtian616/JHenTai)를 바탕으로 합니다. 뷰어, E-Hentai 기능, 레이아웃, 다운로드 시스템은 업스트림에서 왔습니다.

이 프로젝트가 참고한 프로그램(방식을 연구한 뒤 JHenTai에서 다시 구현):

- [JMComic-Crawler-Python](https://github.com/hect0x7/JMComic-Crawler-Python): JM 모바일 API 규칙, 응답 복호화, 이미지 복원.
- [jasmine](https://github.com/ComicSparks/jasmine): JM 연동의 계기가 된 JM 뷰어.
- [NClientV3](https://github.com/maxwai/NClientV3) ([NClientV2](https://github.com/Dar9586/NClientV2)의 포크)와 [Kuron (nhasixapp)](https://github.com/shirokun20/nhasixapp): nhentai 클라이언트.
- [wnacg-downloader](https://github.com/lanyeeee/wnacg-downloader): wnacg.
- [Komga](https://github.com/gotson/komga): Komga 소스가 연결하는 미디어 서버.
- [eh2telegraph](https://github.com/qini7-sese/eh2telegraph): "Telegraph 봇으로 보내기"가 연결하는 봇.

업스트림 JHenTai의 참조 프로젝트와 기여자:

레이아웃과 스타일 참조:

- [FEhviewer](https://github.com/honjow/FEhViewer) : 메인
- [EHPanda](https://github.com/tatsuz0u/EhPanda)
- [EHViewer](https://gitlab.com/NekoInverter/EhViewer)

태그 번역:

- [EhTagTranslation](https://github.com/EhTagTranslation/Database)

Tag order optimization:

- [e-hentai-db](https://github.com/ccloli/e-hentai-db)
- [e-hentai-tag-count](https://github.com/mokurin000/e-hentai-tag-count)
- [EhSyringe](https://github.com/EhTagTranslation/EhSyringe)

앱 번역:

- [andyching168](https://github.com/andyching168) [kenny03211](https://github.com/kenny03211) [NeKoOuO](https://github.com/NeKoOuO) 繁體中文(台灣)
- [lucas-04](https://github.com/lucas-04) Português brasileiro
- [qlife1146](https://github.com/qlife1146) 한국어
- [bropines](https://github.com/bropines) Russian

위의 프로젝트와 여러분께 감사드립니다.
