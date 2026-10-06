import 'dart:io';

import 'package:path/path.dart' as p;

/// The two upscaler programs (ncnn + Vulkan command line tools) and where
/// their releases are.
enum SrEngine {
  realesrgan(
    windowsUrl: 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-windows.zip',
    linuxUrl: 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-ubuntu.zip',
    macUrl: 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip',
    executable: 'realesrgan-ncnn-vulkan',
    windowsDir: '',
    linuxDir: '',
    macDir: '',
  ),
  realcugan(
    windowsUrl: 'https://github.com/nihui/realcugan-ncnn-vulkan/releases/download/20220728/realcugan-ncnn-vulkan-20220728-windows.zip',
    linuxUrl: 'https://github.com/nihui/realcugan-ncnn-vulkan/releases/download/20220728/realcugan-ncnn-vulkan-20220728-ubuntu.zip',
    macUrl: 'https://github.com/nihui/realcugan-ncnn-vulkan/releases/download/20220728/realcugan-ncnn-vulkan-20220728-macos.zip',
    executable: 'realcugan-ncnn-vulkan',
    windowsDir: 'realcugan-ncnn-vulkan-20220728-windows',
    linuxDir: 'realcugan-ncnn-vulkan-20220728-ubuntu',
    macDir: 'realcugan-ncnn-vulkan-20220728-macos',
  );

  const SrEngine({
    required this.windowsUrl,
    required this.linuxUrl,
    required this.macUrl,
    required this.executable,
    required this.windowsDir,
    required this.linuxDir,
    required this.macDir,
  });

  final String windowsUrl;
  final String linuxUrl;
  final String macUrl;

  /// Program name, without `.exe`.
  final String executable;

  /// Folder inside the release zip that holds the program and its models.
  final String windowsDir;
  final String linuxDir;
  final String macDir;

  String get downloadUrl => Platform.isWindows ? windowsUrl : (Platform.isMacOS ? macUrl : linuxUrl);

  String get _zipDir => Platform.isWindows ? windowsDir : (Platform.isMacOS ? macDir : linuxDir);

  /// Folder of the program once the release is unpacked into
  /// `[toolsRoot]/[name]`.
  String directory(String toolsRoot) => p.join(toolsRoot, name, _zipDir);

  String executablePath(String toolsRoot) =>
      p.join(directory(toolsRoot), Platform.isWindows ? '$executable.exe' : executable);

  bool isInstalled(String toolsRoot) => File(executablePath(toolsRoot)).existsSync();
}

/// A model one of the programs can run.
class SrModel {
  const SrModel({
    required this.id,
    required this.engine,
    required this.modelDir,
    this.modelName,
    required this.scales,
    this.denoiseLevels = const <int>[],
  });

  /// Stable name, kept in settings and reports.
  final String id;
  final SrEngine engine;

  /// Model folder inside the program's folder.
  final String modelDir;

  /// `-n` of realesrgan; realcugan picks its file from scale and denoise.
  final String? modelName;
  final List<int> scales;

  /// `-n` of realcugan: -1 conservative, 0 no denoise, 1-3 denoise.
  final List<int> denoiseLevels;

  static const SrModel animeVideoV3 = SrModel(
    id: 'realesr-animevideov3',
    engine: SrEngine.realesrgan,
    modelDir: 'models',
    modelName: 'realesr-animevideov3',
    scales: <int>[2, 3, 4],
  );

