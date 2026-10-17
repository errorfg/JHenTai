import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/network/tachi/tachi_client.dart';
import 'package:jhentai/src/network/tachi/tachi_host.dart';
import 'package:jhentai/src/network/tachi/tachi_models.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/notification/tap_menu_button_notification.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/tachi/tachi_extension_service.dart';
import 'package:jhentai/src/utils/route_util.dart';

import 'tachi_source_page.dart';

/// An extension's icon, served by the host.
class TachiExtensionIcon extends StatelessWidget {
  const TachiExtensionIcon({super.key, required this.pkg, this.size = 36});

  final String pkg;
  final double size;

  @override
  Widget build(BuildContext context) {
    final Widget placeholder = Icon(Icons.extension_outlined, size: size * 0.8);
    final TachiClient? client = tachiHost.clientIfRunning;
    if (client == null) {
      return SizedBox(width: size, height: size, child: placeholder);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 5),
      child: Image.network(
        client.iconUri(pkg).toString(),
        headers: client.authHeaders,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => SizedBox(width: size, height: size, child: placeholder),
      ),
    );
  }
}

/// The home of the Tachiyomi site: the sources of the installed
/// extensions, the ones opened lately first.
class TachiSourcesPage extends StatefulWidget {
  const TachiSourcesPage({super.key, this.showMenuButton = false, this.showTitle = false, this.name});

  final bool showMenuButton;
  final bool showTitle;
  final String? name;

  @override
  State<TachiSourcesPage> createState() => _TachiSourcesPageState();
}

class _TachiSourcesPageState extends State<TachiSourcesPage> {
  @override
  void initState() {
    super.initState();
    if (tachiExtensionService.installed.isEmpty) {
      tachiExtensionService.refreshInstalled();
    }
  }

  void _open(TachiSourceInfo source, {bool latest = false}) {
    toRoute(Routes.tachiSource, arguments: TachiSourcePageArgument(sourceId: source.id, latest: latest), preventDuplicates: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.showMenuButton ? IconButton(icon: const Icon(Icons.menu, size: 20), onPressed: () => TapMenuButtonNotification().dispatch(context)) : null,
        title: widget.showTitle ? Text(widget.name ?? 'tachiSources'.tr) : null,
        centerTitle: true,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'refresh'.tr, onPressed: tachiExtensionService.refreshInstalled),
        ],
      ),
      body: Obx(() {
        if (tachiExtensionService.loadingInstalled.isTrue && tachiExtensionService.installed.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        final String? error = tachiExtensionService.hostError.value;
        if (error != null && tachiExtensionService.installed.isEmpty) {
          return _Message(
            icon: Icons.error_outline,
            text: '${'tachiHostUnavailable'.tr}\n$error',
            action: TextButton(onPressed: tachiExtensionService.refreshInstalled, child: Text('retry'.tr)),
          );
        }
        final List<TachiSourceInfo> sources = tachiExtensionService.sources;
        if (sources.isEmpty) {
          return _Message(
            icon: Icons.extension_off_outlined,
            text: 'noTachiSources'.tr,
            action: FilledButton(onPressed: () => toRoute(Routes.tachiExtensions), child: Text('tachiExtensions'.tr)),
          );
        }
        final Set<String> recent = tachiExtensionService.recentSources.take(5).toSet();
        final List<TachiSourceInfo> lately = sources.where((TachiSourceInfo s) => recent.contains(s.id)).toList();
        final List<TachiSourceInfo> others = sources.where((TachiSourceInfo s) => !recent.contains(s.id)).toList()
          ..sort((TachiSourceInfo a, TachiSourceInfo b) => '${a.lang}${a.name}'.toLowerCase().compareTo('${b.lang}${b.name}'.toLowerCase()));
        return ListView(
          children: [
            if (lately.isNotEmpty) ...[
              _Header('tachiRecentlyUsed'.tr),
              for (final TachiSourceInfo s in lately) _tile(s),
            ],
            if (others.isNotEmpty) ...[
              if (lately.isNotEmpty) _Header('tachiAllSources'.tr),
              for (final TachiSourceInfo s in others) _tile(s),
            ],
          ],
        );
      }),
    );
  }

  Widget _tile(TachiSourceInfo source) {
    final TachiExtension? extension = tachiExtensionService.extensionOfSource(source.id);
    return ListTile(
      leading: extension == null ? const Icon(Icons.extension_outlined) : TachiExtensionIcon(pkg: extension.pkg),
      title: Text(source.name),
      subtitle: Text([source.lang.toUpperCase(), if (extension?.nsfw ?? false) '18+'].join(' · ')),
      trailing: source.supportsLatest
          ? TextButton(
              onPressed: () => _open(source, latest: true),
              child: Text('tachiLatest'.tr),
            )
          : null,
      onTap: () => _open(source),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center),
              if (action != null) ...[const SizedBox(height: 12), action!],
            ],
          ),
        ),
      );
}
