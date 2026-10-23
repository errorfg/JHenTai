import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/model/komga/komga_browse_models.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/komga/komga_query.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/model/content_scheme.dart';
import 'package:jhentai/src/model/tab_bar_icon.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/pages/komga/komga_browse_controller.dart';
import 'package:jhentai/src/pages/komga/komga_filter_sheet.dart';
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
import 'package:jhentai/src/setting/scheme_setting.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:jhentai/src/widget/eh_context_menu.dart';
import 'package:jhentai/src/widget/will_pop_interceptor.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

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
    unawaited(schemeSetting.openOwnPage(ContentScheme.komga));
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
    unawaited(schemeSetting.closeOwnPage(ContentScheme.komga));
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
    final KomgaLevel? level = controller?.current;
    final KomgaQuery? query = switch (level) {
      final KomgaListLevel level => level.query,
      final KomgaSeriesLevel level => level.query,
      _ => null,
    };
    final bool filtered =
        query != null &&
        (query.progress != KomgaProgressFilter.all || !query.filters.isEmpty);
    return SchemePagePopScope(
      onBack: () {
        if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
          _scaffoldKey.currentState?.closeDrawer();
          return true;
        }
        if (controller?.canGoBack ?? false) {
          controller!.goBack();
          return true;
        }
        return false;
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: UIConfig.backGroundColor(context),
        // The content scrolls under the glass buttons of the bar.
        extendBodyBehindAppBar: true,
        drawer: MobileLeftDrawer(
          state: _drawerState,
          currentScheme: ContentScheme.komga,
          onBeforeSwitch: _prepareSourceSwitch,
          onDestinationSelected: _openJhentaiDestination,
          showSelectedDestination: false,
        ),
        // Glass only on the controls above the content, icons of one group
        // sharing one piece of glass (Apple's Human Interface Guidelines).
        appBar: GlassAppBar(
          // The buttons keep the theme's glass; the menus they open take the
          // thicker glass around them (_menuGlass).
          buttonSettings:
              GlassThemeData.of(
                context,
              ).settingsFor(context)?.applyTo(const LiquidGlassSettings()) ??
              const LiquidGlassSettings(),
          leading: GlassButtonGroup.icons(
            items: <GlassButtonGroupItem>[
              GlassButtonGroupItem(
                icon: const Icon(CupertinoIcons.sidebar_left),
                label: MaterialLocalizations.of(context).openAppDrawerTooltip,
                onTap: () => _scaffoldKey.currentState?.openDrawer(),
              ),
              if (canGoBack)
                GlassButtonGroupItem(
                  icon: const Icon(CupertinoIcons.back),
                  label: MaterialLocalizations.of(context).backButtonTooltip,
                  onTap: controller!.goBack,
                ),
            ],
          ),
          title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
          // A group holds one menu at most, so More is a group of its own.
          actions: <Widget>[
            InheritedLiquidGlass(
              settings: _menuGlass(context),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (controller != null)
                    GlassButtonGroup.icons(
                      items: <GlassButtonGroupItem>[
                        GlassButtonGroupItem(
                          icon: const Icon(CupertinoIcons.search),
                          label: 'komgaSearch'.tr,
                          onTap: _openSearch,
                        ),
                        if (level != null && query != null)
                          GlassButtonGroupItem.menu(
                            // Filled while anything is filtered out, as in Photos.
                            icon: Icon(
                              filtered
                                  ? CupertinoIcons
                                        .line_horizontal_3_decrease_circle_fill
                                  : CupertinoIcons
                                        .line_horizontal_3_decrease_circle,
                            ),
                            label: 'komgaSortAndFilter'.tr,
                            menuWidth: 260,
                            menuItems: _sortAndFilterItems(
                              controller,
                              level,
                              query,
                            ),
                          ),
                      ],
                    ),
                  const SizedBox(width: 8),
                  GlassButtonGroup.icons(
                    items: <GlassButtonGroupItem>[
                      GlassButtonGroupItem.menu(
                        icon: _syncingAll
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(CupertinoIcons.ellipsis),
                        label: 'komgaMore'.tr,
                        menuWidth: 260,
                        menuItems: _moreItems(controller),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        body: GlassScrollEdgeEffect(
          topFadeHeight: MediaQuery.paddingOf(context).top + 64,
          // Only a library or search has a switch floating at the bottom.
          fadeBottom: level is KomgaListLevel,
          bottomFadeHeight: MediaQuery.paddingOf(context).bottom + 72,
          fadeColor: UIConfig.backGroundColor(context),
          child: _buildBody(context),
        ),
      ),
    );
  }

  /// Sort orders first, then reading status and display as submenus and the
  /// metadata filters, as in the sort and filter menu of Photos. Picking the
  /// current order again reverses it, as in Files.
  List<Widget> _sortAndFilterItems(
    KomgaBrowseController controller,
    KomgaLevel level,
    KomgaQuery query,
  ) {
    final List<KomgaSortMode> sortModes = <KomgaSortMode>[
      if (query.hasSearch) KomgaSortMode.relevance,
      if (query.target != KomgaTarget.series) KomgaSortMode.number,
      KomgaSortMode.addedAt,
      KomgaSortMode.lastReadAt,
      KomgaSortMode.title,
    ];
    final List<KomgaProgressFilter> progressFilters = <KomgaProgressFilter>[
      KomgaProgressFilter.all,
      KomgaProgressFilter.unread,
      KomgaProgressFilter.inProgress,
      KomgaProgressFilter.read,
      if (level is KomgaListLevel && level.library != null)
        KomgaProgressFilter.newlyAdded,
    ];
    final KomgaDisplayMode display = controller.preferences.displayMode;
    return <Widget>[
      GlassMenuLabel(title: 'komgaSortBy'.tr),
      for (final KomgaSortMode mode in sortModes)
        GlassMenuItem(
          title: sortModeLabel(mode),
          icon: _checkMark(mode == query.sortMode),
          trailing: mode == query.sortMode && mode != KomgaSortMode.relevance
              ? Icon(
                  query.descending
                      ? CupertinoIcons.arrow_down
                      : CupertinoIcons.arrow_up,
                  size: 16,
                )
              : null,
          onTap: () {
            if (mode != query.sortMode) {
              controller.setSort(
                level,
                mode,
                mode != KomgaSortMode.title && mode != KomgaSortMode.number,
              );
            } else if (mode != KomgaSortMode.relevance) {
              controller.setSort(level, mode, !query.descending);
            }
          },
        ),
      const GlassMenuDivider(),
      GlassMenuItem(
        title: 'komgaReadingStatus'.tr,
        subtitle: progressFilterLabel(query.progress),
        icon: const Icon(CupertinoIcons.book),
        onTap: () {},
        submenu: <Widget>[
          for (final KomgaProgressFilter progress in progressFilters)
            GlassMenuItem(
              title: progressFilterLabel(progress),
              icon: _checkMark(progress == query.progress),
              onTap: () => controller.setProgressFilter(level, progress),
            ),
        ],
      ),
      GlassMenuItem(
        title: 'komgaDisplayMode'.tr,
        subtitle: _displayModeLabel(display),
        icon: Icon(_displayModeIcon(display)),
        onTap: () {},
        submenu: <Widget>[
          for (final KomgaDisplayMode mode in KomgaDisplayMode.values)
            GlassMenuItem(
              title: _displayModeLabel(mode),
              icon: _checkMark(mode == display),
              trailing: Icon(_displayModeIcon(mode), size: 18),
              onTap: () => controller.setDisplayMode(mode),
            ),
        ],
      ),
      if (level is KomgaListLevel)
        GlassMenuItem(
          key: const ValueKey<String>('komgaFilterButton'),
          title: 'komgaFilters'.tr,
          icon: const Icon(CupertinoIcons.slider_horizontal_3),
          trailing: query.filters.isEmpty
              ? null
              : Text(query.filters.count.toString()),
          onTap: () => _openFilterSheet(level),
        ),
      if (query.progress != KomgaProgressFilter.all ||
          !query.filters.isEmpty) ...<Widget>[
        const GlassMenuDivider(),
        GlassMenuItem(
          title: 'komgaClearAllFilters'.tr,
          icon: const Icon(CupertinoIcons.xmark_circle),
          isDestructive: true,
          onTap: () => _clearFilters(controller, level),
        ),
      ],
    ];
  }

  /// Series actions on a series, then the page's own.
  List<Widget> _moreItems(KomgaBrowseController? controller) => <Widget>[
    if (controller?.current case final KomgaSeriesLevel level) ...<Widget>[
      GlassMenuItem(
        title: 'komgaMarkSeriesRead'.tr,
        icon: const Icon(CupertinoIcons.checkmark_circle),
        onTap: () =>
            _runSeriesAction(level.series, KomgaSeriesAction.markRead),
      ),
      GlassMenuItem(
        title: 'komgaMarkSeriesUnread'.tr,
        icon: const Icon(CupertinoIcons.circle),
        onTap: () =>
            _runSeriesAction(level.series, KomgaSeriesAction.markUnread),
      ),
      GlassMenuItem(
        title: 'komgaDownloadSeries'.tr,
        icon: const Icon(CupertinoIcons.arrow_down_circle),
        onTap: () =>
            _runSeriesAction(level.series, KomgaSeriesAction.download),
      ),
      const GlassMenuDivider(),
    ],
    GlassMenuItem(
      key: const ValueKey<String>('komgaImportProgressButton'),
      title: 'komgaImportProgress'.tr,
      maxLines: 2,
      icon: const Icon(CupertinoIcons.arrow_2_circlepath),
      enabled: controller != null && !_syncingAll,
      onTap: _syncAllProgress,
    ),
    GlassMenuItem(
      title: 'refresh'.tr,
      icon: const Icon(CupertinoIcons.refresh),
      enabled: controller != null,
      onTap: _syncProgressAndRefresh,
    ),
    GlassMenuItem(
      key: const ValueKey<String>('komgaSettingsButton'),
      title: 'komgaSettings'.tr,
      icon: const Icon(CupertinoIcons.gear),
      onTap: _openSettings,
    ),
  ];

  /// Menus are larger and more opaque than the buttons that open them
  /// (Apple's Human Interface Guidelines); the package's default menu glass
  /// is a white of 12%.
  static LiquidGlassSettings _menuGlass(BuildContext context) =>
      LiquidGlassSettings(
        blur: 16,
        thickness: 10,
        glassColor: Theme.of(context).brightness == Brightness.dark
            ? const Color.fromRGBO(44, 44, 46, 0.6)
            : const Color.fromRGBO(255, 255, 255, 0.6),
        lightIntensity: 0.7,
        ambientStrength: 0.4,
        saturation: 1.2,
        refractiveIndex: 0.7,
      );

  static Widget _checkMark(bool checked) => SizedBox.square(
    dimension: 20,
    child: checked ? const Icon(CupertinoIcons.checkmark, size: 18) : null,
  );

  static String _displayModeLabel(KomgaDisplayMode mode) => switch (mode) {
    KomgaDisplayMode.grid => 'komgaCardView'.tr,
    KomgaDisplayMode.list => 'komgaListView'.tr,
    KomgaDisplayMode.detail => 'komgaDetailView'.tr,
  };

  static IconData _displayModeIcon(KomgaDisplayMode mode) => switch (mode) {
    KomgaDisplayMode.grid => CupertinoIcons.square_grid_2x2,
    KomgaDisplayMode.list => CupertinoIcons.list_bullet,
    KomgaDisplayMode.detail => CupertinoIcons.rectangle_grid_1x2,
  };

  Future<void> _openFilterSheet(KomgaListLevel level) async {
    final KomgaBrowseController controller = _controller!;
    final KomgaFilters? result = await showKomgaFilterSheet(
      context,
      controller: controller,
      libraryId: level.query.libraryId,
      target: level.query.target,
      initial: level.query.filters,
    );
    if (result != null && identical(controller, _controller)) {
      await controller.setFilters(level, result);
    }
  }

  Future<void> _clearFilters(
    KomgaBrowseController controller,
    KomgaLevel level,
  ) async {
    await controller.setProgressFilter(level, KomgaProgressFilter.all);
    if (level is KomgaListLevel) {
      await controller.setFilters(level, const KomgaFilters());
    }
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
