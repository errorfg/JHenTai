import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jhentai/src/service/sr/sr_tools.dart';
import 'package:path/path.dart' as p;

/// A page the benchmark upscales: PNG, as the reader would hand it to an
/// upscaler (see `prepareSrInput`).
class SrBenchmarkPage {
  const SrBenchmarkPage({
    required this.name,
    required this.png,
    required this.width,
    required this.height,
    this.prepareMs,
  });

  final String name;
  final Uint8List png;
  final int width;
  final int height;

  /// Time to decode the page as downloaded, restore it and encode the PNG.
  final int? prepareMs;
}

/// Times every upscaler model on a set of pages and writes a report.
///
/// Each configuration (model, scale, denoise level) is run the way the
/// reader runs it, one page per run of the program, and once more with all
/// pages in one run. The upscaled pages of that last run are kept next to
/// the report, to compare the models by eye.
class SrBenchmark {
  SrBenchmark({required this.toolsRoot, required this.directory, this.gpuId = 0, this.onLog});

  final String toolsRoot;

  /// Folder of this benchmark: `in/`, `out/<configuration>/`, `report.json`
  /// and `report.md`.
  final String directory;
  final int gpuId;
  final void Function(String line)? onLog;

  void _log(String line) => onLog?.call(line);

  /// Runs [configs] (every one by default) on [pages] and returns the
  /// report file, `report.json`. [info] is added to the report as it is.
  Future<File> run({
    required List<SrBenchmarkPage> pages,
    List<SrConfig>? configs,
    Map<String, Object?> info = const <String, Object?>{},
  }) async {
    final SrRunner runner = SrRunner(toolsRoot);
    final String inputDir = p.join(directory, 'in');
    await Directory(inputDir).create(recursive: true);
    for (final SrBenchmarkPage page in pages) {
      await File(p.join(inputDir, '${page.name}.png')).writeAsBytes(page.png);
    }

    final Set<String> gpus = <String>{};
    final List<Map<String, Object?>> results = <Map<String, Object?>>[];
    final List<SrConfig> all = configs ?? SrConfig.everything;
    for (int i = 0; i < all.length; i++) {
      final SrConfig config = all[i];
      _log('[${i + 1}/${all.length}] ${config.label}');
      final Map<String, Object?> result = <String, Object?>{
        'config': config.label,
        'model': config.model.id,
        'engine': config.model.engine.name,
        'scale': config.scale,
        'denoise': config.denoise,
      };
      results.add(result);
      if (!config.model.engine.isInstalled(toolsRoot)) {
        result['error'] = '${config.model.engine.name} is not installed';
        continue;
      }

      try {
        // One page per run, as while reading.
        final String singleDir = p.join(directory, 'tmp-single');
        await Directory(singleDir).create(recursive: true);
        final List<int> perPage = <int>[];
        for (final SrBenchmarkPage page in pages) {
          final String output = p.join(singleDir, '${page.name}.jpg');
          final SrRunResult run = await runner.run(
            config: config,
            input: p.join(inputDir, '${page.name}.png'),
            output: output,
            gpuId: gpuId,
          );
          if (gpus.isEmpty && run.gpus.isNotEmpty) {
            // Which device the numbers are for: the id is set in the settings.
            _log('    GPUs: ${run.gpus.join('; ')} - using $gpuId');
          }
          gpus.addAll(run.gpus);
          if (!run.ok || !File(output).existsSync()) {
            throw SrBenchmarkFailure(run);
          }
          perPage.add(run.elapsed.inMilliseconds);
        }
        await Directory(singleDir).delete(recursive: true);
        // The first run of a model also compiles its GPU programs.
        result['firstRunMs'] = perPage.first;
        result['perPageMs'] = perPage;
        final List<int> later = perPage.length > 1 ? perPage.sublist(1) : perPage;
        result['perPageAvgMs'] = (later.reduce((int a, int b) => a + b) / later.length).round();
        result['perPageMinMs'] = later.reduce((int a, int b) => a < b ? a : b);
        result['perPageMaxMs'] = later.reduce((int a, int b) => a > b ? a : b);

        // All pages in one run: what the model costs without starting the
        // program for each page.
        final String outputDir = p.join(directory, 'out', config.label);
        await Directory(outputDir).create(recursive: true);
        final SrRunResult batch = await runner.run(config: config, input: inputDir, output: outputDir, gpuId: gpuId);
        if (!batch.ok) {
          throw SrBenchmarkFailure(batch);
        }
        final List<File> outputs = Directory(outputDir).listSync().whereType<File>().toList();
        if (outputs.length != pages.length) {
          throw StateError('${outputs.length} of ${pages.length} pages written');
        }
        result['batchMs'] = batch.elapsed.inMilliseconds;
        result['batchPerPageMs'] = (batch.elapsed.inMilliseconds / pages.length).round();
        result['outputBytesAvg'] =
            (outputs.map((File f) => f.lengthSync()).reduce((int a, int b) => a + b) / outputs.length).round();
        _log('    ${result['perPageAvgMs']} ms/page, ${result['batchPerPageMs']} ms/page in one run');
      } catch (e) {
        result['error'] = '$e';
        _log('    failed: $e');
      }
    }

    final Map<String, Object?> report = <String, Object?>{
      'format': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'cpuCount': Platform.numberOfProcessors,
      'gpus': gpus.toList(),
      'gpuId': gpuId,
      ...info,
      'pages': <Map<String, Object?>>[
        for (final SrBenchmarkPage page in pages)
          <String, Object?>{
            'name': page.name,
            'width': page.width,
            'height': page.height,
            'pngBytes': page.png.length,
            if (page.prepareMs != null) 'prepareMs': page.prepareMs,
          },
      ],
      'results': results,
    };
    final File json = File(p.join(directory, 'report.json'));
    await json.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    await File(p.join(directory, 'report.md')).writeAsString(markdown(report));
    _log('report: ${json.path}');
    return json;
  }

