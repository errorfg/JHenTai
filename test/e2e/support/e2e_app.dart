import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/komga/komga_browse_models.dart';
import 'package:jhentai/src/model/komga/komga_models.dart';
import 'package:jhentai/src/model/komga/komga_query.dart';
import 'package:jhentai/src/network/komga_client.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/komga_progress_sync_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';

import 'local_komga.dart';

class SilentLogService extends LogService {
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

/// The app-side state of one device: its database and the services that
/// live on it. [activate] swaps the app's globals to this device.
class E2eDevice {
  E2eDevice() : db = AppDb.forTesting(NativeDatabase.memory());

  final AppDb db;
  final PendingSyncTracker tracker = PendingSyncTracker();
  final ReadProgressService progress = ReadProgressService();
  final KomgaProgressSyncService sync = KomgaProgressSyncService();

  void activate() {
    appDb = db;
    pendingSyncTracker = tracker;
    readProgressService = progress;
    komgaProgressSyncService = sync;
  }

  Future<void> close() => db.close();
}

KomgaClient e2eClient(LocalKomga komga) => KomgaClient(
  serverUrl: komga.serverUrl,
  username: '',
  password: '',
  apiKey: komga.apiKey,
  connectionId: 'e2e',
);

/// Same connection, unreachable server: a device without network.
KomgaClient offlineClient(LocalKomga komga) => KomgaClient(
  serverUrl: 'http://127.0.0.1:9',
  username: '',
  password: '',
  apiKey: komga.apiKey,
  connectionId: 'e2e',
);

Future<List<KomgaBook>> seriesVolumes(KomgaClient client, String title) async {
  final KomgaSeries series = (await client.listSeries(
    KomgaQuery(target: KomgaTarget.series, search: title, sortMode: KomgaSortMode.relevance),
    page: 0,
  )).content.firstWhere((KomgaSeries s) => s.title == title);
  return (await client.listBooks(
    KomgaQuery(
      target: KomgaTarget.books,
      seriesId: series.id,
      sortMode: KomgaSortMode.number,
      descending: false,
    ),
    page: 0,
    size: 100,
  )).content;
}

/// Local stored value ('' is the unread marker; null means no record).
Future<String?> localValue(KomgaClient client, String bookId) async {
  final String key = client.progressRecordKey(bookId);
  return (await readProgressService.getProgressRecords({key}))[key]?.value;
}

Future<KomgaReadProgress?> serverProgress(KomgaClient client, String bookId) async =>
    (await client.getBook(bookId)).readProgress;

/// Copy one progress row from [from] to [to], as JHenTai cloud sync does.
Future<void> cloudSyncRow(E2eDevice from, E2eDevice to, String key) async {
  from.activate();
  final ReadProgressRecord record =
      (await readProgressService.getProgressRecords({key}))[key]!;
  to.activate();
  await localConfigService.batchWrite([
    LocalConfigCompanion(
      configKey: Value(ConfigEnum.readIndexRecord.key),
      subConfigKey: Value(key),
      value: Value(record.value),
      utime: Value(record.utime),
    ),
  ]);
  readProgressService.clearCacheAndRefresh();
}
