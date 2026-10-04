import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/service/komga_progress_sync_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';

import 'support/e2e_app.dart';
import 'support/local_komga.dart';

/// JHenTai progress sync against a real Komga. "Another client" (the Komga
/// web reader, Mihon, ...) is the same account writing through the API.
void main() {
  final KomgaE2eConfig? config = KomgaE2eConfig.load();
  if (config == null) {
    test('Komga progress e2e', () {}, skip: 'test/e2e/komga_e2e.json is absent');
    return;
  }

  late LocalKomga komga;
  late KomgaClient client;
  late E2eDevice device;
  late List<KomgaBook> alpha;
  late List<KomgaBook> beta;

  setUpAll(() async {
    log = SilentLogService();
    komga = await LocalKomga.start(config);
    client = e2eClient(komga);
    alpha = await seriesVolumes(client, TestLibrary.alpha);
    beta = await seriesVolumes(client, TestLibrary.beta);
  });

  tearDownAll(() async {
    await komga.stop();
  });

  setUp(() {
    device = E2eDevice()..activate();
  });

  tearDown(() async {
    await device.close();
    for (final KomgaBook book in <KomgaBook>[...alpha, ...beta]) {
      await client.deleteReadProgress(book.id);
    }
  });

  Future<void> anotherClientReads(KomgaBook book, int page) =>
      komga.api('PATCH', '/api/v1/books/${book.id}/read-progress', body: {'page': page});

  test('reading reports the page, and the last page completes the book', () async {
    final KomgaBook book = alpha[0];
    await readProgressService.updateReadProgress(client.progressRecordKey(book.id), 1);
    await komgaProgressSyncService.report(client, book, 1);
    expect((await serverProgress(client, book.id))!.page, 2);

    await readProgressService.updateReadProgress(client.progressRecordKey(book.id), book.pageCount - 1);
    await komgaProgressSyncService.report(client, book, book.pageCount - 1);
    final KomgaReadProgress done = (await serverProgress(client, book.id))!;
    expect(done.completed, isTrue);
    expect(done.page, book.pageCount);
    expect(await komgaProgressSyncService.pendingRecordKeys(), isEmpty);
  });

  test('opening a book starts at progress made elsewhere and keeps it', () async {
    final KomgaBook book = alpha[1];
    await readProgressService.updateReadProgress(client.progressRecordKey(book.id), 0);
    await komgaProgressSyncService.report(client, book, 0);

    await anotherClientReads(book, 3);
    final int start = await komgaProgressSyncService.reconcileBeforeOpen(client, book);

    expect(start, 2);
    expect(await localValue(client, book.id), '2');
    expect((await serverProgress(client, book.id))!.page, 3);
  });

  test('progress read offline is sent once the server is reachable', () async {
    final KomgaBook book = alpha[2];
    await readProgressService.updateReadProgress(client.progressRecordKey(book.id), 2);
    await komgaProgressSyncService.report(offlineClient(komga), book, 2);
    expect(await komgaProgressSyncService.pendingRecordKeys(), {client.progressRecordKey(book.id)});
    expect(await serverProgress(client, book.id), isNull);

    await komgaProgressSyncService.drainPending(client);

    expect((await serverProgress(client, book.id))!.page, 3);
    expect(await komgaProgressSyncService.pendingRecordKeys(), isEmpty);
  });

  test('a pending book does not overwrite newer progress from elsewhere', () async {
    final KomgaBook book = alpha[3];
    await readProgressService.updateReadProgress(client.progressRecordKey(book.id), 0);
    await komgaProgressSyncService.report(client, book, 0);
    // The book is re-queued while offline without new local reading.
    await komgaProgressSyncService.report(offlineClient(komga), book, 0);
    await anotherClientReads(book, 4);

    await komgaProgressSyncService.drainPending(client);

    expect((await serverProgress(client, book.id))!.page, 4);
    expect(await localValue(client, book.id), '3');
  });

  test('a second device reports progress the first could not send', () async {
    final KomgaBook book = beta[0];
    final String key = client.progressRecordKey(book.id);
    final E2eDevice a = device;
    final E2eDevice b = E2eDevice();
    try {
      a.activate();
      await readProgressService.updateReadProgress(key, 0);
      await komgaProgressSyncService.report(client, book, 0);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await readProgressService.updateReadProgress(key, 1);
      await komgaProgressSyncService.report(offlineClient(komga), book, 1);

      await cloudSyncRow(a, b, key);
      b.activate();
      await komgaProgressSyncService.reconcileBooks(client, <KomgaBook>[await client.getBook(book.id)]);
      expect((await serverProgress(client, book.id))!.page, 2);

      a.activate();
      await komgaProgressSyncService.drainPending(client);
      expect((await serverProgress(client, book.id))!.page, 2);
      expect(await komgaProgressSyncService.pendingRecordKeys(), isEmpty);
    } finally {
      await b.close();
      a.activate();
    }
  });

  test('a book marked unread elsewhere becomes unread here', () async {
    final KomgaBook book = beta[1];
    await readProgressService.updateReadProgress(client.progressRecordKey(book.id), 1);
    await komgaProgressSyncService.report(client, book, 1);

    await komga.api('DELETE', '/api/v1/books/${book.id}/read-progress');
    await komgaProgressSyncService.reconcileBooks(client, <KomgaBook>[await client.getBook(book.id)]);

    expect(await localValue(client, book.id), '');
    expect(await readProgressService.getReadProgressEntryByKey(client.progressRecordKey(book.id)), isNull);
  });

  test('marking a series unread is not undone by older local progress', () async {
    for (final KomgaBook book in beta) {
      await readProgressService.updateReadProgress(client.progressRecordKey(book.id), 1);
    }

    await komgaProgressSyncService.markSeries(client, beta[0].seriesId, read: false);
    await komgaProgressSyncService.reconcileBooks(
      client,
      await seriesVolumes(client, TestLibrary.beta),
    );

    for (final KomgaBook book in beta) {
      expect(await serverProgress(client, book.id), isNull, reason: book.title);
      expect(await localValue(client, book.id), '', reason: book.title);
    }
  });

  test('marking a book read or unread reaches the server', () async {
    final KomgaBook book = alpha[4];
    await komgaProgressSyncService.markBook(client, book, read: true);
    expect((await serverProgress(client, book.id))!.completed, isTrue);

    await komgaProgressSyncService.markBook(client, book, read: false);
    expect(await serverProgress(client, book.id), isNull);
    expect(await localValue(client, book.id), '');
  });

  test('a full sync pulls server progress and pushes local-only progress', () async {
    await anotherClientReads(alpha[0], 2);
    await readProgressService.updateReadProgress(client.progressRecordKey(beta[2].id), 1);

    final KomgaProgressSyncResult result = await komgaProgressSyncService.syncAll(client);

    expect(result.applied, 1);
    expect(result.pushed, 1);
    expect(await localValue(client, alpha[0].id), '1');
    expect((await serverProgress(client, beta[2].id))!.page, 2);
  });
}
