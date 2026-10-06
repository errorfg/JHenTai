import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/setting/preference_setting.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../../../service/sr/realtime_sr_service.dart';
import '../../../../service/sr/sr_tools.dart';
import '../../../../service/super_resolution_service.dart';
import '../../../../setting/super_resolution_setting.dart';
import '../../../../service/log.dart';
import '../../../../widget/loading_state_indicator.dart';
import 'sr_benchmark_dialog.dart';

class SettingSuperResolutionPage extends StatelessWidget {
  const SettingSuperResolutionPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text('superResolution'.tr),
        actions: [
          IconButton(
            icon: const Icon(Icons.help),
            onPressed: () => launchUrlString(
              preferenceSetting.locale.value.languageCode == 'zh'
                  ? 'https://github.com/jiangtian616/JHenTai/wiki/%E5%9B%BE%E7%89%87%E8%B6%85%E5%88%86%E8%BE%A8%E7%8E%87%E6%94%BE%E5%A4%A7%E4%BD%BF%E7%94%A8%E6%96%B9%E6%B3%95'
                  : preferenceSetting.locale.value.languageCode == 'ko'
                      ? 'https://github.com/jiangtian616/JHenTai/wiki/AI-%EC%B4%88%EA%B3%A0%ED%99%94%EC%A7%88-%EC%9D%B4%EB%AF%B8%EC%A7%80-%EC%82%AC%EC%9A%A9-%EB%B0%A9%EB%B2%95'
                      : 'https://github.com/jiangtian616/JHenTai/wiki/AI-Image-Super-Resolution-Usage',
            ),
          )
        ],
      ),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: [
            // Two features that share nothing but the GPU: upscaling what
            // is downloaded, a whole gallery at a time, and upscaling pages
            // while reading online. Each has its own programs and models.
            _SectionHeader(
              key: const Key('srOfflineSection'),
              title: 'srSectionOffline'.tr,
              hint: 'srSectionOfflineHint'.tr,
            ),
            _buildModelDirectoryPath(),
            _buildModelType(),
            const Divider(),
            _SectionHeader(
              key: const Key('srRealtimeSection'),
              title: 'realtimeSr'.tr,
              hint: 'srSectionRealtimeHint'.tr,
              experimental: true,
            ),
            _buildRealtime(),
            _buildRealtimeModel(),
            _buildRealtimeScale(),
            if (realtimeSrService.config.model.denoiseLevels.isNotEmpty) _buildRealtimeDenoise(),
            _buildRealtimeBatchSize(),
            _buildRealtimeMaxWidth(),
            for (final SrEngine engine in SrEngine.values) _SrToolTile(engine: engine),
            _buildBenchmark(),
            const Divider(),
            _SectionHeader(
              key: const Key('srCommonSection'),
              title: 'srSectionCommon'.tr,
              hint: 'srSectionCommonHint'.tr,
            ),
            _buildGpuId(),
          ],
        ).withListTileTheme(context),
      ),
    );
  }

  Widget _buildModelDirectoryPath() {
    return ListTile(
      title: Text('modelDirectoryPath'.tr),
      subtitle: Text(superResolutionSetting.modelDirectoryPath.value ?? ''),
      trailing: const Icon(Icons.keyboard_arrow_right),
      onTap: () async {
        String? result;
        try {
          result = await FilePicker.platform.getDirectoryPath();
        } on Exception catch (e) {
          log.error('Pick executable file path failed', e);
          log.uploadError(e);
          toast('internalError'.tr);
        }

        if (result == null) {
          return;
        }

        superResolutionSetting.saveModelDirectoryPath(result);
      },
    );
  }

  Widget _buildModelType() {
    return ListTile(
      title: Text('modelType'.tr),
      subtitle: GetBuilder<SuperResolutionService>(
        id: SuperResolutionService.downloadId,
        builder: (superResolutionService) => superResolutionService.downloadState == LoadingState.loading
            ? Text('${'downloading'.tr} ${superResolutionService.downloadProgress}')
            : superResolutionService.downloadState == LoadingState.success
                ? Text('downloaded'.tr)
                : const SizedBox(),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GetBuilder<SuperResolutionService>(
            id: SuperResolutionService.downloadId,
            builder: (superResolutionService) => superResolutionService.downloadState == LoadingState.loading
                ? IconButton(icon: const CupertinoActivityIndicator(), onPressed: () {}, enableFeedback: false)
                : IconButton(
                    icon: const Icon(Icons.download),
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      if (superResolutionService.downloadState == LoadingState.loading) {
                        return;
                      }
                      superResolutionService.downloadModelFile(superResolutionSetting.model.value);
                    },
                  ),
          ),
          const SizedBox(width: 8),
          DropdownButton<ModelType>(
            value: superResolutionSetting.model.value,
            elevation: 4,
            onChanged: (ModelType? newValue) => superResolutionSetting.saveModel(newValue!),
            items: [
              DropdownMenuItem(child: Text(ModelType.CUGAN.subType), value: ModelType.CUGAN),
              DropdownMenuItem(child: Text(ModelType.ESRGAN.subType), value: ModelType.ESRGAN),
              DropdownMenuItem(child: Text(ModelType.ESRGAN_ANIME.subType), value: ModelType.ESRGAN_ANIME),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildRealtime() {
    return SwitchListTile(
      key: const Key('realtimeSrSwitch'),
      title: Text('realtimeSrEnable'.tr),
      subtitle: Text('realtimeSrHint'.tr),
      value: superResolutionSetting.realtimeEnabled.value,
      onChanged: (bool value) {
        if (value && !realtimeSrService.available) {
          toast('realtimeSrNotInstalled'.tr, isShort: false);
          return;
        }
        superResolutionSetting.saveRealtimeEnabled(value);
      },
    );
  }

  /// Keeps the scale and denoise level when the model has them, else its
  /// first.
  void _saveRealtime({String? model, int? scale, int? denoise}) {
    final SrModel chosen = SrModel.byId(model ?? superResolutionSetting.realtimeModel.value);
    final int wantedScale = scale ?? superResolutionSetting.realtimeScale.value;
    final int wantedDenoise = denoise ?? superResolutionSetting.realtimeDenoise.value;
    superResolutionSetting.saveRealtimeConfig(
      model: chosen.id,
      scale: chosen.scales.contains(wantedScale) ? wantedScale : chosen.scales.first,
      denoise: chosen.denoiseLevels.contains(wantedDenoise)
          ? wantedDenoise
          : (chosen.denoiseLevels.isEmpty ? 0 : chosen.denoiseLevels.first),
    );
  }

  Widget _buildRealtimeModel() {
    return ListTile(
      title: Text('realtimeSrModel'.tr),
      trailing: DropdownButton<String>(
        key: const Key('realtimeSrModel'),
        value: realtimeSrService.config.model.id,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (String? id) => _saveRealtime(model: id),
        items: [for (final SrModel model in SrModel.all) DropdownMenuItem(value: model.id, child: Text(model.id))],
      ),
    );
  }

  Widget _buildRealtimeScale() {
    final SrConfig config = realtimeSrService.config;
    return ListTile(
      title: Text('realtimeSrScale'.tr),
      trailing: DropdownButton<int>(
        value: config.scale,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (int? scale) => _saveRealtime(scale: scale),
        items: [for (final int scale in config.model.scales) DropdownMenuItem(value: scale, child: Text('x$scale'))],
      ),
    );
  }

  Widget _buildRealtimeDenoise() {
    final SrConfig config = realtimeSrService.config;
    return ListTile(
      title: Text('realtimeSrDenoise'.tr),
      trailing: DropdownButton<int>(
        value: config.denoise,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (int? denoise) => _saveRealtime(denoise: denoise),
        items: [
          for (final int level in config.model.denoiseLevels) DropdownMenuItem(value: level, child: Text('$level')),
        ],
      ),
    );
  }

  Widget _buildRealtimeBatchSize() {
    const List<int> sizes = <int>[1, 2, 4, 8, 16];
    final int current = superResolutionSetting.realtimeBatchSize.value;
    return ListTile(
      title: Text('realtimeSrBatchSize'.tr),
      subtitle: Text('realtimeSrBatchSizeHint'.tr),
      trailing: DropdownButton<int>(
        value: sizes.contains(current) ? current : 4,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (int? size) => superResolutionSetting.saveRealtimeBatchSize(size!),
        items: [for (final int size in sizes) DropdownMenuItem(value: size, child: Text('$size'))],
      ),
    );
  }

  Widget _buildRealtimeMaxWidth() {
    const List<int> widths = <int>[0, 1000, 1200, 1600, 2000, 2560];
    final int current = superResolutionSetting.realtimeMaxWidth.value;
    return ListTile(
      title: Text('realtimeSrMaxWidth'.tr),
      trailing: DropdownButton<int>(
        value: widths.contains(current) ? current : 1600,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (int? width) => superResolutionSetting.saveRealtimeMaxWidth(width!),
        items: [
          for (final int width in widths)
            DropdownMenuItem(value: width, child: Text(width == 0 ? 'noLimit'.tr : '$width px')),
        ],
      ),
    );
  }

  Widget _buildBenchmark() {
    return ListTile(
      key: const Key('srBenchmark'),
      title: Text('srBenchmark'.tr),
      subtitle: Text('srBenchmarkHint'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right),
      onTap: () => Get.dialog(const SrBenchmarkDialog(), barrierDismissible: false),
    );
  }

  Widget _buildGpuId() {
    return ListTile(
      title: const Text('GPU-id'),
      trailing: DropdownButton<int>(
        value: superResolutionSetting.gpuId.value,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (int? newValue) => superResolutionSetting.saveGpuId(newValue!),
        items: const [
          DropdownMenuItem(child: Text('-1'), value: -1),
          DropdownMenuItem(child: Text('0'), value: 0),
          DropdownMenuItem(child: Text('1'), value: 1),
          DropdownMenuItem(child: Text('2'), value: 2),
          DropdownMenuItem(child: Text('3'), value: 3),
          DropdownMenuItem(child: Text('4'), value: 4),
          DropdownMenuItem(child: Text('5'), value: 5),
          DropdownMenuItem(child: Text('6'), value: 6),
          DropdownMenuItem(child: Text('7'), value: 7),
        ],
      ),
    );
  }
}

/// One upscaler program: whether it is installed, and a button that
/// downloads and unpacks it.
class _SrToolTile extends StatefulWidget {
  const _SrToolTile({required this.engine});

  final SrEngine engine;

  @override
  State<_SrToolTile> createState() => _SrToolTileState();
}

class _SrToolTileState extends State<_SrToolTile> {
  double? _progress;

  Future<void> _install() async {
    setState(() => _progress = 0);
    try {
      await realtimeSrService.install(
        widget.engine,
        onProgress: (double progress) {
          if (mounted) {
            setState(() => _progress = progress);
          }
        },
      );
      toast('success'.tr);
    } catch (e, s) {
      log.error('Install upscaler ${widget.engine.name} failed', e, s);
      toast('${'failed'.tr}: $e', isShort: false);
    } finally {
      if (mounted) {
        setState(() => _progress = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool installed = widget.engine.isInstalled(realtimeSrService.toolsRoot);
    return ListTile(
      title: Text('${'srTools'.tr}: ${widget.engine.name}'),
      subtitle: Text(
        _progress != null
            ? '${'downloading'.tr} ${(_progress! * 100).toStringAsFixed(0)}%'
            : (installed ? 'srToolInstalled'.tr : 'srToolNotInstalled'.tr),
      ),
      trailing: _progress != null
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : IconButton(icon: Icon(installed ? Icons.refresh : Icons.download), onPressed: _install),
    );
  }
}

/// Title of a group of settings, with what the group is for; [experimental]
/// adds a badge saying so.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({super.key, required this.title, required this.hint, this.experimental = false});

  final String title;
  final String hint;
  final bool experimental;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
                ),
              ),
              if (experimental)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.tertiary),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'experimental'.tr,
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.tertiary),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(hint, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
