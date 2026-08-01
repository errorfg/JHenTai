import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/komga/komga_browse_models.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/model/reader_source.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/komga_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:jhentai/src/widget/eh_image.dart';
import 'package:jhentai/src/widget/reader_source_switcher.dart';

class KomgaPage extends StatefulWidget {
  const KomgaPage({super.key, this.clientFactory = KomgaClient.fromSetting});

  final KomgaClient Function() clientFactory;

  @override
  State<KomgaPage> createState() => _KomgaPageState();
}

class _KomgaPageState extends State<KomgaPage> {
  static final DateTime _emptyLibraryBaseline = DateTime.utc(1);

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final ScrollController _scrollController = ScrollController();
  late final Worker _settingWorker;
  late final VoidCallback _progressListenerDisposer;
  Timer? _progressReloadTimer;

  KomgaClient? _client;
  KomgaLibrary? _selectedLibrary;
  KomgaSeries? _selectedSeries;
  List<KomgaLibrary> _libraries = const <KomgaLibrary>[];
  List<KomgaSeries> _series = const <KomgaSeries>[];
  List<KomgaBook> _books = const <KomgaBook>[];
  List<KomgaBookBrowseItem> _bookItems = const <KomgaBookBrowseItem>[];
  List<KomgaSeriesBrowseItem> _seriesItems = const <KomgaSeriesBrowseItem>[];

