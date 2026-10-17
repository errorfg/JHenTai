import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/network/tachi/tachi_client.dart';
import 'package:jhentai/src/network/tachi/tachi_host.dart';
import 'package:jhentai/src/network/tachi/tachi_models.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/notification/tap_menu_button_notification.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/tachi/tachi_backup_import.dart';
import 'package:jhentai/src/service/tachi/tachi_extension_service.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/snack_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';

import 'tachi_sources_page.dart';

enum _MenuAction { installFile, importBackup, clearCookies }

/// Extensions: installed ones (with updates), those the repositories
/// offer, and the repositories.
class TachiExtensionsPage extends StatefulWidget {
  const TachiExtensionsPage({super.key, this.showMenuButton = false, this.showTitle = true, this.name});

  final bool showMenuButton;
  final bool showTitle;
  final String? name;

  @override
  State<TachiExtensionsPage> createState() => _TachiExtensionsPageState();
}

class _TachiExtensionsPageState extends State<TachiExtensionsPage> {
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    await Future.wait(<Future<void>>[tachiExtensionService.refreshInstalled(), tachiExtensionService.refreshRepos()]);
  }

  Future<void> _run(Future<void> Function() action, String failure) async {
    try {
      await action();
    } catch (e) {
      snack(failure, e.toString(), isShort: true);
    }
  }

  Future<void> _menu(_MenuAction action) async {
    switch (action) {
      case _MenuAction.installFile:
        final FilePickerResult? picked = await FilePicker.platform.pickFiles(type: FileType.any);
        final String? path = picked?.files.single.path;
        if (path != null) {
          await _run(() async {
            final TachiExtension extension = await tachiExtensionService.installFile(path);
            toast('${'tachiInstalled'.tr}: ${extension.name}');
          }, 'tachiInstallFailed'.tr);
        }
      case _MenuAction.importBackup:
        final FilePickerResult? picked = await FilePicker.platform.pickFiles(type: FileType.any);
        final String? path = picked?.files.single.path;
        if (path != null) {
          await _run(() async {
            final TachiBackupImportResult result = await tachiBackupImport.importFile(path);
            if (mounted) {
              await showDialog<void>(
                context: context,
                builder: (BuildContext context) => AlertDialog(
                  title: Text('tachiImportBackup'.tr),
                  content: Text(result.describe()),
                  actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('OK'))],
                ),
              );
            }
          }, 'tachiImportFailed'.tr);
        }
      case _MenuAction.clearCookies:
        await _run(() async {
          await tachiHost.run((TachiClient c) => c.clearCookies());
          toast('success'.tr);
        }, 'failed'.tr);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          leading: widget.showMenuButton ? IconButton(icon: const Icon(Icons.menu, size: 20), onPressed: () => TapMenuButtonNotification().dispatch(context)) : null,
          title: widget.showTitle ? Text(widget.name ?? 'tachiExtensions'.tr) : null,
          centerTitle: true,
          actions: [
            IconButton(icon: const Icon(Icons.refresh), tooltip: 'refresh'.tr, onPressed: _refresh),
            PopupMenuButton<_MenuAction>(
              onSelected: _menu,
              itemBuilder: (_) => [
                PopupMenuItem(value: _MenuAction.installFile, child: Text('tachiInstallFromFile'.tr)),
                PopupMenuItem(value: _MenuAction.importBackup, child: Text('tachiImportBackup'.tr)),
                PopupMenuItem(value: _MenuAction.clearCookies, child: Text('tachiClearCookies'.tr)),
              ],
            ),
          ],
          bottom: TabBar(tabs: [Tab(text: 'tachiInstalled'.tr), Tab(text: 'tachiAvailable'.tr), Tab(text: 'tachiRepositories'.tr)]),
        ),
        body: TabBarView(children: [_buildInstalled(context), _buildAvailable(context), _buildRepos(context)]),
      ),
    );
  }

  Widget _buildInstalled(BuildContext context) {
    return Obx(() {
      if (tachiExtensionService.loadingInstalled.isTrue && tachiExtensionService.installed.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      final String? error = tachiExtensionService.hostError.value;
      if (error != null && tachiExtensionService.installed.isEmpty) {
        return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${'tachiHostUnavailable'.tr}\n$error', textAlign: TextAlign.center)));
      }
      final List<TachiExtension> installed = tachiExtensionService.installed.toList()
        ..sort((TachiExtension a, TachiExtension b) {
          final int byUpdate = (tachiExtensionService.updateOf(a) == null ? 1 : 0).compareTo(tachiExtensionService.updateOf(b) == null ? 1 : 0);
          return byUpdate != 0 ? byUpdate : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      if (installed.isEmpty) {
        return Center(child: Text('noTachiSources'.tr));
      }
      return ListView(
        children: [
          for (final TachiExtension e in installed)
            ListTile(
              leading: TachiExtensionIcon(pkg: e.pkg),
              title: Text(e.name),
              subtitle: Text([e.versionName, e.lang.toUpperCase(), if (e.nsfw) '18+'].join(' · ')),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tachiExtensionService.busy.contains(e.pkg))
                    const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  else ...[
                    if (tachiExtensionService.updateOf(e) case final TachiRepoExtension update)
                      TextButton(onPressed: () => _run(() => tachiExtensionService.install(update), 'tachiInstallFailed'.tr), child: Text('update'.tr)),
                    for (final TachiSourceInfo s in e.sources.where((TachiSourceInfo s) => s.configurable))
                      IconButton(
                        icon: const Icon(Icons.settings_outlined),
                        tooltip: e.sources.length > 1 ? s.name : 'tachiSourceSettings'.tr,
                        onPressed: () => toRoute(Routes.tachiSourceSettings, arguments: s.id),
                      ),
                    IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'tachiUninstall'.tr, onPressed: () => _confirmUninstall(context, e)),
                  ],
                ],
              ),
            ),
        ],
      );
    });
  }

  Future<void> _confirmUninstall(BuildContext context, TachiExtension extension) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('tachiUninstall'.tr),
        content: Text(extension.name),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text('cancel'.tr)),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text('tachiUninstall'.tr)),
        ],
      ),
    );
    if (ok == true) {
      await _run(() => tachiExtensionService.uninstall(extension.pkg), 'failed'.tr);
    }
  }

  Widget _buildAvailable(BuildContext context) {
    return Obx(() {
      if (tachiExtensionService.repos.isEmpty) {
        return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('tachiNoRepositories'.tr, textAlign: TextAlign.center)));
      }
      final List<TachiRepoExtension> offered = tachiExtensionService.offered
          .where((TachiRepoExtension e) => _filter.isEmpty || e.displayName.toLowerCase().contains(_filter.toLowerCase()) || e.sources.any((TachiSourceInfo s) => s.name.toLowerCase().contains(_filter.toLowerCase())))
          .toList();
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'search'.tr, isDense: true),
              onChanged: (String v) => setState(() => _filter = v.trim()),
            ),
          ),
          if (tachiExtensionService.loadingRepos.isTrue) const LinearProgressIndicator(),
          for (final MapEntry<String, String> error in tachiExtensionService.repoErrors.entries)
            ListTile(dense: true, leading: const Icon(Icons.error_outline), title: Text(error.key), subtitle: Text(error.value, maxLines: 2)),
          Expanded(
            child: ListView(
              children: [
                for (final TachiRepoExtension e in offered)
                  ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(7),
                      child: Image.network(e.iconUrl, width: 36, height: 36, errorBuilder: (_, __, ___) => const Icon(Icons.extension_outlined)),
                    ),
                    title: Text(e.displayName),
                    subtitle: Text([e.versionName, e.lang.toUpperCase(), if (e.nsfw) '18+', e.sources.map((TachiSourceInfo s) => s.name).join(', ')].join(' · '), maxLines: 2),
                    trailing: tachiExtensionService.busy.contains(e.pkg)
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                        : switch (tachiExtensionService.installedPackage(e.pkg)) {
                            null => TextButton(onPressed: () => _run(() => tachiExtensionService.install(e), 'tachiInstallFailed'.tr), child: Text('tachiInstall'.tr)),
                            final TachiExtension have when have.versionCode < e.versionCode =>
                              TextButton(onPressed: () => _run(() => tachiExtensionService.install(e), 'tachiInstallFailed'.tr), child: Text('update'.tr)),
                            _ => const Icon(Icons.check),
                          },
                  ),
              ],
            ),
          ),
        ],
      );
    });
  }

  Widget _buildRepos(BuildContext context) {
    return Obx(() => ListView(
          children: [
            for (final String repo in tachiExtensionService.repos)
              ListTile(
                title: Text(repo, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text('${tachiExtensionService.available[repo]?.length ?? 0}'),
                trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => tachiExtensionService.removeRepo(repo)),
              ),
            ListTile(leading: const Icon(Icons.add), title: Text('tachiAddRepository'.tr), onTap: () => _addRepo(context)),
          ],
        ));
  }

  Future<void> _addRepo(BuildContext context) async {
    final TextEditingController controller = TextEditingController();
    final String? url = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('tachiAddRepository'.tr),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: 'tachiRepositoryHint'.tr),
          onSubmitted: (String v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('cancel'.tr)),
          TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: Text('tachiAdd'.tr)),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty) {
      return;
    }
    final String? error = await tachiExtensionService.addRepo(url);
    if (error != null) {
      snack('tachiAddRepository'.tr, error, isShort: true);
    }
  }
}
