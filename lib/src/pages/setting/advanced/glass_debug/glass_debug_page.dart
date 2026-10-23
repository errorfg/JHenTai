import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/setting/glass_debug_setting.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// Test builds: the liquid glass of the Komga page, with a preview of its
/// controls over colorful content. Changes apply at once and are kept.
class GlassDebugPage extends StatelessWidget {
  const GlassDebugPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('液态玻璃调试'),
        actions: [
          TextButton(onPressed: glassDebugSetting.reset, child: const Text('恢复默认')),
        ],
      ),
      body: Column(
        children: [
          // Fixed above the list: premium glass misdraws inside a scroll view.
          const SizedBox(height: 230, child: _Preview()),
          const Divider(height: 1),
          Expanded(
            child: Obx(
              () => ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  const _Header('顶栏按钮与底部切换栏'),
                  _quality(glassDebugSetting.barQuality),
                  ..._params(glassDebugSetting.bar, GlassParams.barDefaults),
                  const _Header('菜单'),
                  _quality(glassDebugSetting.menuQuality),
                  ..._params(glassDebugSetting.menu, GlassParams.menuDefaults),
                  const _Header('页面'),
                  ListTile(
                    title: const Text('底部切换控件'),
                    trailing: SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment<bool>(value: false, label: Text('切换栏')),
                        ButtonSegment<bool>(value: true, label: Text('分段控件')),
                      ],
                      selected: {glassDebugSetting.segmentedSwitch.value},
                      onSelectionChanged: (Set<bool> v) => _set(() => glassDebugSetting.segmentedSwitch.value = v.single),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('顶栏随下方内容切换明暗'),
                    value: glassDebugSetting.contentAwareBrightness.value,
                    onChanged: (bool v) => _set(() => glassDebugSetting.contentAwareBrightness.value = v),
                  ),
                  ListTile(
                    title: const Text('内容在栏边缘的效果'),
                    trailing: SegmentedButton<GlassScrollEdgeStyle>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: GlassScrollEdgeStyle.soft, label: Text('柔和')),
                        ButtonSegment(value: GlassScrollEdgeStyle.hard, label: Text('清晰')),
                        ButtonSegment(value: GlassScrollEdgeStyle.blur, label: Text('模糊')),
                      ],
                      selected: {glassDebugSetting.edgeStyle.value},
                      onSelectionChanged: (Set<GlassScrollEdgeStyle> v) => _set(() => glassDebugSetting.edgeStyle.value = v.single),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('性能图层'),
                    subtitle: const Text('上为 GPU 每帧耗时，下为 UI 线程'),
                    value: glassDebugSetting.performanceOverlay.value,
                    onChanged: (bool v) => _set(() => glassDebugSetting.performanceOverlay.value = v),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static void _set(VoidCallback change) {
    change();
    glassDebugSetting.save();
  }

  Widget _quality(Rx<GlassQuality> quality) {
    return ListTile(
      title: const Text('渲染档'),
      subtitle: const Text('高：折射、高光与色散；标准：轻量着色器；最低：只有模糊'),
      isThreeLine: true,
      trailing: SegmentedButton<GlassQuality>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: GlassQuality.minimal, label: Text('最低')),
          ButtonSegment(value: GlassQuality.standard, label: Text('标准')),
          ButtonSegment(value: GlassQuality.premium, label: Text('高')),
        ],
        selected: {quality.value},
        onSelectionChanged: (Set<GlassQuality> v) => _set(() => quality.value = v.single),
      ),
    );
  }

  List<Widget> _params(Rxn<GlassParams> glass, GlassParams defaults) {
    final GlassParams? p = glass.value;
    Widget slider(String label, double min, double max, double value, GlassParams Function(GlassParams p, double v) apply) => _ParamSlider(
      label: label,
      min: min,
      max: max,
      value: value.clamp(min, max),
      onChanged: (double v) => glass.value = apply(glass.value!, v),
      onChangeEnd: (_) => glassDebugSetting.save(),
    );
    return [
      SwitchListTile(
        title: const Text('自定义玻璃参数'),
        subtitle: const Text('关闭时用组件包自己的值'),
        value: p != null,
        onChanged: (bool on) => _set(() => glass.value = on ? defaults : null),
      ),
      if (p != null) ...[
        slider('厚度', 0, 60, p.thickness, (p, v) => p.copyWith(thickness: v)),
        slider('模糊', 0, 30, p.blur, (p, v) => p.copyWith(blur: v)),
        slider('玻璃颜色不透明度', 0, 1, p.tint, (p, v) => p.copyWith(tint: v)),
        SwitchListTile(
          title: const Text('玻璃颜色用黑色'),
          value: p.darkTint,
          onChanged: (bool v) => _set(() => glass.value = glass.value!.copyWith(darkTint: v)),
        ),
        slider('折射率', 0.5, 2.5, p.refractiveIndex, (p, v) => p.copyWith(refractiveIndex: v)),
        slider('色散', 0, 0.2, p.chromaticAberration, (p, v) => p.copyWith(chromaticAberration: v)),
        slider('光照强度', 0, 2, p.lightIntensity, (p, v) => p.copyWith(lightIntensity: v)),
        slider('环境光', 0, 1, p.ambientStrength, (p, v) => p.copyWith(ambientStrength: v)),
        slider('饱和度', 0, 3, p.saturation, (p, v) => p.copyWith(saturation: v)),
      ],
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
  );
}

