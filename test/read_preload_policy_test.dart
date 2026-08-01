import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/pages/read/layout/base/read_preload_policy.dart';

void main() {
  group('ReadMode preload semantics', () {
    test('online and remote sources use network preload settings', () {
      expect(ReadMode.online.usesNetworkPreloadSettings, isTrue);
      expect(ReadMode.remote.usesNetworkPreloadSettings, isTrue);
    });

    test(
      'downloaded, archive, and local sources keep local preload settings',
      () {
        expect(ReadMode.downloaded.usesNetworkPreloadSettings, isFalse);
        expect(ReadMode.archive.usesNetworkPreloadSettings, isFalse);
        expect(ReadMode.local.usesNetworkPreloadSettings, isFalse);
      },
    );
  });

  group('page layout preload policy', () {
    test(
      'single-page layout uses the network page count for remote sources',
      () {
        expect(
          readPagePreloadExtent(
            mode: ReadMode.remote,
            networkPageCount: 2,
            localPageCount: 9,
          ),
          2,
        );
      },
    );

    test(
      'double-column layout uses the network page count for remote sources',
      () {
        expect(
          readPagePreloadExtent(
            mode: ReadMode.remote,
            networkPageCount: 3,
            localPageCount: 9,
            doubleColumn: true,
          ),
          2,
        );
      },
    );
  });

  group('list layout preload policy', () {
    test('horizontal list uses the network distance for remote sources', () {
      expect(
        readListPreloadExtent(
          mode: ReadMode.remote,
          networkDistance: 2,
          localDistance: 9,
          viewportExtent: 600,
        ),
        1200,
      );
    });

    test('vertical list uses the network distance for remote sources', () {
      expect(
        readListPreloadExtent(
          mode: ReadMode.remote,
          networkDistance: 3,
          localDistance: 9,
          viewportExtent: 800,
        ),
        2400,
      );
    });

    test('local sources still use the local distance', () {
      expect(
        readListPreloadExtent(
          mode: ReadMode.local,
          networkDistance: 2,
          localDistance: 9,
          viewportExtent: 100,
        ),
        900,
      );
    });
  });
}
