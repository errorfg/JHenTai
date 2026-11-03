import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/content_scheme.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/log.dart';

SchemeSetting schemeSetting = SchemeSetting();

/// The site whose pages the app shows, and the page of its own (Komga, PDF)
/// open over it, which the app opens again at start. Stays on this device.
class SchemeSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  final Rx<ContentScheme> site = ContentScheme.ehentai.obs;

  /// Komga or PDF while its page is open over [site]; null otherwise.
  final Rxn<ContentScheme> ownPage = Rxn<ContentScheme>();

  @override
  ConfigEnum get configEnum => ConfigEnum.schemeSetting;

  @override
  void applyBeanConfig(String configString) {
    final Map<String, dynamic> map = (jsonDecode(configString) as Map).cast<String, dynamic>();
    final ContentScheme? saved = ContentScheme.values.firstWhereOrNull((ContentScheme s) => s.name == map['site']);
    site.value = saved != null && saved.isSite ? saved : ContentScheme.ehentai;
    final ContentScheme? page = ContentScheme.values.firstWhereOrNull((ContentScheme s) => s.name == map['ownPage']);
    ownPage.value = page != null && !page.isSite ? page : null;
  }

  @override
  String toConfigString() => jsonEncode({'site': site.value.name, if (ownPage.value != null) 'ownPage': ownPage.value!.name});

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

  /// The page of [scheme] (Komga, PDF) has opened.
  Future<void> openOwnPage(ContentScheme scheme) async {
    assert(!scheme.isSite);
    if (ownPage.value == scheme) {
      return;
    }
    ownPage.value = scheme;
    await saveBeanConfig();
  }

  /// The page of [scheme] has closed; another one may have opened already.
  Future<void> closeOwnPage(ContentScheme scheme) async {
    if (ownPage.value != scheme) {
      return;
    }
    ownPage.value = null;
    await saveBeanConfig();
  }
}
