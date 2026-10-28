import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';

import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

import 'record_backend.dart';

/// What records/v1/manifest.json of a bucket says.
class BucketManifest {
  const BucketManifest({required this.database, this.snapshot, this.coverage, this.legacyDevice, this.legacyAt});

  /// Made with the layout; a new one (the folder emptied) has every device
  /// push all its records again, as for a sync server's new database.
  final String database;

  /// The snapshot a device new to the records starts from.
  final String? snapshot;

  /// The last pack of each device [snapshot] holds; null in a manifest
  /// written before it was kept here.
  final Map<String, String>? coverage;

  /// The device that took over what versions up to 8.1.1 synced in the
  /// bucket (latest.json and the op packs), and when; null until one has.
  final String? legacyDevice;
  final String? legacyAt;

  factory BucketManifest.fromJson(Map<String, dynamic> json) => BucketManifest(
        database: json['database'] as String,
        snapshot: json['snapshot'] as String?,
        coverage: (json['coverage'] as Map?)?.cast<String, String>(),
        legacyDevice: (json['legacy'] as Map?)?['device'] as String?,
        legacyAt: (json['legacy'] as Map?)?['at'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'format': BucketRecordBackend.format,
        'database': database,
        'snapshot': snapshot,
        if (coverage != null) 'coverage': coverage,
        'legacy': legacyDevice == null ? null : <String, dynamic>{'device': legacyDevice, 'at': legacyAt},
      };
}

/// A pack of records as a key in the bucket:
/// records/v1/packs/<device>/<seq>.json.gz.
class _PackKey {
  const _PackKey(this.key, this.device, this.seq, this.modified);

  final String key;
  final String device;
  final String seq;
  final DateTime? modified;

  static final RegExp _pattern = RegExp(r'^records/v1/packs/([a-z0-9]+)/(\d{17})\.json\.gz$');

  static _PackKey? tryParse(RemoteObjectInfo info) {
    final Match? match = _pattern.firstMatch(info.key);
    return match == null ? null : _PackKey(info.key, match.group(1)!, match.group(2)!, info.modifiedTime);
  }
}

class _Snapshot {
  const _Snapshot(this.records, this.coverage);

  final List<RemoteRecord> records;

  /// The last pack of each device it holds.
  final Map<String, String> coverage;
}

/// Where a pull goes on from: the snapshot taken, the last pack taken of
/// each device, and a snapshot being taken part way.
class _Cursor {
  _Cursor({this.snapshot, Map<String, String>? packs, this.taking, this.offset = 0}) : packs = packs ?? <String, String>{};

  String? snapshot;
  final Map<String, String> packs;
  String? taking;
  int offset;

  factory _Cursor.parse(String value) {
    if (value.isEmpty) {
      return _Cursor();
    }
    final Map<String, dynamic> json = jsonDecode(value) as Map<String, dynamic>;
    return _Cursor(
      snapshot: json['snapshot'] as String?,
      packs: (json['packs'] as Map? ?? const <String, dynamic>{}).cast<String, String>(),
      taking: json['taking'] as String?,
      offset: json['offset'] as int? ?? 0,
    );
  }

