import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

class SyncHistoryPage extends StatefulWidget {
  const SyncHistoryPage({super.key});

  @override
  State<SyncHistoryPage> createState() => _SyncHistoryPageState();
}

class _SyncHistoryPageState extends State<SyncHistoryPage> {
  LoadingState _loadingState = LoadingState.idle;
  List<CloudFile> _versions = [];

  @override
  void initState() {
    super.initState();
    _loadVersions();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text('syncHistory'.tr),
        actions: [
          if (_versions.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: _confirmClearAllHistory,
            ),
        ],
      ),
      body: LoadingStateIndicator(
        loadingState: _loadingState,
        successWidgetBuilder: () => _versions.isEmpty
            ? Center(child: Text('noHistoryVersions'.tr, style: const TextStyle(fontSize: 16)))
            : ListView.builder(
                padding: const EdgeInsets.only(top: 16),
                itemCount: _versions.length,
                itemBuilder: (context, index) => _buildVersionItem(context, _versions[index], index),
              ).withListTileTheme(context),
        errorTapCallback: _loadVersions,
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.refresh),
        onPressed: _loadVersions,
      ),
    );
  }

  Widget _buildVersionItem(BuildContext context, CloudFile version, int index) {
    String formattedDate = _formatTimestamp(version.version);
    String sizeStr = _formatFileSize(version.size);

    return ListTile(
      leading: CircleAvatar(
        child: Text('${_versions.length - index}'),
      ),
      title: Text(formattedDate),
      subtitle: Text('${'version'.tr}: ${version.version}\n${'size'.tr}: $sizeStr'),
      isThreeLine: true,
      trailing: const Icon(Icons.more_vert),
      onTap: () => _showVersionActions(context, version),
    );
  }

  String _formatTimestamp(String timestamp) {
    // Parse timestamp format: yyyyMMddHHmmss
    if (timestamp.length != 14) {
      return timestamp;
    }

    try {
      int year = int.parse(timestamp.substring(0, 4));
      int month = int.parse(timestamp.substring(4, 6));
      int day = int.parse(timestamp.substring(6, 8));
      int hour = int.parse(timestamp.substring(8, 10));
      int minute = int.parse(timestamp.substring(10, 12));
      int second = int.parse(timestamp.substring(12, 14));

      DateTime date = DateTime(year, month, day, hour, minute, second);
      return DateFormat('yyyy-MM-dd HH:mm:ss').format(date);
    } catch (e) {
      return timestamp;
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(2)} KB';
    } else {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
  }

  Future<void> _loadVersions() async {
    if (_loadingState == LoadingState.loading) {
      return;
    }

    setState(() => _loadingState = LoadingState.loading);

    try {
      List<CloudFile> versions = await syncService.listHistory();

      setState(() {
        _versions = versions;
        _loadingState = LoadingState.success;
      });
    } catch (e) {
      log.error('Failed to load history versions', e);
      setState(() => _loadingState = LoadingState.error);
      toast('${'loadHistoryFailed'.tr}: $e');
    }
  }

  void _showVersionActions(BuildContext context, CloudFile version) {
    showCupertinoModalPopup(
      context: context,
      builder: (BuildContext context) => CupertinoActionSheet(
        title: Text('${'version'.tr}: ${_formatTimestamp(version.version)}'),
        message: Text('${'size'.tr}: ${_formatFileSize(version.size)}'),
        actions: <CupertinoActionSheetAction>[
          CupertinoActionSheetAction(
            child: Text('restoreVersion'.tr),
            onPressed: () {
              backRoute();
              _confirmRestoreVersion(version);
            },
          ),
          CupertinoActionSheetAction(
            child: Text('deleteVersion'.tr, style: TextStyle(color: UIConfig.alertColor(context))),
            onPressed: () {
              backRoute();
              _confirmDeleteVersion(version);
            },
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          child: Text('cancel'.tr),
          onPressed: backRoute,
        ),
      ),
    );
  }

  void _confirmRestoreVersion(CloudFile version) {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text('restoreVersion'.tr),
        content: Text(
          '${'restoreVersionConfirm'.tr}\n\n'
          '${'version'.tr}: ${_formatTimestamp(version.version)}\n'
          '${'size'.tr}: ${_formatFileSize(version.size)}\n\n'
          '${'restoreVersionWarning'.tr}',
        ),
        actions: [
          CupertinoDialogAction(
            child: Text('cancel'.tr),
            onPressed: () => Navigator.of(context).pop(),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(context).pop();
              _restoreVersion(version);
            },
            child: Text('restore'.tr),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreVersion(CloudFile version) async {
    setState(() => _loadingState = LoadingState.loading);

    try {
      RestoreResult result = await syncService.restoreFromHistory(
        version: version.version,
        syncToCloud: true,
      );

      if (result.success) {
        toast('restoreSuccess'.tr);
        setState(() => _loadingState = LoadingState.success);
        _loadVersions();
      } else {
        toast('${'restoreFailed'.tr}: ${result.error}');
        setState(() => _loadingState = LoadingState.error);
      }
    } catch (e) {
      log.error('Restore version failed', e);
      toast('${'restoreFailed'.tr}: $e');
      setState(() => _loadingState = LoadingState.error);
    }
  }

  void _confirmDeleteVersion(CloudFile version) {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text('deleteVersion'.tr),
        content: Text(
          '${'deleteVersionConfirm'.tr}\n\n'
          '${'version'.tr}: ${_formatTimestamp(version.version)}\n'
          '${'size'.tr}: ${_formatFileSize(version.size)}',
        ),
        actions: [
          CupertinoDialogAction(
            child: Text('cancel'.tr),
            onPressed: () => Navigator.of(context).pop(),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(context).pop();
              _deleteVersion(version);
            },
            child: Text('delete'.tr),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteVersion(CloudFile version) async {
    setState(() => _loadingState = LoadingState.loading);

    try {
      bool success = await syncService.deleteHistoryVersion(version: version.version);

      if (success) {
        toast('deleteSuccess'.tr);
        _loadVersions();
      } else {
        toast('deleteFailed'.tr);
        setState(() => _loadingState = LoadingState.error);
      }
    } catch (e) {
      log.error('Delete version failed', e);
      toast('${'deleteFailed'.tr}: $e');
      setState(() => _loadingState = LoadingState.error);
    }
  }

  void _confirmClearAllHistory() {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text('clearAllHistory'.tr),
        content: Text(
          '${'clearAllHistoryConfirm'.tr}\n\n'
          '${'totalVersions'.tr}: ${_versions.length}\n\n'
          '${'clearAllHistoryWarning'.tr}',
        ),
        actions: [
          CupertinoDialogAction(
            child: Text('cancel'.tr),
            onPressed: () => Navigator.of(context).pop(),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(context).pop();
              _clearAllHistory();
            },
            child: Text('clearAll'.tr),
          ),
        ],
      ),
    );
  }

  Future<void> _clearAllHistory() async {
    setState(() => _loadingState = LoadingState.loading);

    try {
      bool success = await syncService.clearAllHistory();

      if (success) {
        toast('clearSuccess'.tr);
        _loadVersions();
      } else {
        toast('clearFailed'.tr);
        setState(() => _loadingState = LoadingState.error);
      }
    } catch (e) {
      log.error('Clear all history failed', e);
      toast('${'clearFailed'.tr}: $e');
      setState(() => _loadingState = LoadingState.error);
    }
  }
}
