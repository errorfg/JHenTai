import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_image.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/service/sr/realtime_sr_service.dart';
import 'package:jhentai/src/service/sr/sr_benchmark.dart';
import 'package:jhentai/src/service/sr/sr_input.dart';
import 'package:jhentai/src/service/sr/sr_tools.dart';
import 'package:jhentai/src/setting/super_resolution_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

/// Runs the upscaler benchmark on a folder of page images or on a JM
/// chapter: installs the upscaler programs that are missing, reads the pages
/// (downloading a chapter's once), times every model on them and writes a
/// report into a new folder (in the system's download folder where there
/// is one).
class SrBenchmarkDialog extends StatefulWidget {
  const SrBenchmarkDialog({super.key});

  @override
  State<SrBenchmarkDialog> createState() => _SrBenchmarkDialogState();
}

class _SrBenchmarkDialogState extends State<SrBenchmarkDialog> {
  final TextEditingController _chapter = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<String> _lines = <String>[];
  bool _running = false;
  String? _directory;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  @override
  void dispose() {
    _chapter.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The pages shipped with the app when there are any, else the JM chapter
  /// read last, as a start.
  Future<void> _prefill() async {
    final String? bundled = realtimeSrService.bundledPagesDir;
    if (bundled != null) {
      _chapter.text = bundled;
      return;
    }
    final List<LocalConfig> opened = await localConfigService.readBySubKeyPrefix(
      configKey: ConfigEnum.readIndexRecord,
      prefix: 'jm:album:',
    );
    if (opened.isEmpty || !mounted || _chapter.text.isNotEmpty) {
      return;
    }
    opened.sort((LocalConfig a, LocalConfig b) => b.utime.compareTo(a.utime));
    _chapter.text = opened.first.value;
  }

  void _log(String line) {
    if (!mounted) {
      return;
    }
    setState(() => _lines.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _run() async {
    final String source = _chapter.text.trim();
    final int? chapterId = int.tryParse(source);
    if (chapterId == null && !Directory(source).existsSync()) {
      return;
    }
    setState(() {
      _running = true;
      _directory = null;
      _lines.clear();
    });
    try {
      final String directory = chapterId != null
          ? await runSrBenchmarkOnJmChapter(chapterId, onLog: _log)
          : await runSrBenchmarkOnFolder(source, onLog: _log);
      if (mounted) {
        setState(() => _directory = directory);
      }
      _log('srBenchmarkDone'.tr);
    } catch (e, s) {
      log.error('Upscaler benchmark failed', e, s);
      _log('failed: $e');
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('srBenchmark'.tr),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('srBenchmarkHint'.tr, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              key: const Key('srBenchmarkChapter'),
              controller: _chapter,
              enabled: !_running,
              decoration: InputDecoration(labelText: 'srBenchmarkChapter'.tr, isDense: true),
            ),
            const SizedBox(height: 12),
            Container(
              height: 260,
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                controller: _scroll,
                itemCount: _lines.length,
                itemBuilder: (_, int i) => Text(_lines[i], style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
              ),
            ),
            if (_directory != null) SelectableText(_directory!, style: Theme.of(context).textTheme.bodySmall).marginOnly(top: 8),
          ],
        ),
      ),
      actions: [
        if (_directory != null)
          TextButton(
            onPressed: () => openFolder(_directory!),
            child: Text('openFolder'.tr),
          ),
        TextButton(onPressed: _running ? null : backRoute, child: Text('cancel'.tr)),
        TextButton(
          key: const Key('srBenchmarkStart'),
          onPressed: _running ? null : _run,
          child: _running
              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text('OK'.tr),
        ),
      ],
    );
  }
}

/// Shows [directory] in the system's file manager.
Future<void> openFolder(String directory) async {
  final String program = Platform.isWindows ? 'explorer' : (Platform.isMacOS ? 'open' : 'xdg-open');
  try {
    await Process.run(program, <String>[directory]);
  } catch (e) {
    log.error('Open folder failed: $directory', e);
  }
}

/// Installs the upscaler programs that are missing (none when they are
/// shipped with the app).
Future<void> _installMissingTools(void Function(String line) onLog) async {
  final String toolsRoot = realtimeSrService.toolsRoot;
  for (final SrEngine engine in SrEngine.values) {
    if (engine.isInstalled(toolsRoot)) {
      continue;
    }
    onLog('downloading ${engine.name} ...');
    int shown = -1;
    await realtimeSrService.install(
      engine,
      onProgress: (double progress) {
        final int tenth = (progress * 10).floor();
        if (tenth > shown) {
          shown = tenth;
          onLog('  ${tenth * 10}%');
        }
      },
    );
  }
}

/// A new folder for a benchmark, in the system's download folder where
/// there is one.
String _newBenchmarkDirectory() {
  final String stamp = DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());
  return p.join(
    (pathService.systemDownloadDir ?? pathService.getVisibleDir()).path,
    'JHenTai-SR-Benchmark-$stamp',
  );
}

