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

  group('ReadProgressService external progress import', () {
    test(
      'deduplicates, applies only newer rows, marks one pending batch, and notifies once',
      () async {
        await localConfigService.batchWrite([
          progressRow('local-older', '1', '2026-08-02T09:00:00.000000Z'),
          progressRow('local-newer', '9', '2026-08-02T12:00:00.000000Z'),
          progressRow('local-equal', '3', '2026-08-02T10:00:00.000000Z'),
        ]);
        final ReadProgressService service = ReadProgressService();

        // Prime a cached absence to prove that one final cache refresh makes
        // the newly imported row visible.
        expect(await service.getReadProgressEntryByKey('deduplicated'), isNull);
        int notificationCount = 0;
        final disposer = service.addListener(() => notificationCount++);

        final ReadProgressImportResult result = await service
            .importReadProgressEntries(<ReadProgressEntry>[
              ReadProgressEntry(
                key: 'deduplicated',
                pageIndex: 2,
                lastReadAt: _ImportTimes.earliest,
              ),
              ReadProgressEntry(
                key: 'deduplicated',
                pageIndex: 5,
                lastReadAt: _ImportTimes.latest,
              ),
              ReadProgressEntry(
                key: 'local-older',
                pageIndex: 7,
                lastReadAt: _ImportTimes.middle,
              ),
              ReadProgressEntry(
                key: 'local-newer',
                pageIndex: 4,
                lastReadAt: _ImportTimes.latest,
              ),
              ReadProgressEntry(
                key: 'local-equal',
                pageIndex: 8,
                lastReadAt: _ImportTimes.middle,
              ),
              ReadProgressEntry(
                key: '',
                pageIndex: 1,
                lastReadAt: _ImportTimes.latest,
              ),
              ReadProgressEntry(
                key: 'negative',
                pageIndex: -1,
                lastReadAt: _ImportTimes.latest,
              ),
            ]);

        expect(result.total, 4);
        expect(result.imported, 2);
        expect(result.skipped, 2);
        expect(result.invalid, 2);
        expect(result.isEmpty, isFalse);
        expect(result.isUpToDate, isFalse);
        expect(notificationCount, 1);

        final Map<String, ReadProgressEntry> stored = await service
            .getReadProgressEntriesByKeys(<String>{
              'deduplicated',
              'local-older',
              'local-newer',
              'local-equal',
            });
        expect(stored['deduplicated']!.pageIndex, 5);
        expect(stored['deduplicated']!.lastReadAt, _ImportTimes.latest);
        expect(stored['local-older']!.pageIndex, 7);
        expect(stored['local-newer']!.pageIndex, 9);
        expect(stored['local-equal']!.pageIndex, 3);

        final (_, Set<String> pendingKeys) = await pendingSyncTracker
            .snapshot();
        expect(pendingKeys, <String>{'deduplicated', 'local-older'});

        // markProgressPendingAll awaits its single persistence write, so a
        // fresh tracker can observe the complete batch immediately.
        final PendingSyncTracker reloadedTracker = PendingSyncTracker();
        final (_, Set<String> reloadedKeys) = await reloadedTracker.snapshot();
        expect(reloadedKeys, pendingKeys);

        disposer();
      },
    );

    test('reports up-to-date without marking pending or notifying', () async {
      await localConfigService.batchWrite([
        progressRow('already-current', '6', '2026-08-02T11:00:00.000000Z'),
      ]);
      final ReadProgressService service = ReadProgressService();
      int notificationCount = 0;
      final disposer = service.addListener(() => notificationCount++);

      final ReadProgressImportResult result = await service
          .importReadProgressEntries(<ReadProgressEntry>[
            ReadProgressEntry(
              key: 'already-current',
              pageIndex: 2,
              lastReadAt: _ImportTimes.middle,
            ),
          ]);

      expect(result.total, 1);
      expect(result.imported, 0);
      expect(result.skipped, 1);
      expect(result.invalid, 0);
      expect(result.isEmpty, isFalse);
      expect(result.isUpToDate, isTrue);
      expect(notificationCount, 0);
      final (_, Set<String> pendingKeys) = await pendingSyncTracker.snapshot();
      expect(pendingKeys, isEmpty);

      disposer();
    });

    test(
      'reports an empty import separately from an up-to-date import',
      () async {
        final ReadProgressImportResult result = await ReadProgressService()
            .importReadProgressEntries(<ReadProgressEntry>[
              ReadProgressEntry(
                key: ' ',
                pageIndex: 0,
                lastReadAt: _ImportTimes.middle,
              ),
            ]);

        expect(result.total, 0);
        expect(result.imported, 0);
        expect(result.skipped, 0);
        expect(result.invalid, 1);
        expect(result.isEmpty, isTrue);
        expect(result.isUpToDate, isFalse);
      },
    );
  });
}

abstract final class _ImportTimes {
  static final DateTime earliest = DateTime.utc(2026, 8, 2, 8);
  static final DateTime middle = DateTime.utc(2026, 8, 2, 10);
  static final DateTime latest = DateTime.utc(2026, 8, 2, 11);
}
