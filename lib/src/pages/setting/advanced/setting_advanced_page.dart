import 'dart:convert';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:extended_image/extended_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/service/cloud_service.dart';
import 'package:jhentai/src/service/webdav_sync_service.dart';
import 'package:jhentai/src/setting/advanced_setting.dart';
import 'package:jhentai/src/setting/webdav_setting.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';
import 'package:path/path.dart';

import '../../../config/ui_config.dart';
import '../../../enum/config_type_enum.dart';
import '../../../routes/routes.dart';
import '../../../service/isolate_service.dart';
import '../../../utils/byte_util.dart';
import '../../../utils/permission_util.dart';
import '../../../utils/route_util.dart';
import '../../../widget/eh_config_type_select_dialog.dart';

class SettingAdvancedPage extends StatefulWidget {
  const SettingAdvancedPage({Key? key}) : super(key: key);

  @override
  _SettingAdvancedPageState createState() => _SettingAdvancedPageState();
}

class _SettingAdvancedPageState extends State<SettingAdvancedPage> {
  LoadingState _logLoadingState = LoadingState.idle;
  String _logSize = '...';

  LoadingState _imageCacheLoadingState = LoadingState.idle;
  String _imageCacheSize = '...';

  LoadingState _exportDataLoadingState = LoadingState.idle;
  LoadingState _importDataLoadingState = LoadingState.idle;

  LoadingState _testConnectionLoadingState = LoadingState.idle;
  LoadingState _syncLoadingState = LoadingState.idle;

  final TextEditingController _serverUrlController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _remotePathController = TextEditingController();

