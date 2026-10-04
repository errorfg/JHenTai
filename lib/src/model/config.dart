import 'package:jhentai/src/enum/config_type_enum.dart';

class CloudConfig {
  final int id;

  final String shareCode;

  final String identificationCode;

  final CloudConfigTypeEnum type;

  final String version;

  final String config;

  final DateTime ctime;

  const CloudConfig({
    required this.id,
    required this.shareCode,
    required this.identificationCode,
    required this.type,
    required this.version,
    required this.config,
    required this.ctime,
  });

  factory CloudConfig.fromJson(Map<String, dynamic> json) {
    return CloudConfig(
      id: json["id"],
      shareCode: json["shareCode"],
      identificationCode: json["identificationCode"],
      type: CloudConfigTypeEnum.fromCode(json["type"]),
      version: json["version"],
      config: json["config"],
      ctime: DateTime.fromMillisecondsSinceEpoch(json["ctime"], isUtc: true).toLocal(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      "id": this.id,
      "shareCode": this.shareCode,
      "identificationCode": this.identificationCode,
      "type": this.type.code,
      "version": this.version,
      "config": this.config,
      "ctime": this.ctime.toUtc().millisecondsSinceEpoch,
    };
  }
}

/// The whole-file config list stored remotely (latest.json and its history
/// versions).
///
/// Entries whose type code this build does not know were written by a newer
/// client. They are kept verbatim and written back on upload, so an older
/// client never deletes data it cannot interpret.
class CloudConfigFile {
  final List<CloudConfig> configs;

  final List<Map<String, dynamic>> unknownEntries;

  const CloudConfigFile({required this.configs, required this.unknownEntries});

  static const CloudConfigFile empty = CloudConfigFile(configs: [], unknownEntries: []);

  /// Throws [FormatException] when [json] is not a list of config objects.
  factory CloudConfigFile.fromJson(Object? json) {
    if (json is! List) {
      throw const FormatException('Cloud config file is not a JSON list');
    }

    List<CloudConfig> configs = [];
    List<Map<String, dynamic>> unknownEntries = [];
    for (Object? entry in json) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('Cloud config entry is not a JSON object');
      }
      Object? code = entry['type'];
      if (code is int && CloudConfigTypeEnum.tryFromCode(code) != null) {
        configs.add(CloudConfig.fromJson(entry));
      } else {
        unknownEntries.add(entry);
      }
    }
    return CloudConfigFile(configs: configs, unknownEntries: unknownEntries);
  }

  /// The list to upload after a sync: each of [merged] replaces the remote
  /// entry of its type, types in [dropped] are removed, and every other remote
  /// entry is kept unchanged. A sync that covered only some types therefore
  /// never deletes the others.
  List<Map<String, dynamic>> toUploadJson(
    List<CloudConfig> merged, {
    Set<CloudConfigTypeEnum> dropped = const {},
  }) {
    Map<CloudConfigTypeEnum, Map<String, dynamic>> byType = {};
    for (CloudConfig config in configs) {
      if (!dropped.contains(config.type)) {
        byType[config.type] = config.toJson();
      }
    }
    for (CloudConfig config in merged) {
      byType[config.type] = config.toJson();
    }
    return [...byType.values, ...unknownEntries];
  }
}
