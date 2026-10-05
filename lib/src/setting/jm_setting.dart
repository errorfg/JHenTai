import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/network/jm/jm_api.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/log.dart';

JmSetting jmSetting = JmSetting();

/// JM API and image lines of this device: the lines known, the user's pick
/// and how fast each line answered here. Not cloud-synced, as line speed
/// depends on the device's network; the account is in `JmAccountSetting`.
class JmSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  /// API domains last reported by the JM domain servers, and when.
  final RxList<String> apiDomains = <String>[...JmApi.builtInApiDomains].obs;
  DateTime? apiDomainsDiscoveredAt;

  /// The lines the user picked; empty means automatic, the fastest here.
  final RxString preferredApiDomain = ''.obs;
  final RxString preferredImageDomain = ''.obs;

  /// Response time of each line in milliseconds, -1 when it failed.
  final RxMap<String, int> apiLatencies = <String, int>{}.obs;
  final RxMap<String, int> imageLatencies = <String, int>{}.obs;
  DateTime? linesMeasuredAt;

  /// Image host the JM server recommended at the last measurement.
  final RxString recommendedImageDomain = ''.obs;

  /// What 8.0.30 and 8.0.31 stored here before the account moved to its
  /// own, cloud-synced setting.
  Map<String, dynamic>? legacyAccount;

  @override
  ConfigEnum get configEnum => ConfigEnum.jmSetting;

  @override
  void applyBeanConfig(String configString) {
    final Map<String, dynamic> map = (jsonDecode(configString) as Map).cast<String, dynamic>();
    final List<String> domains = (map['apiDomains'] as List? ?? const <dynamic>[]).map((dynamic d) => '$d').where((String d) => d.isNotEmpty).toList();
    if (domains.isNotEmpty) {
      apiDomains.value = domains;
    }
    apiDomainsDiscoveredAt = DateTime.tryParse(map['apiDomainsDiscoveredAt']?.toString() ?? '');
    preferredApiDomain.value = map['preferredApiDomain']?.toString() ?? '';
    // 8.0.30 and 8.0.31 always stored an image line, chosen or not, under
    // `imageDomain`; only an explicit pick is kept from now on.
    preferredImageDomain.value = map['preferredImageDomain']?.toString() ?? '';
    apiLatencies.value = _latencies(map['apiLatencies']);
    imageLatencies.value = _latencies(map['imageLatencies']);
    linesMeasuredAt = DateTime.tryParse(map['linesMeasuredAt']?.toString() ?? '');
    recommendedImageDomain.value = map['recommendedImageDomain']?.toString() ?? '';
    legacyAccount = (map['accountCookie']?.toString() ?? '').isNotEmpty
        ? <String, dynamic>{'userName': map['userName'], 'userId': map['userId'], 'accountCookie': map['accountCookie']}
        : null;
  }

  static Map<String, int> _latencies(dynamic value) => value is Map
      ? <String, int>{for (final MapEntry<dynamic, dynamic> e in value.entries) '${e.key}': int.tryParse('${e.value}') ?? -1}
      : <String, int>{};

  @override
  String toConfigString() => jsonEncode({
        'apiDomains': apiDomains,
        'apiDomainsDiscoveredAt': apiDomainsDiscoveredAt?.toUtc().toIso8601String(),
        'preferredApiDomain': preferredApiDomain.value,
        'preferredImageDomain': preferredImageDomain.value,
        'apiLatencies': Map<String, int>.of(apiLatencies),
        'imageLatencies': Map<String, int>.of(imageLatencies),
        'linesMeasuredAt': linesMeasuredAt?.toUtc().toIso8601String(),
        'recommendedImageDomain': recommendedImageDomain.value,
      });

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  /// API domains to try: the user's pick, then the fastest here, then those
  /// not measured, then those that failed.
  List<String> orderedApiDomains() {
    final String preferred = preferredApiDomain.value;
    return <String>[
      if (preferred.isNotEmpty) preferred,
      ..._bySpeed(apiDomains.where((String d) => d != preferred), apiLatencies),
    ];
  }

  /// Image lines that can be picked: the known ones and the one the server
  /// recommended.
  List<String> imageDomainChoices() => <String>{
        ...JmApi.imageDomains,
        if (recommendedImageDomain.value.isNotEmpty) recommendedImageDomain.value,
      }.toList();

  /// The image line in use: the user's pick, else [autoImageDomain].
  String get imageDomain =>
      preferredImageDomain.value.isNotEmpty ? preferredImageDomain.value : autoImageDomain;

  /// The fastest image line here, else the server's recommendation.
  String get autoImageDomain {
    final List<String> fastest = _bySpeed(imageDomainChoices(), imageLatencies);
    if (imageLatencies[fastest.first] != null && imageLatencies[fastest.first]! >= 0) {
      return fastest.first;
    }
    return recommendedImageDomain.value.isNotEmpty ? recommendedImageDomain.value : JmApi.imageDomains.first;
  }

  static List<String> _bySpeed(Iterable<String> lines, Map<String, int> latencies) {
    int rank(String line) {
      final int? ms = latencies[line];
      return ms == null ? 1 << 30 : (ms < 0 ? 1 << 31 : ms);
    }

    // Stable: equal ranks keep the order given.
    final List<String> list = lines.toList();
    final Map<String, int> index = {for (int i = 0; i < list.length; i++) list[i]: i};
    return list..sort((String a, String b) {
      final int byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : index[a]!.compareTo(index[b]!);
    });
  }

  Future<void> saveDiscoveredApiDomains(List<String> domains) async {
    if (domains.isEmpty) {
      return;
    }
    if (!listEquals(domains, apiDomains)) {
      log.info('JM API domains updated: $domains');
      apiDomains.value = domains;
    }
    apiDomainsDiscoveredAt = DateTime.now();
    await saveBeanConfig();
  }

  Future<void> saveMeasurement(JmLineMeasurement measurement) async {
    apiLatencies.value = _milliseconds(measurement.api);
    imageLatencies.value = _milliseconds(measurement.image);
    if (measurement.recommendedImageHost != null) {
      recommendedImageDomain.value = measurement.recommendedImageHost!;
    }
    linesMeasuredAt = DateTime.now();
    log.info('JM lines measured: api $apiLatencies, image $imageLatencies');
    await saveBeanConfig();
  }

  static Map<String, int> _milliseconds(Map<String, Duration?> times) =>
      <String, int>{for (final MapEntry<String, Duration?> e in times.entries) e.key: e.value?.inMilliseconds ?? -1};

  Future<void> savePreferredApiDomain(String domain) async {
    preferredApiDomain.value = domain;
    await saveBeanConfig();
  }

  Future<void> savePreferredImageDomain(String domain) async {
    preferredImageDomain.value = domain;
    await saveBeanConfig();
  }

  /// Forgets the account kept here before it moved; see [legacyAccount].
  Future<void> dropLegacyAccount() async {
    legacyAccount = null;
    await saveBeanConfig();
  }

  static bool listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
