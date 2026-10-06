import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/log.dart';

import '../service/jh_service.dart';

SuperResolutionSetting superResolutionSetting = SuperResolutionSetting();

class SuperResolutionSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  RxnString modelDirectoryPath = RxnString(null);
  Rx<ModelType> model = Rx<ModelType>(ModelType.CUGAN);
  RxInt gpuId = 0.obs;

  /// Upscaling pages while reading online (desktop): on or off, the model
  /// (an [SrModel] id) with its scale and denoise level, and the width from
  /// which pages are left as they are (0: every page is upscaled).
  RxBool realtimeEnabled = false.obs;
  RxString realtimeModel = 'realesr-animevideov3'.obs;
  RxInt realtimeScale = 2.obs;
  RxInt realtimeDenoise = 0.obs;
  RxInt realtimeMaxWidth = 1600.obs;

  @override
  ConfigEnum get configEnum => ConfigEnum.superResolutionSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    modelDirectoryPath.value = map['modelDirectoryPath'];
    model.value = map['model'] == null ? ModelType.CUGAN : ModelType.values[map['model']];
    gpuId.value = map['gpuId'] ?? gpuId.value;
    realtimeEnabled.value = map['realtimeEnabled'] ?? realtimeEnabled.value;
    realtimeModel.value = map['realtimeModel'] ?? realtimeModel.value;
    realtimeScale.value = map['realtimeScale'] ?? realtimeScale.value;
    realtimeDenoise.value = map['realtimeDenoise'] ?? realtimeDenoise.value;
    realtimeMaxWidth.value = map['realtimeMaxWidth'] ?? realtimeMaxWidth.value;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'modelDirectoryPath': modelDirectoryPath.value,
      'model': model.value.index,
      'gpuId': gpuId.value,
      'realtimeEnabled': realtimeEnabled.value,
      'realtimeModel': realtimeModel.value,
      'realtimeScale': realtimeScale.value,
      'realtimeDenoise': realtimeDenoise.value,
      'realtimeMaxWidth': realtimeMaxWidth.value,
    });
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> saveModelDirectoryPath(String? modelDirectoryPath) async {
    log.debug('saveModelDirectoryPath:$modelDirectoryPath');
    this.modelDirectoryPath.value = modelDirectoryPath;
    await saveBeanConfig();
  }

  Future<void> saveModel(ModelType model) async {
    log.debug('saveModel:$model');
    this.model.value = model;
    await saveBeanConfig();
  }

  Future<void> saveGpuId(int gpuId) async {
    log.debug('saveGpuId:$gpuId');
    this.gpuId.value = gpuId;
    await saveBeanConfig();
  }

  Future<void> saveRealtimeEnabled(bool enabled) async {
    log.debug('saveRealtimeEnabled:$enabled');
    realtimeEnabled.value = enabled;
    await saveBeanConfig();
  }

  /// [model] is an [SrModel] id; a scale or denoise level the model lacks
  /// falls back to its first.
  Future<void> saveRealtimeConfig({required String model, required int scale, required int denoise}) async {
    log.debug('saveRealtimeConfig:$model x$scale n$denoise');
    realtimeModel.value = model;
    realtimeScale.value = scale;
    realtimeDenoise.value = denoise;
    await saveBeanConfig();
  }

  Future<void> saveRealtimeMaxWidth(int width) async {
    log.debug('saveRealtimeMaxWidth:$width');
    realtimeMaxWidth.value = width;
    await saveBeanConfig();
  }
}

enum ModelType {
  ESRGAN(
    'realesrgan',
    'realesrgan-x4plus',
    'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-windows.zip',
    'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-ubuntu.zip',
    'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip',
    'realesrgan-ncnn-vulkan.exe',
    'realesrgan-ncnn-vulkan',
    'realesrgan-ncnn-vulkan',
    '',
    '',
    '',
    'models',
  ),
  ESRGAN_ANIME(
    'realesrgan',
    'realesrgan-x4plus-anime',
    'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-windows.zip',
    'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-ubuntu.zip',
    'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip',
    'realesrgan-ncnn-vulkan.exe',
    'realesrgan-ncnn-vulkan',
    'realesrgan-ncnn-vulkan',
    '',
    '',
    '',
    'models',
  ),
  CUGAN(
    'realcugan',
    'realcugan',
    'https://github.com/nihui/realcugan-ncnn-vulkan/releases/download/20220728/realcugan-ncnn-vulkan-20220728-windows.zip',
    'https://github.com/nihui/realcugan-ncnn-vulkan/releases/download/20220728/realcugan-ncnn-vulkan-20220728-ubuntu.zip',
    'https://github.com/nihui/realcugan-ncnn-vulkan/releases/download/20220728/realcugan-ncnn-vulkan-20220728-macos.zip',
    'realcugan-ncnn-vulkan.exe',
    'realcugan-ncnn-vulkan',
    'realcugan-ncnn-vulkan',
    'realcugan-ncnn-vulkan-20220728-windows',
    'realcugan-ncnn-vulkan-20220728-macos',
    'realcugan-ncnn-vulkan-20220728-ubuntu',
    'models-se',
  );

  const ModelType(
    this.type,
    this.subType,
    this.windowsDownloadUrl,
    this.linuxDownloadUrl,
    this.macDownloadUrl,
    this.windowsExecutableName,
    this.macOSExecutableName,
    this.linuxExecutableName,
    this.windowsModelExtractPath,
    this.macOSModelExtractPath,
    this.linuxModelExtractPath,
    this.modelRelativePath,
  );

  final String type;

  final String subType;

  final String windowsDownloadUrl;

  final String linuxDownloadUrl;

  final String macDownloadUrl;

  final String windowsExecutableName;

  final String macOSExecutableName;

  final String linuxExecutableName;

  final String windowsModelExtractPath;

  final String macOSModelExtractPath;

  final String linuxModelExtractPath;

  final String modelRelativePath;
}
