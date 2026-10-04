import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/komga/komga_query.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/pages/komga/komga_browse_controller.dart';
import 'package:jhentai/src/pages/komga/komga_item_widgets.dart';

/// Header above the books of a series: metadata that has values, reading
/// counts, "continue reading" and series actions. Metadata chips open the
/// matching filter.
class KomgaSeriesHeader extends StatefulWidget {
  const KomgaSeriesHeader({
    super.key,
    required this.level,
    required this.views,
    required this.onContinue,
    required this.onFilter,
    required this.onSeriesAction,
  });

  final KomgaSeriesLevel level;
  final KomgaItemViews views;
  final void Function(KomgaBook book) onContinue;
  final void Function(String title, KomgaFilters filters) onFilter;
  final void Function(KomgaSeriesAction action) onSeriesAction;

  @override
  State<KomgaSeriesHeader> createState() => _KomgaSeriesHeaderState();
}

enum KomgaSeriesAction { markRead, markUnread, download }

class _KomgaSeriesHeaderState extends State<KomgaSeriesHeader> {
  bool _summaryExpanded = false;

  @override
  Widget build(BuildContext context) {
    final KomgaSeries series = widget.level.series;
    final KomgaClient client = widget.views.client;
    final ThemeData theme = Theme.of(context);
    final List<String> authors = series.authors
        .map((KomgaAuthor a) => a.name)
        .where((String name) => name.isNotEmpty)
        .toSet()
        .toList();

    final List<Widget> chips = <Widget>[
      for (final String author in authors)
        _chip(Icons.person_outline, author, KomgaFilters(authors: {author})),
      if (series.publisher.isNotEmpty)
        _chip(Icons.business_outlined, series.publisher,
            KomgaFilters(publishers: {series.publisher})),
      if (series.language.isNotEmpty)
        _chip(Icons.translate, series.language,
            KomgaFilters(languages: {series.language})),
      for (final String genre in series.genres)
        _chip(Icons.category_outlined, genre, KomgaFilters(genres: {genre})),
      for (final String tag in series.tags)
        _chip(Icons.sell_outlined, tag, KomgaFilters(tags: {tag})),
    ];
    final List<String> facts = <String>[
      if (series.status.isNotEmpty && series.status != 'ONGOING')
        _statusLabel(series.status),
      if (series.readingDirection.isNotEmpty)
        _directionLabel(series.readingDirection),
      if (series.releaseDate != null) series.releaseDate!.year.toString(),
      if (series.ageRating != null) '${series.ageRating}+',
    ];

    final KomgaBook? target = widget.level.continueTarget;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 112,
                  height: 168,
                  child: widget.views.image(client.seriesThumbnailUrl(series.id)),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      series.title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'komgaSeriesCounts'.trParams(<String, String>{
                        'total': series.booksCount.toString(),
                        'read': series.booksReadCount.toString(),
                        'ongoing': series.booksInProgressCount.toString(),
                        'unread': series.booksUnreadCount.toString(),
                      }),
                    ),
                    if (facts.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(facts.join(' · '), style: theme.textTheme.bodySmall),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        FilledButton.icon(
                          key: const ValueKey<String>('komgaContinueSeries'),
                          onPressed: target == null
                              ? null
                              : () => widget.onContinue(target),
                          icon: const Icon(Icons.play_arrow),
                          label: Text(
                            target == null
                                ? 'komgaContinueReading'.tr
                                : widget.level.continueRestarts
                                ? 'komgaReadFromStart'.tr
                                : 'komgaContinueBook'.trParams(
                                    <String, String>{'title': target.title},
                                  ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        PopupMenuButton<KomgaSeriesAction>(
                          key: const ValueKey<String>('komgaSeriesMenu'),
                          onSelected: widget.onSeriesAction,
                          itemBuilder: (_) => <PopupMenuEntry<KomgaSeriesAction>>[
                            PopupMenuItem<KomgaSeriesAction>(
                              value: KomgaSeriesAction.markRead,
                              child: Text('komgaMarkSeriesRead'.tr),
                            ),
                            PopupMenuItem<KomgaSeriesAction>(
                              value: KomgaSeriesAction.markUnread,
                              child: Text('komgaMarkSeriesUnread'.tr),
                            ),
                            PopupMenuItem<KomgaSeriesAction>(
                              value: KomgaSeriesAction.download,
                              child: Text('komgaDownloadSeries'.tr),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (chips.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: chips),
          ],
          if (series.summary.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            InkWell(
              onTap: () => setState(() => _summaryExpanded = !_summaryExpanded),
              child: Text(
                series.summary,
                maxLines: _summaryExpanded ? null : 3,
                overflow: _summaryExpanded ? null : TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label, KomgaFilters filters) {
    return ActionChip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      onPressed: () => widget.onFilter(label, filters),
    );
  }

  static String _statusLabel(String status) => switch (status) {
    'ENDED' => 'komgaStatusEnded'.tr,
    'ABANDONED' => 'komgaStatusAbandoned'.tr,
    'HIATUS' => 'komgaStatusHiatus'.tr,
    _ => status,
  };

  static String _directionLabel(String direction) => switch (direction) {
    'LEFT_TO_RIGHT' => 'komgaDirectionLeftToRight'.tr,
    'RIGHT_TO_LEFT' => 'komgaDirectionRightToLeft'.tr,
    'VERTICAL' => 'komgaDirectionVertical'.tr,
    'WEBTOON' => 'komgaDirectionWebtoon'.tr,
    _ => direction,
  };
}
