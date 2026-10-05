import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/uuid_util.dart';

import '../base/base_page.dart';
import '../base/base_page_logic.dart';
import '../base/base_page_state.dart';

/// A JM album list, paged by [JmSource.list]. Subclasses choose the query,
/// e.g. from controls above the list.
abstract class JmQueryPageLogic extends BasePageLogic {
  @override
  JmQueryPageState get state;

  @override
  bool get useSearchConfig => false;

  /// The query to show when none is chosen yet; may need a request, e.g.
  /// for the newest weekly pick.
  Future<JmListQuery> defaultQuery();

  @override
  Future<GalleryPageInfo> getGalleryPage({String? prevGid, String? nextGid, DateTime? seek}) async {
    final JmListQuery query = state.query ??= await defaultQuery();
    log.info('$runtimeType get data, prevGid:$prevGid, nextGid:$nextGid');
    return ehRequest.jmSource.list(query, pageToken: nextGid ?? prevGid);
  }

  /// Shows [query] from its first page.
  void showQuery(JmListQuery query) {
    state.query = query;
    updateSafely([appBarId]);
    handleClearAndRefresh();
  }
}

abstract class JmQueryPageState extends BasePageState {
  JmQueryPageState({required String storageKey}) {
    pageStorageKey = PageStorageKey<String>(storageKey);
  }

  JmListQuery? query;
}

/// Arguments of [JmListPage].
class JmListPageArgument {
  const JmListPageArgument({required this.title, required this.query});

  final String title;
  final JmListQuery query;
}

/// The full list behind a JM home section.
class JmListPage extends BasePage<JmListPageLogic, JmListPageState> {
  JmListPage({super.key}) : super(showScroll2TopButton: true, showTitle: true) {
    final JmListPageArgument argument = Get.arguments as JmListPageArgument;
    logic = Get.put(JmListPageLogic(argument.query, tag), tag: tag);
    state = logic.state;
    _title = argument.title;
  }

  final String tag = newUUID();
  late final String _title;

  @override
  late final JmListPageLogic logic;

  @override
  late final JmListPageState state;

  @override
  String get name => _title;
}

class JmListPageLogic extends JmQueryPageLogic {
  JmListPageLogic(JmListQuery query, String tag) : state = JmListPageState(tag)..query = query;

  @override
  final JmListPageState state;

  @override
  Future<JmListQuery> defaultQuery() async => state.query!;
}

class JmListPageState extends JmQueryPageState {
  JmListPageState(String tag) : super(storageKey: 'jmList:$tag');

  @override
  String get route => Routes.jmList;
}
