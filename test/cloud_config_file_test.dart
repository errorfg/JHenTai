import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';

Map<String, dynamic> _entry(int type, String config, {int ctime = 1000}) =>
    <String, dynamic>{
      'id': -1,
      'shareCode': 'local',
      'identificationCode': 'local',
      'type': type,
      'version': '1.0.0',
      'config': config,
      'ctime': ctime,
    };

CloudConfig _config(CloudConfigTypeEnum type, String config) => CloudConfig(
  id: -1,
  shareCode: 'local',
  identificationCode: 'local',
  type: type,
  version: '1.0.0',
  config: config,
  ctime: DateTime.utc(2026, 10, 4),
);

void main() {
  group('CloudConfigFile', () {
    test('unknown type codes from newer clients do not fail parsing', () {
      final Map<String, dynamic> future = _entry(99, '{"newer":true}');
      final CloudConfigFile file = CloudConfigFile.fromJson(<dynamic>[
        _entry(9, '{"serverUrl":"http://komga"}'),
        future,
      ]);

      expect(file.configs.map((c) => c.type), [
        CloudConfigTypeEnum.komgaSetting,
      ]);
      expect(file.unknownEntries, [future]);
    });

    test('rejects payloads that are not a list of objects', () {
      expect(
        () => CloudConfigFile.fromJson(<String, dynamic>{}),
        throwsFormatException,
      );
      expect(
        () => CloudConfigFile.fromJson(<dynamic>['text']),
        throwsFormatException,
      );
    });

    test(
      'upload keeps remote entries of types that were not merged, in order',
      () {
        final Map<String, dynamic> future = _entry(99, '{"newer":true}');
        final CloudConfigFile remote = CloudConfigFile.fromJson(<dynamic>[
          _entry(3, '[]'),
          _entry(9, '{"serverUrl":"http://komga"}'),
          future,
        ]);

        final List<Map<String, dynamic>> upload = remote
            .toUploadJson(<CloudConfig>[
              _config(CloudConfigTypeEnum.blockRules, '[{"id":1}]'),
              _config(CloudConfigTypeEnum.eh2telegraphSetting, '{"token":"t"}'),
            ]);

        expect(upload.map((e) => e['type']), [3, 9, 11, 99]);
        expect(upload[0]['config'], '[{"id":1}]');
        expect(upload[1]['config'], '{"serverUrl":"http://komga"}');
        expect(upload[3], future);
      },
    );

    test('dropped types are removed from the upload', () {
      final CloudConfigFile remote = CloudConfigFile.fromJson(<dynamic>[
        _entry(5, '[]'),
        _entry(9, '{"serverUrl":"http://komga"}'),
      ]);

      final List<Map<String, dynamic>> upload = remote.toUploadJson(
        const <CloudConfig>[],
        dropped: const <CloudConfigTypeEnum>{CloudConfigTypeEnum.history},
      );

      expect(upload.map((e) => e['type']), [9]);
    });

    test('an unknown entry survives an encode/decode round trip verbatim', () {
      final String remoteJson = jsonEncode(<dynamic>[
        _entry(42, '{"a":1}', ctime: 1791089548225),
      ]);
      final CloudConfigFile remote = CloudConfigFile.fromJson(
        jsonDecode(remoteJson),
      );

      expect(
        jsonEncode(remote.toUploadJson(const <CloudConfig>[])),
        remoteJson,
      );
    });
  });
}
