import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/network/tachi/tachi_source.dart';
import 'package:jhentai/src/pages/details/details_page_logic.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/notification/tap_menu_button_notification.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/series_reading_service.dart';
import 'package:jhentai/src/service/tachi/tachi_update_service.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/widget/eh_image.dart';
import 'package:jhentai/src/widget/series_chapter_dialog.dart';

/// New chapters of the Tachiyomi manga in the favorites, found by a
/// manual refresh.
class TachiUpdatesPage extends StatelessWidget {
  const TachiUpdatesPage({super.key, this.showMenuButton = false, this.showTitle = true, this.name});

  final bool showMenuButton;
  final bool showTitle;
  final String? name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: showMenuButton ? IconButton(icon: const Icon(Icons.menu, size: 20), onPressed: () => TapMenuButtonNotification().dispatch(context)) : null,
        title: showTitle ? Text(name ?? 'tachiUpdates'.tr) : null,
        centerTitle: true,
        actions: [IconButton(icon: const Icon(Icons.refresh), tooltip: 'refresh'.tr, onPressed: tachiUpdateService.refresh)],
      ),
      body: RefreshIndicator(
        onRefresh: tachiUpdateService.refresh,
        child: Obx(() {
          final List<TachiUpdate> updates = tachiUpdateService.updates;
          final List<Widget> children = <Widget>[
            if (tachiUpdateService.checking.isTrue)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    LinearProgressIndicator(value: tachiUpdateService.total.value == 0 ? null : tachiUpdateService.checked.value / tachiUpdateService.total.value),
                    const SizedBox(height: 4),
                    Text('${tachiUpdateService.checked.value}/${tachiUpdateService.total.value}'),
                  ],
                ),
              )
            else if (tachiUpdateService.failed.value > 0)
              ListTile(leading: const Icon(Icons.error_outline), title: Text('tachiUpdatesFailed'.trParams(<String, String>{'count': '${tachiUpdateService.failed.value}'}))),
            if (updates.isEmpty && tachiUpdateService.checking.isFalse)
              Padding(padding: const EdgeInsets.all(32), child: Text('tachiUpdatesHint'.tr, textAlign: TextAlign.center)),
          ];
          String? day;
          for (final TachiUpdate u in updates) {
            final DateTime when = DateTime.fromMillisecondsSinceEpoch(u.chapterDate > 0 ? u.chapterDate : u.foundAt);
            final String d = DateFormat('yyyy-MM-dd').format(when);
            if (d != day) {
              day = d;
              children.add(Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(d, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
              ));
            }
            children.add(_UpdateTile(update: u));
          }
          return ListView(physics: const AlwaysScrollableScrollPhysics(), children: children);
        }),
      ),
    );
  }
}

class _UpdateTile extends StatelessWidget {
  const _UpdateTile({required this.update});

  final TachiUpdate update;

  @override
  Widget build(BuildContext context) {
    final int chapterId = TachiSource.idOf(update.chapterUrl);
    return SeriesChapterProgressBuilder(
      reading: tachiReadingService,
      chapterIds: <int>[chapterId],
      builder: (BuildContext context, Map<int, SeriesChapterProgress> progress) {
        final bool finished = progress[chapterId]?.finished ?? false;
        final Color? faded = finished ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4) : null;
        return ListTile(
          leading: SizedBox(
            width: 40,
            height: 56,
            child: update.cover.isEmpty ? const Icon(Icons.image_outlined) : EHImage(galleryImage: GalleryImage(url: update.cover), fit: BoxFit.cover, borderRadius: BorderRadius.circular(4)),
          ),
          title: Text(update.mangaTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: faded)),
          subtitle: Text(update.chapterName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: faded)),
          trailing: finished ? Icon(Icons.check, size: 18, color: faded) : null,
          onTap: () => toRoute(
            Routes.details,
            arguments: DetailsPageArgument(galleryUrl: update.chapterUrl, jmExactChapter: true),
            preventDuplicates: false,
          ),
        );
      },
    );
  }
}
