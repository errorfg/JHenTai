import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/network/eh_cookie_manager.dart';
import 'package:jhentai/src/network/eh_igneous.dart';
import 'package:jhentai/src/service/eh_account_sync.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/record_sync/record_adapters.dart';
import 'package:jhentai/src/service/record_sync/record_backend.dart';
import 'package:jhentai/src/service/record_sync/record_sync_engine.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';

import 'memory_bucket.dart';

/// The E-Hentai login travels between devices, through the sync server and
/// through a bucket; igneous does not: each device gets its own.

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

/// The app's cookie store; logout as the logout button does it.
class _ManagerJar implements EhCookieJar {
  _ManagerJar(this.manager, this.settings);

  final EHCookieManager manager;
  final UserSetting settings;

  @override
  List<Cookie> get cookies => manager.cookies;

  @override
  Future<void> store(List<Cookie> cookies) => manager.storeEHCookies(cookies);

  @override
  Future<void> remove(List<String> names) => manager.removeCookies(names);

  @override
  Future<void> logout() async {
    await manager.removeAllCookies();
    await settings.clearBeanConfig();
  }
}

class _Stored {
  final RemoteRecord record;
  final int seq;

  _Stored(this.record, this.seq);
}

class _MemoryServer implements RecordBackend {
  final Map<String, _Stored> stored = {};
  int seq = 0;

  @override
  Future<RecordServerInfo> info() async => const RecordServerInfo(protocol: 1, database: 'db-1');

  @override
  Future<void> push(List<RemoteRecord> records) async {
    for (RemoteRecord record in records) {
      String id = '${record.kind}\u0000${record.key}';
      _Stored? current = stored[id];
      if (current == null ||
          compareVersions(record.updatedAt, record.device, current.record.updatedAt, current.record.device) > 0) {
        stored[id] = _Stored(record, ++seq);
      }
    }
  }

  @override
  Future<RecordPage> pull({required String since, required String device, required int limit}) async {
    final int after = int.tryParse(since) ?? 0;
    List<_Stored> page = (stored.values.where((s) => s.seq > after && s.record.device != device).toList()
          ..sort((a, b) => a.seq.compareTo(b.seq)))
        .take(limit)
        .toList();
    bool more = page.length == limit;
    return RecordPage(
      records: page.map((s) => s.record).toList(),
      next: '${more ? page.last.seq : (seq > after ? seq : after)}',
      more: more,
    );
  }
}

/// latest.json in memory.
class _Device {
  _Device(this.name) {
    jar = _ManagerJar(EHCookieManager(config), user);
    accountSync = EhAccountSync(jar: jar, fetchIgneous: _fetch);
  }

  final String name;
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  final LocalConfigService config = LocalConfigService();
  final UserSetting user = UserSetting();
  final SyncSetting settings = SyncSetting()
    ..enableSync.value = true
    ..autoSync.value = true
    ..enableHistory.value = false;
  late final _ManagerJar jar;
  late final EhAccountSync accountSync;
  IgneousResult nextIgneous = IgneousResult.refreshed;
  int igneousRequests = 0;

  Future<IgneousRefresh> _fetch({required int ipbMemberId, required String ipbPassHash}) async {
    igneousRequests++;
    return nextIgneous == IgneousResult.refreshed
        ? IgneousRefresh(IgneousResult.refreshed, value: '$name-igneous')
        : IgneousRefresh(nextIgneous, message: 'unreachable');
  }

  void activate() {
    appDb = db;
    localConfigService = config;
    userSetting = user;
    ehAccountSync = accountSync;
    syncSetting = settings;
  }

  Future<void> login() async {
    activate();
    await jar.store([
      Cookie('ipb_member_id', '1234'),
      Cookie('ipb_pass_hash', 'pass-hash'),
      Cookie('igneous', '$name-igneous'),
      Cookie('sk', 'settings-key'),
      Cookie('hath_perks', 'perks'),
      Cookie('ipb_session_id', '$name-session'),
      Cookie('event', '$name-event'),
    ]);
    await user.saveUserInfo(userName: 'reader', ipbMemberId: 1234, ipbPassHash: 'pass-hash', nickName: 'Reader');
  }

  /// What the logout of the account page does.
  Future<void> logout() async {
    activate();
    await jar.logout();
    await accountSync.markLoggedOut();
  }

  Future<void> syncThroughServer(_MemoryServer server) async {
    activate();
    await RecordSyncEngine(adapters: [EhAccountRecords()]).sync(server);
    await accountSync.igneousFetch;
  }

