import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/dao/gallery_history_dao.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/gallery_history_model.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/pages/history/history_page_logic.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/cloud/webdav_provider.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/setting/eh_setting.dart';

class _SilentLogService extends LogService {
  @override
  void trace(Object msg, [bool withStack = false]) {}
  @override
  void debug(Object msg, [bool withStack = false]) {}
  @override
  void info(Object msg, [bool withStack = false]) {}
  @override
  void warning(Object msg, [Object? error, bool withStack = false]) {}
  @override
  void error(Object msg, [Object? error, StackTrace? stackTrace]) {}
}

Map<String, dynamic> _row(String url, String title) => <String, dynamic>{
      'galleryUrl': url,
      'title': title,
      'category': 'Manga',
      'coverUrl': 'https://cdn.example.test/cover.jpg',
      'pageCount': 20,
      'rating': 0.5,
      'language': '',
      'uploader': '',
      'publishTime': '',
      'isExpunged': false,
      'tags': <String>[],
    };

/// A row as another device or an older setting wrote it.
Future<void> _store(int gid, Map<String, dynamic> json, String lastReadTime) =>
    GalleryHistoryDao.replaceHistory(GalleryHistoryV2Data(gid: gid, jsonBody: jsonEncode(json), lastReadTime: lastReadTime));

