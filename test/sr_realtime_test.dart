import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/network/jm/jm_image.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sr/realtime_sr_service.dart';
import 'package:jhentai/src/service/sr/sr_benchmark.dart';
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
  // Failures of the upscaler are logged, not thrown; a test that gets no
  // page says why.
  // ignore: avoid_print
  void error(Object msg, [Object? error, StackTrace? stackTrace]) => print('logged error: $msg $error');
}

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

void _expectBands(img.Image image) {
  for (int band = 0; band < 10; band++) {
    final img.Pixel pixel = image.getPixel(image.width ~/ 2, ((band + 0.5) * image.height / 10).floor());
    expect(pixel.r, closeTo(_band(band).r, 12), reason: 'band $band red');
    expect(pixel.b, closeTo(_band(band).b, 12), reason: 'band $band blue');
  }
}

/// The upscaler programs run for real, from the folder named in
/// test/e2e/sr_e2e.json.
void main() {
  final File config = File('test/e2e/sr_e2e.json');
  final String? toolsRoot = config.existsSync() ? (jsonDecode(config.readAsStringSync()) as Map)['toolsRoot'] as String? : null;
  if (toolsRoot == null || !SrEngine.realesrgan.isInstalled(toolsRoot)) {
    test('real-time upscaling', () {}, skip: 'test/e2e/sr_e2e.json is absent or names no tools');
    return;
  }

  late Directory scratch;

  setUp(() {
    log = _SilentLogService();
    scratch = Directory.systemTemp.createTempSync('sr_realtime_test');
    superResolutionSetting = SuperResolutionSetting();
    realtimeSrService = RealtimeSrService()
      ..toolsRootOverride = toolsRoot
      ..cacheDirOverride = '${scratch.path}/cache';
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('each model upscales a page by its scale', () async {
    final String input = '${scratch.path}/page.png';
    File(input).writeAsBytesSync(img.encodePng(_bands(120, 160)));
    final SrRunner runner = SrRunner(toolsRoot);
    for (final SrConfig config in <SrConfig>[
      const SrConfig(model: SrModel.animeVideoV3, scale: 2),
      const SrConfig(model: SrModel.animeVideoV3, scale: 4),
      if (SrEngine.realcugan.isInstalled(toolsRoot)) SrConfig(model: SrModel.byId('realcugan-se'), scale: 2, denoise: -1),
    ]) {
      final String output = '${scratch.path}/${config.label}.jpg';
      final SrRunResult result = await runner.run(config: config, input: input, output: output);
      expect(result.ok, isTrue, reason: '${config.label}: ${result.stderr}');
      expect(result.gpus, isNotEmpty, reason: result.stderr);
      final img.Image upscaled = img.decodeJpg(File(output).readAsBytesSync())!;
      expect((upscaled.width, upscaled.height), (120 * config.scale, 160 * config.scale), reason: config.label);
      _expectBands(upscaled);
    }
  });

  testWidgets('a page is upscaled once and then comes from the disk', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final Uint8List page = img.encodePng(_bands(120, 160));
      Future<String?> request() =>
          realtimeSrService.upscale(sourceKey: 'https://example.test/1.png', position: 0, loadEncoded: () async => page);

      expect(realtimeSrService.cached('https://example.test/1.png'), isNull);
      final String? path = await request();
      expect(path, isNotNull);
      final img.Image upscaled = img.decodeJpg(File(path!).readAsBytesSync())!;
      expect((upscaled.width, upscaled.height), (240, 320));
      expect(realtimeSrService.runs, 1);

      expect(await request(), path);
      expect(realtimeSrService.cached('https://example.test/1.png'), path);
      expect(realtimeSrService.runs, 1, reason: 'the second time it is on disk');
      // Only finished pages are left in the cache.
      expect(Directory('${scratch.path}/cache').listSync().map((FileSystemEntity f) => f.path), <String>[path]);

      // Another scale is another upscaled copy.
      superResolutionSetting.realtimeScale.value = 4;
      final String? larger = await request();
      expect(larger, isNot(path));
      expect(img.decodeJpg(File(larger!).readAsBytesSync())!.width, 480);
      expect(realtimeSrService.runs, 2);
    });
  });

  testWidgets('a JM page is put back in order before it is upscaled; wide and animated pages are left alone', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final Uint8List stored = img.encodePng(_scrambled(_bands(120, 1000), 10));
      final String? path = await realtimeSrService.upscale(
        sourceKey: 'jm-page',
        position: 0,
        strips: 10,
        loadEncoded: () async => stored,
      );
      final img.Image upscaled = img.decodeJpg(File(path!).readAsBytesSync())!;
      expect((upscaled.width, upscaled.height), (240, 2000));
      _expectBands(upscaled);

      // At least as wide as the limit: left as it is.
      superResolutionSetting.realtimeMaxWidth.value = 100;
      expect(
        await realtimeSrService.upscale(sourceKey: 'wide', position: 0, loadEncoded: () async => img.encodePng(_bands(120, 160))),
        isNull,
      );
      superResolutionSetting.realtimeMaxWidth.value = 1600;

      final img.Image frame = _bands(40, 40);
      final Uint8List animated = img.encodeGif(frame..addFrame(_bands(40, 40)));
      expect(await realtimeSrService.upscale(sourceKey: 'animated', position: 0, loadEncoded: () async => animated), isNull);
      expect(realtimeSrService.runs, 1);
    });
  });

  testWidgets('pages ahead of the reader are upscaled first, the nearest first', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final Uint8List page = img.encodePng(_bands(60, 80));
      final List<int> order = <int>[];
      realtimeSrService.focus = () => 2;
      final List<Future<String?>> requests = <Future<String?>>[
        for (final int position in <int>[5, 1, 9, 2])
          realtimeSrService.upscale(
            sourceKey: 'page-$position',
            position: position,
            loadEncoded: () async {
              order.add(position);
              return page;
            },
          ),
      ];
      await Future.wait(requests);
      // Page 5 was taken as it came, with nothing else waiting; then the
      // reader's page 2, 9 ahead of it, and 1 behind it last.
      expect(order, <int>[5, 2, 9, 1]);

      // Leaving the reader drops what still waits.
      final Future<String?> first = realtimeSrService.upscale(sourceKey: 'a', position: 0, loadEncoded: () async => page);
      final Future<String?> second = realtimeSrService.upscale(sourceKey: 'b', position: 1, loadEncoded: () async => page);
      realtimeSrService.clearPending();
      expect(await second, isNull);
      expect(await first, isNotNull, reason: 'the page in the program finishes');
    });
  });
  test('the benchmark times each configuration and keeps the upscaled pages', () async {
    final List<String> lines = <String>[];
    final SrBenchmark benchmark = SrBenchmark(toolsRoot: toolsRoot, directory: '${scratch.path}/bench', onLog: lines.add);
    final File report = await benchmark.run(
      pages: <SrBenchmarkPage>[
        for (final String name in <String>['01', '02'])
          SrBenchmarkPage(name: name, png: img.encodePng(_bands(120, 160)), width: 120, height: 160, prepareMs: 3),
      ],
      configs: <SrConfig>[
        const SrConfig(model: SrModel.animeVideoV3, scale: 2),
        SrConfig(model: SrModel.byId('realcugan-se'), scale: 2, denoise: 0),
      ],
      info: <String, Object?>{'source': 'test pages'},
    );

    final Map<String, dynamic> json = jsonDecode(report.readAsStringSync()) as Map<String, dynamic>;
    expect(json['gpus'], isNotEmpty);
    expect(json['source'], 'test pages');
    expect((json['pages'] as List<dynamic>).map((dynamic p) => (p['name'], p['width'], p['height'], p['prepareMs'])), [
      ('01', 120, 160, 3),
      ('02', 120, 160, 3),
    ]);
    final List<dynamic> results = json['results'] as List<dynamic>;
    expect(results.map((dynamic r) => r['config']), <String>['realesr-animevideov3-x2', 'realcugan-se-x2-n0']);
    for (final dynamic result in results) {
      if (result['engine'] == 'realcugan' && !SrEngine.realcugan.isInstalled(toolsRoot)) {
        expect(result['error'], contains('not installed'));
        continue;
      }
      expect(result['error'], isNull, reason: '${result['config']}');
      expect(result['perPageMs'], hasLength(2));
      expect(result['perPageAvgMs'], greaterThan(0));
      expect(result['batchPerPageMs'], greaterThan(0));
      // The upscaled pages stay, to compare the models by eye.
      final img.Image kept = img.decodeJpg(File('${scratch.path}/bench/out/${result['config']}/01.jpg').readAsBytesSync())!;
      expect((kept.width, kept.height), (240, 320));
    }
    final String markdown = File('${scratch.path}/bench/report.md').readAsStringSync();
    expect(markdown, contains('| realesr-animevideov3-x2 |'));
    expect(lines.last, contains('report.json'));
  });
}
