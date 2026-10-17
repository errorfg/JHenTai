import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/network/jm/jm_image.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sr/realtime_sr_service.dart';
import 'package:jhentai/src/service/sr/sr_server_client.dart';
import 'package:jhentai/src/service/sr/sr_tools.dart';
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

/// A request the service got: its query and the pages, by name.
typedef _Request = ({Map<String, String> query, Map<String, Uint8List> pages});

/// The upscaling service of sr_server/, with a plain resize for a model:
/// the same requests and answers.
class _FakeService {
  late HttpServer _server;
  final List<_Request> requests = <_Request>[];

  /// Pages answered without a result, by name.
  Set<String> drop = <String>{};

  /// Requests answered by cutting the connection.
  bool cutConnections = false;

  /// Answered with this status and an error, when set.
  int? refuseWith;

  String get url => 'http://${_server.address.host}:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    if (request.method == 'GET' && request.uri.path == '/v1/models') {
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, Object>{
          'gpus': <String>['0: NVIDIA GeForce RTX 4080'],
          'maxPages': 16,
          'models': <Object>[
            for (final SrModel model in SrModel.all) <String, Object>{'id': model.id, 'available': model.engine == SrEngine.realesrgan},
          ],
        }));
      await request.response.close();
      return;
    }

    final BytesBuilder body = BytesBuilder();
    await request.forEach(body.add);
    if (cutConnections) {
      requests.add((query: request.uri.queryParameters, pages: const <String, Uint8List>{}));
      (await request.response.detachSocket()).destroy();
      return;
    }
    final Map<String, Uint8List> pages = <String, Uint8List>{
      for (final ArchiveFile file in ZipDecoder().decodeBytes(body.takeBytes()))
        file.name: Uint8List.fromList(file.content as List<int>),
    };
    requests.add((query: request.uri.queryParameters, pages: pages));
    if (refuseWith != null) {
      request.response
        ..statusCode = refuseWith!
        ..write(jsonEncode(<String, String>{'error': 'refused'}));
      await request.response.close();
      return;
    }

    final int scale = int.parse(request.uri.queryParameters['scale']!);
    final Archive answer = Archive();
    for (final MapEntry<String, Uint8List> page in pages.entries) {
      if (drop.contains(page.key)) {
        continue;
      }
      final img.Image image = img.decodeImage(page.value)!;
      final Uint8List jpeg = img.encodeJpg(img.copyResize(image, width: image.width * scale, height: image.height * scale));
      answer.addFile(ArchiveFile.noCompress(page.key, jpeg.length, jpeg));
    }
    request.response
      ..headers.contentType = ContentType('application', 'zip')
      ..add(ZipEncoder().encode(answer, level: Deflate.NO_COMPRESSION)!);
    await request.response.close();
  }
}

img.ColorRgb8 _colour(int page) => img.ColorRgb8(20 + page * 22, 250 - page * 22, (page * 97) % 256);

img.Image _plain(int page, {int width = 60, int height = 80}) => img.Image(width: width, height: height)..clear(_colour(page));

/// Ten horizontal bands of distinct colour.
img.ColorRgb8 _band(int band) => img.ColorRgb8(band * 25, 0, 255 - band * 25);

img.Image _bands(int width, int height) {
  final img.Image image = img.Image(width: width, height: height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      image.setPixel(x, y, _band(y * 10 ~/ height));
    }
  }
  return image;
}

/// [original] as JM stores it: cut into strips, stacked bottom-up.
img.Image _scrambled(img.Image original, int strips) {
  final img.Image stored = img.Image(width: original.width, height: original.height);
  for (final ({int srcY, int dstY, int height}) strip in JmImage.stripLayout(original.height, strips)) {
    img.compositeImage(stored, original,
        dstY: strip.srcY, dstW: original.width, dstH: strip.height, srcY: strip.dstY, srcW: original.width, srcH: strip.height, blend: img.BlendMode.direct);
  }
  return stored;
}

