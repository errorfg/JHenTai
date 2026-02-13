import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/utils/toast_util.dart';

import '../../base/base_page_logic.dart';
import 'gallerys_page_state.dart';

class GallerysPageLogic extends BasePageLogic {
  final String syncProgressId = 'syncProgressId';

  @override
  bool get useSearchConfig => true;

  @override
  final GallerysPageState state = GallerysPageState();

  Future<void> handleTapHomeSync() async {
    if (state.syncInProgress) {
      return;
    }

    if (!syncSetting.enableSync.value) {
      return;
    }

    String provider = syncSetting.currentProvider.value;
    log.info('Syncing on gallery title tap with provider: $provider');

    state.syncInProgress = true;
    state.syncProgress = 0.03;
    update([syncProgressId]);

    try {
      SyncResult result = await syncService.sync(
        types: CloudConfigTypeEnum.values,
        providerName: provider,
        onProgress: (progress) {
          state.syncProgress = progress;
          update([syncProgressId]);
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
      log.error('Sync error on gallery title tap', e);
      toast('syncFailed'.tr, isShort: false);
    } finally {
      state.syncProgress = 1;
      update([syncProgressId]);

      await Future.delayed(const Duration(milliseconds: 350));
      state.syncInProgress = false;
      state.syncProgress = 0;
      update([syncProgressId]);
    }
  }
}
