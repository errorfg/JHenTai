import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/network/tachi/tachi_client.dart';
import 'package:jhentai/src/network/tachi/tachi_host.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/service/record_sync/record_adapters.dart';
import 'package:jhentai/src/service/record_sync/record_backend.dart';
import 'package:jhentai/src/service/record_sync/record_sync_engine.dart';
import 'package:jhentai/src/service/tachi/tachi_extension_service.dart';
import 'package:jhentai/src/service/tachi/tachi_source_setting_service.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

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

/// Runs JSON work inline; the app's isolate is not started in tests.
class _InlineIsolateService extends IsolateService {
  @override
  Future<String> jsonEncodeAsync(Object object) async => jsonEncode(object);

  @override
  Future<dynamic> jsonDecodeAsync(String string) async => jsonDecode(string);
}

/// The sync server in memory, with the rules of sync_server/src/index.ts.
class _MemoryServer implements RecordBackend {
  final Map<String, ({RemoteRecord record, int seq})> stored = {};
  int seq = 0;

  @override
  Future<RecordServerInfo> info() async => const RecordServerInfo(protocol: 1, database: 'db-1');

  @override
  Future<void> push(List<RemoteRecord> records) async {
    for (final RemoteRecord record in records) {
      final String id = '${record.kind}\u0000${record.key}';
      final RemoteRecord? current = stored[id]?.record;
      if (current == null || compareVersions(record.updatedAt, record.device, current.updatedAt, current.device) > 0) {
        stored[id] = (record: record, seq: ++seq);
      }
    }
  }

  @override
  Future<RecordPage> pull({required int since, required String device, required int limit}) async {
    final List<({RemoteRecord record, int seq})> page =
        (stored.values.where((s) => s.seq > since && s.record.device != device).toList()..sort((a, b) => a.seq.compareTo(b.seq))).take(limit).toList();
    final bool more = page.length == limit;
    return RecordPage(records: page.map((s) => s.record).toList(), next: more ? page.last.seq : (seq > since ? seq : since), more: more);
  }
}

const String _source = '1234567890123';
const String _pkg = 'eu.kanade.tachiyomi.extension.en.fake';

/// The extension host, and a repository with one extension, which the host
/// has once it was asked to install it.
class _FakeHost {
  late HttpServer _server;
  bool installed = false;
  int requests = 0;
  final List<String> installs = <String>[];
  final List<String> uninstalls = <String>[];

  /// Settings given to the host: source id and values, as JSON.
  final List<String> settings = <String>[];

  int get port => _server.port;

  String get repo => 'http://127.0.0.1:$port/repo/index.min.json';

