import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/reader_source.dart';
import 'package:jhentai/src/routes/routes.dart';

class ReaderSourceSwitcher extends StatelessWidget {
  const ReaderSourceSwitcher({
    super.key,
    required this.currentSource,
    this.onBeforeSwitch,
  });

  final ReaderSourceType currentSource;
  final VoidCallback? onBeforeSwitch;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.bottomEnd,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 12),
        child: TextButton.icon(
          icon: Icon(currentSource.icon),
          label: Text(currentSource.labelKey.tr),
          onPressed: () {
            onBeforeSwitch?.call();
            showReaderSourcePicker(currentSource);
          },
        ),
      ),
    );
  }
}

Future<void> showReaderSourcePicker(ReaderSourceType currentSource) async {
  final ReaderSourceType? target = await Get.bottomSheet<ReaderSourceType>(
    SafeArea(
      child: Material(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  'switchReaderSource'.tr,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            for (final ReaderSourceType source in ReaderSourceType.values)
              ListTile(
                leading: Icon(source.icon),
                title: Text(source.labelKey.tr),
                trailing: source == currentSource
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Get.back(result: source),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
    isScrollControlled: true,
  );

  if (target == null || target == currentSource) {
    return;
  }

  _navigateToReaderSource(currentSource, target);
}

class ReaderSourceDrawer extends StatelessWidget {
  const ReaderSourceDrawer({
    super.key,
    required this.currentSource,
    this.children = const [],
    this.onBeforeSwitch,
  });

  final ReaderSourceType currentSource;
  final List<Widget> children;
  final VoidCallback? onBeforeSwitch;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: 278,
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 12,
              ),
              leading: CircleAvatar(child: Icon(currentSource.icon)),
              title: Text(
                currentSource.labelKey.tr,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('readerSource'.tr),
            ),
            const Divider(height: 1),
            ...children,
            const Spacer(),
            const Divider(height: 1),
            ReaderSourceSwitcher(
              currentSource: currentSource,
              onBeforeSwitch: onBeforeSwitch,
            ),
          ],
        ),
      ),
    );
  }
}

void _navigateToReaderSource(
  ReaderSourceType currentSource,
  ReaderSourceType target,
) {
  if (target == currentSource) {
    return;
  }

  if (target == ReaderSourceType.jhentai) {
    Get.offAllNamed(Routes.home);
    return;
  }

  final String routeName = target == ReaderSourceType.komga
      ? Routes.komga
      : Routes.pdfLibrary;
  if (currentSource == ReaderSourceType.jhentai) {
    Get.toNamed(routeName);
  } else {
    Get.offNamed(routeName);
  }
}
