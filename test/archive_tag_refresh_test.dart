import 'dart:collection';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_metadata.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/schedule_service.dart';
import 'package:jhentai/src/setting/eh_setting.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';

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

/// Answers the E-Hentai metadata API with nothing, noting what it is asked.
class _MetadataRequests extends EHRequest {
  final List<List<int>> asked = <List<int>>[];

  /// Answers with tags, so that the archives asked are refreshed.
  bool answers = false;

  @override
  Future<T> requestGalleryMetadatas<T>({required List<({int gid, String token})> list, required HtmlParser<T> parser}) async {
    asked.add(list.map((g) => g.gid).toList());
    if (!answers) {
      return <dynamic>[] as T;
    }
    return <GalleryMetadata>[
      for (final ({int gid, String token}) g in list)
        GalleryMetadata(
          galleryUrl: GalleryUrl(isEH: true, gid: g.gid, token: g.token),
          title: '',
          japaneseTitle: '',
          category: 'Manga',
          cover: GalleryImage(url: ''),
          pageCount: 10,
          rating: 0,
          language: '',
          publishTime: '',
          isExpunged: false,
          size: '',
          torrentCount: 0,
          tags: LinkedHashMap<String, List<GalleryTag>>(),
        ),
    ] as T;
  }
}

ArchiveDownloadedCompanion _archive(int gid, String token, String galleryUrl) => ArchiveDownloadedCompanion.insert(
      gid: Value(gid),
      token: token,
      title: 'Archive $gid',
      category: 'Manga',
      pageCount: 10,
      galleryUrl: galleryUrl,
      coverUrl: 'https://example.test/cover.jpg',
      size: 1,
      publishTime: '',
      archiveStatusCode: 0,
      archivePageUrl: '',
      isOriginal: false,
      insertTime: '2026-10-21 10:00:00',
      groupName: 'default',
    );

void main() {
  late _MetadataRequests requests;

  setUp(() async {
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
    ehSetting.nhentaiDomains.value = <String>['nhentai.net', 'nhentai.to'];
    ehRequest = requests = _MetadataRequests();
    await appDb.into(appDb.archiveDownloaded).insert(_archive(3400000, 'abcdef1234', 'https://e-hentai.org/g/3400000/abcdef1234/'));
    await appDb.into(appDb.archiveDownloaded).insert(_archive(501, 'nhentai', 'https://nhentai.net/g/501/'));
  });

  tearDown(() => appDb.close());

  test('each archive is asked once, though those refreshed go to the end of the order', () async {
    requests.answers = true;
    final List<int> gids = <int>[for (int i = 1; i <= 60; i++) 3400000 + i];
    for (final int gid in gids) {
      await appDb.into(appDb.archiveDownloaded).insert(_archive(gid, 'abcdef1234', 'https://e-hentai.org/g/$gid/abcdef1234/'));
    }
    await ScheduleService().refreshArchiveTags();
    final List<int> asked = requests.asked.expand((List<int> batch) => batch).toList();
    expect(asked..sort(), <int>[3400000, ...gids]);
  });

  test('only E-Hentai archives are asked of the E-Hentai API for their tags', () async {
    await ScheduleService().refreshArchiveTags();
    expect(requests.asked, <List<int>>[
      <int>[3400000],
    ]);
  });
}
