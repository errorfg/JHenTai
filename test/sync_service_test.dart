import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/sync_setting.dart';

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

SyncResult _result({bool success = true}) => SyncResult(
  success: success,
  message: success ? 'ok' : 'failed',
  statistics: {},
);

void main() {
  late SyncSetting originalSyncSetting;
  late LogService originalLog;

  setUp(() {
    originalSyncSetting = syncSetting;
    syncSetting = SyncSetting()
      ..enableSync.value = true
      ..autoSync.value = true;
    originalLog = log;
    log = _SilentLogService();
  });

  tearDown(() {
    syncSetting = originalSyncSetting;
    log = originalLog;
  });

  test('read-progress sync respects enable and auto-sync settings', () async {
    int calls = 0;
    final SyncService service = SyncService(
      executeSync: ({required types, providerName, onProgress}) async {
        calls++;
        expect(types, const [CloudConfigTypeEnum.readIndexRecord]);
        return _result();
      },
    );

    syncSetting.enableSync.value = false;
    expect(await service.syncReadProgress(force: true), isNull);

    syncSetting.enableSync.value = true;
    syncSetting.autoSync.value = false;
    expect(await service.syncReadProgress(force: true), isNull);

    expect(
      await service.syncReadProgress(requireAutoSync: false, force: true),
      isNotNull,
    );
    expect(calls, 1);
  });

  test(
    'successful syncs cool non-forced progress syncs for five seconds',
    () async {
      DateTime now = DateTime.utc(2026, 8, 2, 12);
      int calls = 0;
      final SyncService service = SyncService(
        now: () => now,
        executeSync: ({required types, providerName, onProgress}) async {
          calls++;
          return _result();
        },
      );

      expect(await service.syncReadProgress(), isNotNull);
      expect(await service.syncReadProgress(), isNull);
      expect(calls, 1);

      expect(await service.syncReadProgress(force: true), isNotNull);
      expect(calls, 2);

      now = now.add(const Duration(seconds: 5));
      expect(await service.syncReadProgress(), isNotNull);
      expect(calls, 3);
    },
  );

  test(
    'failed progress sync does not start the successful-sync cooldown',
    () async {
      int calls = 0;
      final SyncService service = SyncService(
        executeSync: ({required types, providerName, onProgress}) async {
          calls++;
          return _result(success: calls != 1);
        },
      );

      expect((await service.syncReadProgress())!.success, isFalse);
      expect((await service.syncReadProgress())!.success, isTrue);
      expect(calls, 2);
    },
  );

  test(
    'any successful sync containing progress updates its cooldown',
    () async {
      int calls = 0;
      final SyncService service = SyncService(
        executeSync: ({required types, providerName, onProgress}) async {
          calls++;
          return _result();
        },
      );

      await service.sync(types: CloudConfigTypeEnum.values);

      expect(await service.syncReadProgress(), isNull);
      expect(calls, 1);
    },
  );

  test('resume within thirty seconds reconciles only read progress', () async {
    DateTime now = DateTime.utc(2026, 8, 2, 12);
    final List<List<CloudConfigTypeEnum>> calls = [];
    final SyncService service = SyncService(
      now: () => now,
      executeSync: ({required types, providerName, onProgress}) async {
        calls.add(List<CloudConfigTypeEnum>.of(types));
        return _result();
      },
    );

    await service.sync(types: CloudConfigTypeEnum.values);
    now = now.add(const Duration(seconds: 10));
    await service.performAutoSyncOnResume();

    expect(calls, [
      CloudConfigTypeEnum.values,
      const [CloudConfigTypeEnum.readIndexRecord],
    ]);
  });

  test(
    'failed full resume sync does not start the thirty-second cooldown',
    () async {
      final List<List<CloudConfigTypeEnum>> calls = [];
      final SyncService service = SyncService(
        executeSync: ({required types, providerName, onProgress}) async {
          calls.add(List<CloudConfigTypeEnum>.of(types));
          return _result(success: false);
        },
      );

      await service.performAutoSyncOnResume();
      await service.performAutoSyncOnResume();

      expect(calls.length, 2);
      expect(calls[0], CloudConfigTypeEnum.values);
      expect(calls[1], CloudConfigTypeEnum.values);
    },
  );

  test('busy resume queues one trailing read-progress sync', () async {
    final List<List<CloudConfigTypeEnum>> calls = [];
    final List<Completer<SyncResult>> completions = [];
    final SyncService service = SyncService(
      executeSync: ({required types, providerName, onProgress}) {
        calls.add(List<CloudConfigTypeEnum>.of(types));
        final Completer<SyncResult> completer = Completer<SyncResult>();
        completions.add(completer);
        return completer.future;
      },
    );

    final Future<SyncResult> active = service.sync(
      types: const [CloudConfigTypeEnum.quickSearch],
    );
    final Future<void> resumed = service.performAutoSyncOnResume();

    expect(calls, [
      const [CloudConfigTypeEnum.quickSearch],
    ]);

    completions.first.complete(_result());
    await active;
    await Future<void>.delayed(Duration.zero);

    expect(calls, [
      const [CloudConfigTypeEnum.quickSearch],
      const [CloudConfigTypeEnum.readIndexRecord],
    ]);

    completions[1].complete(_result());
    await resumed;
  });

  test('queued automatic request rechecks settings before it starts', () async {
    final List<List<CloudConfigTypeEnum>> calls = [];
    final List<Completer<SyncResult>> completions = [];
    final SyncService service = SyncService(
      executeSync: ({required types, providerName, onProgress}) {
        calls.add(List<CloudConfigTypeEnum>.of(types));
        final Completer<SyncResult> completer = Completer<SyncResult>();
        completions.add(completer);
        return completer.future;
      },
    );

    final Future<SyncResult> active = service.sync(
      types: const [CloudConfigTypeEnum.quickSearch],
    );
    final Future<SyncResult?> queued = service.syncReadProgress();
    syncSetting.autoSync.value = false;

    completions.first.complete(_result());
    await active;

    expect(await queued, isNull);
    expect(calls.length, 1);
  });

  test(
    'manual request keeps manual semantics when merged into the queue',
    () async {
      final List<List<CloudConfigTypeEnum>> calls = [];
      final List<Completer<SyncResult>> completions = [];
      final SyncService service = SyncService(
        executeSync: ({required types, providerName, onProgress}) {
          calls.add(List<CloudConfigTypeEnum>.of(types));
          final Completer<SyncResult> completer = Completer<SyncResult>();
          completions.add(completer);
          return completer.future;
        },
      );

      final Future<SyncResult> active = service.sync(
        types: const [CloudConfigTypeEnum.quickSearch],
      );
      final Future<SyncResult?> automatic = service.syncReadProgress();
      final Future<SyncResult?> manual = service.syncReadProgress(
        requireAutoSync: false,
      );
      syncSetting.autoSync.value = false;

      expect(identical(automatic, manual), isTrue);
      completions.first.complete(_result());
      await active;
      await Future<void>.delayed(Duration.zero);

      expect(calls.length, 2);
      expect(calls[1], const [CloudConfigTypeEnum.readIndexRecord]);

      completions[1].complete(_result());
      expect((await manual)!.success, isTrue);
      expect((await automatic)!.success, isTrue);
    },
  );

  test('busy progress requests merge into exactly one trailing sync', () async {
    final List<List<CloudConfigTypeEnum>> calls = [];
    final List<Completer<SyncResult>> completions = [];
    final SyncService service = SyncService(
      executeSync: ({required types, providerName, onProgress}) {
        calls.add(List<CloudConfigTypeEnum>.of(types));
        final Completer<SyncResult> completer = Completer<SyncResult>();
        completions.add(completer);
        return completer.future;
      },
    );

    final Future<SyncResult?> first = service.syncReadProgress(force: true);
    final Future<SyncResult?> trailingA = service.syncReadProgress(force: true);
    final Future<SyncResult?> trailingB = service.syncReadProgress(force: true);

    expect(calls, [
      const [CloudConfigTypeEnum.readIndexRecord],
    ]);
    expect(identical(trailingA, trailingB), isTrue);

    completions.first.complete(_result());
    await first;
    await Future<void>.delayed(Duration.zero);

    expect(calls, [
      const [CloudConfigTypeEnum.readIndexRecord],
      const [CloudConfigTypeEnum.readIndexRecord],
    ]);

    completions[1].complete(_result());
    expect((await trailingA)!.success, isTrue);
    expect((await trailingB)!.success, isTrue);
    expect(calls.length, 2);
  });

  test(
    'queued request runs after a successful full sync despite cooldown',
    () async {
      final List<List<CloudConfigTypeEnum>> calls = [];
      final List<Completer<SyncResult>> completions = [];
      final SyncService service = SyncService(
        executeSync: ({required types, providerName, onProgress}) {
          calls.add(List<CloudConfigTypeEnum>.of(types));
          final Completer<SyncResult> completer = Completer<SyncResult>();
          completions.add(completer);
          return completer.future;
        },
      );

      final Future<SyncResult> fullSync = service.sync(
        types: CloudConfigTypeEnum.values,
      );
      final Future<SyncResult?> queued = service.syncReadProgress();

      completions.first.complete(_result());
      await fullSync;
      await Future<void>.delayed(Duration.zero);

      expect(calls.length, 2);
      expect(calls[1], const [CloudConfigTypeEnum.readIndexRecord]);

      completions[1].complete(_result());
      expect((await queued)!.success, isTrue);
    },
  );

  test(
    'public sync keeps returning a busy result for concurrent callers',
    () async {
      final Completer<SyncResult> completion = Completer<SyncResult>();
      int calls = 0;
      final SyncService service = SyncService(
        executeSync: ({required types, providerName, onProgress}) {
          calls++;
          return completion.future;
        },
      );

      final Future<SyncResult> first = service.sync(
        types: const [CloudConfigTypeEnum.quickSearch],
      );
      final SyncResult concurrent = await service.sync(
        types: const [CloudConfigTypeEnum.quickSearch],
      );

      expect(concurrent.success, isFalse);
      expect(concurrent.message, 'Sync already in progress');
      expect(calls, 1);

      completion.complete(_result());
      expect((await first).success, isTrue);
    },
  );
}
