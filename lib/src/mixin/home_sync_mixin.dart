import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/utils/toast_util.dart';

/// A tap on a home page's title syncs everything at once; a thin bar under
/// the app bar shows the progress. Every site's home has it.
mixin HomeSyncLogicMixin on GetxController {
  final String syncProgressId = 'syncProgressId';

  bool syncInProgress = false;
  double syncProgress = 0;

  /// False for pages that share a home page's logic but are not one.
  bool get homeSyncEnabled => true;

  Future<void> handleTapHomeSync() async {
    if (syncInProgress || !syncSetting.enableSync.value) {
      return;
    }

    String provider = syncSetting.currentProvider.value;
    log.info('Syncing on home title tap with provider: $provider');

    syncInProgress = true;
    syncProgress = 0.03;
    updateSafely([syncProgressId]);

    try {
      SyncResult result = await syncService.sync(
        types: CloudConfigTypeEnum.values,
        providerName: provider,
        onProgress: (progress) {
          syncProgress = progress;
          updateSafely([syncProgressId]);
        },
      );

      if (result.success) {
        log.info('Sync successful: ${result.message}');
        toast('syncSuccess'.tr, isShort: false);
      } else {
        log.warning('Sync failed: ${result.message}');
        toast('${'syncFailed'.tr}: ${result.message}', isShort: false);
      }
    } catch (e) {
      log.error('Sync error on home title tap', e);
      toast('syncFailed'.tr, isShort: false);
    } finally {
      syncProgress = 1;
      updateSafely([syncProgressId]);

      await Future.delayed(const Duration(milliseconds: 350));
      syncInProgress = false;
      syncProgress = 0;
      updateSafely([syncProgressId]);
    }
  }
}

/// The page title, syncing when tapped.
class HomeSyncTitle extends StatelessWidget {
  const HomeSyncTitle({super.key, required this.logic, required this.title});

  final HomeSyncLogicMixin logic;
  final String title;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(key: const Key('homeSyncTitle'), onTap: logic.handleTapHomeSync, child: Text(title));
  }
}

/// Progress of a sync started from the title; 2 pixels high, empty when
/// idle.
class HomeSyncProgressBar extends StatelessWidget {
  const HomeSyncProgressBar({super.key, required this.logic});

  final HomeSyncLogicMixin logic;

  @override
  Widget build(BuildContext context) {
    return GetBuilder<HomeSyncLogicMixin>(
      id: logic.syncProgressId,
      global: false,
      init: logic,
      builder: (_) => SizedBox(
        height: 2,
        child: logic.syncInProgress
            ? LinearProgressIndicator(minHeight: 2, value: logic.syncProgress.clamp(0.03, 1).toDouble())
            : null,
      ),
    );
  }
}
