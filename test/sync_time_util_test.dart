import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

void main() {
  group('SyncTimeUtil', () {
    test('parses canonical UTC ISO8601', () {
      DateTime parsed = SyncTimeUtil.parse('2026-07-05T13:30:00.123456Z');
      expect(parsed.isUtc, true);
      expect(parsed.hour, 13);
    });

    test('parses legacy local-time format and converts to UTC', () {
      DateTime parsed = SyncTimeUtil.parse('2026-07-05 21:30:00.123456');
      expect(parsed.isUtc, true);
      DateTime expected = DateTime(2026, 7, 5, 21, 30, 0, 123, 456).toUtc();
      expect(parsed, expected);
    });

    test('isCanonical distinguishes formats', () {
      expect(SyncTimeUtil.isCanonical('2026-07-05T13:30:00.123Z'), true);
      expect(SyncTimeUtil.isCanonical('2026-07-05 21:30:00.123456'), false);
    });

    test('canonicalize converts legacy and keeps canonical unchanged', () {
      String canonical = '2026-07-05T13:30:00.123Z';
      expect(SyncTimeUtil.canonicalize(canonical), canonical);

      String converted = SyncTimeUtil.canonicalize('2026-07-05 21:30:00.123');
      expect(converted.endsWith('Z'), true);
      expect(SyncTimeUtil.parse(converted), DateTime(2026, 7, 5, 21, 30, 0, 123).toUtc());
    });

    test('isAfter works across mixed formats', () {
      DateTime base = DateTime(2026, 7, 5, 21, 30);
      String legacy = base.toString();
      String canonicalEarlier = base.subtract(const Duration(minutes: 1)).toUtc().toIso8601String();
      String canonicalLater = base.add(const Duration(minutes: 1)).toUtc().toIso8601String();

      expect(SyncTimeUtil.isAfter(canonicalLater, legacy), true);
      expect(SyncTimeUtil.isAfter(canonicalEarlier, legacy), false);
    });

    test('nowIso is canonical and lexicographically ordered', () async {
      String a = SyncTimeUtil.nowIso();
      await Future.delayed(const Duration(milliseconds: 5));
      String b = SyncTimeUtil.nowIso();
      expect(SyncTimeUtil.isCanonical(a), true);
      expect(a.compareTo(b) < 0, true);
    });

    test('tryParse returns null for garbage', () {
      expect(SyncTimeUtil.tryParse('not a time'), null);
      expect(SyncTimeUtil.tryParse(null), null);
      expect(SyncTimeUtil.tryParse(''), null);
    });
  });
}
