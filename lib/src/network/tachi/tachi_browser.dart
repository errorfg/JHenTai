import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:jhentai/src/service/log.dart';

import 'tachi_client.dart';
import 'tachi_host.dart';

TachiBrowser tachiBrowser = TachiBrowser();

/// Lends the extension host this platform's WKWebView (iOS and macOS) for the
/// WebView extensions use: carries the host's commands (`/browser/poll`) to
/// the plugin's TachiBrowser.swift and what the pages do back
/// (`/browser/events`); see the host's BrowserRelay.kt. Also moves cookies
/// between the host and the app's own web page.
class TachiBrowser {
  static const MethodChannel _channel = MethodChannel('com.gallery.reader/exthost/browser');

  /// Where the plugin has a browser engine to lend.
  static bool get supported => Platform.isIOS || Platform.isMacOS;

  bool _relaying = false;
  final List<Object?> _events = <Object?>[];
  Future<void>? _delivering;

  /// Starts relaying for the running host; it ends when the host is gone,
  /// and the next start of the host starts it again.
  void relay() {
    if (!supported || _relaying) {
      return;
    }
    _relaying = true;
    _channel.setMethodCallHandler(_onEngine);
    unawaited(_poll());
  }

  Future<void> _poll() async {
    try {
      while (true) {
        final TachiClient? client = tachiHost.clientIfRunning;
        if (client == null) {
          return;
        }
        try {
          final List<dynamic> commands = await client.browserCommands();
          for (final dynamic command in commands) {
            await _channel.invokeMethod<void>('command', command);
          }
        } on SocketException {
          await _recover();
        } on HttpException {
          await _recover();
        } catch (e) {
          log.warning('Browser relay: $e');
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
    } finally {
      _relaying = false;
    }
  }

  /// The host stopped answering (iOS closes the port of an app in the background).
  Future<void> _recover() async {
    try {
      await tachiHost.recover();
    } catch (e) {
      log.warning('Browser relay: the host did not come back: $e');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<dynamic> _onEngine(MethodCall call) async {
    if (call.method == 'events') {
      _events.addAll(call.arguments as List<Object?>);
      _delivering ??= _deliver().whenComplete(() => _delivering = null);
    }
    return null;
  }

  /// Posts the engine's events in order, in batches.
  Future<void> _deliver() async {
    while (_events.isNotEmpty) {
      final List<Object?> batch = List<Object?>.of(_events);
      _events.clear();
      try {
        await tachiHost.run((TachiClient client) => client.browserEvents(batch));
      } catch (e) {
        log.warning('Browser relay: ${batch.length} events not delivered: $e');
      }
    }
  }

  /// Puts the host's cookies for [url] in the engine's store, which the app's
  /// web pages share.
  Future<void> shareHostCookies(TachiClient client, String url) async {
    if (supported) {
      await _channel.invokeMethod<void>('setCookies', <String, Object?>{'cookies': await client.cookies(url)});
    }
  }

  /// Gives the host the engine's cookies for the sites of [urls], e.g. after
  /// a login in the app's web page.
  Future<void> takeEngineCookies(TachiClient client, Iterable<String> urls) async {
    if (supported) {
      final List<dynamic> cookies = await _channel.invokeMethod<List<dynamic>>('cookies', <String, Object?>{'urls': urls.toList()}) ?? const <dynamic>[];
      if (cookies.isNotEmpty) {
        await client.importCookies(cookies);
      }
    }
  }
}
