import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/service/cloud_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sync_merger.dart';
import 'package:jhentai/src/setting/eh2telegraph_setting.dart';

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

void main() {
  group('eh2telegraph setting cloud sync', () {
    setUp(() {
      log = _SilentLogService();
      appDb = AppDb.forTesting(NativeDatabase.memory());
      eh2telegraphSetting.endpoint.value = '';
      eh2telegraphSetting.token.value = '';
    });

    tearDown(() async {
      await appDb.close();
      eh2telegraphSetting.endpoint.value = '';
      eh2telegraphSetting.token.value = '';
    });

    test('uses a dedicated, versioned cloud config type', () {
      expect(
        CloudConfigTypeEnum.fromCode(11),
        CloudConfigTypeEnum.eh2telegraphSetting,
      );
      expect(
        CloudConfigService.configTypeVersionMap[CloudConfigTypeEnum
            .eh2telegraphSetting],
        '1.0.0',
      );
      expect(
        CloudConfigTypeEnum.values,
        contains(CloudConfigTypeEnum.eh2telegraphSetting),
      );
    });

    test('exports and imports endpoint and token as one record', () async {
      const String localPayload =
          '{"endpoint":"http://100.64.0.1:8788","token":"local-token"}';
      await localConfigService.write(
        configKey: ConfigEnum.eh2telegraphSetting,
        value: localPayload,
      );

      final CloudConfig? exported = await CloudConfigService().getLocalConfig(
        CloudConfigTypeEnum.eh2telegraphSetting,
      );
      expect(exported, isNotNull);
      expect(exported!.config, localPayload);
      expect(exported.type, CloudConfigTypeEnum.eh2telegraphSetting);

      const String remotePayload =
          '{"endpoint":"http://100.64.0.1:8788","token":"remote-token"}';
      final DateTime remoteTime = DateTime.utc(2026, 8, 25, 12);
      await CloudConfigService().importConfig(
        CloudConfig(
          id: -1,
          shareCode: 'remote',
          identificationCode: 'remote',
          type: CloudConfigTypeEnum.eh2telegraphSetting,
          version: '1.0.0',
          config: remotePayload,
          ctime: remoteTime,
        ),
      );

      expect(eh2telegraphSetting.endpoint.value, 'http://100.64.0.1:8788');
      expect(eh2telegraphSetting.token.value, 'remote-token');
      expect(eh2telegraphSetting.isConfigured, isTrue);
      expect(
        await localConfigService.read(
          configKey: ConfigEnum.eh2telegraphSetting,
        ),
        remotePayload,
      );
      final CloudConfig? reexported = await CloudConfigService().getLocalConfig(
        CloudConfigTypeEnum.eh2telegraphSetting,
      );
      expect(reexported?.ctime, remoteTime);
      expect(jsonDecode(reexported!.config), <String, dynamic>{
        'endpoint': 'http://100.64.0.1:8788',
        'token': 'remote-token',
      });
    });

    test('newest setting wins whole-file conflicts', () async {
      CloudConfig config(String value, DateTime time) => CloudConfig(
        id: -1,
        shareCode: 'local',
        identificationCode: 'local',
        type: CloudConfigTypeEnum.eh2telegraphSetting,
        version: '1.0.0',
        config: value,
        ctime: time,
      );

      final MergeConfigResult result = await SyncMerger().mergeConfigType(
        CloudConfigTypeEnum.eh2telegraphSetting,
        config(
          '{"endpoint":"http://old","token":"old"}',
          DateTime.utc(2026, 8, 24),
        ),
        config(
          '{"endpoint":"http://new","token":"new"}',
          DateTime.utc(2026, 8, 25),
        ),
        DateTime.utc(2026, 8, 25),
        null,
      );

      expect(result.config.config, contains('http://new'));
    });
  });
}
