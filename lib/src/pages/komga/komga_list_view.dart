import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/komga/komga_browse_models.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/komga/komga_query.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/pages/komga/komga_browse_controller.dart';
import 'package:jhentai/src/pages/komga/komga_item_widgets.dart';
import 'package:jhentai/src/pages/komga/komga_paged_loader.dart';

/// A paged series or book list. [header] is shown above the items (the
/// series header on a series level).
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

    // The page's bars float over the top and bottom of the list; the
    // padding clears them.
    final EdgeInsets inset = MediaQuery.paddingOf(context);
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      edgeOffset: inset.top,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: <Widget>[
          SliverToBoxAdapter(child: SizedBox(height: inset.top)),
          if (widget.header != null) ...<Widget>[
            SliverToBoxAdapter(child: widget.header),
            const SliverToBoxAdapter(child: Divider(height: 1)),
          ],
          if (!_query.filters.isEmpty)
            SliverToBoxAdapter(child: _activeFilters()),
          body,
          SliverToBoxAdapter(child: _footer(context)),
          SliverToBoxAdapter(child: SizedBox(height: inset.bottom)),
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
