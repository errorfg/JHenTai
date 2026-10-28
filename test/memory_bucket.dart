import 'package:jhentai/src/service/cloud/cloud_provider.dart';

/// A bucket in memory, as S3 or WebDAV is to the sync: latest.json and the
/// history versions beside it, of versions up to 8.1.1, and objects by key
/// (their op packs, and the records layout of later versions).
class MemoryBucket implements CloudProvider {
  MemoryBucket({this.latest, DateTime Function()? now})
      : now = now ?? DateTime.now,
        latestTime = latest == null ? null : DateTime.utc(2026, 10, 4, 4, 52, 29);

  /// What modified times objects get.
  DateTime Function() now;

  String? latest;
  DateTime? latestTime;
  final Map<String, String> versions = <String, String>{};
  final Map<String, ({List<int> bytes, DateTime modified})> objects = <String, ({List<int> bytes, DateTime modified})>{};

  /// What was written, in order: object keys, 'latest.json', and 'version:'
  /// and a version.
  final List<String> writes = <String>[];

  /// A download of latest.json fails with this.
  Object? downloadError;

  /// A download of latest.json reports a miss although it is there, as the
  /// S3 provider does for any S3-level read error.
  bool readMisses = false;

  @override
  String get name => 'memory';

  @override
  Future<String?> download() async {
    if (downloadError != null) {
      throw downloadError!;
    }
    return readMisses ? null : latest;
  }

  @override
  Future<CloudFile> upload(String data, {bool saveHistory = false}) async {
    latest = data;
    latestTime = now().toUtc();
    writes.add('latest.json');
    if (saveHistory) {
      final String version = latestTime!.toIso8601String().replaceAll(RegExp(r'\D'), '').substring(0, 14);
      versions[version] = data;
      writes.add('version:$version');
    }
    return CloudFile(version: 'latest', modifiedTime: latestTime!, size: data.length);
  }

  @override
  Future<CloudFile?> getFileMetadata() async => latest == null ? null : CloudFile(version: 'latest', modifiedTime: latestTime!, size: latest!.length);

  @override
  Future<String> downloadVersion(String version) async => versions[version] ?? (throw StateError('no version $version'));

  @override
  Future<List<CloudFile>> listVersions() async => <CloudFile>[
        for (final MapEntry<String, String> e in versions.entries) CloudFile(version: e.key, modifiedTime: now(), size: e.value.length),
      ]..sort((CloudFile a, CloudFile b) => b.version.compareTo(a.version));

  @override
  Future<void> deleteVersion(String version) async {
    versions.remove(version);
  }

  @override
  Future<bool> testConnection() async => true;

  @override
  Future<void> putRawObject(String key, List<int> bytes) async {
    objects[key] = (bytes: List<int>.of(bytes), modified: now().toUtc());
    writes.add(key);
  }

  /// Keys of the objects read, in order.
  final List<String> reads = <String>[];

  @override
  Future<List<int>?> getRawObject(String key) async {
    reads.add(key);
    return objects[key]?.bytes;
  }

  @override
  Future<List<RemoteObjectInfo>> listRawObjects(String prefix) async => <RemoteObjectInfo>[
        for (final MapEntry<String, ({List<int> bytes, DateTime modified})> e in objects.entries)
          if (e.key.startsWith(prefix)) RemoteObjectInfo(key: e.key, size: e.value.bytes.length, modifiedTime: e.value.modified),
      ];

  @override
  Future<void> deleteRawObject(String key) async {
    objects.remove(key);
  }

  /// Written anywhere but in the records layout of later versions.
  Iterable<String> get writesOutsideRecords => writes.where((String key) => !key.startsWith('records/'));
}
