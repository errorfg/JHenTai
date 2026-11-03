import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/setting/test_build.dart';

void main() {
  test('a test build may sync only with a bucket or a sync server named as a test one', () {
    bool allows(String provider, {String bucket = '', String serverUrl = ''}) => TestBuild.allows(provider: provider, bucket: bucket, serverUrl: serverUrl);
    expect(allows('s3', bucket: 'jhentai-sync-dev'), isTrue);
    expect(allows('s3', bucket: 'jhentai-sync'), isFalse);
    expect(allows('server', serverUrl: 'https://gallery-sync-dev.example.workers.dev'), isTrue);
    expect(allows('server', serverUrl: 'https://sync.example.com'), isFalse);
    expect(allows('server', serverUrl: 'https://sync.example.com/gallery-sync-dev'), isFalse, reason: 'by the host, not the path');
    expect(allows('webdav', bucket: 'jhentai-sync-dev', serverUrl: 'https://gallery-sync-dev.example.workers.dev'), isFalse);
  });
}
