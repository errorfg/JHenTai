import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/log.dart';

import '../service/jh_service.dart';

SyncSetting syncSetting = SyncSetting();

/// 统一同步设置（整合 WebDAV + S3 + 历史版本配置）
class SyncSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  // ==================== 通用设置 ====================

  /// 当前使用的同步提供商 ('s3' 或 'webdav')
  RxString currentProvider = 's3'.obs; // 默认使用 S3 (Cloudflare R2)

  /// 是否启用自动同步
  RxBool autoSync = false.obs;

  // ==================== S3 设置 ====================

  /// 是否启用 S3 同步
  RxBool enableS3 = false.obs;

  /// S3 Endpoint (例如: <account-id>.r2.cloudflarestorage.com)
  RxString s3Endpoint = ''.obs;

  /// S3 Access Key
  RxString s3AccessKey = ''.obs;

  /// S3 Secret Key
  RxString s3SecretKey = ''.obs;

  /// S3 Bucket Name
  RxString s3BucketName = 'jhentai-sync'.obs;

  /// S3 Region (R2 使用 'auto')
  RxString s3Region = 'auto'.obs;

  /// S3 对象键前缀 (例如: 'config/')
  RxString s3BaseKey = ''.obs;

  /// S3 是否使用 SSL (默认 true)
  RxBool s3UseSSL = true.obs;

  // ==================== WebDAV 设置 ====================

  /// 是否启用 WebDAV 同步
  RxBool enableWebDav = false.obs;

  /// WebDAV 服务器地址
  RxString webdavServerUrl = 'https://dav.jianguoyun.com/dav/'.obs;

  /// WebDAV 用户名
  RxString webdavUsername = ''.obs;

  /// WebDAV 密码
  RxString webdavPassword = ''.obs;

  /// WebDAV 远程路径
  RxString webdavRemotePath = '/JHenTaiConfig'.obs;

  // ==================== 历史版本设置 ====================

  /// 是否启用历史版本保存（默认关闭）
  RxBool enableHistory = false.obs;

  /// 保留的最大历史版本数（默认 10）
  RxInt maxHistoryVersions = 10.obs;

  /// 自动清理旧版本（默认开启）
  RxBool autoCleanHistory = true.obs;

  @override
  ConfigEnum get configEnum => ConfigEnum.syncSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    // 通用设置
    currentProvider.value = map['currentProvider'] ?? currentProvider.value;
    autoSync.value = map['autoSync'] ?? autoSync.value;

    // S3 设置
    enableS3.value = map['enableS3'] ?? enableS3.value;
    s3Endpoint.value = map['s3Endpoint'] ?? s3Endpoint.value;
    s3AccessKey.value = map['s3AccessKey'] ?? s3AccessKey.value;
    s3SecretKey.value = map['s3SecretKey'] ?? s3SecretKey.value;
    s3BucketName.value = map['s3BucketName'] ?? s3BucketName.value;
    s3Region.value = map['s3Region'] ?? s3Region.value;
    s3BaseKey.value = map['s3BaseKey'] ?? s3BaseKey.value;
    s3UseSSL.value = map['s3UseSSL'] ?? s3UseSSL.value;

    // WebDAV 设置
    enableWebDav.value = map['enableWebDav'] ?? enableWebDav.value;
    webdavServerUrl.value = map['webdavServerUrl'] ?? webdavServerUrl.value;
    webdavUsername.value = map['webdavUsername'] ?? webdavUsername.value;
    webdavPassword.value = map['webdavPassword'] ?? webdavPassword.value;
    webdavRemotePath.value = map['webdavRemotePath'] ?? webdavRemotePath.value;

    // 历史版本设置
    enableHistory.value = map['enableHistory'] ?? enableHistory.value;
    maxHistoryVersions.value = map['maxHistoryVersions'] ?? maxHistoryVersions.value;
    autoCleanHistory.value = map['autoCleanHistory'] ?? autoCleanHistory.value;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      // 通用设置
      'currentProvider': currentProvider.value,
      'autoSync': autoSync.value,

      // S3 设置
      'enableS3': enableS3.value,
      's3Endpoint': s3Endpoint.value,
      's3AccessKey': s3AccessKey.value,
      's3SecretKey': s3SecretKey.value,
      's3BucketName': s3BucketName.value,
      's3Region': s3Region.value,
      's3BaseKey': s3BaseKey.value,
      's3UseSSL': s3UseSSL.value,

      // WebDAV 设置
      'enableWebDav': enableWebDav.value,
      'webdavServerUrl': webdavServerUrl.value,
      'webdavUsername': webdavUsername.value,
      'webdavPassword': webdavPassword.value,
      'webdavRemotePath': webdavRemotePath.value,

      // 历史版本设置
      'enableHistory': enableHistory.value,
      'maxHistoryVersions': maxHistoryVersions.value,
      'autoCleanHistory': autoCleanHistory.value,
    });
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  // ==================== 通用设置保存方法 ====================

  Future<void> saveCurrentProvider(String provider) async {
    log.debug('saveCurrentProvider: $provider');
    currentProvider.value = provider;
    await saveBeanConfig();
  }

  Future<void> saveAutoSync(bool enabled) async {
    log.debug('saveAutoSync: $enabled');
    autoSync.value = enabled;
    await saveBeanConfig();
  }

  // ==================== S3 设置保存方法 ====================

  Future<void> saveEnableS3(bool enabled) async {
    log.debug('saveEnableS3: $enabled');
    enableS3.value = enabled;
    await saveBeanConfig();
  }

  Future<void> saveS3Endpoint(String endpoint) async {
    log.debug('saveS3Endpoint: $endpoint');
    s3Endpoint.value = endpoint;
    await saveBeanConfig();
  }

  Future<void> saveS3AccessKey(String accessKey) async {
    log.debug('saveS3AccessKey');
    s3AccessKey.value = accessKey;
    await saveBeanConfig();
  }

  Future<void> saveS3SecretKey(String secretKey) async {
    log.debug('saveS3SecretKey');
    s3SecretKey.value = secretKey;
    await saveBeanConfig();
  }

  Future<void> saveS3BucketName(String bucketName) async {
    log.debug('saveS3BucketName: $bucketName');
    s3BucketName.value = bucketName;
    await saveBeanConfig();
  }

  Future<void> saveS3Region(String region) async {
    log.debug('saveS3Region: $region');
    s3Region.value = region;
    await saveBeanConfig();
  }

  Future<void> saveS3BaseKey(String baseKey) async {
    log.debug('saveS3BaseKey: $baseKey');
    s3BaseKey.value = baseKey;
    await saveBeanConfig();
  }

  Future<void> saveS3UseSSL(bool useSSL) async {
    log.debug('saveS3UseSSL: $useSSL');
    s3UseSSL.value = useSSL;
    await saveBeanConfig();
  }

  // ==================== WebDAV 设置保存方法 ====================

  Future<void> saveEnableWebDav(bool enabled) async {
    log.debug('saveEnableWebDav: $enabled');
    enableWebDav.value = enabled;
    await saveBeanConfig();
  }

  Future<void> saveWebdavServerUrl(String serverUrl) async {
    log.debug('saveWebdavServerUrl: $serverUrl');
    webdavServerUrl.value = serverUrl;
    await saveBeanConfig();
  }

  Future<void> saveWebdavUsername(String username) async {
    log.debug('saveWebdavUsername: $username');
    webdavUsername.value = username;
    await saveBeanConfig();
  }

  Future<void> saveWebdavPassword(String password) async {
    log.debug('saveWebdavPassword');
    webdavPassword.value = password;
    await saveBeanConfig();
  }

  Future<void> saveWebdavRemotePath(String remotePath) async {
    log.debug('saveWebdavRemotePath: $remotePath');
    webdavRemotePath.value = remotePath;
    await saveBeanConfig();
  }

  // ==================== 历史版本设置保存方法 ====================

  Future<void> saveEnableHistory(bool enabled) async {
    log.debug('saveEnableHistory: $enabled');
    enableHistory.value = enabled;
    await saveBeanConfig();
  }

  Future<void> saveMaxHistoryVersions(int max) async {
    log.debug('saveMaxHistoryVersions: $max');
    maxHistoryVersions.value = max;
    await saveBeanConfig();
  }

  Future<void> saveAutoCleanHistory(bool enabled) async {
    log.debug('saveAutoCleanHistory: $enabled');
    autoCleanHistory.value = enabled;
    await saveBeanConfig();
  }
}