  @override
  void initState() {
    super.initState();

    _loadingLogSize();
    _getImagesCacheSize();

    _serverUrlController.text = webDavSetting.serverUrl.value;
    _usernameController.text = webDavSetting.username.value;
    _passwordController.text = webDavSetting.password.value;
    _remotePathController.text = webDavSetting.remotePath.value;
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _remotePathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('advancedSetting'.tr)),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: [
            _buildEnableLogging(),
            if (advancedSetting.enableLogging.isTrue) _buildRecordAllLogs().fadeIn(),
            _buildOpenLogs(),
            _buildClearLogs(context),
            _buildClearImageCache(context),
            _buildClearNetworkCache(),
            if (GetPlatform.isDesktop) _buildSuperResolution(),
            _buildCheckUpdate(),
            _buildCheckClipboard(),
            if (GetPlatform.isAndroid) _buildVerifyAppLinks(),
            _buildInNoImageMode(),
            _buildImportData(context),
            _buildExportData(context),
            const Divider(),
            _buildWebDavSyncSection(context),
          ],
        ).withListTileTheme(context),
      ),
    );
  }

  Widget _buildEnableLogging() {
    return ListTile(
      title: Text('enableLogging'.tr),
      subtitle: Text('needRestart'.tr),
      trailing: Switch(value: advancedSetting.enableLogging.value, onChanged: advancedSetting.saveEnableLogging),
    );
  }

  Widget _buildRecordAllLogs() {
    return SwitchListTile(
      title: Text('enableVerboseLogging'.tr),
      subtitle: Text('needRestart'.tr),
      value: advancedSetting.enableVerboseLogging.value,
      onChanged: advancedSetting.saveEnableVerboseLogging,
    );
  }

  Widget _buildOpenLogs() {
    return ListTile(
      title: Text('openLog'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right).marginOnly(right: 4),
      onTap: () => toRoute(Routes.logList),
    );
  }

  Widget _buildClearLogs(BuildContext context) {
    return ListTile(
      title: Text('clearLogs'.tr),
      subtitle: Text('longPress2Clear'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingStateIndicator(
            loadingState: _logLoadingState,
            useCupertinoIndicator: true,
            successWidgetBuilder: () => Text(
              _logSize,
              style: TextStyle(color: UIConfig.resumePauseButtonColor(context), fontWeight: FontWeight.w500),
            ),
            errorTapCallback: _loadingLogSize,
          ).marginOnly(right: 8)
        ],
      ),
      onLongPress: _clearAndLoadingLogSize,
    );
  }

  Widget _buildClearImageCache(BuildContext context) {
    return ListTile(
      title: Text('clearImagesCache'.tr),
      subtitle: Text('longPress2Clear'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingStateIndicator(
            loadingState: _imageCacheLoadingState,
            useCupertinoIndicator: true,
            successWidgetBuilder: () => Text(
              _imageCacheSize,
              style: TextStyle(color: UIConfig.resumePauseButtonColor(context), fontWeight: FontWeight.w500),
            ),
            errorTapCallback: _getImagesCacheSize,
          ).marginOnly(right: 8)
        ],
      ),
      onLongPress: _clearAndLoadingImageCacheSize,
    );
  }

  Widget _buildClearNetworkCache() {
    return ListTile(
      title: Text('clearPageCache'.tr),
      subtitle: Text('longPress2Clear'.tr),
      onLongPress: () async {
        await ehRequest.removeAllCache();
        toast('clearSuccess'.tr, isCenter: false);
      },
    );
  }

  Widget _buildSuperResolution() {
    return ListTile(
      title: Text('superResolution'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right).marginOnly(right: 4),
      onTap: () => toRoute(Routes.superResolution),
    );
  }

  Widget _buildCheckUpdate() {
    return SwitchListTile(
      title: Text('checkUpdateAfterLaunchingApp'.tr),
      value: advancedSetting.enableCheckUpdate.value,
      onChanged: advancedSetting.saveEnableCheckUpdate,
    );
  }

  Widget _buildCheckClipboard() {
    return SwitchListTile(
      title: Text('checkClipboard'.tr),
      value: advancedSetting.enableCheckClipboard.value,
      onChanged: advancedSetting.saveEnableCheckClipboard,
    );
  }

  Widget _buildVerifyAppLinks() {
    return ListTile(
      title: Text('verityAppLinks4Android12'.tr),
      subtitle: Text('verityAppLinks4Android12Hint'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right).marginOnly(right: 4),
      onTap: () async {
        try {
          await const AndroidIntent(
            action: 'android.settings.APP_OPEN_BY_DEFAULT_SETTINGS',
            data: 'package:top.jtmonster.jhentai',
          ).launch();
        } on Exception catch (e) {
          log.error(e);
          log.uploadError(e);
          toast('error'.tr);
        }
      },
    );
  }

  Widget _buildInNoImageMode() {
    return SwitchListTile(
      title: Text('noImageMode'.tr),
      value: advancedSetting.inNoImageMode.value,
      onChanged: advancedSetting.saveInNoImageMode,
    );
  }

  Widget _buildImportData(BuildContext context) {
    return ListTile(
      title: Text('importData'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingStateIndicator(
            loadingState: _importDataLoadingState,
            idleWidgetBuilder: () => const Icon(Icons.keyboard_arrow_right),
            successWidgetSameWithIdle: true,
            useCupertinoIndicator: true,
            errorWidgetSameWithIdle: true,
          ).marginOnly(right: 8)
        ],
      ),
      onTap: () => _importData(context),
    );
  }

  Widget _buildExportData(BuildContext context) {
    return ListTile(
      title: Text('exportData'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingStateIndicator(
            loadingState: _exportDataLoadingState,
            idleWidgetBuilder: () => const Icon(Icons.keyboard_arrow_right),
            successWidgetSameWithIdle: true,
            useCupertinoIndicator: true,
            errorWidgetSameWithIdle: true,
          ).marginOnly(right: 8)
        ],
      ),
      onTap: () => _exportData(context),
    );
  }

  Future<void> _loadingLogSize() async {
    if (_logLoadingState == LoadingState.loading) {
      return;
    }

    setStateSafely(() => _logLoadingState = LoadingState.loading);

    try {
      _logSize = await log.getSize();
    } catch (e) {
      log.error('loading log size error', e);
      _logSize = '-1B';
      setStateSafely(() => _imageCacheLoadingState = LoadingState.error);
      return;
    }

    setStateSafely(() => _logLoadingState = LoadingState.success);
  }

  Future<void> _clearAndLoadingLogSize() async {
    if (_logLoadingState == LoadingState.loading) {
      return;
    }

    await log.clear();
    await _loadingLogSize();

    toast('clearSuccess'.tr, isCenter: false);
  }

  Future<void> _getImagesCacheSize() async {
    if (_imageCacheLoadingState == LoadingState.loading) {
      return;
    }

    setStateSafely(() => _imageCacheLoadingState = LoadingState.loading);

    try {
      _imageCacheSize = await compute(
        (dirPath) {
          Directory cacheImagesDirectory = Directory(dirPath);

          int totalBytes;
          if (!cacheImagesDirectory.existsSync()) {
            totalBytes = 0;
          } else {
            totalBytes = cacheImagesDirectory.listSync().fold<int>(0, (previousValue, element) => previousValue += (element as File).lengthSync());
          }

          return byte2String(totalBytes.toDouble());
        },
        join(pathService.tempDir.path, cacheImageFolderName),
      );
    } catch (e) {
      log.error(e);
      _imageCacheSize = '-1B';
      setStateSafely(() => _imageCacheLoadingState = LoadingState.error);
      return;
    }

    setStateSafely(() => _imageCacheLoadingState = LoadingState.success);
  }

  Future<void> _clearAndLoadingImageCacheSize() async {
    if (_imageCacheLoadingState == LoadingState.loading) {
      return;
    }

    await clearDiskCachedImages();
    await _getImagesCacheSize();

    toast('clearSuccess'.tr, isCenter: false);
  }

  Future<void> _importData(BuildContext context) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowCompression: false,
        compressionQuality: 0,
      );
    } on Exception catch (e) {
      log.error('Pick import data file failed', e);
      return;
    }

    if (result == null) {
      return;
    }

    if (_importDataLoadingState == LoadingState.loading) {
      return;
    }

    log.info('Import data from ${result.files.first.path}');
    setStateSafely(() => _importDataLoadingState = LoadingState.loading);

    File file = File(result.files.first.path!);
    String string = await file.readAsString();

    try {
      List list = await isolateService.jsonDecodeAsync(string);
      List<CloudConfig> configs = list.map((e) => CloudConfig.fromJson(e)).toList();
      for (CloudConfig config in configs) {
        await cloudConfigService.importConfig(config);
      }

      toast('success'.tr);
      setStateSafely(() => _importDataLoadingState = LoadingState.success);
    } catch (e, s) {
      log.error('Import data failed', e, s);
      toast('internalError'.tr);
      setStateSafely(() => _importDataLoadingState = LoadingState.error);
      return;
    }
  }

  Future<void> _exportData(BuildContext context) async {
    List<CloudConfigTypeEnum>? result = await showDialog(
      context: context,
      builder: (_) => EHConfigTypeSelectDialog(title: 'selectExportItems'.tr),
    );
    if (result?.isEmpty ?? true) {
      return;
    }

    String fileName = '${CloudConfigService.configFileName}-${DateFormat('yyyyMMddHHmmss').format(DateTime.now())}.json';
    if (GetPlatform.isMobile) {
      return _exportDataMobile(fileName, result);
    } else {
      return _exportDataDesktop(fileName, result);
    }
  }

  Future<void> _exportDataMobile(String fileName, List<CloudConfigTypeEnum>? result) async {
    if (_exportDataLoadingState == LoadingState.loading) {
      return;
    }
    setStateSafely(() => _exportDataLoadingState = LoadingState.loading);

    List<CloudConfig> uploadConfigs = [];
    for (CloudConfigTypeEnum type in result!) {
      CloudConfig? config = await cloudConfigService.getLocalConfig(type);
      if (config != null) {
        uploadConfigs.add(config);
      }
    }

    try {
      String? savedPath = await FilePicker.platform.saveFile(
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: utf8.encode(await isolateService.jsonEncodeAsync(uploadConfigs)),
        lockParentWindow: true,
      );
      if (savedPath != null) {
        log.info('Export data to $savedPath success');
        toast('success'.tr);
        setStateSafely(() => _exportDataLoadingState = LoadingState.success);
      }
    } on Exception catch (e) {
      log.error('Export data failed', e);
      toast('internalError'.tr);
      setStateSafely(() => _exportDataLoadingState = LoadingState.error);
    }
  }

  Future<void> _exportDataDesktop(String fileName, List<CloudConfigTypeEnum>? result) async {
    if (_exportDataLoadingState == LoadingState.loading) {
      return;
    }
    setStateSafely(() => _exportDataLoadingState = LoadingState.loading);

    String? savedPath;
    try {
      savedPath = await FilePicker.platform.saveFile(
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        lockParentWindow: true,
      );
    } on Exception catch (e) {
      log.error('Select save path for exporting data failed', e);
      toast('internalError'.tr);
      setStateSafely(() => _exportDataLoadingState = LoadingState.error);
      return;
    }

    if (savedPath == null) {
      return;
    }

    List<CloudConfig> uploadConfigs = [];
    for (CloudConfigTypeEnum type in result!) {
      CloudConfig? config = await cloudConfigService.getLocalConfig(type);
      if (config != null) {
        uploadConfigs.add(config);
      }
    }

    File file = File(savedPath);
    try {
      if (await file.exists()) {
        await file.create(recursive: true);
      }
      await file.writeAsString(await isolateService.jsonEncodeAsync(uploadConfigs));
      log.info('Export data to $savedPath success');
      toast('success'.tr);
      setStateSafely(() => _exportDataLoadingState = LoadingState.success);
    } on Exception catch (e) {
      log.error('Export data failed', e);
      toast('internalError'.tr);
      setStateSafely(() => _exportDataLoadingState = LoadingState.error);
      file.delete().ignore();
    }
  }

  Widget _buildWebDavSyncSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            'webdavSync'.tr,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        _buildEnableWebDav(),
        if (webDavSetting.enableWebDav.isTrue) ...[
          _buildWebDavServerUrl(),
          _buildWebDavUsername(),
          _buildWebDavPassword(),
          _buildWebDavRemotePath(),
          _buildTestConnection(),
          _buildManualSync(context),
        ],
      ],
    );
  }

  Widget _buildEnableWebDav() {
    return ListTile(
      title: Text('enableWebDav'.tr),
      subtitle: Text('enableWebDavHint'.tr),
      trailing: Switch(
        value: webDavSetting.enableWebDav.value,
        onChanged: webDavSetting.saveEnableWebDav,
      ),
    );
  }

  Widget _buildWebDavServerUrl() {
    return ListTile(
      title: Text('webdavServerUrl'.tr),
      subtitle: TextField(
        controller: _serverUrlController,
        decoration: InputDecoration(
          hintText: 'https://dav.jianguoyun.com/dav/',
          border: InputBorder.none,
        ),
        onChanged: (value) => webDavSetting.saveServerUrl(value),
      ),
    );
  }

  Widget _buildWebDavUsername() {
    return ListTile(
      title: Text('webdavUsername'.tr),
      subtitle: TextField(
        controller: _usernameController,
        decoration: InputDecoration(
          hintText: 'username@example.com',
          border: InputBorder.none,
        ),
        onChanged: (value) => webDavSetting.saveUsername(value),
      ),
    );
  }

  Widget _buildWebDavPassword() {
    return ListTile(
      title: Text('webdavPassword'.tr),
      subtitle: TextField(
        controller: _passwordController,
        obscureText: true,
        decoration: InputDecoration(
          hintText: '••••••••',
          border: InputBorder.none,
        ),
        onChanged: (value) => webDavSetting.savePassword(value),
      ),
    );
  }

  Widget _buildWebDavRemotePath() {
    return ListTile(
      title: Text('webdavRemotePath'.tr),
      subtitle: TextField(
        controller: _remotePathController,
        decoration: InputDecoration(
          hintText: '/JHenTaiConfig',
          border: InputBorder.none,
        ),
        onChanged: (value) => webDavSetting.saveRemotePath(value),
      ),
    );
  }

  Widget _buildTestConnection() {
    return ListTile(
      title: Text('testConnection'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingStateIndicator(
            loadingState: _testConnectionLoadingState,
            idleWidgetBuilder: () => const Icon(Icons.keyboard_arrow_right),
            successWidgetSameWithIdle: false,
            successWidgetBuilder: () => const Icon(Icons.check, color: Colors.green),
            useCupertinoIndicator: true,
            errorWidgetSameWithIdle: false,
            errorWidgetBuilder: () => const Icon(Icons.error, color: Colors.red),
          ).marginOnly(right: 8)
        ],
      ),
      onTap: _testWebDavConnection,
    );
  }

  Widget _buildManualSync(BuildContext context) {
    return ListTile(
      title: Text('manualSync'.tr),
      subtitle: Text('manualSyncHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingStateIndicator(
            loadingState: _syncLoadingState,
            idleWidgetBuilder: () => const Icon(Icons.keyboard_arrow_right),
            successWidgetSameWithIdle: false,
            successWidgetBuilder: () => const Icon(Icons.check, color: Colors.green),
            useCupertinoIndicator: true,
            errorWidgetSameWithIdle: false,
            errorWidgetBuilder: () => const Icon(Icons.error, color: Colors.red),
          ).marginOnly(right: 8)
        ],
      ),
      onTap: () => _performManualSync(context),
    );
  }

  Future<void> _testWebDavConnection() async {
    if (_testConnectionLoadingState == LoadingState.loading) {
      return;
    }

    setStateSafely(() => _testConnectionLoadingState = LoadingState.loading);

    try {
      bool success = await webDavSyncService.testConnection();
      if (success) {
        toast('connectionSuccess'.tr, isCenter: false);
        setStateSafely(() => _testConnectionLoadingState = LoadingState.success);
      } else {
        toast('connectionFailed'.tr, isCenter: false);
        setStateSafely(() => _testConnectionLoadingState = LoadingState.error);
      }
    } catch (e) {
      log.error('Test WebDAV connection failed', e);
      toast('connectionFailed'.tr + ': ${e.toString()}', isCenter: false);
      setStateSafely(() => _testConnectionLoadingState = LoadingState.error);
    }

    // Reset state after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setStateSafely(() => _testConnectionLoadingState = LoadingState.idle);
      }
    });
  }

  Future<void> _performManualSync(BuildContext context) async {
    // First, show dialog to select config types
    List<CloudConfigTypeEnum>? selectedTypes = await showDialog(
      context: context,
      builder: (_) => EHConfigTypeSelectDialog(title: 'selectSyncItems'.tr),
    );

    if (selectedTypes?.isEmpty ?? true) {
      return;
    }

    if (_syncLoadingState == LoadingState.loading) {
      return;
    }

    setStateSafely(() => _syncLoadingState = LoadingState.loading);

    try {
      SyncResult result = await webDavSyncService.manualSync(selectedTypes!);

      if (result.success) {
        String message = '';
        switch (result.direction) {
          case SyncDirection.upload:
            message = 'syncUploadSuccess'.tr;
            break;
          case SyncDirection.download:
            message = 'syncDownloadSuccess'.tr;
            break;
          case SyncDirection.none:
            message = 'alreadySynced'.tr;
            break;
        }
        toast(message, isCenter: false);
        setStateSafely(() => _syncLoadingState = LoadingState.success);
      } else {
        toast('syncFailed'.tr + ': ${result.message}', isCenter: false);
        setStateSafely(() => _syncLoadingState = LoadingState.error);
      }
    } catch (e) {
      log.error('Manual sync failed', e);
      toast('syncFailed'.tr + ': ${e.toString()}', isCenter: false);
      setStateSafely(() => _syncLoadingState = LoadingState.error);
    }

    // Reset state after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setStateSafely(() => _syncLoadingState = LoadingState.idle);
      }
    });
  }
}