  /// The report as a table, for reading.
  static String markdown(Map<String, Object?> report) {
    final List<dynamic> pages = report['pages'] as List<dynamic>;
    final StringBuffer out = StringBuffer()
      ..writeln('# Upscaler benchmark')
      ..writeln()
      ..writeln('- ${report['createdAt']}')
      ..writeln('- ${report['os']} ${report['osVersion']}, ${report['cpuCount']} CPU threads')
      ..writeln('- GPUs: ${(report['gpus'] as List<dynamic>).join('; ')} (used: ${report['gpuId']})')
      ..writeln('- pages: ${pages.length}, ${pages.map((dynamic p) => '${p['width']}x${p['height']}').toSet().join(', ')}');
    for (final String key in <String>['app', 'source']) {
      if (report[key] != null) {
        out.writeln('- $key: ${report[key]}');
      }
    }
    out
      ..writeln()
      ..writeln('Milliseconds. "per page": one run of the program per page, as while reading, the first run left out; '
          '"first": that first run; "one run": all pages in one run, per page.')
      ..writeln()
      ..writeln('| configuration | per page avg | min | max | first | one run | output KB |')
      ..writeln('|---|---|---|---|---|---|---|');
    for (final dynamic r in report['results'] as List<dynamic>) {
      if (r['error'] != null) {
        out.writeln('| ${r['config']} | failed: ${'${r['error']}'.split('\n').first} | | | | | |');
      } else {
        out.writeln(
          '| ${r['config']} | ${r['perPageAvgMs']} | ${r['perPageMinMs']} | ${r['perPageMaxMs']} | ${r['firstRunMs']} '
          '| ${r['batchPerPageMs']} | ${((r['outputBytesAvg'] as int) / 1024).round()} |',
        );
      }
    }
    return out.toString();
  }
}

class SrBenchmarkFailure implements Exception {
  const SrBenchmarkFailure(this.run);

  final SrRunResult run;

  @override
  String toString() {
    final List<String> lines = run.stderr.trim().split('\n').where((String l) => !RegExp(r'^\s*[\d.]+%\s*$').hasMatch(l)).toList();
    return 'exit ${run.exitCode}: ${lines.isEmpty ? '' : lines.last.trim()}';
  }
}
