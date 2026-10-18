import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/l18n/locale_text.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/pages/details/details_page.dart';
import 'package:jhentai/src/pages/setting/style/theme_color/preview_page/detail_preview_page.dart';
import 'package:jhentai/src/service/log.dart';

class _SilentLogService extends LogService {
  @override
  void trace(Object msg, [bool withStack = false]) {}
  @override
  void debug(Object msg, [bool withStack = false]) {}
  @override
  void info(Object msg, [bool withStack = false]) {}
  @override
  void warning(Object msg, [Object? error, bool withStack = false]) {}
  @override
  void error(Object msg, [Object? error, StackTrace? stackTrace]) {}
}

/// The details page's tags, with the preview page's gallery.
class _Tags extends DetailsPage {
  _Tags() : super.preview() {
    logic = DetailsPreviewPageLogic();
    state = logic.state;
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: CustomScrollView(slivers: [buildTags()]));
}

void main() {
  testWidgets('selected tags are copied as searched for, beside the search, on a narrow phone', (WidgetTester tester) async {
    log = _SilentLogService();
    Get.testMode = true;
    addTearDown(Get.reset);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });

    final _Tags page = _Tags();
    // A keyword tag, without a namespace.
    page.state.galleryDetails!.tags['misc'] = <GalleryTag>[GalleryTag(tagData: TagData(namespace: '', key: 'keyword'))];
    await tester.pumpWidget(GetMaterialApp(translations: LocaleText(), locale: const Locale('zh', 'CN'), home: page));
    await tester.pump();

    expect(find.byKey(const Key('copySelectedTags')), findsNothing);
    await tester.tap(find.text('多选标签'));
    await tester.pump();
    expect(find.byKey(const Key('copySelectedTags')), findsNothing, reason: 'nothing selected yet');

    await tester.tap(find.text('chinese'));
    await tester.tap(find.text('JTMonster'));
    await tester.tap(find.text('keyword'));
    await tester.pump();
    expect(find.text('搜索所选标签 (3)'), findsOneWidget);
    expect(find.byTooltip('复制所选标签'), findsOneWidget);

    await tester.tap(find.byKey(const Key('copySelectedTags')));
    await tester.pump();
    expect(copied, 'language:"chinese" artist:"JTMonster" "keyword"');
    // Still selected, to search them too.
    expect(find.text('搜索所选标签 (3)'), findsOneWidget);
    expect(find.text('取消多选'), findsOneWidget);
  });
}
