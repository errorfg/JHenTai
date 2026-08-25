import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/network/eh2telegraph_client.dart';
import 'package:jhentai/src/setting/eh2telegraph_setting.dart';

/// 极简本地服务器：记录请求并按路径返回预设响应。
class _FakeBot {
  _FakeBot(this.server, this.token);

  final HttpServer server;
  final String token;
  final List<HttpRequest> seen = [];
  final List<String> bodies = [];

  static Future<_FakeBot> start({required String token}) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakeBot bot = _FakeBot(server, token);
    server.listen(bot._handle);
    return bot;
  }

  String get endpoint => 'http://127.0.0.1:${server.port}';

  Future<void> _handle(HttpRequest request) async {
    seen.add(request);
    final String body = await utf8.decoder.bind(request).join();
    bodies.add(body);
    final HttpResponse response = request.response;
    response.headers.contentType = ContentType.json;
    if (request.uri.path == '/health') {
      response.statusCode = 200;
      response.write(jsonEncode({'ok': true}));
    } else if (request.uri.path == '/sync') {
      final String? auth = request.headers.value('authorization');
      if (auth != 'Bearer $token') {
        response.statusCode = 401;
        response.write(
          jsonEncode({'error': 'missing or invalid bearer token'}),
        );
      } else {
        final Map<String, dynamic> json = (jsonDecode(body) as Map)
            .cast<String, dynamic>();
        final String url = json['url']?.toString() ?? '';
        if (url.contains('nhentai.net/g/')) {
          response.statusCode = 202;
          response.write(jsonEncode({'accepted': true, 'url': url.trim()}));
        } else {
          response.statusCode = 400;
          response.write(jsonEncode({'error': 'unsupported gallery url'}));
        }
      }
    } else {
      response.statusCode = 404;
    }
    await response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  group('Eh2TelegraphSetting.normalizeEndpoint', () {
    test('adds http scheme and strips trailing slashes', () {
      expect(
        Eh2TelegraphSetting.normalizeEndpoint(' 100.64.0.1:8788/ '),
        'http://100.64.0.1:8788',
      );
      expect(
        Eh2TelegraphSetting.normalizeEndpoint('https://bot.example//'),
        'https://bot.example',
      );
      expect(Eh2TelegraphSetting.normalizeEndpoint('   '), '');
    });
  });

  group('Eh2TelegraphClient', () {
    late _FakeBot bot;

    setUp(() async {
      bot = await _FakeBot.start(token: 'test-token-0123456789');
    });

    tearDown(() => bot.close());

    test('health returns true on 200', () async {
      final client = Eh2TelegraphClient(
        endpoint: bot.endpoint,
        token: 'test-token-0123456789',
      );
      expect(await client.health(), isTrue);
    });

    test(
      'sync posts bearer token and json url, returns accepted url',
      () async {
        final client = Eh2TelegraphClient(
          endpoint: '${bot.endpoint}/',
          token: ' test-token-0123456789 ',
        );
        final String accepted = await client.sync(
          'https://nhentai.net/g/600000',
        );
        expect(accepted, 'https://nhentai.net/g/600000');
        final HttpRequest request = bot.seen.last;
        expect(request.method, 'POST');
        expect(request.uri.path, '/sync');
        expect(
          request.headers.value('authorization'),
          'Bearer test-token-0123456789',
        );
        expect(jsonDecode(bot.bodies.last), {
          'url': 'https://nhentai.net/g/600000',
        });
      },
    );

    test('sync surfaces server rejection with status and message', () async {
      final client = Eh2TelegraphClient(
        endpoint: bot.endpoint,
        token: 'wrong-token',
      );
      await expectLater(
        client.sync('https://nhentai.net/g/1'),
        throwsA(
          isA<Eh2TelegraphException>()
              .having((e) => e.statusCode, 'status', 401)
              .having((e) => e.message, 'message', contains('bearer')),
        ),
      );
      final client2 = Eh2TelegraphClient(
        endpoint: bot.endpoint,
        token: 'test-token-0123456789',
      );
      await expectLater(
        client2.sync('https://example.com/x'),
        throwsA(
          isA<Eh2TelegraphException>().having(
            (e) => e.statusCode,
            'status',
            400,
          ),
        ),
      );
    });
  });
}
