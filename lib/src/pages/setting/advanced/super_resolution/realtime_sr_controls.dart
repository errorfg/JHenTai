import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/service/sr/realtime_sr_service.dart';
import 'package:jhentai/src/service/sr/sr_tools.dart';
import 'package:jhentai/src/setting/super_resolution_setting.dart';
import 'package:jhentai/src/utils/toast_util.dart';

/// Title of a group of settings, with what the group is for; [experimental]
/// adds a badge saying so.
class SrSectionHeader extends StatelessWidget {
  const SrSectionHeader({super.key, required this.title, required this.hint, this.experimental = false});

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

/// What decides how a page is upscaled while it is read: the switch, the
/// model with its scale and denoise level, and the width from which pages
/// are left alone.
///
/// Shown in the upscaling settings and in the reader's settings; an open
/// reader follows a change at once (see `ReadPageLogic`), so the effect of a
/// model shows on the page being read. To be built inside an [Obx].
List<Widget> realtimeSrTiles(BuildContext context) {
  final SrConfig config = realtimeSrService.config;
  return <Widget>[
    _buildSwitch(),
    _buildModel(context, config),
    _buildScale(config),
    if (config.model.denoiseLevels.isNotEmpty) _buildDenoise(config),
    _buildMaxWidth(),
  ];
}

Widget _buildSwitch() {
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
void _save({String? model, int? scale, int? denoise}) {
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

Widget _buildModel(BuildContext context, SrConfig config) {
  return ListTile(
    title: Text('realtimeSrModel'.tr),
    // Nothing is upscaled with a model whose program is missing.
    subtitle: realtimeSrService.available
        ? null
        : Text('realtimeSrNotInstalled'.tr, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    trailing: DropdownButton<String>(
      key: const Key('realtimeSrModel'),
      value: config.model.id,
      elevation: 4,
      alignment: AlignmentDirectional.centerEnd,
      onChanged: (String? id) => _save(model: id),
      items: [for (final SrModel model in SrModel.all) DropdownMenuItem(value: model.id, child: Text(model.id))],
    ),
  );
}

Widget _buildScale(SrConfig config) {
  return ListTile(
    title: Text('realtimeSrScale'.tr),
    trailing: DropdownButton<int>(
      key: const Key('realtimeSrScale'),
      value: config.scale,
      elevation: 4,
      alignment: AlignmentDirectional.centerEnd,
      onChanged: (int? scale) => _save(scale: scale),
      items: [for (final int scale in config.model.scales) DropdownMenuItem(value: scale, child: Text('x$scale'))],
    ),
  );
}

Widget _buildDenoise(SrConfig config) {
  return ListTile(
    title: Text('realtimeSrDenoise'.tr),
    trailing: DropdownButton<int>(
      key: const Key('realtimeSrDenoise'),
      value: config.denoise,
      elevation: 4,
      alignment: AlignmentDirectional.centerEnd,
      onChanged: (int? denoise) => _save(denoise: denoise),
      items: [
        for (final int level in config.model.denoiseLevels) DropdownMenuItem(value: level, child: Text('$level')),
      ],
    ),
  );
}

Widget _buildMaxWidth() {
  const List<int> widths = <int>[0, 1000, 1200, 1600, 2000, 2560];
  final int current = superResolutionSetting.realtimeMaxWidth.value;
  return ListTile(
    title: Text('realtimeSrMaxWidth'.tr),
    trailing: DropdownButton<int>(
      key: const Key('realtimeSrMaxWidth'),
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
