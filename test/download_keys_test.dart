import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Value;
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/service/archive_download_service.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/download_setting.dart';
import 'package:path/path.dart' as path;

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

GalleryDownloadedCompanion _gallery(int gid, String token, String url) => GalleryDownloadedCompanion.insert(
      gid: Value(gid),
      token: token,
      title: 'Gallery $gid',
      category: 'Manga',
      pageCount: 1,
      galleryUrl: url,
      publishTime: '',
      downloadStatusIndex: 0,
      insertTime: '2026-10-21 10:00:00',
      priority: 0,
      groupName: 'default',
      sanitizedTitle: Value('Gallery $gid'),
    );

ArchiveDownloadedCompanion _archive(int gid, String token, String url) => ArchiveDownloadedCompanion.insert(
      gid: Value(gid),
      token: token,
      title: 'Archive $gid',
      category: 'Manga',
      pageCount: 1,
      galleryUrl: url,
      coverUrl: '',
      size: 1,
      publishTime: '',
      archiveStatusCode: 0,
      archivePageUrl: '',
      isOriginal: false,
      insertTime: '2026-10-21 10:00:00',
      groupName: 'default',
      sanitizedTitle: Value('Archive $gid'),
    );

void main() {
  setUp(() {
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
  });

  tearDown(() => appDb.close());

  test('downloads of nhentai and wnacg move to their own numbers with their pages and upscaled copies; E-Hentai and JM ones stay', () async {
    const int nh = 123, wn = 77, eh = 124;
    final int jm = GalleryUrl.jm(5).gid;
    await appDb.into(appDb.galleryDownloaded).insert(_gallery(nh, 'nhentai', 'https://nhentai.net/g/123/'));
    await appDb.into(appDb.galleryDownloaded).insert(_gallery(wn, 'wnacg', 'https://www.wnacg.com/photos-index-aid-77.html'));
    await appDb.into(appDb.galleryDownloaded).insert(_gallery(eh, 'abcdef1234', 'https://e-hentai.org/g/124/abcdef1234/'));
    await appDb.into(appDb.galleryDownloaded).insert(_gallery(jm, 'jmcomic', 'https://18comic.vip/photo/5'));
    for (final int gid in <int>[nh, wn, eh]) {
      await appDb.into(appDb.image).insert(ImageCompanion.insert(gid: gid, url: 'u$gid', serialNo: 0, path: 'p$gid', imageHash: '', downloadStatusIndex: 0));
      await appDb.into(appDb.superResolutionInfo).insert(SuperResolutionInfoCompanion.insert(gid: gid, type: 0, status: 0, imageStatuses: '[]'));
    }
    await appDb.into(appDb.archiveDownloaded).insert(_archive(nh, 'nhentai', 'https://nhentai.net/g/123/'));
    await appDb.into(appDb.superResolutionInfo).insert(SuperResolutionInfoCompanion.insert(gid: nh, type: 1, status: 0, imageStatuses: '[]'));

    await appDb.moveNhentaiAndWnacgDownloads();
    await appDb.moveNhentaiAndWnacgDownloads();

    final int nhKey = GalleryUrl.nhStorageOffset + nh, wnKey = GalleryUrl.wnStorageOffset + wn;
    expect((await appDb.select(appDb.galleryDownloaded).get()).map((g) => g.gid).toSet(), <int>{nhKey, wnKey, eh, jm});
    expect((await appDb.select(appDb.image).get()).map((i) => (i.gid, i.url)).toSet(), <(int, String)>{(nhKey, 'u$nh'), (wnKey, 'u$wn'), (eh, 'u$eh')});
    expect((await appDb.select(appDb.superResolutionInfo).get()).map((s) => (s.gid, s.type)).toSet(), <(int, int)>{(nhKey, 0), (wnKey, 0), (eh, 0), (nhKey, 1)});
    expect((await appDb.select(appDb.archiveDownloaded).get()).single.gid, nhKey);
  });

  test('folders stay named by the site\'s own number; a gallery is found by the number of its site', () async {
    downloadSetting.downloadPath = '/downloads'.obs;
    final GalleryDownloadedData nh = (await (appDb.into(appDb.galleryDownloaded)
            .insertReturning(_gallery(GalleryUrl.nhStorageOffset + 123, 'nhentai', 'https://nhentai.net/g/123/'))));
    expect(path.basename(GalleryDownloadService().computeGalleryDownloadAbsolutePath(nh)), '123 - Gallery ${GalleryUrl.nhStorageOffset + 123}');
    final ArchiveDownloadedData archive = await appDb.into(appDb.archiveDownloaded).insertReturning(_archive(GalleryUrl.nhStorageOffset + 123, 'nhentai', 'https://nhentai.net/g/123/'));
    expect(path.basename(ArchiveDownloadService().computeArchiveUnpackingPath(archive)), startsWith('Archive - 123 - '));

    // Metadata of 8.1.1 says 123; its gallery's row is the nhentai one.
    expect(GalleryUrl.storageGidOfStored('https://nhentai.net/g/123/', 123), GalleryUrl.nhStorageOffset + 123);
    expect(GalleryUrl.storageGidOfStored('https://nhentai.net/g/123/', GalleryUrl.nhStorageOffset + 123), GalleryUrl.nhStorageOffset + 123);
    expect(GalleryUrl.storageGidOfStored('https://e-hentai.org/g/124/abcdef1234/', 124), 124);
    expect(<int>[for (final int gid in <int>[123, GalleryUrl.nhStorageOffset + 123, GalleryUrl.wnStorageOffset + 77, GalleryUrl.jm(5).gid]) GalleryUrl.siteNumberOf(gid)],
        <int>[123, 123, 77, GalleryUrl.jm(5).gid]);
  });
}