  static const Map<String, Object?> _extensionJson = <String, Object?>{
    'pkg': _pkg,
    'name': 'Tachiyomi: Fake',
    'versionName': '1.4.1',
    'versionCode': 1,
    'libVersion': '1.4',
    'sources': <Object?>[
      <String, Object?>{'id': _source, 'name': 'Fake Source', 'lang': 'en', 'baseUrl': 'https://example.test'},
    ],
  };

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((HttpRequest request) async {
      requests++;
      Object? body = <String, Object?>{};
      switch (request.uri.path) {
        case '/repo/index.min.json':
          body = <Object?>[
            <String, Object?>{
              'name': 'Tachiyomi: Fake',
              'pkg': _pkg,
              'apk': 'fake.apk',
              'lang': 'en',
              'code': 1,
              'version': '1.4.1',
              'nsfw': 0,
              'sources': <Object?>[],
            },
          ];
        case '/repo/apk/fake.apk':
          request.response.add(<int>[0x50, 0x4b, 3, 4]);
          await request.response.close();
          return;
        case '/extensions':
          body = <String, Object?>{'extensions': installed ? <Object?>[_extensionJson] : <Object?>[]};
        case '/extensions/install':
          installed = true;
          installs.add(_pkg);
          body = _extensionJson;
        case '/extensions/uninstall':
          final Map<String, dynamic> json = jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
          installed = false;
          uninstalls.add(json['pkg'] as String);
        case '/source/preference-store/set':
          final Map<String, dynamic> json = jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
          settings.add('${json['source']} ${jsonEncode(json['values'])}');
        default:
          request.response.statusCode = HttpStatus.notFound;
          body = <String, Object?>{'error': 'not here'};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);

  /// Waits until nothing has been asked of the host for a while.
  Future<void> quiet() async {
    int seen = -1;
    while (seen != requests) {
      seen = requests;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }
}

/// The host of one launch of the app: not running until something needs it.
class _LaunchHost extends TachiHost {
  _LaunchHost(this._client);

  final TachiClient _client;
  TachiClient? _running;

  @override
  TachiClient? get clientIfRunning => _running;

  @override
  Future<TachiClient> client() async {
    if (_running == null) {
      _running = _client;
      notifyStarted();
    }
    return _running!;
  }
}

/// One device: its database and the services that live on it.
class _Device {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  final LocalConfigService config = LocalConfigService();
  final HistoryService history = HistoryService();
  final PendingSyncTracker tracker = PendingSyncTracker();
  TachiExtensionService extensions = TachiExtensionService();
  TachiSourceSettingService sourceSettings = TachiSourceSettingService();

  void activate() {
    appDb = db;
    localConfigService = config;
    historyService = history;
    pendingSyncTracker = tracker;
    tachiExtensionService = extensions;
    tachiSourceSettingService = sourceSettings;
  }

  /// The app opened (again): its services read what the device keeps.
  Future<void> launch() async {
    extensions = TachiExtensionService();
    sourceSettings = TachiSourceSettingService();
    activate();
    await extensions.initBean();
    await sourceSettings.initBean();
  }

  Future<void> sync(_MemoryServer server) async {
    activate();
    await RecordSyncEngine(adapters: <RecordAdapter>[TachiExtensionRecords(), TachiSourceRecords()]).sync(server);
  }

  /// The settings of [source] changed here, as the settings page takes them
  /// from the host.
  Future<void> changeSource(String source, String choice) async {
    activate();
    sourceSettings.sources[source] = <String, dynamic>{
      'values': <String, dynamic>{'choice': choice},
      'updatedAt': SyncTimeUtil.nowIso(),
    };
    await sourceSettings.saveBeanConfig();
  }

  Future<String?> choiceOf(String source) async {
    activate();
    await sourceSettings.refreshBean();
    return (sourceSettings.sources[source]?['values'] as Map?)?['choice'] as String?;
  }

  /// [pkg] installed (or removed, [origin] null) here, as the extensions
  /// page records it.
  Future<void> setExtension(String pkg, TachiInstalledOrigin? origin) async {
    activate();
    if (origin == null) {
      extensions.origins.remove(pkg);
    } else {
      extensions.origins[pkg] = origin;
    }
    await extensions.saveBeanConfig();
  }

  Future<Set<String>> packages() async {
    activate();
    await extensions.refreshBean();
    return extensions.origins.keys.toSet();
  }
}

TachiInstalledOrigin _origin(String pkg, {String repo = ''}) =>
    TachiInstalledOrigin(pkg: pkg, name: pkg, repo: repo, apk: repo.isEmpty ? '' : 'fake.apk', versionCode: 1);

/// Settings and extensions of Tachiyomi sources synced through a sync server.
void main() {
  late Directory temp;
  final TachiHost appHost = tachiHost;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    log = _SilentLogService();
    isolateService = _InlineIsolateService();
    HttpOverrides.global = null;
    temp = Directory.systemTemp.createTempSync('tachi_sync');
    pathService.tempDir = temp;
  });

  tearDown(() {
    tachiHost = appHost;
    temp.deleteSync(recursive: true);
  });

  test('settings of one source changed on one device and of another on another device are both kept', () async {
    final _MemoryServer server = _MemoryServer();
    final _Device phone = _Device(), desktop = _Device();
    await phone.launch();
    await desktop.launch();
    await phone.changeSource('101', 'phone, before');
    await phone.changeSource('102', 'phone, before');
    await phone.sync(server);
    await desktop.sync(server);

    await phone.changeSource('101', 'phone');
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await desktop.changeSource('102', 'desktop');
    await phone.sync(server);
    await desktop.sync(server);
    await phone.sync(server);

    for (final _Device device in <_Device>[phone, desktop]) {
      expect(await device.choiceOf('101'), 'phone');
      expect(await device.choiceOf('102'), 'desktop');
    }
  });

  test('extensions installed on each of two devices are both kept; one removed on a device goes from the other', () async {
    final _MemoryServer server = _MemoryServer();
    final _Device phone = _Device(), desktop = _Device();
    await phone.launch();
    await desktop.launch();
    await phone.setExtension('package.shared', _origin('package.shared'));
    await phone.sync(server);
    await desktop.sync(server);

    await phone.setExtension('package.phone', _origin('package.phone'));
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await desktop.setExtension('package.desktop', _origin('package.desktop'));
    await phone.sync(server);
    await desktop.sync(server);
    await phone.sync(server);
    for (final _Device device in <_Device>[phone, desktop]) {
      expect(await device.packages(), <String>{'package.shared', 'package.phone', 'package.desktop'});
    }

    await desktop.setExtension('package.shared', null);
    await desktop.sync(server);
    await phone.sync(server);
    expect(await phone.packages(), <String>{'package.phone', 'package.desktop'});
  });

  test('settings and extensions synced while the host does not run reach it when it starts, after the app was closed too', () async {
    final _FakeHost fakeHost = _FakeHost();
    await fakeHost.start();
    addTearDown(fakeHost.stop);
    final TachiClient client = TachiClient(port: fakeHost.port, token: 'token');
    addTearDown(client.close);

    final _MemoryServer server = _MemoryServer();
    final _Device desktop = _Device(), phone = _Device();
    await desktop.launch();
    await desktop.setExtension(_pkg, _origin(_pkg, repo: fakeHost.repo));
    await desktop.changeSource(_source, 'from the desktop');
    await desktop.sync(server);

    // The phone syncs before any Tachiyomi page started the host.
    tachiHost = _LaunchHost(client);
    await phone.launch();
    await phone.sync(server);
    await fakeHost.quiet();
    expect(fakeHost.installs, isEmpty);
    expect(fakeHost.settings, isEmpty);

    // Opened again later; a Tachiyomi page starts the host.
    tachiHost = _LaunchHost(client);
    await phone.launch();
    await tachiHost.client();
    await fakeHost.quiet();
    expect(fakeHost.installs, <String>[_pkg]);
    expect(fakeHost.settings, <String>['$_source {"choice":"from the desktop"}']);

    // The next launch has nothing to give the host.
    tachiHost = _LaunchHost(client);
    await phone.launch();
    await tachiHost.client();
    await fakeHost.quiet();
    expect(fakeHost.installs, hasLength(1));
    expect(fakeHost.settings, hasLength(1));

    // Removed on the desktop while the phone's host is not running, then
    // the phone is closed: the extension goes once the host starts again.
    await desktop.setExtension(_pkg, null);
    await desktop.sync(server);
    tachiHost = _LaunchHost(client);
    await phone.launch();
    await phone.sync(server);
    await fakeHost.quiet();
    expect(fakeHost.uninstalls, isEmpty);
    tachiHost = _LaunchHost(client);
    await phone.launch();
    await tachiHost.client();
    await fakeHost.quiet();
    expect(fakeHost.uninstalls, <String>[_pkg]);
  });
}
