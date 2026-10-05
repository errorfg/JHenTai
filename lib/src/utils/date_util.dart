import 'package:intl/intl.dart';

class DateUtil {
  /// [utcTimeString] as local time; a string in another form (e.g. a date
  /// alone, as JM gives for comments) is returned as is.
  static String transformUtc2LocalTimeString(String utcTimeString) {
    final DateTime utcTime;
    try {
      utcTime = DateFormat('yyyy-MM-dd HH:mm', 'en_US').parseUtc(utcTimeString).toLocal();
    } on FormatException {
      return utcTimeString;
    }
    final String localTime = DateFormat('yyyy-MM-dd HH:mm').format(utcTime);
    return localTime;
  }
}
