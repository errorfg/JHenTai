import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/pages/read/read_page_logic.dart';

void main() {
  test('final local write does not wait for a slow remote reporter', () async {
    final List<int> persisted = <int>[];
    final List<int> reported = <int>[];
    final Completer<void> firstReportStarted = Completer<void>();
    final Completer<void> releaseFirstReport = Completer<void>();

    final ReadProgressFlushCoordinator coordinator =
        ReadProgressFlushCoordinator(
          persist: (int imageIndex) async {
            persisted.add(imageIndex);
          },
          report: (int imageIndex) async {
            reported.add(imageIndex);
            if (imageIndex == 1) {
              firstReportStarted.complete();
              await releaseFirstReport.future;
            }
          },
        );

    await coordinator.schedule(1);
    await firstReportStarted.future;

    await coordinator.schedule(2);
    await coordinator.schedule(3);

    expect(persisted, <int>[1, 2, 3]);
    expect(reported, <int>[1]);

    releaseFirstReport.complete();
    await coordinator.waitForRemoteReports();

    expect(reported, <int>[1, 3]);
  });

  test(
    'returned future completes after its local write in queue order',
    () async {
      final List<int> writesStarted = <int>[];
      final Completer<void> releaseFirstWrite = Completer<void>();

      final ReadProgressFlushCoordinator coordinator =
          ReadProgressFlushCoordinator(
            persist: (int imageIndex) async {
              writesStarted.add(imageIndex);
              if (imageIndex == 4) {
                await releaseFirstWrite.future;
              }
            },
          );

      final Future<void> first = coordinator.schedule(4);
      final Future<void> finalWrite = coordinator.schedule(9);
      bool finalWriteCompleted = false;
      finalWrite.then((_) => finalWriteCompleted = true);

      await Future<void>.delayed(Duration.zero);
      expect(writesStarted, <int>[4]);
      expect(finalWriteCompleted, isFalse);

      releaseFirstWrite.complete();
      await first;
      await finalWrite;

      expect(writesStarted, <int>[4, 9]);
      expect(finalWriteCompleted, isTrue);
    },
  );

  test('report failures never fail or stall later local writes', () async {
    final List<int> persisted = <int>[];
    final List<int> reportAttempts = <int>[];
    final List<Object> reportErrors = <Object>[];

    final ReadProgressFlushCoordinator coordinator =
        ReadProgressFlushCoordinator(
          persist: (int imageIndex) async {
            persisted.add(imageIndex);
          },
          report: (int imageIndex) async {
            reportAttempts.add(imageIndex);
            if (imageIndex == 5) {
              throw StateError('offline');
            }
          },
          onReportError: (Object error, StackTrace _) {
            reportErrors.add(error);
          },
        );

    await coordinator.schedule(5);
    await coordinator.waitForRemoteReports();
    await coordinator.schedule(8);
    await coordinator.waitForRemoteReports();

    expect(persisted, <int>[5, 8]);
    expect(reportAttempts, <int>[5, 8]);
    expect(reportErrors, hasLength(1));
  });

  test(
    'a failed local write is reported and the queue remains usable',
    () async {
      final List<int> persisted = <int>[];
      final List<Object> persistErrors = <Object>[];

      final ReadProgressFlushCoordinator coordinator =
          ReadProgressFlushCoordinator(
            persist: (int imageIndex) async {
              if (imageIndex == 2) {
                throw StateError('database unavailable');
              }
              persisted.add(imageIndex);
            },
            onPersistError: (Object error, StackTrace _) {
              persistErrors.add(error);
            },
          );

      await expectLater(coordinator.schedule(2), throwsStateError);
      await coordinator.schedule(6);

      expect(persisted, <int>[6]);
      expect(persistErrors, hasLength(1));
    },
  );

  test('final sync waits until the final index is persisted', () async {
    final Completer<void> persistStarted = Completer<void>();
    final Completer<void> releasePersist = Completer<void>();
    final List<String> events = <String>[];
    bool syncCalled = false;

    final ReadProgressFlushCoordinator coordinator =
        ReadProgressFlushCoordinator(
          persist: (int imageIndex) async {
            expect(imageIndex, 12);
            events.add('persist-start');
            persistStarted.complete();
            await releasePersist.future;
            events.add('persist-end');
          },
        );

    final Future<void> flush = coordinator.flushFinalAndSync(
      12,
      sync: () async {
        syncCalled = true;
        events.add('sync');
      },
    );

    await persistStarted.future;
    expect(syncCalled, isFalse);
    expect(events, <String>['persist-start']);

    releasePersist.complete();
    await flush;

    expect(syncCalled, isTrue);
    expect(events, <String>['persist-start', 'persist-end', 'sync']);
  });

  test('final sync is skipped when final persistence fails', () async {
    bool syncCalled = false;

    final ReadProgressFlushCoordinator coordinator =
        ReadProgressFlushCoordinator(
          persist: (int _) async {
            throw StateError('database unavailable');
          },
        );

    await expectLater(
      coordinator.flushFinalAndSync(
        13,
        sync: () async {
          syncCalled = true;
        },
      ),
      throwsStateError,
    );

    expect(syncCalled, isFalse);
  });
}
