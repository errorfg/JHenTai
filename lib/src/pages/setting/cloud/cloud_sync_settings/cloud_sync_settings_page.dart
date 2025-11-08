import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/service/sync_merger.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:jhentai/src/widget/eh_config_type_select_dialog.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

class CloudSyncSettingsPage extends StatefulWidget {
  const CloudSyncSettingsPage({super.key});

  @override
  State<CloudSyncSettingsPage> createState() => _CloudSyncSettingsPageState();
}

class _CloudSyncSettingsPageState extends State<CloudSyncSettingsPage> {
  LoadingState _testConnectionState = LoadingState.idle;
  LoadingState _syncState = LoadingState.idle;

  // S3 Controllers
  final TextEditingController _s3EndpointController = TextEditingController();
  final TextEditingController _s3AccessKeyController = TextEditingController();
  final TextEditingController _s3SecretKeyController = TextEditingController();
  final TextEditingController _s3BucketNameController = TextEditingController();
  final TextEditingController _s3RegionController = TextEditingController();
  final TextEditingController _s3BaseKeyController = TextEditingController();

  // WebDAV Controllers
  final TextEditingController _webdavServerUrlController = TextEditingController();
  final TextEditingController _webdavUsernameController = TextEditingController();
  final TextEditingController _webdavPasswordController = TextEditingController();
  final TextEditingController _webdavRemotePathController = TextEditingController();

  // History Controllers
  final TextEditingController _maxHistoryVersionsController = TextEditingController();

  // Password visibility state
  bool _s3AccessKeyVisible = false;
  bool _s3SecretKeyVisible = false;
  bool _webdavPasswordVisible = false;

