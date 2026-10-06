import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/network/jm/jm_api.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/jm_album_tag_service.dart';
import 'package:jhentai/src/service/jm_reading_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/widget/eh_gallery_list_card_.dart';
import 'package:jhentai/src/widget/eh_gallery_waterflow_card.dart';

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

/// Runs JSON work inline; the app's isolate is not started in tests.
class _InlineIsolateService extends IsolateService {
  @override
  Future<String> jsonEncodeAsync(Object object) async => jsonEncode(object);

  @override
  Future<dynamic> jsonDecodeAsync(String string) async => jsonDecode(string);
}

/// JM as the app sees it: a list of albums 1 to [albumCount] that names
/// their authors, and album details that carry the tags.
class _Jm extends JmApi {
  _Jm({this.albumCount = 6}) : super(dio: Dio(), apiDomains: () => const <String>['api.example.test'], discoverDomains: false);

  final int albumCount;

  /// Album details requested, in order.
  final List<int> requested = <int>[];
  int inFlight = 0;
  int mostInFlight = 0;

  /// When set, a details request waits until its album is let through.
  bool held = false;
  final Map<int, Completer<void>> _gates = <int, Completer<void>>{};
  final Set<int> failing = <int>{};

  void release(int id) => _gates.putIfAbsent(id, Completer<void>.new).complete();

  @override
  Future<JmSearchResult> latest({int page = 1}) async => JmSearchResult(
        total: albumCount,
        albums: <JmAlbumSummary>[
          for (int id = 1; id <= albumCount; id++)
            JmAlbumSummary(
              id: id,
              name: 'Album $id',
              author: 'author-$id',
              categoryTitle: '同人',
              subCategoryTitle: '',
              addDate: '',
              updateAt: null,
            ),
        ],
      );

  @override
  Future<JmAlbum> album(int id) async {
    requested.add(id);
    inFlight++;
    mostInFlight = mostInFlight < inFlight ? inFlight : mostInFlight;
    try {
      if (held) {
        await _gates.putIfAbsent(id, Completer<void>.new).future;
      }
      if (failing.contains(id)) {
        throw const JmApiException('no answer');
      }
      return JmAlbum.fromJson(<String, dynamic>{
        'id': id,
        'name': 'Album $id',
        'author': <String>['author-$id'],
        'tags': <String>['tag-$id-a', 'tag-$id-b', '中文'],
        'works': <String>['work-$id'],
        'actors': <String>['actor-$id'],
        'addtime': '1700000000',
      });
    } finally {
      inFlight--;
    }
  }
}

late AppDb _db;
late _Jm _jm;
late JmSource _source;

Future<List<Gallery>> _listPage() async => (await _source.galleryPage()).gallerys;

Future<Set<String>> _stored() async => (await localConfigService.readWithAllSubKeys(configKey: ConfigEnum.jmAlbumTags))
    .map((LocalConfig row) => row.subConfigKey)
    .toSet();

/// Shows [gallerys] as list cards with tags and lets the requests they
/// start run.
Future<void> _show(WidgetTester tester, List<Gallery> gallerys, {bool waterfall = false}) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: <Widget>[
                for (final Gallery gallery in gallerys)
                  waterfall
                      ? SizedBox(
                          width: 220,
                          child: EHGalleryWaterFlowCard(
                            key: ValueKey<int>(gallery.gid),
                            gallery: gallery,
                            downloaded: false,
                            listMode: ListMode.waterfallFlowBig,
                            handleTapCard: (_) {},
                          ),
                        )
                      : EHGalleryListCard(
                          key: ValueKey<int>(gallery.gid),
                          gallery: gallery,
                          downloaded: false,
                          listMode: ListMode.listWithTags,
                          handleTapCard: (_) {},
                        ),
              ],
            ),
          ),
        ),
      ),
    );
    await _settle();
  });
  await tester.pump();
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 150));

