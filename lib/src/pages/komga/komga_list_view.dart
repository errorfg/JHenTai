import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/komga/komga_browse_models.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/komga/komga_query.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/pages/komga/komga_browse_controller.dart';
import 'package:jhentai/src/pages/komga/komga_filter_sheet.dart';
import 'package:jhentai/src/pages/komga/komga_item_widgets.dart';
import 'package:jhentai/src/pages/komga/komga_paged_loader.dart';

/// A paged series or book list with its toolbar. [header] is shown above the
/// toolbar (the series header on a series level).
class KomgaListView extends StatefulWidget {
  const KomgaListView({
    super.key,
    required this.controller,
    required this.level,
    required this.actions,
    required this.onRefresh,
    this.header,
  });

  final KomgaBrowseController controller;
  final KomgaLevel level;
  final KomgaItemActions actions;
  final Future<void> Function() onRefresh;
  final Widget? header;

  @override
  State<KomgaListView> createState() => _KomgaListViewState();
}

class _KomgaListViewState extends State<KomgaListView> {
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: widget.level.scrollOffset,
  );

  KomgaBrowseController get _controller => widget.controller;

  KomgaPagedLoader<Object> get _loader => switch (widget.level) {
    final KomgaListLevel level => level.loader,
    final KomgaSeriesLevel level => level.loader,
    _ => throw StateError('not a list level'),
  };

  KomgaQuery get _query => switch (widget.level) {
    final KomgaListLevel level => level.query,
    final KomgaSeriesLevel level => level.query,
    _ => throw StateError('not a list level'),
  };

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    widget.level.scrollOffset = _scroll.offset;
    if (_scroll.position.extentAfter < 800) {
      _loader.loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final KomgaItemViews views = KomgaItemViews(
      context,
      _controller.client,
      widget.actions,
    );
    final KomgaDisplayMode mode = _controller.preferences.displayMode;
    final List<Object> items = _loader.items;
    final DateTime? newSince = widget.level is KomgaListLevel
        ? (widget.level as KomgaListLevel).newSince
        : null;

    Widget itemAt(int index) {
      final Object item = items[index];
      return switch (item) {
        final KomgaSeries series => views.series(
          KomgaSeriesBrowseItem.fromSeries(series: series, newSince: newSince),
          mode,
        ),
        final KomgaBook book => views.book(
          _controller.bookItem(book, newSince: newSince),
          mode,
        ),
        _ => const SizedBox(),
      };
    }

    final Widget body = mode == KomgaDisplayMode.grid
        ? SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid.builder(
              gridDelegate: KomgaItemViews.gridDelegate,
              itemCount: items.length,
              itemBuilder: (_, int index) => itemAt(index),
            ),
          )
        : SliverPadding(
            padding: EdgeInsets.all(mode == KomgaDisplayMode.detail ? 12 : 0),
            sliver: SliverList.builder(
              itemCount: items.length,
              itemBuilder: (_, int index) => itemAt(index),
            ),
          );

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: <Widget>[
          if (widget.header != null) SliverToBoxAdapter(child: widget.header),
          SliverToBoxAdapter(child: _toolbar(context)),
          if (!_query.filters.isEmpty)
            SliverToBoxAdapter(child: _activeFilters()),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          body,
          SliverToBoxAdapter(child: _footer(context)),
        ],
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final KomgaLevel level = widget.level;
    final bool isList = level is KomgaListLevel;
    final bool isSeriesTarget = _query.target == KomgaTarget.series;
    final List<KomgaSortMode> sortModes = <KomgaSortMode>[
      if (_query.hasSearch) KomgaSortMode.relevance,
      if (!isSeriesTarget) KomgaSortMode.number,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          if (isList)
            SegmentedButton<KomgaTarget>(
              key: const ValueKey<String>('komgaTargetToggle'),
              segments: <ButtonSegment<KomgaTarget>>[
                ButtonSegment<KomgaTarget>(
                  value: KomgaTarget.series,
                  icon: const Icon(Icons.collections_bookmark_outlined),
                  label: Text('komgaSeriesView'.tr),
                ),
                ButtonSegment<KomgaTarget>(
                  value: KomgaTarget.books,
                  icon: const Icon(Icons.menu_book_outlined),
                  label: Text('komgaAllBooksView'.tr),
                ),
              ],
              selected: <KomgaTarget>{_query.target},
              showSelectedIcon: false,
              onSelectionChanged: (Set<KomgaTarget> value) =>
                  _controller.setTarget(level, value.single),
            ),
          _menu<KomgaProgressFilter>(
            icon: Icons.filter_list,
            label: progressFilterLabel(_query.progress),
            values: progressFilters,
            selected: _query.progress,
            labelOf: progressFilterLabel,
            onSelected: (KomgaProgressFilter value) =>
                _controller.setProgressFilter(level, value),
          ),
          _menu<KomgaSortMode>(
            icon: Icons.sort,
            label: sortModeLabel(_query.sortMode),
            values: sortModes,
            selected: _query.sortMode,
            labelOf: sortModeLabel,
            onSelected: (KomgaSortMode value) => _controller.setSort(
              level,
              value,
              value == KomgaSortMode.title || value == KomgaSortMode.number
                  ? false
                  : true,
            ),
          ),
          if (_query.sortMode != KomgaSortMode.relevance)
            IconButton.filledTonal(
              tooltip: _query.descending
                  ? 'komgaDescending'.tr
                  : 'komgaAscending'.tr,
              onPressed: () => _controller.setSort(
                level,
                _query.sortMode,
                !_query.descending,
              ),
              icon: Icon(
                _query.descending ? Icons.arrow_downward : Icons.arrow_upward,
              ),
            ),
          if (level is KomgaListLevel)
            Badge(
              isLabelVisible: !_query.filters.isEmpty,
              label: Text(_query.filters.count.toString()),
              child: IconButton.filledTonal(
                key: const ValueKey<String>('komgaFilterButton'),
                tooltip: 'komgaFilters'.tr,
                onPressed: () => _openFilterSheet(level),
                icon: const Icon(Icons.tune),
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
            selected: <KomgaDisplayMode>{_controller.preferences.displayMode},
            showSelectedIcon: false,
            onSelectionChanged: (Set<KomgaDisplayMode> value) =>
                _controller.setDisplayMode(value.single),
          ),
        ],
      ),
    );
  }

  Widget _activeFilters() {
    final KomgaListLevel level = widget.level as KomgaListLevel;
    final KomgaFilters filters = _query.filters;
    Widget chip(String text, KomgaFilters without) => InputChip(
      label: Text(text),
      onDeleted: () => _controller.setFilters(level, without),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final String v in filters.authors)
            chip(v, filters.copyWith(authors: {...filters.authors}..remove(v))),
          for (final String v in filters.publishers)
            chip(v, filters.copyWith(publishers: {...filters.publishers}..remove(v))),
          for (final String v in filters.languages)
            chip(v, filters.copyWith(languages: {...filters.languages}..remove(v))),
          for (final String v in filters.genres)
            chip(v, filters.copyWith(genres: {...filters.genres}..remove(v))),
          for (final String v in filters.tags)
            chip(v, filters.copyWith(tags: {...filters.tags}..remove(v))),
        ],
      ),
    );
  }

  Future<void> _openFilterSheet(KomgaListLevel level) async {
    final KomgaFilters? result = await showKomgaFilterSheet(
      context,
      controller: _controller,
      libraryId: level.query.libraryId,
      target: level.query.target,
      initial: level.query.filters,
    );
    if (result != null) {
      await _controller.setFilters(level, result);
    }
  }

  Widget _footer(BuildContext context) {
    final KomgaPagedLoader<Object> loader = _loader;
    if (loader.error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: <Widget>[
            Text(
              KomgaClient.friendlyError(loader.error!),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: loader.loadMore,
              child: Text('komgaLoadFailedRetry'.tr),
            ),
          ],
        ),
      );
    }
    if (loader.loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (loader.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(48),
        child: Center(
          child: Text(
            _query.filters.isEmpty && _query.progress == KomgaProgressFilter.all
                ? (_query.target == KomgaTarget.series
                      ? 'komgaNoSeries'.tr
                      : 'komgaNoBooks'.tr)
                : 'komgaNoMatchingItems'.tr,
          ),
        ),
      );
    }
    if (!loader.hasMore) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Text(
            'komgaAllLoaded'.tr,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return const SizedBox(height: 40);
  }

  Widget _menu<T>({
    required IconData icon,
    required String label,
    required List<T> values,
    required T selected,
    required String Function(T) labelOf,
    required void Function(T) onSelected,
  }) {
    return PopupMenuButton<T>(
      tooltip: label,
      initialValue: selected,
      onSelected: onSelected,
      itemBuilder: (_) => values
          .map(
            (T value) => PopupMenuItem<T>(
              value: value,
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 28,
                    child: value == selected
                        ? const Icon(Icons.check, size: 20)
                        : null,
                  ),
                  Expanded(child: Text(labelOf(value))),
                ],
              ),
            ),
          )
          .toList(),
      child: Container(
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
      ),
    );
  }
}

String progressFilterLabel(KomgaProgressFilter value) {
  return switch (value) {
    KomgaProgressFilter.all => 'komgaAllStatuses'.tr,
    KomgaProgressFilter.unread => 'komgaUnread'.tr,
    KomgaProgressFilter.inProgress => 'komgaInProgress'.tr,
    KomgaProgressFilter.read => 'komgaRead'.tr,
    KomgaProgressFilter.newlyAdded => 'komgaNewlyAdded'.tr,
  };
}

String sortModeLabel(KomgaSortMode value) {
  return switch (value) {
    KomgaSortMode.addedAt => 'komgaSortAdded'.tr,
    KomgaSortMode.lastReadAt => 'komgaSortLastRead'.tr,
    KomgaSortMode.title => 'komgaSortTitle'.tr,
    KomgaSortMode.number => 'komgaSortNumber'.tr,
    KomgaSortMode.relevance => 'komgaSortRelevance'.tr,
  };
}
