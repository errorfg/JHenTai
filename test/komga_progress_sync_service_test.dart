import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/komga_progress_sync_service.dart';
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

const int _pages = 20;

KomgaBook _book(String id, {int? page, bool completed = false, String? at}) =>
    KomgaBook.fromJson(<String, dynamic>{
      'id': id,
      'seriesId': 'series',
      'name': id,
      'media': <String, dynamic>{'status': 'READY', 'pagesCount': _pages},
      'metadata': <String, dynamic>{'title': id},
      if (page != null)
        'readProgress': <String, dynamic>{
          'page': page,
          'completed': completed,
          'readDate': at ?? '2026-01-01T00:00:00Z',
        },
    });

DioException _httpError(int status) {
  final RequestOptions options = RequestOptions(path: '/');
  return DioException(
    requestOptions: options,
    response: Response<dynamic>(requestOptions: options, statusCode: status),
    type: DioExceptionType.badResponse,
  );
}

DioException _networkError() => DioException(
  requestOptions: RequestOptions(path: '/'),
  type: DioExceptionType.connectionError,
);

/// In-memory Komga that applies progress writes the way the server does.
class _FakeKomga implements KomgaProgressRemote {
  _FakeKomga({this.connectionId = 'conn'});

  @override
  final String connectionId;

  final Map<String, KomgaBook> books = <String, KomgaBook>{};
  final List<String> calls = <String>[];
  Object? failure;

  void put(KomgaBook book) => books[book.id] = book;

  void _check() {
    if (failure != null) {
      throw failure!;
    }
  }

  @override
  String progressRecordKey(String bookId) => 'komga:$connectionId:$bookId';

  @override
  Future<KomgaBook> getBook(String bookId) async {
    calls.add('GET $bookId');
    _check();
    final KomgaBook? book = books[bookId];
    if (book == null) {
      throw _httpError(404);
    }
    return book;
  }

  @override
  Future<List<KomgaBook>> getAllReadProgressBooks() async {
    calls.add('LIST');
    _check();
    return books.values.where((KomgaBook b) => b.readProgress != null).toList();
  }

  @override
  Future<void> reportReadProgress(String bookId, int imageIndex) async {
    calls.add('PATCH $bookId ${imageIndex + 1}');
    _check();
    put(
      _book(
        bookId,
        page: imageIndex + 1,
        completed: imageIndex + 1 == _pages,
        at: '2026-10-04T06:00:00Z',
      ),
    );
  }

  @override
  Future<void> deleteReadProgress(String bookId) async {
    calls.add('DELETE $bookId');
    _check();
    put(_book(bookId));
  }
}

