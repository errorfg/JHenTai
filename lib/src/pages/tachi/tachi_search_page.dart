import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/tachi/tachi_models.dart';
import 'package:jhentai/src/pages/details/details_page_logic.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/notification/tap_menu_button_notification.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/tachi/tachi_extension_service.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/widget/eh_image.dart';

import 'tachi_source_page.dart';

/// Searches the Tachiyomi sources: all of them at once (one request to
/// each, only when a search is submitted), or one, whose results open as
/// that source's list with its filters.
class TachiSearchPage extends StatefulWidget {
  const TachiSearchPage({super.key, this.showMenuButton = false, this.showTitle = true, this.name});

  final bool showMenuButton;
  final bool showTitle;
  final String? name;

  @override
  State<TachiSearchPage> createState() => _TachiSearchPageState();
}

class _SourceResult {
  _SourceResult(this.source);

  final TachiSourceInfo source;
  List<Gallery>? gallerys;
  String? error;
}

class _TachiSearchPageState extends State<TachiSearchPage> {
  static const int _parallel = 4;

  final TextEditingController _controller = TextEditingController();

  /// Null: all sources.
  String? _scope;
  List<_SourceResult> _results = <_SourceResult>[];
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (tachiExtensionService.installed.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => tachiExtensionService.refreshInstalled());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final String query = _controller.text.trim();
    if (query.isEmpty) {
      return;
    }
    if (_scope != null) {
      toRoute(Routes.tachiSource, arguments: TachiSourcePageArgument(sourceId: _scope!, query: query), preventDuplicates: false);
      return;
    }
    final int generation = ++_generation;
    final List<_SourceResult> results = tachiExtensionService.sources.map(_SourceResult.new).toList();
    setState(() => _results = results);
    int next = 0;
    Future<void> worker() async {
      while (next < results.length && generation == _generation) {
        final _SourceResult r = results[next++];
        try {
          final GalleryPageInfo page = await ehRequest.tachiSource.list(source: r.source.id, query: query);
          r.gallerys = page.gallerys;
        } catch (e) {
          r.error = e.toString();
        }
        if (mounted && generation == _generation) {
          setState(() {});
        }
      }
    }

    await Future.wait(<Future<void>>[for (int i = 0; i < _parallel; i++) worker()]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.showMenuButton ? IconButton(icon: const Icon(Icons.menu, size: 20), onPressed: () => TapMenuButtonNotification().dispatch(context)) : null,
        title: widget.showTitle ? Text(widget.name ?? 'search'.tr) : null,
        centerTitle: true,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: _scope == null ? 'tachiSearchAllSources'.tr : tachiExtensionService.source(_scope!)?.name,
                isDense: true,
                suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _search),
              ),
              onSubmitted: (_) => _search(),
            ),
          ),
          Obx(() => SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(label: Text('tachiAllSources'.tr), selected: _scope == null, onSelected: (_) => setState(() => _scope = null)),
                    ),
                    for (final TachiSourceInfo s in tachiExtensionService.sources)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(label: Text(s.name), selected: _scope == s.id, onSelected: (_) => setState(() => _scope = s.id)),
                      ),
                  ],
                ),
              )),
          Expanded(
            child: ListView(
              children: [for (final _SourceResult r in _results) _buildSource(context, r)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSource(BuildContext context, _SourceResult r) {
    final List<Gallery>? gallerys = r.gallerys;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          title: Text(r.source.name, style: Theme.of(context).textTheme.titleSmall),
          subtitle: r.error != null ? Text(r.error!, maxLines: 1, overflow: TextOverflow.ellipsis) : (gallerys == null ? const LinearProgressIndicator() : null),
          trailing: gallerys != null && gallerys.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: () => toRoute(Routes.tachiSource, arguments: TachiSourcePageArgument(sourceId: r.source.id, query: _controller.text.trim()), preventDuplicates: false),
                )
              : (gallerys != null ? Text('noData'.tr) : null),
        ),
        if (gallerys != null && gallerys.isNotEmpty)
          SizedBox(
            height: 190,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: gallerys.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (BuildContext context, int i) {
                final Gallery g = gallerys[i];
                return GestureDetector(
                  onTap: () => toRoute(Routes.details, arguments: DetailsPageArgument(galleryUrl: g.galleryUrl, gallery: g)),
                  child: SizedBox(
                    width: 110,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: EHImage(galleryImage: g.cover, fit: BoxFit.cover, containerWidth: 110, borderRadius: BorderRadius.circular(6))),
                        const SizedBox(height: 4),
                        Text(g.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
