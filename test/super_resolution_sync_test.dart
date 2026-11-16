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
import 'package:jhentai/src/setting/super_resolution_setting.dart';

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
  type: CloudConfigTypeEnum.superResolutionSetting,
  version: '1.0.0',
  config: value,
  ctime: time,
);

void main() {
  group('super resolution setting cloud sync', () {
    late String defaults;

    setUp(() {
      log = _SilentLogService();
      appDb = AppDb.forTesting(NativeDatabase.memory());
      defaults = SuperResolutionSetting().toConfigString();
      superResolutionSetting.applyBeanConfig(defaults);
      superResolutionSetting.modelDirectoryPath.value = null;
    });

    tearDown(() async {
      await appDb.close();
      superResolutionSetting.applyBeanConfig(defaults);
      superResolutionSetting.modelDirectoryPath.value = null;
    });

    test('uses a dedicated, versioned cloud config type', () {
      expect(CloudConfigTypeEnum.fromCode(19), CloudConfigTypeEnum.superResolutionSetting);
      expect(CloudConfigTypeEnum.tryFromCode(19), CloudConfigTypeEnum.superResolutionSetting);
      expect(CloudConfigService.configTypeVersionMap[CloudConfigTypeEnum.superResolutionSetting], '1.0.0');
    });

    test('exports the stored setting', () async {
      expect(await CloudConfigService().getLocalConfig(CloudConfigTypeEnum.superResolutionSetting), isNull);

      await superResolutionSetting.saveRealtimeServerUrl(' http://sr.example:8000/ ');
      final CloudConfig? exported = await CloudConfigService().getLocalConfig(CloudConfigTypeEnum.superResolutionSetting);
      expect(exported, isNotNull);
      expect(jsonDecode(exported!.config)['realtimeServerUrl'], 'http://sr.example:8000');
    });

    test('import takes the service and the model, keeps what is this computer\'s', () async {
      superResolutionSetting.modelDirectoryPath.value = '/here/models';
      superResolutionSetting.gpuId.value = 1;
      superResolutionSetting.realtimeBatchSize.value = 8;
      superResolutionSetting.realtimeOnServer.value = false;
      superResolutionSetting.model.value = ModelType.ESRGAN;

      final DateTime remoteTime = DateTime.utc(2026, 11, 17, 12);
      await CloudConfigService().importConfig(
        _config(
          jsonEncode({
            'modelDirectoryPath': '/there/models',
            'model': ModelType.CUGAN.index,
            'gpuId': 3,
            'realtimeEnabled': true,
            'realtimeModel': 'realcugan-se',
            'realtimeScale': 3,
            'realtimeDenoise': 1,
            'realtimeMaxWidth': 2000,
            'realtimeBatchSize': 16,
            'realtimeServerUrl': 'http://sr.example:8000',
            'realtimeOnServer': true,
          }),
          remoteTime,
        ),
      );

      expect(superResolutionSetting.realtimeServerUrl.value, 'http://sr.example:8000');
      expect(superResolutionSetting.realtimeEnabled.value, isTrue);
      expect(superResolutionSetting.realtimeModel.value, 'realcugan-se');
      expect(superResolutionSetting.realtimeScale.value, 3);
      expect(superResolutionSetting.realtimeDenoise.value, 1);
      expect(superResolutionSetting.realtimeMaxWidth.value, 2000);

      expect(superResolutionSetting.modelDirectoryPath.value, '/here/models');
      expect(superResolutionSetting.gpuId.value, 1);
      expect(superResolutionSetting.realtimeBatchSize.value, 8);
      expect(superResolutionSetting.realtimeOnServer.value, isFalse);
      expect(superResolutionSetting.model.value, ModelType.ESRGAN);

      final CloudConfig? reexported = await CloudConfigService().getLocalConfig(CloudConfigTypeEnum.superResolutionSetting);
      expect(reexported?.ctime, remoteTime);
      expect(
        jsonDecode((await localConfigService.read(configKey: ConfigEnum.superResolutionSetting))!)['realtimeServerUrl'],
        'http://sr.example:8000',
      );
    });

    test('import of only the service address leaves the other options', () async {
      superResolutionSetting.realtimeScale.value = 4;
      await CloudConfigService().importConfig(
        _config('{"realtimeServerUrl":"http://sr.example:8000"}', DateTime.utc(2026, 11, 17)),
      );
      expect(superResolutionSetting.realtimeServerUrl.value, 'http://sr.example:8000');
      expect(superResolutionSetting.realtimeScale.value, 4);
      final Map stored = jsonDecode((await localConfigService.read(configKey: ConfigEnum.superResolutionSetting))!);
      expect(stored['realtimeScale'], 4);
      expect(stored['realtimeServerUrl'], 'http://sr.example:8000');
    });

    test('newest setting wins whole-file conflicts', () async {
      final MergeConfigResult result = await SyncMerger().mergeConfigType(
        CloudConfigTypeEnum.superResolutionSetting,
        _config('{"realtimeServerUrl":"http://old"}', DateTime.utc(2026, 11, 16)),
        _config('{"realtimeServerUrl":"http://new"}', DateTime.utc(2026, 11, 17)),
        DateTime.utc(2026, 11, 17),
        null,
      );
      expect(result.config.config, contains('http://new'));
    });
  });
}
