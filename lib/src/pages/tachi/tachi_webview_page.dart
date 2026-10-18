import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/network/tachi/tachi_browser.dart';
import 'package:jhentai/src/network/tachi/tachi_client.dart';
import 'package:jhentai/src/network/tachi/tachi_host.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/tachi/tachi_extension_service.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// A source's site inside the app, for what an extension leaves to the user,
/// such as logging in (Mihon's "WebView"). The argument is the source's id.
///
/// What the site sets reaches the host's requests: on Android the page and
/// the host share the system's cookie store; on iOS and macOS the host's
/// cookies are put in the page's store when it opens and taken back when it
/// closes (tachi_browser.dart).
class TachiWebViewPage extends StatefulWidget {
  const TachiWebViewPage({super.key});

  /// Where webview_flutter has a web view; Windows and Linux have none.
  static bool get supported => Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  @override
  State<TachiWebViewPage> createState() => _TachiWebViewPageState();
}

class _TachiWebViewPageState extends State<TachiWebViewPage> {
  final String _sourceId = Get.arguments as String;
  final Set<String> _visited = <String>{};
  WebViewController? _controller;
  String? _title;
  int _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final TachiClient client = await tachiHost.client();
      final ({String url, String? userAgent}) site = await client.sourceWeb(_sourceId);
      await tachiBrowser.shareHostCookies(client, site.url);
      final WebViewController controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: _visited.add,
            onUrlChange: (UrlChange change) {
              if (change.url != null) {
                _visited.add(change.url!);
              }
            },
            onProgress: (int progress) {
              if (mounted) {
                setState(() => _progress = progress);
              }
            },
            onPageFinished: (String url) async {
              final String? title = await _controller?.getTitle();
              if (mounted) {
                setState(() => _title = title);
              }
            },
          ),
        );
      if (site.userAgent != null) {
        await controller.setUserAgent(site.userAgent);
      }
      _visited.add(site.url);
      await controller.loadRequest(Uri.parse(site.url));
      if (mounted) {
        setState(() => _controller = controller);
      }
    } catch (e) {
      log.warning('Opening the site of Tachiyomi source $_sourceId failed', e);
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  @override
  void dispose() {
    if (_controller != null) {
      final List<String> visited = _visited.toList();
      unawaited(
        tachiHost.run((TachiClient client) => tachiBrowser.takeEngineCookies(client, visited)).catchError((Object e) {
          log.warning('Taking the cookies of Tachiyomi source $_sourceId failed', e);
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final WebViewController? controller = _controller;
    return Scaffold(
      appBar: AppBar(
        title: Text(_title?.isNotEmpty == true ? _title! : tachiExtensionService.source(_sourceId)?.name ?? 'tachiOpenInWebView'.tr),
        actions: [
          if (controller != null) IconButton(icon: const Icon(Icons.refresh), tooltip: 'refresh'.tr, onPressed: controller.reload),
        ],
        bottom: controller != null && _progress < 100
            ? PreferredSize(preferredSize: const Size.fromHeight(2), child: LinearProgressIndicator(value: _progress / 100, minHeight: 2))
            : null,
      ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
          : controller == null
              ? const Center(child: CircularProgressIndicator())
              : WebViewWidget(controller: controller),
    );
  }
}
