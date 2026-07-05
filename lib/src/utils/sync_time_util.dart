/// Helpers for sync-related timestamps.
///
/// Historically timestamps were written via `DateTime.now().toString()`, which
/// produces a local-time string without timezone information ("2026-07-05 21:30:00.123456").
/// All new writes use UTC ISO8601 ("2026-07-05T13:30:00.123456Z") so that
/// lexicographic order equals chronological order and cross-device comparison
/// is unambiguous. Reads must keep accepting both formats.
class SyncTimeUtil {
  SyncTimeUtil._();

  /// Current time in canonical form for persisted sync timestamps.
  static String nowIso() => DateTime.now().toUtc().toIso8601String();

  /// Parse either the legacy local-time format or the canonical UTC ISO format.
  /// Returns time in UTC. Legacy strings are interpreted in the device's
  /// current timezone (best effort - the writer's timezone is unrecoverable).
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

  /// Whether [value] is already in canonical UTC ISO8601 form.
  static bool isCanonical(String value) {
    return value.contains('T') && value.endsWith('Z');
  }

  /// Convert any supported timestamp string to canonical form.
  static String canonicalize(String value) {
    if (isCanonical(value)) {
      return value;
    }
    return parse(value).toIso8601String();
  }

  /// True if [a] is strictly after [b]. Both may be in either format.
  static bool isAfter(String a, String b) {
    return parse(a).isAfter(parse(b));
  }
}
