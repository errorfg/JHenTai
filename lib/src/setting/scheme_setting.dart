import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/content_scheme.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/log.dart';

SchemeSetting schemeSetting = SchemeSetting();

/// The site whose pages the app shows. Komga and PDF are entered on top of
/// it and do not change it. Stays on this device.
class SchemeSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  final Rx<ContentScheme> site = ContentScheme.ehentai.obs;

  @override
  ConfigEnum get configEnum => ConfigEnum.schemeSetting;

  @override
  void applyBeanConfig(String configString) {
    final Map<String, dynamic> map = (jsonDecode(configString) as Map).cast<String, dynamic>();
    final ContentScheme? saved = ContentScheme.values.firstWhereOrNull((ContentScheme s) => s.name == map['site']);
    site.value = saved != null && saved.isSite ? saved : ContentScheme.ehentai;
  }

  @override
  String toConfigString() => jsonEncode({'site': site.value.name});

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> saveSite(ContentScheme scheme) async {
    assert(scheme.isSite);
    log.info('Switch site scheme: ${scheme.name}');
    site.value = scheme;
    await saveBeanConfig();
  }
}
