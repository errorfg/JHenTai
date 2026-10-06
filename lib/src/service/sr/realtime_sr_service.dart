import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/service/sr/sr_input.dart';
import 'package:jhentai/src/service/sr/sr_tools.dart';
import 'package:jhentai/src/setting/super_resolution_setting.dart';
import 'package:jhentai/src/utils/archive_util.dart';
import 'package:path/path.dart' as p;

RealtimeSrService realtimeSrService = RealtimeSrService();

class _Task {
  _Task({
    required this.key,
    required this.config,
    required this.position,
    required this.strips,
    required this.loadEncoded,
  });

  final String key;
  final SrConfig config;
  final int position;
  final int strips;
  final Future<Uint8List?> Function() loadEncoded;
  final Completer<Uint8List?> done = Completer<Uint8List?>();
}

/// Upscales pages as they are read (desktop): pages go through one of the
/// upscaler programs a batch at a time, the ones just ahead of where the
/// reader is first, and the results are shown in place of the originals.
///
/// Starting the program costs far more than a page (about 0.85 s against
/// 0.03 s on an RTX 5090), so a run takes a batch of the waiting pages.
///
/// Nothing is kept on disk. The programs only read and write files, so a
/// batch passes through a temporary folder that is deleted as soon as its
/// results are read; the upscaled pages stay in memory, up to
/// [memoryLimitBytes], the least recently used going first.
class RealtimeSrService {
  /// Upscaled pages (encoded) kept in memory.
  static const int memoryLimitBytes = 512 * 1024 * 1024;

  /// Set by tests; the app keeps the programs with its own data and the
  /// folders of running batches with its temporary files.
  String? toolsRootOverride;
  String? workDirOverride;

  /// Where the upscaler programs are: a `sr_tools` folder shipped next to
  /// the app's executable when there is one, so that nothing has to be
  /// downloaded; otherwise the folder they are installed into.
  String get toolsRoot {
    if (toolsRootOverride != null) {
      return toolsRootOverride!;
    }
    final String bundled = p.join(p.dirname(Platform.resolvedExecutable), bundledToolsDirName);
    if (Directory(bundled).existsSync()) {
      return bundled;
    }
    return p.join((pathService.appSupportDir ?? pathService.getVisibleDir()).path, 'sr_tools');
  }

  static const String bundledToolsDirName = 'sr_tools';

  /// Pages for the benchmark shipped next to the app's executable, if any.
  static const String bundledPagesDirName = 'sr-benchmark-pages';

  String? get bundledPagesDir {
    final String dir = p.join(p.dirname(Platform.resolvedExecutable), bundledPagesDirName);
    return Directory(dir).existsSync() ? dir : null;
  }

  /// Parent of the folders batches pass through.
  String get workDir => workDirOverride ?? p.join(pathService.tempDir.path, 'sr_work');

  /// The model, scale and denoise level chosen in the settings; a scale or
  /// level the model lacks falls back to its first.
  SrConfig get config {
    final SrModel model = SrModel.byId(superResolutionSetting.realtimeModel.value);
    final int scale = superResolutionSetting.realtimeScale.value;
    final int denoise = superResolutionSetting.realtimeDenoise.value;
    return SrConfig(
      model: model,
      scale: model.scales.contains(scale) ? scale : model.scales.first,
      denoise: model.denoiseLevels.contains(denoise) ? denoise : (model.denoiseLevels.isEmpty ? 0 : model.denoiseLevels.first),
    );
  }

  /// Pages a run of the program takes at most.
  int get batchSize => superResolutionSetting.realtimeBatchSize.value.clamp(1, 64);

  /// Whether the program of the chosen model is there to run.
  bool get available => GetPlatform.isDesktop && config.model.engine.isInstalled(toolsRoot);

  bool get active => superResolutionSetting.realtimeEnabled.value && available;

  /// The page the reader is at, for ordering the queue.
  int Function()? focus;

  final List<_Task> _pending = <_Task>[];
  final Map<String, Future<Uint8List?>> _requests = <String, Future<Uint8List?>>{};
  bool _running = false;
  bool _cleaned = false;

  /// Upscaled pages by key, least recently used first.
  final LinkedHashMap<String, Uint8List> _memory = LinkedHashMap<String, Uint8List>();
  int _memoryBytes = 0;