class _ParamSlider extends StatelessWidget {
  const _ParamSlider({required this.label, required this.min, required this.max, required this.value, required this.onChanged, required this.onChangeEnd});

  final String label;
  final double min;
  final double max;
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        SizedBox(width: 112, child: Text(label)),
        Expanded(child: Slider(value: value, min: min, max: max, onChanged: onChanged, onChangeEnd: onChangeEnd)),
        SizedBox(width: 44, child: Text(value.toStringAsFixed(max <= 1 ? 2 : 1), textAlign: TextAlign.end)),
      ],
    ),
  );
}

/// The Komga page's glass controls as the settings make them, over stripes,
/// colors and text that show refraction.
class _Preview extends StatefulWidget {
  const _Preview();

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final GlassQuality barQuality = glassDebugSetting.barQuality.value;
      final LiquidGlassSettings? barGlass = glassDebugSetting.bar.value?.settings;
      return Stack(
        children: [
          const Positioned.fill(child: _Backdrop()),
          Positioned(
            top: 12,
            right: 12,
            child: komgaMenuGlass(
              GlassButtonGroup.icons(
                quality: barQuality,
                settings: barGlass,
                items: [
                  GlassButtonGroupItem(icon: const Icon(CupertinoIcons.search), onTap: () {}),
                  GlassButtonGroupItem.menu(
                    icon: const Icon(CupertinoIcons.line_horizontal_3_decrease_circle),
                    menuWidth: 240,
                    menuItems: [
                      const GlassMenuLabel(title: '排序方式'),
                      GlassMenuItem(title: '添加时间', icon: const Icon(CupertinoIcons.checkmark, size: 18), trailing: const Icon(CupertinoIcons.arrow_down, size: 16), onTap: () {}),
                      GlassMenuItem(title: '标题', icon: const SizedBox.square(dimension: 20), onTap: () {}),
                      const GlassMenuDivider(),
                      GlassMenuItem(title: '阅读状态', subtitle: '全部', icon: const Icon(CupertinoIcons.book), onTap: () {}),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: GlassButtonGroup.icons(
              quality: barQuality,
              settings: barGlass,
              items: [
                GlassButtonGroupItem(icon: const Icon(CupertinoIcons.sidebar_left), onTap: () {}),
                GlassButtonGroupItem(icon: const Icon(CupertinoIcons.back), onTap: () {}),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: Center(
              child: SizedBox(
                width: 280,
                child: komgaTargetSwitch(
                  selectedIndex: _tab,
                  labels: const ['系列', '全部书籍'],
                  onSelected: (int i) => setState(() => _tab = i),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// [actions] of the bar with the menus' glass of the debug page around them.
Widget komgaMenuGlass(Widget actions) {
  final LiquidGlassSettings? menuGlass = glassDebugSetting.menu.value?.settings;
  final GlassQuality menuQuality = glassDebugSetting.menuQuality.value;
  return GlassIsolationScope(
    isolated: true,
    defaultQuality: menuQuality,
    child: menuGlass == null ? actions : InheritedLiquidGlass(settings: menuGlass, quality: menuQuality, child: actions),
  );
}

/// The series/books switch as the debug page sets it.
Widget komgaTargetSwitch({Key? key, required int selectedIndex, required List<String> labels, required ValueChanged<int> onSelected}) {
  final GlassQuality quality = glassDebugSetting.barQuality.value;
  final LiquidGlassSettings? glass = glassDebugSetting.bar.value?.settings;
  if (glassDebugSetting.segmentedSwitch.isTrue) {
    return GlassSegmentedControl(
      key: key,
      quality: quality,
      settings: glass,
      segments: [for (final String label in labels) GlassSegment(label: label)],
      selectedIndex: selectedIndex,
      onSegmentSelected: onSelected,
    );
  }
  return GlassTabBar.inline(
    key: key,
    quality: quality,
    settings: glass,
    tabs: [for (final String label in labels) GlassTab(label: label)],
    selectedIndex: selectedIndex,
    onTabSelected: onSelected,
  );
}

class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) {
    const List<Color> colors = [Color(0xFFE53935), Color(0xFFFB8C00), Color(0xFFFDD835), Color(0xFF43A047), Color(0xFF1E88E5), Color(0xFF8E24AA)];
    return Stack(
      fit: StackFit.expand,
      children: [
        Row(children: [for (final Color c in colors) Expanded(child: ColoredBox(color: c))]),
        CustomPaint(painter: _StripesPainter()),
        const Center(
          child: Text('JHenTai 液态玻璃', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: Colors.white)),
        ),
      ],
    );
  }
}

class _StripesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = const Color(0x55000000)
      ..strokeWidth = 3;
    for (double x = -size.height; x < size.width; x += 18) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