/// Galleries read must stay in the history and keep their progress.
void main() {
  setUp(() {
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
    pendingSyncTracker = PendingSyncTracker();
    localConfigService = LocalConfigService();
    historyService = HistoryService();
    readProgressService = ReadProgressService();
    ehSetting.nhentaiDomains.value = <String>['nhentai.net', 'nhentai.to'];
    ehSetting.wnacgDomain.value = EHSetting.defaultWnacgDomain;
  });

  tearDown(() => appDb.close());

  test('an nhentai row on a domain this device does not list is still shown; an unreadable row hides only itself', () async {
    // Written on a device that had a mirror, read on one that does not.
    await _store(501, _row('https://nhentai.mirror.example/g/501/', 'On a mirror'), '2026-10-18T10:00:00.000Z');
    await _store(9, _row('not a gallery url', 'Broken'), '2026-10-18T09:00:00.000Z');
    await _store(3400000, _row('https://e-hentai.org/g/3400000/abcdef1234/', 'E-Hentai'), '2026-10-18T08:00:00.000Z');
    await _store(502, _row('https://nhentai.net/g/502/', 'On nhentai.net'), '2026-10-18T07:00:00.000Z');
    // wnacg on the domain set before the current one.
    await _store(77, _row('https://www.wn05.cc/photos-index-aid-77.html', 'On an old wnacg domain'), '2026-10-18T06:00:00.000Z');

    final List<GalleryHistoryModel> page = await historyService.getByPageIndex(0);
    expect(page.map((GalleryHistoryModel h) => h.title), <String>['On a mirror', 'E-Hentai', 'On nhentai.net', 'On an old wnacg domain']);
    final GalleryUrl wnacg = page.last.galleryUrl;
    expect((wnacg.isWN, wnacg.gid), (true, 77));
    // Opened on the domain set now.
    expect(wnacg.url, 'https://${ehSetting.wnacgDomain.value}/photos-index-aid-77.html');
    final GalleryUrl mirror = page.first.galleryUrl;
    expect((mirror.isNH, mirror.gid, mirror.sourceHost), (true, 501, 'nhentai.mirror.example'));
    expect(mirror.url, 'https://nhentai.mirror.example/g/501/');

    final List<GalleryHistoryModel> shown = (await HistoryPageLogic.visibleHistory(0, await historyService.getPageCount())).rows;
    expect(shown, hasLength(4));
  });

  test('links met elsewhere are recognised as before: only stored urls take any nhentai domain', () {
    expect(GalleryUrl.tryParse('https://nhentai.mirror.example/g/501/'), isNull);
    expect(GalleryUrl.tryParseStored('https://nhentai.mirror.example/g/501/')?.isNH, isTrue);
    expect(GalleryUrl.tryParseStored('https://www.nhentai.net/g/502/')?.sourceHost, 'nhentai.net');
    expect(GalleryUrl.tryParseStored('https://e-hentai.org/g/3400000/abcdef1234/')?.isNH, isFalse);
    expect(GalleryUrl.tryParseStored('https://example.com/page'), isNull);
    expect(GalleryUrl.tryParse('https://www.wn05.cc/photos-index-aid-77.html'), isNull);
    expect(GalleryUrl.tryParseStored('https://www.wn05.cc/photos-index-aid-77.html')?.isWN, isTrue);
  });

  test('the wnacg domain is kept as a host, whatever is pasted; nothing typed restores the default', () async {
    expect(EHSetting.normalizeDomain(' https://www.wn08.ru/albums-index.html '), 'www.wn08.ru');
    expect(EHSetting.normalizeDomain('WWW.WN08.RU'), 'www.wn08.ru');
    expect(EHSetting.normalizeDomain('www.wn08.ru?x=1'), 'www.wn08.ru');
    await ehSetting.saveWnacgDomain('https://www.wn08.ru/');
    expect(ehSetting.wnacgDomain.value, 'www.wn08.ru');
    expect(GalleryUrl.tryParse('https://www.wn08.ru/photos-index-aid-5.html')?.isWN, isTrue);
    await ehSetting.saveWnacgDomain('  ');
    expect(ehSetting.wnacgDomain.value, EHSetting.defaultWnacgDomain);
  });

  test('a WebDAV remote path ending in a slash does not give file paths with //', () {
    expect(WebDavProvider.normalizeRemotePath('/JHenTaiConfig/'), '/JHenTaiConfig');
    expect(WebDavProvider.normalizeRemotePath(' JHenTaiConfig// '), '/JHenTaiConfig');
    expect(WebDavProvider.normalizeRemotePath('/a/b'), '/a/b');
    expect(WebDavProvider.normalizeRemotePath('/'), '');
    expect(WebDavProvider(serverUrl: 'https://dav.example.com/', username: 'u', password: 'p', remotePath: '/JHenTaiConfig/').remotePath, '/JHenTaiConfig');
  });

  group('a new version of an E-Hentai gallery', () {
    test('takes over the progress of the version it replaces, within its own pages', () async {
      // Page 15 of the old version (index 14).
      await readProgressService.updateReadProgress('3400000', 14);

      expect(await readProgressService.takeOverFromOlderVersion(gid: 3500000, olderGid: 3400000, pageCount: 25), isTrue);
      expect(await readProgressService.getReadProgress(3500000), 14);
      // The old version keeps its own.
      expect(await readProgressService.getReadProgress(3400000), 14);

      // Fewer pages than were read: the last one.
      await readProgressService.updateReadProgress('3400001', 30);
      await readProgressService.takeOverFromOlderVersion(gid: 3500001, olderGid: 3400001, pageCount: 25);
      expect(await readProgressService.getReadProgress(3500001), 24);
    });

    test('keeps its own progress, and takes nothing from an older version never read', () async {
      await readProgressService.updateReadProgress('3400000', 14);
      await readProgressService.updateReadProgress('3500000', 3);
      expect(await readProgressService.takeOverFromOlderVersion(gid: 3500000, olderGid: 3400000, pageCount: 25), isFalse);
      expect(await readProgressService.getReadProgress(3500000), 3);

      // Opened at its first page: that is progress of its own too.
      await readProgressService.updateReadProgress('3500002', 0);
      expect(await readProgressService.takeOverFromOlderVersion(gid: 3500002, olderGid: 3400000, pageCount: 25), isFalse);

      expect(await readProgressService.takeOverFromOlderVersion(gid: 3500003, olderGid: 3400003, pageCount: 25), isFalse);
      expect(await readProgressService.getReadProgressEntryByKey('3500003'), isNull);
    });
  });
}
