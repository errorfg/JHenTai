import 'dart:io';

import 'package:clipboard/clipboard.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/mixin/scroll_to_top_logic_mixin.dart';
import 'package:jhentai/src/mixin/update_global_gallery_status_logic_mixin.dart';
import 'package:jhentai/src/setting/archive_bot_setting.dart';
import 'package:jhentai/src/widget/eh_archive_parse_source_select_dialog.dart';
import 'package:path/path.dart';

import '../../../../database/database.dart';
import '../../../../model/gallery_image.dart';
import '../../../../model/read_page_info.dart';
import '../../../../routes/routes.dart';
import '../../../../service/archive_download_service.dart';
import '../../../../service/log.dart';
import '../../../../service/path_service.dart';
import '../../../../service/read_progress_service.dart';
import '../../../../service/super_resolution_service.dart';
import '../../../../setting/read_setting.dart';
import '../../../../setting/super_resolution_setting.dart';
import '../../../../utils/process_util.dart';
import '../../../../utils/route_util.dart';
import '../../../../utils/toast_util.dart';
import '../../../../widget/eh_alert_dialog.dart';
import '../../../../widget/eh_download_dialog.dart';
import '../../../../widget/re_unlock_dialog.dart';
import '../basic/multi_select/multi_select_download_page_logic_mixin.dart';
import '../basic/multi_select/multi_select_download_page_state_mixin.dart';
import 'archive_download_page_state_mixin.dart';

