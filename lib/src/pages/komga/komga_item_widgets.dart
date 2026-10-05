import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/komga/komga_browse_models.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/service/komga_download_service.dart';
import 'package:jhentai/src/widget/eh_image.dart';

/// What tapping or long-pressing an item does.
class KomgaItemActions {
  const KomgaItemActions({
    required this.openBook,
    required this.openSeries,
    required this.showBookMenu,
    required this.showSeriesMenu,
    this.openingBookId,
  });

  final void Function(KomgaBook book) openBook;
  final void Function(KomgaSeries series) openSeries;
  /// [position] places the menu at the pointer on desktop layouts.
  final void Function(BuildContext context, KomgaBook book, {Offset? position})
  showBookMenu;
  final void Function(
    BuildContext context,
    KomgaSeries series, {
    Offset? position,
  })
  showSeriesMenu;
  final String? openingBookId;
}

/// Card, list and detail renderings of Komga series and books.
class KomgaItemViews {
  const KomgaItemViews(this.context, this.client, this.actions);

  final BuildContext context;
  final KomgaClient client;
  final KomgaItemActions actions;

  static const SliverGridDelegate gridDelegate =
      SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        childAspectRatio: 0.53,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      );

  ThemeData get _theme => Theme.of(context);

  Widget series(KomgaSeriesBrowseItem item, KomgaDisplayMode mode) {
    return switch (mode) {
      KomgaDisplayMode.grid => _seriesCard(item),
      KomgaDisplayMode.list => _seriesTile(item),
      KomgaDisplayMode.detail => _seriesDetail(item),
    };
  }

  Widget book(KomgaBookBrowseItem item, KomgaDisplayMode mode) {
    return switch (mode) {
      KomgaDisplayMode.grid => _bookCard(item),
      KomgaDisplayMode.list => _bookTile(item),
      KomgaDisplayMode.detail => _bookDetail(item),
    };
  }

  /// Fixed-width card for horizontal home sections.
  Widget seriesShelfCard(KomgaSeriesBrowseItem item) =>
      SizedBox(width: 132, child: _seriesCard(item));

  Widget bookShelfCard(KomgaBookBrowseItem item) =>
      SizedBox(width: 132, child: _bookCard(item, showSeries: true));

  // ---- series ----

  Widget _seriesCard(KomgaSeriesBrowseItem item) {
    final String url = client.seriesThumbnailUrl(item.series.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => actions.openSeries(item.series),
        onLongPress: () => actions.showSeriesMenu(context, item.series),
        onSecondaryTapDown: (TapDownDetails details) =>
            actions.showSeriesMenu(context, item.series, position: details.globalPosition),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  image(url),
                  _coverBadges(item.readingStatus, isNew: item.isNew),
                ],
              ),
            ),
            _linearProgress(item.readingStatus == KomgaReadingStatus.unread
                ? null
                : item.progressFraction),
            _cardText(item.title, _seriesProgressText(item), bold: true),
          ],
        ),
      ),
    );
  }

  Widget _seriesTile(KomgaSeriesBrowseItem item) {
    final String url = client.seriesThumbnailUrl(item.series.id);
    // ListTile has no secondary-tap callback; right click opens the menu
    // at the pointer on desktop layouts.
    return GestureDetector(
      onSecondaryTapDown: (TapDownDetails details) =>
          actions.showSeriesMenu(context, item.series, position: details.globalPosition),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: _thumbnail(url, 54, 76),
        title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(_seriesProgressText(item)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (item.isNew) newBadge(),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () => actions.openSeries(item.series),
        onLongPress: () => actions.showSeriesMenu(context, item.series),
      ),
    );
  }

  Widget _seriesDetail(KomgaSeriesBrowseItem item) {
    final KomgaSeries series = item.series;
    final String url = client.seriesThumbnailUrl(series.id);
    final List<String> facts = <String>[
      if (series.authors.isNotEmpty)
        series.authors.map((KomgaAuthor a) => a.name).toSet().join(', '),
      if (series.publisher.isNotEmpty) series.publisher,
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => actions.openSeries(series),
        onLongPress: () => actions.showSeriesMenu(context, series),
        onSecondaryTapDown: (TapDownDetails details) =>
            actions.showSeriesMenu(context, series, position: details.globalPosition),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _thumbnail(url, 96, 144),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            item.title,
                            style: _theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (item.isNew) newBadge(),
                      ],
                    ),
                    const SizedBox(height: 8),
                    statusBadge(item.readingStatus),
                    const SizedBox(height: 8),
                    Text(_seriesProgressText(item)),
                    for (final String fact in facts) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        fact,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: _theme.textTheme.bodySmall,
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
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- books ----

  Widget _bookCard(KomgaBookBrowseItem item, {bool showSeries = false}) {
    final KomgaBook book = item.book;
    final String url = client.bookThumbnailUrl(book.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => actions.openBook(book),
        onLongPress: () => actions.showBookMenu(context, book),
        onSecondaryTapDown: (TapDownDetails details) =>
            actions.showBookMenu(context, book, position: details.globalPosition),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  image(url),
                  _coverBadges(item.readingStatus, isNew: item.isNew),
                  _downloadOverlay(book),
                  if (actions.openingBookId == book.id)
                    const ColoredBox(
                      color: Colors.black45,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
            ),
            _linearProgress(item.progress == null ? null : item.progressFraction),
            _cardText(
              showSeries && book.seriesTitle.isNotEmpty
                  ? '${book.seriesTitle} · ${book.title}'
                  : book.title,
              bookStatusText(item),
              bold: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _bookTile(KomgaBookBrowseItem item) {
    final KomgaBook book = item.book;
    final String url = client.bookThumbnailUrl(book.id);
    // ListTile has no secondary-tap callback; right click opens the menu
    // at the pointer on desktop layouts.
    return GestureDetector(
      onSecondaryTapDown: (TapDownDetails details) =>
          actions.showBookMenu(context, book, position: details.globalPosition),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: _thumbnail(url, 54, 76),
        title: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          <String>[
            if (book.seriesTitle.isNotEmpty) book.seriesTitle,
            bookStatusText(item),
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: actions.openingBookId == book.id
            ? const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (item.isNew) newBadge(),
                  _downloadIcon(book),
                  _statusIcon(item.readingStatus),
                ],
              ),
        onTap: () => actions.openBook(book),
        onLongPress: () => actions.showBookMenu(context, book),
      ),
    );
  }

  Widget _bookDetail(KomgaBookBrowseItem item) {
    final KomgaBook book = item.book;
    final String url = client.bookThumbnailUrl(book.id);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => actions.openBook(book),
        onLongPress: () => actions.showBookMenu(context, book),
        onSecondaryTapDown: (TapDownDetails details) =>
            actions.showBookMenu(context, book, position: details.globalPosition),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Stack(
                children: <Widget>[
                  _thumbnail(url, 96, 144),
                  Positioned.fill(child: _downloadOverlay(book)),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            book.title,
                            style: _theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (item.isNew) newBadge(),
                      ],
                    ),
                    if (book.seriesTitle.isNotEmpty)
                      Text(book.seriesTitle, style: _theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    statusBadge(item.readingStatus),
                    const SizedBox(height: 8),
                    Text(bookStatusText(item)),
                    const SizedBox(height: 6),
                    Text(
                      'komgaAddedAt'.trParams(<String, String>{
                        'date': book.createdDate == null
                            ? '—'
                            : DateFormat('yyyy-MM-dd').format(
                                book.createdDate!.toLocal(),
                              ),
                      }),
                      style: _theme.textTheme.bodySmall,
                    ),
                    Text(
                      <String>[
                        '${book.pageCount}P',
                        if (book.size.isNotEmpty) book.size,
                      ].join(' · '),
                      style: _theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- pieces ----

  Widget image(String url) {
    return EHImage(
      galleryImage: GalleryImage(
        url: url,
        headers: client.imageHeaders,
        cacheKey: client.imageCacheKey(url),
      ),
      fit: BoxFit.cover,
    );
  }

  Widget _thumbnail(String url, double width, double height) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(width: width, height: height, child: image(url)),
    );
  }

  Widget _cardText(String title, String subtitle, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: bold ? FontWeight.w600 : null),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _linearProgress(double? value) {
    if (value == null) {
      return const SizedBox(height: 3);
    }
    return LinearProgressIndicator(
      value: value,
      minHeight: 3,
      backgroundColor: _theme.colorScheme.surfaceContainerHighest,
    );
  }

  Widget _coverBadges(KomgaReadingStatus status, {required bool isNew}) {
    return PositionedDirectional(
      top: 8,
      start: 8,
      end: 8,
      child: Row(
        children: <Widget>[
          statusBadge(status),
          const Spacer(),
          if (isNew) newBadge(),
        ],
      ),
    );
  }

  Widget _downloadOverlay(KomgaBook book) {
    final String key = client.progressRecordKey(book.id);
    return ListenableBuilder(
      listenable: komgaDownloadService,
      builder: (BuildContext context, _) {
        final KomgaDownloadTask? task = komgaDownloadService.task(key);
        if (komgaDownloadService.downloaded(key) != null) {
          return const PositionedDirectional(
            bottom: 6,
            end: 6,
            child: CircleAvatar(
              radius: 12,
              child: Icon(Icons.download_done, size: 16),
            ),
          );
        }
        if (task == null) {
          return const SizedBox();
        }
        return PositionedDirectional(
          bottom: 6,
          end: 6,
          child: CircleAvatar(
            radius: 14,
            child: task.state == KomgaDownloadState.failed
                ? const Icon(Icons.error_outline, size: 18)
                : SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      value: task.progress,
                      strokeWidth: 2.5,
                    ),
                  ),
          ),
        );
      },
    );
  }

  Widget _downloadIcon(KomgaBook book) {
    final String key = client.progressRecordKey(book.id);
    return ListenableBuilder(
      listenable: komgaDownloadService,
      builder: (BuildContext context, _) {
        if (komgaDownloadService.downloaded(key) != null) {
          return const Padding(
            padding: EdgeInsets.only(right: 6),
            child: Icon(Icons.download_done, size: 20),
          );
        }
        final KomgaDownloadTask? task = komgaDownloadService.task(key);
        if (task == null) {
          return const SizedBox();
        }
        return Padding(
          padding: const EdgeInsets.only(right: 6),
          child: task.state == KomgaDownloadState.failed
              ? const Icon(Icons.error_outline, size: 20)
              : SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    value: task.progress,
                    strokeWidth: 2,
                  ),
                ),
        );
      },
    );
  }

  Widget statusBadge(KomgaReadingStatus status) {
    final ColorScheme colors = _theme.colorScheme;
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
    return _badge(readingStatusLabel(status), background, foreground);
  }

  Widget newBadge() {
    final ColorScheme colors = _theme.colorScheme;
    return _badge(
      'komgaNewlyAdded'.tr,
      colors.secondaryContainer.withValues(alpha: 0.95),
      colors.onSecondaryContainer,
    );
  }

  Widget _badge(String text, Color background, Color foreground) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w600,
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

  static String readingStatusLabel(KomgaReadingStatus value) {
    return switch (value) {
      KomgaReadingStatus.unread => 'komgaUnread'.tr,
      KomgaReadingStatus.inProgress => 'komgaInProgress'.tr,
      KomgaReadingStatus.read => 'komgaRead'.tr,
    };
  }

  static String bookStatusText(KomgaBookBrowseItem item) {
    if (item.book.isTextEpub) {
      return 'komgaBookTextEpub'.tr;
    }
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

  static String _seriesProgressText(KomgaSeriesBrowseItem item) {
    return 'komgaSeriesProgress'.trParams(<String, String>{
      'completed': item.readCount.toString(),
      'ongoing': item.inProgressCount.toString(),
      'remaining': item.unreadCount.toString(),
    });
  }
}
