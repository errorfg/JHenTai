import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/komga/komga_progress_state.dart';

const int _pages = 20;

KomgaServerProgress _server(int page, {bool completed = false, DateTime? at}) =>
    KomgaServerProgress(
      page: page,
      completed: completed,
      readDate: at ?? DateTime.utc(2026, 10, 4, 12),
    );

KomgaLocalProgress _local(String value, String utime) =>
    KomgaLocalProgress(value: value, utime: utime);

const String _t1 = '2026-10-04T10:00:00.000000Z';
const String _t2 = '2026-10-04T11:00:00.000000Z';

KomgaProgressAction _resolve({
  required KomgaServerProgress server,
  KomgaLocalProgress? local,
  KomgaProgressBase? base,
}) => resolveKomgaProgress(
  server: server,
  local: local,
  base: base,
  pageCount: _pages,
);

void main() {
  group('value mapping', () {
    test('server progress maps to a local page index or the unread value', () {
      expect(_server(5).toLocalValue(_pages), '4');
      expect(_server(20, completed: true).toLocalValue(_pages), '19');
      expect(_server(99).toLocalValue(_pages), '19');
      expect(KomgaServerProgress.none.toLocalValue(_pages), '');
    });

    test('pushing a local value predicts the resulting server state', () {
      final KomgaServerProgress middle = KomgaServerProgress.afterPush(
        '4',
        _pages,
      );
      expect(middle.page, 5);
      expect(middle.completed, isFalse);

      final KomgaServerProgress last = KomgaServerProgress.afterPush(
        '19',
        _pages,
      );
      expect(last.page, 20);
      expect(last.completed, isTrue);

      expect(KomgaServerProgress.afterPush('', _pages).hasProgress, isFalse);
    });

    test('local values outside the book are clamped or treated as unread', () {
      expect(normalizeKomgaLocalValue('25', _pages), '19');
      expect(normalizeKomgaLocalValue('-1', _pages), '');
      expect(normalizeKomgaLocalValue('abc', _pages), '');
      expect(normalizeKomgaLocalValue('', _pages), '');
    });
  });

  group('equal values', () {
    test('a never-read book on both sides creates no base', () {
      expect(
        _resolve(server: KomgaServerProgress.none),
        KomgaProgressAction.none,
      );
      expect(
        _resolve(server: KomgaServerProgress.none, local: _local('', _t1)),
        KomgaProgressAction.none,
      );
    });

    test('matching progress records a base once, then does nothing', () {
      final KomgaLocalProgress local = _local('4', _t1);
      expect(
        _resolve(server: _server(5), local: local),
        KomgaProgressAction.updateBaseOnly,
      );

      final KomgaProgressBase base = KomgaProgressBase.agreed(
        server: _server(5),
        local: local,
      );
      expect(
        _resolve(server: _server(5), local: local, base: base),
        KomgaProgressAction.none,
      );
    });

    test('a completed server book matches a local last page', () {
      expect(
        _resolve(
          server: _server(20, completed: true),
          local: _local('19', _t1),
        ),
        KomgaProgressAction.updateBaseOnly,
      );
    });
  });

  group('first contact without a base', () {
    test('only the server has progress', () {
      expect(_resolve(server: _server(5)), KomgaProgressAction.applyServer);
    });

    test('only the local side has progress', () {
      expect(
        _resolve(server: KomgaServerProgress.none, local: _local('4', _t1)),
        KomgaProgressAction.pushLocal,
      );
    });

    test('both have progress: the newer one wins, ties go to the server', () {
      final DateTime localTime = DateTime.utc(2026, 10, 4, 10);
      expect(
        _resolve(
          server: _server(9, at: localTime.add(const Duration(seconds: 1))),
          local: _local('4', _t1),
        ),
        KomgaProgressAction.applyServer,
      );
      expect(
        _resolve(
          server: _server(9, at: localTime.subtract(const Duration(seconds: 1))),
          local: _local('4', _t1),
        ),
        KomgaProgressAction.pushLocal,
      );
      expect(
        _resolve(
          server: _server(9, at: localTime),
          local: _local('4', _t1),
        ),
        KomgaProgressAction.applyServer,
      );
    });
  });

  group('with a base', () {
    final KomgaLocalProgress baseLocal = _local('4', _t1);
    final KomgaProgressBase base = KomgaProgressBase.agreed(
      server: _server(5),
      local: baseLocal,
    );

    test('only the local side changed: push', () {
      expect(
        _resolve(server: _server(5), local: _local('9', _t2), base: base),
        KomgaProgressAction.pushLocal,
      );
    });

    test('only the server changed: apply, whatever the clocks say', () {
      expect(
        _resolve(
          server: _server(30 ~/ 2, at: DateTime.utc(2000)),
          local: baseLocal,
          base: base,
        ),
        KomgaProgressAction.applyServer,
      );
    });

    test('the server marked the book unread and the local side did not move', () {
      expect(
        _resolve(server: KomgaServerProgress.none, local: baseLocal, base: base),
        KomgaProgressAction.applyServer,
      );
    });

    test('both changed: the newer one wins', () {
      expect(
        _resolve(
          server: _server(12, at: DateTime.utc(2026, 10, 4, 12)),
          local: _local('9', _t2),
          base: base,
        ),
        KomgaProgressAction.applyServer,
      );
      expect(
        _resolve(
          server: _server(12, at: DateTime.utc(2026, 10, 4, 10, 30)),
          local: _local('9', _t2),
          base: base,
        ),
        KomgaProgressAction.pushLocal,
      );
    });

    test('both changed and the server is unread: keep the local reading', () {
      expect(
        _resolve(
          server: KomgaServerProgress.none,
          local: _local('9', _t2),
          base: base,
        ),
        KomgaProgressAction.pushLocal,
      );
    });

    test('a local unread value is pushed like any other change', () {
      expect(
        _resolve(server: _server(5), local: _local('', _t2), base: base),
        KomgaProgressAction.pushLocal,
      );
    });

    test('the base survives a JSON round trip', () {
      expect(
        KomgaProgressBase.fromJson(base.toJson()).toJson(),
        base.toJson(),
      );
    });
  });
}