  KomgaBrowsePreferences _preferences = const KomgaBrowsePreferences();
  DateTime? _newSince;
  bool _preferencesLoaded = false;
  bool _loading = false;
  bool _importingProgress = false;
  String? _errorMessage;
  String? _openingBookId;
  int? _appliedConfigurationHash;
  int _loadGeneration = 0;
  int _bookOperationGeneration = 0;
  int _progressImportGeneration = 0;

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
    _loadGeneration++;
    _bookOperationGeneration++;
    _progressImportGeneration++;
    _progressReloadTimer?.cancel();
    _progressListenerDisposer();
    _scrollController.dispose();
    _settingWorker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isBelowRoot = _selectedLibrary != null;
    return PopScope(
      canPop: !isBelowRoot,
      onPopInvokedWithResult: (bool didPop, dynamic _) {
        if (!didPop) {
          if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
            _closeDrawer();
          } else {
            _goUp();
          }
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: ReaderSourceDrawer(
          currentSource: ReaderSourceType.komga,
          onBeforeSwitch: _prepareSourceSwitch,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: Text('komgaSettings'.tr),
              onTap: _importingProgress
                  ? null
                  : () async {
                      _closeDrawer();
                      await _openSettings();
                    },
            ),
          ],
        ),
        appBar: AppBar(
          leadingWidth: isBelowRoot ? 96 : null,
          leading: isBelowRoot
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
                      onPressed: _goUp,
                      icon: const Icon(Icons.arrow_back),
                    ),
                  ],
                )
              : null,
          title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: <Widget>[
            IconButton(
              key: const ValueKey<String>('komgaImportProgressButton'),
              tooltip: 'komgaImportProgress'.tr,
              onPressed:
                  !komgaSetting.isConfigured ||
                      _client == null ||
                      _loading ||
                      _importingProgress ||
                      _openingBookId != null
                  ? null
                  : _importKomgaProgress,
              icon: _importingProgress
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_download_outlined),
            ),
            IconButton(
              tooltip: 'refresh'.tr,
              onPressed: _loading || _importingProgress
                  ? null
                  : _refreshCurrent,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'komgaSettings'.tr,
              onPressed: _importingProgress ? null : _openSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        body: _buildBody(context),
      ),
    );
  }

  String get _title {
    if (_selectedSeries != null) {
      return _selectedSeries!.title;
    }
    if (_selectedLibrary != null) {
      return _selectedLibrary!.name;
    }
    return 'Komga';
  }

  bool get _hasLibraryData => _series.isNotEmpty || _books.isNotEmpty;

  Widget _buildBody(BuildContext context) {
    if (!komgaSetting.isConfigured) {
      return _buildNotConfigured();
    }
    if (_selectedLibrary == null) {
      if (_loading && _libraries.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_errorMessage != null && _libraries.isEmpty) {
        return _buildError();
      }
      return _buildLibraries();
    }

    return Column(
      children: <Widget>[
        _buildBrowseToolbar(context),
        const Divider(height: 1),
        Expanded(child: _buildLibraryContent(context)),
      ],
    );
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

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.cloud_off_outlined, size: 56),
            const SizedBox(height: 16),
            Text(_errorMessage!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _refreshCurrent,
              icon: const Icon(Icons.refresh),
              label: Text('retry'.tr),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLibraries() {
    if (_libraries.isEmpty) {
      return _buildEmptyList('komgaNoLibraries'.tr);
    }
    return RefreshIndicator(
      onRefresh: _syncProgressAndRefresh,
      child: ListView.separated(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: _libraries.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
        itemBuilder: (_, int index) {
          final KomgaLibrary library = _libraries[index];
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 8,
            ),
            leading: const CircleAvatar(
              child: Icon(Icons.video_library_outlined),
            ),
            title: Text(library.name),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _enterLibrary(library),
          );
        },
      ),
    );
  }

  Widget _buildBrowseToolbar(BuildContext context) {
    return Material(
      key: const ValueKey<String>('komgaBrowseToolbar'),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (_selectedSeries == null)
              SegmentedButton<KomgaLibraryView>(
                segments: <ButtonSegment<KomgaLibraryView>>[
                  ButtonSegment<KomgaLibraryView>(
                    value: KomgaLibraryView.series,
                    icon: const Icon(Icons.collections_bookmark_outlined),
                    label: Text('komgaSeriesView'.tr),
                  ),
                  ButtonSegment<KomgaLibraryView>(
                    value: KomgaLibraryView.books,
                    icon: const Icon(Icons.menu_book_outlined),
                    label: Text('komgaAllBooksView'.tr),
                  ),
                ],
                selected: <KomgaLibraryView>{_preferences.libraryView},
                showSelectedIcon: false,
                onSelectionChanged: (Set<KomgaLibraryView> value) {
                  _updatePreferences(
                    _preferences.copyWith(libraryView: value.single),
                  );
                },
              ),
            PopupMenuButton<KomgaProgressFilter>(
              tooltip: _progressFilterLabel(_preferences.progressFilter),
              initialValue: _preferences.progressFilter,
              onSelected: (KomgaProgressFilter value) {
                _updatePreferences(
                  _preferences.copyWith(progressFilter: value),
                );
              },
              itemBuilder: (_) => KomgaProgressFilter.values
                  .map(
                    (KomgaProgressFilter value) => PopupMenuItem(
                      value: value,
                      child: _popupItem(
                        _progressFilterLabel(value),
                        value == _preferences.progressFilter,
                      ),
                    ),
                  )
                  .toList(),
              child: _toolbarAnchor(
                icon: Icons.filter_list,
                label: _progressFilterLabel(_preferences.progressFilter),
              ),
            ),
            PopupMenuButton<KomgaSortMode>(
              tooltip: _sortModeLabel(_preferences.sortMode),
              initialValue: _preferences.sortMode,
              onSelected: (KomgaSortMode value) {
                _updatePreferences(
                  _preferences.copyWith(
                    sortMode: value,
                    descending: value != KomgaSortMode.title,
                  ),
                );
              },
              itemBuilder: (_) => KomgaSortMode.values
                  .map(
                    (KomgaSortMode value) => PopupMenuItem(
                      value: value,
                      child: _popupItem(
                        _sortModeLabel(value),
                        value == _preferences.sortMode,
                      ),
                    ),
                  )
                  .toList(),
              child: _toolbarAnchor(
                icon: Icons.sort,
                label: _sortModeLabel(_preferences.sortMode),
              ),
            ),
            IconButton.filledTonal(
              tooltip: _preferences.descending
                  ? 'komgaDescending'.tr
                  : 'komgaAscending'.tr,
              onPressed: () {
                _updatePreferences(
                  _preferences.copyWith(descending: !_preferences.descending),
                );
              },
              icon: Icon(
                _preferences.descending
                    ? Icons.arrow_downward
                    : Icons.arrow_upward,
              ),
            ),
            SegmentedButton<KomgaDisplayMode>(
              segments: <ButtonSegment<KomgaDisplayMode>>[
                ButtonSegment<KomgaDisplayMode>(
                  value: KomgaDisplayMode.grid,
                  icon: const Icon(Icons.grid_view_outlined),
                  tooltip: 'komgaCardView'.tr,
                ),
                ButtonSegment<KomgaDisplayMode>(
                  value: KomgaDisplayMode.list,
                  icon: const Icon(Icons.view_list_outlined),
                  tooltip: 'komgaListView'.tr,
                ),
                ButtonSegment<KomgaDisplayMode>(
                  value: KomgaDisplayMode.detail,
                  icon: const Icon(Icons.view_agenda_outlined),
                  tooltip: 'komgaDetailView'.tr,
                ),
              ],
              selected: <KomgaDisplayMode>{_preferences.displayMode},
              showSelectedIcon: false,
              onSelectionChanged: (Set<KomgaDisplayMode> value) {
                _updatePreferences(
                  _preferences.copyWith(displayMode: value.single),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbarAnchor({required IconData icon, required String label}) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(label),
          const SizedBox(width: 4),
          const Icon(Icons.arrow_drop_down, size: 18),
        ],
      ),
    );
  }

  Widget _popupItem(String label, bool selected) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 28,
          child: selected ? const Icon(Icons.check, size: 20) : null,
        ),
        Expanded(child: Text(label)),
      ],
    );
  }

  Widget _buildLibraryContent(BuildContext context) {
    if (_loading && !_hasLibraryData) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null && !_hasLibraryData) {
      return _buildError();
    }

    if (_selectedSeries != null) {
      final List<KomgaBookBrowseItem> raw = _bookItems
          .where(
            (KomgaBookBrowseItem item) =>
                item.book.seriesId == _selectedSeries!.id,
          )
          .toList();
      final List<KomgaBookBrowseItem> visible =
          filterAndSortKomgaItems<KomgaBookBrowseItem>(
            raw,
            filter: _preferences.progressFilter,
            sortMode: _preferences.sortMode,
            descending: _preferences.descending,
          );
      return _buildBookCollection(raw, visible);
    }

    if (_preferences.libraryView == KomgaLibraryView.books) {
      final List<KomgaBookBrowseItem> visible =
          filterAndSortKomgaItems<KomgaBookBrowseItem>(
            _bookItems,
            filter: _preferences.progressFilter,
            sortMode: _preferences.sortMode,
            descending: _preferences.descending,
          );
      return _buildBookCollection(_bookItems, visible);
    }

    final List<KomgaSeriesBrowseItem> visible =
        filterAndSortKomgaItems<KomgaSeriesBrowseItem>(
          _seriesItems,
          filter: _preferences.progressFilter,
          sortMode: _preferences.sortMode,
          descending: _preferences.descending,
        );
    return _buildSeriesCollection(_seriesItems, visible);
  }

  Widget _buildBookCollection(
    List<KomgaBookBrowseItem> raw,
    List<KomgaBookBrowseItem> visible,
  ) {
    if (raw.isEmpty) {
      return _buildEmptyList('komgaNoBooks'.tr);
    }
    if (visible.isEmpty) {
      return _buildEmptyList('komgaNoMatchingItems'.tr);
    }
    return switch (_preferences.displayMode) {
      KomgaDisplayMode.grid => _buildGrid(
        visible.length,
        (_, int index) => _buildBookCard(visible[index]),
      ),
      KomgaDisplayMode.list => _buildList(
        visible.length,
        (_, int index) => _buildBookListItem(visible[index]),
      ),
      KomgaDisplayMode.detail => _buildDetailList(
        visible.length,
        (_, int index) => _buildBookDetailItem(visible[index]),
      ),
    };
  }

  Widget _buildSeriesCollection(
    List<KomgaSeriesBrowseItem> raw,
    List<KomgaSeriesBrowseItem> visible,
  ) {
    if (raw.isEmpty) {
      return _buildEmptyList('komgaNoSeries'.tr);
    }
    if (visible.isEmpty) {
      return _buildEmptyList('komgaNoMatchingItems'.tr);
    }
    return switch (_preferences.displayMode) {
      KomgaDisplayMode.grid => _buildGrid(
        visible.length,
        (_, int index) => _buildSeriesCard(visible[index]),
      ),
      KomgaDisplayMode.list => _buildList(
        visible.length,
        (_, int index) => _buildSeriesListItem(visible[index]),
      ),
      KomgaDisplayMode.detail => _buildDetailList(
        visible.length,
        (_, int index) => _buildSeriesDetailItem(visible[index]),
      ),
    };
  }

  Widget _buildGrid(int itemCount, IndexedWidgetBuilder itemBuilder) {
    return RefreshIndicator(
      onRefresh: _syncProgressAndRefresh,
      child: GridView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          childAspectRatio: 0.53,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: itemCount,
        itemBuilder: itemBuilder,
      ),
    );
  }

  Widget _buildList(int itemCount, IndexedWidgetBuilder itemBuilder) {
    return RefreshIndicator(
      onRefresh: _syncProgressAndRefresh,
      child: ListView.separated(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: itemCount,
        separatorBuilder: (_, __) => const SizedBox(height: 2),
        itemBuilder: itemBuilder,
      ),
    );
  }

  Widget _buildDetailList(int itemCount, IndexedWidgetBuilder itemBuilder) {
    return RefreshIndicator(
      onRefresh: _syncProgressAndRefresh,
      child: ListView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        itemCount: itemCount,
        itemBuilder: itemBuilder,
      ),
    );
  }

  Widget _buildEmptyList(String message) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return RefreshIndicator(
          onRefresh: _syncProgressAndRefresh,
          child: ListView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            children: <Widget>[
              SizedBox(
                height: max(constraints.maxHeight, 180),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(message, textAlign: TextAlign.center),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSeriesCard(KomgaSeriesBrowseItem item) {
    final KomgaClient client = _client!;
    final String url = client.seriesThumbnailUrl(item.series.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _enterSeries(item.series),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _buildImage(url, client.imageCacheKey(url)),
                  _buildCoverBadges(item),
                ],
              ),
            ),
            _buildLinearProgressIndicator(item),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 3),
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 3),
              child: Text(
                _seriesStatusText(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 9),
              child: Text(
                _addedAtText(item.addedAt),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBookCard(KomgaBookBrowseItem item) {
    final KomgaClient client = _client!;
    final KomgaBook book = item.book;
    final String url = client.bookThumbnailUrl(book.id);
    final bool isOpening = _openingBookId == book.id;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openingBookId != null || _loading || _importingProgress
            ? null
            : () => _openBook(book),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _buildImage(url, client.imageCacheKey(url)),
                  _buildCoverBadges(item),
                  if (isOpening)
                    const ColoredBox(
                      color: Colors.black45,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
            ),
            _buildLinearProgressIndicator(item),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 3),
              child: Text(
                book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 3),
              child: Text(
                _bookStatusText(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 9),
              child: Text(
                _addedAtText(item.addedAt),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeriesListItem(KomgaSeriesBrowseItem item) {
    final KomgaClient client = _client!;
    final String url = client.seriesThumbnailUrl(item.series.id);
    final Widget? progressIndicator = _buildCircularProgressIndicator(item);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: _buildListThumbnail(url, client.imageCacheKey(url)),
      title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[Text(_seriesStatusText(item))],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (item.isNew) _buildNewBadge(),
          if (item.isNew && progressIndicator != null) const SizedBox(width: 8),
          if (progressIndicator != null) progressIndicator,
          if (item.isNew || progressIndicator != null) const SizedBox(width: 6),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () => _enterSeries(item.series),
    );
  }

  Widget _buildBookListItem(KomgaBookBrowseItem item) {
    final KomgaClient client = _client!;
    final KomgaBook book = item.book;
    final String url = client.bookThumbnailUrl(book.id);
    final bool isOpening = _openingBookId == book.id;
    final Widget? progressIndicator = _buildCircularProgressIndicator(item);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: _buildListThumbnail(url, client.imageCacheKey(url)),
      title: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            <String>[
              if (book.seriesTitle.isNotEmpty) book.seriesTitle,
              _bookStatusText(item),
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      trailing: isOpening
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (item.isNew) _buildNewBadge(),
                if (item.isNew && progressIndicator != null)
                  const SizedBox(width: 8),
                if (progressIndicator != null)
                  progressIndicator
                else if (!item.isNew)
                  _statusIcon(item.readingStatus),
              ],
            ),
      onTap: _openingBookId != null || _loading || _importingProgress
          ? null
          : () => _openBook(book),
    );
  }

  Widget _buildSeriesDetailItem(KomgaSeriesBrowseItem item) {
    final KomgaClient client = _client!;
    final KomgaSeries series = item.series;
    final String url = client.seriesThumbnailUrl(series.id);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _enterSeries(series),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _buildDetailThumbnail(url, client.imageCacheKey(url)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            item.title,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (item.isNew) _buildNewBadge(),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _buildStatusWithCircularProgress(item),
                    const SizedBox(height: 8),
                    Text(_seriesStatusText(item)),
                    const SizedBox(height: 10),
                    Text(_addedAtText(item.addedAt)),
                    if (item.lastReadAt != null)
                      Text(_lastReadAtText(item.lastReadAt)),
                    if (series.authors.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        series.authors
                            .map((KomgaAuthor author) => author.name)
                            .where((String name) => name.isNotEmpty)
                            .join(', '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (series.summary.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        series.summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (series.tags.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        series.tags.take(6).join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBookDetailItem(KomgaBookBrowseItem item) {
    final KomgaClient client = _client!;
    final KomgaBook book = item.book;
    final String url = client.bookThumbnailUrl(book.id);
    final bool isOpening = _openingBookId == book.id;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openingBookId != null || _loading || _importingProgress
            ? null
            : () => _openBook(book),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Stack(
                children: <Widget>[
                  _buildDetailThumbnail(url, client.imageCacheKey(url)),
                  if (isOpening)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black45,
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            book.title,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (item.isNew) _buildNewBadge(),
                      ],
                    ),
                    if (book.seriesTitle.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        <String>[
                          book.seriesTitle,
                          if (book.number.isNotEmpty) book.number,
                        ].join(' · '),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 8),
                    _buildStatusWithCircularProgress(item),
                    const SizedBox(height: 8),
                    Text(_bookStatusText(item)),
                    const SizedBox(height: 10),
                    Text(_addedAtText(item.addedAt)),
                    if (item.lastReadAt != null)
                      Text(_lastReadAtText(item.lastReadAt)),
                    const SizedBox(height: 6),
                    Text(
                      <String>[
                        '${book.pageCount}P',
                        if (book.mediaProfile.isNotEmpty) book.mediaProfile,
                        if (book.size.isNotEmpty) book.size,
                      ].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (book.authors.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        book.authors
                            .map((KomgaAuthor author) => author.name)
                            .where((String name) => name.isNotEmpty)
                            .join(', '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (book.summary.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        book.summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (book.tags.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        book.tags.take(6).join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImage(String url, String cacheKey) {
    return EHImage(
      galleryImage: GalleryImage(
        url: url,
        headers: _client!.imageHeaders,
        cacheKey: cacheKey,
      ),
      fit: BoxFit.cover,
    );
  }

  Widget _buildListThumbnail(String url, String cacheKey) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(width: 54, height: 76, child: _buildImage(url, cacheKey)),
    );
  }

  Widget _buildDetailThumbnail(String url, String cacheKey) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 116,
        height: 174,
        child: _buildImage(url, cacheKey),
      ),
    );
  }

  Widget _buildCoverBadges(KomgaBrowseItem item) {
    return PositionedDirectional(
      top: 8,
      start: 8,
      end: 8,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: _buildStatusBadge(item.readingStatus),
            ),
          ),
          if (item.isNew)
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.topEnd,
                child: _buildNewBadge(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(KomgaReadingStatus status) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final (Color background, Color foreground) = switch (status) {
      KomgaReadingStatus.unread => (
        colors.surfaceContainerHighest.withValues(alpha: 0.92),
        colors.onSurface,
      ),
      KomgaReadingStatus.inProgress => (
        colors.primaryContainer.withValues(alpha: 0.94),
        colors.onPrimaryContainer,
      ),
      KomgaReadingStatus.read => (
        colors.tertiaryContainer.withValues(alpha: 0.94),
        colors.onTertiaryContainer,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        _readingStatusLabel(status),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildNewBadge() {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'komgaNewlyAdded'.tr,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: colors.onSecondaryContainer,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _statusIcon(KomgaReadingStatus status) {
    return Icon(switch (status) {
      KomgaReadingStatus.unread => Icons.radio_button_unchecked,
      KomgaReadingStatus.inProgress => Icons.play_circle_outline,
      KomgaReadingStatus.read => Icons.check_circle_outline,
    });
  }

  double? _progressValue(KomgaBrowseItem item) {
    return switch (item) {
      KomgaBookBrowseItem book when book.progress != null =>
        book.progressFraction,
      KomgaSeriesBrowseItem series
          when series.readingStatus != KomgaReadingStatus.unread =>
        series.progressFraction,
      _ => null,
    };
  }

  String _progressIdentity(KomgaBrowseItem item) {
    return switch (item) {
      KomgaBookBrowseItem book => 'book:${book.book.id}',
      KomgaSeriesBrowseItem series => 'series:${series.series.id}',
      _ => item.title,
    };
  }

  Widget _buildLinearProgressIndicator(KomgaBrowseItem item) {
    final double? value = _progressValue(item);
    if (value == null) {
      return const SizedBox(height: 3);
    }
    return LinearProgressIndicator(
      key: ValueKey<String>(
        'komgaLinearReadProgress:${_progressIdentity(item)}',
      ),
      value: value,
      minHeight: 3,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }

  Widget? _buildCircularProgressIndicator(
    KomgaBrowseItem item, {
    double size = 18,
  }) {
    final double? value = _progressValue(item);
    if (value == null) {
      return null;
    }
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: CircularProgressIndicator(
        key: ValueKey<String>(
          'komgaCircularReadProgress:${_progressIdentity(item)}',
        ),
        value: value,
        strokeWidth: 2,
        backgroundColor: colors.surfaceContainerHighest,
        valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
      ),
    );
  }

  Widget _buildStatusWithCircularProgress(KomgaBrowseItem item) {
    final Widget? progressIndicator = _buildCircularProgressIndicator(item);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _buildStatusBadge(item.readingStatus),
        if (progressIndicator != null) ...<Widget>[
          const SizedBox(width: 8),
          progressIndicator,
        ],
      ],
    );
  }

  String _progressFilterLabel(KomgaProgressFilter value) {
    return switch (value) {
      KomgaProgressFilter.all => 'komgaAllStatuses'.tr,
      KomgaProgressFilter.unread => 'komgaUnread'.tr,
      KomgaProgressFilter.inProgress => 'komgaInProgress'.tr,
      KomgaProgressFilter.read => 'komgaRead'.tr,
      KomgaProgressFilter.newlyAdded => 'komgaNewlyAdded'.tr,
    };
  }

  String _sortModeLabel(KomgaSortMode value) {
    return switch (value) {
      KomgaSortMode.addedAt => 'komgaSortAdded'.tr,
      KomgaSortMode.lastReadAt => 'komgaSortLastRead'.tr,
      KomgaSortMode.title => 'komgaSortTitle'.tr,
    };
  }

  String _readingStatusLabel(KomgaReadingStatus value) {
    return switch (value) {
      KomgaReadingStatus.unread => 'komgaUnread'.tr,
      KomgaReadingStatus.inProgress => 'komgaInProgress'.tr,
      KomgaReadingStatus.read => 'komgaRead'.tr,
    };
  }

  String _bookStatusText(KomgaBookBrowseItem item) {
    if (!item.book.isReadable) {
      return 'komgaBookNotReady'.tr;
    }
    return switch (item.readingStatus) {
      KomgaReadingStatus.unread => 'komgaUnreadPages'.trParams(<String, String>{
        'total': item.book.pageCount.toString(),
      }),
      KomgaReadingStatus.inProgress =>
        'komgaContinueAt'.trParams(<String, String>{
          'current': item.currentPage.toString(),
          'total': item.book.pageCount.toString(),
        }),
      KomgaReadingStatus.read => 'komgaCompletedPages'.trParams(
        <String, String>{'total': item.book.pageCount.toString()},
      ),
    };
  }

  String _seriesStatusText(KomgaSeriesBrowseItem item) {
    return 'komgaSeriesProgress'.trParams(<String, String>{
      'completed': item.readCount.toString(),
      'ongoing': item.inProgressCount.toString(),
      'remaining': item.unreadCount.toString(),
    });
  }

  String _addedAtText(DateTime? date) {
    return 'komgaAddedAt'.trParams(<String, String>{
      'date': date == null
          ? '—'
          : DateFormat('yyyy-MM-dd').format(date.toLocal()),
    });
  }

  String _lastReadAtText(DateTime? date) {
    return 'komgaLastReadAt'.trParams(<String, String>{
      'date': date == null
          ? '—'
          : DateFormat('yyyy-MM-dd HH:mm').format(date.toLocal()),
    });
  }

  Future<void> _initialize() async {
    _appliedConfigurationHash = _configurationHash;
    if (!komgaSetting.isConfigured) {
      setState(() {
        _loading = false;
        _errorMessage = null;
      });
      return;
    }
    await _loadPreferences();
    if (!mounted) {
      return;
    }
    try {
      _client = widget.clientFactory();
    } catch (e) {
      setState(() => _errorMessage = KomgaClient.friendlyError(e));
      return;
    }
    unawaited(syncService.syncReadProgress());
    await _loadLibraries();
  }

  Future<void> _loadPreferences() async {
    if (_preferencesLoaded) {
      return;
    }
    final String? value = await localConfigService.read(
      configKey: ConfigEnum.komgaBrowseSetting,
    );
    if (!mounted) {
      return;
    }
    _preferences = KomgaBrowsePreferences.fromJsonString(value);
    _preferencesLoaded = true;
  }

  Future<void> _persistPreferences() async {
    await localConfigService.write(
      configKey: ConfigEnum.komgaBrowseSetting,
      value: _preferences.toJsonString(),
    );
  }

  void _updatePreferences(KomgaBrowsePreferences preferences) {
    setState(() => _preferences = preferences);
    unawaited(_persistPreferences());
    _scrollToTop();
  }

  Future<void> _loadLibraries() async {
    final int generation = ++_loadGeneration;
    final bool hadData = _libraries.isNotEmpty;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final List<KomgaLibrary> libraries = <KomgaLibrary>[
        ...await _client!.getLibraries(),
      ];
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      libraries.sort(
        (KomgaLibrary a, KomgaLibrary b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      setState(() => _libraries = List<KomgaLibrary>.unmodifiable(libraries));
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        final String message = KomgaClient.friendlyError(e);
        if (hadData) {
          toast(message, isShort: false);
        } else {
          setState(() => _errorMessage = message);
        }
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _enterLibrary(KomgaLibrary library) async {
    final KomgaClient client = _client!;
    final DateTime? lastSeen = _preferences.lastSeen(
      client.sourceFingerprint,
      library.id,
    );
    _bookOperationGeneration++;
    setState(() {
      _selectedLibrary = library;
      _selectedSeries = null;
      _series = const <KomgaSeries>[];
      _books = const <KomgaBook>[];
      _seriesItems = const <KomgaSeriesBrowseItem>[];
      _bookItems = const <KomgaBookBrowseItem>[];
      _errorMessage = null;
      _openingBookId = null;
      _newSince =
          lastSeen ??
          (_preferences.hasSeenLibrary(client.sourceFingerprint, library.id)
              ? _emptyLibraryBaseline
              : null);
    });
    _scrollToTop();
    await _loadLibraryContent();
  }

  void _enterSeries(KomgaSeries series) {
    setState(() => _selectedSeries = series);
    _scrollToTop();
  }

  Future<void> _loadLibraryContent() async {
    final KomgaLibrary? library = _selectedLibrary;
    final KomgaClient? client = _client;
    if (library == null || client == null) {
      return;
    }
    final int generation = ++_loadGeneration;
    final bool hadData = _hasLibraryData;
    _bookOperationGeneration++;
    setState(() {
      _loading = true;
      _errorMessage = null;
      _openingBookId = null;
    });

    try {
      late List<KomgaSeries> series;
      late List<KomgaBook> books;
      await Future.wait<void>(<Future<void>>[
        client.getAllSeries(libraryId: library.id).then((value) {
          series = value;
        }),
        client.getAllBooks(libraryId: library.id).then((value) {
          books = value;
        }),
      ]);
      final Set<String> progressKeys = books
          .map((KomgaBook book) => client.progressRecordKey(book.id))
          .toSet();
      final Map<String, ReadProgressEntry> progress = await readProgressService
          .getReadProgressEntriesByKeys(progressKeys);
      if (!mounted || generation != _loadGeneration) {
        return;
      }

      setState(() {
        _series = List<KomgaSeries>.unmodifiable(series);
        _books = List<KomgaBook>.unmodifiable(books);
        _rebuildBrowseItems(progress);
        if (_selectedSeries != null) {
          final String selectedSeriesId = _selectedSeries!.id;
          final List<KomgaSeries> matchingSeries = _series
              .where((KomgaSeries item) => item.id == selectedSeriesId)
              .toList(growable: false);
          _selectedSeries = matchingSeries.isEmpty
              ? null
              : matchingSeries.first;
        }
        final DateTime? latestCreatedDate = _latestCreatedDate(series, books);
        // The first successful visit establishes a baseline only after the
        // initial items have been built, so existing content is not marked as
        // new while later refreshes in this same visit still can be.
        _newSince ??= latestCreatedDate ?? _emptyLibraryBaseline;
        _preferences = _preferences.markLibrarySeen(
          client.sourceFingerprint,
          library.id,
          latestCreatedDate,
        );
      });
      unawaited(_persistPreferences());
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        final String message = KomgaClient.friendlyError(e);
        if (hadData) {
          toast(message, isShort: false);
        } else {
          setState(() => _errorMessage = message);
        }
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _reloadProgress() async {
    final KomgaClient? client = _client;
    final KomgaLibrary? library = _selectedLibrary;
    if (client == null || library == null || _books.isEmpty) {
      return;
    }
    final int generation = _loadGeneration;
    final List<KomgaBook> books = _books;
    final Set<String> progressKeys = books
        .map((KomgaBook book) => client.progressRecordKey(book.id))
        .toSet();
    final Map<String, ReadProgressEntry> progress = await readProgressService
        .getReadProgressEntriesByKeys(progressKeys);
    if (!mounted ||
        generation != _loadGeneration ||
        !identical(client, _client) ||
        library.id != _selectedLibrary?.id ||
        !identical(books, _books)) {
      return;
    }
    setState(() => _rebuildBrowseItems(progress));
  }

  void _rebuildBrowseItems(Map<String, ReadProgressEntry> progress) {
    final KomgaClient client = _client!;
    final List<KomgaBookBrowseItem> bookItems = _books
        .map(
          (KomgaBook book) => KomgaBookBrowseItem.fromBook(
            book: book,
            progress: progress[client.progressRecordKey(book.id)],
            newSince: _newSince,
          ),
        )
        .toList(growable: false);
    final Map<String, List<KomgaBookBrowseItem>> booksBySeries =
        <String, List<KomgaBookBrowseItem>>{};
    for (final KomgaBookBrowseItem item in bookItems) {
      booksBySeries.putIfAbsent(item.book.seriesId, () => []).add(item);
    }
    _bookItems = List<KomgaBookBrowseItem>.unmodifiable(bookItems);
    _seriesItems = List<KomgaSeriesBrowseItem>.unmodifiable(
      _series.map(
        (KomgaSeries series) => KomgaSeriesBrowseItem.fromSeries(
          series: series,
          books: booksBySeries[series.id] ?? const <KomgaBookBrowseItem>[],
          newSince: _newSince,
        ),
      ),
    );
  }

  Future<void> _openBook(KomgaBook book) async {
    if (_openingBookId != null || _loading || _importingProgress) {
      return;
    }
    if (!book.isReadable) {
      toast('komgaBookNotReady'.tr, isShort: false);
      return;
    }

    final KomgaClient? client = _client;
    final KomgaLibrary? library = _selectedLibrary;
    if (client == null || library == null) {
      return;
    }
    final int operation = ++_bookOperationGeneration;
    setState(() => _openingBookId = book.id);
    try {
      final List<KomgaBookPage> pages = await client.getBookPages(book.id)
        ..sort(
          (KomgaBookPage a, KomgaBookPage b) => a.number.compareTo(b.number),
        );
      if (pages.isEmpty) {
        throw StateError('komgaBookHasNoPages'.tr);
      }

      final String progressKey = client.progressRecordKey(book.id);
      final ReadProgressEntry? saved = await readProgressService
          .getReadProgressEntryByKey(progressKey);
      if (!_isCurrentBookOperation(operation, client, library, book.id)) {
        return;
      }
      final int initialIndex = min(
        max(saved?.pageIndex ?? 0, 0),
        pages.length - 1,
      );
      final List<GalleryImage> images = List<GalleryImage>.generate(
        pages.length,
        (int index) {
          final KomgaBookPage page = pages[index];
          final int pageNumber = page.number > 0 ? page.number : index + 1;
          final String pageUrl = client.bookPageUrl(book.id, pageNumber);
          return GalleryImage(
            url: pageUrl,
            width: page.width?.toDouble(),
            height: page.height?.toDouble(),
            headers: client.imageHeaders,
            cacheKey: client.imageCacheKey(pageUrl),
            downloadStatus: DownloadStatus.downloaded,
          );
        },
      );

      final ReadPageInfo readPageInfo = ReadPageInfo(
        mode: ReadMode.remote,
        galleryTitle: book.title,
        initialIndex: initialIndex,
        pageCount: images.length,
        readProgressRecordStorageKey: progressKey,
        images: images,
        useSuperResolution: false,
        reportReadProgress: (int imageIndex) =>
            client.reportReadProgress(book.id, imageIndex),
      );
      await toRoute<dynamic>(Routes.read, arguments: readPageInfo);
      await _reloadProgress();
    } catch (e) {
      if (_isCurrentBookOperation(operation, client, library, book.id)) {
        toast(KomgaClient.friendlyError(e), isShort: false);
      }
    } finally {
      if (mounted &&
          operation == _bookOperationGeneration &&
          _openingBookId == book.id) {
        setState(() => _openingBookId = null);
      }
    }
  }

  Future<void> _importKomgaProgress() async {
    if (!komgaSetting.isConfigured ||
        _client == null ||
        _loading ||
        _importingProgress ||
        _openingBookId != null) {
      return;
    }

    final KomgaClient client = _client!;
    final int operation = ++_progressImportGeneration;
    setState(() => _importingProgress = true);
    try {
      final List<KomgaBook> books = await client.getAllReadProgressBooks();
      if (!_isCurrentProgressImport(operation, client)) {
        return;
      }

      final List<ReadProgressEntry> entries = <ReadProgressEntry>[];
      for (final KomgaBook book in books) {
        final KomgaReadProgress? progress = book.readProgress;
        if (progress == null) {
          continue;
        }
        final DateTime? lastReadAt =
            progress.readDate ??
            progress.lastModifiedDate ??
            progress.createdDate;
        if (lastReadAt == null) {
          continue;
        }

        late final int pageIndex;
        if (progress.completed) {
          if (book.pageCount <= 0) {
            continue;
          }
          pageIndex = book.pageCount - 1;
        } else {
          if (progress.page < 0) {
            continue;
          }
          final int nonNegativePageIndex = max(progress.page - 1, 0);
          pageIndex = book.pageCount > 0
              ? min(nonNegativePageIndex, book.pageCount - 1)
              : nonNegativePageIndex;
        }
        entries.add(
          ReadProgressEntry(
            key: client.progressRecordKey(book.id),
            pageIndex: pageIndex,
            lastReadAt: lastReadAt,
          ),
        );
      }

      if (!_isCurrentProgressImport(operation, client)) {
        return;
      }
      if (entries.isEmpty) {
        toast('komgaImportProgressEmpty'.tr);
        return;
      }

      final ReadProgressImportResult result = await readProgressService
          .importReadProgressEntries(entries);
      if (!_isCurrentProgressImport(operation, client)) {
        return;
      }
      if (result.imported > 0) {
        await _reloadProgress();
        if (!_isCurrentProgressImport(operation, client)) {
          return;
        }
        toast(
          'komgaImportProgressImported'.trParams(<String, String>{
            'count': result.imported.toString(),
          }),
          isShort: false,
        );
      } else if (result.isUpToDate) {
        toast('komgaImportProgressUpToDate'.tr);
      } else {
        toast('komgaImportProgressEmpty'.tr);
      }
    } catch (e) {
      if (_isCurrentProgressImport(operation, client)) {
        toast(KomgaClient.friendlyError(e), isShort: false);
      }
    } finally {
      if (_isCurrentProgressImport(operation, client)) {
        setState(() => _importingProgress = false);
      }
    }
  }

  Future<void> _refreshCurrent() async {
    if (!komgaSetting.isConfigured || _importingProgress) {
      return;
    }
    if (_client == null) {
      await _initialize();
      return;
    }
    if (_selectedLibrary != null) {
      await _loadLibraryContent();
    } else {
      await _loadLibraries();
    }
  }

  Future<void> _syncProgressAndRefresh() async {
    if (_importingProgress) {
      return;
    }

    final int configurationHash = _configurationHash;
    final KomgaClient? client = _client;
    final SyncResult? result = await syncService.syncReadProgress(
      requireAutoSync: false,
      force: true,
    );
    if (!mounted || configurationHash != _configurationHash) {
      return;
    }
    if (client != null && !identical(client, _client)) {
      return;
    }
    if (result != null && !result.success) {
      toast('${'syncFailed'.tr}: ${result.message}', isShort: false);
    }
    await _refreshCurrent();
  }

  Future<void> _openSettings() async {
    if (_importingProgress) {
      return;
    }
    _bookOperationGeneration++;
    if (_openingBookId != null && mounted) {
      setState(() => _openingBookId = null);
    }
    final dynamic changed = await toRoute<dynamic>(Routes.komgaSettings);
    if (changed == true) {
      await _reloadForSettingChange();
    }
  }

  Future<void> _reloadForSettingChange() async {
    if (!mounted || _appliedConfigurationHash == _configurationHash) {
      return;
    }
    _loadGeneration++;
    _bookOperationGeneration++;
    _progressImportGeneration++;
    setState(() {
      _client = null;
      _selectedLibrary = null;
      _selectedSeries = null;
      _libraries = const <KomgaLibrary>[];
      _series = const <KomgaSeries>[];
      _books = const <KomgaBook>[];
      _seriesItems = const <KomgaSeriesBrowseItem>[];
      _bookItems = const <KomgaBookBrowseItem>[];
      _newSince = null;
      _errorMessage = null;
      _openingBookId = null;
      _importingProgress = false;
    });
    await _initialize();
  }

  int get _configurationHash => Object.hash(
    komgaSetting.serverUrl.value,
    komgaSetting.username.value,
    komgaSetting.password.value,
    komgaSetting.apiKey.value,
    komgaSetting.connectionId.value,
  );

  void _goUp() {
    _bookOperationGeneration++;
    if (_selectedSeries != null) {
      setState(() {
        _selectedSeries = null;
        _openingBookId = null;
      });
      _scrollToTop();
      return;
    }
    if (_selectedLibrary != null) {
      _loadGeneration++;
      setState(() {
        _loading = false;
        _selectedLibrary = null;
        _series = const <KomgaSeries>[];
        _books = const <KomgaBook>[];
        _seriesItems = const <KomgaSeriesBrowseItem>[];
        _bookItems = const <KomgaBookBrowseItem>[];
        _newSince = null;
        _errorMessage = null;
        _openingBookId = null;
      });
      _scrollToTop();
    }
  }

  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  void _closeDrawer() {
    _scaffoldKey.currentState?.closeDrawer();
  }

  void _prepareSourceSwitch() {
    _bookOperationGeneration++;
    _progressImportGeneration++;
    if ((_openingBookId != null || _importingProgress) && mounted) {
      setState(() {
        _openingBookId = null;
        _importingProgress = false;
      });
    }
    _closeDrawer();
  }

  void _handleProgressServiceRefresh() {
    if (!mounted || _selectedLibrary == null) {
      return;
    }
    _progressReloadTimer?.cancel();
    _progressReloadTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted && _selectedLibrary != null) {
        unawaited(_reloadProgress());
      }
    });
  }

  bool _isCurrentBookOperation(
    int operation,
    KomgaClient client,
    KomgaLibrary library,
    String bookId,
  ) {
    return mounted &&
        operation == _bookOperationGeneration &&
        identical(client, _client) &&
        library.id == _selectedLibrary?.id &&
        _openingBookId == bookId;
  }

  bool _isCurrentProgressImport(int operation, KomgaClient client) {
    return mounted &&
        operation == _progressImportGeneration &&
        identical(client, _client);
  }

  DateTime? _latestCreatedDate(
    List<KomgaSeries> series,
    List<KomgaBook> books,
  ) {
    DateTime? latest;
    for (final DateTime date in <DateTime?>[
      ...series.map((KomgaSeries item) => item.createdDate),
      ...books.map((KomgaBook item) => item.createdDate),
    ].whereType<DateTime>()) {
      if (latest == null || date.isAfter(latest)) {
        latest = date;
      }
    }
    return latest;
  }
}
