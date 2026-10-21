import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
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

  @override
  Future<T> requestGalleryMetadatas<T>({required List<({int gid, String token})> list, required HtmlParser<T> parser}) async {
    asked.add(list.map((g) => g.gid).toList());
    return <dynamic>[] as T;
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

  test('only E-Hentai archives are asked of the E-Hentai API for their tags', () async {
    await ScheduleService().refreshArchiveTags();
    expect(requests.asked, <List<int>>[
      <int>[3400000],
    ]);
  });
}
