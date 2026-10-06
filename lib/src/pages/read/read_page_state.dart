import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/mixin/scroll_status_listener_state.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/setting/site_setting.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../model/gallery_image.dart';
import '../../model/gallery_thumbnail.dart';
import '../../service/gallery_download_service.dart';
import '../../setting/read_setting.dart';
import '../../widget/loading_state_indicator.dart';

class ReadPageState with ScrollStatusListerState {
  /// gallery info
  final ReadPageInfo readPageInfo = Get.arguments;

  /// property used for parsing and loading
  int thumbnailsCountPerPage = SiteSetting.thumbnailsCountPerPage.value;
  late List<GalleryThumbnail?> thumbnails;
  late List<GalleryImage?> images;

  late List<LoadingState> parseImageHrefsStates;
  late List<LoadingState> parseImageUrlStates;
  late List<Size?> imageContainerSizes;
  String? parseImageHrefErrorMsg;
  late List<String?> parseImageUrlErrorMsg;

  bool autoMode = false;
  bool isMenuOpen = false;
  bool showTapZoneGuide = false;
  Battery battery = Battery();
  int batteryLevel = 100;
  bool useSuperResolution = false;
  bool displayFirstPageAlone = readSetting.displayFirstPageAlone.value;
  FocusNode focusNode = FocusNode();

  late Size displayRegionSize;

  final ItemPositionsListener thumbnailPositionsListener = ItemPositionsListener.create();
  final ItemScrollController thumbnailsScrollController = ItemScrollController();
  final ScrollOffsetController thumbnailsScrollOffsetController = ScrollOffsetController();

  /// The books being read, in order; the first is the one the reader was
  /// opened with, later ones are appended as reading goes on.
  late final List<ReadSegment> segments;

  ReadPageState() {
    segments = <ReadSegment>[ReadSegment(info: readPageInfo, start: 0, pageCount: readPageInfo.pageCount)];
    thumbnails = _pagesOf(readPageInfo.thumbnails, readPageInfo.pageCount);

    if (readPageInfo.mode == ReadMode.online) {
      images = _pagesOf(readPageInfo.images, readPageInfo.pageCount);
    }

    if (readPageInfo.mode == ReadMode.downloaded) {
      images = galleryDownloadService.galleryDownloadInfos[readPageInfo.gid]!.images;
    }

    if (readPageInfo.mode == ReadMode.archive || readPageInfo.mode == ReadMode.local || readPageInfo.mode == ReadMode.remote) {
      images = List<GalleryImage?>.of(readPageInfo.images!);
    }

    parseImageHrefsStates = List.generate(readPageInfo.pageCount, (_) => LoadingState.idle);
    parseImageUrlStates = List.generate(readPageInfo.pageCount, (_) => LoadingState.idle);
    imageContainerSizes = List.generate(readPageInfo.pageCount, (_) => null);
    parseImageUrlErrorMsg = List.generate(readPageInfo.pageCount, (_) => null);

    useSuperResolution = readPageInfo.useSuperResolution;
  }

  /// [known] padded with nulls to [pageCount], in a list that can grow.
  static List<T?> _pagesOf<T>(List<T?>? known, int pageCount) =>
      List<T?>.generate(pageCount, (int i) => known != null && i < known.length ? known[i] : null);

  /// The book page [index] of the reader belongs to.
  ReadSegment segmentAt(int index) {
    for (int i = segments.length - 1; i > 0; i--) {
      if (index >= segments[i].start) {
        return segments[i];
      }
    }
    return segments.first;
  }

  /// Whether [info] can follow the books being read in this reader: same
  /// kind of source, its pages reachable by index.
  bool canAppend(ReadPageInfo info) {
    if (info.mode != readPageInfo.mode || info.pageCount <= 0) {
      return false;
    }
    return switch (readPageInfo.mode) {
      ReadMode.online => info.thumbnails != null || info.galleryUrl != null,
      ReadMode.remote => info.images != null,
      _ => false,
    };
  }

  /// Puts the pages of [info] after the last book; pages already there keep
  /// their index.
  ReadSegment appendSegment(ReadPageInfo info) {
    final int count = info.pageCount;
    final ReadSegment segment = ReadSegment(info: info, start: readPageInfo.pageCount, pageCount: count);
    segments.add(segment);
    thumbnails.addAll(_pagesOf(info.thumbnails, count));
    images.addAll(_pagesOf(info.images, count));
    parseImageHrefsStates.addAll(List.generate(count, (_) => LoadingState.idle));
    parseImageUrlStates.addAll(List.generate(count, (_) => LoadingState.idle));
    imageContainerSizes.addAll(List.generate(count, (_) => null));
    parseImageUrlErrorMsg.addAll(List.generate(count, (_) => null));
    readPageInfo.pageCount += count;
    return segment;
  }
}
