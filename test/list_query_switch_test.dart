import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/pages/jm/jm_list_page.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

class _SilentLogService extends LogService {
  @override
  void trace(Object msg, [bool withStack = false]) {}
  @override
  void debug(Object msg, [bool withStack = false]) {}
  @override
  void info(Object msg, [bool withStack = false]) {}
  @override
  void warning(Object msg, [Object? error, bool withStack = false]) {}
  @override
  void error(Object msg, [Object? error, StackTrace? stackTrace]) {}
}

/// A JM list whose requests answer when the test says.
class _ListLogic extends JmQueryPageLogic {
  @override
  final JmListPageState state = JmListPageState('test')..query = const JmFilterQuery(order: 'mr');

  /// The requests made, with the order each was for.
  final List<({String order, Completer<GalleryPageInfo> answer})> requests = [];

  @override
  Future<JmListQuery> defaultQuery() async => state.query!;

  @override
  Future<GalleryPageInfo> getGalleryPage({String? prevGid, String? nextGid, DateTime? seek}) {
    final Completer<GalleryPageInfo> answer = Completer<GalleryPageInfo>();
    requests.add((order: (state.query as JmFilterQuery).order, answer: answer));
    return answer.future;
  }

  @override
  Future<List<Gallery>> postHandleNewGallerys(List<Gallery> gallerys, {bool cleanDuplicate = true}) async => gallerys;
}

Gallery _album(int id) => Gallery(
      galleryUrl: GalleryUrl.jm(id),
      title: 'Album $id',
      category: 'Manga',
      cover: GalleryImage(url: 'https://example.test/cover.jpg'),
      pageCount: 10,
      rating: 0,
      hasRated: false,
      language: null,
      uploader: null,
      publishTime: '2026-10-01 10:00',
      isExpunged: false,
      tags: LinkedHashMap<String, List<GalleryTag>>(),
    );

void main() {
  setUp(() {
    log = _SilentLogService();
    Get.testMode = true;
  });

  test('another order chosen while a page loads is asked for, and the page of the order before is dropped', () async {
    final _ListLogic logic = _ListLogic();
    final Future<void> first = logic.loadMore();
    logic.showQuery(const JmFilterQuery(order: 'mv'));
    expect(logic.requests.map((r) => r.order), <String>['mr', 'mv']);

    logic.requests[1].answer.complete(GalleryPageInfo(gallerys: <Gallery>[_album(2)], nextGid: 'mv-2'));
    await Future<void>.delayed(Duration.zero);
    logic.requests[0].answer.complete(GalleryPageInfo(gallerys: <Gallery>[_album(1)], nextGid: 'mr-2'));
    await first;

    expect(logic.state.gallerys.map((Gallery g) => g.title), <String>['Album 2']);
    expect(logic.state.nextGid, 'mv-2');
    expect(logic.state.loadingState, LoadingState.idle);

    // The next page is of the order shown.
    unawaited(logic.loadMore());
    expect(logic.requests.last.order, 'mv');
  });

  test('a page of the order before that fails after another order is chosen changes nothing', () async {
    final _ListLogic logic = _ListLogic();
    final Future<void> first = logic.loadMore();
    logic.showQuery(const JmFilterQuery(order: 'mv'));

    logic.requests[0].answer.completeError(StateError('connection reset'));
    await first;
    expect(logic.state.loadingState, LoadingState.loading, reason: 'the page of the order shown is still on its way');

    logic.requests[1].answer.complete(GalleryPageInfo(gallerys: <Gallery>[_album(2)]));
    await Future<void>.delayed(Duration.zero);
    expect(logic.state.gallerys.map((Gallery g) => g.title), <String>['Album 2']);
    expect(logic.state.loadingState, LoadingState.noMore);
  });
}
