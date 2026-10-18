import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/tachi/tachi_client.dart';
import 'package:jhentai/src/network/tachi/tachi_host.dart';
import 'package:jhentai/src/network/tachi/tachi_models.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/tachi/tachi_extension_service.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:jhentai/src/utils/uuid_util.dart';

import '../base/base_page.dart';
import '../base/base_page_logic.dart';
import '../base/base_page_state.dart';
import 'tachi_filter_sheet.dart';
import 'tachi_webview_page.dart';

class TachiSourcePageArgument {
  const TachiSourcePageArgument({required this.sourceId, this.query, this.latest = false});

  final String sourceId;

  /// Opens on the latest list.
  final bool latest;

  /// Opens as a search for this.
  final String? query;
}

/// What a Tachiyomi source lists: popular, latest, or a search with the
/// source's own filters.
enum TachiSourceListing { popular, latest, search }

/// One Tachiyomi source: its popular and latest lists, and searching it.
class TachiSourcePage extends BasePage<TachiSourcePageLogic, TachiSourcePageState> {
  TachiSourcePage({super.key}) : super(showScroll2TopButton: true, showTitle: true) {
    final TachiSourcePageArgument argument = Get.arguments as TachiSourcePageArgument;
    logic = Get.put(TachiSourcePageLogic(argument, tag), tag: tag);
    state = logic.state;
  }

  final String tag = newUUID();

  @override
  late final TachiSourcePageLogic logic;

  @override
  late final TachiSourcePageState state;

  @override
  String get name => tachiExtensionService.source(state.sourceId)?.name ?? '';

  @override
  List<Widget> buildAppBarActions() {
    final TachiSourceInfo? info = tachiExtensionService.source(state.sourceId);
    return [
      IconButton(icon: const Icon(Icons.search), tooltip: 'search'.tr, onPressed: () => logic.askQuery(Get.context!)),
      IconButton(icon: const Icon(Icons.filter_alt_outlined), tooltip: 'filter'.tr, onPressed: () => logic.editFilters(Get.context!)),
      if (TachiWebViewPage.supported && info?.baseUrl != null)
        IconButton(
          icon: const Icon(Icons.public),
          tooltip: 'tachiOpenInWebView'.tr,
          onPressed: () => toRoute(Routes.tachiWebView, arguments: state.sourceId),
        ),
      if (info?.configurable ?? false)
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'tachiSourceSettings'.tr,
          onPressed: () => toRoute(Routes.tachiSourceSettings, arguments: state.sourceId),
        ),
    ];
  }

  @override
  Widget buildBody(BuildContext context) {
    return Column(
      children: [
        GetBuilder<TachiSourcePageLogic>(
          id: logic.appBarId,
          global: false,
          init: logic,
          builder: (_) {
            final bool latest = tachiExtensionService.source(state.sourceId)?.supportsLatest ?? false;
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: SegmentedButton<TachiSourceListing>(
                      showSelectedIcon: false,
                      segments: <ButtonSegment<TachiSourceListing>>[
                        ButtonSegment(value: TachiSourceListing.popular, label: Text('popular'.tr)),
                        if (latest) ButtonSegment(value: TachiSourceListing.latest, label: Text('tachiLatest'.tr)),
                        if (state.listing == TachiSourceListing.search)
                          ButtonSegment(
                            value: TachiSourceListing.search,
                            label: Text(state.query.isEmpty ? 'filter'.tr : state.query, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      selected: <TachiSourceListing>{state.listing},
                      onSelectionChanged: (Set<TachiSourceListing> s) => logic.show(s.single),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        Expanded(child: buildListBody(context)),
      ],
    );
  }
}

class TachiSourcePageLogic extends BasePageLogic {
  TachiSourcePageLogic(TachiSourcePageArgument argument, String tag) : state = TachiSourcePageState(argument.sourceId, tag) {
    if (argument.latest) {
      state.listing = TachiSourceListing.latest;
    }
    if (argument.query != null && argument.query!.isNotEmpty) {
      state
        ..listing = TachiSourceListing.search
        ..query = argument.query!;
    }
  }

  @override
  final TachiSourcePageState state;

  @override
  bool get useSearchConfig => false;

  @override
  Future<void> onInit() async {
    await super.onInit();
    await tachiExtensionService.markSourceUsed(state.sourceId);
  }

  @override
  Future<GalleryPageInfo> getGalleryPage({String? prevGid, String? nextGid, DateTime? seek}) {
    return ehRequest.tachiSource.list(
      source: state.sourceId,
      latest: state.listing == TachiSourceListing.latest,
      query: state.listing == TachiSourceListing.search ? state.query : null,
      filters: state.listing == TachiSourceListing.search ? state.filters : null,
      pageToken: nextGid ?? prevGid,
    );
  }

  void show(TachiSourceListing listing) {
    if (listing == state.listing) {
      return;
    }
    state.listing = listing;
    updateSafely([appBarId]);
    handleClearAndRefresh();
  }

  Future<void> askQuery(BuildContext context) async {
    final TextEditingController controller = TextEditingController(text: state.query);
    final String? query = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('search'.tr),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (String v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('cancel'.tr)),
          TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: Text('search'.tr)),
        ],
      ),
    );
    if (query == null) {
      return;
    }
    state
      ..query = query.trim()
      ..listing = TachiSourceListing.search;
    updateSafely([appBarId]);
    handleClearAndRefresh();
  }

  Future<List<TachiFilter>> _defaults() => tachiHost.run((TachiClient c) => c.filters(state.sourceId));

  Future<void> editFilters(BuildContext context) async {
    List<TachiFilter>? filters;
    try {
      filters = state.filters ?? await _defaults();
    } catch (e) {
      toast(e.toString());
      return;
    }
    if (!context.mounted) {
      return;
    }
    final List<TachiFilter>? edited = await TachiFilterSheet.show(context, filters: filters, onReset: _defaults);
    if (edited == null) {
      return;
    }
    state
      ..filters = edited
      ..listing = TachiSourceListing.search;
    updateSafely([appBarId]);
    handleClearAndRefresh();
  }
}

class TachiSourcePageState extends BasePageState {
  TachiSourcePageState(this.sourceId, String tag) {
    pageStorageKey = PageStorageKey<String>('tachiSource:$tag');
  }

  final String sourceId;
  TachiSourceListing listing = TachiSourceListing.popular;
  String query = '';

  /// The filters of a search, once the user set them.
  List<TachiFilter>? filters;

  @override
  String get route => Routes.tachiSource;
}
