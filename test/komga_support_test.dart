import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/tab_bar_icon.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/pages/layout/desktop/desktop_layout_page_state.dart';
import 'package:jhentai/src/service/cloud_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sync_merger.dart';
import 'package:jhentai/src/setting/komga_setting.dart';

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
  group('Komga client identity and authentication', () {
    test('normalizes the URL and builds Basic authentication', () {
      final KomgaClient client = KomgaClient(
        serverUrl: 'https://komga.example.com///',
        username: 'reader',
        password: 'secret',
        apiKey: '',
      );

      expect(client.serverUrl, 'https://komga.example.com');
      expect(client.authHeaders, {
        'Authorization': 'Basic ${base64Encode(utf8.encode('reader:secret'))}',
      });
      expect(
        client.bookPageUrl('book id', 3),
        'https://komga.example.com/api/v1/books/book%20id/pages/3?contentNegotiation=false',
      );
    });

    test(
      'API key takes priority and source-specific progress keys are stable',
      () {
        final KomgaClient first = KomgaClient(
          serverUrl: 'https://komga.example.com',
          username: 'ignored',
          password: 'ignored',
          apiKey: 'key-1',
        );
        final KomgaClient same = KomgaClient(
          serverUrl: 'https://komga.example.com/',
          username: 'ignored',
          password: 'different',
          apiKey: 'key-1',
        );
        final KomgaClient other = KomgaClient(
          serverUrl: 'https://other.example.com',
          username: 'ignored',
          password: 'ignored',
          apiKey: 'key-1',
        );

        expect(first.authHeaders, {'X-API-Key': 'key-1'});
        expect(
          first.progressRecordKey('book-1'),
          same.progressRecordKey('book-1'),
        );
        expect(
          first.progressRecordKey('book-1'),
          isNot(other.progressRecordKey('book-1')),
        );
      },
    );

    test(
      'explicit connection IDs keep progress stable across credential changes',
      () {
        final KomgaClient before = KomgaClient(
          serverUrl: 'https://komga.example.com',
          username: 'reader',
          password: 'old-password',
          apiKey: '',
          connectionId: 'connection-1',
        );
        final KomgaClient after = KomgaClient(
          serverUrl: 'https://komga.example.com',
          username: 'reader-renamed',
          password: 'new-password',
          apiKey: '',
          connectionId: 'connection-1',
        );

        expect(before.progressRecordKey('book-1'), 'komga:connection-1:book-1');
        expect(
          after.progressRecordKey('book-1'),
          before.progressRecordKey('book-1'),
        );
      },
    );
  });

  test('authenticated image headers remain transient', () {
    final GalleryImage image = GalleryImage(
      url: 'https://komga.example.com/page',
      headers: const {'X-API-Key': 'secret'},
    );

    expect(image.toJson().containsKey('headers'), false);
    expect(image.toJson().containsKey('cacheKey'), false);
    expect(GalleryImage.fromJson(image.toJson()).headers, null);
  });

  test('desktop menu keeps the reader source button as its bottom item', () {
    final DesktopLayoutPageState state = DesktopLayoutPageState();

    expect(state.icons.last.name, TabBarIconNameEnum.readerSource);
  });

  test('Komga credentials are represented by the synced setting payload', () {
    final KomgaSetting setting = KomgaSetting();
    setting.applyBeanConfig(
      jsonEncode({
        'serverUrl': 'https://komga.example.com',
        'username': 'reader',
        'password': 'secret',
        'apiKey': 'api-key',
      }),
    );

    final Map<String, dynamic> payload = jsonDecode(setting.toConfigString());
    expect(payload['serverUrl'], 'https://komga.example.com');
    expect(payload['password'], 'secret');
    expect(payload['apiKey'], 'api-key');
    expect(
      payload['connectionId'],
      KomgaSetting.legacyConnectionId(
        serverUrl: 'https://komga.example.com',
        username: 'reader',
        apiKey: 'api-key',
      ),
    );
    expect(CloudConfigTypeEnum.fromCode(9), CloudConfigTypeEnum.komgaSetting);
  });

  test('legacy Komga config keeps the previous progress namespace', () {
    final KomgaSetting setting = KomgaSetting();
    setting.applyBeanConfig(
      jsonEncode({
        'serverUrl': 'https://komga.example.com/',
        'username': 'reader',
        'password': 'secret',
        'apiKey': '',
      }),
    );
    final String legacyFingerprint = sha1
        .convert(utf8.encode('https://komga.example.com|reader'))
        .toString();
    final KomgaClient client = KomgaClient(
      serverUrl: setting.serverUrl.value,
      username: setting.username.value,
      password: setting.password.value,
      apiKey: setting.apiKey.value,
      connectionId: setting.connectionId.value,
    );

    expect(setting.connectionId.value, legacyFingerprint);
    expect(
      client.progressRecordKey('book-1'),
      'komga:$legacyFingerprint:book-1',
    );
  });

  test('Komga config merge uses the newest config timestamp', () async {
    CloudConfig config(String value, DateTime time) => CloudConfig(
      id: -1,
      shareCode: 'local',
      identificationCode: 'local',
      type: CloudConfigTypeEnum.komgaSetting,
      version: '1.0.0',
      config: value,
      ctime: time,
    );

    final MergeConfigResult result = await SyncMerger().mergeConfigType(
      CloudConfigTypeEnum.komgaSetting,
      config('local', DateTime.utc(2026, 8, 2, 10)),
      config('remote', DateTime.utc(2026, 8, 2, 11)),
      DateTime.utc(2026, 8, 2, 11),
      null,
    );

    expect(result.config.config, 'remote');
  });

  group('Komga cloud configuration wiring', () {
    setUp(() {
      log = _SilentLogService();
      appDb = AppDb.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await appDb.close();
    });

    test('exports and imports the full server configuration', () async {
      const String localPayload =
          '{"serverUrl":"https://local.example.com","username":"local","password":"local-pass","apiKey":"","connectionId":"local-connection"}';
      await localConfigService.write(
        configKey: ConfigEnum.komgaSetting,
        value: localPayload,
      );

      final CloudConfig? exported = await CloudConfigService().getLocalConfig(
        CloudConfigTypeEnum.komgaSetting,
      );
      expect(exported, isNotNull);
      expect(exported!.config, localPayload);
      expect(exported.type, CloudConfigTypeEnum.komgaSetting);

      const String remotePayload =
          '{"serverUrl":"https://remote.example.com","username":"","password":"","apiKey":"remote-key","connectionId":"remote-connection"}';
      await CloudConfigService().importConfig(
        CloudConfig(
          id: -1,
          shareCode: 'remote',
          identificationCode: 'remote',
          type: CloudConfigTypeEnum.komgaSetting,
          version: '1.0.0',
          config: remotePayload,
          ctime: DateTime.utc(2026, 8, 2),
        ),
      );

      expect(komgaSetting.serverUrl.value, 'https://remote.example.com');
      expect(komgaSetting.apiKey.value, 'remote-key');
      expect(komgaSetting.connectionId.value, 'remote-connection');
      expect(
        await localConfigService.read(configKey: ConfigEnum.komgaSetting),
        remotePayload,
      );
      final CloudConfig? reexported = await CloudConfigService().getLocalConfig(
        CloudConfigTypeEnum.komgaSetting,
      );
      expect(reexported, isNotNull);
      expect(reexported!.ctime, DateTime.utc(2026, 8, 2));

      final MergeConfigResult nextMerge = await SyncMerger().mergeConfigType(
        CloudConfigTypeEnum.komgaSetting,
        reexported,
        CloudConfig(
          id: -1,
          shareCode: 'remote',
          identificationCode: 'remote',
          type: CloudConfigTypeEnum.komgaSetting,
          version: '1.0.0',
          config:
              '{"serverUrl":"https://newer.example.com","username":"","password":"","apiKey":"newer-key","connectionId":"newer-connection"}',
          ctime: DateTime.utc(2026, 8, 3),
        ),
        DateTime.utc(2026, 8, 3),
        null,
      );
      expect(nextMerge.config.config, contains('newer.example.com'));
    });

    test(
      'saving credential changes on the same server preserves connection ID',
      () async {
        final KomgaSetting setting = KomgaSetting();
        setting.applyBeanConfig(
          jsonEncode({
            'serverUrl': 'https://komga.example.com',
            'username': 'old-user',
            'password': 'old-password',
            'apiKey': '',
            'connectionId': 'stable-connection',
          }),
        );

        await setting.save(
          serverUrl: 'https://komga.example.com/',
          username: 'new-user',
          password: 'new-password',
          apiKey: '',
        );

        expect(setting.connectionId.value, 'stable-connection');
        expect(
          jsonDecode(setting.toConfigString())['connectionId'],
          'stable-connection',
        );
      },
    );
  });
}