  Future<void> syncThroughBucket(MemoryBucket bucket) async {
    activate();
    settings.currentProvider.value = 's3';
    SyncResult result = await SyncService(providerFactory: (_) => bucket).sync(types: const [CloudConfigTypeEnum.ehAccount]);
    expect(result.success, isTrue, reason: result.message);
    await accountSync.igneousFetch;
  }

  Map<String, String> cookies() => {for (Cookie c in jar.cookies) c.name: c.value};
}

void main() {
  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    log = _SilentLogService();
    isolateService = _InlineIsolateService();
  });

  Future<void> expectLoggedInWithOwnIgneous(_Device device) async {
    device.activate();
    expect(device.user.ipbMemberId.value, 1234);
    expect(device.user.ipbPassHash.value, 'pass-hash');
    expect(device.user.nickName.value, 'Reader');
    Map<String, String> cookies = device.cookies();
    expect(cookies['ipb_member_id'], '1234');
    expect(cookies['ipb_pass_hash'], 'pass-hash');
    expect(cookies['sk'], 'settings-key');
    expect(cookies['hath_perks'], 'perks');
    expect(cookies['igneous'], '${device.name}-igneous', reason: 'its own, not the other device\'s');
    expect(cookies.containsKey('ipb_session_id'), isFalse, reason: 'session cookies stay where they are');
    expect(await device.config.read(configKey: ConfigEnum.ehIgneousPending), isNull);
  }

  void expectLoggedOut(_Device device) {
    device.activate();
    expect(device.user.hasLoggedIn(), isFalse);
    expect(device.cookies().containsKey('ipb_member_id'), isFalse);
    expect(device.cookies().containsKey('igneous'), isFalse);
  }

  test('a login reaches the other device through the sync server, with an igneous of its own, and so does a logout', () async {
    final _MemoryServer server = _MemoryServer();
    final _Device phone = _Device('phone');
    final _Device desktop = _Device('desktop');

    await phone.login();
    await phone.syncThroughServer(server);
    String synced = server.stored.values.single.record.value!;
    expect(synced, isNot(contains('igneous')));
    expect(synced, isNot(contains('phone-session')));

    // The desktop never logged in; it browsed, so it has cookies of its own.
    desktop.activate();
    await desktop.jar.store([Cookie('event', 'desktop-event')]);
    await desktop.syncThroughServer(server);
    await expectLoggedInWithOwnIgneous(desktop);
    expect(desktop.cookies()['event'], 'desktop-event');
    expect(desktop.igneousRequests, 1);
    expect(phone.cookies()['igneous'], 'phone-igneous');

    // Nothing more moves once both agree.
    await phone.syncThroughServer(server);
    await desktop.syncThroughServer(server);
    expect(desktop.igneousRequests, 1);
    await expectLoggedInWithOwnIgneous(desktop);

    await phone.logout();
    await phone.syncThroughServer(server);
    await desktop.syncThroughServer(server);
    expectLoggedOut(desktop);
    await desktop.syncThroughServer(server);
    await phone.syncThroughServer(server);
    expectLoggedOut(desktop);
    expectLoggedOut(phone);
  });

  test('a login reaches the other device through a bucket, with an igneous of its own, and so does a logout', () async {
    final MemoryBucket bucket = MemoryBucket();
    final _Device phone = _Device('phone');
    final _Device desktop = _Device('desktop');

    await phone.login();
    await phone.syncThroughBucket(bucket);
    expect(bucket.latest, isNot(contains('phone-igneous')));

    await desktop.syncThroughBucket(bucket);
    await expectLoggedInWithOwnIgneous(desktop);
    expect(phone.cookies()['igneous'], 'phone-igneous');

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await phone.logout();
    await phone.syncThroughBucket(bucket);
    await desktop.syncThroughBucket(bucket);
    expectLoggedOut(desktop);
    await desktop.syncThroughBucket(bucket);
    expectLoggedOut(desktop);
  });

  test('an igneous that could not be fetched is fetched at the next launch', () async {
    final _MemoryServer server = _MemoryServer();
    final _Device phone = _Device('phone');
    final _Device desktop = _Device('desktop');
    await phone.login();
    await phone.syncThroughServer(server);

    desktop.nextIgneous = IgneousResult.failed;
    await desktop.syncThroughServer(server);
    expect(desktop.cookies().containsKey('igneous'), isFalse);
    expect(await desktop.config.read(configKey: ConfigEnum.ehIgneousPending), 'true');

    // The next launch
    desktop.nextIgneous = IgneousResult.refreshed;
    await desktop.accountSync.fetchIgneousIfPending();
    await expectLoggedInWithOwnIgneous(desktop);
  });
}