mixin ArchiveDownloadPageLogicMixin on GetxController
    implements
        Scroll2TopLogicMixin,
        MultiSelectDownloadPageLogicMixin<ArchiveDownloadedData>,
        UpdateGlobalGalleryStatusLogicMixin {
  final String bodyId = 'bodyId';

  ArchiveDownloadPageStateMixin get archiveDownloadPageState;

  @override
  MultiSelectDownloadPageStateMixin get multiSelectDownloadPageState =>
      archiveDownloadPageState;

  Future<void> handleChangeArchiveGroup(ArchiveDownloadedData archive) async {
    String oldGroup =
        archiveDownloadService.archiveDownloadInfos[archive.gid]!.group;

    ({String group, bool downloadOriginalImage})? result = await Get.dialog(
      EHDownloadDialog(
        title: 'changeGroup'.tr,
        currentGroup: oldGroup,
        candidates: archiveDownloadService.allGroups,
      ),
    );

    if (result == null) {
      return;
    }

    String newGroup = result.group;
    if (newGroup == oldGroup) {
      return;
    }

    await archiveDownloadService.updateArchiveGroup(archive.gid, newGroup);
    update([bodyId]);
  }

  @override
  void handleTapItem(ArchiveDownloadedData item) {
    if (multiSelectDownloadPageState.inMultiSelectMode) {
      toggleSelectItem(item.gid);
    } else {
      goToReadPage(item);
    }
  }

  @override
  void handleLongPressOrSecondaryTapItem(
      ArchiveDownloadedData item, BuildContext context) {
    if (multiSelectDownloadPageState.inMultiSelectMode) {
      toggleSelectItem(item.gid);
    } else {
      showBottomSheet(item, context);
    }
  }

  Future<void> handleLongPressGroup(String groupName) {
    if (archiveDownloadService.archiveDownloadInfos.values
        .every((a) => a.group != groupName)) {
      return handleDeleteGroup(groupName);
    }
    return handleRenameGroup(groupName);
  }

  Future<void> handleRenameGroup(String oldGroup) async {
    ({String group, bool downloadOriginalImage})? result = await Get.dialog(
      EHDownloadDialog(
        title: 'renameGroup'.tr,
        currentGroup: oldGroup,
        candidates: archiveDownloadService.allGroups,
      ),
    );

    if (result == null) {
      return;
    }

    String newGroup = result.group;
    if (newGroup == oldGroup) {
      return;
    }

    return doRenameGroup(oldGroup, newGroup);
  }

  Future<void> doRenameGroup(String oldGroup, String newGroup) async {
    await archiveDownloadService.renameGroup(oldGroup, newGroup);
    update([bodyId]);
  }

  Future<void> handleDeleteGroup(String oldGroup) async {
    bool? success = await Get.dialog(EHDialog(title: 'deleteGroup'.tr + '?'));
    if (success == null || !success) {
      return;
    }

    await archiveDownloadService.deleteGroup(oldGroup);

    update([bodyId]);
  }

  void handleResumeAllTasks() {
    archiveDownloadService.resumeAllDownloadArchive();
  }

  void handlePauseAllTasks() {
    archiveDownloadService.pauseAllDownloadArchive();
  }

  Future<void> handleImportArchive() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'cbz'],
        allowMultiple: true,
        allowCompression: false,
        compressionQuality: 0,
      );
    } catch (e, s) {
      log.error('Pick archive import file failed', e, s);
      await _showArchiveImportReport([
        'Stage: pick files',
        'Error: ${e.runtimeType}: $e',
        'Stack:\n$s',
      ]);
      return;
    }

    if (result == null) {
      return;
    }

    if (result.files.isEmpty) {
      log.error('Pick archive import file failed, empty result');
      await _showArchiveImportReport([
        'Stage: pick files',
        'Error: FilePicker returned an empty result.',
      ]);
      return;
    }

    toast('loading'.tr);

    List<ArchiveDownloadedData> importedArchives = [];
    List<String> failedReports = [];
    int failedCount = 0;
    for (PlatformFile file in result.files) {
      List<String> debugMessages = [
        'File: ${file.name}',
        'Picker path: ${_safePlatformFilePath(file) ?? '<null>'}',
        'Picker identifier: ${file.identifier ?? '<null>'}',
        'Picker size: ${file.size}',
        'Picker bytes length: ${file.bytes?.length ?? '<null>'}',
        'Picker has readStream: ${file.readStream != null}',
      ];
      ({String path, bool temporary})? preparedFile;
      try {
        preparedFile = await _prepareArchiveImportFile(file, debugMessages);
      } catch (e, s) {
        log.error(
          'Prepare archive import file failed: name=${file.name}, path=${_safePlatformFilePath(file)}, identifier=${file.identifier}, size=${file.size}',
          e,
          s,
        );
        debugMessages.add('Prepare error: ${e.runtimeType}: $e');
        debugMessages.add('Prepare stack:\n$s');
      }

      if (preparedFile == null) {
        log.error(
            'Prepare archive import file failed, no usable content: name=${file.name}, path=${_safePlatformFilePath(file)}, identifier=${file.identifier}, size=${file.size}');
        debugMessages
            .add('Result: failed before import, no usable local file content.');
        failedReports.add(debugMessages.join('\n'));
        failedCount++;
        continue;
      }

      debugMessages.add('Prepared path: ${preparedFile.path}');
      debugMessages.add('Prepared is temporary: ${preparedFile.temporary}');
      ArchiveDownloadedData? archive;
      try {
        archive = await archiveDownloadService.importArchiveFile(
          preparedFile.path,
          fileName: file.name,
          debugMessages: debugMessages,
        );
      } catch (e, s) {
        log.error(
            'Import archive file failed unexpectedly: ${preparedFile.path}',
            e,
            s);
        debugMessages.add('Import unexpected error: ${e.runtimeType}: $e');
        debugMessages.add('Import unexpected stack:\n$s');
      } finally {
        if (preparedFile.temporary) {
          try {
            await File(preparedFile.path).delete();
            debugMessages
                .add('Temporary prepared file deleted: ${preparedFile.path}');
          } on Exception catch (_) {}
        }
      }

      if (archive == null) {
        failedReports.add(debugMessages.join('\n'));
        failedCount++;
      } else {
        importedArchives.add(archive);
      }
    }

    if (importedArchives.isNotEmpty) {
      await afterImportArchives(importedArchives);
      update([bodyId]);
      updateGlobalGalleryStatus();
    }

    if (failedCount == 0) {
      toast('${'success'.tr}: ${importedArchives.length}');
    } else {
      await _showArchiveImportReport([
        'Summary: ${'success'.tr}: ${importedArchives.length}, ${'failed'.tr}: $failedCount',
        ...failedReports,
      ]);
    }
  }

  Future<void> afterImportArchives(
      List<ArchiveDownloadedData> archives) async {}

  Future<({String path, bool temporary})?> _prepareArchiveImportFile(
    PlatformFile file,
    List<String> debugMessages,
  ) async {
    String? filePath = _safePlatformFilePath(file);
    if (filePath != null) {
      File pickedFile = File(filePath);
      bool exists = await pickedFile.exists();
      int? length = exists ? await pickedFile.length() : null;
      debugMessages.add('Path candidate exists: $exists');
      debugMessages.add('Path candidate length: ${length ?? '<unavailable>'}');
      if (exists && length != null && length > 0) {
        return (path: pickedFile.path, temporary: false);
      }
    }

    if (file.readStream != null) {
      File tempFile = await _createArchiveImportTempFile(file.name);
      debugMessages.add('Copying readStream to temp path: ${tempFile.path}');
      IOSink sink = tempFile.openWrite();
      await file.readStream!.pipe(sink);
      int length = await tempFile.length();
      debugMessages.add('readStream temp length: $length');
      if (length > 0) {
        return (path: tempFile.path, temporary: true);
      }
      await tempFile.delete();
      debugMessages.add('Deleted empty readStream temp file.');
      return null;
    }

    if (file.bytes != null) {
      File tempFile = await _createArchiveImportTempFile(file.name);
      debugMessages.add('Writing bytes to temp path: ${tempFile.path}');
      await tempFile.writeAsBytes(file.bytes!, flush: true);
      int length = await tempFile.length();
      debugMessages.add('Bytes temp length: $length');
      if (length > 0) {
        return (path: tempFile.path, temporary: true);
      }
      await tempFile.delete();
      debugMessages.add('Deleted empty bytes temp file.');
    }

    return null;
  }

  Future<File> _createArchiveImportTempFile(String name) async {
    String safeName = basename(name).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    File tempFile = File(join(pathService.tempDir.path,
        'archive_import_${DateTime.now().microsecondsSinceEpoch}_$safeName'));
    return tempFile.create(recursive: true);
  }

  String? _safePlatformFilePath(PlatformFile file) {
    try {
      return file.path;
    } catch (e) {
      return '<unavailable: ${e.runtimeType}: $e>';
    }
  }

  Future<void> _showArchiveImportReport(List<String> messages) async {
    String report = messages.join('\n\n---\n\n');
    BuildContext? context = Get.context;
    if (context == null) {
      toast(report, isShort: false);
      return;
    }

    await Get.dialog(
      AlertDialog(
        title: Text('failed'.tr),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.65,
            maxWidth: 640,
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              report,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await FlutterClipboard.copy(report);
              toast('hasCopiedToClipboard'.tr);
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: backRoute,
            child: Text('OK'.tr),
          ),
        ],
      ),
    );
  }

  void handleRemoveItem(ArchiveDownloadedData archive) {
    archiveDownloadService
        .update([archiveDownloadService.galleryCountChangedId]);
  }

  Future<void> goToReadPage(ArchiveDownloadedData archive) async {
    if (archiveDownloadService
            .archiveDownloadInfos[archive.gid]?.archiveStatus !=
        ArchiveStatus.completed) {
      return;
    }

    if (readSetting.useThirdPartyViewer.isTrue &&
        readSetting.thirdPartyViewerPath.value != null) {
      openThirdPartyViewer(archiveDownloadService.computeArchiveUnpackingPath(archive));
    } else {
      int readIndexRecord =
          await readProgressService.getReadProgress(archive.gid);

      List<GalleryImage> images =
          await archiveDownloadService.getUnpackedImages(archive.gid);

      toRoute(
        Routes.read,
        arguments: ReadPageInfo(
          mode: ReadMode.archive,
          gid: archive.gid,
          galleryTitle: archive.title,
          galleryUrl: archive.galleryUrl,
          initialIndex: readIndexRecord,
          pageCount: images.length,
          isOriginal: archive.isOriginal,
          readProgressRecordStorageKey: archive.gid.toString(),
          images: images,
          useSuperResolution: superResolutionService.get(
                  archive.gid, SuperResolutionType.archive) !=
              null,
        ),
      );
    }
  }

  void showBottomSheet(ArchiveDownloadedData archive, BuildContext context) {
    ArchiveDownloadInfo? archiveDownloadInfo =
        archiveDownloadService.archiveDownloadInfos[archive.gid];

    showCupertinoModalPopup(
      context: context,
      builder: (BuildContext context) => CupertinoActionSheet(
        actions: <CupertinoActionSheetAction>[
          if (superResolutionSetting.modelDirectoryPath.value != null &&
              (superResolutionService.get(
                          archive.gid, SuperResolutionType.archive) ==
                      null ||
                  superResolutionService
                          .get(archive.gid, SuperResolutionType.archive)
                          ?.status ==
                      SuperResolutionStatus.paused))
            CupertinoActionSheetAction(
              child: Text('superResolution'.tr),
              onPressed: () async {
                backRoute();

                if (superResolutionService.get(
                            archive.gid, SuperResolutionType.archive) ==
                        null &&
                    archive.isOriginal) {
                  bool? result = await Get.dialog(EHDialog(
                      title: 'attention'.tr + '!',
                      content: 'superResolveOriginalImageHint'.tr));
                  if (result == false) {
                    return;
                  }
                }

                superResolutionService.superResolve(
                    archive.gid, SuperResolutionType.archive);
              },
            ),
          if (superResolutionService
                  .get(archive.gid, SuperResolutionType.archive)
                  ?.status ==
              SuperResolutionStatus.running)
            CupertinoActionSheetAction(
              child: Text('stopSuperResolution'.tr),
              onPressed: () async {
                backRoute();

                superResolutionService
                    .pauseSuperResolve(archive.gid, SuperResolutionType.archive)
                    .then((_) => toast("success".tr));
              },
            ),
          if (superResolutionService
                      .get(archive.gid, SuperResolutionType.archive)
                      ?.status ==
                  SuperResolutionStatus.paused ||
              superResolutionService
                      .get(archive.gid, SuperResolutionType.archive)
                      ?.status ==
                  SuperResolutionStatus.success)
            CupertinoActionSheetAction(
              child: Text('deleteSuperResolvedImage'.tr),
              onPressed: () async {
                backRoute();

                superResolutionService
                    .deleteSuperResolve(
                        archive.gid, SuperResolutionType.archive)
                    .then((_) => toast("success".tr));
              },
            ),
          if (archiveDownloadInfo != null &&
              archiveDownloadInfo.archiveStatus.code <
                  ArchiveStatus.downloaded.code &&
              archiveDownloadInfo.parseSource == ArchiveParseSource.bot.code)
            CupertinoActionSheetAction(
              child: Text('changeParseSource2Official'.tr),
              onPressed: () {
                backRoute();
                changeParseSource(archive.gid, ArchiveParseSource.official);
              },
            ),
          if (archiveDownloadInfo != null &&
              archiveDownloadInfo.archiveStatus.code <
                  ArchiveStatus.downloaded.code &&
              archiveBotSetting.isReady &&
              archiveDownloadInfo.parseSource ==
                  ArchiveParseSource.official.code)
            CupertinoActionSheetAction(
              child: Text('changeParseSource2Bot'.tr),
              onPressed: () {
                backRoute();
                changeParseSource(archive.gid, ArchiveParseSource.bot);
              },
            ),
          CupertinoActionSheetAction(
            child: Text('changeGroup'.tr),
            onPressed: () {
              backRoute();
              handleChangeArchiveGroup(archive);
            },
          ),
          CupertinoActionSheetAction(
            child: Text('delete'.tr,
                style: TextStyle(color: UIConfig.alertColor(context))),
            onPressed: () {
              handleRemoveItem(archive);
              backRoute();
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

  Future<void> handleReUnlockArchive(ArchiveDownloadedData archive) async {
    bool? ok = await Get.dialog(const ReUnlockDialog());
    if (ok ?? false) {
      await archiveDownloadService.cancelArchive(archive.gid);
      await archiveDownloadService.downloadArchive(archive,
          resume: true, reParse: true);
    }
  }

  Future<void> handleMultiResumeTasks() async {
    for (int gid in multiSelectDownloadPageState.selectedGids) {
      archiveDownloadService.resumeDownloadArchive(gid);
    }

    exitSelectMode();
  }

  Future<void> handleMultiPauseTasks() async {
    for (int gid in multiSelectDownloadPageState.selectedGids) {
      archiveDownloadService.pauseDownloadArchive(gid);
    }

    exitSelectMode();
  }

  Future<void> handleMultiChangeGroup() async {
    ({String group, bool downloadOriginalImage})? result = await Get.dialog(
      EHDownloadDialog(
        title: 'changeGroup'.tr,
        candidates: archiveDownloadService.allGroups,
      ),
    );

    if (result == null) {
      return;
    }

    String newGroup = result.group;

    for (int gid in multiSelectDownloadPageState.selectedGids) {
      await archiveDownloadService.updateArchiveGroup(gid, newGroup);
    }

    multiSelectDownloadPageState.inMultiSelectMode = false;
    multiSelectDownloadPageState.selectedGids.clear();
    updateSafely([bottomAppbarId, bodyId]);
  }

  Future<void> handleMultiDelete() async {
    bool? result = await Get.dialog(
      EHDialog(title: 'delete'.tr, content: 'multiDeleteHint'.tr),
    );

    if (result == true) {
      List<Future> futures = [];

      for (int gid in multiSelectDownloadPageState.selectedGids) {
        futures.add(archiveDownloadService.deleteArchive(gid));
      }

      exitSelectMode();

      await Future.wait(futures);
      updateGlobalGalleryStatus();
    }
  }

  Future<void> handleChangeParseSource() async {
    ArchiveParseSource? result =
        await Get.dialog(const EHArchiveParseSourceSelectDialog());

    if (result == null) {
      return;
    }

    for (int gid in multiSelectDownloadPageState.selectedGids) {
      await archiveDownloadService.changeParseSource(gid, result);
    }

    multiSelectDownloadPageState.inMultiSelectMode = false;
    multiSelectDownloadPageState.selectedGids.clear();
    updateSafely([bottomAppbarId, bodyId]);
  }

  Future<void> changeParseSource(
      int gid, ArchiveParseSource parseSource) async {
    return archiveDownloadService.changeParseSource(gid, parseSource);
  }
}
