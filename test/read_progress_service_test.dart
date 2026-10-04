import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';

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
  late PendingSyncTracker originalPendingSyncTracker;

  setUp(() {
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
    originalPendingSyncTracker = pendingSyncTracker;
    pendingSyncTracker = PendingSyncTracker();
  });

  tearDown(() async {
    pendingSyncTracker = originalPendingSyncTracker;
    await appDb.close();
  });

  LocalConfigCompanion progressRow(String key, String value, String utime) {
    return LocalConfigCompanion(
      configKey: const Value('readIndexRecord'),
      subConfigKey: Value(key),
      value: Value(value),
      utime: Value(utime),
    );
  }

  group('ReadProgressService unread marker', () {
    test('an empty value reads as no progress', () async {
      final ReadProgressService service = ReadProgressService();
      await localConfigService.batchWrite([
        progressRow('komga:server:unread', '', '2026-10-04T10:00:00.000000Z'),
        progressRow('komga:server:read', '3', '2026-10-04T10:00:00.000000Z'),
      ]);

      expect(
        await service.getReadProgressEntryByKey('komga:server:unread'),
        isNull,
      );
      expect(await service.getReadProgressByKey('komga:server:unread'), 0);
      expect(
        (await service.getReadProgressEntriesByKeys({
          'komga:server:unread',
          'komga:server:read',
        })).keys,
        ['komga:server:read'],
      );
    });

    test('raw records include unread markers and omit missing keys', () async {
      final ReadProgressService service = ReadProgressService();
      await localConfigService.batchWrite([
        progressRow('a', '', '2026-10-04T10:00:00.000000Z'),
        progressRow('b', '7', '2026-10-04T11:00:00.000000Z'),
      ]);

      final Map<String, ReadProgressRecord> records = await service
          .getProgressRecords({'a', 'b', 'missing'});

      expect(records.keys.toSet(), {'a', 'b'});
      expect(records['a']!.value, '');
      expect(records['b']!.value, '7');
      expect(records['b']!.utime, '2026-10-04T11:00:00.000000Z');
    });

    test(
      'deleting progress writes a newer unread marker and marks it for sync',
      () async {
        final ReadProgressService service = ReadProgressService();
        await localConfigService.batchWrite([
          progressRow('123', '9', '2026-01-01T10:00:00.000000Z'),
        ]);

        await service.deleteReadProgress('123');

        final Map<String, ReadProgressRecord> records = await service
            .getProgressRecords({'123'});
        expect(records['123']!.value, '');
        expect(
          records['123']!.utime.compareTo('2026-01-01T10:00:00.000000Z'),
          greaterThan(0),
        );
        expect(await service.getReadProgressEntryByKey('123'), isNull);
        expect((await pendingSyncTracker.snapshot()).$2, contains('123'));
      },
    );
  });

  group('ReadProgressService rich progress records', () {
    test('distinguishes an absent record from page index zero', () async {
      final ReadProgressService service = ReadProgressService();

      expect(
        await service.getReadProgressEntryByKey('komga:server:missing'),
        isNull,
      );
      expect(await service.getReadProgressByKey('komga:server:missing'), 0);

      await localConfigService.batchWrite([
        progressRow(
          'komga:server:first-page',
          '0',
          '2026-08-02T10:00:00.000000Z',
        ),
      ]);

      final ReadProgressEntry? entry = await service.getReadProgressEntryByKey(
        'komga:server:first-page',
      );
      expect(entry, isNotNull);
      expect(entry!.key, 'komga:server:first-page');
      expect(entry.pageIndex, 0);
      expect(entry.lastReadAt, DateTime.utc(2026, 8, 2, 10));
      expect(await service.getReadProgressByKey('komga:server:first-page'), 0);
    });

    test('loads multiple entries together and omits missing keys', () async {
      await localConfigService.batchWrite([
        progressRow('komga:server:book-1', '0', '2026-08-02T10:00:00.000000Z'),
        progressRow('komga:server:book-2', '18', '2026-08-02T11:00:00.000000Z'),
        progressRow('other-source', '7', '2026-08-02T12:00:00.000000Z'),
      ]);
      final ReadProgressService service = ReadProgressService();

      final Map<String, ReadProgressEntry> entries = await service
          .getReadProgressEntriesByKeys({
            'komga:server:book-1',
            'komga:server:book-2',
            'komga:server:missing',
          });

      expect(entries.keys, {'komga:server:book-1', 'komga:server:book-2'});
      expect(entries['komga:server:book-1']!.pageIndex, 0);
      expect(entries['komga:server:book-2']!.pageIndex, 18);
      expect(
        await service.getReadProgressEntryByKey('komga:server:missing'),
        isNull,
      );
    });

    test(
      'local update and delete notify both key-specific and global listeners',
      () async {
        const String key = 'komga:server:listener-book';
        final ReadProgressService service = ReadProgressService();
        int globalNotifications = 0;
        int keyNotifications = 0;
        final globalDisposer = service.addListener(() => globalNotifications++);
        final keyDisposer = service.addListenerId(
          '${ReadProgressService.readProgressUpdateId}::$key',
          () => keyNotifications++,
        );

        await service.updateReadProgress(key, 7);
        expect(globalNotifications, 1);
        expect(keyNotifications, 1);

        await service.deleteReadProgress(key);
        expect(globalNotifications, 2);
        expect(keyNotifications, 2);

        globalDisposer();
        keyDisposer();
      },
    );
  });

  test(
    'newer rows update utime even when the progress value is unchanged',
    () async {
      final LocalConfigService service = LocalConfigService();
      await service.batchWrite([
        progressRow('komga:server:book-1', '18', '2026-08-02T10:00:00.000Z'),
      ]);

      final int written = await service.batchWriteIfNewer(
        configKey: ConfigEnum.readIndexRecord,
        localConfigs: [
          progressRow('komga:server:book-1', '18', '2026-08-02T11:00:00.000Z'),
        ],
      );

      expect(written, 1);
      final LocalConfig? record = await service.readRecord(
        configKey: ConfigEnum.readIndexRecord,
        subConfigKey: 'komga:server:book-1',
      );
      expect(record, isNotNull);
      expect(record!.value, '18');
      expect(record.utime, '2026-08-02T11:00:00.000000Z');
    },
  );
}
