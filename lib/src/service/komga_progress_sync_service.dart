import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' as drift show Value;
import 'package:flutter/widgets.dart';
import 'package:jhentai/src/database/database.dart' show LocalConfigCompanion;
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/komga/komga_progress_state.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/setting/komga_setting.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';
import 'package:jhentai/src/widget/app_manager.dart';

KomgaProgressSyncService komgaProgressSyncService = KomgaProgressSyncService();

/// Counts reported by [KomgaProgressSyncService.syncAll].
class KomgaProgressSyncResult {
  const KomgaProgressSyncResult({required this.applied, required this.pushed});

  /// Books whose local progress was replaced by the server's.
  final int applied;

  /// Books whose local progress was sent to the server.
  final int pushed;
}

class _BookState {
  _BookState({required this.book, required this.server});

  final KomgaBook book;
  final KomgaServerProgress server;
}

/// Two-way read-progress sync between JHenTai and Komga.
///
/// Each book is reconciled against a per-device base, the last state both
/// sides agreed on (see `resolveKomgaProgress`). Books whose local progress
/// still has to reach the server are kept in a pending list that survives
/// restarts; every pending book is re-checked against the server before it is
/// sent, so a stale entry never overwrites newer server progress.
///
/// All operations run one at a time.
class KomgaProgressSyncService
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  /// Completion of the most recent queued operation; null until the first
  /// one, so no future is created ahead of the caller's zone.
  Future<void>? _tail;

  @override
  List<JHLifeCircleBean> get initDependencies => super.initDependencies
    ..addAll([localConfigService, readProgressService, komgaSetting]);

  @override
  Future<void> doInitBean() async {}

  @override
  Future<void> doAfterBeanReady() async {
    AppManager.registerDidChangeAppLifecycleStateCallback((
      AppLifecycleState state,
    ) {
      if (state == AppLifecycleState.resumed) {
        unawaited(drainPendingFromSetting());
      }
    });
    unawaited(drainPendingFromSetting());
  }

  /// Drain with the configured server, if there is anything to drain.
  Future<void> drainPendingFromSetting() async {
    if (!komgaSetting.isConfigured || (await pendingRecordKeys()).isEmpty) {
      return;
    }
    try {
      await drainPending(KomgaClient.fromSetting());
    } catch (e) {
      log.warning('Komga pending progress drain failed', e);
    }
  }

  Future<Set<String>> pendingRecordKeys() async {
    final List<LocalConfig> records = await localConfigService
        .readWithAllSubKeys(configKey: ConfigEnum.komgaProgressPending);
    return records.map((LocalConfig record) => record.subConfigKey).toSet();
  }

  /// Reconcile books from a list response using the progress it carries.
  Future<void> reconcileBooks(
    KomgaProgressRemote remote,
    List<KomgaBook> books,
  ) {
    return _serialized(() async {
      await _reconcile(remote, <_BookState>[
        for (final KomgaBook book in books)
          _BookState(book: book, server: KomgaServerProgress.fromBook(book)),
      ]);
    });
  }

  /// Fetch the book's current server state, reconcile it, and return the page
  /// index to open at. Falls back to local progress when the server cannot be
  /// reached.
  Future<int> reconcileBeforeOpen(KomgaProgressRemote remote, KomgaBook book) {
    return _serialized(() async {
      try {
        final KomgaBook fresh = await remote.getBook(book.id);
        await _reconcile(remote, <_BookState>[
          _BookState(book: fresh, server: KomgaServerProgress.fromBook(fresh)),
        ]);
      } catch (e) {
        log.warning('Komga progress check before opening failed', e);
      }
      final ReadProgressEntry? entry = await readProgressService
          .getReadProgressEntryByKey(remote.progressRecordKey(book.id));
      final int lastIndex = book.pageCount > 0 ? book.pageCount - 1 : 0;
      return (entry?.pageIndex ?? 0).clamp(0, lastIndex);
    });
  }

  /// Send progress the reader has just persisted locally. The book is marked
  /// pending first, so a failed or interrupted send is retried later.
  Future<void> report(
    KomgaProgressRemote remote,
    KomgaBook book,
    int imageIndex,
  ) {
    return _serialized(() async {
      final String key = remote.progressRecordKey(book.id);
      await _markPending(remote, book.id);
      final ReadProgressRecord? record = (await readProgressService
          .getProgressRecords({key}))[key];
      final KomgaLocalProgress local = record == null
          ? KomgaLocalProgress(
              value: imageIndex.toString(),
              utime: SyncTimeUtil.nowIso(),
            )
          : KomgaLocalProgress(value: record.value, utime: record.utime);
      try {
        await _push(remote, book, local);
      } catch (e) {
        if (_isNotFound(e)) {
          await _forget(key);
        } else {
          log.warning('Komga progress report failed; kept pending', e);
        }
      }
    });
  }

  /// Re-check and send every pending book of [remote]'s connection. Stops at
  /// the first authentication or network failure, keeping the remaining
  /// entries.
  Future<void> drainPending(KomgaProgressRemote remote) {
    return _serialized(() async {
      final List<LocalConfig> records = await localConfigService
          .readWithAllSubKeys(configKey: ConfigEnum.komgaProgressPending);
      for (final LocalConfig record in records) {
        final Map<String, dynamic> entry = (jsonDecode(record.value) as Map)
            .cast<String, dynamic>();
        if (entry['connectionId'] != remote.connectionId) {
          await _clearPending(record.subConfigKey);
          continue;
        }
        final String bookId = entry['bookId'] as String;
        try {
          final KomgaBook book = await remote.getBook(bookId);
          await _reconcile(remote, <_BookState>[
            _BookState(book: book, server: KomgaServerProgress.fromBook(book)),
          ], rethrowPushErrors: true);
          await _clearPending(record.subConfigKey);
        } catch (e) {
          if (_isNotFound(e)) {
            await _forget(record.subConfigKey);
            continue;
          }
          log.warning('Komga pending progress drain stopped', e);
          return;
        }
      }
    });
  }

  /// Full check: every book with server progress, plus every local record of
  /// this connection that the server lists as unread.
  Future<KomgaProgressSyncResult> syncAll(KomgaProgressRemote remote) {
    return _serialized(() async {
      final List<KomgaBook> serverBooks = await remote
          .getAllReadProgressBooks();
      final Set<String> serverKeys = serverBooks
          .map((KomgaBook book) => remote.progressRecordKey(book.id))
          .toSet();
      final String prefix = remote.progressRecordKey('');

      final List<_BookState> states = <_BookState>[
        for (final KomgaBook book in serverBooks)
          _BookState(book: book, server: KomgaServerProgress.fromBook(book)),
      ];
      final List<LocalConfig> localRecords = await localConfigService
          .readWithAllSubKeys(configKey: ConfigEnum.readIndexRecord);
      for (final LocalConfig record in localRecords) {
        if (!record.subConfigKey.startsWith(prefix) ||
            record.value.isEmpty ||
            serverKeys.contains(record.subConfigKey)) {
          continue;
        }
        try {
          final KomgaBook book = await remote.getBook(
            record.subConfigKey.substring(prefix.length),
          );
          states.add(
            _BookState(book: book, server: KomgaServerProgress.fromBook(book)),
          );
        } catch (e) {
          if (!_isNotFound(e)) {
            rethrow;
          }
        }
      }
      return _reconcile(remote, states);
    });
  }

  Future<KomgaProgressSyncResult> _reconcile(
    KomgaProgressRemote remote,
    List<_BookState> states, {
    bool rethrowPushErrors = false,
  }) async {
    if (states.isEmpty) {
      return const KomgaProgressSyncResult(applied: 0, pushed: 0);
    }
    final Map<String, _BookState> byKey = <String, _BookState>{
      for (final _BookState state in states)
        remote.progressRecordKey(state.book.id): state,
    };
    final Map<String, ReadProgressRecord> locals = await readProgressService
        .getProgressRecords(byKey.keys.toSet());
    final Map<String, KomgaProgressBase> bases = await _readBases(
      byKey.keys.toSet(),
    );

    final Map<String, String> toApply = <String, String>{};
    final Map<String, KomgaProgressBase> newBases =
        <String, KomgaProgressBase>{};
    final List<MapEntry<_BookState, KomgaLocalProgress>> toPush =
        <MapEntry<_BookState, KomgaLocalProgress>>[];

    for (final MapEntry<String, _BookState> entry in byKey.entries) {
      final _BookState state = entry.value;
      final ReadProgressRecord? record = locals[entry.key];
      final KomgaLocalProgress? local = record == null
          ? null
          : KomgaLocalProgress(value: record.value, utime: record.utime);
      switch (resolveKomgaProgress(
        server: state.server,
        local: local,
        base: bases[entry.key],
        pageCount: state.book.pageCount,
      )) {
        case KomgaProgressAction.none:
          break;
        case KomgaProgressAction.updateBaseOnly:
          newBases[entry.key] = KomgaProgressBase.agreed(
            server: state.server,
            local: local,
          );
        case KomgaProgressAction.applyServer:
          toApply[entry.key] = state.server.toLocalValue(state.book.pageCount);
        case KomgaProgressAction.pushLocal:
          toPush.add(MapEntry(state, local!));
      }
    }

    final Map<String, ReadProgressRecord> applied = await readProgressService
        .writeProgressValues(toApply);
    for (final MapEntry<String, ReadProgressRecord> entry in applied.entries) {
      newBases[entry.key] = KomgaProgressBase.agreed(
        server: byKey[entry.key]!.server,
        local: KomgaLocalProgress(
          value: entry.value.value,
          utime: entry.value.utime,
        ),
      );
    }
    await _writeBases(newBases);

    int pushed = 0;
    for (final MapEntry<_BookState, KomgaLocalProgress> entry in toPush) {
      final KomgaBook book = entry.key.book;
      await _markPending(remote, book.id);
      try {
        await _push(remote, book, entry.value);
        pushed++;
      } catch (e) {
        if (_isNotFound(e)) {
          await _forget(remote.progressRecordKey(book.id));
          continue;
        }
        if (rethrowPushErrors) {
          rethrow;
        }
        log.warning('Komga progress push failed; kept pending', e);
      }
    }
    return KomgaProgressSyncResult(applied: applied.length, pushed: pushed);
  }

  /// Send [local] to the server, then record the agreed base and clear the
  /// pending mark.
  Future<void> _push(
    KomgaProgressRemote remote,
    KomgaBook book,
    KomgaLocalProgress local,
  ) async {
    final String value = normalizeKomgaLocalValue(local.value, book.pageCount);
    if (value.isEmpty) {
      await remote.deleteReadProgress(book.id);
    } else {
      await remote.reportReadProgress(book.id, int.parse(value));
    }
    final String key = remote.progressRecordKey(book.id);
    await _writeBases(<String, KomgaProgressBase>{
      key: KomgaProgressBase.agreed(
        server: KomgaServerProgress.afterPush(value, book.pageCount),
        local: local,
      ),
    });
    await _clearPending(key);
  }

  Future<Map<String, KomgaProgressBase>> _readBases(Set<String> keys) async {
    final List<LocalConfig> records = await localConfigService.readBySubKeys(
      configKey: ConfigEnum.komgaProgressBase,
      subConfigKeys: keys,
    );
    return <String, KomgaProgressBase>{
      for (final LocalConfig record in records)
        record.subConfigKey: KomgaProgressBase.fromJson(
          (jsonDecode(record.value) as Map).cast<String, dynamic>(),
        ),
    };
  }

  Future<void> _writeBases(Map<String, KomgaProgressBase> bases) async {
    if (bases.isEmpty) {
      return;
    }
    final String utime = SyncTimeUtil.nowIso();
    await localConfigService.batchWrite(
      bases.entries
          .map(
            (MapEntry<String, KomgaProgressBase> entry) => LocalConfigCompanion(
              configKey: drift.Value(ConfigEnum.komgaProgressBase.key),
              subConfigKey: drift.Value(entry.key),
              value: drift.Value(jsonEncode(entry.value.toJson())),
              utime: drift.Value(utime),
            ),
          )
          .toList(growable: false),
    );
  }

  Future<void> _markPending(KomgaProgressRemote remote, String bookId) {
    return localConfigService.write(
      configKey: ConfigEnum.komgaProgressPending,
      subConfigKey: remote.progressRecordKey(bookId),
      value: jsonEncode(<String, String>{
        'connectionId': remote.connectionId,
        'bookId': bookId,
      }),
    );
  }

  Future<void> _clearPending(String key) {
    return localConfigService.delete(
      configKey: ConfigEnum.komgaProgressPending,
      subConfigKey: key,
    );
  }

  /// The book no longer exists on the server.
  Future<void> _forget(String key) async {
    await _clearPending(key);
    await localConfigService.delete(
      configKey: ConfigEnum.komgaProgressBase,
      subConfigKey: key,
    );
  }

  static bool _isNotFound(Object error) =>
      error is DioException && error.response?.statusCode == 404;

  Future<T> _serialized<T>(Future<T> Function() operation) async {
    final Future<void>? previous = _tail;
    final Completer<void> done = Completer<void>();
    _tail = done.future;
    try {
      if (previous != null) {
        await previous;
      }
      return await operation();
    } finally {
      done.complete();
    }
  }
}
