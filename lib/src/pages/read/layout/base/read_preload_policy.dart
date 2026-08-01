import 'package:jhentai/src/model/read_page_info.dart';

double readPagePreloadExtent({
  required ReadMode mode,
  required int networkPageCount,
  required int localPageCount,
  bool doubleColumn = false,
}) {
  final int pageCount = mode.usesNetworkPreloadSettings
      ? networkPageCount
      : localPageCount;
  return doubleColumn ? (pageCount + 1) / 2 : pageCount.toDouble();
}

double readListPreloadExtent({
  required ReadMode mode,
  required int networkDistance,
  required int localDistance,
  required double viewportExtent,
}) {
  final int distance = mode.usesNetworkPreloadSettings
      ? networkDistance
      : localDistance;
  return distance * viewportExtent;
}
