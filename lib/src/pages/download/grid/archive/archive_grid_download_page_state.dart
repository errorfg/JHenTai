import 'package:jhentai/src/service/archive_download_service.dart';

import '../../../../database/database.dart';
import '../../../../mixin/scroll_to_top_state_mixin.dart';
import '../../mixin/archive/archive_download_page_state_mixin.dart';
import '../../mixin/basic/multi_select/multi_select_download_page_state_mixin.dart';
import '../mixin/grid_download_page_state_mixin.dart';

class ArchiveGridDownloadPageState with Scroll2TopStateMixin, MultiSelectDownloadPageStateMixin, ArchiveDownloadPageStateMixin, GridBasePageState {
  final bool readerMode;

  ArchiveGridDownloadPageState({this.readerMode = false});

  @override
  List<String> get allRootGroups {
    if (!readerMode) {
      return archiveDownloadService.allGroups;
    }

    return archiveDownloadService.allGroups.where((group) => galleryObjectsWithGroup(group).isNotEmpty).toList();
  }

  @override
  List<ArchiveDownloadedData> galleryObjectsWithGroup(String groupName) =>
      archiveDownloadService.archives.where((archive) => archiveDownloadService.archiveDownloadInfos[archive.gid]?.group == groupName && _shouldShowArchive(archive)).toList();

  bool _shouldShowArchive(ArchiveDownloadedData archive) => archiveDownloadService.isImportedArchive(archive) == readerMode;
}