  String encode() => jsonEncode(<String, dynamic>{
        'snapshot': snapshot,
        'packs': packs,
        if (taking != null) 'taking': taking,
        if (taking != null) 'offset': offset,
      });
}

/// The records of [RecordSyncEngine] kept in a bucket (S3, WebDAV) the way
/// a sync server keeps them: for each (kind, key) the version with the
/// larger (updatedAt, device) wins, deletions included. Versions up to
/// 8.1.1 synced the bucket otherwise (latest.json and the op packs of
/// history and progress); what they wrote is taken over once (see
/// [BucketManifest.legacyDevice]) and never written again.
///
/// Layout, under records/v1/ of the sync root, where versions up to 8.1.1
/// do not look, nor clean up:
///   manifest.json                     see [BucketManifest]
///   packs/<device>/<seq>.json.gz      the records a device pushed at once
///   snapshots/<seq>-<device>.json.gz  the winning version of every record,
///                                     and the last pack of each device it
///                                     holds
///   backups/<yyyyMMddHHmmss>.json     history versions of the settings
///
/// A device writes only its own packs, so two devices syncing at once do
/// not overwrite each other. Once there are more than [compactAfter] packs,
/// a device writes a snapshot of all records and removes the packs it holds
/// that were uploaded over [packRetention] ago: any snapshot written since
/// holds them, so two devices compacting at once lose nothing, and a device
/// that has not synced for longer starts from the snapshot.
class BucketRecordBackend implements RecordBackend {
  BucketRecordBackend(this._provider, {required this.device, this.compactAfter = 200, DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const String root = 'records/v1/';
  static const String manifestKey = '${root}manifest.json';
  static const String packsPrefix = '${root}packs/';
  static const String snapshotsPrefix = '${root}snapshots/';
  static const String backupsPrefix = '${root}backups/';
  static const int format = 1;

  /// Packs there may be before they are compacted.
  final int compactAfter;

  /// Records, and bytes of their values, a pack holds at most: a request
  /// to a bucket takes much longer than one to a sync server.
  static const int packRecords = 2000;
  static const int packBytes = 4 * 1024 * 1024;

  /// Packs downloaded ahead of the one taken.
  static const int downloadAhead = 4;
  static const Duration packRetention = Duration(days: 7);
  static const int snapshotsToKeep = 2;

  final CloudProvider _provider;

  /// This device: its packs, which it does not pull.
  final String device;
  final DateTime Function() _now;

  BucketManifest? _manifest;
  List<_PackKey>? _packs;
  final Map<String, Future<List<int>?>> _downloads = <String, Future<List<int>?>>{};
  final Map<String, _Snapshot> _snapshots = <String, _Snapshot>{};

  /// The manifest, made with a new layout when there is none. One that can
  /// not be read fails the sync: a new one would have every device push all
  /// its records again.
  Future<BucketManifest> manifest() async {
    BucketManifest? manifest = _manifest ?? await _readManifest();
    if (manifest == null) {
      final Random random = Random.secure();
      manifest = BucketManifest(database: List<String>.generate(16, (_) => random.nextInt(16).toRadixString(16)).join());
      await _writeManifest(manifest);
      log.info('🗄 Bucket records: new layout, database ${manifest.database}');
    }
    return _manifest = manifest;
  }

  Future<BucketManifest?> _readManifest() async {
    final List<int>? bytes = await _provider.getRawObject(manifestKey);
    return bytes == null ? null : BucketManifest.fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
  }

  Future<void> _writeManifest(BucketManifest manifest) => _provider.putRawObject(manifestKey, utf8.encode(jsonEncode(manifest.toJson())));

  /// Notes that this device took over what earlier versions synced, unless
  /// another one did meanwhile.
  Future<void> markLegacyTaken() async {
    final BucketManifest current = await _readManifest() ?? await manifest();
    if (current.legacyDevice != null) {
      _manifest = current;
      return;
    }
    _manifest = BucketManifest(
      database: current.database,
      snapshot: current.snapshot,
      coverage: current.coverage,
      legacyDevice: device,
      legacyAt: SyncTimeUtil.nowIso(),
    );
    await _writeManifest(_manifest!);
  }

  @override
  Future<RecordServerInfo> info() async => RecordServerInfo(protocol: 1, database: (await manifest()).database);

  @override
  Future<void> push(List<RemoteRecord> records) async {
    if (records.isEmpty) {
      return;
    }
    final String seq = await _nextSeq();
    final List<int> bytes = await _encode(<String, dynamic>{
      'format': format,
      'device': device,
      'records': records.map((RemoteRecord r) => r.toJson()).toList(),
    });
    await _provider.putRawObject('$packsPrefix$device/$seq.json.gz', bytes);
    await localConfigService.write(configKey: ConfigEnum.recordPackLastKey, value: seq);
    _packs = null;
  }

  /// A snapshot newer than the one taken comes first, a page at a time,
  /// unless every pack it holds that this device lacks is still there;
  /// then the packs of other devices after the last taken of each, whole.
  @override
  Future<RecordPage> pull({required String since, required String device, required int limit}) async {
    final _Cursor cursor = _Cursor.parse(since);
    final BucketManifest manifest = await this.manifest();
    String? taking = cursor.taking;
    if (taking == null && manifest.snapshot != null && (cursor.snapshot == null || manifest.snapshot!.compareTo(cursor.snapshot!) > 0)) {
      if (await _packsLeftFor(manifest.coverage, cursor, device)) {
        cursor.snapshot = manifest.snapshot;
      } else {
        taking = manifest.snapshot;
      }
    }
    if (taking != null) {
      _Snapshot? snapshot = await _snapshot(taking);
      if (snapshot == null && manifest.snapshot != null && manifest.snapshot != taking) {
        // Removed by compactions while this device was part way through it:
        // the newest is taken instead, from its start.
        taking = manifest.snapshot!;
        cursor.offset = 0;
        snapshot = await _snapshot(taking);
      }
      if (snapshot == null) {
        throw StateError('Snapshot $taking of the bucket records is missing');
      }
      final int end = min(cursor.offset + limit, snapshot.records.length);
      final List<RemoteRecord> records = snapshot.records.sublist(min(cursor.offset, end), end);
      if (end < snapshot.records.length) {
        cursor
          ..taking = taking
          ..offset = end;
      } else {
        cursor
          ..snapshot = taking
          ..taking = null
          ..offset = 0;
        snapshot.coverage.forEach((String device, String seq) {
          if (seq.compareTo(cursor.packs[device] ?? '') > 0) {
            cursor.packs[device] = seq;
          }
        });
      }
      return RecordPage(records: records, next: cursor.encode(), more: true);
    }

    final List<_PackKey> pending = (_packs ??= await _listPacks())
        .where((_PackKey p) => p.device != device && p.seq.compareTo(cursor.packs[p.device] ?? '') > 0)
        .toList()
      ..sort((_PackKey a, _PackKey b) => a.seq != b.seq ? a.seq.compareTo(b.seq) : a.device.compareTo(b.device));
    final List<RemoteRecord> records = <RemoteRecord>[];
    int taken = 0;
    for (final _PackKey pack in pending) {
      if (records.isNotEmpty && records.length >= limit) {
        break;
      }
      for (final _PackKey next in pending.skip(taken).take(downloadAhead)) {
        // A failure is met when the pack is taken.
        _downloads.putIfAbsent(next.key, () => _provider.getRawObject(next.key)..ignore());
      }
      final List<int>? bytes = await _downloads.remove(pack.key);
      if (bytes == null) {
        // Removed by a compaction since the listing: its snapshot is taken next time.
        throw StateError('Pack ${pack.key} of the bucket records is gone');
      }
      records.addAll(_records(await _decode(bytes)));
      cursor.packs[pack.device] = pack.seq;
      taken++;
    }
    return RecordPage(records: records, next: cursor.encode(), more: taken < pending.length);
  }

  /// Whether this device can go without the snapshot of [coverage] and take
  /// packs only: for each other device with packs in it after the last one
  /// taken here, that one is still in the bucket. Packs are removed oldest
  /// first, so then none after it was.
  Future<bool> _packsLeftFor(Map<String, String>? coverage, _Cursor cursor, String device) async {
    if (coverage == null) {
      return false;
    }
    final Set<String> listed = <String>{for (final _PackKey pack in _packs ??= await _listPacks()) pack.key};
    for (final MapEntry<String, String> entry in coverage.entries) {
      final String? taken = cursor.packs[entry.key];
      if (entry.key == device || entry.value.compareTo(taken ?? '') <= 0) {
        continue;
      }
      if (taken == null || !listed.contains('$packsPrefix${entry.key}/$taken.json.gz')) {
        return false;
      }
    }
    return true;
  }

  /// See the class: a snapshot of all records once there are more than
  /// [compactAfter] packs, and the packs it holds removed after
  /// [packRetention]. Nothing when another device's snapshot came first.
  Future<void> compact() async {
    final List<_PackKey> packs = await _listPacks();
    if (packs.length <= compactAfter) {
      return;
    }
    final BucketManifest? base = await _readManifest();
    if (base == null) {
      return;
    }
    final Map<String, RemoteRecord> winners = <String, RemoteRecord>{};
    final Map<String, String> coverage = <String, String>{};
    String id(RemoteRecord r) => '${r.kind}\u0000${r.key}';
    void take(RemoteRecord r) {
      final RemoteRecord? current = winners[id(r)];
      if (current == null || compareVersions(r.updatedAt, r.device, current.updatedAt, current.device) > 0) {
        winners[id(r)] = r;
      }
    }

    if (base.snapshot != null) {
      final _Snapshot? snapshot = await _snapshot(base.snapshot!);
      if (snapshot == null) {
        return;
      }
      snapshot.records.forEach(take);
      coverage.addAll(snapshot.coverage);
    }
    packs.sort((_PackKey a, _PackKey b) => a.seq.compareTo(b.seq));
    for (final _PackKey pack in packs) {
      if (pack.seq.compareTo(coverage[pack.device] ?? '') <= 0) {
        continue;
      }
      final List<int>? bytes = await _provider.getRawObject(pack.key);
      if (bytes == null) {
        // Another device compacts too.
        return;
      }
      _records(await _decode(bytes)).forEach(take);
      coverage[pack.device] = pack.seq;
    }

    final String name = '${_seqOf(_now())}-$device';
    await _provider.putRawObject(
      '$snapshotsPrefix$name.json.gz',
      await _encode(<String, dynamic>{
        'format': format,
        'coverage': coverage,
        'records': winners.values.map((RemoteRecord r) => r.toJson()).toList(),
      }),
    );
    final BucketManifest? current = await _readManifest();
    if (current == null || current.snapshot != base.snapshot) {
      log.info('🗄 Bucket records: another snapshot came first, $name is left out');
      await _provider.deleteRawObject('$snapshotsPrefix$name.json.gz');
      return;
    }
    _manifest = BucketManifest(
      database: current.database,
      snapshot: name,
      coverage: coverage,
      legacyDevice: current.legacyDevice,
      legacyAt: current.legacyAt,
    );
    await _writeManifest(_manifest!);

    final DateTime removable = _now().subtract(packRetention);
    int removed = 0;
    for (final _PackKey pack in packs) {
      if (pack.seq.compareTo(coverage[pack.device] ?? '') <= 0 && pack.modified != null && pack.modified!.isBefore(removable)) {
        await _provider.deleteRawObject(pack.key);
        removed++;
      }
    }
    final List<String> snapshots = (await _provider.listRawObjects(snapshotsPrefix))
        .map((RemoteObjectInfo o) => o.key)
        .where((String key) => key.endsWith('.json.gz'))
        .toList()
      ..sort((String a, String b) => b.compareTo(a));
    for (final String key in snapshots.skip(snapshotsToKeep)) {
      if (key != '$snapshotsPrefix$name.json.gz') {
        await _provider.deleteRawObject(key);
      }
    }
    _packs = null;
    log.info('🗄 Bucket records: snapshot $name of ${winners.length} records, $removed packs removed');
  }

  /// History versions of the settings, newest first.
  Future<List<CloudFile>> listBackups() async {
    final RegExp pattern = RegExp(r'^records/v1/backups/(\d{14})\.json$');
    final List<CloudFile> versions = <CloudFile>[
      for (final RemoteObjectInfo info in await _provider.listRawObjects(backupsPrefix))
        if (pattern.firstMatch(info.key) case final Match match)
          CloudFile(version: match.group(1)!, modifiedTime: info.modifiedTime ?? _now(), size: info.size),
    ];
    return versions..sort((CloudFile a, CloudFile b) => b.version.compareTo(a.version));
  }

  Future<String?> readBackup(String version) async {
    final List<int>? bytes = await _provider.getRawObject('$backupsPrefix$version.json');
    return bytes == null ? null : utf8.decode(bytes);
  }

  Future<void> writeBackup(String version, String data) => _provider.putRawObject('$backupsPrefix$version.json', utf8.encode(data));

  Future<void> deleteBackup(String version) => _provider.deleteRawObject('$backupsPrefix$version.json');

  Future<List<_PackKey>> _listPacks() async =>
      (await _provider.listRawObjects(packsPrefix)).map(_PackKey.tryParse).whereType<_PackKey>().toList();

  Future<_Snapshot?> _snapshot(String name) async {
    final _Snapshot? known = _snapshots[name];
    if (known != null) {
      return known;
    }
    final List<int>? bytes = await _provider.getRawObject('$snapshotsPrefix$name.json.gz');
    if (bytes == null) {
      return null;
    }
    final Map<String, dynamic> json = await _decode(bytes);
    return _snapshots[name] = _Snapshot(_records(json), (json['coverage'] as Map? ?? const <String, dynamic>{}).cast<String, String>());
  }

  static List<RemoteRecord> _records(Map<String, dynamic> json) =>
      (json['records'] as List? ?? const <dynamic>[]).map((dynamic e) => RemoteRecord.fromJson(Map<String, dynamic>.from(e as Map))).toList();

  /// 17 digits of UTC time to the millisecond, after this device's last.
  Future<String> _nextSeq() async {
    String seq = _seqOf(_now());
    final String last = await localConfigService.read(configKey: ConfigEnum.recordPackLastKey) ?? '';
    if (last.length == seq.length && seq.compareTo(last) <= 0) {
      seq = (BigInt.parse(last) + BigInt.one).toString().padLeft(seq.length, '0');
    }
    return seq;
  }

  static String _seqOf(DateTime time) {
    final DateTime utc = time.toUtc();
    String pad(int n, [int width = 2]) => n.toString().padLeft(width, '0');
    return '${pad(utc.year, 4)}${pad(utc.month)}${pad(utc.day)}${pad(utc.hour)}${pad(utc.minute)}${pad(utc.second)}${pad(utc.millisecond, 3)}';
  }

  static Future<List<int>> _encode(Map<String, dynamic> json) async => gzip.encode(utf8.encode(await isolateService.jsonEncodeAsync(json)));

  static Future<Map<String, dynamic>> _decode(List<int> bytes) async =>
      Map<String, dynamic>.from(await isolateService.jsonDecodeAsync(utf8.decode(gzip.decode(bytes))) as Map);
}
