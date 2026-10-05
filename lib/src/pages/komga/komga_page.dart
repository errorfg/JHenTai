import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/model/content_scheme.dart';
import 'package:jhentai/src/model/tab_bar_icon.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/pages/komga/komga_browse_controller.dart';
import 'package:jhentai/src/pages/komga/komga_home_view.dart';
import 'package:jhentai/src/pages/komga/komga_item_widgets.dart';
import 'package:jhentai/src/pages/komga/komga_list_view.dart';
import 'package:jhentai/src/pages/komga/komga_reader_launcher.dart';
import 'package:jhentai/src/pages/komga/komga_series_header.dart';
import 'package:jhentai/src/pages/layout/desktop/desktop_layout_page_logic.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2_logic.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2_state.dart';
import 'package:jhentai/src/pages/read/read_page_logic.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/komga_download_service.dart';
import 'package:jhentai/src/service/komga_progress_sync_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/komga_setting.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:jhentai/src/widget/eh_context_menu.dart';

class KomgaPage extends StatefulWidget {
  const KomgaPage({super.key, this.clientFactory = KomgaClient.fromSetting});

  final KomgaClient Function() clientFactory;

  @override
  State<KomgaPage> createState() => _KomgaPageState();
}

class _KomgaPageState extends State<KomgaPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final MobileLayoutPageV2State _drawerState = MobileLayoutPageV2State();
  late final Worker _settingWorker;
  late final VoidCallback _progressListenerDisposer;
  Timer? _progressReloadTimer;

  KomgaBrowseController? _controller;
  String? _clientError;
  String? _openingBookId;
  bool _syncingAll = false;
  int? _appliedConfigurationHash;

  @override
  void initState() {
    super.initState();
    _settingWorker = ever<int>(
      komgaSetting.revision,
      (_) => _reloadForSettingChange(),
    );
    _progressListenerDisposer = readProgressService.addListener(
      _handleProgressServiceRefresh,
    );
    _initialize();
  }

  @override
  void dispose() {
    _progressReloadTimer?.cancel();
    _progressListenerDisposer();
    _settingWorker.dispose();
    _drawerState.scrollController.dispose();
    _controller?.dispose();
    super.dispose();
  }

  void _initialize() {
    _appliedConfigurationHash = _configurationHash;
    _controller?.dispose();
    _controller = null;
    _clientError = null;
    if (!komgaSetting.isConfigured) {
      return;
    }
    final KomgaClient client;
    try {
      client = widget.clientFactory();
    } catch (e) {
      _clientError = KomgaClient.friendlyError(e);
      return;
    }
    final KomgaBrowseController controller = KomgaBrowseController(
      client: client,
    )..addListener(_onControllerChanged);
    _controller = controller;
    unawaited(syncService.syncReadProgress());
    unawaited(_drainPending(client));
    unawaited(controller.start());
  }

  void _onControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final KomgaBrowseController? controller = _controller;
    final bool canGoBack = controller?.canGoBack ?? false;
    return PopScope(
      canPop: !canGoBack,
      onPopInvokedWithResult: (bool didPop, dynamic _) {
        if (didPop) {
          return;
        }
        if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
          _scaffoldKey.currentState?.closeDrawer();
        } else {
          controller?.goBack();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: UIConfig.backGroundColor(context),
        drawer: MobileLeftDrawer(
          state: _drawerState,
          currentScheme: ContentScheme.komga,
          onBeforeSwitch: _prepareSourceSwitch,
          onDestinationSelected: _openJhentaiDestination,
          showSelectedDestination: false,
        ),
        appBar: AppBar(
          leadingWidth: canGoBack ? 96 : null,
          leading: canGoBack
              ? Row(
                  children: <Widget>[
                    IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).openAppDrawerTooltip,
                      onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                      icon: const Icon(Icons.menu),
                    ),
                    IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      onPressed: controller!.goBack,
                      icon: const Icon(Icons.arrow_back),
                    ),
                  ],
                )
              : null,
          title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: <Widget>[
            if (controller != null)
              IconButton(
                key: const ValueKey<String>('komgaSearchButton'),
                tooltip: 'komgaSearch'.tr,
                onPressed: _openSearch,
                icon: const Icon(Icons.search),
              ),
            IconButton(
              key: const ValueKey<String>('komgaImportProgressButton'),
              tooltip: 'komgaImportProgress'.tr,
              onPressed: controller == null || _syncingAll
                  ? null
                  : _syncAllProgress,
              icon: _syncingAll
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_sync_outlined),
            ),
            IconButton(
              tooltip: 'refresh'.tr,
              onPressed: controller == null ? null : _syncProgressAndRefresh,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              key: const ValueKey<String>('komgaSettingsButton'),
              tooltip: 'komgaSettings'.tr,
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        body: _buildBody(context),
      ),
    );
  }

  String get _title {
    return switch (_controller?.current) {
      final KomgaListLevel level when level.isSearch =>
        'komgaSearchResults'.trParams(<String, String>{'query': level.title}),
      final KomgaListLevel level => level.title,
      final KomgaSeriesLevel level => level.series.title,
      KomgaDownloadsLevel() => 'komgaDownloads'.tr,
      _ => 'Komga',
    };
  }

  Widget _buildBody(BuildContext context) {
    if (!komgaSetting.isConfigured) {
      return _buildNotConfigured();
    }
    final KomgaBrowseController? controller = _controller;
    if (controller == null) {
      return Center(child: Text(_clientError ?? ''));
    }
    final KomgaItemActions actions = KomgaItemActions(
      openBook: _openBook,
      openSeries: controller.openSeries,
      showBookMenu: _showBookMenu,
      showSeriesMenu: _showSeriesMenu,
      openingBookId: _openingBookId,
    );
    final KomgaLevel level = controller.current;
    return switch (level) {
      KomgaHomeLevel() => KomgaHomeView(
        controller: controller,
        actions: actions,
        onRefresh: _syncProgressAndRefresh,
      ),
      KomgaListLevel() => KomgaListView(
        key: ObjectKey(level),
        controller: controller,
        level: level,
        actions: actions,
        onRefresh: _syncProgressAndRefresh,
      ),
      KomgaSeriesLevel() => KomgaListView(
        key: ObjectKey(level),
        controller: controller,
        level: level,
        actions: actions,
        onRefresh: _syncProgressAndRefresh,
        header: KomgaSeriesHeader(
          level: level,
          views: KomgaItemViews(context, controller.client, actions),
          onContinue: _openBook,
          onFilter: controller.openFilter,
          onSeriesAction: (KomgaSeriesAction action) =>
              _runSeriesAction(level.series, action),
        ),
      ),
      KomgaDownloadsLevel() => KomgaDownloadsView(
        controller: controller,
        actions: actions,
      ),
    };
  }

  Widget _buildNotConfigured() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.dns_outlined, size: 64),
            const SizedBox(height: 20),
            Text(
              'komgaNotConfigured'.tr,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_outlined),
              label: Text('configureKomga'.tr),
            ),
          ],
        ),
      ),
    );
  }

  // ---- actions ----

  Future<void> _openBook(KomgaBook book) async {
    final KomgaBrowseController? controller = _controller;
    if (controller == null || _openingBookId != null) {
      return;
    }
    setState(() => _openingBookId = book.id);
    try {
      final ReadPageInfo info = await KomgaReaderLauncher(
        controller.client,
      ).prepare(book);
      if (!mounted || !identical(controller, _controller)) {
        return;
      }
      setState(() => _openingBookId = null);
      ReadPageInfo? session = info;
      while (session != null) {
        final dynamic result = await toRoute<dynamic>(
          Routes.read,
          arguments: session,
        );
        if (!mounted || !identical(controller, _controller)) {
          return;
        }
        await controller.refreshProgress();
        // "Next/previous book" closes the reader with the sibling session.
        session = result is ReadPageInfo ? result : null;
        if (session != null) {
          await waitForReaderDisposed();
        }
      }
    } catch (e) {
      if (mounted) {
        toast(KomgaClient.friendlyError(e), isShort: false);
      }
    } finally {
      if (mounted && _openingBookId == book.id) {
        setState(() => _openingBookId = null);
      }
    }
  }

  Future<void> _showBookMenu(
    BuildContext context,
    KomgaBook book, {
    Offset? position,
  }) async {
    final KomgaBrowseController controller = _controller!;
    final String key = controller.client.progressRecordKey(book.id);
    final bool downloaded = komgaDownloadService.downloaded(key) != null;
    final KomgaDownloadTask? task = komgaDownloadService.task(key);
    final String? choice = await _chooseFromMenu<String>(
      context,
      title: book.title,
      position: position,
      entries: <_MenuEntry<String>>[
        _MenuEntry('read', Icons.check_circle_outline, 'komgaMarkRead'.tr),
        _MenuEntry('unread', Icons.radio_button_unchecked, 'komgaMarkUnread'.tr),
        if (downloaded)
          _MenuEntry('delete', Icons.delete_outline, 'komgaDeleteDownload'.tr)
        else if (book.isReadable &&
            (task == null || task.state == KomgaDownloadState.failed))
          _MenuEntry(
            'download',
            Icons.download_outlined,
            task == null ? 'komgaDownload'.tr : 'komgaRetryDownload'.tr,
          ),
      ],
    );
    try {
      switch (choice) {
        case 'read':
          await controller.markBook(book, read: true);
        case 'unread':
          await controller.markBook(book, read: false);
        case 'download':
          komgaDownloadService.enqueue(controller.client, book);
        case 'delete':
          await komgaDownloadService.delete(key);
      }
    } catch (e) {
      toast(KomgaClient.friendlyError(e), isShort: false);
    }
  }

  Future<void> _showSeriesMenu(
    BuildContext context,
    KomgaSeries series, {
    Offset? position,
  }) async {
    final KomgaSeriesAction? action = await _chooseFromMenu<KomgaSeriesAction>(
      context,
      title: series.title,
      position: position,
      entries: <_MenuEntry<KomgaSeriesAction>>[
        _MenuEntry(
          KomgaSeriesAction.markRead,
          Icons.check_circle_outline,
          'komgaMarkSeriesRead'.tr,
        ),
        _MenuEntry(
          KomgaSeriesAction.markUnread,
          Icons.radio_button_unchecked,
          'komgaMarkSeriesUnread'.tr,
        ),
        _MenuEntry(
          KomgaSeriesAction.download,
          Icons.download_outlined,
          'komgaDownloadSeries'.tr,
        ),
      ],
    );
    if (action != null) {
      await _runSeriesAction(series, action);
    }
  }

  /// A menu at the pointer on desktop layouts, a bottom sheet with the item
  /// title otherwise. Completes with the chosen value, or null.
  Future<T?> _chooseFromMenu<T>(
    BuildContext context, {
    required String title,
    required List<_MenuEntry<T>> entries,
    Offset? position,
  }) async {
    if (styleSetting.isInDesktopLayout) {
      T? chosen;
      await showEHContextMenu(
        context,
        position: position,
        actions: <EHContextMenuAction>[
          for (final _MenuEntry<T> entry in entries)
            EHContextMenuAction(
              text: entry.label,
              icon: Icon(entry.icon, size: 20),
              onTap: () => chosen = entry.value,
            ),
        ],
      );
      return chosen;
    }
    return showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(title: Text(title, maxLines: 2)),
            for (final _MenuEntry<T> entry in entries)
              ListTile(
                leading: Icon(entry.icon),
                title: Text(entry.label),
                onTap: () => Navigator.of(context).pop(entry.value),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _runSeriesAction(
    KomgaSeries series,
    KomgaSeriesAction action,
  ) async {
    final KomgaBrowseController controller = _controller!;
    try {
      switch (action) {
        case KomgaSeriesAction.markRead:
          await controller.markSeries(series, read: true);
        case KomgaSeriesAction.markUnread:
          await controller.markSeries(series, read: false);
        case KomgaSeriesAction.download:
          await komgaDownloadService.enqueueSeries(controller.client, series);
          toast('komgaDownloadQueued'.tr);
      }
    } catch (e) {
      toast(KomgaClient.friendlyError(e), isShort: false);
    }
  }

  Future<void> _openSearch() async {
    final TextEditingController text = TextEditingController();
    final String? query = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('komgaSearch'.tr),
        content: TextField(
          key: const ValueKey<String>('komgaSearchField'),
          controller: text,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(hintText: 'komgaSearchHint'.tr),
          onSubmitted: (String value) => Navigator.of(context).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('cancel'.tr),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(text.text),
            child: Text('komgaSearch'.tr),
          ),
        ],
      ),
    );
    text.dispose();
    if (query != null && query.trim().isNotEmpty) {
      await _controller?.openSearch(query);
    }
  }

  Future<void> _syncAllProgress() async {
    final KomgaBrowseController controller = _controller!;
    setState(() => _syncingAll = true);
    try {
      final KomgaProgressSyncResult result = await komgaProgressSyncService
          .syncAll(controller.client);
      if (!identical(controller, _controller)) {
        return;
      }
      await controller.refreshProgress();
      final int synced = result.applied + result.pushed;
      toast(
        synced > 0
            ? 'komgaImportProgressImported'.trParams(<String, String>{
                'count': synced.toString(),
              })
            : 'komgaImportProgressUpToDate'.tr,
        isShort: synced == 0,
      );
    } catch (e) {
      toast(KomgaClient.friendlyError(e), isShort: false);
    } finally {
      if (mounted) {
        setState(() => _syncingAll = false);
      }
    }
  }

  Future<void> _syncProgressAndRefresh() async {
    final KomgaBrowseController? controller = _controller;
    if (controller == null) {
      return;
    }
    final SyncResult? result = await syncService.syncReadProgress(
      requireAutoSync: false,
      force: true,
    );
    if (!identical(controller, _controller)) {
      return;
    }
    if (result != null && !result.success) {
      toast('${'syncFailed'.tr}: ${result.message}', isShort: false);
    }
    unawaited(_drainPending(controller.client));
    await controller.refreshCurrent();
  }

  Future<void> _drainPending(KomgaClient client) async {
    try {
      await komgaProgressSyncService.drainPending(client);
    } catch (e) {
      log.warning('Komga pending progress drain failed', e);
    }
  }

  Future<void> _openSettings() async {
    final dynamic changed = await toRoute<dynamic>(Routes.komgaSettings);
    if (changed == true) {
      _reloadForSettingChange();
    }
  }

  void _reloadForSettingChange() {
    if (!mounted || _appliedConfigurationHash == _configurationHash) {
      return;
    }
    setState(_initialize);
  }

  int get _configurationHash => Object.hash(
    komgaSetting.serverUrl.value,
    komgaSetting.username.value,
    komgaSetting.password.value,
    komgaSetting.apiKey.value,
    komgaSetting.connectionId.value,
  );

  void _handleProgressServiceRefresh() {
    if (!mounted || _controller == null) {
      return;
    }
    _progressReloadTimer?.cancel();
    _progressReloadTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted) {
        unawaited(_controller?.refreshProgress());
      }
    });
  }

  void _prepareSourceSwitch() {
    if (_openingBookId != null && mounted) {
      setState(() => _openingBookId = null);
    }
    _scaffoldKey.currentState?.closeDrawer();
  }

  void _openJhentaiDestination(int index) {
    final TabBarIconNameEnum targetName = _drawerState.icons[index].name;
    _prepareSourceSwitch();
    Get.offAllNamed<dynamic>(Routes.home);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (styleSetting.isInDesktopLayout &&
          Get.isRegistered<DesktopLayoutPageLogic>()) {
        final DesktopLayoutPageLogic layoutLogic =
            Get.find<DesktopLayoutPageLogic>();
        final int targetIndex = layoutLogic.state.icons.indexWhere(
          (icon) => icon.name == targetName,
        );
        if (targetIndex >= 0) {
          layoutLogic.handleTapTabBarButton(targetIndex);
        }
        return;
      }
      if (!Get.isRegistered<MobileLayoutPageV2Logic>()) {
        return;
      }
      final MobileLayoutPageV2Logic layoutLogic =
          Get.find<MobileLayoutPageV2Logic>();
      final int targetIndex = layoutLogic.state.icons.indexWhere(
        (icon) => icon.name == targetName,
      );
      if (targetIndex >= 0) {
        layoutLogic.handleTapTabBarButton(targetIndex);
      }
    });
  }
}

class _MenuEntry<T> {
  const _MenuEntry(this.value, this.icon, this.label);

  final T value;
  final IconData icon;
  final String label;
}
