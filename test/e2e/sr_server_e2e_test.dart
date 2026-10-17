import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sr/realtime_sr_service.dart';
import 'package:jhentai/src/service/sr/sr_server_client.dart';
import 'package:jhentai/src/service/sr/sr_tools.dart';
import 'package:jhentai/src/setting/super_resolution_setting.dart';

class _PrintingLogService extends LogService {
  @override
  void trace(Object msg, [bool withStack = false]) => debugPrint('$msg');
  @override
  void debug(Object msg, [bool withStack = false]) {}
  @override
  void info(Object msg, [bool withStack = false]) {}
  @override
  void warning(Object msg, [Object? error, bool withStack = false]) => debugPrint('warning: $msg $error');
  @override
  void error(Object msg, [Object? error, StackTrace? stackTrace]) => debugPrint('error: $msg $error');
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

/// The upscaling service of sr_server/, running for real at the address in
/// test/e2e/sr_server_e2e.json (copy from sr_server_e2e.example.json).
void main() {
  final File config = File('test/e2e/sr_server_e2e.json');
  final String? url = config.existsSync() ? (jsonDecode(config.readAsStringSync()) as Map)['url'] as String? : null;
  if (url == null || url.isEmpty) {
    test('upscaling service', () {}, skip: 'test/e2e/sr_server_e2e.json is absent or names no service');
    return;
  }

  late Directory scratch;

  setUp(() {
    // flutter_test answers every HTTP request with 400 unless told not to.
    HttpOverrides.global = null;
    log = _PrintingLogService();
    scratch = Directory.systemTemp.createTempSync('sr_server_e2e');
    superResolutionSetting = SuperResolutionSetting()
      ..realtimeOnServer.value = true
      ..realtimeServerUrl.value = url;
    realtimeSrService = RealtimeSrService()..workDirOverride = '${scratch.path}/work';
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('the service runs every model', () async {
    final SrServerInfo info = await SrServerClient(url).info();
    debugPrint('GPUs: ${info.gpus}');
    expect(info.gpus, isNotEmpty);
    expect(info.availableModels, SrModel.all.map((SrModel model) => model.id).toSet());
  });

  testWidgets('a batch of pages comes back upscaled by each engine', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final List<Uint8List> pages = <Uint8List>[
        for (int i = 0; i < 4; i++) img.encodeJpg(_bands(600 + i * 20, 850), quality: 90),
      ];
      for (final (String model, int scale, int denoise) choice in <(String, int, int)>[
        ('realesr-animevideov3', 2, 0),
        ('realcugan-se', 2, -1),
      ]) {
        superResolutionSetting
          ..realtimeModel.value = choice.$1
          ..realtimeScale.value = choice.$2
          ..realtimeDenoise.value = choice.$3;
        final Stopwatch watch = Stopwatch()..start();
        final List<Uint8List?> results = await Future.wait(<Future<Uint8List?>>[
          for (int i = 0; i < pages.length; i++)
            realtimeSrService.upscale(sourceKey: '${choice.$1}-$i', position: i, loadEncoded: () async => pages[i]),
        ]);
        debugPrint('${choice.$1} x${choice.$2}: ${pages.length} pages in ${watch.elapsedMilliseconds} ms, '
            '${results.fold<int>(0, (int sum, Uint8List? r) => sum + (r?.length ?? 0)) ~/ 1024} KB back');
        for (int i = 0; i < pages.length; i++) {
          final img.Image upscaled = img.decodeJpg(results[i]!)!;
          expect((upscaled.width, upscaled.height), ((600 + i * 20) * 2, 1700), reason: '${choice.$1} page $i');
          for (int band = 0; band < 10; band++) {
            final img.Pixel pixel = upscaled.getPixel(upscaled.width ~/ 2, ((band + 0.5) * upscaled.height / 10).floor());
            expect(pixel.b, closeTo(_band(band).b, 16), reason: '${choice.$1} page $i band $band');
          }
        }
      }
      expect(realtimeSrService.batchSizes, <int>[4, 4]);
    });
  });
}
