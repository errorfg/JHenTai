import 'dart:collection';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/local_block_rule_service.dart';
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

void main() {
  final GalleryUrl eh = GalleryUrl.parse('https://e-hentai.org/g/123/abcdef1234/');
  final GalleryUrl nh = GalleryUrl(isEH: true, isNH: true, gid: 123, token: 'nhentai', sourceHost: 'nhentai.net');
  final GalleryUrl wn = GalleryUrl(isEH: true, isWN: true, gid: 123, token: 'wnacg');

  setUp(() {
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
    pendingSyncTracker = PendingSyncTracker();
    localConfigService = LocalConfigService();
    readProgressService = ReadProgressService();
    ehSetting.nhentaiDomains.value = <String>['nhentai.net', 'nhentai.to'];
  });

  tearDown(() => appDb.close());

  test('galleries of the same number on two sites have keys of their own; JM and Tachiyomi keep theirs', () {
    expect(<String>[eh.contentKey, nh.contentKey, wn.contentKey], <String>['eh:123', 'nh:123', 'wn:123']);
    expect(<String?>[eh.legacyKey, nh.legacyKey, wn.legacyKey], <String>['123', '123', '123']);
    expect(GalleryUrl.jm(5).contentKey, '${GalleryUrl.jmGidOffset + 5}');
    expect(GalleryUrl.jm(5).legacyKey, isNull);
    final GalleryUrl tachi = GalleryUrl.tachiChapter('1', '/m', '/c');
    expect((tachi.contentKey, tachi.legacyKey), ('${tachi.gid}', null));
    expect(GalleryUrl.keysOf('https://nhentai.to/g/123/', 123), (key: 'nh:123', legacy: '123'));
    expect(GalleryUrl.keysOf('not an address', 9), (key: '9', legacy: null));
  });

  test('progress of the same number on two sites is kept apart; what 8.1.1 kept under the number stays for each until it has its own', () async {
    // Kept by 8.1.1 under the bare number: E-Hentai's or nhentai's, unknown.
    await readProgressService.updateReadProgress('123', 7);
    expect(await readProgressService.getReadProgressOf(eh), 7);
    expect(await readProgressService.getReadProgressOf(nh), 7);

    await readProgressService.updateReadProgress(nh.contentKey, 2);
    expect(await readProgressService.getReadProgressOf(nh), 2);
    expect(await readProgressService.getReadProgressOf(eh), 7, reason: 'nhentai\'s own progress does not move what E-Hentai may have had');
    expect(await readProgressService.getReadProgressOf(wn), 7);

    // Cleared: a record of its own, the number's is not read again.
    await readProgressService.deleteReadProgress(eh.contentKey);
    expect(await readProgressService.getReadProgressEntryOf(eh), isNull);
    expect((await readProgressService.getProgressRecords(<String>{'123'}))['123']?.value, '7', reason: 'the old record is kept');
  });

  test('a gallery blocked from its page is blocked on its own site; a rule of 8.1.1 by the number still on every site', () async {
    Gallery gallery(GalleryUrl url) => Gallery(
          galleryUrl: url,
          title: url.contentKey,
          category: 'Manga',
          cover: GalleryImage(url: 'https://example.test/cover.jpg'),
          pageCount: 10,
          rating: 0,
          hasRated: false,
          language: null,
          uploader: null,
          publishTime: '2026-10-01 10:00',
          isExpunged: false,
          tags: LinkedHashMap<String, List<GalleryTag>>(),
        );
    final LocalBlockRuleService rules = LocalBlockRuleService();
    await rules.initBean();
    List<String> shown(List<Gallery> galleries) => galleries.map((g) => g.title).toList();
    LocalBlockRule byNumber(String expression) => LocalBlockRule(
          groupId: expression,
          target: LocalBlockTargetEnum.gallery,
          attribute: LocalBlockAttributeEnum.gid,
          pattern: LocalBlockPatternEnum.equal,
          expression: expression,
        );

    final List<Gallery> galleries = <Gallery>[gallery(eh), gallery(nh), gallery(wn)];
    await rules.upsertBlockRule(byNumber(nh.contentKey));
    expect(shown(await rules.executeRules(galleries)), <String>['eh:123', 'wn:123']);

    await rules.upsertBlockRule(byNumber('123'));
    expect(shown(await rules.executeRules(galleries)), isEmpty);
  });
}
