import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:executor/executor.dart';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/exception/eh_parse_exception.dart';
import 'package:jhentai/src/exception/eh_site_exception.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/tap_zone_config.dart';
import 'package:jhentai/src/pages/read/layout/base/base_layout_logic.dart';
import 'package:jhentai/src/pages/read/layout/horizontal_double_column/horizontal_double_column_layout_logic.dart';
import 'package:jhentai/src/pages/read/layout/horizontal_list/horizontal_list_layout_logic.dart';
import 'package:jhentai/src/pages/read/layout/horizontal_page/horizontal_page_layout_logic.dart';
import 'package:jhentai/src/pages/read/layout/vertical_list/vertical_list_layout_logic.dart';
import 'package:jhentai/src/pages/read/read_page_state.dart';
import 'package:jhentai/src/service/super_resolution_service.dart';
import 'package:jhentai/src/service/volume_service.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/utils/eh_executor.dart';
import 'package:retry/retry.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:throttling/throttling.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../model/detail_page_info.dart';
import '../../model/gallery_image.dart';
import '../../setting/super_resolution_setting.dart';
import '../../service/sr/realtime_sr_service.dart';
import '../../service/gallery_download_service.dart';
import '../../network/jm/jm_image.dart';
import '../../model/read_page_info.dart';
import '../../network/eh_request.dart';
import '../../routes/routes.dart';
import '../../service/local_config_service.dart';
import '../../service/log.dart';
import '../../service/read_progress_service.dart';
import '../../service/sync_service.dart';
import '../../setting/preference_setting.dart';
import '../../setting/read_setting.dart';
import '../../utils/eh_spider_parser.dart';
import '../../utils/route_util.dart';
import '../../utils/toast_util.dart';
import '../../widget/auto_mode_interval_dialog.dart';
import '../../widget/eh_image.dart';
import '../../widget/loading_state_indicator.dart';
import '../home_page.dart';
import '../setting/read/tap_zone/setting_tap_zone_page.dart';
import '../setting/keyboard_shortcuts/setting_keyboard_shortcuts_page.dart';
import '../setting/read/setting_read_page.dart';

/// Whether a scrolling layout shows the end of the book: at least half of
/// the last image is on screen, or its trailing edge is (an image over twice
/// the screen's size never shows half of itself at once). Requiring the
/// trailing edge alone left the book one page short whenever the last screen
/// showed several pages and the list was not pulled all the way to its end.
/// The tolerance absorbs rounding when the list is scrolled exactly to its
/// end.
bool listShowsEnd(Iterable<ItemPosition> visible, int pageCount) {
  return visible.any((ItemPosition item) {
    if (item.index != pageCount - 1) {
      return false;
    }
    if (item.itemTrailingEdge <= 1.005) {
      return true;
    }
    final double extent = item.itemTrailingEdge - item.itemLeadingEdge;
    final double shown = min(item.itemTrailingEdge, 1) - max(item.itemLeadingEdge, 0);
    return extent > 0 && shown >= extent / 2;
  });
}

/// The index persisted as read progress: the last page once the end of the
/// book is shown, otherwise the first visible image. Recording the first
/// visible image alone would leave a finished book one page short whenever the
/// last screen shows more than one page.
int progressIndexFor({
  required int currentIndex,
  required bool reachedEnd,
  required int pageCount,
}) {
  return reachedEnd && pageCount > 0 ? pageCount - 1 : currentIndex;
}

typedef PersistReadProgress = Future<void> Function(int imageIndex);
typedef SyncReadProgress = Future<void> Function();
typedef ReadProgressFlushErrorHandler =
    void Function(Object error, StackTrace stack);

/// Serializes local read-progress writes while keeping remote source reports
/// completely off the local durability path.
///
/// Local writes retain their call order, so the Future returned from
/// [schedule] completes only after that exact index is durable. Remote reports
/// use a latest-wins trailing edge: while one report is in flight, repeated
/// schedules replace the single pending index instead of building a backlog.
class ReadProgressFlushCoordinator {
  ReadProgressFlushCoordinator({
    required this.persist,
    this.report,
    this.onPersistError,
    this.onReportError,
  });

  final PersistReadProgress persist;
  final ReadProgressReporter? report;
  final ReadProgressFlushErrorHandler? onPersistError;
  final ReadProgressFlushErrorHandler? onReportError;

  Future<void> _localTail = Future<void>.value();
  int? _lastPersistedIndex;

  int? _lastReportedIndex;
  int? _pendingReportIndex;
  bool _reportInFlight = false;
  Future<void>? _reportDrainFuture;

  Future<void> schedule(int imageIndex) {
    final Future<void> operation = _localTail.then((_) async {
      if (_lastPersistedIndex == imageIndex) {
        return;
      }
      await persist(imageIndex);
      _lastPersistedIndex = imageIndex;
    });

    // Keep the internal tail usable after an error, while returning the raw
    // operation Future so a final flush can refuse to sync when persistence
    // failed. Attaching this handler immediately also prevents ignored timer
    // Futures from becoming unhandled asynchronous errors.
    _localTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _notifyError(onPersistError, error, stack);
      },
    );

    // Preserve the old local-before-report ordering without making the local
    // Future wait for network I/O. A failed local write is never reported as
    // successfully read to the source server.
    unawaited(
      operation.then<void>(
        (_) => _queueReport(imageIndex),
        onError: (Object _, StackTrace __) {},
      ),
    );

    return operation;
  }

  /// Persists the final reader index before invoking the app-level sync.
  ///
  /// If persistence fails, [sync] is deliberately not invoked and the
  /// persistence error is forwarded to the caller.
  Future<void> flushFinalAndSync(
    int imageIndex, {
    required SyncReadProgress sync,
  }) async {
    await schedule(imageIndex);
    await sync();
  }

  void _queueReport(int imageIndex) {
    if (report == null) {
      return;
    }
    if (!_reportInFlight && _lastReportedIndex == imageIndex) {
      return;
    }

    _pendingReportIndex = imageIndex;
    if (_reportInFlight) {
      return;
    }

    _reportInFlight = true;
    _reportDrainFuture = _drainReports();
    // _drainReports catches both reporter and error-handler failures, so this
    // detached Future cannot surface an unhandled asynchronous error.
    unawaited(_reportDrainFuture!);
  }

  Future<void> _drainReports() async {
    try {
      while (_pendingReportIndex != null) {
        final int imageIndex = _pendingReportIndex!;
        _pendingReportIndex = null;

        if (_lastReportedIndex == imageIndex) {
          continue;
        }

        try {
          await report!(imageIndex);
          _lastReportedIndex = imageIndex;
        } catch (error, stack) {
          _notifyError(onReportError, error, stack);
        }
      }
    } catch (error, stack) {
      _notifyError(onReportError, error, stack);
    } finally {
      _reportInFlight = false;
      if (_pendingReportIndex != null) {
        _queueReport(_pendingReportIndex!);
      }
    }
  }

  /// Waits for the currently queued reports. Intended for deterministic tests;
  /// reader shutdown deliberately does not await remote reporting.
  Future<void> waitForRemoteReports() async {
    while (_reportInFlight || _pendingReportIndex != null) {
      final Future<void>? drain = _reportDrainFuture;
      if (drain == null) {
        await Future<void>.delayed(Duration.zero);
      } else {
        await drain;
      }
    }
  }

  void _notifyError(
    ReadProgressFlushErrorHandler? handler,
    Object error,
    StackTrace stack,
  ) {
    try {
      handler?.call(error, stack);
    } catch (_) {
      // Error reporting must never break either queue.
    }
  }
}

