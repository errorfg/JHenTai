import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/network/jm/jm_api.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/service/cloud_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sync_merger.dart';
import 'package:jhentai/src/setting/jm_account_setting.dart';
import 'package:jhentai/src/setting/jm_setting.dart';

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

CloudConfig _config(String value, DateTime time) => CloudConfig(
  id: -1,
  shareCode: 'remote',
  identificationCode: 'remote',
  type: CloudConfigTypeEnum.jmAccount,
  version: '1.0.0',
  config: value,
  ctime: time,
);

void main() {
  setUp(() {
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
    jmSetting = JmSetting();
    jmAccountSetting = JmAccountSetting();
  });

  tearDown(() async {
    await appDb.close();
  });

  group('JM account sync', () {
    test('is its own cloud config type', () {
      expect(CloudConfigTypeEnum.fromCode(13), CloudConfigTypeEnum.jmAccount);
      expect(CloudConfigService.configTypeVersionMap[CloudConfigTypeEnum.jmAccount], '1.0.0');
    });

    test('a login travels to another device, and so does the logout', () async {
      await jmAccountSetting.saveAccount(const JmUser(id: 7, username: 'reader'), 'AVS=session');
      final CloudConfig exported = (await CloudConfigService().getLocalConfig(CloudConfigTypeEnum.jmAccount))!;
      expect(jsonDecode(exported.config), <String, dynamic>{'userName': 'reader', 'userId': 7, 'accountCookie': 'AVS=session'});

      // Another device: an empty database and no account.
      await appDb.close();
      appDb = AppDb.forTesting(NativeDatabase.memory());
      jmAccountSetting = JmAccountSetting();
      await CloudConfigService().importConfig(exported);
      expect(jmAccountSetting.hasLoggedIn, isTrue);
      expect(jmAccountSetting.userName.value, 'reader');
      expect(jmAccountSetting.accountCookie, 'AVS=session');

      await jmAccountSetting.clearAccount();
      final CloudConfig loggedOut = (await CloudConfigService().getLocalConfig(CloudConfigTypeEnum.jmAccount))!;
      await CloudConfigService().importConfig(loggedOut);
      expect(jmAccountSetting.hasLoggedIn, isFalse);
    });

    test('the newest login wins', () async {
      final MergeConfigResult result = await SyncMerger().mergeConfigType(
        CloudConfigTypeEnum.jmAccount,
        _config('{"userName":"old","userId":1,"accountCookie":"AVS=old"}', DateTime.utc(2026, 10, 1)),
        _config('{"userName":"new","userId":2,"accountCookie":"AVS=new"}', DateTime.utc(2026, 10, 5)),
        DateTime.utc(2026, 10, 5),
        null,
      );
      expect(jsonDecode(result.config.config)['userName'], 'new');
    });

    test('a login stored by 8.0.30 or 8.0.31 moves to the synced setting', () async {
      await localConfigService.write(
        configKey: ConfigEnum.jmSetting,
        value: jsonEncode(<String, dynamic>{
          'apiDomains': <String>['www.example.test'],
          'userName': 'reader',
          'userId': 7,
          'accountCookie': 'AVS=session',
        }),
      );
      await jmSetting.initBean();
      await jmAccountSetting.initBean();

      expect(jmAccountSetting.userName.value, 'reader');
      expect(jmAccountSetting.accountCookie, 'AVS=session');
      expect(jmSetting.legacyAccount, isNull);
      expect(await localConfigService.read(configKey: ConfigEnum.jmSetting), isNot(contains('accountCookie')));
      expect(await localConfigService.read(configKey: ConfigEnum.jmAccountSetting), contains('AVS=session'));
    });
  });

  group('JM lines', () {
    test('automatic picks the fastest line that answered', () async {
      jmSetting.apiDomains.value = <String>['a.test', 'b.test', 'c.test', 'd.test'];
      await jmSetting.saveMeasurement(
        const JmLineMeasurement(
          api: <String, Duration?>{'a.test': Duration(seconds: 4), 'b.test': null, 'c.test': Duration(milliseconds: 500)},
          image: <String, Duration?>{'cdn-msp.jmapiproxy1.cc': Duration(seconds: 3), 'cdn-msp.jmapinodeudzn.net': Duration(milliseconds: 900)},
          recommendedImageHost: 'tencent.example.test',
        ),
      );
      // Fastest first, not measured next, failed last.
      expect(jmSetting.orderedApiDomains(), <String>['c.test', 'a.test', 'd.test', 'b.test']);
      expect(jmSetting.imageDomain, 'cdn-msp.jmapinodeudzn.net');
      expect(jmSetting.imageDomainChoices(), contains('tencent.example.test'));

      await jmSetting.savePreferredApiDomain('a.test');
      await jmSetting.savePreferredImageDomain('cdn-msp.jmapiproxy1.cc');
      expect(jmSetting.orderedApiDomains().first, 'a.test');
      expect(jmSetting.imageDomain, 'cdn-msp.jmapiproxy1.cc');
      expect(jmSetting.autoImageDomain, 'cdn-msp.jmapinodeudzn.net');
    });

    test('without a measurement the server recommendation is used', () {
      jmSetting.recommendedImageDomain.value = 'tencent.example.test';
      expect(jmSetting.imageDomain, 'tencent.example.test');
    });
  });
}
