import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/service/cloud/s3_provider.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sync_service.dart';

class _SilentLogService extends LogService {
  @override
  void trace(Object msg, [bool withStack = false]) {}
  @override
  void debug(Object msg, [bool withStack = false]) {}
  @override
  void info(Object msg, [bool withStack = false]) {}
  @override
  void warning(Object msg, [Object? error, bool withStack = false]) {}
  @override
  void error(Object msg, [Object? error, StackTrace? stackTrace]) {}
}

S3Provider _provider(Duration timeout) => S3Provider(
      endpoint: 's3.example.test',
      accessKey: 'key',
      secretKey: 'secret',
      bucketName: 'bucket',
      region: 'us-east-1',
      useSSL: false,
      timeout: timeout,
    );

/// Sends the requests to a server on this machine, over real connections.
class _ToLocal extends http.BaseClient {
  _ToLocal(this.port);

  final int port;
  final IOClient _io = IOClient();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final http.ByteStream body = request.finalize();
    final http.StreamedRequest local = http.StreamedRequest(request.method, request.url.replace(host: '127.0.0.1', port: port))
      ..headers.addAll(request.headers)
      ..contentLength = request.contentLength;
    body.listen(local.sink.add, onError: local.sink.addError, onDone: local.sink.close);
    return _io.send(local);
  }

  @override
  void close() => _io.close();
}

/// A service that takes connections and what is sent on them, and answers
/// with [answer] (nothing by default), never finishing.
class _StalledServer {
  _StalledServer({this.answer = ''});

  final String answer;
  late ServerSocket _socket;
  int connections = 0;
  final Completer<void> closedByClient = Completer<void>();

  int get port => _socket.port;

  Future<void> start() async {
    _socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket.listen((Socket connection) {
      connections++;
      bool answered = false;
      connection.listen(
        (List<int> data) {
          if (!answered && answer.isNotEmpty && utf8.decode(data, allowMalformed: true).contains('\r\n\r\n')) {
            answered = true;
            connection.add(utf8.encode(answer));
          }
        },
        onDone: () {
          if (!closedByClient.isCompleted) {
            closedByClient.complete();
          }
        },
        onError: (Object _) {
          if (!closedByClient.isCompleted) {
            closedByClient.complete();
          }
        },
      );
    });
  }

  Future<void> stop() => _socket.close();
}

void main() {
  setUp(() => log = _SilentLogService());

  test('a request the service never answers ends the sync, which lets the next one in', () async {
    final List<String> requests = <String>[];
    final MockClient stalled = MockClient.streaming((http.BaseRequest request, http.ByteStream body) {
      requests.add(request.method);
      return Completer<http.StreamedResponse>().future;
    });
    final SyncService service = SyncService(providerFactory: (_) => _provider(const Duration(milliseconds: 200)));
    Future<SyncResult> sync() => http.runWithClient(
          () => service.sync(types: const <CloudConfigTypeEnum>[CloudConfigTypeEnum.quickSearch], providerName: 's3'),
          () => stalled,
        );

    final SyncResult first = await sync().timeout(const Duration(seconds: 5));
    expect(first.success, isFalse);
    expect(first.message, contains('TimeoutException'));

    final SyncResult second = await sync().timeout(const Duration(seconds: 5));
    expect(second.message, isNot('Sync already in progress'));
    expect(requests, <String>['HEAD', 'HEAD']);
  });

  test('a sync given up keeps the next one out until its request is ended, then lets it in', () async {
    final MockClient stalled = MockClient.streaming((http.BaseRequest request, http.ByteStream body) => Completer<http.StreamedResponse>().future);
    final SyncService service = SyncService(
      providerFactory: (_) => _provider(const Duration(milliseconds: 600)),
      syncTimeout: const Duration(milliseconds: 100),
    );
    Future<SyncResult> sync() => http.runWithClient(
          () => service.sync(types: const <CloudConfigTypeEnum>[CloudConfigTypeEnum.quickSearch], providerName: 's3'),
          () => stalled,
        );

    expect((await sync()).message, startsWith('Sync timed out'));
    expect((await sync()).message, 'Sync already in progress');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect((await sync().timeout(const Duration(seconds: 5))).message, isNot('Sync already in progress'));
  });

  test('an upload the service does not answer is ended, its connection closed', () async {
    final _StalledServer server = _StalledServer();
    await server.start();
    addTearDown(server.stop);

    final Stopwatch watch = Stopwatch()..start();
    await expectLater(
      http.runWithClient(() => _provider(const Duration(milliseconds: 300)).upload('{"configs":[]}'), () => _ToLocal(server.port)),
      throwsA(isA<TimeoutException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    await server.closedByClient.future.timeout(const Duration(seconds: 3));
    expect(server.connections, 1);
  });

  test('a download that stops coming is ended, its connection closed', () async {
    final _StalledServer server = _StalledServer(answer: 'HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n0123456789');
    await server.start();
    addTearDown(server.stop);

    await expectLater(
      http.runWithClient(() => _provider(const Duration(milliseconds: 300)).getRawObject('manifest.json'), () => _ToLocal(server.port)),
      throwsA(isA<TimeoutException>()),
    );
    await server.closedByClient.future.timeout(const Duration(seconds: 3));
  });
}