void main() {
  late PendingSyncTracker originalPendingSyncTracker;
  late _FakeKomga komga;
  late KomgaProgressSyncService service;

  setUp(() {
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
    originalPendingSyncTracker = pendingSyncTracker;
    pendingSyncTracker = PendingSyncTracker();
    readProgressService = ReadProgressService();
    komga = _FakeKomga();
    service = KomgaProgressSyncService();
  });

  tearDown(() async {
    pendingSyncTracker = originalPendingSyncTracker;
    await appDb.close();
  });

  Future<void> writeLocal(String bookId, String value, String utime) {
    return localConfigService.batchWrite([
      LocalConfigCompanion(
        configKey: const Value('readIndexRecord'),
        subConfigKey: Value('komga:conn:$bookId'),
        value: Value(value),
        utime: Value(utime),
      ),
    ]);
  }

  Future<String?> localValue(String bookId) async =>
      (await readProgressService.getProgressRecords({
        'komga:conn:$bookId',
      }))['komga:conn:$bookId']?.value;

  group('report', () {
    test('a successful report reaches the server and leaves nothing pending',
        () async {
      komga.put(_book('b1'));
      await readProgressService.updateReadProgress('komga:conn:b1', 4);

      await service.report(komga, _book('b1'), 4);

      expect(komga.calls, ['PATCH b1 5']);
      expect(await service.pendingRecordKeys(), isEmpty);
    });

    test('a failed report stays pending and is sent by the next drain',
        () async {
      komga.put(_book('b1'));
      await readProgressService.updateReadProgress('komga:conn:b1', 4);
      komga.failure = _networkError();

      await service.report(komga, _book('b1'), 4);
      expect(await service.pendingRecordKeys(), {'komga:conn:b1'});

      komga.failure = null;
      komga.calls.clear();
      await service.drainPending(komga);

      expect(komga.calls, ['GET b1', 'PATCH b1 5']);
      expect(await service.pendingRecordKeys(), isEmpty);
      expect(komga.books['b1']!.readProgress!.page, 5);
    });

    test('the last page is reported as completed', () async {
      komga.put(_book('b1'));
      await readProgressService.updateReadProgress('komga:conn:b1', 19);

      await service.report(komga, _book('b1'), 19);

      expect(komga.books['b1']!.readProgress!.completed, isTrue);
    });
  });

  group('drainPending', () {
    test('a server change made elsewhere is applied instead of overwritten',
        () async {
      komga.put(_book('b1'));
      await readProgressService.updateReadProgress('komga:conn:b1', 4);
      await service.report(komga, _book('b1'), 4);

      // Read further on another client, then a stale entry gets queued.
      komga.put(_book('b1', page: 15, at: '2026-10-04T07:00:00Z'));
      komga.failure = _networkError();
      await service.report(komga, _book('b1'), 4);
      komga.failure = null;
      komga.calls.clear();

      await service.drainPending(komga);

      expect(komga.calls, ['GET b1']);
      expect(await localValue('b1'), '14');
      expect(await service.pendingRecordKeys(), isEmpty);
    });

    test('a book removed from the server is dropped', () async {
      await readProgressService.updateReadProgress('komga:conn:gone', 3);
      komga.failure = _networkError();
      await service.report(komga, _book('gone'), 3);
      komga.failure = null;

      await service.drainPending(komga);

      expect(await service.pendingRecordKeys(), isEmpty);
    });

    test('an authentication failure stops the drain and keeps entries',
        () async {
      komga.put(_book('b1'));
      komga.put(_book('b2'));
      await readProgressService.updateReadProgress('komga:conn:b1', 1);
      await readProgressService.updateReadProgress('komga:conn:b2', 2);
      komga.failure = _networkError();
      await service.report(komga, _book('b1'), 1);
      await service.report(komga, _book('b2'), 2);

      komga.failure = _httpError(401);
      komga.calls.clear();
      await service.drainPending(komga);

      expect(komga.calls, hasLength(1));
      expect(await service.pendingRecordKeys(), {
        'komga:conn:b1',
        'komga:conn:b2',
      });
    });

    test('entries of another server connection are discarded', () async {
      final _FakeKomga other = _FakeKomga(connectionId: 'old');
      other.put(_book('b1'));
      await readProgressService.updateReadProgress('komga:old:b1', 1);
      other.failure = _networkError();
      await service.report(other, _book('b1'), 1);

      await service.drainPending(komga);

      expect(komga.calls, isEmpty);
      expect(await service.pendingRecordKeys(), isEmpty);
    });
  });

  group('reconcileBooks', () {
    test('first contact takes whichever side has progress', () async {
      await writeLocal('local-only', '6', '2026-10-01T00:00:00.000000Z');
      komga.put(_book('local-only'));
      komga.put(_book('server-only', page: 9));
      komga.put(_book('neither'));

      await service.reconcileBooks(komga, komga.books.values.toList());

      expect(await localValue('server-only'), '8');
      expect(komga.books['local-only']!.readProgress!.page, 7);
      expect(await localValue('neither'), isNull);
    });

    test('progress from another device is pushed when the server is unchanged',
        () async {
      komga.put(_book('b1', page: 5));
      await writeLocal('b1', '4', '2026-10-01T00:00:00.000000Z');
      await service.reconcileBooks(komga, komga.books.values.toList());
      komga.calls.clear();

      // Cloud sync delivers a newer row written by device A.
      await writeLocal('b1', '11', '2026-10-02T00:00:00.000000Z');
      await service.reconcileBooks(komga, komga.books.values.toList());

      expect(komga.calls, ['PATCH b1 12']);
    });

    test('a book marked unread on the server becomes unread locally', () async {
      komga.put(_book('b1', page: 5));
      await writeLocal('b1', '4', '2026-10-01T00:00:00.000000Z');
      await service.reconcileBooks(komga, komga.books.values.toList());

      komga.put(_book('b1'));
      await service.reconcileBooks(komga, komga.books.values.toList());

      expect(await localValue('b1'), '');
      expect(
        await readProgressService.getReadProgressEntryByKey('komga:conn:b1'),
        isNull,
      );
    });
  });

  group('reconcileBeforeOpen', () {
    test('opens at newer server progress', () async {
      await writeLocal('b1', '0', '2026-01-01T00:00:00.000000Z');
      komga.put(_book('b1', page: 20, completed: true, at: '2026-10-04T05:00:00Z'));

      expect(await service.reconcileBeforeOpen(komga, _book('b1')), 19);
      expect(komga.calls, ['GET b1']);
    });

    test('falls back to local progress when the server is unreachable',
        () async {
      await writeLocal('b1', '6', '2026-01-01T00:00:00.000000Z');
      komga.failure = _networkError();

      expect(await service.reconcileBeforeOpen(komga, _book('b1')), 6);
    });
  });

  test('syncAll covers server progress and local-only progress', () async {
    komga.put(_book('server', page: 3));
    komga.put(_book('local'));
    await writeLocal('local', '8', '2026-10-01T00:00:00.000000Z');
    await writeLocal('deleted', '1', '2026-10-01T00:00:00.000000Z');
    await readProgressService.updateReadProgress('123456', 1);
    await readProgressService.updateReadProgress('komga:old:x', 1);

    final KomgaProgressSyncResult result = await service.syncAll(komga);

    expect(result.applied, 1);
    expect(result.pushed, 1);
    expect(
      komga.calls.where((String call) => call.startsWith('GET')).toSet(),
      {'GET local', 'GET deleted'},
    );
    expect(await localValue('server'), '2');
    expect(komga.books['local']!.readProgress!.page, 9);
  });
}