  /// Runs of an upscaler program so far, and the pages of each; tests tell
  /// batches and pages served from memory by them.
  int runs = 0;
  final List<int> batchSizes = <int>[];

  String _keyOf(String sourceKey) => '${config.label}|$sourceKey';

  /// The upscaled copy of the page [sourceKey] (encoded), when it is in
  /// memory.
  Uint8List? cached(String sourceKey) {
    final String key = _keyOf(sourceKey);
    final Uint8List? bytes = _memory.remove(key);
    if (bytes != null) {
      _memory[key] = bytes;
    }
    return bytes;
  }

  void _remember(String key, Uint8List bytes) {
    _memoryBytes -= _memory.remove(key)?.length ?? 0;
    _memory[key] = bytes;
    _memoryBytes += bytes.length;
    while (_memoryBytes > memoryLimitBytes && _memory.length > 1) {
      _memoryBytes -= _memory.remove(_memory.keys.first)!.length;
    }
  }

  /// Upscales the page [sourceKey] (its url or file path), whose encoded
  /// bytes [loadEncoded] gives. Completes with the upscaled image, encoded;
  /// with null when the page is left as it is (animated, wide enough
  /// already), cannot be read, the program fails, or the queue was cleared
  /// first. [position] is the page's place in the reader.
  Future<Uint8List?> upscale({
    required String sourceKey,
    required int position,
    required Future<Uint8List?> Function() loadEncoded,
    int strips = 0,
  }) {
    final Uint8List? hit = cached(sourceKey);
    if (hit != null) {
      return Future<Uint8List?>.value(hit);
    }
    final String key = _keyOf(sourceKey);
    final Future<Uint8List?>? known = _requests[key];
    if (known != null) {
      return known;
    }
    final _Task task = _Task(key: key, config: config, position: position, strips: strips, loadEncoded: loadEncoded);
    _pending.add(task);
    // A block body: returning the removed future (this very request) from
    // whenComplete would make it wait for itself.
    final Future<Uint8List?> request = task.done.future.whenComplete(() {
      _requests.remove(key);
    });
    _requests[key] = request;
    unawaited(_pump());
    return request;
  }

  /// Drops the pages still waiting; the batch in the program finishes.
  void clearPending() {
    for (final _Task task in _pending) {
      task.done.complete(null);
    }
    _pending.clear();
  }

  /// The next batch: the waiting pages nearest ahead of the reader, pages
  /// behind it last, up to [batchSize], of one model configuration.
  List<_Task> _takeBatch() {
    final int at = focus?.call() ?? 0;
    int cost(_Task task) => task.position >= at ? task.position - at : (at - task.position) * 2 + 1000;
    final List<_Task> ordered = List<_Task>.of(_pending)..sort((_Task a, _Task b) => cost(a).compareTo(cost(b)));
    final SrConfig first = ordered.first.config;
    final List<_Task> batch = ordered.where((_Task t) => t.config.label == first.label).take(batchSize).toList();
    _pending.removeWhere(batch.contains);
    return batch;
  }

  Future<void> _pump() async {
    if (_running) {
      return;
    }
    _running = true;
    try {
      // Pages asked for in the same turn (a screenful, a batch ahead) are
      // all waiting before the first batch is taken.
      await Future<void>.delayed(Duration.zero);
      await _cleanDiskOnce();
      while (_pending.isNotEmpty) {
        final List<_Task> batch = _takeBatch();
        Map<_Task, Uint8List> results = const <_Task, Uint8List>{};
        try {
          results = await _runBatch(batch);
        } catch (e, s) {
          log.error('Upscale batch failed', e, s);
        }
        for (final _Task task in batch) {
          final Uint8List? bytes = results[task];
          if (bytes != null) {
            _remember(task.key, bytes);
          }
          task.done.complete(bytes);
        }
      }
    } finally {
      _running = false;
    }
  }

