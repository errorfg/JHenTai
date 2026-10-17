import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/setting/network_setting.dart';
import 'package:jhentai/src/utils/proxy_util.dart';
import 'package:path/path.dart' as p;

import 'tachi_client.dart';

TachiHost tachiHost = TachiHost();

/// Starts the extension host (`ext_host/`) when Tachiyomi sources are first
/// used and hands out its client.
///
/// - Android: in the app's process, on the system's runtime (see
///   android/app/.../ExtHostPlugin.kt).
/// - iOS: in the app's process, on the OpenJDK runtime the app carries.
/// - Desktop: a child process on the bundled runtime in `exthost/`, ending
///   when the app ends (its standard input closes).
class TachiHost {
  static const MethodChannel _channel = MethodChannel('com.gallery.reader/exthost');

  Future<TachiClient>? _starting;
  TachiClient? _client;
  Process? _process;

  /// The client once the host runs, without starting it.
  TachiClient? get clientIfRunning => _client;

  bool get supported => Platform.isAndroid || Platform.isIOS || _desktopRuntime() != null;

  Directory get dataDir => Directory(p.join((pathService.appSupportDir ?? pathService.getVisibleDir()).path, 'tachiyomi'));

  /// The host's client, starting the host first if needed. Concurrent
  /// callers share one start.
  Future<TachiClient> client() {
    final TachiClient? client = _client;
    if (client != null) {
      return Future<TachiClient>.value(client);
    }
    return _starting ??= _start().then((TachiClient client) {
      _client = client;
      return client;
    }).whenComplete(() => _starting = null);
  }

  /// After the host stopped answering (iOS reclaims sockets of apps in the
  /// background): opens its port again, or starts it anew.
  Future<TachiClient> recover() async {
    final TachiClient? current = _client;
    if (current != null && await current.ping()) {
      return current;
    }
    if (current != null && (Platform.isIOS || Platform.isAndroid)) {
      final int port = await _channel.invokeMethod<int>('restartServer') ?? -1;
      if (port > 0) {
        current.close();
        _client = TachiClient(port: port, token: current.token);
        return _client!;
      }
    }
    _client = null;
    _process?.kill();
    _process = null;
    return client();
  }

  /// Runs [action], and once more after [recover] when the host is gone.
  Future<T> run<T>(Future<T> Function(TachiClient client) action) async {
    final TachiClient first = await client();
    try {
      return await action(first);
    } on SocketException {
      return action(await recover());
    } on HttpException {
      return action(await recover());
    }
  }

  /// Sends the app's current proxy setting to a running host.
  Future<void> applyProxy() async {
    final TachiClient? client = _client;
    if (client != null) {
      await client.configure(proxy: await proxySpecForHost());
    }
  }

  Future<TachiClient> _start() async {
    final String token = _token();
    final Directory dir = dataDir..createSync(recursive: true);
    final String config = jsonEncode(<String, Object?>{
      'dataDir': dir.path,
      'token': token,
      'proxy': await proxySpecForHost(),
    });
    final Stopwatch watch = Stopwatch()..start();
    final int port;
    if (Platform.isAndroid || Platform.isIOS) {
      port = await _channel.invokeMethod<int>('start', config) ?? -1;
    } else {
      port = await _startProcess(config);
    }
    if (port <= 0) {
      throw const SocketException('The extension host did not start');
    }
    log.info('Extension host on port $port, started in ${watch.elapsedMilliseconds} ms');
    return TachiClient(port: port, token: token);
  }

  /// `exthost/` of a desktop build: `jre/` and `exthost.jar`.
  static Directory? _desktopRuntime() {
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      return null;
    }
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final List<String> candidates = <String>[
      if (Platform.isMacOS) p.normalize(p.join(exeDir, '..', 'Resources', 'exthost')),
      p.join(exeDir, 'exthost'),
    ];
    for (final String candidate in candidates) {
      if (File(p.join(candidate, 'exthost.jar')).existsSync()) {
        return Directory(candidate);
      }
    }
    return null;
  }

  Future<int> _startProcess(String config) async {
    final Directory? runtime = _desktopRuntime();
    if (runtime == null) {
      throw const SocketException('This build does not include the extension host');
    }
    final String java = p.join(runtime.path, 'jre', 'bin', Platform.isWindows ? 'java.exe' : 'java');
    final Process process = await Process.start(
      java,
      <String>[
        '-XX:+UnlockDiagnosticVMOptions',
        '-XX:-BytecodeVerificationRemote',
        '-Xmx512m',
        '-jar',
        p.join(runtime.path, 'exthost.jar'),
      ],
      workingDirectory: runtime.path,
    );
    _process = process;
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((String line) => log.debug('[exthost] $line'));
    final Completer<int> port = Completer<int>();
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((String line) {
      if (!port.isCompleted) {
        try {
          port.complete(((jsonDecode(line) as Map<String, dynamic>)['port'] as num).toInt());
        } catch (e) {
          port.completeError(e);
        }
      }
    });
    unawaited(process.exitCode.then((int code) {
      log.warning('Extension host exited with $code');
      if (!port.isCompleted) {
        port.completeError(SocketException('The extension host exited with $code'));
      }
      if (identical(_process, process)) {
        _process = null;
        _client = null;
      }
    }));
    // The host reads one line, then waits for the pipe to close.
    process.stdin.writeln(config);
    await process.stdin.flush();
    return port.future.timeout(const Duration(seconds: 60));
  }

  static String _token() {
    final Random random = Random.secure();
    return List<String>.generate(32, (_) => random.nextInt(16).toRadixString(16)).join();
  }

  /// The app's proxy for the host: `http://host:port`, `socks5://host:port`,
  /// or empty for a direct connection.
  static Future<String> proxySpecForHost() async {
    String address = networkSetting.proxyAddress.value.trim();
    switch (networkSetting.proxyType.value) {
      case JProxyType.direct:
        return '';
      case JProxyType.system:
        address = (await getSystemProxyAddress()).trim();
        return address.isEmpty ? '' : 'http://$address';
      case JProxyType.http:
        return address.isEmpty ? '' : 'http://$address';
      case JProxyType.socks5:
        return address.isEmpty ? '' : 'socks5://$address';
      case JProxyType.socks4:
        return address.isEmpty ? '' : 'socks4://$address';
    }
  }
}
