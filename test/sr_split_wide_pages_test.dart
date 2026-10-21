import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/network/tachi/tachi_client.dart';
import 'package:jhentai/src/network/tachi/tachi_host.dart';
import 'package:jhentai/src/network/tachi/tachi_models.dart';
import 'package:jhentai/src/network/tachi/tachi_source.dart';
import 'package:jhentai/src/pages/read/layout/horizontal_page/horizontal_page_layout_logic.dart';
import 'package:jhentai/src/pages/read/read_page.dart';
import 'package:jhentai/src/pages/read/read_page_logic.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/sr/realtime_sr_service.dart';
import 'package:jhentai/src/service/sr/sr_input.dart';
import 'package:jhentai/src/setting/read_setting.dart';
import 'package:jhentai/src/setting/super_resolution_setting.dart';

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

/// Image 1 is two pages scanned as one: 600 x 400; the others 300 x 400.
const List<bool> _wide = <bool>[false, true, false];

/// Pages are left as they are from this width on: image 1 whole is, each
/// of its halves is not.
const int _maxWidth = 400;

Uint8List _page(int index) =>
    img.encodePng(img.Image(width: _wide[index] ? 600 : 300, height: 400)..clear(img.ColorRgb8(40 + 60 * index, 120, 200)));

/// A site serving the book's pages as `/p<index>.png`.
class _FakeSite {
  late HttpServer _server;

  /// The pages asked for, by index.
  final List<int> served = <int>[];

