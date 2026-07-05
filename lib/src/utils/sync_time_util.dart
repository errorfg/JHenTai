/// Helpers for sync-related timestamps.
///
/// Historically timestamps were written via `DateTime.now().toString()`, which
/// produces a local-time string without timezone information ("2026-07-05 21:30:00.123456").
/// All new writes use a FIXED-WIDTH UTC ISO8601 form ("2026-07-05T13:30:00.123456Z",
/// microseconds always 6 digits) so that lexicographic order equals
/// chronological order (Dart's own toIso8601String emits a 3-digit fraction
/// when microsecond == 0, which breaks string ordering) and cross-device
/// comparison is unambiguous. Reads must keep accepting all formats.
class SyncTimeUtil {
  SyncTimeUtil._();

  static final RegExp _canonicalPattern = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$');

  /// Current time in canonical form for persisted sync timestamps.
  static String nowIso() => format(DateTime.now().toUtc());

  /// Fixed-width canonical form of [time] (converted to UTC).
  static String format(DateTime time) {
    DateTime utc = time.toUtc();
    String pad(int n, int width) => n.toString().padLeft(width, '0');
    int fraction = utc.millisecond * 1000 + utc.microsecond;
    return '${pad(utc.year, 4)}-${pad(utc.month, 2)}-${pad(utc.day, 2)}'
        'T${pad(utc.hour, 2)}:${pad(utc.minute, 2)}:${pad(utc.second, 2)}.${pad(fraction, 6)}Z';
  }

  /// Parse any supported format (canonical, Dart ISO variants, or the legacy
  /// local-time format, interpreted in the device's current timezone).
  /// Returns time in UTC.
  static DateTime parse(String value) {
    return DateTime.parse(value).toUtc();
  }

  static DateTime? tryParse(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    try {
      return parse(value);
    } catch (_) {
      return null;
    }
  }

  /// Whether [value] is already in canonical fixed-width UTC ISO8601 form.
  static bool isCanonical(String value) {
    return _canonicalPattern.hasMatch(value);
  }

  /// Convert any supported timestamp string to canonical form.
  static String canonicalize(String value) {
    if (isCanonical(value)) {
      return value;
    }
    return format(parse(value));
  }

  /// True if [a] is strictly after [b]. Both may be in any supported format.
  static bool isAfter(String a, String b) {
    return parse(a).isAfter(parse(b));
  }
}
