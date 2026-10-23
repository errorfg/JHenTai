import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

GlassDebugSetting glassDebugSetting = GlassDebugSetting();

/// The glass of one kind of surface, as the debug page sets it.
class GlassParams {
  const GlassParams({
    required this.thickness,
    required this.blur,
    required this.tint,
    required this.darkTint,
    required this.refractiveIndex,
    required this.chromaticAberration,
    required this.lightIntensity,
    required this.ambientStrength,
    required this.saturation,
  });

  final double thickness;
  final double blur;

  /// Opacity of the glass color, white or, with [darkTint], black.
  final double tint;
  final bool darkTint;
  final double refractiveIndex;
  final double chromaticAberration;
  final double lightIntensity;
  final double ambientStrength;
  final double saturation;

  /// The package's own values: LiquidGlassSettings() for the bars, the
  /// default of GlassMenu for menus.
  static const GlassParams barDefaults = GlassParams(
    thickness: 20,
    blur: 5,
    tint: 0,
    darkTint: false,
    refractiveIndex: 1.2,
    chromaticAberration: 0.01,
    lightIntensity: 0.5,
    ambientStrength: 0,
    saturation: 1.5,
  );
  static const GlassParams menuDefaults = GlassParams(
    thickness: 10,
    blur: 10,
    tint: 0.12,
    darkTint: false,
    refractiveIndex: 0.7,
    chromaticAberration: 0,
    lightIntensity: 0.7,
    ambientStrength: 0.4,
    saturation: 1.2,
  );

  LiquidGlassSettings get settings => LiquidGlassSettings(
    thickness: thickness,
    blur: blur,
    glassColor: (darkTint ? const Color(0xFF000000) : const Color(0xFFFFFFFF)).withValues(alpha: tint),
    refractiveIndex: refractiveIndex,
    chromaticAberration: chromaticAberration,
    lightIntensity: lightIntensity,
    ambientStrength: ambientStrength,
    saturation: saturation,
  );

  GlassParams copyWith({
    double? thickness,
    double? blur,
    double? tint,
    bool? darkTint,
    double? refractiveIndex,
    double? chromaticAberration,
    double? lightIntensity,
    double? ambientStrength,
    double? saturation,
  }) =>
      GlassParams(
        thickness: thickness ?? this.thickness,
        blur: blur ?? this.blur,
        tint: tint ?? this.tint,
        darkTint: darkTint ?? this.darkTint,
        refractiveIndex: refractiveIndex ?? this.refractiveIndex,
        chromaticAberration: chromaticAberration ?? this.chromaticAberration,
        lightIntensity: lightIntensity ?? this.lightIntensity,
        ambientStrength: ambientStrength ?? this.ambientStrength,
        saturation: saturation ?? this.saturation,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'thickness': thickness,
    'blur': blur,
    'tint': tint,
    'darkTint': darkTint,
    'refractiveIndex': refractiveIndex,
    'chromaticAberration': chromaticAberration,
    'lightIntensity': lightIntensity,
    'ambientStrength': ambientStrength,
    'saturation': saturation,
  };

  static GlassParams? fromJson(Object? json, GlassParams defaults) {
    if (json is! Map) {
      return null;
    }
    double read(String key, double fallback) => (json[key] as num?)?.toDouble() ?? fallback;
    return GlassParams(
      thickness: read('thickness', defaults.thickness),
      blur: read('blur', defaults.blur),
      tint: read('tint', defaults.tint),
      darkTint: json['darkTint'] == true,
      refractiveIndex: read('refractiveIndex', defaults.refractiveIndex),
      chromaticAberration: read('chromaticAberration', defaults.chromaticAberration),
      lightIntensity: read('lightIntensity', defaults.lightIntensity),
      ambientStrength: read('ambientStrength', defaults.ambientStrength),
      saturation: read('saturation', defaults.saturation),
    );
  }
}

/// Liquid glass of the Komga page, set on the debug page of test builds to
/// find the values the release keeps. Null glass keeps the package's own.
class GlassDebugSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  final Rx<GlassQuality> barQuality = GlassQuality.premium.obs;
  final Rx<GlassQuality> menuQuality = GlassQuality.premium.obs;
  final Rxn<GlassParams> bar = Rxn<GlassParams>();
  final Rxn<GlassParams> menu = Rxn<GlassParams>();

  /// The series/books switch as a segmented control instead of a tab bar.
  final RxBool segmentedSwitch = false.obs;
  final RxBool contentAwareBrightness = true.obs;
  final Rx<GlassScrollEdgeStyle> edgeStyle = GlassScrollEdgeStyle.soft.obs;
  final RxBool performanceOverlay = false.obs;

  @override
  ConfigEnum get configEnum => ConfigEnum.glassDebugSetting;

  @override
  void applyBeanConfig(String configString) {
    final Map<String, dynamic> map = (jsonDecode(configString) as Map).cast<String, dynamic>();
    GlassQuality quality(Object? name) => GlassQuality.values.firstWhereOrNull((GlassQuality q) => q.name == name) ?? GlassQuality.premium;
    barQuality.value = quality(map['barQuality']);
    menuQuality.value = quality(map['menuQuality']);
    bar.value = GlassParams.fromJson(map['bar'], GlassParams.barDefaults);
    menu.value = GlassParams.fromJson(map['menu'], GlassParams.menuDefaults);
    segmentedSwitch.value = map['segmentedSwitch'] == true;
    contentAwareBrightness.value = map['contentAwareBrightness'] != false;
    edgeStyle.value = GlassScrollEdgeStyle.values.firstWhereOrNull((GlassScrollEdgeStyle s) => s.name == map['edgeStyle']) ?? GlassScrollEdgeStyle.soft;
    performanceOverlay.value = map['performanceOverlay'] == true;
  }

  @override
  String toConfigString() => jsonEncode(<String, dynamic>{
    'barQuality': barQuality.value.name,
    'menuQuality': menuQuality.value.name,
    'bar': bar.value?.toJson(),
    'menu': menu.value?.toJson(),
    'segmentedSwitch': segmentedSwitch.value,
    'contentAwareBrightness': contentAwareBrightness.value,
    'edgeStyle': edgeStyle.value.name,
    'performanceOverlay': performanceOverlay.value,
  });

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> save() => saveBeanConfig();

  Future<void> reset() {
    barQuality.value = GlassQuality.premium;
    menuQuality.value = GlassQuality.premium;
    bar.value = null;
    menu.value = null;
    segmentedSwitch.value = false;
    contentAwareBrightness.value = true;
    edgeStyle.value = GlassScrollEdgeStyle.soft;
    performanceOverlay.value = false;
    return saveBeanConfig();
  }
}