  String pageUrl(int index) => 'http://${_server.address.host}:${_server.port}/p$index.png';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((HttpRequest request) async {
      final int index = int.parse(RegExp(r'^/p(\d+)\.png$').firstMatch(request.uri.path)!.group(1)!);
      served.add(index);
      request.response
        ..headers.contentType = ContentType('image', 'png')
        ..add(_page(index));
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

/// The extension host: serves a source's page images, to the app's token
/// only.
class _FakeHost {
  static const String token = 'host-token';

  late HttpServer _server;

  /// The pages asked for, by index.
  final List<int> served = <int>[];

  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((HttpRequest request) async {
      if (request.uri.path != '/image' || request.headers.value(HttpHeaders.authorizationHeader) != 'Bearer $token') {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      final int index = int.parse(request.uri.queryParameters['index']!);
      served.add(index);
      request.response
        ..headers.contentType = ContentType('image', 'png')
        ..add(_page(index));
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

/// The host running, without starting one.
class _RunningHost extends TachiHost {
  _RunningHost(this._running);

  final TachiClient _running;

  @override
  TachiClient? get clientIfRunning => _running;

  @override
  Future<TachiClient> client() async => _running;
}

/// The upscaling service of sr_server/, a plain resize for a model.
class _FakeService {
  late HttpServer _server;

  /// The widths of the pages sent, request by request.
  final List<List<int>> sentWidths = <List<int>>[];

  String get url => 'http://${_server.address.host}:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((HttpRequest request) async {
      final BytesBuilder body = BytesBuilder();
      await request.forEach(body.add);
      final int scale = int.parse(request.uri.queryParameters['scale']!);
      final Archive answer = Archive();
      final List<int> widths = <int>[];
      for (final ArchiveFile file in ZipDecoder().decodeBytes(body.takeBytes())) {
        final img.Image image = img.decodeImage(Uint8List.fromList(file.content as List<int>))!;
        widths.add(image.width);
        final Uint8List png = img.encodePng(img.copyResize(image, width: image.width * scale, height: image.height * scale));
        answer.addFile(ArchiveFile.noCompress(file.name, png.length, png));
      }
      sentWidths.add(widths);
      request.response
        ..headers.contentType = ContentType('application', 'zip')
        ..add(ZipEncoder().encode(answer, level: Deflate.NO_COMPRESSION)!);
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

/// A book read online, its pages at [pageUrl].
ReadPageInfo _book(String Function(int index) pageUrl) {
  return ReadPageInfo(
    mode: ReadMode.online,
    gid: 9,
    token: 'test',
    galleryTitle: 'Book',
    galleryUrl: 'https://example.test/book/9',
    initialIndex: 0,
    pageCount: _wide.length,
    readProgressRecordStorageKey: 'sr-split',
    thumbnails: <GalleryThumbnail?>[
      for (int i = 0; i < _wide.length; i++) GalleryThumbnail(href: 'test://book/$i', isLarge: true, thumbUrl: ''),
    ],
    images: <GalleryImage?>[
      for (int i = 0; i < _wide.length; i++) GalleryImage(url: pageUrl(i)),
    ],
    useSuperResolution: false,
  );
}

/// Pages upscaled while reading with wide pages split: the width limit is
/// compared with what is shown of a page, a half of a wide image.
void main() {
  late _FakeSite site;
  late _FakeService service;
  late Directory scratch;

  setUp(() async {
    log = _SilentLogService();
    scratch = Directory.systemTemp.createTempSync('sr_split_wide_pages');
    // flutter_test answers every HTTP request with 400 unless told not to.
    HttpOverrides.global = null;
    site = _FakeSite();
    await site.start();
    service = _FakeService();
    await service.start();
    superResolutionSetting = SuperResolutionSetting()
      ..realtimeEnabled.value = true
      ..realtimeOnServer.value = true
      ..realtimeServerUrl.value = service.url
      ..realtimeMaxWidth.value = _maxWidth;
    realtimeSrService = RealtimeSrService()
      ..toolsRootOverride = '${scratch.path}/no-tools'
      ..workDirOverride = '${scratch.path}/work';
  });

  tearDown(() async {
    await site.stop();
    await service.stop();
    scratch.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester, ReadPageInfo book, {required bool split}) async {
    appDb = (await tester.runAsync(() async => AppDb.forTesting(NativeDatabase.memory())))!;
    Get.testMode = true;
    Get.put<ReadProgressService>(readProgressService, permanent: true);
    Get.put<GalleryDownloadService>(galleryDownloadService, permanent: true);
    readSetting.readDirection.value = ReadDirection.right2leftSinglePage;
    readSetting.enableOrientationSpecificReadDirection.value = false;
    readSetting.keepScreenAwakeWhenReading.value = false;
    readSetting.showThumbnails.value = false;
    readSetting.enablePageTurnAnime.value = false;
    readSetting.splitWidePages.value = split;
    readSetting.invertSplitOrder.value = false;
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async => null);
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (ByteData? message) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
    // The network image provider keeps downloads in the temporary directory.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => scratch.path,
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(GetMaterialApp(home: const Scaffold(), getPages: [GetPage(name: '/read', page: () => const ReadPage())]));
      Get.toNamed('/read', arguments: book);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
  }

  Future<void> settle(WidgetTester tester, {int rounds = 16}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await settle(tester, rounds: 1);
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.runAsync(() async {
      Get.back();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    // The route leaves and the reader is disposed with it.
    await settle(tester, rounds: 10);
    expect(Get.isRegistered<ReadPageLogic>(), isFalse);
    await tester.runAsync(() async {
      Get.reset();
      await appDb.close();
    });
    // The image loader's idle connections close after 15 seconds.
    await tester.pump(const Duration(seconds: 16));
    readSetting.splitWidePages.value = false;
  }

  List<int> upscaled(ReadPageLogic reader) => <int>[for (int i = 0; i < _wide.length; i++) if (reader.upscaledPage(i) != null) i];

  testWidgets('for the programs on a desktop and for the service alike, a split wide page counts at half its width', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final Uint8List wide = _page(1);
      // Not a format sent as it is: decoded first, as for the programs.
      final Uint8List gif = img.encodeGif(img.decodePng(wide)!);
      // A portrait page is never halved.
      final Uint8List tall = img.encodePng(img.Image(width: 500, height: 800));
      for (final Uint8List page in <Uint8List>[wide, gif]) {
        expect(await prepareSrInput(page, maxWidth: _maxWidth), isNull);
        expect((await prepareSrInput(page, maxWidth: _maxWidth, splitWide: true))?.width, 600, reason: 'the whole image goes');
        expect(await prepareSrUpload(page, maxWidth: _maxWidth), isNull);
        expect(await prepareSrUpload(page, maxWidth: _maxWidth, splitWide: true), isNotNull);
      }
      expect(await prepareSrInput(tall, maxWidth: _maxWidth, splitWide: true), isNull);
      expect(await prepareSrUpload(tall, maxWidth: _maxWidth, splitWide: true), isNull);
    });
  });

  testWidgets('shown whole, a wide page over the limit is left as it is; split while reading, it is upscaled', (WidgetTester tester) async {
    await open(tester, _book(site.pageUrl), split: false);
    await settle(tester);
    final ReadPageLogic reader = Get.find<ReadPageLogic>();
    expect(reader.realtimeSrOn, isTrue);

    await waitFor(tester, () => upscaled(reader).length >= 2);
    expect(upscaled(reader), <int>[0, 2], reason: 'image 1 is shown 600 wide, over the limit');
    expect(service.sentWidths.expand((List<int> w) => w), isNot(contains(600)));

    // Split now: image 1 is shown in halves 300 wide, and is upscaled.
    readSetting.splitWidePages.value = true;
    await waitFor(tester, () => reader.upscaledPage(1) != null);
    expect(upscaled(reader), <int>[0, 1, 2]);
    expect(service.sentWidths.last, <int>[600]);

    await close(tester);
  });

  testWidgets('a Tachiyomi page is read from the extension host, with its token, and upscaled', (WidgetTester tester) async {
    final _FakeHost host = _FakeHost();
    await tester.runAsync(host.start);
    tachiHost = _RunningHost(TachiClient(port: host.port, token: _FakeHost.token));
    addTearDown(() async {
      tachiHost = TachiHost();
      await host.stop();
    });

    // Kept as tachi-image:// addresses; the host's port and token are
    // worked out when a page is shown or upscaled.
    await open(tester, _book((int i) => TachiImages.page('2001', TachiPage(index: i, url: '', imageUrl: 'https://site.test/p$i.png'))), split: true);
    await settle(tester);
    final ReadPageLogic reader = Get.find<ReadPageLogic>();

    await waitFor(tester, () => upscaled(reader).length == _wide.length);
    expect(upscaled(reader), <int>[0, 1, 2]);
    expect(service.sentWidths.expand((List<int> w) => w), <int>[300, 600, 300]);
    expect(host.served, containsAll(<int>[0, 1, 2]));

    await close(tester);
  });

  testWidgets('split, a wide page is judged by the width of a half, and its halves show the upscaled copy', (WidgetTester tester) async {
    await open(tester, _book(site.pageUrl), split: true);
    await settle(tester);
    final ReadPageLogic reader = Get.find<ReadPageLogic>();

    await waitFor(tester, () => upscaled(reader).length == _wide.length);
    expect(upscaled(reader), <int>[0, 1, 2]);
    expect(service.sentWidths, <List<int>>[
      <int>[300, 600, 300],
    ], reason: 'the three pages in one batch');

    // Image 1's first half: drawn from the upscaled copy, 1200 x 800.
    final HorizontalPageLayoutLogic layout = Get.find<HorizontalPageLayoutLogic>();
    layout.toNext();
    await settle(tester);
    expect(reader.state.currentImageIndex, 1);
    final Iterable<ui.Image?> shown = find.byType(ExtendedRawImage).evaluate().map((Element e) => (e.widget as ExtendedRawImage).image);
    expect(shown.any((ui.Image? image) => image != null && image.width == 1200 && image.height == 800), isTrue);

    await close(tester);
  });
}
