import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:collection/collection.dart';
import 'package:get/get.dart' hide Response;
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/network/tachi/tachi_client.dart';
import 'package:jhentai/src/network/tachi/tachi_host.dart';
import 'package:jhentai/src/network/tachi/tachi_models.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';
import 'package:path/path.dart' as p;

TachiExtensionService tachiExtensionService = TachiExtensionService();

/// Where an installed extension came from, so another device can install
/// the same one.
class TachiInstalledOrigin {
  const TachiInstalledOrigin({required this.pkg, required this.name, required this.repo, required this.apk, required this.versionCode});

  final String pkg;
  final String name;

  /// Index URL of the repository; empty for an APK the user picked.
  final String repo;
  final String apk;
  final int versionCode;

  factory TachiInstalledOrigin.fromJson(Map<String, dynamic> json) => TachiInstalledOrigin(
        pkg: json['pkg'] as String,
        name: json['name'] as String? ?? '',
        repo: json['repo'] as String? ?? '',
        apk: json['apk'] as String? ?? '',
        versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{'pkg': pkg, 'name': name, 'repo': repo, 'apk': apk, 'versionCode': versionCode};
}

/// Extension repositories and installed extensions.
///
/// The repositories and the list of installed extensions (with the
/// repository each came from) are a setting that cloud sync carries; a
/// device that receives it installs what it lacks and removes what was
/// removed elsewhere (see [applyInstalledList]). What the host has actually
/// installed is [installed].
class TachiExtensionService with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  @override
  ConfigEnum get configEnum => ConfigEnum.tachiExtensionSetting;

  final RxList<String> repos = <String>[].obs;

  /// Extensions to have, by package; synced.
  final RxMap<String, TachiInstalledOrigin> origins = <String, TachiInstalledOrigin>{}.obs;

  /// When [repos] or [origins] last changed here or arrived from another
  /// device, as stored (fixed-width UTC ISO 8601).
  String updatedAt = '';

  /// What the host has installed, once asked.
  final RxList<TachiExtension> installed = <TachiExtension>[].obs;
  final RxBool loadingInstalled = false.obs;
  final RxnString hostError = RxnString();

  /// Each repository's extensions, once fetched.
  final RxMap<String, List<TachiRepoExtension>> available = <String, List<TachiRepoExtension>>{}.obs;
  final RxMap<String, String> repoErrors = <String, String>{}.obs;
  final RxBool loadingRepos = false.obs;

  /// Packages being installed or removed.
  final RxSet<String> busy = <String>{}.obs;

  /// Sources by when they were last opened here, newest first; device-local.
  final RxList<String> recentSources = <String>[].obs;