Future<String> _runBenchmark({
  required String directory,
  required List<SrBenchmarkPage> pages,
  required String source,
  required void Function(String line) onLog,
  List<SrConfig>? configs,
  String? app,
}) async {
  if (pages.isEmpty) {
    throw StateError('No pages to upscale');
  }
  if (app == null) {
    final PackageInfo package = await PackageInfo.fromPlatform();
    app = '${package.version}+${package.buildNumber}';
  }
  await SrBenchmark(
    toolsRoot: realtimeSrService.toolsRoot,
    directory: directory,
    gpuId: superResolutionSetting.gpuId.value,
    onLog: onLog,
  ).run(
    pages: pages,
    configs: configs,
    info: <String, Object?>{'app': app, 'source': source},
  );
  return directory;
}

/// One page for the benchmark from its encoded bytes; null when it is
/// animated.
Future<SrBenchmarkPage?> _page(String name, Uint8List encoded, {int strips = 0, required void Function(String line) onLog}) async {
  final Stopwatch watch = Stopwatch()..start();
  final SrInput? input = await prepareSrInput(encoded, strips: strips);
  watch.stop();
  if (input == null) {
    onLog('  $name: animated, left out');
    return null;
  }
  onLog('  $name: ${input.width}x${input.height}, ${encoded.length} bytes');
  return SrBenchmarkPage(
    name: name,
    png: input.png,
    width: input.width,
    height: input.height,
    prepareMs: watch.elapsedMilliseconds,
  );
}

/// The benchmark on the images of [folder], in name order; nothing is
/// downloaded but upscaler programs that are missing. Returns the folder
/// with the report (`report.json`, `report.md`) and the upscaled pages.
/// [configs] narrows what is timed (everything by default).
Future<String> runSrBenchmarkOnFolder(
  String folder, {
  required void Function(String line) onLog,
  List<SrConfig>? configs,
  String? app,
}) async {
  await _installMissingTools(onLog);
  const Set<String> extensions = <String>{'.png', '.jpg', '.jpeg', '.webp'};
  final List<File> files = Directory(folder)
      .listSync()
      .whereType<File>()
      .where((File f) => extensions.contains(p.extension(f.path).toLowerCase()))
      .toList()
    ..sort((File a, File b) => p.basename(a.path).compareTo(p.basename(b.path)));
  onLog('$folder: ${files.length} pages');
  final List<SrBenchmarkPage> pages = <SrBenchmarkPage>[];
  for (final File file in files) {
    final SrBenchmarkPage? page = await _page(p.basenameWithoutExtension(file.path), await file.readAsBytes(), onLog: onLog);
    if (page != null) {
      pages.add(page);
    }
  }
  return _runBenchmark(
    directory: _newBenchmarkDirectory(),
    pages: pages,
    source: 'folder ${p.basename(folder)}',
    onLog: onLog,
    configs: configs,
    app: app,
  );
}

/// The benchmark on the JM chapter [chapterId], whose pages are downloaded
/// once, into the benchmark's folder, before anything is timed. Returns the
/// folder with the report and the upscaled pages. [configs] narrows what is
/// timed (everything by default); [fetch] gets a page's bytes, through the
/// app's downloader by default.
Future<String> runSrBenchmarkOnJmChapter(
  int chapterId, {
  required void Function(String line) onLog,
  List<SrConfig>? configs,
  Future<Uint8List> Function(String url)? fetch,
  String? app,
}) async {
  await _installMissingTools(onLog);
  final String directory = _newBenchmarkDirectory();
  final String rawDir = p.join(directory, 'downloaded');
  await Directory(rawDir).create(recursive: true);

  final JmChapterBundle bundle = await ehRequest.jmSource.bundle(chapterId);
  onLog('${bundle.title}: ${bundle.pageCount} pages');
  final List<SrBenchmarkPage> pages = <SrBenchmarkPage>[];
  for (int i = 0; i < bundle.pageCount; i++) {
    final String url = bundle.imageUrl(ehRequest.jmSource.imageDomain(), i);
    final String name = (i + 1).toString().padLeft(3, '0');
    final String rawPath = p.join(rawDir, '$name${p.extension(JmImage.requestUrl(url))}');
    if (fetch != null) {
      await File(rawPath).writeAsBytes(await fetch(JmImage.requestUrl(url)));
    } else {
      await ehRequest.download(url: url, path: rawPath);
    }
    final SrBenchmarkPage? page = await _page(
      name,
      await File(rawPath).readAsBytes(),
      strips: JmImage.stripsOf(url),
      onLog: onLog,
    );
    if (page != null) {
      pages.add(page);
    }
  }
  return _runBenchmark(
    directory: directory,
    pages: pages,
    source: 'JM chapter $chapterId: ${bundle.title}',
    onLog: onLog,
    configs: configs,
    app: app,
  );
}