  /// One run of the program on the pages of [batch]. Each page is written
  /// as `<its place in the batch>.png`, and the program writes its result
  /// under the same name, so results cannot be mixed up; pages left as they
  /// are take no part and get no result.
  Future<Map<_Task, Uint8List>> _runBatch(List<_Task> batch) async {
    final int maxWidth = superResolutionSetting.realtimeMaxWidth.value;
    final List<SrInput?> inputs = await Future.wait(
      batch.map((_Task task) async {
        final Uint8List? encoded = await task.loadEncoded();
        return encoded == null ? null : prepareSrInput(encoded, strips: task.strips, maxWidth: maxWidth);
      }),
    );
    if (inputs.every((SrInput? input) => input == null)) {
      return const <_Task, Uint8List>{};
    }

    await Directory(workDir).create(recursive: true);
    final Directory run = await Directory(workDir).createTemp('run-');
    try {
      final Directory inDir = await Directory(p.join(run.path, 'in')).create();
      final Directory outDir = await Directory(p.join(run.path, 'out')).create();
      String name(int i) => i.toString().padLeft(4, '0');
      for (int i = 0; i < batch.length; i++) {
        if (inputs[i] != null) {
          await File(p.join(inDir.path, '${name(i)}.png')).writeAsBytes(inputs[i]!.png);
        }
      }

      runs++;
      batchSizes.add(inputs.whereType<SrInput>().length);
      final SrConfig config = batch.first.config;
      final SrRunResult result = await SrRunner(toolsRoot).run(
        config: config,
        input: inDir.path,
        output: outDir.path,
        gpuId: superResolutionSetting.gpuId.value,
      );
      if (!result.ok) {
        log.error('Upscaler exited with ${result.exitCode}', result.stderr);
        return const <_Task, Uint8List>{};
      }

      final Map<_Task, Uint8List> results = <_Task, Uint8List>{};
      for (int i = 0; i < batch.length; i++) {
        if (inputs[i] == null) {
          continue;
        }
        final File output = File(p.join(outDir.path, '${name(i)}.jpg'));
        if (output.existsSync()) {
          results[batch[i]] = await output.readAsBytes();
        } else {
          log.error('Upscaler wrote no result for page ${batch[i].position}', result.stderr);
        }
      }
      log.trace('Upscaled ${results.length} page(s) with ${config.label} in ${result.elapsed.inMilliseconds} ms');
      return results;
    } finally {
      try {
        await run.delete(recursive: true);
      } on FileSystemException catch (e) {
        log.warning('Delete upscaler work folder failed', e);
      }
    }
  }

  /// Removes what earlier runs left on disk: work folders of batches cut
  /// short, and the page cache the first experimental build kept.
  Future<void> _cleanDiskOnce() async {
    if (_cleaned) {
      return;
    }
    _cleaned = true;
    final List<String> leftovers = <String>[
      workDir,
      if (workDirOverride == null) p.join(pathService.tempDir.path, 'sr_cache'),
    ];
    for (final String path in leftovers) {
      try {
        final Directory dir = Directory(path);
        if (dir.existsSync()) {
          await dir.delete(recursive: true);
        }
      } on FileSystemException catch (e) {
        log.warning('Delete $path failed', e);
      }
    }
  }

  /// Downloads and unpacks the program of [engine] with its models.
  /// [onProgress] gets the share downloaded, from 0 to 1. [download] saves
  /// a url to a file; the app's own downloader by default.
  Future<void> install(
    SrEngine engine, {
    void Function(double progress)? onProgress,
    Future<void> Function(String url, String path, void Function(int count, int total) onReceiveProgress)? download,
  }) async {
    await Directory(toolsRoot).create(recursive: true);
    final String zipPath = p.join(toolsRoot, '${engine.name}.zip');
    void report(int count, int total) {
      if (total > 0) {
        onProgress?.call(count / total);
      }
    }

    if (download != null) {
      await download(engine.downloadUrl, zipPath, report);
    } else {
      await ehRequest.download(
        url: engine.downloadUrl,
        path: zipPath,
        receiveTimeout: 10 * 60 * 1000,
        onReceiveProgress: report,
      );
    }
    final String target = p.join(toolsRoot, engine.name);
    await Directory(target).create(recursive: true);
    final bool unpacked = await extractZipArchive(zipPath, target);
    await File(zipPath).delete();
    if (!unpacked || !File(engine.executablePath(toolsRoot)).existsSync()) {
      throw FileSystemException('Unpacking ${engine.name} failed', target);
    }
    if (!Platform.isWindows) {
      await Process.run('chmod', <String>['+x', engine.executablePath(toolsRoot)]);
    }
    log.info('Installed upscaler ${engine.name} at $target');
  }
}