  final Dio _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(minutes: 2)));

  @override
  Future<void> doInitBean() async {
    final String? recent = await localConfigService.read(configKey: ConfigEnum.tachiRecentSources);
    if (recent != null) {
      recentSources.value = (jsonDecode(recent) as List).cast<String>();
    }
  }

  @override
  void doAfterBeanReady() {}

  /// Packages a received list no longer has: removed on another device.
  final Set<String> _removedElsewhere = <String>{};

  @override
  void applyBeanConfig(String configString) {
    final Map<String, dynamic> json = jsonDecode(configString) as Map<String, dynamic>;
    final Set<String> before = origins.keys.toSet();
    repos.value = ((json['repos'] as List?) ?? const <dynamic>[]).cast<String>();
    origins.value = <String, TachiInstalledOrigin>{
      for (final dynamic e in (json['extensions'] as List?) ?? const <dynamic>[])
        (e as Map<String, dynamic>)['pkg'] as String: TachiInstalledOrigin.fromJson(e),
    };
    updatedAt = json['updatedAt'] as String? ?? '';
    _removedElsewhere
      ..addAll(before.difference(origins.keys.toSet()))
      ..removeAll(origins.keys);
  }

  @override
  String toConfigString() => jsonEncode(<String, dynamic>{
        'repos': repos,
        'extensions': origins.values.map((TachiInstalledOrigin o) => o.toJson()).toList(),
        'updatedAt': updatedAt,
      });

  Future<void> _saveChanged() async {
    updatedAt = SyncTimeUtil.nowIso();
    await saveBeanConfig();
  }

  /// Every source of the installed extensions, recently opened first.
  List<TachiSourceInfo> get sources {
    final List<TachiSourceInfo> all = <TachiSourceInfo>[for (final TachiExtension e in installed) ...e.sources];
    int rank(TachiSourceInfo s) {
      final int i = recentSources.indexOf(s.id);
      return i < 0 ? 1 << 30 : i;
    }

    all.sort((TachiSourceInfo a, TachiSourceInfo b) {
      final int byRecent = rank(a).compareTo(rank(b));
      return byRecent != 0 ? byRecent : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return all;
  }

  TachiSourceInfo? source(String id) => installed.expand((TachiExtension e) => e.sources).firstWhereOrNull((TachiSourceInfo s) => s.id == id);

  TachiExtension? extensionOfSource(String id) => installed.firstWhereOrNull((TachiExtension e) => e.sources.any((TachiSourceInfo s) => s.id == id));

  Future<void> markSourceUsed(String id) async {
    recentSources
      ..remove(id)
      ..insert(0, id);
    if (recentSources.length > 50) {
      recentSources.removeRange(50, recentSources.length);
    }
    await localConfigService.write(configKey: ConfigEnum.tachiRecentSources, value: jsonEncode(recentSources));
  }

  /// Asks the host what it has installed (starting it if needed).
  Future<void> refreshInstalled() async {
    loadingInstalled.value = true;
    try {
      installed.value = await tachiHost.run((TachiClient c) => c.extensions());
      hostError.value = null;
    } catch (e) {
      log.error('Extension host unavailable', e);
      hostError.value = e.toString();
    } finally {
      loadingInstalled.value = false;
    }
  }

  /// Fetches the index of every repository.
  Future<void> refreshRepos() async {
    loadingRepos.value = true;
    try {
      await Future.wait(repos.map(_fetchRepo));
    } finally {
      loadingRepos.value = false;
    }
  }

  Future<void> _fetchRepo(String repo) async {
    try {
      final Response<String> response = await _dio.get<String>(repo, options: Options(responseType: ResponseType.plain));
      final List<dynamic> json = jsonDecode(response.data!) as List<dynamic>;
      available[repo] = json.map((dynamic e) => TachiRepoExtension.fromJson(repo, e as Map<String, dynamic>)).toList();
      repoErrors.remove(repo);
    } catch (e) {
      log.error('Fetch extension repository failed: $repo', e);
      repoErrors[repo] = e.toString();
    }
  }

  /// [url]: a repository's `index.min.json`, or the address of its folder.
  Future<String?> addRepo(String url) async {
    String repo = url.trim();
    if (repo.isEmpty) {
      return null;
    }
    if (!repo.endsWith('.json')) {
      repo = '${repo.replaceFirst(RegExp(r'/+$'), '')}/index.min.json';
    }
    if (!repos.contains(repo)) {
      repos.add(repo);
      await _saveChanged();
    }
    await _fetchRepo(repo);
    return repoErrors[repo];
  }

  Future<void> removeRepo(String repo) async {
    repos.remove(repo);
    available.remove(repo);
    repoErrors.remove(repo);
    await _saveChanged();
  }

  /// Every extension the repositories offer, the newest version of each package.
  List<TachiRepoExtension> get offered {
    final Map<String, TachiRepoExtension> byPkg = <String, TachiRepoExtension>{};
    for (final List<TachiRepoExtension> list in available.values) {
      for (final TachiRepoExtension e in list) {
        final TachiRepoExtension? known = byPkg[e.pkg];
        if (known == null || e.versionCode > known.versionCode) {
          byPkg[e.pkg] = e;
        }
      }
    }
    return byPkg.values.toList()..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
  }

  TachiExtension? installedPackage(String pkg) => installed.firstWhereOrNull((TachiExtension e) => e.pkg == pkg);

  /// A newer version of an installed extension in the repositories.
  TachiRepoExtension? updateOf(TachiExtension extension) {
    final TachiRepoExtension? offer = offered.firstWhereOrNull((TachiRepoExtension e) => e.pkg == extension.pkg);
    return offer != null && offer.versionCode > extension.versionCode ? offer : null;
  }

  /// Downloads and installs [extension] (or its newer version).
  Future<void> install(TachiRepoExtension extension) async {
    busy.add(extension.pkg);
    final File apk = File(p.join(pathService.tempDir.path, 'tachi-${DateTime.now().microsecondsSinceEpoch}.apk'));
    try {
      await _dio.download(extension.apkUrl, apk.path);
      final TachiExtension installedExtension = await tachiHost.run((TachiClient c) => c.install(apk.path));
      origins[extension.pkg] = TachiInstalledOrigin(
        pkg: extension.pkg,
        name: installedExtension.name,
        repo: extension.repo,
        apk: extension.apk,
        versionCode: installedExtension.versionCode,
      );
      await _saveChanged();
      await refreshInstalled();
    } finally {
      busy.remove(extension.pkg);
      if (apk.existsSync()) {
        apk.deleteSync();
      }
    }
  }

  /// Installs an APK the user picked, not from a repository.
  Future<TachiExtension> installFile(String path) async {
    final TachiExtension extension = await tachiHost.run((TachiClient c) => c.install(path));
    origins[extension.pkg] = TachiInstalledOrigin(pkg: extension.pkg, name: extension.name, repo: '', apk: '', versionCode: extension.versionCode);
    await _saveChanged();
    await refreshInstalled();
    return extension;
  }

  Future<void> uninstall(String pkg) async {
    busy.add(pkg);
    try {
      await tachiHost.run((TachiClient c) => c.uninstall(pkg));
      origins.remove(pkg);
      await _saveChanged();
      await refreshInstalled();
    } finally {
      busy.remove(pkg);
    }
  }

  /// Makes the host's extensions match [origins], after they arrived from
  /// another device: missing ones are installed from their repositories
  /// (whose newest version is taken), and ones removed there are
  /// uninstalled. An extension this device installed before it had a list
  /// is kept. Only
  /// when the host runs or [startHost] is set: the host is not started
  /// just for this on a phone.
  Future<void> applyInstalledList({bool startHost = false}) async {
    if (tachiHost.clientIfRunning == null && !startHost) {
      return;
    }
    await refreshInstalled();
    final Set<String> have = installed.map((TachiExtension e) => e.pkg).toSet();
    final Iterable<TachiInstalledOrigin> missing = origins.values.where((TachiInstalledOrigin o) => !have.contains(o.pkg) && o.repo.isNotEmpty);
    if (missing.isNotEmpty) {
      for (final String repo in missing.map((TachiInstalledOrigin o) => o.repo).toSet()) {
        if (!repos.contains(repo)) {
          repos.add(repo);
        }
        if (!available.containsKey(repo)) {
          await _fetchRepo(repo);
        }
      }
      for (final TachiInstalledOrigin origin in missing.toList()) {
        final TachiRepoExtension? offer = available[origin.repo]?.firstWhereOrNull((TachiRepoExtension e) => e.pkg == origin.pkg);
        if (offer == null) {
          log.warning('Synced extension ${origin.pkg} is not in ${origin.repo}');
          continue;
        }
        try {
          await install(offer);
        } catch (e) {
          log.error('Install synced extension ${origin.pkg} failed', e);
        }
      }
    }
    for (final TachiExtension extension in installed.toList()) {
      if (_removedElsewhere.contains(extension.pkg) && !origins.containsKey(extension.pkg)) {
        try {
          await tachiHost.run((TachiClient c) => c.uninstall(extension.pkg));
        } catch (e) {
          log.error('Remove extension ${extension.pkg} failed', e);
        }
      }
    }
    _removedElsewhere.clear();
    await refreshInstalled();
  }
}
