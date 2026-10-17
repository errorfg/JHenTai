import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_history_model.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/jm_favorite_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/record_sync/record_backend.dart';
import 'package:jhentai/src/service/record_sync/record_sync_engine.dart';

/// The app against the real Worker and D1 (sync_server/), run by
/// `wrangler dev` on this machine. Skipped when sync_server/ has no
/// node_modules (run `npm install` there).

const String _token = 'e2e-token';

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

class _InlineIsolateService extends IsolateService {
  @override
  Future<String> jsonEncodeAsync(Object object) async => jsonEncode(object);

  @override
  Future<dynamic> jsonDecodeAsync(String string) async => jsonDecode(string);
}

class _Device {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  final LocalConfigService config = LocalConfigService();
  final HistoryService history = HistoryService();
  final PendingSyncTracker tracker = PendingSyncTracker();
  final ReadProgressService progress = ReadProgressService();
  final JmFavoriteService jm = JmFavoriteService();

  void activate() {
    appDb = db;
    localConfigService = config;
    historyService = history;
    pendingSyncTracker = tracker;
    readProgressService = progress;
    jmFavoriteService = jm;
  }

  Future<RecordSyncResult> sync(RecordBackend server) {
    activate();
    return RecordSyncEngine().sync(server);
  }

  Future<Set<int>> historyGids() async {
    activate();
    return (await history.getAllRawHistory()).map((h) => h.gid).toSet();
  }

  Set<int> favoriteIds() {
    activate();
    return jm.getDisplayFavorites().map((g) => g.gid - GalleryUrl.jmGidOffset).toSet();
  }
}

GalleryHistoryModel _entry(int gid) => GalleryHistoryModel(
      galleryUrl: GalleryUrl(isEH: true, gid: gid, token: 't${gid.toString().padLeft(9, '0')}'),
      title: 'Gallery $gid',
      category: 'Manga',
      coverUrl: 'https://cdn.example.test/$gid.jpg',
      pageCount: 20,
      rating: 0,
      language: '',
      uploader: '',
      publishTime: '',
      isExpunged: false,
      tags: const <String>[],
    );

Gallery _jmGallery(int id) => Gallery(
      galleryUrl: GalleryUrl.jm(id),
      title: 'JM $id',
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

Future<int> _freePort() async {
  ServerSocket socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  int port = socket.port;
  await socket.close();
  return port;
}

void main() {
  final Directory serverDir = Directory('sync_server');
  final bool available = File('${serverDir.path}/node_modules/.bin/wrangler').existsSync();

  Process? wrangler;
  Directory? state;
  late String url;

  setUpAll(() async {
    if (!available) {
      return;
    }
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    log = _SilentLogService();
    isolateService = _InlineIsolateService();
    HttpOverrides.global = null;

    state = await Directory.systemTemp.createTemp('gallery-sync-e2e');
    int port = await _freePort();
    url = 'http://127.0.0.1:$port';
    wrangler = await Process.start(
      'node_modules/.bin/wrangler',
      [
        'dev',
        '--config', 'wrangler.test.toml',
        '--ip', '127.0.0.1',
        '--port', '$port',
        '--var', 'SYNC_TOKEN:$_token',
        '--persist-to', state!.path,
        '--show-interactive-dev-session=false',
        '--log-level', 'warn',
      ],
      workingDirectory: serverDir.path,
      environment: {'WRANGLER_SEND_METRICS': 'false'},
    );
    unawaited(wrangler!.stderr.drain<void>());
    unawaited(wrangler!.stdout.drain<void>());

    // Ready once it answers.
    DateTime deadline = DateTime.now().add(const Duration(seconds: 60));
    HttpClient client = HttpClient();
    while (true) {
      try {
        HttpClientResponse response = await (await client.getUrl(Uri.parse('$url/v1/info'))).close();
        await response.drain<void>();
        break;
      } catch (_) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('wrangler dev did not start');
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    client.close();
  });

  tearDownAll(() async {
    wrangler?.kill();
    await wrangler?.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      wrangler?.kill(ProcessSignal.sigkill);
      return -1;
    });
    await state?.delete(recursive: true);
  });

  test('a wrong token is turned away', () async {
    final HttpRecordBackend backend = HttpRecordBackend(url: url, token: 'wrong');
    await expectLater(
      backend.info(),
      throwsA(isA<RecordServerException>().having((e) => e.status, 'status', 401)),
    );
  }, skip: available ? false : 'sync_server/node_modules is missing');

  test('two devices sync through the Worker: data both ways, a deletion, a large first push', () async {
    final HttpRecordBackend server = HttpRecordBackend(url: url, token: _token);
    final _Device phone = _Device();
    final _Device desktop = _Device();

    // A first push larger than one request.
    phone.activate();
    for (int gid = 1; gid <= 450; gid++) {
      await historyService.record(_entry(gid));
    }
    await jmFavoriteService.addFavorite(_jmGallery(101), favoriteCategoryIndex: 0);
    await jmFavoriteService.addFavorite(_jmGallery(102), favoriteCategoryIndex: 0);
    RecordSyncResult first = await phone.sync(server);
    expect(first.pushed, 452);

    desktop.activate();
    await historyService.record(_entry(1000));
    await desktop.sync(server);
    await phone.sync(server);
    expect(await desktop.historyGids(), {for (int gid = 1; gid <= 450; gid++) gid, 1000});
    expect(await phone.historyGids(), {for (int gid = 1; gid <= 450; gid++) gid, 1000});
    expect(desktop.favoriteIds(), {101, 102});

    phone.activate();
    await jmFavoriteService.removeFavorite(_jmGallery(101).gid);
    await historyService.delete(7);
    await phone.sync(server);
    await desktop.sync(server);
    expect(desktop.favoriteIds(), {102});
    expect((await desktop.historyGids()).contains(7), isFalse);

    // Nothing left to move either way.
    RecordSyncResult quiet = await desktop.sync(server);
    expect(quiet.pulled + quiet.pushed, 0);
  }, skip: available ? false : 'sync_server/node_modules is missing', timeout: const Timeout(Duration(minutes: 3)));
}
