// Live requests to JM and real runs of the upscaler programs.
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_api.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/pages/setting/advanced/super_resolution/sr_benchmark_dialog.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/service/sr/realtime_sr_service.dart';
import 'package:jhentai/src/service/sr/sr_tools.dart';
import 'package:jhentai/src/setting/super_resolution_setting.dart';

import 'support/e2e_app.dart';

/// The benchmark as the settings page runs it, on a real JM chapter.
/// Enabled by test/e2e/jm_e2e.json and test/e2e/sr_e2e.json; the latter may
/// set "chapter" (a JM chapter number), "full" (every configuration, kept in
/// "keep") and "install" (download the programs into a fresh folder first).
void main() {
  Map<dynamic, dynamic> read(String path) =>
      File(path).existsSync() ? jsonDecode(File(path).readAsStringSync()) as Map : const <String, dynamic>{};
  final Map<dynamic, dynamic> jm = read('test/e2e/jm_e2e.json');
  final Map<dynamic, dynamic> sr = read('test/e2e/sr_e2e.json');
  final String? toolsRoot = sr['toolsRoot'] as String?;
  if (jm['enabled'] != true || toolsRoot == null) {
    test('upscaler benchmark e2e', () {}, skip: 'test/e2e/jm_e2e.json or test/e2e/sr_e2e.json is absent');
    return;
  }

  late Directory scratch;
  final Dio dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(minutes: 5)));

  setUpAll(() {
    HttpOverrides.global = null;
    log = SilentLogService();
    List<String> domains = <String>[];
    // Set once: the app's JM source cannot be replaced.
    ehRequest.jmSource = JmSource(
      api: JmApi(dio: dio, apiDomains: () => domains, onApiDomainsDiscovered: (List<String> latest) => domains = latest),
      imageDomain: () => JmApi.imageDomains.first,
    );
  });

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('sr_benchmark_e2e');
    superResolutionSetting = SuperResolutionSetting();
    pathService.systemDownloadDir = scratch;
    realtimeSrService = RealtimeSrService()..toolsRootOverride = toolsRoot;
  });

  tearDown(() {
    if (sr['keep'] == null) {
      scratch.deleteSync(recursive: true);
    }
  });

  Future<Uint8List> fetch(String url) async =>
      Uint8List.fromList((await dio.get<List<int>>(url, options: Options(responseType: ResponseType.bytes))).data!);

  testWidgets('a JM chapter is downloaded, upscaled by the models and reported', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final List<String> lines = <String>[];
      final bool full = sr['full'] == true;
      // The chapter named in the config, else this week's most viewed album.
      final int chapter = (sr['chapter'] as int?) ??
          (await ehRequest.jmSource.list(const JmFilterQuery(order: 'mv', period: 'w'))).gallerys.first.galleryUrl.jmChapterId;
      final String directory = await runSrBenchmarkOnJmChapter(
        chapter,
        onLog: (String line) {
          lines.add(line);
          // ignore: avoid_print
          print(line);
        },
        configs: full
            ? null
            : <SrConfig>[
                const SrConfig(model: SrModel.animeVideoV3, scale: 2),
                SrConfig(model: SrModel.byId('realcugan-se'), scale: 2, denoise: -1),
              ],
        fetch: fetch,
        app: 'test',
      );

      final Map<String, dynamic> report = jsonDecode(File('$directory/report.json').readAsStringSync()) as Map<String, dynamic>;
      final List<dynamic> pages = report['pages'] as List<dynamic>;
      expect(pages, isNotEmpty);
      expect(report['source'], contains('JM chapter'));
      final List<dynamic> results = report['results'] as List<dynamic>;
      expect(results, hasLength(full ? SrConfig.everything.length : 2));
      for (final dynamic result in results) {
        expect(result['error'], isNull, reason: '${result['config']}');
        expect(result['perPageMs'], hasLength(pages.length));
        expect(Directory('$directory/out/${result['config']}').listSync(), hasLength(pages.length));
      }
      expect(File('$directory/report.md').existsSync(), isTrue);

      if (sr['keep'] != null) {
        final Directory keep = Directory(sr['keep'] as String);
        if (keep.existsSync()) {
          keep.deleteSync(recursive: true);
        }
        Directory(directory).renameSync(keep.path);
      }
    });
  });

  testWidgets('a folder of pages is benchmarked without any download', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final Directory pages = Directory('${scratch.path}/pages')..createSync();
      for (int i = 1; i <= 3; i++) {
        File('${pages.path}/00$i.png').writeAsBytesSync(img.encodePng(img.Image(width: 90, height: 120)..clear(img.ColorRgb8(40 * i, 30, 60))));
      }
      File('${pages.path}/notes.txt').writeAsStringSync('not a page');
      // Any request would fail: no JM source, no downloader.
      final String directory = await runSrBenchmarkOnFolder(
        pages.path,
        onLog: (_) {},
        configs: <SrConfig>[const SrConfig(model: SrModel.animeVideoV3, scale: 2)],
        app: 'test',
      );
      final Map<String, dynamic> report = jsonDecode(File('$directory/report.json').readAsStringSync()) as Map<String, dynamic>;
      expect((report['pages'] as List<dynamic>).map((dynamic p) => p['name']), <String>['001', '002', '003']);
      expect(report['source'], 'folder pages');
      final dynamic result = (report['results'] as List<dynamic>).single;
      expect(result['error'], isNull);
      expect(result['perPageMs'], hasLength(3));
      expect(Directory('$directory/out/realesr-animevideov3-x2').listSync(), hasLength(3));
    });
  });

  testWidgets('the programs are downloaded, unpacked and run', (WidgetTester tester) async {
    await tester.runAsync(() async {
      realtimeSrService.toolsRootOverride = '${scratch.path}/tools';
      for (final SrEngine engine in SrEngine.values) {
        expect(engine.isInstalled(realtimeSrService.toolsRoot), isFalse);
        await realtimeSrService.install(
          engine,
          download: (String url, String path, void Function(int, int) onProgress) => dio.download(url, path, onReceiveProgress: onProgress),
        );
        expect(engine.isInstalled(realtimeSrService.toolsRoot), isTrue);
      }
      // Installed where the runner looks for them: a page goes through.
      final File page = File('${scratch.path}/page.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 64, height: 64)..clear(img.ColorRgb8(200, 30, 60))));
      for (final SrConfig config in <SrConfig>[
        const SrConfig(model: SrModel.animeVideoV3, scale: 2),
        SrConfig(model: SrModel.byId('realcugan-se'), scale: 2),
      ]) {
        final SrRunResult result = await SrRunner(realtimeSrService.toolsRoot)
            .run(config: config, input: page.path, output: '${scratch.path}/${config.label}.jpg');
        expect(result.ok, isTrue, reason: result.stderr);
        expect(File('${scratch.path}/${config.label}.jpg').existsSync(), isTrue);
      }
    });
  }, skip: sr['install'] != true);
}
