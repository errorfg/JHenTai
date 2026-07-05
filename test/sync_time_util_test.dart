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

    test('format is fixed-width even when microsecond part is zero', () {
      /// Dart's own toIso8601String emits ".123Z" here, which breaks
      /// lexicographic ordering against 6-digit fractions
      expect(SyncTimeUtil.format(DateTime.utc(2026, 7, 5, 13, 30, 0, 123, 0)), '2026-07-05T13:30:00.123000Z');
      expect(SyncTimeUtil.format(DateTime.utc(2026, 7, 5, 13, 30, 0, 123, 456)), '2026-07-05T13:30:00.123456Z');
      expect(SyncTimeUtil.format(DateTime.utc(2026, 7, 5, 13, 30)), '2026-07-05T13:30:00.000000Z');
    });

    test('fixed-width form is lexicographically ordered', () {
      DateTime a = DateTime.utc(2026, 7, 5, 13, 30, 0, 123, 0);
      DateTime b = DateTime.utc(2026, 7, 5, 13, 30, 0, 123, 456);

      /// Dart's variable-width form misorders exactly this pair
      expect(a.toIso8601String().compareTo(b.toIso8601String()) > 0, true);
      expect(SyncTimeUtil.format(a).compareTo(SyncTimeUtil.format(b)) < 0, true);
    });

    test('isCanonical only accepts the fixed-width form', () {
      expect(SyncTimeUtil.isCanonical('2026-07-05T13:30:00.123456Z'), true);
      expect(SyncTimeUtil.isCanonical('2026-07-05T13:30:00.123Z'), false, reason: 'variable-width Dart ISO is not canonical');
      expect(SyncTimeUtil.isCanonical('2026-07-05 21:30:00.123456'), false);
    });

    test('canonicalize converts all supported formats to fixed width', () {
      String canonical = '2026-07-05T13:30:00.123456Z';
      expect(SyncTimeUtil.canonicalize(canonical), canonical);
      expect(SyncTimeUtil.canonicalize('2026-07-05T13:30:00.123Z'), '2026-07-05T13:30:00.123000Z');

      String converted = SyncTimeUtil.canonicalize('2026-07-05 21:30:00.123');
      expect(SyncTimeUtil.isCanonical(converted), true);
      expect(SyncTimeUtil.parse(converted), DateTime(2026, 7, 5, 21, 30, 0, 123).toUtc());
    });

    test('isAfter works across mixed formats', () {
      DateTime base = DateTime(2026, 7, 5, 21, 30);
      String legacy = base.toString();
      String canonicalEarlier = SyncTimeUtil.format(base.subtract(const Duration(minutes: 1)));
      String canonicalLater = SyncTimeUtil.format(base.add(const Duration(minutes: 1)));

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