  static const List<SrModel> all = <SrModel>[
    animeVideoV3,
    SrModel(
      id: 'realesrgan-x4plus-anime',
      engine: SrEngine.realesrgan,
      modelDir: 'models',
      modelName: 'realesrgan-x4plus-anime',
      scales: <int>[4],
    ),
    SrModel(
      id: 'realesrgan-x4plus',
      engine: SrEngine.realesrgan,
      modelDir: 'models',
      modelName: 'realesrgan-x4plus',
      scales: <int>[4],
    ),
    SrModel(
      id: 'realcugan-se',
      engine: SrEngine.realcugan,
      modelDir: 'models-se',
      scales: <int>[2, 3, 4],
      denoiseLevels: <int>[-1, 0, 3],
    ),
    SrModel(
      id: 'realcugan-pro',
      engine: SrEngine.realcugan,
      modelDir: 'models-pro',
      scales: <int>[2, 3],
      denoiseLevels: <int>[-1, 0, 3],
    ),
    SrModel(
      id: 'realcugan-nose',
      engine: SrEngine.realcugan,
      modelDir: 'models-nose',
      scales: <int>[2],
      denoiseLevels: <int>[0],
    ),
  ];

  static SrModel byId(String id) => all.firstWhere((SrModel m) => m.id == id, orElse: () => animeVideoV3);
}

/// A model with the scale and denoise level to run it at.
class SrConfig {
  const SrConfig({required this.model, required this.scale, this.denoise = 0});

  final SrModel model;
  final int scale;
  final int denoise;

  /// Used in file names and reports, e.g. `realcugan-se-x2-n0`.
  String get label => model.engine == SrEngine.realcugan ? '${model.id}-x$scale-n$denoise' : '${model.id}-x$scale';

  /// Every scale and denoise level of every model.
  static List<SrConfig> get everything => <SrConfig>[
        for (final SrModel model in SrModel.all)
          for (final int scale in model.scales)
            if (model.denoiseLevels.isEmpty)
              SrConfig(model: model, scale: scale)
            else
              for (final int denoise in model.denoiseLevels) SrConfig(model: model, scale: scale, denoise: denoise),
      ];
}

class SrRunResult {
  const SrRunResult({required this.exitCode, required this.elapsed, required this.stderr});

  final int exitCode;
  final Duration elapsed;

  /// The programs log to stderr; it starts with the GPUs they see.
  final String stderr;

  bool get ok => exitCode == 0;

  /// GPU names as the program lists them, e.g. `NVIDIA GeForce RTX 5090`.
  List<String> get gpus => RegExp(r'^\[(\d+) ([^\]]+)\]', multiLine: true)
      .allMatches(stderr)
      .map((RegExpMatch m) => '${m.group(1)}: ${m.group(2)}')
      .toSet()
      .toList();
}

/// Runs the upscaler programs.
class SrRunner {
  const SrRunner(this.toolsRoot);

  /// Folder the releases are unpacked into, one sub-folder per engine.
  final String toolsRoot;

  /// Upscales [input] to [output]: an image file each, or a folder each
  /// (every image of the input folder, in one run of the program). The
  /// output format follows the extension of [output], [format] for folders.
  Future<SrRunResult> run({
    required SrConfig config,
    required String input,
    required String output,
    int gpuId = 0,
    String format = 'jpg',
  }) async {
    final SrEngine engine = config.model.engine;
    final String ext = FileSystemEntity.isDirectorySync(input) ? format : p.extension(output).replaceFirst('.', '').toLowerCase();
    final List<String> arguments = <String>[
      '-i',
      input,
      '-o',
      output,
      '-s',
      '${config.scale}',
      if (engine == SrEngine.realesrgan) ...<String>['-n', config.model.modelName!] else ...<String>['-n', '${config.denoise}'],
      '-f',
      ext.isEmpty ? format : ext,
      '-g',
      '$gpuId',
      '-m',
      p.join(engine.directory(toolsRoot), config.model.modelDir),
    ];

    final Stopwatch watch = Stopwatch()..start();
    // Not through a shell: paths with spaces stay one argument. The
    // program's folder is the working directory, where its libraries are.
    final ProcessResult result = await Process.run(
      engine.executablePath(toolsRoot),
      arguments,
      workingDirectory: engine.directory(toolsRoot),
    );
    watch.stop();
    return SrRunResult(exitCode: result.exitCode, elapsed: watch.elapsed, stderr: '${result.stderr}');
  }
}