void _expectColour(img.Image image, img.ColorRgb8 colour, String reason) {
  final img.Pixel pixel = image.getPixel(image.width ~/ 2, image.height ~/ 2);
  expect(pixel.r, closeTo(colour.r, 10), reason: reason);
  expect(pixel.g, closeTo(colour.g, 10), reason: reason);
  expect(pixel.b, closeTo(colour.b, 10), reason: reason);
}

/// Pages go to an upscaling service on another computer: a phone or tablet
/// always, a desktop when it is chosen.
void main() {
  late _FakeService service;
  late Directory scratch;

  setUp(() async {
    log = _SilentLogService();
    scratch = Directory.systemTemp.createTempSync('sr_server_test');
    // flutter_test answers every HTTP request with 400 unless told not to.
    HttpOverrides.global = null;
    service = _FakeService();
    await service.start();
    superResolutionSetting = SuperResolutionSetting()
      ..realtimeOnServer.value = true
      ..realtimeServerUrl.value = service.url;
    // No programs here: the service does the work.
    realtimeSrService = RealtimeSrService()
      ..toolsRootOverride = '${scratch.path}/no-tools'
      ..workDirOverride = '${scratch.path}/work';
  });

  tearDown(() async {
    await service.stop();
    scratch.deleteSync(recursive: true);
  });

  test('on a desktop the service is used when chosen; it needs only its address', () {
    expect(realtimeSrService.onServer, isTrue);
    expect(realtimeSrService.supported, isTrue);
    expect(realtimeSrService.available, isTrue, reason: 'no program is installed here');

    superResolutionSetting.realtimeServerUrl.value = '';
    expect(realtimeSrService.available, isFalse);
    expect(realtimeSrService.unavailableMessage, 'realtimeSrNoServer');

    superResolutionSetting.realtimeOnServer.value = false;
    expect(realtimeSrService.onServer, isFalse);
    expect(realtimeSrService.available, isFalse);
    expect(realtimeSrService.unavailableMessage, 'realtimeSrNotInstalled');
  });

  testWidgets('waiting pages go to the service a batch per request, each getting its own result', (WidgetTester tester) async {
    await tester.runAsync(() async {
      superResolutionSetting
        ..realtimeBatchSize.value = 4
        ..realtimeModel.value = 'realcugan-se'
        ..realtimeScale.value = 2
        ..realtimeDenoise.value = -1;
      final Uint8List animated = img.encodeGif(img.Image(width: 40, height: 40)..addFrame(img.Image(width: 40, height: 40)));
      Uint8List encoded(int page) => page.isEven ? img.encodeJpg(_plain(page), quality: 95) : img.encodePng(_plain(page));
      realtimeSrService.focus = () => 3;
      final Map<int, Future<Uint8List?>> requests = <int, Future<Uint8List?>>{
        for (final int page in <int>[7, 0, 9, 3, 5, 1, 8, 2, 6, 4])
          page: realtimeSrService.upscale(
            sourceKey: 'page-$page',
            position: page,
            loadEncoded: () async => page == 6 ? animated : encoded(page),
          ),
      };
      final Map<int, Uint8List?> results = <int, Uint8List?>{
        for (final MapEntry<int, Future<Uint8List?>> e in requests.entries) e.key: await e.value,
      };

      // From the reader's page on, four to a request; page 6 is not sent.
      expect(service.requests.map((_Request r) => r.pages.keys.toList()), <List<String>>[
        <String>['0', '1', '2'],
        <String>['0', '1', '2', '3'],
        <String>['0', '1'],
      ]);
      expect(realtimeSrService.batchSizes, <int>[3, 4, 2]);
      expect(service.requests.first.query, <String, String>{'model': 'realcugan-se', 'scale': '2', 'denoise': '-1'});
      // The files go as they are, not decoded and encoded again.
      expect(service.requests.first.pages['0'], encoded(3));
      expect(service.requests.first.pages['1'], encoded(4));

      expect(results[6], isNull);
      for (final int page in <int>[0, 1, 2, 3, 4, 5, 7, 8, 9]) {
        final img.Image upscaled = img.decodeJpg(results[page]!)!;
        expect((upscaled.width, upscaled.height), (120, 160), reason: 'page $page');
        _expectColour(upscaled, _colour(page), 'page $page got another page\'s result');
      }
      // Asked again: from memory, no request.
      expect(identical(await realtimeSrService.upscale(sourceKey: 'page-3', position: 3, loadEncoded: () async => encoded(3)), results[3]), isTrue);
      expect(service.requests, hasLength(3));
      expect(Directory('${scratch.path}/work').existsSync() ? Directory('${scratch.path}/work').listSync() : <FileSystemEntity>[], isEmpty);
    });
  });

  testWidgets('a JM page goes with its strips back in order; a wide page is not sent', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final Uint8List stored = img.encodePng(_scrambled(_bands(120, 1000), 10));
      final Uint8List? jm = await realtimeSrService.upscale(sourceKey: 'jm', position: 0, strips: 10, loadEncoded: () async => stored);
      final img.Image sent = img.decodePng(service.requests.single.pages['0']!)!;
      for (int band = 0; band < 10; band++) {
        expect(sent.getPixel(60, ((band + 0.5) * 100).floor()).b, closeTo(_band(band).b, 2), reason: 'band $band');
      }
      expect(img.decodeJpg(jm!)!.height, 2000);

      superResolutionSetting.realtimeMaxWidth.value = 100;
      expect(await realtimeSrService.upscale(sourceKey: 'wide', position: 0, loadEncoded: () async => img.encodeJpg(_plain(1, width: 120))), isNull);
      expect(service.requests, hasLength(1));
    });
  });

  testWidgets('a page the service has no result for stays as it is; the others are upscaled', (WidgetTester tester) async {
    await tester.runAsync(() async {
      service.drop = <String>{'1'};
      final List<Future<Uint8List?>> pages = <Future<Uint8List?>>[
        for (int page = 0; page < 3; page++)
          realtimeSrService.upscale(sourceKey: 'p$page', position: page, loadEncoded: () async => img.encodePng(_plain(page))),
      ];
      final List<Uint8List?> results = await Future.wait(pages);
      expect(results.map((Uint8List? r) => r != null), <bool>[true, false, true]);
      _expectColour(img.decodeJpg(results[2]!)!, _colour(2), 'page 2');
    });
  });

  testWidgets('after the service cannot be reached, batches wait a while before it is tried again', (WidgetTester tester) async {
    await tester.runAsync(() async {
      Future<Uint8List?> page(String key) =>
          realtimeSrService.upscale(sourceKey: key, position: 0, loadEncoded: () async => img.encodePng(_plain(1)));

      realtimeSrService.serverRetryAfter = const Duration(milliseconds: 400);
      service.cutConnections = true;
      expect(await page('a'), isNull);
      expect(service.requests, hasLength(1));

      // Within the wait nothing is sent; the page stays as it is.
      service.cutConnections = false;
      expect(await page('b'), isNull);
      expect(service.requests, hasLength(1));

      // Once it is over, the service is tried again.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await page('c'), isNotNull);
      expect(service.requests, hasLength(2));
    });
  });

  testWidgets('a batch the service refuses stays as it is, and the next one is sent', (WidgetTester tester) async {
    await tester.runAsync(() async {
      Future<Uint8List?> page(String key) =>
          realtimeSrService.upscale(sourceKey: key, position: 0, loadEncoded: () async => img.encodePng(_plain(1)));
      service.refuseWith = 400;
      expect(await page('a'), isNull);
      service.refuseWith = null;
      expect(await page('b'), isNotNull);
      expect(service.requests, hasLength(2));
    });
  });

  test('the service tells its GPU and the models it can run', () async {
    final SrServerInfo info = await SrServerClient('${service.url}/ ').info();
    expect(info.gpus, <String>['0: NVIDIA GeForce RTX 4080']);
    expect(info.availableModels, <String>{'realesr-animevideov3', 'realesrgan-x4plus-anime', 'realesrgan-x4plus'});
  });
}
