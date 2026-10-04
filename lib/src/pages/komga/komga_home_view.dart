import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/komga/komga_browse_models.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/pages/komga/komga_browse_controller.dart';
import 'package:jhentai/src/pages/komga/komga_item_widgets.dart';
import 'package:jhentai/src/service/komga_download_service.dart';

/// Home: reading shelves, libraries and downloads. Downloads stay reachable
/// when the server is not.
class KomgaHomeView extends StatefulWidget {
  const KomgaHomeView({
    super.key,
    required this.controller,
    required this.actions,
    required this.onRefresh,
  });

  final KomgaBrowseController controller;
  final KomgaItemActions actions;
  final Future<void> Function() onRefresh;

  @override
  State<KomgaHomeView> createState() => _KomgaHomeViewState();
}

class _KomgaHomeViewState extends State<KomgaHomeView> {
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: widget.controller.home.scrollOffset,
  )..addListener(() => widget.controller.home.scrollOffset = _scroll.offset);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final KomgaBrowseController controller = widget.controller;
    final KomgaHomeLevel home = controller.home;
    final KomgaItemViews views = KomgaItemViews(
      context,
      controller.client,
      widget.actions,
    );

    if (home.loading && !home.loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    final List<Widget> children = <Widget>[
      if (home.error != null) _error(context, home.error!),
      _bookShelf('komgaContinueReading'.tr, home.continueReading, views),
      _bookShelf('komgaOnDeck'.tr, home.onDeck, views),
      _seriesShelf('komgaRecentlyAddedSeries'.tr, home.newSeries, views),
      _seriesShelf('komgaRecentlyUpdatedSeries'.tr, home.updatedSeries, views),
      if (home.libraries.isNotEmpty) _heading(context, 'komgaLibraries'.tr),
      for (final KomgaLibrary library in home.libraries)
        ListTile(
          leading: const CircleAvatar(child: Icon(Icons.video_library_outlined)),
          title: Text(library.name),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => controller.openLibrary(library),
        ),
      ListenableBuilder(
        listenable: komgaDownloadService,
        builder: (BuildContext context, _) => ListTile(
          key: const ValueKey<String>('komgaDownloadsEntry'),
          leading: const CircleAvatar(child: Icon(Icons.download_done)),
          title: Text('komgaDownloads'.tr),
          trailing: Text(
            komgaDownloadService
                .downloadedBooks(controller.client.connectionId)
                .length
                .toString(),
          ),
          onTap: controller.openDownloads,
        ),
      ),
      const SizedBox(height: 24),
    ];

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        children: children,
      ),
    );
  }

  Widget _error(BuildContext context, Object error) {
    return Card(
      margin: const EdgeInsets.all(12),
      child: ListTile(
        leading: const Icon(Icons.cloud_off_outlined),
        title: Text(KomgaClient.friendlyError(error)),
        trailing: TextButton(
          onPressed: widget.onRefresh,
          child: Text('retry'.tr),
        ),
      ),
    );
  }

  Widget _heading(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _shelf(String title, int count, IndexedWidgetBuilder builder) {
    if (count == 0) {
      return const SizedBox();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _heading(context, title),
        SizedBox(
          height: 300,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: count,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: builder,
          ),
        ),
      ],
    );
  }

  Widget _bookShelf(String title, List<KomgaBook> books, KomgaItemViews views) {
    return _shelf(
      title,
      books.length,
      (_, int index) =>
          views.bookShelfCard(widget.controller.bookItem(books[index])),
    );
  }

  Widget _seriesShelf(
    String title,
    List<KomgaSeries> series,
    KomgaItemViews views,
  ) {
    return _shelf(
      title,
      series.length,
      (_, int index) => views.seriesShelfCard(
        KomgaSeriesBrowseItem.fromSeries(series: series[index]),
      ),
    );
  }
}

/// Books stored on this device, readable without the server.
class KomgaDownloadsView extends StatelessWidget {
  const KomgaDownloadsView({
    super.key,
    required this.controller,
    required this.actions,
  });

  final KomgaBrowseController controller;
  final KomgaItemActions actions;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: komgaDownloadService,
      builder: (BuildContext context, _) {
        final List<KomgaDownloadedBook> books = komgaDownloadService
            .downloadedBooks(controller.client.connectionId);
        if (books.isEmpty) {
          return Center(child: Text('komgaNoDownloads'.tr));
        }
        final KomgaItemViews views = KomgaItemViews(
          context,
          controller.client,
          actions,
        );
        return ListView.builder(
          itemCount: books.length,
          itemBuilder: (_, int index) => views.book(
            controller.bookItem(books[index].book),
            KomgaDisplayMode.list,
          ),
        );
      },
    );
  }
}