  // Debounce timer for auto-save
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() {
    // S3 settings
    _s3EndpointController.text = syncSetting.s3Endpoint.value;
    _s3AccessKeyController.text = syncSetting.s3AccessKey.value;
    _s3SecretKeyController.text = syncSetting.s3SecretKey.value;
    _s3BucketNameController.text = syncSetting.s3BucketName.value;
    _s3RegionController.text = syncSetting.s3Region.value;
    _s3BaseKeyController.text = syncSetting.s3BaseKey.value;

    // WebDAV settings
    _webdavServerUrlController.text = syncSetting.webdavServerUrl.value;
    _webdavUsernameController.text = syncSetting.webdavUsername.value;
    _webdavPasswordController.text = syncSetting.webdavPassword.value;
    _webdavRemotePathController.text = syncSetting.webdavRemotePath.value;

    // History settings
    _maxHistoryVersionsController.text = syncSetting.maxHistoryVersions.value.toString();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _s3EndpointController.dispose();
    _s3AccessKeyController.dispose();
    _s3SecretKeyController.dispose();
    _s3BucketNameController.dispose();
    _s3RegionController.dispose();
    _s3BaseKeyController.dispose();
    _webdavServerUrlController.dispose();
    _webdavUsernameController.dispose();
    _webdavPasswordController.dispose();
    _webdavRemotePathController.dispose();
    _maxHistoryVersionsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text('cloudSync'.tr),
      ),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: [
            _buildProviderSelector(context),
            _buildAutoSyncSwitch(context),
            const Divider(height: 32),
            if (syncSetting.currentProvider.value == 's3') ..._buildS3Settings(context),
            if (syncSetting.currentProvider.value == 'webdav') ..._buildWebDavSettings(context),
            const Divider(height: 32),
            ..._buildHistorySettings(context),
            const Divider(height: 32),
            _buildTestConnectionButton(context),
            _buildSyncButton(context),
            if (syncSetting.enableHistory.value) _buildViewHistoryButton(context),
          ],
        ).withListTileTheme(context),
      ),
    );
  }

  Widget _buildProviderSelector(BuildContext context) {
    return ListTile(
      title: Text('syncProvider'.tr),
      subtitle: Text('syncProviderHint'.tr),
      trailing: DropdownButton<String>(
        value: syncSetting.currentProvider.value,
        elevation: 4,
        alignment: AlignmentDirectional.centerEnd,
        onChanged: (String? newValue) async {
          if (newValue != null) {
            await syncSetting.saveCurrentProvider(newValue);
            syncService.reinitProviders();
            setState(() => _testConnectionState = LoadingState.idle);
          }
        },
        items: [
          DropdownMenuItem(value: 's3', child: Text('cloudProviderS3'.tr)),
          DropdownMenuItem(value: 'webdav', child: Text('cloudProviderWebDAV'.tr)),
        ],
      ),
    );
  }

  Widget _buildAutoSyncSwitch(BuildContext context) {
    return SwitchListTile(
      title: Text('autoSync'.tr),
      subtitle: Text('autoSyncHint'.tr),
      value: syncSetting.autoSync.value,
      onChanged: (value) async {
        await syncSetting.saveAutoSync(value);
      },
    );
  }

  List<Widget> _buildS3Settings(BuildContext context) {
    return [
      ListTile(
        title: Text('s3Config'.tr, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      ),
      SwitchListTile(
        title: Text('enableS3'.tr),
        subtitle: Text('enableS3Hint'.tr),
        value: syncSetting.enableS3.value,
        onChanged: (value) async {
          await syncSetting.saveEnableS3(value);
        },
      ),
      _buildTextFieldTile(
        context: context,
        title: 's3Endpoint'.tr,
        subtitle: 's3EndpointHint'.tr,
        controller: _s3EndpointController,
        onSave: syncSetting.saveS3Endpoint,
      ),
      _buildTextFieldTile(
        context: context,
        title: 's3AccessKey'.tr,
        controller: _s3AccessKeyController,
        onSave: syncSetting.saveS3AccessKey,
        obscureText: true,
        isPasswordVisible: _s3AccessKeyVisible,
        togglePasswordVisibility: () => setState(() => _s3AccessKeyVisible = !_s3AccessKeyVisible),
      ),
      _buildTextFieldTile(
        context: context,
        title: 's3SecretKey'.tr,
        controller: _s3SecretKeyController,
        onSave: syncSetting.saveS3SecretKey,
        obscureText: true,
        isPasswordVisible: _s3SecretKeyVisible,
        togglePasswordVisibility: () => setState(() => _s3SecretKeyVisible = !_s3SecretKeyVisible),
      ),
      _buildTextFieldTile(
        context: context,
        title: 's3BucketName'.tr,
        controller: _s3BucketNameController,
        onSave: syncSetting.saveS3BucketName,
      ),
      _buildTextFieldTile(
        context: context,
        title: 's3Region'.tr,
        subtitle: 's3RegionHint'.tr,
        controller: _s3RegionController,
        onSave: syncSetting.saveS3Region,
      ),
      _buildTextFieldTile(
        context: context,
        title: 's3BaseKey'.tr,
        subtitle: 's3BaseKeyHint'.tr,
        controller: _s3BaseKeyController,
        onSave: syncSetting.saveS3BaseKey,
      ),
      SwitchListTile(
        title: Text('s3UseSSL'.tr),
        value: syncSetting.s3UseSSL.value,
        onChanged: (value) async {
          await syncSetting.saveS3UseSSL(value);
        },
      ),
    ];
  }

  List<Widget> _buildWebDavSettings(BuildContext context) {
    return [
      ListTile(
        title: Text('webdavConfig'.tr, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      ),
      SwitchListTile(
        title: Text('enableWebDAV'.tr),
        subtitle: Text('enableWebDAVHint'.tr),
        value: syncSetting.enableWebDav.value,
        onChanged: (value) async {
          await syncSetting.saveEnableWebDav(value);
        },
      ),
      _buildTextFieldTile(
        context: context,
        title: 'webdavServerUrl'.tr,
        subtitle: 'webdavServerUrlHint'.tr,
        controller: _webdavServerUrlController,
        onSave: syncSetting.saveWebdavServerUrl,
      ),
      _buildTextFieldTile(
        context: context,
        title: 'webdavUsername'.tr,
        controller: _webdavUsernameController,
        onSave: syncSetting.saveWebdavUsername,
      ),
      _buildTextFieldTile(
        context: context,
        title: 'webdavPassword'.tr,
        controller: _webdavPasswordController,
        onSave: syncSetting.saveWebdavPassword,
        obscureText: true,
        isPasswordVisible: _webdavPasswordVisible,
        togglePasswordVisibility: () => setState(() => _webdavPasswordVisible = !_webdavPasswordVisible),
      ),
      _buildTextFieldTile(
        context: context,
        title: 'webdavRemotePath'.tr,
        subtitle: 'webdavRemotePathHint'.tr,
        controller: _webdavRemotePathController,
        onSave: syncSetting.saveWebdavRemotePath,
      ),
    ];
  }

  List<Widget> _buildHistorySettings(BuildContext context) {
    return [
      ListTile(
        title: Text('historySettings'.tr, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      ),
      SwitchListTile(
        title: Text('enableHistory'.tr),
        subtitle: Text('enableHistoryHint'.tr),
        value: syncSetting.enableHistory.value,
        onChanged: syncSetting.saveEnableHistory,
      ),
      if (syncSetting.enableHistory.value) ...[
        _buildTextFieldTile(
          context: context,
          title: 'maxHistoryVersions'.tr,
          subtitle: 'maxHistoryVersionsHint'.tr,
          controller: _maxHistoryVersionsController,
          onSave: (value) async {
            int? intValue = int.tryParse(value);
            if (intValue != null && intValue > 0) {
              await syncSetting.saveMaxHistoryVersions(intValue);
              toast('saveSuccess'.tr);
            } else {
              toast('invalidValue'.tr);
            }
          },
          keyboardType: TextInputType.number,
        ),
        SwitchListTile(
          title: Text('autoCleanHistory'.tr),
          subtitle: Text('autoCleanHistoryHint'.tr),
          value: syncSetting.autoCleanHistory.value,
          onChanged: syncSetting.saveAutoCleanHistory,
        ),
      ],
    ];
  }

  /// Debounced auto-save helper
  void _debouncedSave(Future<void> Function() saveFunction) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () async {
      await saveFunction();
    });
  }

  Widget _buildTextFieldTile({
    required BuildContext context,
    required String title,
    String? subtitle,
    required TextEditingController controller,
    required Future<void> Function(String) onSave,
    bool obscureText = false,
    bool? isPasswordVisible,
    VoidCallback? togglePasswordVisibility,
    TextInputType? keyboardType,
  }) {
    Widget textField = TextField(
      controller: controller,
      obscureText: obscureText && !(isPasswordVisible ?? false),
      keyboardType: keyboardType,
      onChanged: (value) {
        // Auto-save with debounce
        _debouncedSave(() => onSave(value));
      },
      decoration: InputDecoration(
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        suffixIcon: obscureText && togglePasswordVisibility != null
            ? IconButton(
                icon: Icon(
                  (isPasswordVisible ?? false) ? Icons.visibility : Icons.visibility_off,
                  size: 20,
                ),
                onPressed: togglePasswordVisibility,
              )
            : null,
      ),
    );

    return ListTile(
      title: Text(title),
      subtitle: subtitle != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(height: 8),
                textField,
              ],
            )
          : textField,
    );
  }

  Widget _buildTestConnectionButton(BuildContext context) {
    return ListTile(
      title: ElevatedButton.icon(
        icon: LoadingStateIndicator(
          loadingState: _testConnectionState,
          idleWidgetBuilder: () => const Icon(Icons.wifi_tethering),
          successWidgetBuilder: () => const Icon(Icons.check_circle, color: Colors.green),
          errorWidgetBuilder: () => const Icon(Icons.error, color: Colors.red),
        ),
        label: Text('testConnection'.tr),
        onPressed: _testConnection,
      ),
    );
  }

  Widget _buildSyncButton(BuildContext context) {
    return ListTile(
      title: ElevatedButton.icon(
        icon: LoadingStateIndicator(
          loadingState: _syncState,
          idleWidgetBuilder: () => const Icon(Icons.sync),
          successWidgetBuilder: () => const Icon(Icons.check_circle, color: Colors.green),
          errorWidgetBuilder: () => const Icon(Icons.error, color: Colors.red),
        ),
        label: Text('syncNow'.tr),
        onPressed: _performSync,
      ),
    );
  }

  Widget _buildViewHistoryButton(BuildContext context) {
    return ListTile(
      title: ElevatedButton.icon(
        icon: const Icon(Icons.history),
        label: Text('viewHistory'.tr),
        onPressed: () => toRoute(Routes.syncHistory),
      ),
    );
  }

  Future<void> _testConnection() async {
    if (_testConnectionState == LoadingState.loading) {
      return;
    }

    setState(() => _testConnectionState = LoadingState.loading);

    try {
      // Save all current values from controllers before testing
      if (syncSetting.currentProvider.value == 's3') {
        await syncSetting.saveS3Endpoint(_s3EndpointController.text);
        await syncSetting.saveS3AccessKey(_s3AccessKeyController.text);
        await syncSetting.saveS3SecretKey(_s3SecretKeyController.text);
        await syncSetting.saveS3BucketName(_s3BucketNameController.text);
        await syncSetting.saveS3Region(_s3RegionController.text);
        await syncSetting.saveS3BaseKey(_s3BaseKeyController.text);
      } else if (syncSetting.currentProvider.value == 'webdav') {
        await syncSetting.saveWebdavServerUrl(_webdavServerUrlController.text);
        await syncSetting.saveWebdavUsername(_webdavUsernameController.text);
        await syncSetting.saveWebdavPassword(_webdavPasswordController.text);
        await syncSetting.saveWebdavRemotePath(_webdavRemotePathController.text);
      }

      bool success = await syncService.testConnection(syncSetting.currentProvider.value);

      setState(() => _testConnectionState = success ? LoadingState.success : LoadingState.error);

      if (success) {
        toast('connectionSuccess'.tr);
      } else {
        toast('connectionFailed'.tr);
      }

      // Reset state after 2 seconds
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() => _testConnectionState = LoadingState.idle);
        }
      });
    } catch (e) {
      log.error('Test connection failed', e);
      setState(() => _testConnectionState = LoadingState.error);
      toast('connectionFailed'.tr);

      // Reset state after 2 seconds
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() => _testConnectionState = LoadingState.idle);
        }
      });
    }
  }

  Future<void> _performSync() async {
    if (_syncState == LoadingState.loading) {
      return;
    }

    // Show dialog to select config types
    List<CloudConfigTypeEnum>? selectedTypes = await showDialog(
      context: context,
      builder: (_) => EHConfigTypeSelectDialog(title: '${'selectSyncTypes'.tr}?'),
    );

    if (selectedTypes == null || selectedTypes.isEmpty) {
      return;
    }

    setState(() => _syncState = LoadingState.loading);

    try {
      SyncResult result = await syncService.sync(types: selectedTypes);

      setState(() => _syncState = result.success ? LoadingState.success : LoadingState.error);

      if (result.success) {
        log.info('Sync successful: ${result.message}');
        // Log statistics to console instead of showing dialog
        _logSyncStatistics(result.statistics);
        toast('syncSuccess'.tr, isShort: false);
      } else {
        log.warning('Sync failed: ${result.message}');
        toast('${('syncFailed'.tr)}: ${result.message}');
      }

      // Reset state after 2 seconds
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() => _syncState = LoadingState.idle);
        }
      });
    } catch (e) {
      log.error('Sync failed', e);
      setState(() => _syncState = LoadingState.error);
      toast('syncFailed'.tr);

      // Reset state after 2 seconds
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() => _syncState = LoadingState.idle);
        }
      });
    }
  }

  void _logSyncStatistics(Map<CloudConfigTypeEnum, MergeStatistics> statistics) {
    if (statistics.isEmpty) {
      return;
    }

    log.info('Sync statistics:');
    statistics.forEach((type, stats) {
      log.info('  ${type.name}:');
      log.info('    Local count: ${stats.localCount}');
      log.info('    Remote count: ${stats.remoteCount}');
      log.info('    Merged count: ${stats.mergedCount}');
      log.info('    Added from remote: ${stats.addedFromRemote}');
      log.info('    Conflicts: ${stats.conflicts}');
    });
  }
}
