import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/log.dart';

import '../service/jh_service.dart';

WebDavSetting webDavSetting = WebDavSetting();

class WebDavSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  RxString serverUrl = 'https://dav.jianguoyun.com/dav/'.obs;
  RxString username = ''.obs;
  RxString password = ''.obs;
  RxString remotePath = '/JHenTaiConfig'.obs;
  RxBool enableWebDav = false.obs;
  RxBool autoSync = false.obs;

  @override
  ConfigEnum get configEnum => ConfigEnum.webdavSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    serverUrl.value = map['serverUrl'] ?? serverUrl.value;
    username.value = map['username'] ?? username.value;
    password.value = map['password'] ?? password.value;
    remotePath.value = map['remotePath'] ?? remotePath.value;
    enableWebDav.value = map['enableWebDav'] ?? enableWebDav.value;
    autoSync.value = map['autoSync'] ?? autoSync.value;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'serverUrl': serverUrl.value,
      'username': username.value,
      'password': password.value,
      'remotePath': remotePath.value,
      'enableWebDav': enableWebDav.value,
      'autoSync': autoSync.value,
    });
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> saveServerUrl(String serverUrl) async {
    log.debug('saveServerUrl:$serverUrl');
    this.serverUrl.value = serverUrl;
    await saveBeanConfig();
  }

  Future<void> saveUsername(String username) async {
    log.debug('saveUsername:$username');
    this.username.value = username;
    await saveBeanConfig();
  }

  Future<void> savePassword(String password) async {
    log.debug('savePassword');
    this.password.value = password;
    await saveBeanConfig();
  }

  Future<void> saveRemotePath(String remotePath) async {
    log.debug('saveRemotePath:$remotePath');
    this.remotePath.value = remotePath;
    await saveBeanConfig();
  }

  Future<void> saveEnableWebDav(bool enableWebDav) async {
    log.debug('saveEnableWebDav:$enableWebDav');
    this.enableWebDav.value = enableWebDav;
    await saveBeanConfig();
  }

  Future<void> saveAutoSync(bool autoSync) async {
    log.debug('saveAutoSync:$autoSync');
    this.autoSync.value = autoSync;
    await saveBeanConfig();
  }
}