/// The reader's controllers are registered by type; a reader opened right
/// after another must not start until the previous one has released them.
Future<void> waitForReaderDisposed() async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
  while (Get.isRegistered<ReadPageLogic>() &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

class ReadPageLogic extends GetxController with WidgetsBindingObserver {
  final String pageId = 'pageId';
  final String layoutId = 'layoutId';
  final String onlineImageId = 'onlineImageId';
  final String parseImageHrefsStateId = 'parseImageHrefsStateId';
  final String parseImageUrlStateId = 'parseImageUrlStateId';
  final String autoModeId = 'autoModeId';
  final String batteryId = 'batteryId';
  final String currentTimeId = 'currentTimeId';
  final String topMenuId = 'topMenuId';
  final String bottomMenuId = 'bottomMenuId';
  final String rightBottomInfoId = 'rightBottomInfoId';
  final String pageNoId = 'pageNoId';
  final String thumbnailNoId = 'thumbnailsId';
  final String sliderId = 'sliderId';
  final String endOfBookId = 'endOfBookId';
  final String tapZoneId = 'tapZoneId';
  final String guideOverlayId = 'guideOverlayId';

  ReadPageState state = ReadPageState();

  BaseLayoutLogic get layoutLogic => effectiveReadDirection == ReadDirection.top2bottomList
      ? Get.find<VerticalListLayoutLogic>()
      : isInListReadDirection
      ? Get.find<HorizontalListLayoutLogic>()
      : isInDoubleColumnReadDirection
      ? Get.find<HorizontalDoubleColumnLayoutLogic>()
      : Get.find<HorizontalPageLayoutLogic>();

  late Timer refreshCurrentTimeAndBatteryLevelTimer;
  late Timer flushReadProgressTimer;

  late Worker toggleTurnPageByVolumeKeyLister;
  late Worker toggleCurrentImmersiveModeLister;
  late Worker toggleDeviceOrientationLister;
  late Worker readDirectionLister;
  late Worker imageSpaceLister;
  late Worker displayFirstPageAloneListener;
  late Worker enableCustomBrightnessListener;
  late Worker customBrightnessListener;
  late Worker preloadListener;
  late Worker enableBottomMenuListener;
  late Worker orientationSpecificReadDirectionLister;
  late Worker portraitReadDirectionLister;
  late Worker landscapeReadDirectionLister;
  late Worker portraitImageRegionWidthRatioLister;
  late Worker landscapeImageRegionWidthRatioLister;
  late Worker portraitDisplayFirstPageAloneListener;
  late Worker landscapeDisplayFirstPageAloneListener;
  late Worker autoDetectWebtoonListener;
  late Worker tapZoneConfigListener;

  /// Tracks the last known portrait state for orientation-specific read direction
  bool? _lastIsPortrait;

  /// limit the rate of parsing to decrease the lagging of build
  final EHExecutor executor = EHExecutor(
    concurrency: 100,
    rate: const Rate(10, Duration(milliseconds: 1000)),
  );
  final Throttling _thr = Throttling(
    duration: const Duration(milliseconds: 200),
  );

  final int normalPriority = 10000;

  bool inited = false;
  bool _reachedEnd = false;
  bool _openingSibling = false;
  Completer<void> delayInitCompleter = Completer<void>();

  /// The book being read, of [ReadPageState.segments].
  late ReadSegment _currentSegment = state.segments.first;

  /// Whether no book follows the last one appended.
  bool _noNextSegment = false;

  /// Progress writes of each book, by its progress key.
  final Map<String, ReadProgressFlushCoordinator> _progressFlushCoordinators = {};

  /// Pages left below the last visible one when the next book is fetched.
  static const int _appendAhead = 3;

  /// Pages whose upscaled copy is being made, and pages left as they are
  /// (animated, wide enough, failed), which are not asked for again.
  final Set<int> _srInFlight = <int>{};
  final Set<int> _srSkipped = <int>{};

  /// Whether pages are upscaled as they are read: on a desktop, switched
  /// on, with the upscaler of the chosen model installed. Wherever the pages
  /// come from: a site, a Komga server, files.
  bool get realtimeSrOn => _realtimeSrApplies && realtimeSrService.active;

  /// Shown in the reader's menu where upscaling while reading can be used.
  bool get canUseRealtimeSr => GetPlatform.isDesktop && _realtimeSrApplies;

  /// Not while the reader shows the copy of a downloaded gallery or archive
  /// that was upscaled as a whole: those pages are upscaled already.
  bool get _realtimeSrApplies => !state.useSuperResolution;

  Future<void> toggleRealtimeSr() async {
    final bool enable = !superResolutionSetting.realtimeEnabled.value;
    if (enable && !realtimeSrService.available) {
      toast('realtimeSrNotInstalled'.tr, isShort: false);
      return;
    }
    await superResolutionSetting.saveRealtimeEnabled(enable);
    log.info('toggle real-time super resolution: $enable');
    updateSafely([topMenuId]);
    // Rebuilt pages show their upscaled copy, or go back to the original.
    layoutLogic.updateSafely([BaseLayoutLogic.pageId]);
    requestRealtimeSrAhead();
  }

  /// Where page [index] comes from, for the upscaler: a key naming it, the
  /// strips of a JM page, and its encoded bytes. Null until the page's
  /// address is known.
  ({String key, int strips, Future<Uint8List?> Function() load})? _srSource(int index) {
    final GalleryImage? image = index < state.images.length ? state.images[index] : null;
    if (image == null) {
      return null;
    }
    // A page of a download that is still running is not there yet; it is
    // never fetched from its site here.
    if (state.readPageInfo.mode == ReadMode.downloaded && image.downloadStatus != DownloadStatus.downloaded) {
      return null;
    }
    if (image.path != null) {
      // A page on disk: of a download (a JM page was restored when saved), an
      // archive, a downloaded Komga book, a local gallery.
      final String path = GalleryDownloadService.computeImageDownloadAbsolutePathFromRelativePath(image.path!);
      return (key: path, strips: 0, load: () => io.File(path).readAsBytes());
    }
    final String requestUrl = JmImage.requestUrl(image.url);
    // From the image cache when the page was shown, else downloaded into it:
    // with the headers and under the cache key the page is shown with (a
    // Komga server wants its login).
    return (
      key: requestUrl,
      strips: JmImage.stripsOf(image.url),
      load: () => ExtendedNetworkImageProvider(requestUrl, headers: image.headers, cacheKey: image.cacheKey, cache: true).getNetworkImageData(),
    );
  }

  /// The upscaled copy of page [index] (encoded), when it is ready.
  Uint8List? upscaledPage(int index) {
    final ({String key, int strips, Future<Uint8List?> Function() load})? source = _srSource(index);
    return source == null ? null : realtimeSrService.cached(source.key);
  }

  /// Asks for the upscaled copy of page [index] unless it is there, being
  /// made, or the page is left as it is; the page is rebuilt with it once
  /// it is ready and decoded.
  void requestRealtimeSr(int index) {
    if (!realtimeSrOn || _srSkipped.contains(index) || _srInFlight.contains(index)) {
      return;
    }
    final ({String key, int strips, Future<Uint8List?> Function() load})? source = _srSource(index);
    if (source == null || realtimeSrService.cached(source.key) != null) {
      return;
    }

    _srInFlight.add(index);
    unawaited(
      realtimeSrService.upscale(sourceKey: source.key, position: index, strips: source.strips, loadEncoded: source.load).then(
        (Uint8List? bytes) async {
          _srInFlight.remove(index);
          if (isClosed) {
            return;
          }
          if (bytes == null) {
            _srSkipped.add(index);
            return;
          }
          // Decoded before the page switches to it, so the switch does not
          // show a loading page in between.
          final BuildContext? context = Get.context;
          if (context != null && context.mounted) {
            await precacheImage(ExtendedMemoryImageProvider(bytes), context);
          }
          if (!isClosed) {
            updateSafely(['$onlineImageId::$index']);
          }
        },
        onError: (Object e, StackTrace s) {
          _srInFlight.remove(index);
          log.error('Upscale page $index failed', e, s);
        },
      ),
    );
  }

  /// End of the pages to have upscaled ahead of the reader's page: at least
  /// a batch (or the preload setting, when larger) ahead, rounded up to a
  /// whole number of batches, so that pages come due a batch at a time
  /// rather than one with each page turned.
  int get _srAheadEnd {
    final int batch = realtimeSrService.batchSize;
    final int ahead = max(readSetting.preloadPageCount.value, batch);
    final int end = ((state.readPageInfo.currentImageIndex + 1 + ahead) / batch).ceil() * batch;
    return min(end, state.readPageInfo.pageCount);
  }

  /// Fetches and upscales the pages up to [_srAheadEnd] that are not there
  /// yet, whether or not the layout has built them.
  void requestRealtimeSrAhead() {
    if (!realtimeSrOn) {
      return;
    }
    for (int index = state.readPageInfo.currentImageIndex; index < _srAheadEnd; index++) {
      _ensureRealtimeSr(index);
    }
  }

  /// Page [index] on its way to being upscaled: its address is looked up
  /// first when it is not known (the lookups call back here), then its
  /// upscaled copy asked for.
  void _ensureRealtimeSr(int index) {
    if (!realtimeSrOn || index < state.readPageInfo.currentImageIndex || index >= _srAheadEnd) {
      return;
    }
    if (state.images[index] != null) {
      requestRealtimeSr(index);
    } else if (state.readPageInfo.mode != ReadMode.online) {
      // A page a download has not reached: asked for when it is shown.
      return;
    } else if (state.thumbnails[index] == null) {
      if (state.parseImageHrefsStates[index] == LoadingState.idle) {
        beginToParseImageHref(index);
      }
    } else if (state.parseImageUrlStates[index] == LoadingState.idle) {
      beginToParseImageUrl(index, false);
    }
  }

  ReadProgressFlushCoordinator _flushCoordinatorOf(ReadSegment segment) {
    final ReadPageInfo info = segment.info;
    return _progressFlushCoordinators.putIfAbsent(
      info.readProgressRecordStorageKey,
      () => ReadProgressFlushCoordinator(
        persist: (int imageIndex) => readProgressService.updateReadProgress(
          info.readProgressRecordStorageKey,
          imageIndex,
        ),
        report: info.reportReadProgress,
        onPersistError: (Object error, StackTrace stack) {
          log.error('Flush read progress failed', error, stack);
        },
        onReportError: (Object error, StackTrace stack) {
          log.error('Report read progress failed', error, stack);
        },
      ),
    );
  }

  @override
  void onReady() {
    super.onReady();

    WidgetsBinding.instance.addObserver(this);

    Timer(const Duration(milliseconds: 120), () {
      if (inited && !delayInitCompleter.isCompleted) {
        delayInitCompleter.complete();
      }
    });

    /// Turn page by volume keys. The reason for not use [KeyboardListener]: https://github.com/flutter/flutter/issues/71144
    listen2VolumeKeys();

    applyCurrentImmersiveMode();

    updateDeviceOrientation();

    /// Listen to turn page by volume key change
    toggleTurnPageByVolumeKeyLister = ever(
      readSetting.enablePageTurnByVolumeKeys,
      (_) => listen2VolumeKeys(),
    );

    /// Listen to immersive mode change
    toggleCurrentImmersiveModeLister = ever(
      readSetting.enableImmersiveMode,
      (_) => applyCurrentImmersiveMode(),
    );

    /// Listen to device orientation change
    toggleDeviceOrientationLister = ever(
      readSetting.deviceDirection,
      (_) => updateDeviceOrientation(),
    );

    /// Listen to read direction change
    readDirectionLister = ever(
      readSetting.readDirection,
      (_) => onEffectiveSettingChanged(),
    );

    imageSpaceLister = ever(readSetting.imageSpace, (_) {
      updateSafely([layoutId]);
    });

    displayFirstPageAloneListener = ever(
      readSetting.displayFirstPageAlone,
      (_) => _syncDisplayFirstPageAloneToState(),
    );
    portraitDisplayFirstPageAloneListener = ever(
      readSetting.portraitDisplayFirstPageAlone,
      (_) {
        if (readSetting.enableOrientationSpecificReadDirection.isTrue &&
            isPortrait) {
          _syncDisplayFirstPageAloneToState();
        }
      },
    );
    landscapeDisplayFirstPageAloneListener = ever(
      readSetting.landscapeDisplayFirstPageAlone,
      (_) {
        if (readSetting.enableOrientationSpecificReadDirection.isTrue &&
            !isPortrait) {
          _syncDisplayFirstPageAloneToState();
        }
      },
    );

    /// Listen to orientation-specific settings changes for rebuild
    orientationSpecificReadDirectionLister = ever(
      readSetting.enableOrientationSpecificReadDirection,
      (_) => onEffectiveSettingChanged(),
    );
    portraitReadDirectionLister = ever(readSetting.portraitReadDirection, (_) {
      if (readSetting.enableOrientationSpecificReadDirection.isTrue &&
          isPortrait) {
        onEffectiveSettingChanged();
      }
    });
    landscapeReadDirectionLister = ever(readSetting.landscapeReadDirection, (
      _,
    ) {
      if (readSetting.enableOrientationSpecificReadDirection.isTrue &&
          !isPortrait) {
        onEffectiveSettingChanged();
      }
    });
    autoDetectWebtoonListener = ever(readSetting.autoDetectWebtoon, (_) => onEffectiveSettingChanged());
    portraitImageRegionWidthRatioLister = ever(readSetting.portraitImageRegionWidthRatio, (_) {
      if (readSetting.enableOrientationSpecificReadDirection.isTrue && isPortrait) {
        updateSafely([layoutId]);
      }
    });
    landscapeImageRegionWidthRatioLister = ever(readSetting.landscapeImageRegionWidthRatio, (_) {
      if (readSetting.enableOrientationSpecificReadDirection.isTrue && !isPortrait) {
        updateSafely([layoutId]);
      }
    });

    if (!GetPlatform.isDesktop) {
      state.battery.batteryLevel.then((value) => state.batteryLevel = value);
    }

    /// refresh current time and battery level info
    refreshCurrentTimeAndBatteryLevelTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!GetPlatform.isDesktop) {
          state.battery.batteryLevel.then((value) {
            state.batteryLevel = value;
            update([batteryId]);
          });
        }
        update([currentTimeId]);
      },
    );

    flushReadProgressTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _scheduleReadProgressFlush(),
    );

    if (readSetting.keepScreenAwakeWhenReading.isTrue) {
      WakelockPlus.enable();
    }

    if (GetPlatform.isMobile && readSetting.enableCustomReadBrightness.isTrue) {
      applyCurrentBrightness();
    }
    enableCustomBrightnessListener = ever(
      readSetting.enableCustomReadBrightness,
      (_) {
        if (GetPlatform.isMobile &&
            readSetting.enableCustomReadBrightness.isTrue) {
          applyCurrentBrightness();
        } else {
          resetBrightness();
        }
      },
    );
    customBrightnessListener = ever(readSetting.customBrightness, (_) {
      applyCurrentBrightness();
    });

    enableBottomMenuListener = ever(readSetting.enableBottomMenu, (_) {
      updateSafely([topMenuId]);
    });

    preloadListener = everAll([
      readSetting.preloadPageCountLocal,
      readSetting.preloadPageCount,
      readSetting.preloadDistanceLocal,
      readSetting.preloadDistance,
    ], (_) => updateSafely([layoutId]));

    _syncDisplayFirstPageAloneToState();

    tapZoneConfigListener = ever(readSetting.tapZoneConfigJson, (_) => updateSafely([tapZoneId]));

    _maybeShowTapZoneGuide();

    unawaited(_notifyShown(state.segments.first));

    realtimeSrService.focus = () => state.readPageInfo.currentImageIndex;
    requestRealtimeSrAhead();

    inited = true;
    if (!delayInitCompleter.isCompleted) {
      delayInitCompleter.complete();
    }
  }

  Future<void> _maybeShowTapZoneGuide() async {
    String? shown = await localConfigService.read(configKey: ConfigEnum.tapZoneGuideShown);
    if (shown != null) {
      return;
    }
    state.showTapZoneGuide = true;
    updateSafely([guideOverlayId]);
  }

  void dismissTapZoneGuide() {
    state.showTapZoneGuide = false;
    update([guideOverlayId]);
    localConfigService.write(configKey: ConfigEnum.tapZoneGuideShown, value: 'true');
  }

  @override
  void onClose() {
    super.onClose();

    WidgetsBinding.instance.removeObserver(this);

    state.focusNode.dispose();
    refreshCurrentTimeAndBatteryLevelTimer.cancel();
    toggleTurnPageByVolumeKeyLister.dispose();
    toggleCurrentImmersiveModeLister.dispose();
    readDirectionLister.dispose();
    imageSpaceLister.dispose();
    flushReadProgressTimer.cancel();
    displayFirstPageAloneListener.dispose();
    enableCustomBrightnessListener.dispose();
    customBrightnessListener.dispose();
    preloadListener.dispose();
    enableBottomMenuListener.dispose();
    orientationSpecificReadDirectionLister.dispose();
    portraitReadDirectionLister.dispose();
    landscapeReadDirectionLister.dispose();
    portraitImageRegionWidthRatioLister.dispose();
    landscapeImageRegionWidthRatioLister.dispose();
    portraitDisplayFirstPageAloneListener.dispose();
    landscapeDisplayFirstPageAloneListener.dispose();
    autoDetectWebtoonListener.dispose();
    tapZoneConfigListener.dispose();

    restoreVolumeListener();

    restoreImmersiveMode();

    restoreDeviceOrientation();

    unawaited(_flushReadProgressAndSync());

    realtimeSrService
      ..clearPending()
      ..focus = null;

    if (readSetting.enableCustomReadBrightness.isTrue) {
      resetBrightness();
    }

    Get.delete<VerticalListLayoutLogic>(force: true);
    Get.delete<HorizontalListLayoutLogic>(force: true);
    Get.delete<HorizontalPageLayoutLogic>(force: true);
    Get.delete<HorizontalDoubleColumnLayoutLogic>(force: true);

    executor.close();

    WakelockPlus.disable();

    EHImageAnimationGateRegistry.clear();
  }

  void beginToParseImageHref(int index) {
    if (state.parseImageHrefsStates[index] == LoadingState.loading) {
      return;
    }

    state.parseImageHrefsStates[index] = LoadingState.loading;
    updateSafely(['$parseImageHrefsStateId::$index']);

    /// limit the rate of parsing to decrease the lagging of build
    executor.scheduleTask(normalPriority, () => parseImageHref(index));
  }

  Future<void> parseImageHref(int index) async {
    log.trace(
      'Begin to load Thumbnail $index with page size: ${state.thumbnailsCountPerPage}',
    );

    // Pages are numbered within their own book.
    final ReadSegment segment = state.segmentAt(index);
    final int pageInBook = index - segment.start;
    int requestPageIndex = pageInBook ~/ state.thumbnailsCountPerPage;

    DetailPageInfo detailPageInfo;
    try {
      detailPageInfo = await retry(
        () => ehRequest.requestDetailPage(
          galleryUrl: segment.info.galleryUrl!,
          thumbnailsPageIndex: requestPageIndex,
          parser: EHSpiderParser.detailPage2RangeAndThumbnails,
        ),
        maxAttempts: 3,
        retryIf: (e) => e is DioException,
        onRetry: (e) =>
            log.error('Get thumbnails error!', (e as DioException).errorMsg),
      );
    } on DioException catch (_) {
      state.parseImageHrefErrorMsg = 'parsePageFailed'.tr;
      state.parseImageHrefsStates[index] = LoadingState.error;
      update(['$parseImageHrefsStateId::$index']);
      return;
    } on EHSiteException catch (e) {
      state.parseImageHrefErrorMsg = e.message;
      state.parseImageHrefsStates[index] = LoadingState.error;
      update(['$parseImageHrefsStateId::$index']);
      return;
    }

    state.parseImageHrefsStates[index] = LoadingState.idle;

    /// some gallery's [thumbnailsCountPerPage] is not equal to default setting, we need to compute and update it.
    /// For example, default setting is 40, but some gallerys' thumbnails has only high quality thumbnails, which results in 20.
    bool thumbnailsCountPerPageChanged =
        state.thumbnailsCountPerPage != detailPageInfo.thumbnailsCountPerPage;
    state.thumbnailsCountPerPage = detailPageInfo.thumbnailsCountPerPage;

    for (
      int i = detailPageInfo.imageNoFrom;
      i <= detailPageInfo.imageNoTo && i < segment.pageCount;
      i++
    ) {
      state.thumbnails[segment.start + i] =
          detailPageInfo.thumbnails[i - detailPageInfo.imageNoFrom];
    }

    /// If we changed profile setting in EH site and have cached in JHenTai, we need to remove the cache to get the latest page info before re-parsing
    if (state.thumbnails[index] == null) {
      log.download(
        'Parse image hrefs error, thumbnails count per page is not equal to default setting, parse again. Thumbnails count per page: ${detailPageInfo.thumbnailsCountPerPage}, changed: $thumbnailsCountPerPageChanged',
      );
      await ehRequest.removeCacheByGalleryUrlAndPage(
        segment.info.galleryUrl!,
        requestPageIndex,
      );
      return beginToParseImageHref(index);
    }

    updateSafely(['$onlineImageId::$index']);
    _ensureRealtimeSr(index);
  }

  void beginToParseImageUrl(int index, bool reParse, {String? reloadKey}) {
    if (state.parseImageUrlStates[index] == LoadingState.loading) {
      return;
    }

    state.parseImageUrlStates[index] = LoadingState.loading;
    updateSafely(['$parseImageUrlStateId::$index']);

    executor.scheduleTask(
      normalPriority,
      () => parseImageUrl(index, reParse, reloadKey),
    );
  }

  Future<void> parseImageUrl(int index, bool reParse, String? reloadKey) async {
    GalleryImage image;
    try {
      image = await retry(
        () => requestImage(index, reParse, reloadKey),
        maxAttempts: 3,
        retryIf: (e) => e is DioException,
        onRetry: (e) => log.error(
          'Parse gallery image failed, index: ${index.toString()}',
          (e as DioException).errorMsg,
        ),
      );
    } on DioException catch (_) {
      state.parseImageUrlStates[index] = LoadingState.error;
      state.parseImageUrlErrorMsg[index] = 'parseURLFailed'.tr;
      updateSafely(['$parseImageUrlStateId::$index']);
      return;
    } on EHParseException catch (e) {
      state.parseImageUrlStates[index] = LoadingState.error;
      state.parseImageUrlErrorMsg[index] = e.message.tr;
      updateSafely(['$parseImageUrlStateId::$index']);
      return;
    } on EHSiteException catch (e) {
      state.parseImageUrlStates[index] = LoadingState.error;
      state.parseImageUrlErrorMsg[index] = e.message.tr;
      updateSafely(['$parseImageUrlStateId::$index']);
      return;
    }

    state.images[index] = image;
    state.parseImageUrlStates[index] = LoadingState.success;
    updateSafely(['$onlineImageId::$index']);
    _ensureRealtimeSr(index);
  }

  Future<GalleryImage> requestImage(
    int index,
    bool reParse,
    String? reloadKey,
  ) {
    return ehRequest.requestImagePage(
      state.thumbnails[index]!.replacedMPVHref(pageNumberOf(index)),
      reloadKey: reloadKey,
      parser: EHSpiderParser.imagePage2GalleryImage,
      useCacheIfAvailable: !reParse,
    );
  }

  Future<void> reloadImage(int index) async {
    String? reloadKey;
    if (state.images[index] != null) {
      reloadKey = state.images[index]!.reloadKey;
      clearDiskCachedImage(state.images[index]!.url);
    }
    state.images[index] = null;
    beginToParseImageUrl(index, true, reloadKey: reloadKey);
    updateSafely(['$onlineImageId::$index']);
  }

  void listen2VolumeKeys() {
    if (readSetting.enablePageTurnByVolumeKeys.isFalse) {
      volumeService.cancelListen();
      return;
    }

    volumeService.listen((VolumeEventType type) {
      if (type == VolumeEventType.volumeUp) {
        layoutLogic.toPrev();
      } else if (type == VolumeEventType.volumeDown) {
        layoutLogic.toNext();
      }
    });
  }

  void restoreVolumeListener() {
    volumeService.cancelListen();
  }

  /// If [immersiveMode], switch to [SystemUiMode.immersiveSticky], otherwise reset to [SystemUiMode.edgeToEdge]
  void applyCurrentImmersiveMode() {
    if (GetPlatform.isWindows) {
      clearImageContainerSized();
      updateSafely([pageId]);
    }

    if (readSetting.enableImmersiveMode.isTrue) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void restoreImmersiveMode() {
    if (GetPlatform.isMobile) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void applyCurrentBrightness() {
    if (GetPlatform.isMobile && readSetting.enableCustomReadBrightness.isTrue) {
      ScreenBrightness().setScreenBrightness(
        readSetting.customBrightness.value.toDouble() / 100,
      );
    }
  }

  void resetBrightness() {
    if (GetPlatform.isMobile) {
      ScreenBrightness().resetScreenBrightness();
    }
  }

  void updateDeviceOrientation() {
    if (!GetPlatform.isMobile) {
      return;
    }

    if (readSetting.deviceDirection.value == DeviceDirection.followSystem) {
      restoreDeviceOrientation();
    }
    if (readSetting.deviceDirection.value == DeviceDirection.landscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    if (readSetting.deviceDirection.value == DeviceDirection.portrait) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  void restoreDeviceOrientation() {
    if (!GetPlatform.isMobile) {
      return;
    }

    SystemChrome.setPreferredOrientations([]);
  }

  @override
  void didChangeMetrics() {
    if (!GetPlatform.isMobile) {
      return;
    }

    if (readSetting.enableOrientationSpecificReadDirection.isFalse) {
      return;
    }

    if (readSetting.deviceDirection.value != DeviceDirection.followSystem) {
      return;
    }

    final Size size =
        WidgetsBinding.instance.platformDispatcher.views.first.physicalSize;
    final bool isPortrait = size.height >= size.width;

    if (_lastIsPortrait == null) {
      _lastIsPortrait = isPortrait;
      return;
    }

    if (_lastIsPortrait == isPortrait) {
      return;
    }

    _lastIsPortrait = isPortrait;

    final ReadDirection targetDirection = isPortrait
        ? readSetting.portraitReadDirection.value
        : readSetting.landscapeReadDirection.value;
    final String directionName = targetDirection.name.tr;
    final String orientationKey = isPortrait ? 'portrait' : 'landscape';
    toast(
      '${'autoSwitchedReadDirection'.tr}: $directionName (${orientationKey.tr})',
    );

    onEffectiveSettingChanged();
  }

  void onEffectiveSettingChanged() {
    clearImageContainerSized();
    state.readPageInfo.initialIndex = state.readPageInfo.currentImageIndex;
    _syncDisplayFirstPageAloneToState();
    updateSafely([layoutId]);
  }

  void _syncDisplayFirstPageAloneToState() {
    final effective = effectiveDisplayFirstPageAlone;
    if (state.displayFirstPageAlone != effective) {
      state.displayFirstPageAlone = effective;
      layoutLogic.toggleDisplayFirstPageAlone();
      updateSafely([topMenuId, bottomMenuId]);
    }
  }

  bool get isPortrait {
    if (readSetting.deviceDirection.value == DeviceDirection.portrait) {
      return true;
    }
    if (readSetting.deviceDirection.value == DeviceDirection.landscape) {
      return false;
    }
    final size =
        WidgetsBinding.instance.platformDispatcher.views.first.physicalSize;
    return size.height >= size.width;
  }

  ReadDirection get effectiveReadDirection {
    if (readSetting.autoDetectWebtoon.isTrue && state.readPageInfo.readDirection != null) {
      return state.readPageInfo.readDirection!;
    }
    if (readSetting.enableOrientationSpecificReadDirection.isFalse || !GetPlatform.isMobile) {
      return readSetting.readDirection.value;
    }
    if (isPortrait) {
      return readSetting.portraitReadDirection.value;
    }
    return readSetting.landscapeReadDirection.value;
  }

  bool get reachedEnd => _reachedEnd;

  bool get hasSiblingBooks => state.readPageInfo.loadSiblingBook != null;

  /// The book being read.
  ReadSegment get currentSegment => _currentSegment;

  /// Page number of [index] within its book, from 1.
  int pageNumberOf(int index) => index - state.segmentAt(index).start + 1;

  /// Whether the next book is appended below the last as reading goes on,
  /// instead of reopening the reader: in the scrolling layouts.
  bool get readsBooksInARow =>
      hasSiblingBooks &&
      (effectiveReadDirection == ReadDirection.top2bottomList ||
          isInListReadDirection);

  /// The button to the next book: at the end of a book with nothing
  /// appended after it.
  bool get showsNextBookButton =>
      hasSiblingBooks &&
      _reachedEnd &&
      identical(_currentSegment, state.segments.last) &&
      !(readsBooksInARow && _noNextSegment);

  /// Appends the book after the last one, once.
  Future<ReadSegment?> appendNextSegment() async {
    if (_openingSibling || _noNextSegment) {
      return null;
    }
    final Future<ReadPageInfo?> Function({required bool next})? load =
        state.segments.last.info.loadSiblingBook;
    if (load == null) {
      return null;
    }
    _openingSibling = true;
    update([endOfBookId, topMenuId]);
    try {
      final ReadPageInfo? next = await load(next: true);
      if (isClosed) {
        return null;
      }
      if (next == null) {
        _noNextSegment = true;
        return null;
      }
      if (!state.canAppend(next)) {
        log.warning('Book can not follow in this reader: ${next.galleryTitle}');
        return null;
      }
      final ReadSegment segment = state.appendSegment(next);
      log.info('Appended ${next.galleryTitle}: pages ${segment.start}-${segment.end - 1}');
      _onPagesAppended();
      return segment;
    } catch (e) {
      log.error('Append next book failed', e);
      return null;
    } finally {
      _openingSibling = false;
      updateSafely([endOfBookId, topMenuId]);
    }
  }

  void _onPagesAppended() {
    for (final BaseLayoutLogic logic in <BaseLayoutLogic?>[
      if (Get.isRegistered<VerticalListLayoutLogic>()) Get.find<VerticalListLayoutLogic>(),
      if (Get.isRegistered<HorizontalListLayoutLogic>()) Get.find<HorizontalListLayoutLogic>(),
      if (Get.isRegistered<HorizontalPageLayoutLogic>()) Get.find<HorizontalPageLayoutLogic>(),
      if (Get.isRegistered<HorizontalDoubleColumnLayoutLogic>()) Get.find<HorizontalDoubleColumnLayoutLogic>(),
    ].whereType<BaseLayoutLogic>()) {
      logic.onPagesAppended();
    }
    updateSafely([sliderId, pageNoId, thumbnailNoId, bottomMenuId]);
  }

  /// The previous or next book: within this reader when it is there or can
  /// be appended, otherwise by closing this reader with the book as the
  /// result; the page that opened the reader opens it once this reader is
  /// disposed. Replacing the route in place would let the new page bind to
  /// this reader's still-registered controllers, so the new book's page
  /// events would be recorded as the old book's progress.
  Future<void> openSiblingBook({required bool next}) async {
    final int position = state.segments.indexOf(_currentSegment);
    final int target = position + (next ? 1 : -1);
    if (target >= 0 && target < state.segments.length) {
      jump2ImageIndex(state.segments[target].start);
      return;
    }
    if (next && readsBooksInARow) {
      final ReadSegment? appended = await appendNextSegment();
      if (appended != null) {
        jump2ImageIndex(appended.start);
      } else if (_noNextSegment) {
        toast((state.readPageInfo.siblingsAreChapters ? 'noNextChapter' : 'noNextBook').tr);
      }
      return;
    }

    final Future<ReadPageInfo?> Function({required bool next})? load =
        _currentSegment.info.loadSiblingBook;
    if (load == null || _openingSibling) {
      return;
    }
    _openingSibling = true;
    update([endOfBookId, topMenuId]);
    try {
      final ReadPageInfo? sibling = await load(next: next);
      if (sibling == null) {
        final String key = state.readPageInfo.siblingsAreChapters
            ? (next ? 'noNextChapter' : 'noPreviousChapter')
            : (next ? 'noNextBook' : 'noPreviousBook');
        toast(key.tr);
        return;
      }
      backRoute(currentRoute: Routes.read, result: sibling);
    } catch (e) {
      log.error('Open sibling book failed', e);
      toast(e.toString(), isShort: false);
    } finally {
      _openingSibling = false;
      update([endOfBookId, topMenuId]);
    }
  }

  bool get openingSibling => _openingSibling;

  String get previousSiblingLabel =>
      (state.readPageInfo.siblingsAreChapters ? 'previousChapter' : 'previousBook').tr;

  String get nextSiblingLabel =>
      (state.readPageInfo.siblingsAreChapters ? 'nextChapter' : 'nextBook').tr;

  void saveReadDirection(ReadDirection value) {
    state.readPageInfo.readDirection = null;

    if (readSetting.enableOrientationSpecificReadDirection.isTrue && GetPlatform.isMobile) {
      if (isPortrait) {
        readSetting.savePortraitReadDirection(value);
      } else {
        readSetting.saveLandscapeReadDirection(value);
      }
    } else {
      readSetting.saveReadDirection(value);
    }
  }

  int get effectiveImageRegionWidthRatio {
    if (!GetPlatform.isMobile ||
        readSetting.enableOrientationSpecificReadDirection.isFalse) {
      return readSetting.imageRegionWidthRatio.value;
    }
    return isPortrait ? readSetting.portraitImageRegionWidthRatio.value : readSetting.landscapeImageRegionWidthRatio.value;
  }

  bool get effectiveDisplayFirstPageAlone {
    if (!GetPlatform.isMobile ||
        readSetting.enableOrientationSpecificReadDirection.isFalse) {
      return readSetting.displayFirstPageAlone.value;
    }
    return isPortrait ? readSetting.portraitDisplayFirstPageAlone.value : readSetting.landscapeDisplayFirstPageAlone.value;
  }

  bool get isInListReadDirection =>
      ReadSetting.isListDirection(effectiveReadDirection);

  bool get isInDoubleColumnReadDirection =>
      ReadSetting.isDoubleColumnDirection(effectiveReadDirection);

  bool get isInSinglePageReadDirection =>
      ReadSetting.isSinglePageDirection(effectiveReadDirection);

  bool get isInFitWidthReadDirection =>
      ReadSetting.isFitWidthDirection(effectiveReadDirection);

  bool get isInRight2LeftDirection =>
      ReadSetting.isRight2LeftDirection(effectiveReadDirection);

  void toggleMenu() {
    state.isMenuOpen = !state.isMenuOpen;
    update([topMenuId, bottomMenuId, rightBottomInfoId]);
  }

  Future<void> toggleAutoMode() async {
    if (state.autoMode) {
      return closeAutoMode();
    }

    bool? begin = await Get.dialog(const AutoModeIntervalDialog());
    if (begin == null || !begin) {
      return;
    }

    enterAutoMode();
  }

  void enterAutoMode() {
    state.autoMode = true;
    update([autoModeId]);
    layoutLogic.enterAutoMode();
  }

  void closeAutoMode() {
    state.autoMode = false;
    update([autoModeId]);
    layoutLogic.closeAutoMode();
  }

  void handleTapZone(int index) {
    if (!inited) {
      return;
    }

    if (state.isScrolling) {
      return;
    }

    switch (readSetting.tapZoneConfig.actions[index]) {
      case TapZoneAction.none:
        break;
      case TapZoneAction.toggleMenu:
        toggleMenu();
      case TapZoneAction.prevPage:
        toPrev();
      case TapZoneAction.nextPage:
        toNext();
      case TapZoneAction.flipLeft:
        toLeft();
      case TapZoneAction.flipRight:
        toRight();
    }
  }

  /// click right arrow key
  void toLeft() {
    layoutLogic.toLeft();
  }

  /// click right arrow key
  void toRight() {
    layoutLogic.toRight();
  }

  /// to prev image or screen
  void toPrev() {
    layoutLogic.toPrev();
  }

  /// to next image or screen
  void toNext() {
    layoutLogic.toNext();
  }

  void handleM() {
    toggleDisplayFirstPageAlone();
  }

  void jump2ImageIndex(int pageIndex) {
    layoutLogic.jump2ImageIndex(pageIndex);
  }

  /// [pageNo] counts within the book being read.
  void handleSlide(double pageNo) {
    state.readPageInfo.currentImageIndex = _currentSegment.start + (pageNo - 1).toInt();
    update([sliderId, pageNoId]);
  }

  void handleSlideEnd(double pageNo) {
    jump2ImageIndex(_currentSegment.start + (pageNo - 1).toInt());
  }

  /// Sync thumbnails after user scrolling to image whose index is [targetImageIndex]
  void syncThumbnails(int targetImageIndex) {
    if (readSetting.showThumbnails.isFalse) {
      return;
    }

    int? firstThumbnailIndex = getCurrentVisibleThumbnails().firstOrNull?.index;
    int? lastThumbnailIndex = getCurrentVisibleThumbnails().lastOrNull?.index;
    if (firstThumbnailIndex == null) {
      return;
    }

    /// No more thumbnails, do not scroll more
    if (lastThumbnailIndex == state.readPageInfo.pageCount - 1 &&
        targetImageIndex > firstThumbnailIndex) {
      return;
    }

    /// If a new scroll starts before previous scroll end, the previous scroll will be cancelled. So if user keeps scrolling
    /// the list, the scroll of the thumbnail list will be delayed until the user stops scrolling. We use Throttling to avoid.
    _thr.throttle(() {
      scrollThumbnailsToIndex(targetImageIndex);
    });
  }

  void scrollThumbnailsToIndex(int index) {
    if (!isClosed) {
      state.thumbnailsScrollController.scrollTo(
        index: max(0, index - 2),
        duration: const Duration(milliseconds: 200),
      );
    }
  }

  void handleTapSuperResolutionButton() {
    state.useSuperResolution = !state.useSuperResolution;
    log.info('toggle super resolution mode: ${state.useSuperResolution}');
    updateSafely([topMenuId]);
    layoutLogic.updateSafely([BaseLayoutLogic.pageId]);
  }

  String getSuperResolutionProgress() {
    int gid = state.readPageInfo.gid!;
    SuperResolutionType type = state.readPageInfo.mode == ReadMode.downloaded
        ? SuperResolutionType.gallery
        : SuperResolutionType.archive;
    SuperResolutionInfo? superResolutionInfo = superResolutionService.get(
      gid,
      type,
    );

    if (superResolutionInfo == null) {
      return '';
    }

    return '(${superResolutionInfo.imageStatuses.where((status) => status == SuperResolutionStatus.success).length}/${superResolutionInfo.imageStatuses.length})';
  }

  void toggleDisplayFirstPageAlone() {
    log.info('toggleDisplayFirstPageAlone->${!state.displayFirstPageAlone}');
    state.displayFirstPageAlone = !state.displayFirstPageAlone;

    layoutLogic.toggleDisplayFirstPageAlone();
    updateSafely([topMenuId, bottomMenuId]);
  }

  List<ItemPosition> getCurrentVisibleThumbnails() {
    return filterAndSortItems(
      state.thumbnailPositionsListener.itemPositions.value,
    );
  }

  /// for some reason like slow loading of some image, [ItemPositions] may be not in index order, and even some of
  /// them are not in viewport
  List<ItemPosition> filterAndSortItems(Iterable<ItemPosition> positions) {
    positions = positions
        .where(
          (item) => !(item.itemTrailingEdge < 0 || item.itemLeadingEdge > 1),
        )
        .toList();
    (positions as List<ItemPosition>).sort((a, b) => a.index - b.index);
    return positions;
  }

  /// [index] is the first visible image; [reachedEnd] tells whether the end
  /// of its book is on screen. The book's last page as the first visible
  /// image is the end as well, so a book counts as finished exactly when the
  /// button to the next book or chapter shows.
  void recordReadProgress(int index, {bool reachedEnd = false}) {
    final ReadSegment left = _currentSegment;
    final int leftProgress = _progressIndex;

    state.readPageInfo.currentImageIndex = index;
    final ReadSegment segment = state.segmentAt(index);
    final bool atEnd = reachedEnd || (segment.pageCount > 0 && index >= segment.end - 1);

    final bool bookChanged = !identical(segment, left);
    if (bookChanged) {
      // Where the book being left was, kept before its record goes quiet.
      unawaited(_flushCoordinatorOf(left).schedule(leftProgress));
      _currentSegment = segment;
      unawaited(_notifyShown(segment));
      toast(segment.info.galleryTitle, isCenter: false);
    }

    final bool endChanged = _reachedEnd != atEnd;
    _reachedEnd = atEnd;
    update([sliderId, pageNoId, thumbnailNoId, if (endChanged || bookChanged) endOfBookId, if (bookChanged) topMenuId]);
    requestRealtimeSrAhead();
  }

  /// For the scrolling layouts: records [visible] (in index order) and
  /// appends the next book as the end of the last one comes near.
  void recordVisibleItems(List<ItemPosition> visible) {
    if (visible.isEmpty) {
      return;
    }
    final int first = visible.first.index;
    final ReadSegment segment = state.segmentAt(first);
    recordReadProgress(first, reachedEnd: listShowsEnd(visible, segment.end));
    if (readsBooksInARow && visible.last.index >= state.readPageInfo.pageCount - _appendAhead) {
      unawaited(appendNextSegment());
    }
  }

  /// Progress of [segment] when [index] (of the reader) was the first
  /// visible image: within the book, its last page once its end was reached.
  int _progressIndexIn(ReadSegment segment, bool reachedEnd, int index) => progressIndexFor(
    currentIndex: (index - segment.start).clamp(0, max(0, segment.pageCount - 1)),
    reachedEnd: reachedEnd,
    pageCount: segment.pageCount,
  );

  int get _progressIndex => _progressIndexIn(_currentSegment, _reachedEnd, state.readPageInfo.currentImageIndex);

  Future<void> _notifyShown(ReadSegment segment) async {
    try {
      await segment.info.onShown?.call();
    } catch (e) {
      log.error('Notify book shown failed', e);
    }
  }

  Future<void> _scheduleReadProgressFlush() {
    return _flushCoordinatorOf(_currentSegment).schedule(_progressIndex);
  }

  Future<void> _flushReadProgressAndSync() async {
    try {
      await _flushCoordinatorOf(_currentSegment).flushFinalAndSync(
        _progressIndex,
        sync: () async {
          await syncService.syncReadProgress(force: true);
        },
      );
    } catch (e, stack) {
      log.error('Final read progress sync failed', e, stack);
    }
  }

  void clearImageContainerSized() {
    state.imageContainerSizes = List.generate(
      state.readPageInfo.pageCount,
      (_) => null,
    );
  }

  Future<void> openReadSetting(BuildContext context) async {
    if (styleSetting.isInDesktopLayout || styleSetting.isInTabletLayout) {
      await _showReadSettingDrawer(context);
    } else {
      await _pushReadSettingPage();
    }
  }

  Future<void> _pushReadSettingPage() async {
    restoreImmersiveMode();
    toRoute(Routes.settingRead, id: fullScreen)?.then((_) {
      applyCurrentImmersiveMode();
      state.focusNode.requestFocus();
    });
  }

  Future<void> _showReadSettingDrawer(BuildContext context) async {
    restoreImmersiveMode();

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (_) {
        double width = MediaQuery.of(context).size.width * 0.55;
        if (width < 360) {
          width = 360;
        }
        if (width > 600) {
          width = 600;
        }
        return Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: width,
            child: Material(
              elevation: 16,
              child: Navigator(
                key: const Key('readPageLogic'),
                initialRoute: '/',
                onGenerateRoute: (settings) {
                  final bool useCupertino =
                      preferenceSetting.enableSwipeBackGesture.isTrue;
                  if (settings.name == '/') {
                    return _buildDrawerRoute(
                      builder: (_) => SettingReadPage(),
                      settings: settings,
                      useCupertino: useCupertino,
                    );
                  }
                  if (settings.name == '/keyboard_shortcuts') {
                    return _buildDrawerRoute(
                      builder: (_) => const SettingKeyboardShortcutsPage(),
                      settings: settings,
                      useCupertino: useCupertino,
                    );
                  }
                  if (settings.name == '/tap_zone_style') {
                    return _buildDrawerRoute(
                      builder: (_) => const SettingTapZonePage(),
                      settings: settings,
                      useCupertino: useCupertino,
                    );
                  }
                  return null;
                },
              ),
            ),
          ),
        );
      },
    );

    applyCurrentImmersiveMode();
    state.focusNode.requestFocus();
  }

  Route _buildDrawerRoute({
    required Widget Function(BuildContext) builder,
    required RouteSettings settings,
    required bool useCupertino,
  }) {
    if (useCupertino) {
      return PageRouteBuilder(
        pageBuilder: (context, __, ___) => builder(context),
        transitionsBuilder: (_, animation, __, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
              .animate(
                CurvedAnimation(parent: animation, curve: Curves.easeInOut),
              ),
          child: child,
        ),
        settings: settings,
      );
    }
    return PageRouteBuilder(
      pageBuilder: (context, __, ___) => builder(context),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
      settings: settings,
    );
  }
}
