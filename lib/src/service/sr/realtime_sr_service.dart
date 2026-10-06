import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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
  _Task({required this.output, required this.position, required this.strips, required this.loadEncoded});

  final String output;
  final int position;
  final int strips;
  final Future<Uint8List?> Function() loadEncoded;
  final Completer<String?> done = Completer<String?>();
}

/// Upscales pages as they are read (desktop): each page goes through one of
/// the upscaler programs once, the result is kept on disk and shown in place
/// of the original. Pages wait in a queue, the ones just ahead of where the
/// reader is first; one runs at a time, as they share the GPU.
class RealtimeSrService {
  /// Upscaled pages kept on disk; the oldest go first.
  static const int cacheLimitBytes = 2 * 1024 * 1024 * 1024;

  /// Set by tests; the app keeps the programs with its own data and the
  /// upscaled pages with its temporary files.
  String? toolsRootOverride;
  String? cacheDirOverride;

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

  String get cacheDir => cacheDirOverride ?? p.join(pathService.tempDir.path, 'sr_cache');

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

  /// Whether the program of the chosen model is there to run.
  bool get available => GetPlatform.isDesktop && config.model.engine.isInstalled(toolsRoot);

  bool get active => superResolutionSetting.realtimeEnabled.value && available;

  /// The page the reader is at, for ordering the queue.
  int Function()? focus;

  final List<_Task> _pending = <_Task>[];
  final Map<String, Future<String?>> _requests = <String, Future<String?>>{};
  bool _running = false;

  /// Runs of an upscaler program so far; tests tell cached pages by it.
  int runs = 0;

  String outputPathOf(String sourceKey) {
    final String name = md5.convert(utf8.encode('${config.label}|$sourceKey')).toString();
    return p.join(cacheDir, '$name.jpg');
  }

  /// The upscaled copy of the page [sourceKey], when it is on disk already.
  String? cached(String sourceKey) {
    final String output = outputPathOf(sourceKey);
    return File(output).existsSync() ? output : null;
  }

  /// Upscales the page [sourceKey] (its url or file path), whose encoded
  /// bytes [loadEncoded] gives. Completes with the path of the upscaled
  /// image; with null when the page is left as it is (animated, wide
  /// enough already), cannot be read, the program fails, or the queue was
  /// cleared first. [position] is the page's place in the reader.
  Future<String?> upscale({
    required String sourceKey,
    required int position,
    required Future<Uint8List?> Function() loadEncoded,
    int strips = 0,
  }) {
    final String output = outputPathOf(sourceKey);
    if (File(output).existsSync()) {
      return Future<String?>.value(output);
    }
    final Future<String?>? known = _requests[output];
    if (known != null) {
      return known;
    }
    final _Task task = _Task(output: output, position: position, strips: strips, loadEncoded: loadEncoded);
    _pending.add(task);
    // A block body: returning the removed future (this very request) from
    // whenComplete would make it wait for itself.
    final Future<String?> request = task.done.future.whenComplete(() {
      _requests.remove(output);
    });
    _requests[output] = request;
    unawaited(_pump());
    return request;
  }

  /// Drops the pages still waiting; the one in the program finishes.
  void clearPending() {
    for (final _Task task in _pending) {
      task.done.complete(null);
    }
    _pending.clear();
  }

  /// The waiting page nearest ahead of the reader, pages behind it last.
  _Task _next() {
    final int at = focus?.call() ?? 0;
    int cost(_Task task) => task.position >= at ? task.position - at : (at - task.position) * 2 + 1000;
    _Task best = _pending.first;
    for (final _Task task in _pending.skip(1)) {
      if (cost(task) < cost(best)) {
        best = task;
      }
    }
    _pending.remove(best);
    return best;
  }

  Future<void> _pump() async {
    if (_running) {
      return;
    }
    _running = true;
    try {
      while (_pending.isNotEmpty) {
        final _Task task = _next();
        String? result;
        try {
          result = await _run(task);
        } catch (e, s) {
          log.error('Upscale page failed', e, s);
        }
        task.done.complete(result);
      }
    } finally {
      _running = false;
    }
  }

  Future<String?> _run(_Task task) async {
    final Uint8List? encoded = await task.loadEncoded();
    if (encoded == null) {
      return null;
    }
    final SrInput? input = await prepareSrInput(
      encoded,
      strips: task.strips,
      maxWidth: superResolutionSetting.realtimeMaxWidth.value,
    );
    if (input == null) {
      return null;
    }

    await Directory(cacheDir).create(recursive: true);
    final String inputPath = '${p.withoutExtension(task.output)}.in.png';
    // Written under another name first: a file at the output path is a
    // finished page.
    final String partial = '${p.withoutExtension(task.output)}.part.jpg';
    await File(inputPath).writeAsBytes(input.png);
    try {
      runs++;
      final SrRunResult result = await SrRunner(toolsRoot).run(
        config: config,
        input: inputPath,
        output: partial,
        gpuId: superResolutionSetting.gpuId.value,
      );
      if (!result.ok || !File(partial).existsSync()) {
        log.error('Upscaler exited with ${result.exitCode}', result.stderr);
        return null;
      }
      await File(partial).rename(task.output);
      log.trace('Upscaled ${input.width}x${input.height} with ${config.label} in ${result.elapsed.inMilliseconds} ms');
      return task.output;
    } finally {
      for (final String leftover in <String>[inputPath, partial]) {
        final File file = File(leftover);
        if (file.existsSync()) {
          await file.delete();
        }
      }
    }
  }

  /// Deletes the oldest upscaled pages beyond [cacheLimitBytes].
  Future<void> pruneCache({int limitBytes = cacheLimitBytes}) async {
    final Directory dir = Directory(cacheDir);
    if (!dir.existsSync()) {
      return;
    }
    final List<File> files = dir.listSync().whereType<File>().toList()
      ..sort((File a, File b) => b.statSync().modified.compareTo(a.statSync().modified));
    int total = 0;
    for (final File file in files) {
      total += file.statSync().size;
      if (total > limitBytes) {
        try {
          file.deleteSync();
        } on FileSystemException catch (e) {
          log.warning('Delete upscaled page failed', e);
        }
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