void main() {
  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    log = _SilentLogService();
    isolateService = _InlineIsolateService();
    jmReadingService = JmReadingService();
  });

  Future<void> start(WidgetTester tester, {int albumCount = 6}) async {
    await tester.runAsync(() async {
      _db = AppDb.forTesting(NativeDatabase.memory());
      appDb = _db;
      localConfigService = LocalConfigService();
      readProgressService = ReadProgressService();
    });
    addTearDown(() => tester.runAsync(_db.close));
    Get.testMode = true;
    Get.put<ReadProgressService>(readProgressService, permanent: true);
    addTearDown(Get.reset);
    final Directory cache = Directory.systemTemp.createTempSync('jm_tags_test');
    addTearDown(() => cache.deleteSync(recursive: true));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => cache.path,
    );
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    _jm = _Jm(albumCount: albumCount);
    jmAlbumTagService = JmAlbumTagService();
    _source = JmSource(
      api: _jm,
      imageDomain: () => 'cdn.example.test',
      onAlbum: jmAlbumTagService.record,
      fillTags: jmAlbumTagService.fill,
    );
    jmAlbumTagService.loadAlbum = _source.album;
  }

  testWidgets('a card of a JM list shows the tags of its album, requested once', (WidgetTester tester) async {
    await start(tester);

    // The list names the author only, and asks for no details.
    List<Gallery> page = (await tester.runAsync(_listPage))!;
    expect(page.map((Gallery g) => g.tags.keys.toList()), everyElement(<String>['artist']));
    expect(_jm.requested, isEmpty);

    // The albums whose cards show are requested; the others are not.
    await _show(tester, page.sublist(0, 2));
    expect(_jm.requested, <int>[1, 2]);
    for (final String tag in <String>['author-1', 'tag-1-a', 'tag-1-b', 'work-1', 'actor-1', 'tag-2-a']) {
      // The author is also the line under the title.
      expect(find.text(tag), tag == 'author-1' ? findsNWidgets(2) : findsOneWidget, reason: tag);
    }
    expect(find.text('tag-3-a'), findsNothing);
    // The language follows from the tags, as on the details page.
    expect(page.first.language, 'Chinese');
    expect(await tester.runAsync(_stored), <String>{'1', '2'});

    // The same list again: the tags come with the page, and nothing is
    // requested for the cards.
    page = (await tester.runAsync(_listPage))!;
    expect(page[0].tags.keys, <String>['artist', 'parody', 'character', 'tag']);
    expect(page[1].tags['tag']!.map((t) => t.tagData.key), <String>['tag-2-a', 'tag-2-b', '中文']);
    expect(page[2].tags.keys, <String>['artist']);
    await _show(tester, page.sublist(0, 2));
    expect(_jm.requested, <int>[1, 2]);
    expect(find.text('tag-1-a'), findsOneWidget);
  });

  testWidgets('the big waterfall card loads the tags as well', (WidgetTester tester) async {
    await start(tester);
    final List<Gallery> page = (await tester.runAsync(_listPage))!;

    await _show(tester, page.sublist(0, 1), waterfall: true);

    expect(_jm.requested, <int>[1]);
    // The tags are one row that scrolls: those past the card's width are
    // not built.
    expect(find.text('work-1'), findsOneWidget);
    expect(find.text('actor-1'), findsOneWidget);
    expect(page.first.tags['tag']!.map((t) => t.tagData.key), contains('tag-1-a'));
  });

  testWidgets('albums are requested a few at a time, and not for cards that left', (WidgetTester tester) async {
    await start(tester);
    _jm.held = true;
    final List<Gallery> page = (await tester.runAsync(_listPage))!;

    await _show(tester, page);
    expect(_jm.requested, <int>[1, 2, 3]);

    // Cards 5 and 6 leave before their turn; 1 is answered and 4 follows.
    await _show(tester, page.sublist(0, 4));
    await tester.runAsync(() async {
      _jm.release(1);
      await _settle();
    });
    await tester.pump();
    expect(_jm.requested, <int>[1, 2, 3, 4]);
    expect(find.text('tag-1-a'), findsOneWidget);
    expect(find.text('tag-2-a'), findsNothing);

    await tester.runAsync(() async {
      for (final int id in <int>[2, 3, 4]) {
        _jm.release(id);
      }
      await _settle();
    });
    await tester.pump();
    expect(_jm.requested, <int>[1, 2, 3, 4]);
    expect(_jm.mostInFlight, JmAlbumTagService.concurrency);
    expect(find.text('tag-4-a'), findsOneWidget);

    // A card that left while its request was out: the answer is kept.
    expect(await tester.runAsync(_stored), <String>{'1', '2', '3', '4'});
  });

  testWidgets('a request that failed is not repeated at once; details loaded elsewhere reach the card', (WidgetTester tester) async {
    await start(tester);
    _jm.failing.add(1);
    final List<Gallery> page = (await tester.runAsync(_listPage))!;

    await _show(tester, page.sublist(0, 1));
    expect(_jm.requested, <int>[1]);
    expect(find.text('tag-1-a'), findsNothing);

    // The card leaves and comes back.
    await _show(tester, const <Gallery>[]);
    await _show(tester, page.sublist(0, 1));
    expect(_jm.requested, <int>[1]);

    // The album's details page is opened and loads it.
    _jm.failing.clear();
    await tester.runAsync(() async {
      await _source.album(1);
      await _settle();
    });
    await tester.pump();
    expect(_jm.requested, <int>[1, 1]);
    expect(find.text('tag-1-a'), findsOneWidget);
    expect(page.first.tags.keys, <String>['artist', 'parody', 'character', 'tag']);
  });

  testWidgets('the details of the albums used last are kept', (WidgetTester tester) async {
    await start(tester);

    await tester.runAsync(() async {
      for (int id = 1; id <= JmSource.albumsKept + 1; id++) {
        await _source.album(id);
      }
      // Album 2 is used again, then one more album is loaded: 3 makes room.
      await _source.album(2);
      await _source.album(JmSource.albumsKept + 2);
      _jm.requested.clear();

      await _source.album(2);
      await _source.album(JmSource.albumsKept + 2);
      expect(_jm.requested, isEmpty);
      await _source.album(1);
      await _source.album(3);
      expect(_jm.requested, <int>[1, 3]);
      await _settle();
    });
  });
}
