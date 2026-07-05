import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';

/// The real LogService lazily creates log files via pathService, which is not
/// initialized in unit tests.
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

/// The timestamp-guarded write-backs are the core protection against a sync
/// merge (computed from a stale snapshot) rolling back rows written while the
/// sync was in flight.
void main() {
  setUp(() {
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await appDb.close();
  });

  LocalConfigCompanion progressRow(String gid, String value, String utime) {
    return LocalConfigCompanion(
      configKey: const Value('readIndexRecord'),
      subConfigKey: Value(gid),
      value: Value(value),
      utime: Value(utime),
    );
  }

  group('LocalConfigService.batchWriteIfNewer', () {
    test('inserts absent rows, skips stale rows, applies newer rows', () async {
      LocalConfigService service = LocalConfigService();

      await service.batchWrite([
        progressRow('1001', '20', '2026-07-05T10:00:00.000Z'),
        progressRow('1002', '5', '2026-07-05T10:00:00.000Z'),
      ]);

      int written = await service.batchWriteIfNewer(
        configKey: ConfigEnum.readIndexRecord,
        localConfigs: [
          // Stale: older than local -> must not roll back
          progressRow('1001', '10', '2026-07-05T09:00:00.000Z'),
          // Newer: must apply
          progressRow('1002', '8', '2026-07-05T11:00:00.000Z'),
          // Absent: must insert
          progressRow('1003', '3', '2026-07-05T08:00:00.000Z'),
        ],
      );

      expect(written, 2);

      List<LocalConfig> rows = await service.readWithAllSubKeys(configKey: ConfigEnum.readIndexRecord);
      Map<String, String> values = {for (var r in rows) r.subConfigKey: r.value};
      expect(values['1001'], '20', reason: 'stale merge result must not roll back progress');
      expect(values['1002'], '8');
      expect(values['1003'], '3');
    });

    test('same timestamp with same value is not rewritten', () async {
      LocalConfigService service = LocalConfigService();
      await service.batchWrite([progressRow('1001', '20', '2026-07-05T10:00:00.000Z')]);

      int written = await service.batchWriteIfNewer(
        configKey: ConfigEnum.readIndexRecord,
        localConfigs: [progressRow('1001', '20', '2026-07-05T10:00:00.000Z')],
      );
      expect(written, 0);
    });

    test('handles legacy local-time timestamps on either side', () async {
      LocalConfigService service = LocalConfigService();

      DateTime base = DateTime(2026, 7, 5, 21, 30);
      await service.batchWrite([progressRow('1001', '20', base.toString())]);

      int written = await service.batchWriteIfNewer(
        configKey: ConfigEnum.readIndexRecord,
        localConfigs: [
          progressRow('1001', '25', base.add(const Duration(minutes: 1)).toUtc().toIso8601String()),
        ],
      );
      expect(written, 1);

      List<LocalConfig> rows = await service.readWithAllSubKeys(configKey: ConfigEnum.readIndexRecord);
      expect(rows.single.value, '25');
    });
  });

  group('HistoryService.batchRecordIfNewer', () {
    GalleryHistoryV2Data history(int gid, String body, String time) {
      return GalleryHistoryV2Data(gid: gid, jsonBody: body, lastReadTime: time);
    }

    test('inserts absent rows, skips stale rows, applies newer rows', () async {
      HistoryService service = HistoryService();

      await service.batchRecordIfNewer([
        history(1, 'local-1', '2026-07-05T10:00:00.000Z'),
        history(2, 'local-2', '2026-07-05T10:00:00.000Z'),
      ]);

      int written = await service.batchRecordIfNewer([
        history(1, 'stale', '2026-07-05T09:00:00.000Z'),
        history(2, 'newer', '2026-07-05T11:00:00.000Z'),
        history(3, 'fresh', '2026-07-05T08:00:00.000Z'),
      ]);

      expect(written, 2);

      List<GalleryHistoryV2Data> rows = await service.getAllRawHistory();
      Map<int, String> bodies = {for (var r in rows) r.gid: r.jsonBody};
      expect(bodies[1], 'local-1', reason: 'stale merge result must not roll back history');
      expect(bodies[2], 'newer');
      expect(bodies[3], 'fresh');
    });
  });

  group('LocalConfigService cursor queries', () {
    test('readNewerThan and maxUtime', () async {
      LocalConfigService service = LocalConfigService();
      await service.batchWrite([
        progressRow('1', '1', '2026-07-05T10:00:00.000Z'),
        progressRow('2', '2', '2026-07-05T11:00:00.000Z'),
        progressRow('3', '3', '2026-07-05T12:00:00.000Z'),
      ]);

      List<LocalConfig> newer =
          await service.readNewerThan(configKey: ConfigEnum.readIndexRecord, utimeExclusive: '2026-07-05T10:00:00.000Z');
      expect(newer.map((r) => r.subConfigKey).toSet(), {'2', '3'});

      String? max = await service.maxUtime(configKey: ConfigEnum.readIndexRecord);
      expect(max, '2026-07-05T12:00:00.000Z');
    });
  });
}
